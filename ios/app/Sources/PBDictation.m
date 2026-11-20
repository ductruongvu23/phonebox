#import "PBDictation.h"
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>

static const NSTimeInterval kMaxSeconds = 60;
static const NSUInteger kMaxChars = 2000;

NSString *PBJSString(NSString *s) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:s ?: @"" options:NSJSONWritingFragmentsAllowed error:nil];
    NSString *out = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"\"\"";
    // U+2028/2029 are valid in JSON but ended a JS string literal before ES2019
    out = [out stringByReplacingOccurrencesOfString:@" " withString:@"\\u2028"];
    return [out stringByReplacingOccurrencesOfString:@" " withString:@"\\u2029"];
}

@implementation PBDictation {
    void (^_js)(NSString *);
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_request;
    SFSpeechRecognitionTask *_task;
    AVAudioEngine *_engine;
    NSInteger _session;   // id of the running session, 0 = none
    NSInteger _starting;  // id waiting for permission prompts
}

- (instancetype)initWithScript:(void (^)(NSString *))js {
    if ((self = [super init])) _js = [js copy];
    return self;
}

- (BOOL)available { return [SFSpeechRecognizer new] != nil; }

- (void)send:(NSString *)kind text:(NSString *)text id:(NSInteger)sid {
    if (text.length > kMaxChars) text = [text substringToIndex:kMaxChars];
    NSString *js = [NSString stringWithFormat:@"window.onAndroidSpeech && window.onAndroidSpeech(%@, %@, %ld)", PBJSString(kind), PBJSString(text), (long)sid];
    dispatch_async(dispatch_get_main_queue(), ^{ self->_js(js); });
}

- (void)startWithLanguage:(NSString *)lang offline:(BOOL)offline id:(NSInteger)sid {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_starting) [self send:@"error" text:@"cancelled" id:self->_starting]; // a newer request replaces one waiting
        self->_starting = sid;
        [self authorize:^(NSString *problem) {
            if (self->_starting != sid) return; // replaced or cancelled while the prompt was up
            self->_starting = 0;
            if (problem) [self send:@"error" text:problem id:sid];
            else [self begin:lang offline:offline id:sid];
        }];
    });
}

/// Asks for speech recognition and the microphone; iOS shows each prompt once, later a refusal only
/// reads "denied", which is the "permission-blocked" case (Settings is the only way back).
- (void)authorize:(void (^)(NSString *problem))done {
    void (^afterSpeech)(SFSpeechRecognizerAuthorizationStatus, BOOL) = ^(SFSpeechRecognizerAuthorizationStatus st, BOOL asked) {
        if (st != SFSpeechRecognizerAuthorizationStatusAuthorized) {
            done(asked && st == SFSpeechRecognizerAuthorizationStatusDenied ? @"permission" : @"permission-blocked");
            return;
        }
        AVAudioSessionRecordPermission mic = AVAudioSession.sharedInstance.recordPermission;
        if (mic == AVAudioSessionRecordPermissionGranted) { done(nil); return; }
        if (mic == AVAudioSessionRecordPermissionDenied) { done(@"permission-blocked"); return; }
        [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(granted ? nil : @"permission"); });
        }];
    };
    SFSpeechRecognizerAuthorizationStatus st = SFSpeechRecognizer.authorizationStatus;
    if (st == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus s) {
            dispatch_async(dispatch_get_main_queue(), ^{ afterSpeech(s, YES); });
        }];
    } else afterSpeech(st, NO);
}

- (void)begin:(NSString *)lang offline:(BOOL)offline id:(NSInteger)sid {
    if (_session) { NSInteger was = _session; [self endSession]; [self send:@"error" text:@"cancelled" id:was]; }
    SFSpeechRecognizer *r = lang.length ? [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:lang]] : [SFSpeechRecognizer new];
    if (!r || !r.isAvailable) { [self send:@"error" text:@"unavailable" id:sid]; return; }
    // "on the phone only" is a promise: refuse rather than fall back to Apple's servers
    if (offline && !r.supportsOnDeviceRecognition) { [self send:@"error" text:@"offline-unavailable" id:sid]; return; }

    NSError *err = nil;
    AVAudioSession *as = AVAudioSession.sharedInstance;
    [as setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeMeasurement options:0 error:&err];
    if (!err) [as setActive:YES withOptions:0 error:&err];
    if (err) { [self send:@"error" text:@"unavailable" id:sid]; return; }

    SFSpeechAudioBufferRecognitionRequest *req = [SFSpeechAudioBufferRecognitionRequest new];
    req.shouldReportPartialResults = YES;
    if (offline) req.requiresOnDeviceRecognition = YES;
    AVAudioEngine *engine = [AVAudioEngine new];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *fmt = [input outputFormatForBus:0];
    if (fmt.sampleRate <= 0) { [as setActive:NO withOptions:0 error:nil]; [self send:@"error" text:@"unavailable" id:sid]; return; }
    [input installTapOnBus:0 bufferSize:1024 format:fmt block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) { [req appendAudioPCMBuffer:buf]; }];
    [engine prepare];
    if (![engine startAndReturnError:&err]) {
        [input removeTapOnBus:0];
        [as setActive:NO withOptions:0 error:nil];
        [self send:@"error" text:@"unavailable" id:sid];
        return;
    }
    _recognizer = r; _request = req; _engine = engine; _session = sid;
    _task = [r recognitionTaskWithRequest:req resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_session != sid) return; // cancelled or replaced
            if (result && !result.isFinal) { [self send:@"partial" text:result.bestTranscription.formattedString id:sid]; return; }
            if (result && result.isFinal) { [self endSession]; [self send:@"final" text:result.bestTranscription.formattedString id:sid]; return; }
            if (error) {
                // 1110 = "no speech detected"; anything else is reported like a recognizer/network failure
                BOOL noSpeech = [error.domain isEqualToString:@"kAFAssistantErrorDomain"] && (error.code == 1110 || error.code == 203);
                [self endSession];
                [self send:@"error" text:noSpeech ? @"7" : @"2" id:sid];
            }
        });
    }];
    [self send:@"ready" text:@"" id:sid];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kMaxSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_session == sid) [self stop:sid];
    });
}

- (void)endSession {
    [_engine stop];
    [_engine.inputNode removeTapOnBus:0];
    [_task cancel];
    _task = nil; _request = nil; _engine = nil; _recognizer = nil;
    _session = 0;
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
}

/// Stops listening and delivers what was heard so far, if [sid] is the session running.
- (void)stop:(NSInteger)sid {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sid != self->_session || !self->_engine) return;
        [self->_engine stop];
        [self->_engine.inputNode removeTapOnBus:0];
        [self->_request endAudio]; // the final result follows
        [self send:@"end" text:@"" id:sid];
    });
}

/// Drops the session without a result if [sid] is running or waiting; 0 = whatever runs (the app went inactive).
- (void)cancel:(NSInteger)sid {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_starting && sid != 0 && self->_starting == sid) { NSInteger w = self->_starting; self->_starting = 0; [self send:@"error" text:@"cancelled" id:w]; }
        if (self->_session && (sid == 0 || sid == self->_session)) { NSInteger was = self->_session; [self endSession]; [self send:@"error" text:@"cancelled" id:was]; }
    });
}

@end
