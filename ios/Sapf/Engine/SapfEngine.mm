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

#import "SapfEngine.h"

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

#pragma mark Evaluation

static void reportError(int err)
{
	if (err <= -1000 && err > -1000 - kNumErrors) {
		post("error: %s\n", errString[-1000 - err]);
	} else {
		post("error: %d\n", err);
	}
}

- (void)evaluate:(NSString *)code
{
	std::string source = code.UTF8String ?: "";
	dispatch_async(dispatch_get_main_queue(), ^{ if (self.busyHandler) self.busyHandler(YES); });
	dispatch_async(_queue, ^{
		Thread& th = *self->_thread;
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

- (void)setPointerX:(float)x y:(float)y down:(BOOL)down
{
	setMouseUGenState(x, y, down);
}

@end
