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

#include "Play.hpp"
#include <AudioToolbox/AudioToolbox.h>
#include <pthread.h>
#include <mach/mach_time.h>
#include <atomic>

#include "SoundFiles.hpp"

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
};

static ScopeTap gScopeTaps[kMaxScopeTaps];

static ScopeTap* claimScopeTap()
{
	for (int i = 0; i < kMaxScopeTaps; ++i) {
		ScopeTap& tap = gScopeTaps[i];
		bool expected = false;
		if (tap.inUse.compare_exchange_strong(expected, true)) {
			tap.writePos.store(0);
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

static double hostTicksToSeconds()
{
	static double secondsPerTick = [] {
		mach_timebase_info_data_t info;
		mach_timebase_info(&info);
		return 1e-9 * info.numer / info.denom;
	}();
	return secondsPerTick;
}

static void noteRenderTime(uint64_t startTicks, UInt32 numFrames)
{
	double seconds = (mach_absolute_time() - startTicks) * hostTicksToSeconds();
	float load = (float)(seconds * vm.ar.sampleRate / numFrames);
	if (load > 1.f) gLateRenders.fetch_add(1, std::memory_order_relaxed);
	float peak = gPeakRenderLoad.load(std::memory_order_relaxed);
	while (load > peak && !gPeakRenderLoad.compare_exchange_weak(peak, load, std::memory_order_relaxed)) {}
}



struct AUPlayer
{
	AUPlayer(Thread& inThread, int inNumChannels, ExtAudioFileRef inXAFRef = nullptr)
		: th(inThread), count(0), done(false), prev(nullptr), next(gAllPlayers), outputUnit(nullptr), numChannels(inNumChannels), xaf(inXAFRef)
	{ 
		gAllPlayers = this; 
		if (next) next->prev = this; 
		scopeTap = claimScopeTap();
	}
	
	~AUPlayer() {
		if (next) next->prev = prev;

		if (prev) prev->next = next;
		else gAllPlayers = next;
		
		if (xaf) {
			ExtAudioFileDispose(xaf);
			openFileExternally(path.c_str());
		}
		if (scopeTap) scopeTap->inUse.store(false, std::memory_order_release);
	}
	
	Thread th;
	int count;
	bool done;
	AUPlayer* prev;
	AUPlayer* next;
	AudioComponentInstance outputUnit;
	int numChannels;
	ZIn in[kMaxChannels];
	ExtAudioFileRef xaf = nullptr;
	std::string path;
	ScopeTap* scopeTap = nullptr;
	Float64 nextSampleTime = -1.;
};

static void stopPlayer(AUPlayer* player)
{
	AudioComponentInstance outputUnit = player->outputUnit;
	player->outputUnit = nullptr;
	if (outputUnit) {
	
		OSStatus err = AudioOutputUnitStop(outputUnit);
		if (err) post("AudioOutputUnitStop err %d\n", (int)err);
		err = AudioComponentInstanceDispose(outputUnit);
		if (err) post("AudioComponentInstanceDispose outputUnit err %d\n", (int)err);
		
	}
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

static void* stopDonePlayers(void* x)
{
	while(1) {
		sleep(1);
		stopPlayingIfDone();
	}
	return nullptr;
}

bool gWatchdogRunning = false;
pthread_t watchdog;

static bool fillBufferList(AUPlayer* player, int inNumberFrames, AudioBufferList* ioData)
{
	if (player->done) {
zeroAll:
		for (int i = 0; i < (int)ioData->mNumberBuffers; ++i) {
			memset((float*)ioData->mBuffers[i].mData, 0, inNumberFrames * sizeof(float));
		}
		return true;
	}
	ZIn* in = player->in;
	bool done = true;
	for (int i = 0; i < (int)ioData->mNumberBuffers; ++i) {
		int n = inNumberFrames;
		if (i >= player->numChannels) {
			memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
		} else {
			try {
				float* buf = (float*)ioData->mBuffers[i].mData;
				bool imdone = in[i].fill(player->th, n, buf, 1);
				if (n < inNumberFrames) {
					memset((float*)ioData->mBuffers[i].mData + n, 0, (inNumberFrames - n) * sizeof(float));
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

static void recordPlayer(AUPlayer* player, int inNumberFrames, AudioBufferList const* inData)
{
	if (!player->xaf) return;
		
	OSStatus err = ExtAudioFileWriteAsync(player->xaf, inNumberFrames, inData); // initialize async.
	if (err) printf("ExtAudioFileWriteAsync err %d\n", (int)err);
}

static void tapPlayer(AUPlayer* player, int inNumberFrames, AudioBufferList const* inData)
{
	ScopeTap* tap = player->scopeTap;
	if (!tap) return;

	int numChannels = std::min((int)inData->mNumberBuffers, player->numChannels);
	uint64_t pos = tap->writePos.load(std::memory_order_relaxed);
	for (int i = 0; i < inNumberFrames; ++i) {
		float sum = 0.f;
		for (int j = 0; j < numChannels; ++j) {
			sum += ((const float*)inData->mBuffers[j].mData)[i];
		}
		tap->buf[(pos + i) & (kScopeBufferSize - 1)] = sum;
	}
	tap->writePos.store(pos + inNumberFrames, std::memory_order_release);
}

static OSStatus inputCallback(	void *							inRefCon,
						AudioUnitRenderActionFlags *	ioActionFlags,
						const AudioTimeStamp *			inTimeStamp,
						UInt32							inBusNumber,
						UInt32							inNumberFrames,
						AudioBufferList *				ioData)
{
	
	AUPlayer* player = (AUPlayer*)inRefCon;
	uint64_t startTicks = mach_absolute_time();

	// When a render runs late, the next one starts later than where this one ended.
	if (inTimeStamp->mFlags & kAudioTimeStampSampleTimeValid) {
		if (player->nextSampleTime >= 0. && inTimeStamp->mSampleTime > player->nextSampleTime + 0.5)
			gAudioDropouts.fetch_add(1, std::memory_order_relaxed);
		player->nextSampleTime = inTimeStamp->mSampleTime + inNumberFrames;
	}

	bool done = fillBufferList(player, inNumberFrames, ioData);
	recordPlayer(player, inNumberFrames, ioData);
	tapPlayer(player, inNumberFrames, ioData);
	noteRenderTime(startTicks, inNumberFrames);

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

static OSStatus createGraph(AUPlayer* player)
{
    OSStatus err = noErr;
#if TARGET_OS_IPHONE
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
		
	if (!gWatchdogRunning) {
		pthread_create(&watchdog, nullptr, stopDonePlayers, nullptr);
		gWatchdogRunning = true;
	}

	{
		OSStatus err = noErr;
		err = createGraph(player);
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
	ExtAudioFileRef xaf = nullptr;
	
	if (v.isZList()) {
		makeRecordingPath(filename, path, 1024);
		xaf = sfcreate(th, path, 1, 0., false);
		if (!xaf) {
			printf("couldn't create recording file \"%s\"\n", path);
			return;
		}

		player = new AUPlayer(th, 1, xaf);
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
		xaf = sfcreate(th, path, numChannels, 0., false);
		if (!xaf) {
			printf("couldn't create recording file \"%s\"\n", path);
			return;
		}
		
		player = new AUPlayer(th, numChannels, xaf);
		for (int i = 0; i < numChannels; ++i) {
			player->in[i].set(a->at(i));
		}
		s = nullptr;
		a = nullptr;
	}
	v.o = nullptr; // try to prevent leak.

	player->path = path;

	{
		OSStatus err = ExtAudioFileWriteAsync(xaf, 0, nullptr); // initialize async.
		if (err) printf("init ExtAudioFileWriteAsync err %d\n", (int)err);
    }
	
    std::atomic_thread_fence(std::memory_order_seq_cst);
		
	if (!gWatchdogRunning) {
		pthread_create(&watchdog, nullptr, stopDonePlayers, nullptr);
		gWatchdogRunning = true;
	}

	{
		OSStatus err = noErr;
		err = createGraph(player);
		if (err) {
			post("play failed: %d '%4.4s'\n", (int)err, (char*)&err);
			throw errFailed;
		}
	}
}

