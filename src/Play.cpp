//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "Play.hpp"
#include "Platform.hpp"
#if SAPF_COREAUDIO
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#endif
#include <pthread.h>
#include <unistd.h>
#include <atomic>
#include <vector>
#include <algorithm>

#include "SoundFiles.hpp"
#include "elapsedTime.hpp"

// Sound output.
//
//   macOS and iOS: each player has its own output AudioUnit; the system mixes them.
//   The web (SAPF_SHARED_MIXER): the host's AudioWorklet calls renderSharedMix(), which mixes every player.
//
// Either way, players are evaluated lazily on the audio thread, each one feeds its own scope tap, and render
// times feed the timing statistics. gPlayerMutex guards the player list; the shared mixer only try-locks it,
// so the audio thread never blocks.

pthread_mutex_t gPlayerMutex = PTHREAD_MUTEX_INITIALIZER;

const int kMaxChannels = 32;

struct AUPlayer* gAllPlayers = nullptr;

// Each player writes a mono mix of its output into its own ring buffer so that
// a front end can display what is playing. One writer per tap, so no locking.
const int kMaxScopeTaps = 64;

struct ScopeTap
{
	std::atomic<bool> inUse{false};
	std::atomic<uint64_t> writePos{0};
	float buf[kScopeBufferSize];

	std::atomic<uint64_t> envelopeWritePos{0};
	float envelopeMin[kScopeEnvelopeBlocks];
	float envelopeMax[kScopeEnvelopeBlocks];
	// The block being accumulated. Only the render thread touches these.
	float blockMin, blockMax;
	int blockCount;
};

static ScopeTap gScopeTaps[kMaxScopeTaps];

static ScopeTap* claimScopeTap()
{
	for (int i = 0; i < kMaxScopeTaps; ++i) {
		ScopeTap& tap = gScopeTaps[i];
		bool expected = false;
		if (tap.inUse.compare_exchange_strong(expected, true)) {
			tap.writePos.store(0);
			tap.envelopeWritePos.store(0);
			tap.blockCount = 0;
			return &tap;
		}
	}
	return nullptr;
}

int getScopeSamples(float* out, int n)
{
	n = std::min(n, kScopeBufferSize);
	memset(out, 0, n * sizeof(float));
	int numActive = 0;
	for (int i = 0; i < kMaxScopeTaps; ++i) {
		ScopeTap& tap = gScopeTaps[i];
		if (!tap.inUse.load(std::memory_order_acquire)) continue;
		++numActive;
		uint64_t end = tap.writePos.load(std::memory_order_acquire);
		int avail = (int)std::min<uint64_t>(end, n);
		float* dst = out + n - avail;
		uint64_t pos = end - avail;
		for (int j = 0; j < avail; ++j) {
			dst[j] += tap.buf[(pos + j) & (kScopeBufferSize - 1)];
		}
	}
	return numActive;
}

int getScopeEnvelope(float* outMin, float* outMax, int n)
{
	n = std::min(n, kScopeEnvelopeBlocks);
	memset(outMin, 0, n * sizeof(float));
	memset(outMax, 0, n * sizeof(float));
	int numActive = 0;
	for (int i = 0; i < kMaxScopeTaps; ++i) {
		ScopeTap& tap = gScopeTaps[i];
		if (!tap.inUse.load(std::memory_order_acquire)) continue;
		++numActive;
		uint64_t end = tap.envelopeWritePos.load(std::memory_order_acquire);
		int avail = (int)std::min<uint64_t>(end, n);
		uint64_t pos = end - avail;
		for (int j = 0; j < avail; ++j) {
			int k = (pos + j) & (kScopeEnvelopeBlocks - 1);
			outMin[n - avail + j] += tap.envelopeMin[k];
			outMax[n - avail + j] += tap.envelopeMax[k];
		}
	}
	return numActive;
}

static std::atomic<uint32_t> gAudioDropouts{0};
static std::atomic<uint32_t> gLateRenders{0};
static std::atomic<float> gPeakRenderLoad{0.f};

AudioTimingStats getAudioTimingStats(bool resetPeakLoad)
{
	return {
		gAudioDropouts.load(std::memory_order_relaxed),
		gLateRenders.load(std::memory_order_relaxed),
		resetPeakLoad ? gPeakRenderLoad.exchange(0.f, std::memory_order_relaxed)
		              : gPeakRenderLoad.load(std::memory_order_relaxed)
	};
}

// a clock for measuring render times, in seconds.
static double renderClock()
{
#if SAPF_COREAUDIO
	static double secondsPerTick = [] {
		mach_timebase_info_data_t info;
		mach_timebase_info(&info);
		return 1e-9 * info.numer / info.denom;
	}();
	return mach_absolute_time() * secondsPerTick;
#else
	return elapsedTime(); // never throws, even on the audio worklet
#endif
}

static void noteLoad(float load)
{
	if (load > 1.f) gLateRenders.fetch_add(1, std::memory_order_relaxed);
	float peak = gPeakRenderLoad.load(std::memory_order_relaxed);
	while (load > peak && !gPeakRenderLoad.compare_exchange_weak(peak, load, std::memory_order_relaxed)) {}
}

static void noteRenderTime(double startSeconds, int numFrames)
{
	double seconds = renderClock() - startSeconds;
#if SAPF_SHARED_MIXER
	// The browser's audio thread only has a millisecond clock, and renders are about 3 ms, so measure the load
	// over windows of several renders. Only the audio thread calls this.
	static double windowSeconds = 0.;
	static int windowFrames = 0;
	windowSeconds += seconds;
	windowFrames += numFrames;
	if (windowFrames < 8192) return;
	float load = (float)(windowSeconds * vm.ar.sampleRate / windowFrames);
	windowSeconds = 0.;
	windowFrames = 0;
	noteLoad(load);
#else
	noteLoad((float)(seconds * vm.ar.sampleRate / numFrames));
#endif
}



struct AUPlayer
{
	AUPlayer(Thread& inThread, int inNumChannels, SoundFileWriter* inRecording = nullptr)
		: th(inThread), count(0), done(false), prev(nullptr), next(gAllPlayers), numChannels(inNumChannels), recording(inRecording)
	{
		gAllPlayers = this;
		if (next) next->prev = this;
		scopeTap = claimScopeTap();
	}

	~AUPlayer() {
		if (next) next->prev = prev;

		if (prev) prev->next = next;
		else gAllPlayers = next;

		if (recording) {
			sfclose(recording);
			openFileExternally(path.c_str());
		}
		if (scopeTap) scopeTap->inUse.store(false, std::memory_order_release);
	}

	Thread th;
	int count;
	bool done;
	AUPlayer* prev;
	AUPlayer* next;
#if SAPF_COREAUDIO
	AudioComponentInstance outputUnit = nullptr;
#endif
	int numChannels;
	ZIn in[kMaxChannels];
	SoundFileWriter* recording = nullptr;
	std::string path;
	ScopeTap* scopeTap = nullptr;
	double nextSampleTime = -1.;
#if SAPF_SHARED_MIXER
	// with the shared mixer each player renders into its own buffers first.
	std::vector<float> scratch;
	float* bufs[kMaxChannels] = {};
#endif
};

static void stopPlayer(AUPlayer* player)
{
#if SAPF_COREAUDIO
	AudioComponentInstance outputUnit = player->outputUnit;
	player->outputUnit = nullptr;
	if (outputUnit) {

		OSStatus err = AudioOutputUnitStop(outputUnit);
		if (err) post("AudioOutputUnitStop err %d\n", (int)err);
		err = AudioComponentInstanceDispose(outputUnit);
		if (err) post("AudioComponentInstanceDispose outputUnit err %d\n", (int)err);

	}
#endif
	delete player;
}

void stopPlaying()
{
	Locker lock(&gPlayerMutex);

	AUPlayer* player = gAllPlayers;
	while (player) {
		AUPlayer* next = player->next;
		stopPlayer(player);
		player = next;
	}
}

void stopPlayingIfDone()
{
	Locker lock(&gPlayerMutex);

	AUPlayer* player = gAllPlayers;
	while (player) {
		AUPlayer* next = player->next;
		if (player->done)
			stopPlayer(player);
		player = next;
	}
}

void restartPlaying()
{
	Locker lock(&gPlayerMutex);

	for (AUPlayer* player = gAllPlayers; player; player = player->next) {
		if (player->done) continue;
		// The gap while stopped isn't a dropout.
		player->nextSampleTime = -1.;
#if SAPF_COREAUDIO
		if (!player->outputUnit) continue;
		OSStatus err = AudioOutputUnitStart(player->outputUnit);
		if (err) post("AudioOutputUnitStart err %d\n", (int)err);
#endif
	}
}

static void* stopDonePlayers(void* x)
{
#if SAPF_EXTAUDIOFILE
	while(1) {
		sleep(1);
		stopPlayingIfDone();
	}
#else
	// recordings are written out from here, so wake more often than once a second.
	for (int tick = 1; ; ++tick) {
		usleep(100000);
		sfserviceAsync();
		if (tick % 10 == 0) stopPlayingIfDone();
	}
#endif
	return nullptr;
}

bool gWatchdogRunning = false;
pthread_t watchdog;

// fill numBufs output buffers of n frames from the player's inputs. returns true when the player is done.
static bool fillBuffers(AUPlayer* player, int inNumberFrames, float* const* bufs, int numBufs)
{
	if (player->done) {
zeroAll:
		for (int i = 0; i < numBufs; ++i) {
			memset(bufs[i], 0, inNumberFrames * sizeof(float));
		}
		return true;
	}
	ZIn* in = player->in;
	bool done = true;
	for (int i = 0; i < numBufs; ++i) {
		int n = inNumberFrames;
		if (i >= player->numChannels) {
			memset(bufs[i], 0, inNumberFrames * sizeof(float));
		} else {
			try {
				float* buf = bufs[i];
				bool imdone = in[i].fill(player->th, n, buf, 1);
				if (n < inNumberFrames) {
					memset(buf + n, 0, (inNumberFrames - n) * sizeof(float));
				}
				done = done && imdone;
			} catch (int err) {
				if (err <= -1000 && err > -1000 - kNumErrors) {
					post("\nerror: %s\n", errString[-1000 - err]);
				} else {
					post("\nerror: %d\n", err);
				}
				post("exception in real time. stopping player.\n");
				done = true;
				goto zeroAll;
			} catch (std::bad_alloc& xerr) {
				post("\nnot enough memory\n");
				post("exception in real time. stopping player.\n");
				done = true;
				goto zeroAll;
			} catch (...) {
				post("\nunknown error\n");
				post("exception in real time. stopping player.\n");
				done = true;
				goto zeroAll;
			}
		}
	}

	return done;
}

static void recordPlayer(AUPlayer* player, int inNumberFrames, float* const* bufs)
{
	if (!player->recording) return;
	sfwriteAsync(player->recording, bufs, inNumberFrames);
}

static void tapPlayer(AUPlayer* player, int inNumberFrames, float* const* bufs, int numBufs)
{
	ScopeTap* tap = player->scopeTap;
	if (!tap) return;

	int numChannels = std::min(numBufs, player->numChannels);
	uint64_t pos = tap->writePos.load(std::memory_order_relaxed);
	uint64_t envelopePos = tap->envelopeWritePos.load(std::memory_order_relaxed);
	for (int i = 0; i < inNumberFrames; ++i) {
		float sum = 0.f;
		for (int j = 0; j < numChannels; ++j) {
			sum += bufs[j][i];
		}
		tap->buf[(pos + i) & (kScopeBufferSize - 1)] = sum;

		if (tap->blockCount == 0) {
			tap->blockMin = tap->blockMax = sum;
		} else {
			tap->blockMin = std::min(tap->blockMin, sum);
			tap->blockMax = std::max(tap->blockMax, sum);
		}
		if (++tap->blockCount == kScopeEnvelopeBlockSize) {
			int k = envelopePos & (kScopeEnvelopeBlocks - 1);
			tap->envelopeMin[k] = tap->blockMin;
			tap->envelopeMax[k] = tap->blockMax;
			++envelopePos;
			tap->blockCount = 0;
		}
	}
	tap->writePos.store(pos + inNumberFrames, std::memory_order_release);
	tap->envelopeWritePos.store(envelopePos, std::memory_order_release);
}

#if SAPF_SHARED_MIXER

const int kMaxRenderFrames = 4096;
static std::atomic<bool> gOutputMuted { false };

void setOutputMuted(bool muted)
{
	gOutputMuted = muted;
}

static void preparePlayerBuffers(AUPlayer* player)
{
	int numChannels = player->numChannels;
	player->scratch.assign((size_t)numChannels * kMaxRenderFrames, 0.f);
	for (int i = 0; i < numChannels; ++i) {
		player->bufs[i] = player->scratch.data() + (size_t)i * kMaxRenderFrames;
	}
}

void renderSharedMix(float* outL, float* outR, int inNumberFrames)
{
	double start = renderClock();
	memset(outL, 0, inNumberFrames * sizeof(float));
	if (outR != outL) memset(outR, 0, inNumberFrames * sizeof(float));

	// never block the audio thread. if a player is being added or removed, skip mixing for this buffer.
	if (pthread_mutex_trylock(&gPlayerMutex) == 0) {
		for (int offset = 0; offset < inNumberFrames; offset += kMaxRenderFrames) {
			int n = std::min(kMaxRenderFrames, inNumberFrames - offset);
			for (AUPlayer* player = gAllPlayers; player; player = player->next) {
				if (player->done || player->scratch.empty()) continue;
				if (fillBuffers(player, n, player->bufs, player->numChannels)) player->done = true;
				recordPlayer(player, n, player->bufs);
				tapPlayer(player, n, player->bufs, player->numChannels);
				// mono to both sides; otherwise channels alternate left and right.
				if (player->numChannels == 1) {
					float* in = player->bufs[0];
					for (int i = 0; i < n; ++i) { outL[offset+i] += in[i]; }
					if (outR != outL) for (int i = 0; i < n; ++i) { outR[offset+i] += in[i]; }
				} else {
					for (int c = 0; c < player->numChannels; ++c) {
						float* in = player->bufs[c];
						float* out = (c & 1) ? outR : outL;
						for (int i = 0; i < n; ++i) { out[offset+i] += in[i]; }
					}
				}
			}
		}
		bool anyPlaying = gAllPlayers != nullptr;
		pthread_mutex_unlock(&gPlayerMutex);
		if (anyPlaying) noteRenderTime(start, inNumberFrames);
	}

	if (gOutputMuted) {
		memset(outL, 0, inNumberFrames * sizeof(float));
		if (outR != outL) memset(outR, 0, inNumberFrames * sizeof(float));
	}
}

int numPlayersPlaying()
{
	Locker lock(&gPlayerMutex);
	int count = 0;
	for (AUPlayer* player = gAllPlayers; player; player = player->next) {
		if (!player->done) ++count;
	}
	return count;
}

#endif // SAPF_SHARED_MIXER

#if SAPF_COREAUDIO

static OSStatus inputCallback(	void *							inRefCon,
						AudioUnitRenderActionFlags *	ioActionFlags,
						const AudioTimeStamp *			inTimeStamp,
						UInt32							inBusNumber,
						UInt32							inNumberFrames,
						AudioBufferList *				ioData)
{

	AUPlayer* player = (AUPlayer*)inRefCon;
	double start = renderClock();

	// When a render runs late, the next one starts later than where this one ended.
	if (inTimeStamp->mFlags & kAudioTimeStampSampleTimeValid) {
		if (player->nextSampleTime >= 0. && inTimeStamp->mSampleTime > player->nextSampleTime + 0.5)
			gAudioDropouts.fetch_add(1, std::memory_order_relaxed);
		player->nextSampleTime = inTimeStamp->mSampleTime + inNumberFrames;
	}

	float* bufs[kMaxChannels];
	int numBufs = std::min((int)ioData->mNumberBuffers, kMaxChannels);
	for (int i = 0; i < numBufs; ++i) bufs[i] = (float*)ioData->mBuffers[i].mData;

	bool done = fillBuffers(player, inNumberFrames, bufs, numBufs);
	recordPlayer(player, inNumberFrames, bufs);
	tapPlayer(player, inNumberFrames, bufs, numBufs);
	noteRenderTime(start, inNumberFrames);

	if (done) {
		player->done = true;
	}
	return noErr;
}


static AudioComponentInstance openAU(UInt32 inType, UInt32 inSubtype, UInt32 inManuf)
{
    AudioComponentDescription desc;
    desc.componentType = inType;
    desc.componentSubType = inSubtype;
    desc.componentManufacturer = inManuf;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;

    AudioComponent comp = AudioComponentFindNext(nullptr, &desc);
	if (!comp) {
		return nullptr;
	}

    AudioComponentInstance au = nullptr;
    AudioComponentInstanceNew(comp, &au);

	return au;
}

#endif // SAPF_COREAUDIO

typedef int PlayStatus; // 0 or an OSStatus

static PlayStatus createGraph(AUPlayer* player)
{
#if SAPF_SHARED_MIXER
	preparePlayerBuffers(player);
	return 0; // the host's audio callback calls renderSharedMix().
#else
    OSStatus err = noErr;
#if SAPF_IOS
	AudioComponentInstance outputUnit = openAU(kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple);
#else
	AudioComponentInstance outputUnit = openAU('auou', 'def ', 'appl');
#endif
	if (!outputUnit) {
		post("open output unit failed\n");
		return 'fail';
	}

	player->outputUnit = outputUnit;

	UInt32 flags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
	AudioStreamBasicDescription fmt = { vm.ar.sampleRate, kAudioFormatLinearPCM, flags, 4, 1, 4, (UInt32)player->numChannels, 32, 0 };

	err = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt, sizeof(fmt));
	if (err) {
		post("set outputUnit client format failed\n");
		return err;
	}

	AURenderCallbackStruct cbs;

	cbs.inputProc = inputCallback;
	cbs.inputProcRefCon = player;

	err = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cbs, sizeof(cbs));
	if (err) {
		post("set render callback failed\n");
		return err;
	}

	err = AudioUnitInitialize(outputUnit);
	if (err) {
		post("initialize output unit failed\n");
		return err;
	}

	err = AudioOutputUnitStart(outputUnit);
	if (err) {
		post("start output unit failed\n");
		return err;
	}

	post("start output unit OK\n");

	return noErr;
#endif
}

static void startWatchdog()
{
	if (!gWatchdogRunning) {
		pthread_create(&watchdog, nullptr, stopDonePlayers, nullptr);
		gWatchdogRunning = true;
	}
}

void playWithAudioUnit(Thread& th, V& v)
{
	if (!v.isList()) wrongType("play : s", "List", v);

	Locker lock(&gPlayerMutex);

	AUPlayer *player;

	if (v.isZList()) {
		player = new AUPlayer(th, 1);
		player->in[0].set(v);
		player->numChannels = 1;
	} else {
		if (!v.isFinite()) indefiniteOp("play : s", "");
		P<List> s = (List*)v.o();
		s = s->pack(th, kMaxChannels);
		if (!s()) {
			post("Too many channels. Max is %d.\n", kMaxChannels);
			return;
		}
		Array* a = s->mArray();

		int asize = (int)a->size();

		player = new AUPlayer(th, asize);
		for (int i = 0; i < asize; ++i) {
			player->in[i].set(a->at(i));
		}
		s = nullptr;
		a = nullptr;
	}
	v.o = nullptr; // try to prevent leak.

    std::atomic_thread_fence(std::memory_order_seq_cst);

	startWatchdog();

	{
		PlayStatus err = createGraph(player);
		if (err) {
			post("play failed: %d '%4.4s'\n", (int)err, (char*)&err);
			throw errFailed;
		}
	}
}


void recordWithAudioUnit(Thread& th, V& v, Arg filename)
{
	if (!v.isList()) wrongType("play : s", "List", v);

	Locker lock(&gPlayerMutex);

	AUPlayer *player;

	char path[1024];
	SoundFileWriter* recording = nullptr;

	if (v.isZList()) {
		makeRecordingPath(filename, path, 1024);
		recording = sfcreate(th, path, 1, 0., false);
		if (!recording) {
			post("couldn't create recording file \"%s\"\n", path);
			return;
		}

		player = new AUPlayer(th, 1, recording);
		player->in[0].set(v);
		player->numChannels = 1;
	} else {
		if (!v.isFinite()) indefiniteOp("play : s", "");
		P<List> s = (List*)v.o();
		s = s->pack(th, kMaxChannels);
		if (!s()) {
			post("Too many channels. Max is %d.\n", kMaxChannels);
			return;
		}
		Array* a = s->mArray();

		int numChannels = (int)a->size();

		makeRecordingPath(filename, path, 1024);
		recording = sfcreate(th, path, numChannels, 0., false);
		if (!recording) {
			post("couldn't create recording file \"%s\"\n", path);
			return;
		}

		player = new AUPlayer(th, numChannels, recording);
		for (int i = 0; i < numChannels; ++i) {
			player->in[i].set(a->at(i));
		}
		s = nullptr;
		a = nullptr;
	}
	v.o = nullptr; // try to prevent leak.

	player->path = path;

	sfbeginAsync(recording);

    std::atomic_thread_fence(std::memory_order_seq_cst);

	startWatchdog();

	{
		PlayStatus err = createGraph(player);
		if (err) {
			post("play failed: %d '%4.4s'\n", (int)err, (char*)&err);
			throw errFailed;
		}
	}
}
