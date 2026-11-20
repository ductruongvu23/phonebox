#import <Foundation/Foundation.h>

/// Connection to the PhoneBox agent on the PC (port of AgentLink.kt).
///   1. USB: http://127.0.0.1:8765 (a tunnel, see PBUsbListener / IosUsb.cs)
///   2. Wi-Fi: https://<host>:<port>, token + SHA-256 pin of the agent's self-signed certificate.
/// A USB cable always wins. POSTs are never retried on another route once the body may have been sent.

#define PBL(key) NSLocalizedString(key, nil) // the native dialogs, in the Android shell's languages (en, vi, el)

typedef NS_ENUM(NSInteger, PBRoute) { PBRouteNone = 0, PBRouteUSB, PBRouteWiFi };
FOUNDATION_EXPORT NSString *PBRouteName(PBRoute route); // "usb" | "wifi" | "none"

@interface PBReply : NSObject
@property (nonatomic) NSInteger code;
@property (nonatomic, copy) NSString *contentType;
@property (nonatomic, copy) NSData *body;
+ (instancetype)withCode:(NSInteger)code json:(NSString *)json;
@end

@interface PBStreamTarget : NSObject
@property (nonatomic) PBRoute route;
@property (nonatomic, copy) NSString *urlString;
@property (nonatomic, copy) NSString *host;
@property (nonatomic) int port;
@property (nonatomic, copy) NSString *pin;   // nil on USB
@property (nonatomic, copy) NSString *token; // nil on USB
@end

typedef NS_ENUM(NSInteger, PBPairFailureKind) {
    PBPairUnreachable, PBPairCodeRejected, PBPairBadAnswer, PBPairWrongCertificate
};
@interface PBPairFailure : NSObject
@property (nonatomic) PBPairFailureKind kind;
@property (nonatomic, copy) NSString *pc;
@property (nonatomic, copy) NSArray<NSString *> *hosts;
@property (nonatomic) NSInteger code;
- (NSString *)message;
@end

/// Pairing link from the QR code (https://ersinkoc.github.io/phonebox/pair/#v=1&...) or phonebox://pair?v=1&...
@interface PBPairLink : NSObject
@property (nonatomic, copy) NSString *pc;
@property (nonatomic, copy) NSString *fingerprint;
@property (nonatomic) int port;
@property (nonatomic, copy) NSArray<NSString *> *hosts;
@property (nonatomic, copy) NSString *code;
@property (nonatomic, readonly) NSString *check; // first 8 hex digits of the fingerprint, "ABCD 1234"
+ (PBPairLink *)parse:(NSURL *)url;
+ (BOOL)isLocalAddress:(NSString *)host;
@end

/// URLSession delegate: refuses redirects and, when [pin] is set, trusts only the certificate with that SHA-256.
@interface PBPinDelegate : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, copy) NSString *pin;
@property (atomic) BOOL pinMismatch;
@property (nonatomic, copy) void (^onWebSocketClose)(void); // trackpad socket ended
- (instancetype)initWithPin:(NSString *)pin;
- (void)handleChallenge:(NSURLAuthenticationChallenge *)challenge
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler;
@end

@interface PBAgentLink : NSObject
@property (atomic, readonly) PBRoute route;
@property (nonatomic, copy) void (^onChange)(void); // route or paired computers changed (any thread)
@property (nonatomic, readonly, copy) NSString *appVersion;

- (PBReply *)request:(NSString *)method path:(NSString *)pathAndQuery body:(NSData *)body contentType:(NSString *)contentType;
- (NSArray<PBStreamTarget *> *)streamTargets;
- (void)noteRoute:(PBRoute)route;
- (void)applyIdentity:(NSMutableURLRequest *)request;
+ (BOOL)probeHost:(NSString *)host port:(int)port timeoutMs:(int)timeoutMs;

- (NSString *)pcsJSON;
- (BOOL)selectPc:(NSString *)pcId;
- (void)forgetPc:(NSString *)pcId;
- (NSString *)pairedPc;
- (PBPairFailure *)claim:(PBPairLink *)link; // blocks (network): call off the main thread; nil = paired
- (void)sendTrackpad:(NSString *)type dx:(double)dx dy:(double)dy delta:(double)delta;
- (void)close;
@end
