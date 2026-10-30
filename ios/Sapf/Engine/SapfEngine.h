//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Help for a single word, as shown in the editor tooltip.
@interface SapfWordHelp : NSObject
@property (nonatomic, readonly) NSString *name;
/// Argument automapping mask, e.g. "zz" for "@zz". nil if not automapped.
@property (nonatomic, readonly, nullable) NSString *mask;
/// One line help, usually starting with the stack effect, e.g. "(freq phase --> out) sine oscillator."
@property (nonatomic, readonly) NSString *help;
/// YES if this is a built in function, NO if user defined.
@property (nonatomic, readonly) BOOL builtIn;
@end

/// Wraps the sapf virtual machine. All evaluation happens on a private serial queue,
/// so the interpreter state is only ever touched by one thread at a time.
@interface SapfEngine : NSObject

@property (class, nonatomic, readonly) SapfEngine *shared;

/// Called on the main queue with text printed by the interpreter.
@property (nonatomic, copy, nullable) void (^outputHandler)(NSString *text);

/// Called on the main queue when the interpreter wants to show a file
/// (a recorded sound, a spectrogram image, ...).
@property (nonatomic, copy, nullable) void (^openFileHandler)(NSURL *url);

/// Called on the main queue when evaluation starts or finishes.
@property (nonatomic, copy, nullable) void (^busyHandler)(BOOL busy);

@property (nonatomic, readonly) double sampleRate;
@property (nonatomic, readonly) NSString *version;

/// Names of all built in functions. Safe to read from any thread.
@property (atomic, readonly, copy) NSSet<NSString *> *builtInWords;
/// Names of user defined functions that have help. Safe to read from any thread.
@property (atomic, readonly, copy) NSSet<NSString *> *userWords;

/// Sets up the VM at the given sample rate, adds all primitives and loads the prelude.
- (void)startWithSampleRate:(double)sampleRate preludePath:(nullable NSString *)preludePath;

/// Compiles and runs code, then prints the stack, exactly like entering a line in the terminal REPL.
- (void)evaluate:(NSString *)code;

/// Stops all sounds (like the 'stop' word).
- (void)stopAll;

/// Clears the stack (like the 'clear' word).
- (void)clearStack;

/// Help for a built in or user defined word. Returns nil if there is none. Fast; safe from the main thread.
- (nullable SapfWordHelp *)helpForWord:(NSString *)word;

/// Looks up a word in the workspace and calls back on the main queue with a short description of its
/// value, or nil if it is not defined. Runs on the interpreter queue, so it waits for any running evaluation.
- (void)describeWord:(NSString *)word completion:(void (^)(NSString *_Nullable description))completion;

/// Copies the most recent `count` samples of everything currently playing (mixed to mono) into `buffer`.
/// Returns the number of sounds playing. Safe to call from any thread.
- (NSInteger)copyOutputSamples:(float *)buffer count:(NSInteger)count;

/// Starts the sounds that were playing again after an audio interruption stopped them.
- (void)resumeAll;

/// Gaps in the audio output's timestamps, whatever caused them.
@property (nonatomic, readonly) NSUInteger audioDropouts;
/// Renders that took longer than the audio they produced lasts.
@property (nonatomic, readonly) NSUInteger lateAudioRenders;
/// The longest render since the last call, as a fraction of the time available. Reading resets it.
- (float)takePeakAudioLoad;

/// Maximum count for copyOutputSamples.
@property (class, nonatomic, readonly) NSInteger outputBufferCapacity;

/// Feeds touch positions to the mousex / mousey family of unit generators. x and y are 0..1, y up.
- (void)setPointerX:(float)x y:(float)y down:(BOOL)down;

@end

NS_ASSUME_NONNULL_END
