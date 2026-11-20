#import <WebKit/WebKit.h>
#import "PBAgentLink.h"

/// phonebox-app://panel/assets/www/<file> serves the bundled panel; phonebox-app://panel/agent/<path> is forwarded to
/// the PC (the web view itself never makes network requests). Port of MainActivity.shouldInterceptRequest/proxy.
FOUNDATION_EXPORT NSString *const PBScheme;   // "phonebox-app"
FOUNDATION_EXPORT NSString *const PBHost;     // "panel"
FOUNDATION_EXPORT NSString *PBPanelURLString(void);

@interface PBSchemeHandler : NSObject <WKURLSchemeHandler>
- (instancetype)initWithLink:(PBAgentLink *)link;
@end
