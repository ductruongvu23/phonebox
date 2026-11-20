#import <Foundation/Foundation.h>

/// The iPhone end of the USB tunnel (the counterpart of IosUsb.cs on the PC). iOS has no "adb reverse", and usbmuxd only
/// lets the PC connect INTO the phone, so the PC keeps a few idle connections open to 127.0.0.1:8767 here. When the app
/// connects to 127.0.0.1:8765, its bytes are spliced onto one of them, and the PC pipes that to the agent.
///
/// Both ports are bound to loopback only (usbmuxd arrives from loopback), so nothing on the network can reach them.
/// 8765 is only open while an idle PC connection exists: with no cable, a connection to it is refused at once, exactly
/// like a missing "adb reverse" rule, and the app's link falls back to Wi-Fi without trying a POST on a dead tunnel.
/// If another process (phoneboxd) already owns the ports, start is a no-op.
@interface PBUsbListener : NSObject
+ (instancetype)shared;
- (void)start;
- (void)stop;
@end

FOUNDATION_EXPORT const int PBUsbClientPort; // 8765: where the app (and anything on the phone) reaches the agent
FOUNDATION_EXPORT const int PBUsbPoolPort;   // 8767: where the PC's idle connections arrive
