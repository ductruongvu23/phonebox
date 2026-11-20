#import "PBPanelViewController.h"
#import "PBSchemeHandler.h"
#import "PBAgentStream.h"
#import "PBDictation.h"
#import <WebKit/WebKit.h>

@interface PBPanelViewController () <WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler>
@end

@implementation PBPanelViewController {
    PBAgentLink *_link;
    PBAgentStream *_stream;
    PBBridge *_bridge;
    WKWebView *_web;
    BOOL _active;
    NSString *_orientation; // landscape (default) | portrait | auto
    CGFloat _savedBrightness;
    BOOL _brightnessOverridden;
    double _wantedBrightness;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _orientation = @"landscape";
    _savedBrightness = UIScreen.mainScreen.brightness;

    _link = [PBAgentLink new];
    __weak PBPanelViewController *weak = self;
    _stream = [[PBAgentStream alloc] initWithLink:_link deliver:^(NSString *event, NSString *data) {
        NSString *js = [NSString stringWithFormat:@"window.onAgentStream && window.onAgentStream(%@, %@)", PBJSString(event), PBJSString(data)];
        dispatch_async(dispatch_get_main_queue(), ^{ [weak bridgeEvaluate:js]; });
    }];
    _bridge = [[PBBridge alloc] initWithLink:_link];
    _bridge.host = self;

    WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
    [cfg setURLSchemeHandler:[[PBSchemeHandler alloc] initWithLink:_link] forURLScheme:PBScheme];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    [cfg.userContentController addUserScript:[_bridge initialStateScript]];
    [cfg.userContentController addScriptMessageHandler:_bridge name:@"phonebox"];
    // Android sets textZoom = 100: the same here, or Safari enlarges text on its own in landscape.
    [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:
        @"(function(){var s=document.createElement('style');s.textContent='html{-webkit-text-size-adjust:100%}';(document.head||document.documentElement).appendChild(s)})()"
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
#ifdef DEBUG
    // Debug builds only: page errors with their stack go to the device log (the panel's own box only says "Script error.").
    [cfg.userContentController addUserScript:[[WKUserScript alloc] initWithSource:
        @"window.addEventListener('error',function(e){try{window.webkit.messageHandlers.pblog.postMessage(String(e.message)+' | '+(e.filename||'')+':'+e.lineno+':'+e.colno+' | '+((e.error&&e.error.stack)||'')+' | target='+(e.target&&e.target.tagName||''));}catch(_){} try{var d=String(e.message)+' @'+(e.filename||'?').split('/').pop()+':'+e.lineno+':'+e.colno+' '+((e.error&&e.error.stack)||'').split('\\n').slice(0,3).join(' < ');setTimeout(function(){window.__pbFail&&window.__pbFail('DBG '+d)},50)}catch(_){}},true);"
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    [cfg.userContentController addScriptMessageHandler:(id<WKScriptMessageHandler>)self name:@"pblog"];
#endif

    _web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    _web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _web.opaque = NO;
    _web.backgroundColor = UIColor.blackColor;
    _web.scrollView.backgroundColor = UIColor.blackColor;
    _web.scrollView.bounces = NO;
    _web.scrollView.scrollEnabled = NO;
    _web.scrollView.showsVerticalScrollIndicator = NO;
    _web.scrollView.showsHorizontalScrollIndicator = NO;
    _web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _web.navigationDelegate = self;
    _web.UIDelegate = self;
#ifdef DEBUG
    if (@available(iOS 16.4, *)) _web.inspectable = YES;
#endif
    [self.view addSubview:_web];
    [_web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:PBPanelURLString()]]];

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(didBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(willResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self didBecomeActive];
}

#pragma mark Lifecycle

- (void)didBecomeActive {
    _active = YES;
#ifdef DEBUG
    // Debug builds only (testing without a camera or Safari): a phonebox://pair link on the clipboard opens the pairing dialog.
    NSString *clip = UIPasteboard.generalPasteboard.string;
    if ([clip hasPrefix:@"phonebox://pair?"]) {
        PBPairLink *link = [PBPairLink parse:[NSURL URLWithString:clip]];
        UIPasteboard.generalPasteboard.string = @"";
        if (link) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self handlePairLink:link]; });
    }
#endif
    UIApplication.sharedApplication.idleTimerDisabled = YES; // the panel stays on
    [_stream start];
    [_bridge appDidBecomeActive];
    if (_brightnessOverridden) UIScreen.mainScreen.brightness = _wantedBrightness;
}

- (void)willResignActive {
    _active = NO;
    [_stream stop];
    [_bridge appWillResignActive];
    // brightness is system-wide on iOS: give it back whenever the app is not in front
    if (_brightnessOverridden) UIScreen.mainScreen.brightness = _savedBrightness;
    [self setProximity:NO];
}

#ifdef DEBUG
// Debug builds only: what the native side actually did, sent to the agent so a test can read it.
- (void)debugReport:(NSString *)what {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIInterfaceOrientation o = self.view.window.windowScene.interfaceOrientation;
        NSString *js = [NSString stringWithFormat:@"fetch('/agent/api/selftest',{method:'POST',headers:{'X-PhoneBox-Panel':'1'},body:JSON.stringify({what:'%@',brightness:%.3f,overridden:%d,orientation:%ld,bounds:'%@'})})", what, UIScreen.mainScreen.brightness, self->_brightnessOverridden, (long)o, NSStringFromCGRect(self.view.bounds)];
        [self->_web evaluateJavaScript:js completionHandler:nil];
    });
}
#endif

- (void)setProximity:(BOOL)on {
    if (!PBProximitySupported()) return;
    UIDevice *d = UIDevice.currentDevice;
    if (d.proximityMonitoringEnabled == on) return;
    d.proximityMonitoringEnabled = on;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    if (on) {
        [nc addObserver:self selector:@selector(proximityChanged) name:UIDeviceProximityStateDidChangeNotification object:nil];
        [self proximityChanged];
    } else {
        [nc removeObserver:self name:UIDeviceProximityStateDidChangeNotification object:nil];
    }
}

- (void)proximityChanged {
    [self bridgeEvaluate:[NSString stringWithFormat:@"window.onAndroidSensor && window.onAndroidSensor('proximity', %@)", UIDevice.currentDevice.proximityState ? @"true" : @"false"]];
}

#pragma mark PBBridgeHost

- (void)bridgeEvaluate:(NSString *)script {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self bridgeEvaluate:script]; }); return; }
    [_web evaluateJavaScript:script completionHandler:nil];
}

- (void)bridgeReloadPanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_stream stop];
        if (self->_active) [self->_stream start];
        [self->_web reload];
    });
}

- (void)bridgeSetBrightness:(double)value {
    dispatch_async(dispatch_get_main_queue(), ^{
        // A hand near the phone wakes the night screen (onAndroidSensor 'proximity'). iOS blanks the display while its proximity
        // sensor is covered, so the sensor is only on while the panel is dimmed, never in the daytime.
        [self setProximity:(value >= 0 && value <= 0.1)];
        if (value < 0) {
            if (self->_brightnessOverridden) UIScreen.mainScreen.brightness = self->_savedBrightness;
            self->_brightnessOverridden = NO;
#ifdef DEBUG
            [self debugReport:@"setBrightness(-1)"];
#endif
            return;
        }
        if (!self->_brightnessOverridden) self->_savedBrightness = UIScreen.mainScreen.brightness;
        self->_brightnessOverridden = YES;
        self->_wantedBrightness = MIN(1.0, MAX(0.01, value));
        UIScreen.mainScreen.brightness = self->_wantedBrightness;
#ifdef DEBUG
        [self debugReport:[NSString stringWithFormat:@"setBrightness(%.2f)", value]];
#endif
    });
}

- (void)bridgeSetOrientation:(NSString *)mode {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *m = [mode isEqualToString:@"portrait"] || [mode isEqualToString:@"auto"] ? mode : @"landscape";
        if ([m isEqualToString:self->_orientation]) return;
        self->_orientation = m;
        [self applyOrientation];
#ifdef DEBUG
        [self debugReport:[NSString stringWithFormat:@"setOrientation(%@)", m]];
#endif
    });
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if ([_orientation isEqualToString:@"portrait"]) return UIInterfaceOrientationMaskPortrait;
    if ([_orientation isEqualToString:@"auto"]) return UIInterfaceOrientationMaskAllButUpsideDown;
    return UIInterfaceOrientationMaskLandscape;
}

- (void)applyOrientation {
    UIInterfaceOrientationMask mask = [self supportedInterfaceOrientations];
    UIInterfaceOrientation now = self.view.window.windowScene.interfaceOrientation;
    if (mask & (1 << now)) { [UIViewController attemptRotationToDeviceOrientation]; return; }
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *p = [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
        [self.view.window.windowScene requestGeometryUpdateWithPreferences:p errorHandler:nil];
    } else {
        UIDeviceOrientation want = (mask & UIInterfaceOrientationMaskPortrait) ? UIDeviceOrientationPortrait : UIDeviceOrientationLandscapeLeft;
        [UIDevice.currentDevice setValue:@(want) forKey:@"orientation"];
    }
    if (@available(iOS 16.0, *)) [self setNeedsUpdateOfSupportedInterfaceOrientations];
    [UIViewController attemptRotationToDeviceOrientation];
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleLightContent; }

#pragma mark Pairing

- (void)handlePairLink:(PBPairLink *)pairing {
    if (!pairing) return;
    NSString *msg = [NSString stringWithFormat:PBL(@"pair_message"), pairing.pc, [pairing.hosts componentsJoinedByString:@", "], pairing.port, pairing.check];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:PBL(@"pair_title") message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:PBL(@"pair_negative") style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:PBL(@"pair_positive") style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self pair:pairing]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pair:(PBPairLink *)pairing {
    [self toast:[NSString stringWithFormat:PBL(@"pair_progress"), pairing.pc]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        PBPairFailure *problem = [self->_link claim:pairing];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a;
            if (!problem) {
                a = [UIAlertController alertControllerWithTitle:nil message:[NSString stringWithFormat:PBL(@"pair_done"), pairing.pc] preferredStyle:UIAlertControllerStyleAlert];
                [self bridgeReloadPanel];
            } else {
                a = [UIAlertController alertControllerWithTitle:PBL(@"pair_failed_title") message:problem.message preferredStyle:UIAlertControllerStyleAlert];
            }
            [a addAction:[UIAlertAction actionWithTitle:PBL(@"ok") style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    NSLog(@"PBWEB %@ (main=%d)", message.body, message.frameInfo.isMainFrame);
}

/// A short message at the bottom (Android's Toast).
- (void)toast:(NSString *)text {
    UILabel *l = [UILabel new];
    l.text = [NSString stringWithFormat:@"  %@  ", text];
    l.textColor = UIColor.whiteColor; l.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.95];
    l.font = [UIFont systemFontOfSize:14]; l.layer.cornerRadius = 14; l.clipsToBounds = YES; l.numberOfLines = 2;
    [l sizeToFit];
    CGFloat w = MIN(l.bounds.size.width + 8, self.view.bounds.size.width - 40);
    l.frame = CGRectMake((self.view.bounds.size.width - w) / 2, self.view.bounds.size.height - 70, w, 32);
    l.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:l];
    [UIView animateWithDuration:0.3 delay:2.5 options:0 animations:^{ l.alpha = 0; } completion:^(BOOL f) { [l removeFromSuperview]; }];
}

#pragma mark WKNavigationDelegate / WKUIDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    // the panel never leaves its own origin; an external link is dropped, not opened in the kiosk
    NSURL *u = action.request.URL;
    BOOL own = [u.scheme isEqualToString:PBScheme] || [u.scheme isEqualToString:@"about"] || [u.scheme isEqualToString:@"blob"] || [u.scheme isEqualToString:@"data"];
    // The Web widget shows a page in an iframe: sub-frames may load https (the Android WebView allows it too). Only the
    // top-level page is held to the panel's own origin, so a link cannot replace the kiosk with a website.
    BOOL subframe = action.targetFrame != nil && !action.targetFrame.isMainFrame && [u.scheme isEqualToString:@"https"];
    handler(own || subframe ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

#ifdef DEBUG
// Debug builds only: PB_SELFTEST=1 runs a few checks from inside the panel (scheme handler POST body, the panel header
// rule, window.Android, a sandboxed iframe) and reports them to the agent at /api/selftest-result.
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (!getenv("PB_SELFTEST")) return;
    NSString *js = @"(async()=>{const r={};const H={'X-PhoneBox-Panel':'1'};"
    "try{const x=await fetch('/agent/api/selftest-post',{method:'POST',headers:Object.assign({'Content-Type':'application/json'},H),body:JSON.stringify({hello:'body'})});r.postStatus=x.status;}catch(e){r.postErr=String(e)}"
    "try{const x=await fetch('/agent/api/state');r.noHeaderStatus=x.status;}catch(e){r.noHeaderErr=String(e)}"
    "r.android=typeof window.Android;r.battery=window.Android&&Android.battery();r.version=Android.version();r.canListen=Android.canListen();r.transport=Android.transport();r.pcs=Android.pcs();"
    "const f=document.createElement('iframe');f.sandbox='allow-scripts';"
    "f.srcdoc='<script>var o={android:typeof window.Android,state:typeof window.__pbNative};try{window.webkit.messageHandlers.phonebox.postMessage({m:\\\"haptic\\\",a:[]});o.posted=true}catch(e){o.postErr=1}"
    "fetch(\\\"/agent/api/state\\\",{headers:{\\\"X-PhoneBox-Panel\\\":\\\"1\\\"}}).then(x=>o.fetch=x.status).catch(e=>o.fetch=\\\"blocked\\\").finally(()=>parent.postMessage(o,\\\"*\\\"))<\\/script>';"
    "window.addEventListener('message',async e=>{r.iframe=e.data;await fetch('/agent/api/selftest-result',{method:'POST',headers:H,body:JSON.stringify(r)});});"
    "document.body.appendChild(f);})()";
    [webView evaluateJavaScript:js completionHandler:nil];
}
#endif

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { [webView reload]; } // iOS kills the web process under memory pressure

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_stream stop];
    [_bridge teardown];
    [_link close];
}

@end
