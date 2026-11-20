#import "PBPanelViewController.h"
#import "PBSchemeHandler.h"
#import "PBAgentStream.h"
#import "PBDictation.h"
#import <WebKit/WebKit.h>

@interface PBPanelViewController () <WKNavigationDelegate, WKUIDelegate>
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
        if (value < 0) {
            if (self->_brightnessOverridden) UIScreen.mainScreen.brightness = self->_savedBrightness;
            self->_brightnessOverridden = NO;
            return;
        }
        if (!self->_brightnessOverridden) self->_savedBrightness = UIScreen.mainScreen.brightness;
        self->_brightnessOverridden = YES;
        self->_wantedBrightness = MIN(1.0, MAX(0.01, value));
        UIScreen.mainScreen.brightness = self->_wantedBrightness;
    });
}

- (void)bridgeSetOrientation:(NSString *)mode {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *m = [mode isEqualToString:@"portrait"] || [mode isEqualToString:@"auto"] ? mode : @"landscape";
        if ([m isEqualToString:self->_orientation]) return;
        self->_orientation = m;
        [self applyOrientation];
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
    NSString *msg = [NSString stringWithFormat:@"Pair this phone with %@?\n\nAddresses: %@\nPort: %d\n\nThe computer shows the code %@ next to the QR code. Only pair if they match.",
                     pairing.pc, [pairing.hosts componentsJoinedByString:@", "], pairing.port, pairing.check];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Pair with a computer" message:msg preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Pair" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { [self pair:pairing]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pair:(PBPairLink *)pairing {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        PBPairFailure *problem = [self->_link claim:pairing];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a;
            if (!problem) {
                a = [UIAlertController alertControllerWithTitle:@"Paired" message:[NSString stringWithFormat:@"%@ is paired. The panel reloads over Wi-Fi.", pairing.pc] preferredStyle:UIAlertControllerStyleAlert];
                [self bridgeReloadPanel];
            } else {
                a = [UIAlertController alertControllerWithTitle:@"Pairing failed" message:problem.message preferredStyle:UIAlertControllerStyleAlert];
            }
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:a animated:YES completion:nil];
        });
    });
}

#pragma mark WKNavigationDelegate / WKUIDelegate

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    // the panel never leaves its own origin; an external link is dropped, not opened in the kiosk
    NSURL *u = action.request.URL;
    BOOL own = [u.scheme isEqualToString:PBScheme] || [u.scheme isEqualToString:@"about"] || [u.scheme isEqualToString:@"blob"] || [u.scheme isEqualToString:@"data"];
    handler(own ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
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
