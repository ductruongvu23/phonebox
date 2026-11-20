#import "PBPanelViewController.h"

// Phase 0 stub: a black screen. Phase 1 puts the WKWebView here.
@implementation PBPanelViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
}

- (BOOL)prefersStatusBarHidden { return YES; }

@end
