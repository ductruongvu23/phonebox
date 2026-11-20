#import "PBBridge.h"
#import "PBSchemeHandler.h"
#import "PBDictation.h"
#import "PBFlags.h"
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Speech/Speech.h>

@implementation PBBridge {
    PBAgentLink *_link;
    PBDictation *_dictation;
    NSSet<NSString *> *_trackpadTypes;
    BOOL _observing;
}

- (instancetype)initWithLink:(PBAgentLink *)link {
    if ((self = [super init])) {
        _link = link;
        _trackpadTypes = [NSSet setWithArray:@[@"move", @"click", @"rightClick", @"mousedown", @"mouseup", @"scroll", @"hscroll"]];
        __weak PBBridge *weak = self;
        _dictation = [[PBDictation alloc] initWithScript:^(NSString *js) { [weak.host bridgeEvaluate:js]; }];
        UIDevice.currentDevice.batteryMonitoringEnabled = YES;
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        for (NSNotificationName n in @[UIDeviceBatteryLevelDidChangeNotification, UIDeviceBatteryStateDidChangeNotification, NSCurrentLocaleDidChangeNotification])
            [nc addObserver:self selector:@selector(pushState) name:n object:nil];
        void (^changed)(void) = ^{ [weak pushState]; };
        _link.onChange = changed;
        [self observeDarwin];
    }
    return self;
}

- (void)teardown {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
    [_dictation cancel:0];
    _link.onChange = nil;
}

#pragma mark State the panel reads synchronously

BOOL PBProximitySupported(void) {
    static BOOL known, supported;
    if (!known) {
        UIDevice *d = UIDevice.currentDevice;
        BOOL was = d.proximityMonitoringEnabled;
        d.proximityMonitoringEnabled = YES;
        supported = d.proximityMonitoringEnabled; // stays NO on a device without the sensor (and in the Simulator)
        d.proximityMonitoringEnabled = was;
        known = YES;
    }
    return supported;
}

static BOOL PBIs24Hour(void) {
    NSString *f = [NSDateFormatter dateFormatFromTemplate:@"j" options:0 locale:NSLocale.currentLocale] ?: @"";
    return [f rangeOfString:@"a"].location == NSNotFound;
}

- (NSDictionary *)state {
    UIDevice *d = UIDevice.currentDevice;
    float level = d.batteryLevel; // -1 when unknown (simulator)
    BOOL plugged = d.batteryState == UIDeviceBatteryStateCharging || d.batteryState == UIDeviceBatteryStateFull;
    return @{
        @"battery": @{@"level": @(level < 0 ? -1 : (int)lroundf(level * 100)), @"plugged": @(plugged), @"temp": @0, @"source": @"", @"usb": NSNull.null},
        @"transport": PBRouteName(_link.route),
        @"is24Hour": @(PBIs24Hour()),
        @"sensors": @{@"light": @((PBNotifyState(PBLuxNotification) & PBLuxPresent) != 0), @"proximity": @(PBProximitySupported())}, // light: only with the SpringBoard tweak
        @"pcs": [NSJSONSerialization JSONObjectWithData:[_link.pcsJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] ?: @[],
        @"version": _link.appVersion ?: @"",
        @"canListen": @(_dictation.available),
    };
}

- (NSString *)stateJSON {
    return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:self.state options:0 error:nil] encoding:NSUTF8StringEncoding];
}

- (WKUserScript *)initialStateScript {
    NSString *src = [NSString stringWithFormat:@"window.__pbNative = %@;", self.stateJSON];
    // main frame only: widget iframes never see the state, and the native side checks the sender again
    return [[WKUserScript alloc] initWithSource:src injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
}

- (void)pushState {
    NSString *js = [NSString stringWithFormat:@"window.__pbNative = Object.assign(window.__pbNative || {}, %@);", self.stateJSON];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.host bridgeEvaluate:js]; });
}

- (void)appDidBecomeActive {
    PBFlagsSet(PBFlagForeground, YES);
    [self pushState];
    [self.host bridgeEvaluate:@"window.onAppPause && window.onAppPause(false)"]; // the panel catches up at once
}

- (void)appWillResignActive {
    PBFlagsSet(PBFlagForeground, NO);
    [_dictation cancel:0]; // the microphone is never left open behind another app or a dark screen
    [self.host bridgeEvaluate:@"window.onAppPause && window.onAppPause(true)"];
}

#pragma mark Messages from the panel

static BOOL PBNum(id v) { return [v isKindOfClass:NSNumber.class] && isfinite([v doubleValue]); }
static BOOL PBStr(id v) { return [v isKindOfClass:NSString.class]; }

- (void)userContentController:(WKUserContentController *)ucc didReceiveScriptMessage:(WKScriptMessage *)message {
    // window.webkit.messageHandlers exists in every frame, so check who is asking
    NSURL *u = message.frameInfo.request.URL;
    if (!message.frameInfo.isMainFrame || ![u.scheme isEqualToString:PBScheme] || ![u.host isEqualToString:PBHost]) return;
    NSDictionary *b = message.body;
    if (![b isKindOfClass:NSDictionary.class] || !PBStr(b[@"m"])) return;
    NSString *m = b[@"m"];
    NSArray *a = [b[@"a"] isKindOfClass:NSArray.class] ? b[@"a"] : @[];

    if ([m isEqualToString:@"trackpad"]) {
        if (a.count < 4 || !PBStr(a[0]) || ![_trackpadTypes containsObject:a[0]] || !PBNum(a[1]) || !PBNum(a[2]) || !PBNum(a[3])) return;
        [_link sendTrackpad:a[0] dx:[a[1] doubleValue] dy:[a[2] doubleValue] delta:[a[3] doubleValue]];
    } else if ([m isEqualToString:@"setBrightness"]) {
        if (a.count < 1 || !PBNum(a[0])) return;
        [self.host bridgeSetBrightness:[a[0] doubleValue]];
    } else if ([m isEqualToString:@"haptic"]) {
        AudioServicesPlaySystemSound(1519); // "peek": a short tap; the 6s has no Taptic Engine for UIFeedbackGenerator
    } else if ([m isEqualToString:@"buzz"]) {
        if (a.count < 1 || !PBStr(a[0])) return;
        [self buzz:a[0]];
    } else if ([m isEqualToString:@"setOrientation"]) {
        if (a.count < 1 || !PBStr(a[0])) return;
        [self.host bridgeSetOrientation:a[0]];
    } else if ([m isEqualToString:@"selectPc"]) {
        if (a.count < 1 || !PBStr(a[0])) return;
        if ([_link selectPc:a[0]]) [self.host bridgeReloadPanel];
    } else if ([m isEqualToString:@"forgetPc"]) {
        if (a.count < 1 || !PBStr(a[0])) return;
        [_link forgetPc:a[0]];
    } else if ([m isEqualToString:@"setVolumeKeys"] || [m isEqualToString:@"setPinned"] || [m isEqualToString:@"setHomeScreen"]) {
        if (a.count < 1 || !PBNum(a[0])) return;
        PBFlag f = [m isEqualToString:@"setVolumeKeys"] ? PBFlagVolumeKeys : [m isEqualToString:@"setPinned"] ? PBFlagPinned : PBFlagHomeScreen;
        PBFlagsSet(f, [a[0] boolValue]); // the SpringBoard tweak acts on these; without it they change nothing
    } else if ([m isEqualToString:@"listen"]) {
        if (a.count < 3 || !PBStr(a[0]) || !PBNum(a[1]) || !PBNum(a[2]) || [a[2] integerValue] <= 0) return;
        NSMutableString *lang = [NSMutableString string];
        for (NSUInteger i = 0; i < [a[0] length] && lang.length < 20; i++) {
            unichar c = [a[0] characterAtIndex:i];
            if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:c] || c == '-') [lang appendFormat:@"%C", c];
        }
        [_dictation startWithLanguage:lang offline:[a[1] boolValue] id:[a[2] integerValue]];
    } else if ([m isEqualToString:@"stopListening"]) {
        if (a.count >= 1 && PBNum(a[0]) && [a[0] integerValue] > 0) [_dictation stop:[a[0] integerValue]];
    } else if ([m isEqualToString:@"cancelListening"]) {
        if (a.count >= 1 && PBNum(a[0]) && [a[0] integerValue] > 0) [_dictation cancel:[a[0] integerValue]];
    }
}

/// "wait,vibrate,wait,vibrate..." in milliseconds. iOS cannot set the length of a vibration, so each vibrate entry
/// is one pulse at the time it would start.
- (void)buzz:(NSString *)pattern {
    NSMutableArray<NSNumber *> *t = [NSMutableArray array];
    for (NSString *p in [pattern componentsSeparatedByString:@","]) {
        NSString *s = [p stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSScanner *sc = [NSScanner scannerWithString:s]; long long v;
        if ([sc scanLongLong:&v] && sc.isAtEnd && v >= 0 && v < 5000) [t addObject:@(v)]; // a bad entry is skipped, like toLongOrNull
    }
    if (!t.count || t.count > 40) return;
    double at = 0;
    for (NSUInteger i = 0; i < t.count; i++) {
        double len = t[i].doubleValue;
        if (i % 2 == 1 && len > 0) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{ AudioServicesPlaySystemSound(kSystemSoundID_Vibrate); });
        }
        at += len;
    }
}

#pragma mark From the SpringBoard tweak

static void PBDarwinCallback(CFNotificationCenterRef c, void *observer, CFStringRef name, const void *obj, CFDictionaryRef info) {
    PBBridge *self = (__bridge PBBridge *)observer;
    NSString *n = (__bridge NSString *)name;
    dispatch_async(dispatch_get_main_queue(), ^{ [self darwin:n]; });
}

- (void)observeDarwin {
    CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
    for (NSString *n in @[PBKeyPrevNotification, PBKeyNextNotification, PBBackNotification, PBLuxNotification])
        CFNotificationCenterAddObserver(c, (__bridge const void *)self, PBDarwinCallback, (__bridge CFStringRef)n, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)darwin:(NSString *)name {
    if ([name isEqualToString:PBKeyPrevNotification]) [self.host bridgeEvaluate:@"window.onAndroidKey && window.onAndroidKey('prev')"];
    else if ([name isEqualToString:PBKeyNextNotification]) [self.host bridgeEvaluate:@"window.onAndroidKey && window.onAndroidKey('next')"];
    else if ([name isEqualToString:PBBackNotification]) [self.host bridgeEvaluate:@"window.onAndroidBack && window.onAndroidBack()"];
    else if ([name isEqualToString:PBLuxNotification]) {
        uint64_t raw = PBNotifyState(PBLuxNotification);
        double lux = (raw & PBLuxMask) / 100.0;
#ifdef DEBUG
        [self.host bridgeEvaluate:[NSString stringWithFormat:@"fetch('/agent/api/selftest',{method:'POST',headers:{'X-PhoneBox-Panel':'1'},body:JSON.stringify({what:'lux-notification',raw:'%llu',lux:%g})})", raw, lux]];
#endif
        [self.host bridgeEvaluate:[NSString stringWithFormat:@"window.__pbNative && window.__pbNative.sensors && (window.__pbNative.sensors.light = true); window.onAndroidSensor && window.onAndroidSensor('light', %g)", lux]];
    }
}

@end
