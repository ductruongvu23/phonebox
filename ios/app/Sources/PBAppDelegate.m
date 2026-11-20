#import "PBAppDelegate.h"
#import "PBPanelViewController.h"

@implementation PBAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [PBPanelViewController new];
    [self.window makeKeyAndVisible];
    return YES;
}

@end
