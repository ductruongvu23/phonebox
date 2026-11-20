#import "PBAgentStream.h"

@interface PBAgentStream ()
- (void)dispatch:(NSInteger)gen event:(NSString *)event data:(NSString *)data;
- (BOOL)alive:(NSInteger)gen;
- (PBAgentLink *)link;
@end

/// One connection: its own parse state and delegate, so a connection that is being cancelled can never touch the next one.
@interface PBStreamConn : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, weak) PBAgentStream *stream;
@property (nonatomic) NSInteger generation;
@property (nonatomic) PBRoute route;
@property (nonatomic) BOOL opened;
@property (nonatomic, strong) PBPinDelegate *pinner;
@property (nonatomic, strong) dispatch_semaphore_t done;
@end

@implementation PBAgentStream {
    PBAgentLink *_link;
    void (^_deliver)(NSString *, NSString *);
    NSObject *_gate;
    BOOL _running;
    NSInteger _generation; // each start()/stop() advances it; a loop from an earlier one ends without side effects
    NSURLSessionTask *_current;

}

- (instancetype)initWithLink:(PBAgentLink *)link deliver:(void (^)(NSString *, NSString *))deliver {
    if ((self = [super init])) {
        _link = link; _deliver = [deliver copy]; _gate = [NSObject new];
    }
    return self;
}

- (void)start {
    NSInteger gen;
    @synchronized(_gate) {
        if (_running) return;
        _running = YES;
        gen = ++_generation;
    }
    NSThread *t = [[NSThread alloc] initWithBlock:^{ [self loop:gen]; }];
    t.name = @"agent-stream";
    [t start];
}

- (void)stop {
    NSURLSessionTask *active;
    @synchronized(_gate) {
        _running = NO;
        _generation++;
        active = _current;
        _current = nil;
    }
    [active cancel];
}

- (PBAgentLink *)link { return _link; }

- (BOOL)alive:(NSInteger)gen { @synchronized(_gate) { return _running && gen == _generation; } }

/// Delivers only while generation [gen] is current; check and delivery happen under the gate, so nothing is
/// delivered after stop() returns. [deliver] must not block (it only posts to the main queue).
- (void)dispatch:(NSInteger)gen event:(NSString *)event data:(NSString *)data {
    @synchronized(_gate) { if (_running && gen == _generation) _deliver(event, data); }
}

- (void)loop:(NSInteger)gen {
    while ([self alive:gen]) {
        BOOL opened = NO;
        for (PBStreamTarget *target in _link.streamTargets) {
            if (![self alive:gen]) break;
            // no probe on USB: a connection through the tunnel uses up one of the PC's idle connections
            if (target.route == PBRouteWiFi && ![PBAgentLink probeHost:target.host port:target.port timeoutMs:1500]) continue;
            opened = [self readFrom:target generation:gen];
            if (opened) break; // it worked and then ended: reconnect through the whole list again
        }
        if (opened) [self dispatch:gen event:@"close" data:@"{}"];
        if (![self alive:gen]) break;
        [NSThread sleepForTimeInterval:opened ? 0.3 : 2.0];
    }
}

- (BOOL)readFrom:(PBStreamTarget *)target generation:(NSInteger)gen {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:target.urlString]];
    r.timeoutInterval = 8; // the agent sends "state" every second: a silent connection this long is dead
    r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [r setValue:@"text/event-stream" forHTTPHeaderField:@"Accept"];
    [_link applyIdentity:r];
    if (target.token) [r setValue:[@"Bearer " stringByAppendingString:target.token] forHTTPHeaderField:@"Authorization"];

    PBStreamConn *conn = [PBStreamConn new];
    conn.stream = self;
    conn.generation = gen;
    conn.route = target.route;
    conn.pinner = [[PBPinDelegate alloc] initWithPin:target.pin];
    conn.done = dispatch_semaphore_create(0);

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.URLCache = nil; cfg.HTTPCookieStorage = nil;
    if (target.route == PBRouteUSB) cfg.connectionProxyDictionary = @{};
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:conn delegateQueue:nil];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:r];
    @synchronized(_gate) {
        if (!(_running && gen == _generation)) { [session invalidateAndCancel]; return NO; }
        _current = task;
    }
    [task resume];
    dispatch_semaphore_wait(conn.done, DISPATCH_TIME_FOREVER);
    @synchronized(_gate) { if (_current == task) _current = nil; }
    [session invalidateAndCancel];
    return conn.opened;
}

@end

@implementation PBStreamConn {
    NSMutableData *_buffer;
    NSString *_event;
    NSMutableString *_data;
    NSTimeInterval _since;
}

- (instancetype)init {
    if ((self = [super init])) {
        _buffer = [NSMutableData data]; _event = @"message"; _data = [NSMutableString string];
        _since = NSDate.timeIntervalSinceReferenceDate;
    }
    return self;
}

- (void)URLSession:(NSURLSession *)s didReceiveChallenge:(NSURLAuthenticationChallenge *)c completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))d { [self.pinner handleChallenge:c completionHandler:d]; }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didReceiveChallenge:(NSURLAuthenticationChallenge *)c completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))d { [self.pinner handleChallenge:c completionHandler:d]; }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)n completionHandler:(void (^)(NSURLRequest *))d { d(nil); }

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveResponse:(NSURLResponse *)resp completionHandler:(void (^)(NSURLSessionResponseDisposition))done {
    NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
    PBAgentStream *st = self.stream;
    if (code != 200 || ![st alive:self.generation]) { done(NSURLSessionResponseCancel); return; }
    self.opened = YES;
    [st.link noteRoute:self.route];
    [st dispatch:self.generation event:@"open" data:[NSString stringWithFormat:@"{\"route\":\"%@\"}", PBRouteName(self.route)]];
    done(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)data {
    PBAgentStream *st = self.stream;
    if (![st alive:self.generation]) { [t cancel]; return; }
    [_buffer appendData:data];
    const uint8_t *b = _buffer.bytes;
    NSUInteger start = 0, n = _buffer.length;
    for (NSUInteger i = 0; i < n; i++) {
        if (b[i] != '\n') continue;
        NSUInteger end = i;
        if (end > start && b[end - 1] == '\r') end--;
        NSString *line = [[NSString alloc] initWithBytes:b + start length:end - start encoding:NSUTF8StringEncoding] ?: @"";
        start = i + 1;
        if (line.length == 0) {
            if (_data.length) [st dispatch:self.generation event:_event data:[_data copy]];
            _event = @"message";
            [_data setString:@""];
            // on Wi-Fi, reconnect every minute so a freshly plugged-in cable is preferred again
            if (self.route == PBRouteWiFi && NSDate.timeIntervalSinceReferenceDate - _since > 60) { [t cancel]; return; }
        } else if ([line hasPrefix:@"event:"]) {
            _event = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        } else if ([line hasPrefix:@"data:"]) {
            NSString *v = [line substringFromIndex:5];
            while (v.length && [v characterAtIndex:0] <= ' ') v = [v substringFromIndex:1];
            [_data appendString:v];
        }
    }
    [_buffer replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    dispatch_semaphore_signal(self.done);
}

@end
