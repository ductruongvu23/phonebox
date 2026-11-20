#import <Foundation/Foundation.h>

/// Speech to text for the Dictation widget (port of Dictation.kt) with SFSpeechRecognizer. One session at a time, at
/// most 60 s, cancelled when the app is not active. Every session has an id (made by bridge.js); events go to
/// window.onAndroidSpeech(kind, text, id) through [js]. Nothing is stored.
@interface PBDictation : NSObject
- (instancetype)initWithScript:(void (^)(NSString *script))js;
- (BOOL)available;
- (void)startWithLanguage:(NSString *)lang offline:(BOOL)offline id:(NSInteger)sessionId;
- (void)stop:(NSInteger)sessionId;
- (void)cancel:(NSInteger)sessionId; // 0 = whatever runs
@end

/// A string as a JavaScript/JSON literal, quotes included.
FOUNDATION_EXPORT NSString *PBJSString(NSString *s);
