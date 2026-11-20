#import "PBSchemeHandler.h"

NSString *const PBScheme = @"phonebox-app";
NSString *const PBHost = @"panel";
NSString *PBPanelURLString(void) { return @"phonebox-app://panel/assets/www/index.html"; }

static NSString *const kPanelHeader = @"X-PhoneBox-Panel";

/// Images (album art, process icons) cannot carry headers, but they are read-only GETs.
static NSSet<NSString *> *PBReadOnlyImages(void) {
    static NSSet *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [NSSet setWithArray:@[@"/agent/api/art", @"/agent/api/procs/icon", @"/agent/api/controls/radio-logo",
                                  @"/agent/api/apps/icon", @"/agent/api/discord/img", @"/agent/api/shortcuts/icon"]];
    });
    return s;
}

static NSString *PBMime(NSString *ext) {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{@"html": @"text/html", @"js": @"text/javascript", @"mjs": @"text/javascript", // ES modules need a JavaScript type
              @"css": @"text/css", @"json": @"application/json", @"svg": @"image/svg+xml", @"png": @"image/png",
              @"jpg": @"image/jpeg", @"jpeg": @"image/jpeg", @"gif": @"image/gif", @"webp": @"image/webp",
              @"ico": @"image/x-icon", @"woff": @"font/woff", @"woff2": @"font/woff2", @"ttf": @"font/ttf",
              @"txt": @"text/plain", @"map": @"application/json", @"wasm": @"application/wasm"};
    });
    return m[ext.lowercaseString] ?: @"application/octet-stream";
}

@implementation PBSchemeHandler {
    PBAgentLink *_link;
    NSMutableSet *_active; // tasks WebKit has not stopped; answering a stopped task raises an exception
    NSLock *_lock;
    dispatch_queue_t _queue;
}

- (instancetype)initWithLink:(PBAgentLink *)link {
    if ((self = [super init])) {
        _link = link;
        _active = [NSMutableSet set];
        _lock = [NSLock new];
        _queue = dispatch_queue_create("phonebox.scheme", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    [_lock lock]; [_active addObject:task]; [_lock unlock];
    dispatch_async(_queue, ^{ [self handle:task]; });
}

- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {
    [_lock lock]; [_active removeObject:task]; [_lock unlock];
}

- (void)finish:(id<WKURLSchemeTask>)task status:(NSInteger)status type:(NSString *)type body:(NSData *)body {
    [_lock lock];
    BOOL live = [_active containsObject:task];
    if (live) [_active removeObject:task];
    [_lock unlock];
    if (!live) return;
    NSMutableDictionary *h = [@{@"Cache-Control": @"no-store", @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)body.length]} mutableCopy];
    if (type) h[@"Content-Type"] = type;
    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc] initWithURL:task.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:h];
    @try {
        [task didReceiveResponse:resp];
        if (body.length) [task didReceiveData:body];
        [task didFinish];
    } @catch (NSException *e) { /* stopped between the check and the call */ }
}

- (BOOL)fromPanel:(NSURLRequest *)req {
    for (NSString *k in req.allHTTPHeaderFields) if ([k caseInsensitiveCompare:kPanelHeader] == NSOrderedSame) return YES;
    return [req.HTTPMethod isEqualToString:@"GET"] && [PBReadOnlyImages() containsObject:req.URL.path];
}

- (void)handle:(id<WKURLSchemeTask>)task {
    NSURLRequest *req = task.request;
    NSURL *url = req.URL;
    NSString *path = url.path ?: @"";
    if (![url.host isEqualToString:PBHost]) { [self finish:task status:404 type:@"text/plain" body:nil]; return; }

    if ([path hasPrefix:@"/agent/"]) {
        // Every frame comes through here, including the sandboxed iframe of a Custom HTML widget: only the panel's own
        // requests carry the header (a sandboxed frame cannot add it without a CORS preflight, which is refused).
        if (![self fromPanel:req]) { [self finish:task status:403 type:@"text/plain" body:nil]; return; }
        NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *rest = [c.percentEncodedPath substringFromIndex:@"/agent".length];
        if (c.percentEncodedQuery) rest = [rest stringByAppendingFormat:@"?%@", c.percentEncodedQuery];
        NSData *body = req.HTTPBody;
        if (!body && req.HTTPBodyStream) {
            NSMutableData *d = [NSMutableData data];
            NSInputStream *in = req.HTTPBodyStream;
            [in open];
            uint8_t buf[4096]; NSInteger n;
            while ((n = [in read:buf maxLength:sizeof buf]) > 0) [d appendBytes:buf length:n];
            [in close];
            body = d;
        }
        PBReply *r = [_link request:req.HTTPMethod path:rest body:body contentType:[req valueForHTTPHeaderField:@"Content-Type"]];
        NSInteger status = (r.code >= 100 && r.code <= 599 && !(r.code >= 300 && r.code < 400)) ? r.code : 502;
        [self finish:task status:status type:r.contentType ?: @"application/octet-stream" body:r.body];
        return;
    }

    if ([path hasPrefix:@"/assets/www/"]) {
        NSString *rel = [[path substringFromIndex:@"/assets/www/".length] stringByRemovingPercentEncoding];
        if (!rel.length) rel = @"index.html";
        for (NSString *part in [rel componentsSeparatedByString:@"/"]) {
            if ([part isEqualToString:@".."] || [part isEqualToString:@"."] || [part containsString:@"\\"]) { [self finish:task status:404 type:@"text/plain" body:nil]; return; }
        }
        NSString *file = [[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"www"] stringByAppendingPathComponent:rel];
        NSData *data = [NSData dataWithContentsOfFile:file];
        if (!data) { [self finish:task status:404 type:@"text/plain" body:nil]; return; }
        [self finish:task status:200 type:PBMime(file.pathExtension) body:data];
        return;
    }
    [self finish:task status:404 type:@"text/plain" body:nil];
}

@end
