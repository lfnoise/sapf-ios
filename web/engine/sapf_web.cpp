//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// The bridge between the web page and the interpreter; the web counterpart of ios/Sapf/Engine/SapfEngine.mm,
// and it behaves the same way.
//
// Threads:
//   browser main thread   calls the exported sapf_* functions and collects results with sapf_poll().
//   interpreter pthread   runs everything that uses the interpreter's Thread, one request at a time.
//   audio worklet         calls renderSharedMix() (Play.cpp), which pulls every playing signal.
//   player watchdog       Play.cpp's thread that removes finished players and writes recordings.
//
// The main thread never waits for the interpreter, so the page stays responsive and Stop always works.

#include <emscripten.h>
#include <emscripten/webaudio.h>
#include <pthread.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <vector>

#include "VM.hpp"
#include "Play.hpp"
#include "UGen.hpp"
#include "Midi.hpp"
#include "ErrorCodes.hpp"
#include "SpinLock.hpp"

extern void AddCoreOps();
extern void AddMathOps();
extern void AddStreamOps();
extern void AddUGenOps();
extern void AddSetOps();
extern void AddRandomOps();
extern void AddMidiOps();

const char* gVersionString = "0.1.22";

static const size_t kInterpreterStackSize = 32 * 1024 * 1024;
static const size_t kAudioThreadStackSize = 2 * 1024 * 1024;
static const size_t kMaxPendingOutput = 1 << 20;

static Thread* gThread = nullptr;
static EMSCRIPTEN_WEBAUDIO_T gAudioContext = 0;
static double gSampleRate = 48000.;
static bool gStarted = false;

////////////////////////////////////////////////////////////////////////////////////////////////////
// Outbox: what the page needs to know, collected from any thread and handed over by sapf_poll().
// A spin lock, because the audio thread posts error messages.

static SpinLock gOutboxLock;
static std::string gPendingOutput;
static bool gOutputTruncated = false;
static std::vector<std::string> gPendingResults;   // JSON objects
static std::vector<std::string> gPendingOpenPaths;
static std::vector<std::string> gPendingMidiRequests; // JSON arrays
static std::atomic<int> gQueuedRequests { 0 };
static std::atomic<int> gAudioState { 0 };           // 0 starting, 1 ready, -1 failed

static void postToPage(const char* text, size_t length)
{
	SpinLocker lock(gOutboxLock);
	if (gPendingOutput.size() + length > kMaxPendingOutput) {
		gOutputTruncated = true;
		return;
	}
	gPendingOutput.append(text, length);
}

static void openFileOnPage(const char* path)
{
	SpinLocker lock(gOutboxLock);
	gPendingOpenPaths.emplace_back(path);
}

static void appendJSONString(std::string& out, const std::string& s);

// The MIDI words ask the page, which has the Web MIDI devices (see Midi.hpp).
static void midiRequestToPage(const char* request, int uid, int index)
{
	std::string json = "[";
	appendJSONString(json, request);
	json += "," + std::to_string(uid) + "," + std::to_string(index) + "]";
	SpinLocker lock(gOutboxLock);
	gPendingMidiRequests.push_back(json);
}

static void appendJSONString(std::string& out, const std::string& s)
{
	out += '"';
	for (unsigned char c : s) {
		switch (c) {
			case '"': out += "\\\""; break;
			case '\\': out += "\\\\"; break;
			case '\n': out += "\\n"; break;
			case '\r': out += "\\r"; break;
			case '\t': out += "\\t"; break;
			default:
				if (c < 0x20) {
					char buf[8];
					snprintf(buf, sizeof buf, "\\u%04x", c);
					out += buf;
				} else {
					out += (char)c;
				}
		}
	}
	out += '"';
}

static void addResult(const std::string& json)
{
	SpinLocker lock(gOutboxLock);
	gPendingResults.push_back(json);
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// Interpreter thread.

static std::mutex gQueueMutex;
static std::condition_variable gQueueCondition;
static std::deque<std::function<void()>> gQueue;

static void* interpreterMain(void*)
{
	for (;;) {
		std::function<void()> work;
		{
			std::unique_lock<std::mutex> lock(gQueueMutex);
			gQueueCondition.wait(lock, [] { return !gQueue.empty(); });
			work = std::move(gQueue.front());
			gQueue.pop_front();
		}
		work();
		--gQueuedRequests;
	}
	return nullptr;
}

static void enqueue(std::function<void()> work)
{
	++gQueuedRequests;
	{
		std::lock_guard<std::mutex> lock(gQueueMutex);
		gQueue.push_back(std::move(work));
	}
	gQueueCondition.notify_one();
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// Help. The page keeps the table; it is sent the help lines as they appear. Built-in help never changes after
// startup; user help only grows.

static size_t gNumUdfHelpSent = 0;
static bool gBifHelpSent = false;

// Must be called on the interpreter thread. Returns a JSON fragment: "bif":[...],"udf":[...] (either may be empty).
static std::string newHelpLines()
{
	std::vector<std::string> bifs, udfs;
	{
		Locker lock(&gHelpMutex);
		if (!gBifHelpSent) bifs = vm.bifHelp;
		udfs.assign(vm.udfHelp.begin() + gNumUdfHelpSent, vm.udfHelp.end());
		gNumUdfHelpSent = vm.udfHelp.size();
	}
	gBifHelpSent = true;
	std::string json = "\"bif\":[";
	for (size_t i = 0; i < bifs.size(); ++i) { if (i) json += ','; appendJSONString(json, bifs[i]); }
	json += "],\"udf\":[";
	for (size_t i = 0; i < udfs.size(); ++i) { if (i) json += ','; appendJSONString(json, udfs[i]); }
	json += "]";
	return json;
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// Evaluation, as one turn of Thread::repl reading from a string.

static void reportError(int err)
{
	if (err <= -1000 && err > -1000 - kNumErrors) {
		post("error: %s\n", errString[-1000 - err]);
	} else {
		post("error: %d\n", err);
	}
}

// Appends code that's run to the log file, as Thread::getLine does for each line typed on the Mac.
static void logCode(Thread& th, std::string const& source)
{
	const char* path = vm.log_file;
	if (!path || source.find_first_not_of(" \t\r\n") == std::string::npos) return;
	FILE* file = fopen(path, "a");
	if (!file) return;
	th.logTimestamp(file);
	fwrite(source.data(), 1, source.size(), file);
	if (source.back() != '\n') fputc('\n', file);
	fclose(file);
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// Plotting. Same rules and messages as the iOS app.

// Pulls up to maxFrames from a signal into samples. Returns true if the signal ended.
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

static std::string plotTopOfStack(Thread& th, double maxSeconds)
{
	std::string message;
	double sampleRate = vm.ar.sampleRate;
	// Keep the whole plot to about 128 MB of floats.
	const int64_t kMaxTotalFrames = 32 << 20;
	std::vector<std::vector<float>> channels;
	bool isSignal = true, truncated = false;
	try {
		if (th.stackDepth() == 0) {
			message = "the stack is empty";
		} else {
			V v = th.top();
			if (v.isZList()) {
				channels.emplace_back();
				truncated = !takeSignal(th, v, (int64_t)(maxSeconds * sampleRate), channels[0]);
			} else if (v.isVList() && !v.isFinite()) {
				message = "can't plot an endless list of channels or values";
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
					message = "plot needs a signal, a list of signals, or a list of numbers";
				}
			} else {
				message = "plot needs a signal, a list of signals, or a list of numbers";
			}
		}
	} catch (int err) {
		channels.clear();
		if (err <= -1000 && err > -1000 - kNumErrors) message = std::string("error: ") + errString[-1000 - err];
		else message = "error: " + std::to_string(err);
	} catch (std::bad_alloc&) {
		channels.clear();
		message = "not enough memory";
	} catch (...) {
		channels.clear();
		message = "unknown error";
	}

	size_t frames = 0;
	for (auto& c : channels) frames = std::max(frames, c.size());
	if (!channels.empty() && frames == 0) message = "nothing to plot: it has no frames";

	std::string json = "\"plot\":";
	if (!channels.empty() && frames > 0) {
		// channels one after another; the page copies them out and frees the buffer.
		float* data = (float*)malloc(channels.size() * frames * sizeof(float));
		if (!data) {
			json += "null";
			message = "not enough memory";
		} else {
			for (size_t c = 0; c < channels.size(); ++c) {
				float* dst = data + c * frames;
				memcpy(dst, channels[c].data(), channels[c].size() * sizeof(float));
				// channels that ended early are silent after
				std::fill(dst + channels[c].size(), dst + frames, 0.f);
			}
			char buf[200];
			snprintf(buf, sizeof buf, "{\"ptr\":%lu,\"channels\":%d,\"frames\":%lu,\"isSignal\":%s,\"truncated\":%s,\"sampleRate\":%g}",
				(unsigned long)(uintptr_t)data, (int)channels.size(), (unsigned long)frames,
				isSignal ? "true" : "false", truncated ? "true" : "false", sampleRate);
			json += buf;
		}
	} else {
		json += "null";
	}
	json += ",\"message\":";
	appendJSONString(json, message);
	return json;
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// Audio.

static bool processAudio(int numInputs, const AudioSampleFrame* inputs, int numOutputs, AudioSampleFrame* outputs,
                         int numParams, const AudioParamFrame* params, void* userData)
{
	if (numOutputs < 1) return true;
	AudioSampleFrame& out = outputs[0];
	int n = out.samplesPerChannel;
	float* left = out.data;
	float* right = out.numberOfChannels > 1 ? out.data + n : left;
	renderSharedMix(left, right, n);
	for (int c = 2; c < out.numberOfChannels; ++c) memset(out.data + c * n, 0, n * sizeof(float));
	return true;
}

static void audioProcessorCreated(EMSCRIPTEN_WEBAUDIO_T context, bool success, void* userData)
{
	if (!success) {
		post("could not create the audio processor.\n");
		gAudioState = -1;
		return;
	}
	int outputChannelCounts[1] = { 2 };
	EmscriptenAudioWorkletNodeCreateOptions options = {};
	options.numberOfInputs = 0;
	options.numberOfOutputs = 1;
	options.outputChannelCounts = outputChannelCounts;
	EMSCRIPTEN_AUDIO_WORKLET_NODE_T node = emscripten_create_wasm_audio_worklet_node(context, "sapf", &options, &processAudio, nullptr);
	emscripten_audio_node_connect(node, context, 0, 0);
	gAudioState = 1;
}

static void audioThreadStarted(EMSCRIPTEN_WEBAUDIO_T context, bool success, void* userData)
{
	if (!success) {
		post("could not start the audio thread.\n");
		gAudioState = -1;
		return;
	}
	WebAudioWorkletProcessorCreateOptions options = {};
	options.name = "sapf";
	emscripten_create_wasm_audio_worklet_processor_async(context, &options, &audioProcessorCreated, nullptr);
}

////////////////////////////////////////////////////////////////////////////////////////////////////
// Exports.

extern "C" {

// Create the audio context and audio thread, then start the interpreter on its own thread at the context's
// sample rate, loading the prelude. Returns the sample rate. The page resumes the context after a user gesture.
// latencyHint is "interactive", "balanced" or "playback".
EMSCRIPTEN_KEEPALIVE double sapf_start(const char* preludePath, const char* latencyHint)
{
	if (gStarted) return gSampleRate;
	gStarted = true;

	gPostHook = postToPage;
	gOpenFileHook = openFileOnPage;
	gMidiRequestHook = midiRequestToPage;

	EmscriptenWebAudioCreateAttributes attributes = {};
	std::string hint = latencyHint && *latencyHint ? latencyHint : "interactive";
	attributes.latencyHint = hint.c_str();
	gAudioContext = emscripten_create_audio_context(&attributes);
	gSampleRate = EM_ASM_DOUBLE({ return emscriptenGetAudioObject($0).sampleRate; }, gAudioContext);

	void* audioStack = aligned_alloc(16, kAudioThreadStackSize);
	emscripten_start_wasm_audio_worklet_thread_async(gAudioContext, audioStack, kAudioThreadStackSize, &audioThreadStarted, nullptr);

	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setstacksize(&attr, kInterpreterStackSize);
	pthread_t thread;
	pthread_create(&thread, &attr, interpreterMain, nullptr);
	pthread_attr_destroy(&attr);

	std::string prelude = preludePath ? preludePath : "";
	double sampleRate = gSampleRate;
	enqueue([prelude, sampleRate] {
		post("------------------------------------------------\n");
		post("A tool for the expression of sound as pure form.\n");
		post("------------------------------------------------\n");
		post("--- version %s\n", gVersionString);

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

		// the Thread captures the sample rate when constructed, so make it after setting the rate.
		gThread = new Thread();
		if (const char* log = getenv("SAPF_LOG")) vm.log_file = strdup(log);

		if (!prelude.empty()) {
			vm.prelude_file = strdup(prelude.c_str());
			loadFile(*gThread, vm.prelude_file);
		}

		post("Type 'helpall' to get a list of all built-in functions.\n");
		post("Click a word to see its help.\n\n");
		addResult("{\"id\":0,\"ok\":true," + newHelpLines() + "}");
	});
	return gSampleRate;
}

EMSCRIPTEN_KEEPALIVE int sapf_audio_context() { return (int)gAudioContext; }

// 0 starting, 1 ready, -1 failed.
EMSCRIPTEN_KEEPALIVE int sapf_audio_state() { return gAudioState; }

// Evaluate code at top level, logging it and printing the stack after. The result arrives through sapf_poll()
// with the same id, with any new help lines. The sounds it starts are tagged with tag (0 for none), for
// sapf_stop_tag.
EMSCRIPTEN_KEEPALIVE void sapf_evaluate(const char* code, int id, int tag)
{
	std::string source = code;
	enqueue([source, id, tag] {
		Thread& th = *gThread;
		logCode(th, source);
		bool ok = false;
		setPlayTag(tag);
		try {
			P<Fun> compiledFun;
			if (th.compile(source.c_str(), compiledFun, true)) {
				compiledFun->runREPL(th);
				ok = true;
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
		setPlayTag(0);

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

		addResult("{\"id\":" + std::to_string(id) + (ok ? ",\"ok\":true," : ",\"ok\":false,") + newHelpLines() + "}");
	});
}

// Plot the top of the stack without removing it.
EMSCRIPTEN_KEEPALIVE void sapf_plot(double maxSeconds, int id)
{
	enqueue([maxSeconds, id] {
		addResult("{\"id\":" + std::to_string(id) + ",\"ok\":true," + plotTopOfStack(*gThread, maxSeconds) + "}");
	});
}

// The value of a workspace variable, printed short, or null.
EMSCRIPTEN_KEEPALIVE void sapf_describe_word(const char* word, int id)
{
	std::string name = word;
	enqueue([name, id] {
		std::string json = "{\"id\":" + std::to_string(id) + ",\"ok\":true,\"value\":";
		bool found = false;
		Thread* th = gThread;
		try {
			P<String> sym = getsym(name.c_str());
			V value;
			if (th && th->mWorkspace() && th->mWorkspace->get(*th, sym, value)) {
				std::string out;
				value.printShort(*th, out);
				if (out.size() > 300) out = out.substr(0, 300) + " ...";
				appendJSONString(json, out);
				found = true;
			}
		} catch (...) {
		}
		if (!found) json += "null";
		addResult(json + "}");
	});
}

EMSCRIPTEN_KEEPALIVE void sapf_clear_stack(int id)
{
	enqueue([id] {
		gThread->clearStack();
		addResult("{\"id\":" + std::to_string(id) + ",\"ok\":true}");
	});
}

// Stop all sound. Runs on the calling thread so it works while an evaluation is running.
EMSCRIPTEN_KEEPALIVE void sapf_stop() { stopPlaying(); }

// Stop the sounds started by the evaluation with this tag, and only those. Also immediate.
EMSCRIPTEN_KEEPALIVE void sapf_stop_tag(int tag) { stopPlayingTag(tag); }

// The tags of the sounds playing, into tags (up to max). Returns how many. Doesn't lock.
EMSCRIPTEN_KEEPALIVE int sapf_playing_tags(int* tags, int max) { return playingTags(tags, max); }

EMSCRIPTEN_KEEPALIVE void sapf_restart() { restartPlaying(); }

EMSCRIPTEN_KEEPALIVE void sapf_set_pointer(float x, float y, int down) { setMouseUGenState(x, y, down != 0); }

EMSCRIPTEN_KEEPALIVE void sapf_set_muted(int muted) { setOutputMuted(muted != 0); }

// Feed raw MIDI bytes from the page (Web MIDI) to the MIDI unit generators.
EMSCRIPTEN_KEEPALIVE void sapf_midi_input(int srcIndex, const uint8_t* data, int length) { sapfMidiInput(srcIndex, data, length); }

// The scope: the mono mix of everything playing (see Play.hpp). Both return the number of players.
EMSCRIPTEN_KEEPALIVE int sapf_scope_samples(float* out, int n) { return getScopeSamples(out, n); }
EMSCRIPTEN_KEEPALIVE int sapf_scope_envelope(float* outMin, float* outMax, int n) { return getScopeEnvelope(outMin, outMax, n); }
EMSCRIPTEN_KEEPALIVE int sapf_scope_buffer_size() { return kScopeBufferSize; }
EMSCRIPTEN_KEEPALIVE int sapf_scope_envelope_block_size() { return kScopeEnvelopeBlockSize; }
EMSCRIPTEN_KEEPALIVE int sapf_scope_envelope_blocks() { return kScopeEnvelopeBlocks; }

// Audio timing: out[0] dropouts, out[1] late renders, out[2] peak load (reset if resetPeakLoad).
EMSCRIPTEN_KEEPALIVE void sapf_timing(float* out, int resetPeakLoad)
{
	AudioTimingStats s = getAudioTimingStats(resetPeakLoad != 0);
	out[0] = (float)s.dropouts;
	out[1] = (float)s.lateRenders;
	out[2] = s.peakLoad;
}

// Everything that happened since the last poll, as JSON:
//   { "busy": n, "output": "...", "results": [ {...}, ... ], "open": ["path", ...], "midi": [["connect", uid, index], ...] }
// The returned string stays valid until the next call. Main thread only.
EMSCRIPTEN_KEEPALIVE const char* sapf_poll()
{
	static std::string json;
	std::string output;
	std::vector<std::string> results;
	std::vector<std::string> openPaths;
	std::vector<std::string> midiRequests;
	bool truncated;
	{
		SpinLocker lock(gOutboxLock);
		output.swap(gPendingOutput);
		results.swap(gPendingResults);
		openPaths.swap(gPendingOpenPaths);
		midiRequests.swap(gPendingMidiRequests);
		truncated = gOutputTruncated;
		gOutputTruncated = false;
	}
	if (truncated) output += "\n[some output was dropped]\n";

	json.clear();
	json += "{\"busy\":" + std::to_string(gQueuedRequests.load()) + ",\"output\":";
	appendJSONString(json, output);
	json += ",\"results\":[";
	for (size_t i = 0; i < results.size(); ++i) {
		if (i) json += ',';
		json += results[i];
	}
	json += "],\"open\":[";
	for (size_t i = 0; i < openPaths.size(); ++i) {
		if (i) json += ',';
		appendJSONString(json, openPaths[i]);
	}
	json += "],\"midi\":[";
	for (size_t i = 0; i < midiRequests.size(); ++i) {
		if (i) json += ',';
		json += midiRequests[i];
	}
	json += "]}";
	return json.c_str();
}

} // extern "C"

int main()
{
	// keep the runtime alive after main returns; the page drives everything through the exports.
	emscripten_exit_with_live_runtime();
	return 0;
}
