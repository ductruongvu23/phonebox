// PhoneBoxSB: loaded into SpringBoard (ElleKit). Plain Objective-C runtime swizzling, no Logos, so it also builds
// without Theos. Every hook is optional: a class or selector that does not exist on this iOS is skipped and logged
// ("PhoneBoxSB: ..." in the device log), and PhoneBox still works without any of it.
//
//   volume keys   -> Darwin notification key.prev / key.next (the app flips pages), no volume change, no HUD
//   Home button   -> notification back (kiosk: the panel returns to its first page), or opens PhoneBox (home-screen mode)
//   cmd.wake/sleep/open (from phoneboxd) -> screen on + unlock, lock, launch PhoneBox
//
// What the hooks do is switched by the app through flag bits (see PBFlags.h), read here as Darwin notification state.
#pragma clang diagnostic ignored "-Warc-performSelector-leaks" // +sharedInstance of singletons
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#import <QuartzCore/QuartzCore.h>
#import "PBFlags.h"

static NSString *const kBundleID = @"com.ductruongvu23.phonebox";
static NSString *const kCmdWake = @"com.ductruongvu23.phonebox.cmd.wake";
static NSString *const kCmdSleep = @"com.ductruongvu23.phonebox.cmd.sleep";
static NSString *const kCmdOpen = @"com.ductruongvu23.phonebox.cmd.open";

static BOOL PBHas(PBFlag f) { return (PBNotifyState(PBFlagsNotification) & f) != 0; }
static void PBPost(NSString *n) { notify_post(n.UTF8String); }

/// Replaces a no-argument void method: [handle] returns YES when it took the event (the original is then not called).
static void PBHook(const char *cls, const char *sel, BOOL (^handle)(id self)) {
    Class c = objc_getClass(cls);
    SEL s = sel_registerName(sel);
    Method m = c ? class_getInstanceMethod(c, s) : NULL;
    if (!m) { NSLog(@"PhoneBoxSB: no -[%s %s] on this iOS, skipped", cls, sel); return; }
    IMP orig = method_getImplementation(m);
    IMP repl = imp_implementationWithBlock(^(id self) {
        if (handle(self)) return;
        ((void (*)(id, SEL))orig)(self, s);
    });
    class_replaceMethod(c, s, repl, method_getTypeEncoding(m)); // on the class itself, not its superclass
    NSLog(@"PhoneBoxSB: hooked -[%s %s]", cls, sel);
}

static void PBOpenApp(void) {
    static int (*launch)(CFStringRef, Boolean);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        launch = h ? dlsym(h, "SBSLaunchApplicationWithIdentifier") : NULL;
    });
    if (launch) launch((__bridge CFStringRef)kBundleID, false);
    else NSLog(@"PhoneBoxSB: SBSLaunchApplicationWithIdentifier is missing");
}

/// Calls a selector if the object has it; returns whether it did. Every private call goes through here so a method that
/// does not exist on this iOS is skipped (and logged) instead of crashing SpringBoard.
static BOOL PBCall(id obj, const char *sel, int nargs, long long a, id b) {
    SEL s = sel_registerName(sel);
    if (!obj || ![obj respondsToSelector:s]) return NO;
    if (nargs == 0) ((void (*)(id, SEL))objc_msgSend)(obj, s);
    else if (nargs == 1) ((void (*)(id, SEL, long long))objc_msgSend)(obj, s, a);
    else ((void (*)(id, SEL, long long, id))objc_msgSend)(obj, s, a, b);
    return YES;
}

static void PBWake(void) {
    id bl = [objc_getClass("SBBacklightController") performSelector:NSSelectorFromString(@"sharedInstance")];
    BOOL on = PBCall(bl, "turnOnScreenFullyWithBacklightSource:", 1, 1, nil);
    if (!on) NSLog(@"PhoneBoxSB: cannot turn the screen on (no SBBacklightController turnOnScreenFully...)");
    // A phone without a passcode only needs the lock screen dismissed. Which call does it depends on the iOS build, so the
    // ones that exist are tried in turn (a passcode phone stays locked: there is no secret to type here).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id lm = [objc_getClass("SBLockScreenManager") performSelector:NSSelectorFromString(@"sharedInstance")];
        BOOL did = PBCall(lm, "unlockUIFromSource:withOptions:", 2, 8, nil);
        if (!did) did = PBCall(lm, "attemptUnlockWithPasscode:", 2, 0, nil);
        if (!did) did = PBCall(lm, "unlockWithRequest:completion:", 2, 0, nil);
        if (!did) NSLog(@"PhoneBoxSB: no way to dismiss the lock screen on this iOS");
    });
}

static void PBSleep(void) {
    id lm = [objc_getClass("SBLockScreenManager") performSelector:NSSelectorFromString(@"sharedInstance")];
    SEL lock = NSSelectorFromString(@"lockUIFromSource:withOptions:");
    if ([lm respondsToSelector:lock]) ((void (*)(id, SEL, int, id))objc_msgSend)(lm, lock, 1, nil);
    else NSLog(@"PhoneBoxSB: cannot lock (no SBLockScreenManager lockUIFromSource:...)");
}

static void PBCommand(CFNotificationCenterRef c, void *o, CFStringRef name, const void *obj, CFDictionaryRef info) {
    NSString *n = (__bridge NSString *)name;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([n isEqualToString:kCmdWake]) PBWake();
        else if ([n isEqualToString:kCmdSleep]) PBSleep();
        else if ([n isEqualToString:kCmdOpen]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ PBOpenApp(); }); // after the unlock animation
    });
}

/// The Home button. Kiosk on and the panel in front: Home goes back to the first page. Home-screen mode: Home opens PhoneBox.
static BOOL PBHome(id self) {
    if (PBHas(PBFlagPinned) && PBHas(PBFlagForeground)) { PBPost(PBBackNotification); return YES; }
    if (PBHas(PBFlagHomeScreen) && !PBHas(PBFlagForeground)) { PBOpenApp(); return YES; }
    return NO;
}


#pragma mark Ambient light sensor (IOKit HID, private)

// The light sensor is an HID service (usage page 0xFF00, usage 4). Its events carry the level in field (type << 16).
typedef struct __IOHIDEventSystemClient *PBHIDClient;
typedef struct __IOHIDServiceClient *PBHIDService;
typedef struct __IOHIDEvent *PBHIDEvent;
typedef void (*PBHIDCallback)(void *target, void *refcon, void *sender, PBHIDEvent event);
static PBHIDClient (*pHIDCreate)(CFAllocatorRef);
static void (*pHIDSetMatching)(PBHIDClient, CFDictionaryRef);
static CFArrayRef (*pHIDCopyServices)(PBHIDClient);
static void (*pHIDSchedule)(PBHIDClient, CFRunLoopRef, CFStringRef);
static void (*pHIDRegister)(PBHIDClient, PBHIDCallback, void *, void *);
static int (*pHIDSetProperty)(PBHIDService, CFStringRef, CFTypeRef);
static int (*pHIDEventType)(PBHIDEvent);
static long long (*pHIDEventInt)(PBHIDEvent, int);
static double (*pHIDEventFloat)(PBHIDEvent, int);
static int gLuxToken = 0;
static double gLastLux = -1;
static CFTimeInterval gLastLuxAt = 0;

static void PBLightEvent(void *target, void *refcon, void *sender, PBHIDEvent event) {
    if (!event || pHIDEventType(event) != 12) return; // kIOHIDEventTypeAmbientLightSensor
    double lux = pHIDEventFloat ? pHIDEventFloat(event, 12 << 16) : (double)pHIDEventInt(event, 12 << 16);
    if (lux < 0 || lux > 200000) return;
    CFTimeInterval now = CACurrentMediaTime();
    // the panel wants a change that matters, not a stream: same rule as the Android shell
    BOOL jump = gLastLux < 0 || fabs(lux - gLastLux) > MAX(3.0, gLastLux * 0.15);
    if (!jump && now - gLastLuxAt < 10) return;
    if (now - gLastLuxAt < 0.7) return;
    gLastLux = lux; gLastLuxAt = now;
    if (!gLuxToken) notify_register_check(PBLuxNotification.UTF8String, &gLuxToken);
    notify_set_state(gLuxToken, PBLuxPresent | (uint64_t)(lux * 100));
    notify_post(PBLuxNotification.UTF8String);
}

static void PBStartLight(void) {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    if (!iokit) { NSLog(@"PhoneBoxSB: no IOKit"); return; }
    pHIDCreate = dlsym(iokit, "IOHIDEventSystemClientCreate");
    pHIDSetMatching = dlsym(iokit, "IOHIDEventSystemClientSetMatching");
    pHIDCopyServices = dlsym(iokit, "IOHIDEventSystemClientCopyServices");
    pHIDSchedule = dlsym(iokit, "IOHIDEventSystemClientScheduleWithRunLoop");
    pHIDRegister = dlsym(iokit, "IOHIDEventSystemClientRegisterEventCallback");
    pHIDSetProperty = dlsym(iokit, "IOHIDServiceClientSetProperty");
    pHIDEventType = dlsym(iokit, "IOHIDEventGetType");
    pHIDEventInt = dlsym(iokit, "IOHIDEventGetIntegerValue");
    pHIDEventFloat = dlsym(iokit, "IOHIDEventGetFloatValue");
    if (!pHIDCreate || !pHIDSetMatching || !pHIDCopyServices || !pHIDSchedule || !pHIDRegister || !pHIDEventType || !pHIDEventInt) {
        NSLog(@"PhoneBoxSB: IOHID symbols missing, no light sensor"); return;
    }
    static PBHIDClient client;
    client = pHIDCreate(kCFAllocatorDefault);
    pHIDSetMatching(client, (__bridge CFDictionaryRef)@{@"PrimaryUsagePage": @0xff00, @"PrimaryUsage": @4});
    CFArrayRef services = pHIDCopyServices(client);
    CFIndex n = services ? CFArrayGetCount(services) : 0;
    NSLog(@"PhoneBoxSB: %ld light sensor service(s)", (long)n);
    if (n == 0) { if (services) CFRelease(services); return; }
    if (pHIDSetProperty) for (CFIndex i = 0; i < n; i++)
        pHIDSetProperty((PBHIDService)CFArrayGetValueAtIndex(services, i), CFSTR("ReportInterval"), (__bridge CFTypeRef)@1000000);
    CFRelease(services);
    pHIDSchedule(client, CFRunLoopGetMain(), kCFRunLoopDefaultMode);
    pHIDRegister(client, PBLightEvent, NULL, NULL);
}

__attribute__((constructor)) static void PBInit(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
        NSLog(@"PhoneBoxSB: loaded");
        dispatch_async(dispatch_get_main_queue(), ^{ PBStartLight(); });

        // volume keys: the panel in front and "volume keys flip pages" on
        BOOL (^flip)(NSString *) = ^BOOL(NSString *which) {
            if (!(PBHas(PBFlagVolumeKeys) && PBHas(PBFlagForeground))) return NO;
            PBPost(which);
            return YES;
        };
        PBHook("SBVolumeControl", "increaseVolume", ^BOOL(id s) { return flip(PBKeyPrevNotification); });
        PBHook("SBVolumeControl", "decreaseVolume", ^BOOL(id s) { return flip(PBKeyNextNotification); });

        // Home button: the first of these that exists on this iOS (several are tried; a repeated "back" is harmless)
        PBHook("SBHomeHardwareButtonActions", "performSinglePressUpActions", ^BOOL(id s) { return PBHome(s); });
        PBHook("SBUIController", "clickedMenuButton", ^BOOL(id s) { return PBHome(s); });

        CFNotificationCenterRef dc = CFNotificationCenterGetDarwinNotifyCenter();
        for (NSString *n in @[kCmdWake, kCmdSleep, kCmdOpen])
            CFNotificationCenterAddObserver(dc, NULL, PBCommand, (__bridge CFStringRef)n, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
