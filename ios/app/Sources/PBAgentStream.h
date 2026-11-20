#import <Foundation/Foundation.h>
#import "PBAgentLink.h"

/// One live connection to the agent's /api/stream (server-sent events). Reconnects after errors; on Wi-Fi it
/// reconnects every minute so a freshly plugged-in cable is preferred again. "open" / "close" pseudo-events tell
/// the panel when to stop or resume its polling fallback. Port of AgentStream.kt.
@interface PBAgentStream : NSObject
- (instancetype)initWithLink:(PBAgentLink *)link deliver:(void (^)(NSString *event, NSString *data))deliver;
- (void)start;
- (void)stop;
@end
