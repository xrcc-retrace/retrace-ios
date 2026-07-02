#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try/@catch and converts any raised
/// NSException into an NSError. Swift's do/catch cannot catch NSExceptions —
/// AVFoundation raises them from deep inside AVAudioEngine graph rebuilds
/// (e.g. -[AVAudioIONode setVoiceProcessingEnabled:error:] →
/// AVAudioEngineGraph::_Connect during audio-route flux), and an uncaught
/// one terminates the app.
@interface ObjCExceptionCatcher : NSObject

/// Returns YES if `block` completed; NO (with `error` populated from the
/// NSException's name/reason) if an NSException was raised.
+ (BOOL)catchException:(void (NS_NOESCAPE ^)(void))block
                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
