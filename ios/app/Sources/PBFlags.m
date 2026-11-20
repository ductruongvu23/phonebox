#import "PBFlags.h"
#import <notify.h>

NSString *const PBFlagsNotification = @"com.ductruongvu23.phonebox.flags";
NSString *const PBKeyPrevNotification = @"com.ductruongvu23.phonebox.key.prev";
NSString *const PBKeyNextNotification = @"com.ductruongvu23.phonebox.key.next";
NSString *const PBBackNotification = @"com.ductruongvu23.phonebox.back";
NSString *const PBLuxNotification = @"com.ductruongvu23.phonebox.lux";

static uint64_t gFlags = PBFlagVolumeKeys; // the panel's default: volume keys flip pages
static int gToken = 0;
static dispatch_once_t gOnce;

static void PBPublish(void) {
    dispatch_once(&gOnce, ^{ notify_register_check(PBFlagsNotification.UTF8String, &gToken); });
    notify_set_state(gToken, gFlags);
    notify_post(PBFlagsNotification.UTF8String);
}

void PBFlagsSet(PBFlag flag, BOOL on) {
    @synchronized([NSBundle class]) {
        uint64_t before = gFlags;
        if (on) gFlags |= flag; else gFlags &= ~(uint64_t)flag;
        if (gFlags == before && gOnce) return;
    }
    PBPublish();
}

uint64_t PBFlagsGet(void) { return gFlags; }

uint64_t PBNotifyState(NSString *name) {
    int t = 0; uint64_t s = 0;
    if (notify_register_check(name.UTF8String, &t) != NOTIFY_STATUS_OK) return 0;
    notify_get_state(t, &s);
    notify_cancel(t);
    return s;
}
