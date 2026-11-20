#import "PBAppDelegate.h"
#import "PBPanelViewController.h"
#import "PBUsbListener.h"

@implementation PBAppDelegate {
    PBPanelViewController *_panel;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [[PBUsbListener shared] start]; // the USB tunnel (a no-op if phoneboxd owns the ports)
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    _panel = [PBPanelViewController new];
    self.window.rootViewController = _panel;
    [self.window makeKeyAndVisible];
    return YES;
}

// phonebox://pair?... from the "Open in PhoneBox" button on the pairing page
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    PBPairLink *link = [PBPairLink parse:url];
    if (!link) return NO;
    [_panel handlePairLink:link];
    return YES;
}

@end
