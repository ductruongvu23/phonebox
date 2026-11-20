#import <Foundation/Foundation.h>

/// State shared with the SpringBoard tweak, which lives in another process and sandbox. The app publishes a bit
/// mask as a Darwin notification state (readable with notify_get_state) and posts the notification; the tweak posts
/// the notifications below back (key presses, back, light level). Both sides work without the other.
FOUNDATION_EXPORT NSString *const PBFlagsNotification;   // state: bit mask of PBFlag*
FOUNDATION_EXPORT NSString *const PBKeyPrevNotification;  // volume up
FOUNDATION_EXPORT NSString *const PBKeyNextNotification;  // volume down
FOUNDATION_EXPORT NSString *const PBBackNotification;     // Home button while kiosk is on
FOUNDATION_EXPORT NSString *const PBLuxNotification;      // state: bit 62 = a light sensor exists, low bits = lux * 100
FOUNDATION_EXPORT const uint64_t PBLuxPresent;            // 1 << 62
FOUNDATION_EXPORT const uint64_t PBLuxMask;               // the low bits

typedef NS_OPTIONS(uint64_t, PBFlag) {
    PBFlagVolumeKeys = 1 << 0, // volume keys flip pages
    PBFlagPinned     = 1 << 1, // kiosk: Home returns to the first page instead of leaving
    PBFlagHomeScreen = 1 << 2, // reopen PhoneBox when it is closed
    PBFlagForeground = 1 << 3, // PhoneBox is the active app
};

FOUNDATION_EXPORT void PBFlagsSet(PBFlag flag, BOOL on);
FOUNDATION_EXPORT uint64_t PBFlagsGet(void);
FOUNDATION_EXPORT uint64_t PBNotifyState(NSString *name);
