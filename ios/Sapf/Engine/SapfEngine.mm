//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#import "SapfEngine.h"
#include "CodeWarmer.h"

#include "VM.hpp"
#include "Play.hpp"
#include "UGen.hpp"
#include <string>

extern void AddCoreOps();
extern void AddMathOps();
extern void AddStreamOps();
extern void AddUGenOps();
extern void AddSetOps();
extern void AddRandomOps();
extern void AddMidiOps();

static NSString* const kSapfVersion = @"0.1.22";

#pragma mark - SapfWordHelp

@implementation SapfWordHelp

- (instancetype)initWithName:(NSString*)name mask:(NSString*)mask help:(NSString*)help builtIn:(BOOL)builtIn
{
	if ((self = [super init])) {
		_name = [name copy];
		_mask = [mask copy];
		_help = [help copy];
		_builtIn = builtIn;
	}
	return self;
}

@end

#pragma mark - SapfEngine

@interface SapfEngine ()
@property (atomic, readwrite, copy) NSSet<NSString *> *builtInWords;
@property (atomic, readwrite, copy) NSSet<NSString *> *userWords;
@property (atomic, copy) NSDictionary<NSString *, SapfWordHelp *> *helpTable;
@end

@implementation SapfPlot
- (instancetype)initWithChannels:(NSArray<NSData *> *)channels frameCount:(NSInteger)frameCount
                        isSignal:(BOOL)isSignal truncated:(BOOL)truncated sampleRate:(double)sampleRate
{
	if ((self = [super init])) {
		_channels = channels;
		_frameCount = frameCount;
		_isSignal = isSignal;
		_truncated = truncated;
		_sampleRate = sampleRate;
	}
	return self;
}
@end

@implementation SapfEngine
{
	dispatch_queue_t _queue;
	Thread* _thread;
	size_t _numUdfHelpSeen;
	NSMutableDictionary<NSString *, SapfWordHelp *> *_helpTableBuilder; // only touched on _queue

	// post() can be called from any thread, including the audio thread when a sound fails,
	// so text is collected here and handed to the main thread in batches.
	NSLock* _outputLock;
	NSMutableString* _pendingOutput;
	BOOL _flushScheduled;
}

+ (SapfEngine *)shared
{
	static SapfEngine* sShared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ sShared = [[SapfEngine alloc] init]; });
	return sShared;
}

+ (NSInteger)outputBufferCapacity
{
	return kScopeBufferSize;
}

+ (NSInteger)outputEnvelopeBlockSize
{
	return kScopeEnvelopeBlockSize;
}

+ (NSInteger)outputEnvelopeCapacity
{
	return kScopeEnvelopeBlocks;
}

- (NSInteger)copyOutputEnvelopeMin:(float *)minBuffer max:(float *)maxBuffer count:(NSInteger)count
{
	return getScopeEnvelope(minBuffer, maxBuffer, (int)count);
}

static void postHook(const char* str, size_t len)
{
	[SapfEngine.shared appendOutput:str length:len];
}

static void openFileHook(const char* path)
{
	NSURL* url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
	dispatch_async(dispatch_get_main_queue(), ^{
		void (^handler)(NSURL*) = SapfEngine.shared.openFileHandler;
		if (handler) handler(url);
	});
}

- (instancetype)init
{
	if ((self = [super init])) {
		dispatch_queue_attr_t attr = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
		_queue = dispatch_queue_create("sapf.interpreter", attr);
		_outputLock = [[NSLock alloc] init];
		_pendingOutput = [NSMutableString string];
		_helpTableBuilder = [NSMutableDictionary dictionary];
		_builtInWords = [NSSet set];
		_userWords = [NSSet set];
		_helpTable = @{};
		gPostHook = postHook;
		gOpenFileHook = openFileHook;
	}
	return self;
}

- (NSString *)version
{
	return kSapfVersion;
}

- (double)sampleRate
{
	return vm.ar.sampleRate;
}

#pragma mark Output

- (void)appendOutput:(const char*)str length:(size_t)len
{
	NSString* text = [[NSString alloc] initWithBytes:str length:len encoding:NSUTF8StringEncoding];
	if (!text) text = [[NSString alloc] initWithBytes:str length:len encoding:NSISOLatin1StringEncoding];
	if (!text) return;

	[_outputLock lock];
	[_pendingOutput appendString:text];
	BOOL needsFlush = !_flushScheduled;
	_flushScheduled = YES;
	[_outputLock unlock];

	if (needsFlush) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self flushOutput]; });
	}
}

- (void)flushOutput
{
	[_outputLock lock];
	NSString* text = [_pendingOutput copy];
	[_pendingOutput setString:@""];
	_flushScheduled = NO;
	[_outputLock unlock];

	if (text.length && self.outputHandler) self.outputHandler(text);
}

#pragma mark Startup

- (void)startWithSampleRate:(double)sampleRate preludePath:(NSString *)preludePath
{
	NSString* prelude = [preludePath copy];
	dispatch_async(_queue, ^{
		post("------------------------------------------------\n");
		post("A tool for the expression of sound as pure form.\n");
		post("------------------------------------------------\n");
		post("--- version %s\n", kSapfVersion.UTF8String);

		vm.setSampleRate(sampleRate);
		post("sample rate %g\n", vm.ar.sampleRate);

		// On by default; launch with "-warmCode NO" to compare.
		NSNumber* warm = [NSUserDefaults.standardUserDefaults objectForKey:@"warmCode"];
		if (!warm || warm.boolValue) {
			CodeWarmth warmth = warmCode();
			post("code warmed: %zu pages, %.1f MB%s\n", warmth.pages, warmth.bytes / 1048576.,
			     warmth.locked ? ", locked in memory" : "");
		}

		vm.addBifHelp("Argument Automapping legend:");
		vm.addBifHelp("   a - as is. argument is not automapped.");
		vm.addBifHelp("   z - argument is expected to be a signal or scalar, streams are auto mapped.");
		vm.addBifHelp("   k - argument is expected to be a scalar, signals and streams are automapped.");
		vm.addBifHelp("");

		AddCoreOps();
		AddMathOps();
		AddStreamOps();
		AddRandomOps();
		AddUGenOps();
		AddMidiOps();
		AddSetOps();

		self->_thread = new Thread();

		if (prelude) {
			vm.prelude_file = strdup(prelude.fileSystemRepresentation);
			loadFile(*self->_thread, vm.prelude_file);
		}
		[self rebuildHelpTable];

		post("Type 'helpall' to get a list of all built-in functions.\n");
		post("Tap a word to see its help.\n\n");
	});
}

#pragma mark Help

// Help lines look like "name @mask (a b --> c) description" or "name (a --> b) description".
// Section headers and the legend start with whitespace or are otherwise not a single word.
static SapfWordHelp* parseHelpLine(std::string const& line, BOOL builtIn)
{
	if (line.empty() || isspace((unsigned char)line[0])) return nil;

	size_t nameEnd = line.find(' ');
	if (nameEnd == std::string::npos || nameEnd == 0) return nil;
	std::string name = line.substr(0, nameEnd);
	if (name.back() == ':') return nil; // "Argument Automapping legend:"

	std::string rest = line.substr(nameEnd + 1);
	std::string mask;
	if (!rest.empty() && rest[0] == '@') {
		size_t maskEnd = rest.find(' ');
		mask = rest.substr(1, maskEnd == std::string::npos ? std::string::npos : maskEnd - 1);
		rest = maskEnd == std::string::npos ? std::string() : rest.substr(maskEnd + 1);
	}

	NSString* nsName = [NSString stringWithUTF8String:name.c_str()];
	NSString* nsHelp = [NSString stringWithUTF8String:rest.c_str()];
	if (!nsName || !nsHelp) return nil;
	NSString* nsMask = mask.empty() ? nil : [NSString stringWithUTF8String:mask.c_str()];
	return [[SapfWordHelp alloc] initWithName:nsName mask:nsMask help:nsHelp builtIn:builtIn];
}

// Must be called on _queue. Built in help never changes after startup; user help only grows.
- (void)rebuildHelpTable
{
	std::vector<std::string> bifs, udfs;
	{
		Locker lock(&gHelpMutex);
		if (self.builtInWords.count == 0) bifs = vm.bifHelp;
		if (vm.udfHelp.size() == _numUdfHelpSeen && bifs.empty()) return;
		udfs.assign(vm.udfHelp.begin() + _numUdfHelpSeen, vm.udfHelp.end());
		_numUdfHelpSeen = vm.udfHelp.size();
	}

	if (!bifs.empty()) {
		NSMutableSet* words = [NSMutableSet set];
		for (auto const& line : bifs) {
			SapfWordHelp* help = parseHelpLine(line, YES);
			if (!help) continue;
			_helpTableBuilder[help.name] = help;
			[words addObject:help.name];
		}
		self.builtInWords = words;
	}

	NSMutableSet* userWords = [self.userWords mutableCopy];
	for (auto const& line : udfs) {
		SapfWordHelp* help = parseHelpLine(line, NO);
		if (!help) continue;
		_helpTableBuilder[help.name] = help;
		[userWords addObject:help.name];
	}
	self.userWords = userWords;
	self.helpTable = _helpTableBuilder;
}

- (NSString *)allHelpText
{
	std::string text = "BUILT IN FUNCTIONS\n\n";
	Locker lock(&gHelpMutex);
	for (auto const& line : vm.bifHelp) text += line + "\n";
	text += "\nUSER DEFINED FUNCTIONS\n\n";
	for (auto const& line : vm.udfHelp) text += line + "\n";
	return [NSString stringWithUTF8String:text.c_str()] ?: @"";
}

- (SapfWordHelp *)helpForWord:(NSString *)word
{
	return self.helpTable[word];
}

- (void)describeWord:(NSString *)word completion:(void (^)(NSString * _Nullable))completion
{
	NSString* name = [word copy];
	dispatch_async(_queue, ^{
		NSString* result = nil;
		Thread* th = self->_thread;
		if (th) {
			try {
				P<String> sym = getsym(name.UTF8String);
				V value;
				if (th->mWorkspace() && th->mWorkspace->get(*th, sym, value)) {
					std::string out;
					value.printShort(*th, out);
					if (out.size() > 300) out = out.substr(0, 300) + " ...";
					result = [NSString stringWithUTF8String:out.c_str()];
				}
			} catch (...) {
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
	});
}

#pragma mark Plotting

// Pulls up to maxFrames from a signal into samples. Returns YES if the signal ended.
static bool takeSignal(Thread& th, Arg signal, int64_t maxFrames, std::vector<float>& samples)
{
	ZIn in(signal);
	const int kChunk = 4096;
	samples.reserve((size_t)std::min<int64_t>(maxFrames, 1 << 20));
	while ((int64_t)samples.size() < maxFrames) {
		int n = (int)std::min<int64_t>(kChunk, maxFrames - samples.size());
		size_t at = samples.size();
		samples.resize(at + n);
		bool done = in.fill(th, n, samples.data() + at, 1);
		samples.resize(at + n);
		if (done) return true;
	}
	return false;
}

- (void)plotTopOfStackWithMaxSeconds:(double)maxSeconds
                          completion:(void (^)(SapfPlot * _Nullable, NSString *))completion
{
	dispatch_async(dispatch_get_main_queue(), ^{ if (self.busyHandler) self.busyHandler(YES); });
	dispatch_async(_queue, ^{
		SapfPlot* plot = nil;
		NSString* message = @"";
		Thread& th = *self->_thread;
		double sampleRate = vm.ar.sampleRate;
		// Keep the whole plot to about 128 MB of floats.
		const int64_t kMaxTotalFrames = 32 << 20;
		try {
			if (th.stackDepth() == 0) {
				message = @"the stack is empty";
			} else {
				V v = th.top();
				std::vector<std::vector<float>> channels;
				bool isSignal = true, truncated = false;

				if (v.isZList()) {
					channels.emplace_back();
					truncated = !takeSignal(th, v, (int64_t)(maxSeconds * sampleRate), channels[0]);
				} else if (v.isVList() && !v.isFinite()) {
					message = @"can't plot an endless list of channels or values";
				} else if (v.isVList()) {
					P<List> list = ((List*)v.o())->pack(th);
					Array* items = list->mArray();
					int64_t count = items->size();
					bool allSignals = count > 0, allNumbers = count > 0;
					for (int64_t i = 0; i < count; ++i) {
						V item = items->at(i);
						allSignals = allSignals && item.isZList();
						allNumbers = allNumbers && item.isReal();
					}
					if (allSignals && count <= 64) {
						int64_t maxFrames = std::min<int64_t>((int64_t)(maxSeconds * sampleRate), kMaxTotalFrames / count);
						for (int64_t i = 0; i < count; ++i) {
							channels.emplace_back();
							if (!takeSignal(th, items->at(i), maxFrames, channels.back())) truncated = true;
						}
					} else if (allNumbers) {
						isSignal = false;
						channels.emplace_back();
						for (int64_t i = 0; i < std::min(count, kMaxTotalFrames); ++i) {
							channels[0].push_back((float)items->at(i).f);
						}
						truncated = count > kMaxTotalFrames;
					} else {
						message = @"plot needs a signal, a list of signals, or a list of numbers";
					}
				} else {
					message = @"plot needs a signal, a list of signals, or a list of numbers";
				}

				if (!channels.empty()) {
					size_t frames = 0;
					for (auto& c : channels) frames = std::max(frames, c.size());
					NSMutableArray<NSData*>* datas = [NSMutableArray array];
					for (auto& c : channels) {
						c.resize(frames, 0.f); // channels that ended early are silent after
						[datas addObject:[NSData dataWithBytes:c.data() length:frames * sizeof(float)]];
					}
					if (frames == 0) {
						message = @"nothing to plot: it has no frames";
					} else {
						plot = [[SapfPlot alloc] initWithChannels:datas frameCount:(NSInteger)frames
						                                 isSignal:isSignal truncated:truncated sampleRate:sampleRate];
						message = @"";
					}
				}
			}
		} catch (int err) {
			if (err <= -1000 && err > -1000 - kNumErrors) {
				message = [NSString stringWithFormat:@"error: %s", errString[-1000 - err]];
			} else {
				message = [NSString stringWithFormat:@"error: %d", err];
			}
		} catch (std::bad_alloc&) {
			message = @"not enough memory";
		} catch (...) {
			message = @"unknown error";
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (self.busyHandler) self.busyHandler(NO);
			completion(plot, message);
		});
	});
}

#pragma mark Evaluation

static void reportError(int err)
{
	if (err <= -1000 && err > -1000 - kNumErrors) {
		post("error: %s\n", errString[-1000 - err]);
	} else {
		post("error: %d\n", err);
	}
}

// Appends code that's run to $SAPF_LOG, as Thread::getLine does for each line typed on the Mac.
static void logCode(Thread& th, std::string const& source)
{
	const char* path = getenv("SAPF_LOG");
	if (!path || source.find_first_not_of(" \t\r\n") == std::string::npos) return;
	FILE* file = fopen(path, "a");
	if (!file) return;
	th.logTimestamp(file);
	fwrite(source.data(), 1, source.size(), file);
	if (source.back() != '\n') fputc('\n', file);
	fclose(file);
}

- (void)evaluate:(NSString *)code
{
	std::string source = code.UTF8String ?: "";
	dispatch_async(dispatch_get_main_queue(), ^{ if (self.busyHandler) self.busyHandler(YES); });
	dispatch_async(_queue, ^{
		Thread& th = *self->_thread;
		logCode(th, source);
		// Same as one turn of Thread::repl, but reading from a string.
		try {
			P<Fun> compiledFun;
			if (th.compile(source.c_str(), compiledFun, true)) {
				compiledFun->runREPL(th);
			}
		} catch (V& v) {
			post("error: ");
			v.print(th);
			post("\n");
		} catch (int err) {
			reportError(err);
		} catch (std::bad_alloc& xerr) {
			post("not enough memory\n");
		} catch (...) {
			post("unknown error\n");
		}

		try {
			if (th.stackDepth()) {
				th.printStack();
				post("\n");
			}
		} catch (int err) {
			reportError(err);
		} catch (...) {
			post("unknown error\n");
		}

		[self rebuildHelpTable];
		dispatch_async(dispatch_get_main_queue(), ^{ if (self.busyHandler) self.busyHandler(NO); });
	});
}

- (void)stopAll
{
	// Not on the interpreter queue: stop must work even while something long is evaluating.
	stopPlaying();
}

- (void)resumeAll
{
	restartPlaying();
}

- (void)clearStack
{
	dispatch_async(_queue, ^{
		if (self->_thread) self->_thread->clearStack();
	});
}

#pragma mark Output display

- (NSInteger)copyOutputSamples:(float *)buffer count:(NSInteger)count
{
	return getScopeSamples(buffer, (int)count);
}

- (NSUInteger)audioDropouts
{
	return getAudioTimingStats(false).dropouts;
}

- (NSUInteger)lateAudioRenders
{
	return getAudioTimingStats(false).lateRenders;
}

- (float)takePeakAudioLoad
{
	return getAudioTimingStats(true).peakLoad;
}

- (void)setPointerX:(float)x y:(float)y down:(BOOL)down
{
	setMouseUGenState(x, y, down);
}

@end
