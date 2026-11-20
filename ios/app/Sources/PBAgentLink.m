#import "PBAgentLink.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <sys/socket.h>
#import <sys/utsname.h>
#import <netdb.h>
#import <poll.h>
#import <fcntl.h>
#import <unistd.h>

static NSString *const kUSBBase = @"http://127.0.0.1:8765";
static NSString *const kPcsKey = @"pb.pcs";
static NSString *const kActiveKey = @"pb.active";

NSString *PBRouteName(PBRoute r) { return r == PBRouteUSB ? @"usb" : r == PBRouteWiFi ? @"wifi" : @"none"; }

static NSString *PBHex(const unsigned char *d, size_t n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (size_t i = 0; i < n; i++) [s appendFormat:@"%02x", d[i]];
    return s;
}

#pragma mark - Small value classes

@implementation PBReply
+ (instancetype)withCode:(NSInteger)code json:(NSString *)json {
    PBReply *r = [PBReply new];
    r.code = code;
    r.contentType = @"application/json";
    r.body = [json dataUsingEncoding:NSUTF8StringEncoding];
    return r;
}
@end

@implementation PBStreamTarget
@end

@implementation PBPairFailure
- (NSString *)message {
    NSString *hosts = [self.hosts componentsJoinedByString:@", "];
    switch (self.kind) {
        case PBPairUnreachable: return [NSString stringWithFormat:PBL(@"pair_failed_unreachable"), self.pc, hosts];
        case PBPairCodeRejected: return [NSString stringWithFormat:PBL(@"pair_failed_code"), self.pc];
        case PBPairBadAnswer: return [NSString stringWithFormat:PBL(@"pair_failed_answer"), self.pc, (int)self.code];
        case PBPairWrongCertificate: return PBL(@"pair_failed_certificate");
    }
    return @"";
}
@end

@interface PBPc : NSObject
@property (nonatomic, copy) NSString *pcId, *name, *token;
@property (nonatomic, copy) NSArray<NSString *> *hosts;
@property (nonatomic) int port;
@end
@implementation PBPc
- (NSDictionary *)json { return @{@"id": self.pcId, @"name": self.name ?: @"", @"hosts": self.hosts, @"port": @(self.port), @"token": self.token}; }
+ (PBPc *)fromJSON:(NSDictionary *)j {
    if (![j isKindOfClass:NSDictionary.class]) return nil;
    NSString *i = j[@"id"], *t = j[@"token"]; NSArray *h = j[@"hosts"]; NSNumber *p = j[@"port"];
    if (![i isKindOfClass:NSString.class] || ![t isKindOfClass:NSString.class] || ![h isKindOfClass:NSArray.class] || ![p isKindOfClass:NSNumber.class]) return nil;
    PBPc *pc = [PBPc new];
    pc.pcId = i; pc.token = t; pc.hosts = h; pc.port = p.intValue;
    pc.name = [j[@"name"] isKindOfClass:NSString.class] ? j[@"name"] : @"";
    return pc;
}
@end

@implementation PBPairLink
+ (BOOL)isLocalAddress:(NSString *)host {
    NSArray *p = [host componentsSeparatedByString:@"."];
    if (p.count != 4) return NO;
    int b[4];
    for (int i = 0; i < 4; i++) {
        NSString *s = p[i];
        if (s.length < 1 || s.length > 3) return NO;
        NSScanner *sc = [NSScanner scannerWithString:s]; int v;
        if (![sc scanInt:&v] || !sc.isAtEnd || v < 0 || v > 255) return NO;
        b[i] = v;
    }
    return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127);
}

- (NSString *)check {
    NSString *s = [[self.fingerprint substringToIndex:8] uppercaseString];
    return [NSString stringWithFormat:@"%@ %@", [s substringToIndex:4], [s substringFromIndex:4]];
}

+ (PBPairLink *)parse:(NSURL *)url {
    if (!url) return nil;
    NSString *raw = nil;
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if ([c.scheme isEqualToString:@"https"] && [c.host isEqualToString:@"ersinkoc.github.io"] && [c.path hasPrefix:@"/phonebox/pair"]) raw = c.percentEncodedFragment;
    else if ([c.scheme isEqualToString:@"phonebox"] && [c.host isEqualToString:@"pair"]) raw = c.percentEncodedQuery;
    if (!raw) return nil;
    NSMutableDictionary<NSString *, NSString *> *q = [NSMutableDictionary dictionary];
    for (NSString *part in [raw componentsSeparatedByString:@"&"]) {
        NSRange eq = [part rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0) continue;
        NSString *v = [[part substringFromIndex:eq.location + 1] stringByRemovingPercentEncoding];
        if (v) q[[part substringToIndex:eq.location]] = v;
    }
    if (![q[@"v"] isEqualToString:@"1"]) return nil;
    NSString *fp = q[@"fp"].lowercaseString;
    if (!fp || ![[NSPredicate predicateWithFormat:@"SELF MATCHES %@", @"^[0-9a-f]{64}$"] evaluateWithObject:fp]) return nil;
    int port = q[@"port"].intValue;
    if (port < 1 || port > 65535) return nil;
    NSString *code = q[@"c"];
    if (!code || ![[NSPredicate predicateWithFormat:@"SELF MATCHES %@", @"^[A-Za-z0-9_-]{16,64}$"] evaluateWithObject:code]) return nil;
    NSMutableArray *hosts = [NSMutableArray array];
    for (NSString *h in [q[@"h"] componentsSeparatedByString:@","]) {
        NSString *t = [h stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([self isLocalAddress:t] && hosts.count < 8) [hosts addObject:t];
    }
    if (!hosts.count) return nil;
    NSMutableString *pc = [NSMutableString string];
    for (NSUInteger i = 0; i < q[@"pc"].length && pc.length < 64; i++) {
        unichar ch = [q[@"pc"] characterAtIndex:i];
        if (ch >= ' ') [pc appendFormat:@"%C", ch];
    }
    PBPairLink *l = [PBPairLink new];
    l.pc = pc.length ? pc : @"your computer";
    l.fingerprint = fp; l.port = port; l.hosts = hosts; l.code = code;
    return l;
}
@end

#pragma mark - Pinning

@implementation PBPinDelegate
- (instancetype)initWithPin:(NSString *)pin { if ((self = [super init])) _pin = [pin copy]; return self; }

- (void)handleChallenge:(NSURLAuthenticationChallenge *)ch
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))done {
    if (![ch.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] || !self.pin || !ch.protectionSpace.serverTrust) {
        done(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    SecTrustRef trust = ch.protectionSpace.serverTrust;
    CFArrayRef chain = SecTrustCopyCertificateChain(trust);
    NSString *fp = nil;
    if (chain && CFArrayGetCount(chain) > 0) {
        SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(chain, 0);
        NSData *der = (NSData *)CFBridgingRelease(SecCertificateCopyData(leaf));
        unsigned char h[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(der.bytes, (CC_LONG)der.length, h);
        fp = PBHex(h, sizeof h);
    }
    if (chain) CFRelease(chain);
    // identity is the pinned certificate, not the host name or a CA
    if (fp && [fp caseInsensitiveCompare:self.pin] == NSOrderedSame) {
        done(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    } else {
        self.pinMismatch = YES;
        done(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
}

- (void)URLSession:(NSURLSession *)s didReceiveChallenge:(NSURLAuthenticationChallenge *)c completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))d { [self handleChallenge:c completionHandler:d]; }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didReceiveChallenge:(NSURLAuthenticationChallenge *)c completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))d { [self handleChallenge:c completionHandler:d]; }
- (void)URLSession:(NSURLSession *)s webSocketTask:(NSURLSessionWebSocketTask *)t didCloseWithCode:(NSURLSessionWebSocketCloseCode)c reason:(NSData *)r { void (^cb)(void) = self.onWebSocketClose; if (cb) cb(); }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e { if (e) { void (^cb)(void) = self.onWebSocketClose; if (cb) cb(); } }
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t willPerformHTTPRedirection:(NSHTTPURLResponse *)r newRequest:(NSURLRequest *)n completionHandler:(void (^)(NSURLRequest *))d { d(nil); }
@end

#pragma mark - Link

@interface PBTrackpadEvent : NSObject
@property (nonatomic, copy) NSString *type;
@property (nonatomic) double dx, dy, delta;
@end
@implementation PBTrackpadEvent
@end

@interface PBAgentLink ()
@property (atomic) PBRoute route;
@end

@implementation PBAgentLink {
    NSMutableArray<PBPc *> *_pcs;
    NSString *_activeId;
    NSString *_deviceId, *_deviceModel;
    NSURLSession *_usbSession;
    NSMutableDictionary<NSString *, NSURLSession *> *_wifiSessions; // by pin
    NSMutableDictionary<NSString *, PBPinDelegate *> *_wifiDelegates;
    NSInteger _preferredHost;
    NSTimeInterval _lastPair;
    dispatch_queue_t _background;
    BOOL _closed;
    // trackpad over HTTP: one in flight, the rest coalesced
    BOOL _tpInFlight;
    NSMutableArray<PBTrackpadEvent *> *_tpPending;
    NSURLSessionWebSocketTask *_ws;       // low-latency trackpad over Wi-Fi (Android's TrackpadSocket)
    NSURLSession *_wsSession;
    NSTimeInterval _wsLastAttempt;
}

- (instancetype)init {
    if ((self = [super init])) {
        _appVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
        NSString *vendor = UIDevice.currentDevice.identifierForVendor.UUIDString ?: @"unknown";
        unsigned char h[CC_SHA256_DIGEST_LENGTH];
        NSData *vd = [vendor dataUsingEncoding:NSUTF8StringEncoding];
        CC_SHA256(vd.bytes, (CC_LONG)vd.length, h);
        _deviceId = PBHex(h, 6);
        struct utsname u; uname(&u);
        _deviceModel = [NSString stringWithFormat:@"Apple %s", u.machine];
        _background = dispatch_queue_create("phonebox.link", DISPATCH_QUEUE_SERIAL);
        _wifiSessions = [NSMutableDictionary dictionary];
        _wifiDelegates = [NSMutableDictionary dictionary];
        _tpPending = [NSMutableArray array];
        _pcs = [NSMutableArray array];
        NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:kPcsKey];
        NSArray *arr = stored ? [NSJSONSerialization JSONObjectWithData:[stored dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if ([arr isKindOfClass:NSArray.class]) for (id j in arr) { PBPc *pc = [PBPc fromJSON:j]; if (pc) [_pcs addObject:pc]; }
        _activeId = [NSUserDefaults.standardUserDefaults stringForKey:kActiveKey];
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        cfg.URLCache = nil;
        cfg.HTTPCookieStorage = nil;
        cfg.connectionProxyDictionary = @{}; // loopback must never go through a proxy
        _usbSession = [NSURLSession sessionWithConfiguration:cfg delegate:[[PBPinDelegate alloc] initWithPin:nil] delegateQueue:nil];
    }
    return self;
}

#pragma mark Paired computers

- (void)saveLocked {
    NSMutableArray *a = [NSMutableArray array];
    for (PBPc *p in _pcs) [a addObject:p.json];
    NSData *d = [NSJSONSerialization dataWithJSONObject:a options:0 error:nil];
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    [ud setObject:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] forKey:kPcsKey];
    if (_activeId) [ud setObject:_activeId forKey:kActiveKey]; else [ud removeObjectForKey:kActiveKey];
}

- (PBPc *)activePcLocked {
    for (PBPc *p in _pcs) if ([p.pcId isEqualToString:_activeId]) return p;
    return _pcs.firstObject;
}
- (PBPc *)activePc { @synchronized(self) { return [self activePcLocked]; } }

- (void)changed { void (^cb)(void) = self.onChange; if (cb) cb(); }

- (NSString *)pcsJSON {
    @synchronized(self) {
        NSString *active = [self activePcLocked].pcId;
        NSMutableArray *a = [NSMutableArray array];
        for (PBPc *p in _pcs) [a addObject:@{@"id": p.pcId, @"name": p.name ?: @"", @"active": @([p.pcId isEqualToString:active])}];
        return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:a options:0 error:nil] encoding:NSUTF8StringEncoding];
    }
}

- (NSString *)pairedPc { return [self activePc].name; }

- (BOOL)selectPc:(NSString *)pcId {
    @synchronized(self) {
        BOOL found = NO;
        for (PBPc *p in _pcs) if ([p.pcId isEqualToString:pcId]) found = YES;
        if (!found) return NO;
        _activeId = pcId;
        _preferredHost = 0;
        [self saveLocked];
    }
    { NSURLSessionWebSocketTask *t; @synchronized(self) { t = _ws; } if (t) [self closeWebSocket:t]; }
    [self changed];
    return YES;
}

- (void)forgetPc:(NSString *)pcId {
    @synchronized(self) {
        NSMutableArray *rest = [NSMutableArray array];
        for (PBPc *p in _pcs) if (![p.pcId isEqualToString:pcId]) [rest addObject:p];
        _pcs = rest;
        if ([_activeId isEqualToString:pcId]) _activeId = rest.count ? ((PBPc *)rest.firstObject).pcId : nil;
        [self saveLocked];
    }
    [self changed];
}

/// Adds or replaces a computer (an entry with the same certificate, and optionally the same name) and makes it active.
- (void)storePc:(PBPc *)pc replacingSameName:(BOOL)byName {
    @synchronized(self) {
        if (_closed) return;
        NSMutableArray *list = [NSMutableArray array];
        for (PBPc *p in _pcs) {
            if ([p.pcId isEqualToString:pc.pcId]) continue;
            if (byName && pc.name.length && [p.name isEqualToString:pc.name]) continue;
            [list addObject:p];
        }
        [list addObject:pc];
        _pcs = list;
        _activeId = pc.pcId;
        _preferredHost = 0;
        [self saveLocked];
    }
    [self changed];
}

#pragma mark Requests

- (void)noteRoute:(PBRoute)route {
    if (self.route == route) return;
    self.route = route;
    [self changed];
}

- (void)applyIdentity:(NSMutableURLRequest *)r {
    [r setValue:_appVersion forHTTPHeaderField:@"X-PhoneBox-App"]; // lets the agent offer updates
    [r setValue:_deviceId forHTTPHeaderField:@"X-PhoneBox-Device"];
    [r setValue:_deviceModel forHTTPHeaderField:@"X-PhoneBox-Model"];
    // X-PhoneBox-WebView is deliberately not sent: the agent's WebView check is about Android System WebView.
}

+ (BOOL)probeHost:(NSString *)host port:(int)port timeoutMs:(int)timeoutMs {
    struct addrinfo hints; memset(&hints, 0, sizeof hints);
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *res = NULL;
    char ps[8]; snprintf(ps, sizeof ps, "%d", port);
    if (getaddrinfo(host.UTF8String, ps, &hints, &res) != 0 || !res) return NO;
    BOOL ok = NO;
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd >= 0) {
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        int r = connect(fd, res->ai_addr, res->ai_addrlen);
        if (r == 0) ok = YES;
        else if (errno == EINPROGRESS) {
            struct pollfd p = {fd, POLLOUT, 0};
            if (poll(&p, 1, timeoutMs) == 1) {
                int err = 0; socklen_t l = sizeof err;
                ok = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &l) == 0 && err == 0;
            }
        }
        close(fd);
    }
    freeaddrinfo(res);
    return ok;
}

- (NSURLSession *)sessionForPin:(NSString *)pin {
    @synchronized(self) {
        NSURLSession *s = _wifiSessions[pin];
        if (!s) {
            NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
            cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
            cfg.URLCache = nil;
            cfg.HTTPCookieStorage = nil;
            PBPinDelegate *d = [[PBPinDelegate alloc] initWithPin:pin];
            s = [NSURLSession sessionWithConfiguration:cfg delegate:d delegateQueue:nil];
            _wifiSessions[pin] = s;
            _wifiDelegates[pin] = d;
        }
        return s;
    }
}

/// One attempt. Returns nil with *error set when the request did not complete.
- (PBReply *)perform:(NSURLRequest *)req session:(NSURLSession *)session error:(NSError **)error {
    __block PBReply *reply = nil;
    __block NSError *failure = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *t = [session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSHTTPURLResponse *h = [resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)resp : nil;
        if (err || !h) { failure = err ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]; }
        else {
            NSInteger code = h.statusCode;
            if (code < 100 || code > 599 || (code >= 300 && code < 400)) {
                reply = [PBReply withCode:502 json:@"{\"error\":\"unexpected response\"}"];
            } else {
                reply = [PBReply new];
                reply.code = code;
                reply.contentType = h.allHeaderFields[@"Content-Type"] ?: h.allHeaderFields[@"content-type"];
                reply.body = data ?: [NSData data];
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [t resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (error) *error = failure;
    return reply;
}

- (NSMutableURLRequest *)build:(NSString *)method url:(NSString *)url body:(NSData *)body contentType:(NSString *)ct timeout:(NSTimeInterval)timeout {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.HTTPMethod = method;
    r.timeoutInterval = [method isEqualToString:@"POST"] ? 30 : timeout; // a workflow or restart outlasts a state poll
    r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    r.HTTPShouldHandleCookies = NO;
    [self applyIdentity:r];
    if ([method isEqualToString:@"POST"]) {
        if (ct) [r setValue:ct forHTTPHeaderField:@"Content-Type"];
        r.HTTPBody = body ?: [NSData data];
    }
    return r;
}

static PBReply *PBUnknownResult(void) {
    return [PBReply withCode:504 json:@"{\"ok\":false,\"error\":\"The command result is unknown; check the computer before retrying\"}"];
}

- (PBReply *)request:(NSString *)method path:(NSString *)path body:(NSData *)body contentType:(NSString *)ct {
    BOOL post = [method isEqualToString:@"POST"];
    NSError *error = nil;

    // USB first. No probe: a connection through the tunnel uses up one of the PC's idle connections, and "refused" is
    // instant on loopback when there is no tunnel (the listener only listens while the PC has one ready).
    {
        NSMutableURLRequest *r = [self build:method url:[kUSBBase stringByAppendingString:path] body:body contentType:ct timeout:4];
        PBReply *reply = [self perform:r session:_usbSession error:&error];
        if (reply) { [self noteRoute:PBRouteUSB]; [self maybePair]; return reply; }
        BOOL refused = [error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCannotConnectToHost;
        // Anything but a refusal may have delivered the body to the PC: never run a command twice by trying another route.
        if (post && !refused) return PBUnknownResult();
    }

    PBPc *pc = [self activePc];
    if (pc && pc.hosts.count) {
        NSURLSession *session = [self sessionForPin:pc.pcId];
        NSInteger count = (NSInteger)pc.hosts.count, start;
        @synchronized(self) { start = _preferredHost < count ? _preferredHost : 0; }
        for (NSInteger n = 0; n < count; n++) {
            NSInteger i = n == 0 ? start : (n <= start ? n - 1 : n); // preferred host first, then the rest in order
            NSString *host = pc.hosts[i];
            if (![PBAgentLink probeHost:host port:pc.port timeoutMs:1500]) continue;
            NSString *url = [NSString stringWithFormat:@"https://%@:%d%@", host, pc.port, path];
            NSMutableURLRequest *r = [self build:method url:url body:body contentType:ct timeout:4];
            [r setValue:[@"Bearer " stringByAppendingString:pc.token] forHTTPHeaderField:@"Authorization"];
            PBReply *reply = [self perform:r session:session error:&error];
            if (reply) {
                @synchronized(self) { _preferredHost = i; }
                [self noteRoute:PBRouteWiFi];
                return reply;
            }
            if (post) return PBUnknownResult();
        }
    }
    [self noteRoute:PBRouteNone];
    return [PBReply withCode:503 json:@"{\"error\":\"offline\"}"];
}

- (NSArray<PBStreamTarget *> *)streamTargets {
    NSMutableArray *out = [NSMutableArray array];
    PBStreamTarget *usb = [PBStreamTarget new];
    usb.route = PBRouteUSB; usb.host = @"127.0.0.1"; usb.port = 8765;
    usb.urlString = [kUSBBase stringByAppendingString:@"/api/stream"];
    [out addObject:usb];
    PBPc *pc = [self activePc];
    if (pc) {
        NSInteger count = (NSInteger)pc.hosts.count, start;
        @synchronized(self) { start = _preferredHost < count ? _preferredHost : 0; }
        for (NSInteger n = 0; n < count; n++) {
            NSInteger i = n == 0 ? start : (n <= start ? n - 1 : n);
            PBStreamTarget *t = [PBStreamTarget new];
            t.route = PBRouteWiFi; t.host = pc.hosts[i]; t.port = pc.port; t.pin = pc.pcId; t.token = pc.token;
            t.urlString = [NSString stringWithFormat:@"https://%@:%d/api/stream", t.host, t.port];
            [out addObject:t];
        }
    }
    return out;
}

#pragma mark USB re-pairing

/// While on USB, refresh the Wi-Fi pairing data about once a minute.
- (void)maybePair {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    @synchronized(self) { if (now - _lastPair < 60) return; _lastPair = now; }
    dispatch_async(_background, ^{
        NSMutableURLRequest *r = [self build:@"GET" url:[kUSBBase stringByAppendingString:@"/api/pair"] body:nil contentType:nil timeout:3];
        PBReply *reply = [self perform:r session:self->_usbSession error:NULL];
        if (!reply || reply.code != 200) return; // a redirect or error is not the agent's pairing answer
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:reply.body options:0 error:nil];
        if (![j isKindOfClass:NSDictionary.class]) return;
        NSString *name = [j[@"pc"] isKindOfClass:NSString.class] ? j[@"pc"] : @"";
        if ([j[@"enabled"] boolValue]) {
            PBPc *pc = [PBPc fromJSON:@{@"id": j[@"fingerprint"] ?: @"", @"name": name, @"hosts": j[@"hosts"] ?: @[], @"port": j[@"port"] ?: @0, @"token": j[@"token"] ?: @""}];
            if (pc && pc.token.length && pc.hosts.count) [self storePc:pc replacingSameName:YES];
        } else if (name.length) {
            // Wi-Fi was turned off on this computer: forget its pairing, keep the others
            @synchronized(self) {
                NSMutableArray *rest = [NSMutableArray array];
                for (PBPc *p in self->_pcs) if (![p.name isEqualToString:name]) [rest addObject:p];
                if (self->_closed || rest.count == self->_pcs.count) return;
                self->_pcs = rest;
                BOOL activeKept = NO;
                for (PBPc *p in rest) if ([p.pcId isEqualToString:self->_activeId]) activeKept = YES;
                if (!activeKept) self->_activeId = rest.count ? ((PBPc *)rest.firstObject).pcId : nil;
                [self saveLocked];
            }
            [self changed];
        }
    });
}

#pragma mark Pairing from a QR link

- (PBPairFailure *)failure:(PBPairFailureKind)k link:(PBPairLink *)l code:(NSInteger)code {
    PBPairFailure *f = [PBPairFailure new];
    f.kind = k; f.pc = l.pc; f.hosts = l.hosts; f.code = code;
    return f;
}

- (PBPairFailure *)claim:(PBPairLink *)link {
    PBPinDelegate *delegate = [[PBPinDelegate alloc] initWithPin:link.fingerprint];
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.URLCache = nil; cfg.HTTPCookieStorage = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:delegate delegateQueue:nil];
    PBPairFailure *problem = [self failure:PBPairUnreachable link:link code:0];
    for (NSString *host in link.hosts) {
        if (![PBAgentLink probeHost:host port:link.port timeoutMs:3000]) continue;
        NSString *url = [NSString stringWithFormat:@"https://%@:%d/api/pair/claim", host, link.port];
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
        r.HTTPMethod = @"POST";
        r.timeoutInterval = 8;
        [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [r setValue:_deviceModel forHTTPHeaderField:@"X-PhoneBox-Model"];
        r.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"code": link.code} options:0 error:nil];
        PBReply *reply = [self perform:r session:session error:NULL];
        if (!reply) {
            if (delegate.pinMismatch) { [session finishTasksAndInvalidate]; return [self failure:PBPairWrongCertificate link:link code:0]; }
            continue;
        }
        if (reply.code == 403) { [session finishTasksAndInvalidate]; return [self failure:PBPairCodeRejected link:link code:403]; }
        if (reply.code != 200) { problem = [self failure:PBPairBadAnswer link:link code:reply.code]; continue; }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:reply.body options:0 error:nil];
        NSString *fp = [j isKindOfClass:NSDictionary.class] && [j[@"fingerprint"] isKindOfClass:NSString.class] ? j[@"fingerprint"] : @"";
        NSString *token = [j isKindOfClass:NSDictionary.class] && [j[@"token"] isKindOfClass:NSString.class] ? j[@"token"] : nil;
        if ([fp caseInsensitiveCompare:link.fingerprint] != NSOrderedSame) { [session finishTasksAndInvalidate]; return [self failure:PBPairWrongCertificate link:link code:0]; }
        if (!token.length) { problem = [self failure:PBPairBadAnswer link:link code:reply.code]; continue; }
        NSMutableArray *hosts = [NSMutableArray array];
        if ([j[@"hosts"] isKindOfClass:NSArray.class])
            for (id h in j[@"hosts"]) if ([h isKindOfClass:NSString.class] && [PBPairLink isLocalAddress:h]) [hosts addObject:h];
        PBPc *pc = [PBPc new];
        pc.pcId = link.fingerprint.lowercaseString;
        pc.name = link.pc; // the name the user confirmed
        pc.hosts = hosts.count ? hosts : link.hosts;
        pc.port = [j[@"port"] isKindOfClass:NSNumber.class] ? [j[@"port"] intValue] : link.port;
        pc.token = token;
        [self storePc:pc replacingSameName:NO]; // only an entry for this very certificate is replaced
        [session finishTasksAndInvalidate];
        return nil;
    }
    [session finishTasksAndInvalidate];
    if (delegate.pinMismatch) return [self failure:PBPairWrongCertificate link:link code:0];
    return problem;
}

#pragma mark Trackpad

- (void)sendTrackpad:(NSString *)type dx:(double)dx dy:(double)dy delta:(double)delta {
    // On USB the HTTP path is as fast as it gets; on Wi-Fi a WebSocket avoids a request per event.
    if (self.route != PBRouteUSB) {
        NSString *json = [NSString stringWithFormat:@"{\"type\":\"%@\",\"dx\":%g,\"dy\":%g,\"delta\":%g}", type, dx, dy, delta];
        if (json.length <= 125 && [self wsSend:json]) return;
    }
    PBTrackpadEvent *e = [PBTrackpadEvent new];
    e.type = type; e.dx = dx; e.dy = dy; e.delta = delta;
    @synchronized(_tpPending) {
        if (_tpInFlight) {
            PBTrackpadEvent *last = _tpPending.lastObject;
            if (last && [last.type isEqualToString:type] && ([type isEqualToString:@"move"] || [type isEqualToString:@"scroll"])) {
                last.dx += dx; last.dy += dy; last.delta += delta;
            } else [_tpPending addObject:e];
            return;
        }
        _tpInFlight = YES;
    }
    [self dispatchTrackpad:e];
}

- (void)dispatchTrackpad:(PBTrackpadEvent *)e {
    dispatch_async(_background, ^{
        NSString *json = [NSString stringWithFormat:@"{\"type\":\"%@\",\"dx\":%g,\"dy\":%g,\"delta\":%g}", e.type, e.dx, e.dy, e.delta];
        [self request:@"POST" path:@"/api/trackpad" body:[json dataUsingEncoding:NSUTF8StringEncoding] contentType:@"application/json"];
        PBTrackpadEvent *next = nil;
        @synchronized(self->_tpPending) {
            if (self->_tpPending.count) { next = self->_tpPending.firstObject; [self->_tpPending removeObjectAtIndex:0]; }
            else self->_tpInFlight = NO;
        }
        if (next) [self dispatchTrackpad:next];
    });
}

#pragma mark Trackpad WebSocket

- (BOOL)wsSend:(NSString *)json {
    NSURLSessionWebSocketTask *t;
    @synchronized(self) { t = _ws; }
    if (!t || t.state != NSURLSessionTaskStateRunning) { [self ensureWebSocket]; return NO; }
    [t sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:json] completionHandler:^(NSError *error) {
        if (error) [self closeWebSocket:t];
    }];
    return YES;
}

/// Opens wss://<host>:<port>/api/trackpad on the last host that worked, at most once every 3 s.
- (void)ensureWebSocket {
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    PBPc *pc = [self activePc];
    if (!pc || !pc.hosts.count) return;
    NSString *host;
    @synchronized(self) {
        if (_ws || now - _wsLastAttempt < 3) return;
        _wsLastAttempt = now;
        host = pc.hosts[_preferredHost < (NSInteger)pc.hosts.count ? _preferredHost : 0];
    }
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.URLCache = nil; cfg.HTTPCookieStorage = nil;
    PBPinDelegate *delegate = [[PBPinDelegate alloc] initWithPin:pc.pcId];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:delegate delegateQueue:nil];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithFormat:@"wss://%@:%d/api/trackpad", host, pc.port]]];
    [r setValue:[@"Bearer " stringByAppendingString:pc.token] forHTTPHeaderField:@"Authorization"];
    NSURLSessionWebSocketTask *t = [session webSocketTaskWithRequest:r];
    __weak NSURLSessionWebSocketTask *weak = t;
    delegate.onWebSocketClose = ^{ NSURLSessionWebSocketTask *x = weak; if (x) [self closeWebSocket:x]; };
    @synchronized(self) { _ws = t; _wsSession = session; }
    [t resume];
    [self receiveLoop:t]; // incoming frames are ignored, but reading is how a closed socket is noticed
}

- (void)receiveLoop:(NSURLSessionWebSocketTask *)t {
    [t receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *error) {
        if (error) { [self closeWebSocket:t]; return; }
        [self receiveLoop:t];
    }];
}

- (void)closeWebSocket:(NSURLSessionWebSocketTask *)t {
    NSURLSession *s = nil;
    @synchronized(self) { if (_ws == t) { _ws = nil; s = _wsSession; _wsSession = nil; } }
    [t cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
    [s invalidateAndCancel];
}

- (void)close {
    NSURLSessionWebSocketTask *t; @synchronized(self) { t = _ws; }
    if (t) [self closeWebSocket:t];
    @synchronized(self) { _closed = YES; }
    [_usbSession invalidateAndCancel];
    @synchronized(self) { for (NSURLSession *s in _wifiSessions.allValues) [s invalidateAndCancel]; }
}

@end
