//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This program is free software: you can redistribute it and/or modify
//    it under the terms of the GNU General Public License as published by
//    the Free Software Foundation, either version 3 of the License, or
//    (at your option) any later version.
//
//    This program is distributed in the hope that it will be useful,
//    but WITHOUT ANY WARRANTY; without even the implied warranty of
//    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//    GNU General Public License for more details.
//
//    You should have received a copy of the GNU General Public License
//    along with this program.  If not, see <https://www.gnu.org/licenses/>.

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

/// Maximum count for copyOutputSamples.
@property (class, nonatomic, readonly) NSInteger outputBufferCapacity;

/// Feeds touch positions to the mousex / mousey family of unit generators. x and y are 0..1, y up.
- (void)setPointerX:(float)x y:(float)y down:(BOOL)down;

@end

NS_ASSUME_NONNULL_END
