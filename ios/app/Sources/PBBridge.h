#import <WebKit/WebKit.h>
#import "PBAgentLink.h"

@protocol PBBridgeHost <NSObject>
- (void)bridgeEvaluate:(NSString *)script;
- (void)bridgeReloadPanel;
- (void)bridgeSetBrightness:(double)value; // negative = give control back to the system
- (void)bridgeSetOrientation:(NSString *)mode; // "landscape" | "portrait" | "auto"
@end

/// The native end of window.Android (see bridge.js). Only the panel's main frame is served: window.webkit exists in
/// every frame, so the sender is checked on each message. The phone only ever sends ids and plain values, never
/// commands or paths, to the PC.
@interface PBBridge : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) id<PBBridgeHost> host;
- (instancetype)initWithLink:(PBAgentLink *)link;
/// The user script that defines window.__pbNative before any page script runs.
- (WKUserScript *)initialStateScript;
/// Pushes values that changed into window.__pbNative.
- (void)pushState;
- (void)appDidBecomeActive;
- (void)appWillResignActive;
- (void)teardown;
@end
