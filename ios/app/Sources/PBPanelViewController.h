#import <UIKit/UIKit.h>
#import "PBBridge.h"
#import "PBAgentLink.h"

@interface PBPanelViewController : UIViewController <PBBridgeHost>
/// A pairing link opened through the phonebox:// scheme: ask, then pair.
- (void)handlePairLink:(PBPairLink *)link;
@end
