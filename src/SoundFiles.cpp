//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "SoundFiles.hpp"
#include <valarray>
#include <vector>
#include <atomic>
#include <mutex>
#include <algorithm>
#include <cmath>
#include <string>
#include <sys/stat.h>
#include "Platform.hpp"

extern char gSessionTime[256];

////////////////////////////////////////////////////////////////////////////////////////////////////
// Backends.
//
// A reader delivers non-interleaved doubles at the thread's sample rate.
// A writer takes float frames and writes a 32 bit float WAV file.

struct SoundFileReader;
static SoundFileReader* sfopenRead(Thread& th, const char* path, int64_t offset, int& outNumChannels);
// read up to numFrames into chans[c]. returns the number of frames read, 0 at the end or on error.
static int sfreadFrames(SoundFileReader* r, double* const* chans, int numFrames);
static void sfcloseRead(SoundFileReader* r);

#if SAPF_EXTAUDIOFILE

#include <AudioToolbox/ExtendedAudioFile.h>

struct SoundFileReader
{
	ExtAudioFileRef xaf;
	int numChannels;
	std::vector<uint8_t> ablStorage;
};

static SoundFileReader* sfopenRead(Thread& th, const char* path, int64_t offset, int& outNumChannels)
{
	CFStringRef cfpath = CFStringCreateWithFileSystemRepresentation(0, path);
	if (!cfpath) {
		post("failed to create path\n");
		return nullptr;
	}
	CFReleaser cfpathReleaser(cfpath);

	CFURLRef url = CFURLCreateWithFileSystemPath(0, cfpath, kCFURLPOSIXPathStyle, false);
	if (!url) {
		post("failed to create url\n");
		return nullptr;
	}
	CFReleaser urlReleaser(url);

	ExtAudioFileRef xaf;
	OSStatus err = ExtAudioFileOpenURL(url, &xaf);

	cfpathReleaser.release();
	urlReleaser.release();

	if (err) {
		post("failed to open file %d\n", (int)err);
		return nullptr;
	}

	AudioStreamBasicDescription fileFormat;

	UInt32 propSize = sizeof(fileFormat);
	err = ExtAudioFileGetProperty(xaf, kExtAudioFileProperty_FileDataFormat, &propSize, &fileFormat);

	int numChannels = fileFormat.mChannelsPerFrame;

	AudioStreamBasicDescription clientFormat = {
		th.rate.sampleRate,
		kAudioFormatLinearPCM,
		kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
		static_cast<UInt32>(sizeof(double)),
		1,
		static_cast<UInt32>(sizeof(double)),
		static_cast<UInt32>(numChannels),
		64,
		0
	};

	err = ExtAudioFileSetProperty(xaf, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFormat), &clientFormat);
	if (err) {
		post("failed to set client data format\n");
		ExtAudioFileDispose(xaf);
		return nullptr;
	}

	err = ExtAudioFileSeek(xaf, offset);
	if (err) {
		post("seek failed %d\n", (int)err);
		ExtAudioFileDispose(xaf);
		return nullptr;
	}

	SoundFileReader* r = new SoundFileReader;
	r->xaf = xaf;
	r->numChannels = numChannels;
	r->ablStorage.assign(sizeof(AudioBufferList) + std::max(0, numChannels - 1) * sizeof(AudioBuffer), 0);
	outNumChannels = numChannels;
	return r;
}

static int sfreadFrames(SoundFileReader* r, double* const* chans, int numFrames)
{
	AudioBufferList* abl = (AudioBufferList*)r->ablStorage.data();
	abl->mNumberBuffers = r->numChannels;
	for (int i = 0; i < r->numChannels; ++i) {
		abl->mBuffers[i].mNumberChannels = 1;
		abl->mBuffers[i].mData = chans[i];
		abl->mBuffers[i].mDataByteSize = (UInt32)(numFrames * sizeof(double));
	}
	UInt32 framesRead = numFrames;
	OSStatus err = ExtAudioFileRead(r->xaf, &framesRead, abl);
	if (err) return 0;
	return (int)framesRead;
}

static void sfcloseRead(SoundFileReader* r)
{
	ExtAudioFileDispose(r->xaf);
	delete r;
}

struct SoundFileWriter
{
	ExtAudioFileRef xaf;
	int numChannels;
	bool interleaved;
};

SoundFileWriter* sfcreate(Thread& th, const char* path, int numChannels, double fileSampleRate, bool interleaved)
{
	if (fileSampleRate == 0.)
		fileSampleRate = th.rate.sampleRate;

	CFStringRef cfpath = CFStringCreateWithFileSystemRepresentation(0, path);
	if (!cfpath) {
		post("failed to create path '%s'\n", path);
		return nullptr;
	}
	CFReleaser cfpathReleaser(cfpath);

	CFURLRef url = CFURLCreateWithFileSystemPath(0, cfpath, kCFURLPOSIXPathStyle, false);
	if (!url) {
		post("failed to create url\n");
		return nullptr;
	}
	CFReleaser urlReleaser(url);

	AudioStreamBasicDescription fileFormat = {
		fileSampleRate,
		kAudioFormatLinearPCM,
		kAudioFormatFlagsNativeFloatPacked,
		static_cast<UInt32>(sizeof(float) * numChannels),
		1,
		static_cast<UInt32>(sizeof(float) * numChannels),
		static_cast<UInt32>(numChannels),
		32,
		0
	};

	int interleavedChannels = interleaved ? numChannels : 1;
	UInt32 interleavedBit = interleaved ? 0 : kAudioFormatFlagIsNonInterleaved;

	AudioStreamBasicDescription clientFormat = {
		th.rate.sampleRate,
		kAudioFormatLinearPCM,
		kAudioFormatFlagsNativeFloatPacked | interleavedBit,
		static_cast<UInt32>(sizeof(float) * interleavedChannels),
		1,
		static_cast<UInt32>(sizeof(float) * interleavedChannels),
		static_cast<UInt32>(numChannels),
		32,
		0
	};

	ExtAudioFileRef xaf;
	OSStatus err = ExtAudioFileCreateWithURL(url, kAudioFileWAVEType, &fileFormat, nullptr, kAudioFileFlags_EraseFile, &xaf);

	if (err) {
		post("failed to create file '%s'. err: %d\n", path, (int)err);
		return nullptr;
	}

	err = ExtAudioFileSetProperty(xaf, kExtAudioFileProperty_ClientDataFormat, sizeof(clientFormat), &clientFormat);
	if (err) {
		post("failed to set client data format\n");
		ExtAudioFileDispose(xaf);
		return nullptr;
	}

	SoundFileWriter* w = new SoundFileWriter;
	w->xaf = xaf;
	w->numChannels = numChannels;
	w->interleaved = interleaved;
	return w;
}

// an AudioBufferList with room for enough channels for players and recordings.
struct BigAudioBufferList
{
	UInt32 mNumberBuffers;
	AudioBuffer mBuffers[64];
};

static AudioBufferList* fillABL(BigAudioBufferList& big, SoundFileWriter* w, float* const* data, int numFrames)
{
	if (w->interleaved) {
		big.mNumberBuffers = 1;
		big.mBuffers[0].mNumberChannels = w->numChannels;
		big.mBuffers[0].mData = data[0];
		big.mBuffers[0].mDataByteSize = (UInt32)(numFrames * w->numChannels * sizeof(float));
	} else {
		int n = std::min(w->numChannels, 64);
		big.mNumberBuffers = n;
		for (int i = 0; i < n; ++i) {
			big.mBuffers[i].mNumberChannels = 1;
			big.mBuffers[i].mData = data[i];
			big.mBuffers[i].mDataByteSize = (UInt32)(numFrames * sizeof(float));
		}
	}
	return (AudioBufferList*)&big;
}

bool sfwriteFrames(SoundFileWriter* w, float* const* data, int numFrames)
{
	BigAudioBufferList big;
	OSStatus err = ExtAudioFileWrite(w->xaf, numFrames, fillABL(big, w, data, numFrames));
	if (err) {
		post("ExtAudioFileWrite failed %d\n", (int)err);
		return false;
	}
	return true;
}

void sfbeginAsync(SoundFileWriter* w)
{
	OSStatus err = ExtAudioFileWriteAsync(w->xaf, 0, nullptr); // initialize async.
	if (err) post("init ExtAudioFileWriteAsync err %d\n", (int)err);
}

void sfwriteAsync(SoundFileWriter* w, float* const* channels, int numFrames)
{
	BigAudioBufferList big;
	OSStatus err = ExtAudioFileWriteAsync(w->xaf, numFrames, fillABL(big, w, channels, numFrames));
	if (err) post("ExtAudioFileWriteAsync err %d\n", (int)err);
}

void sfserviceAsync()
{
	// ExtAudioFile has its own writer thread.
}

void sfclose(SoundFileWriter* w)
{
	if (!w) return;
	ExtAudioFileDispose(w->xaf);
	delete w;
}

#else // portable: dr_wav

#define DR_WAV_IMPLEMENTATION
#include "../third_party/dr_wav.h"

// The whole file is decoded, and converted to the thread's sample rate, when it's opened: reading happens lazily,
// possibly on the audio thread, which must not do file I/O or heavy work.
struct SoundFileReader
{
	int numChannels = 0;
	std::vector<float> samples; // interleaved
	size_t numFrames = 0;
	size_t position = 0;
};

static bool readWholeFile(const char* path, std::vector<uint8_t>& out)
{
	FILE* f = fopen(path, "rb");
	if (!f) return false;
	uint8_t buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, f)) > 0) out.insert(out.end(), buf, buf + n);
	fclose(f);
	return true;
}

// Band limited sample rate conversion of interleaved frames, with a Blackman windowed sinc 16 zero crossings wide
// on each side, cut off just below the lower of the two Nyquist frequencies.
static std::vector<float> resampleFrames(const std::vector<float>& in, size_t inFrames, int numChannels,
                                         double inRate, double outRate, size_t& outFrames)
{
	const double ratio = outRate / inRate;
	const double cutoff = std::min(1., ratio) * 0.97;
	const int kZeroCrossings = 16;
	const int kPhases = 512; // table entries per zero crossing
	std::vector<float> kernel(kZeroCrossings * kPhases + 2, 0.f);
	for (int i = 0; i <= kZeroCrossings * kPhases; ++i) {
		double x = (double)i / kPhases;
		double window = 0.42 + 0.5 * cos(M_PI * x / kZeroCrossings) + 0.08 * cos(2. * M_PI * x / kZeroCrossings);
		double sinc = i == 0 ? 1. : sin(M_PI * x) / (M_PI * x);
		kernel[i] = (float)(sinc * window);
	}

	outFrames = (size_t)std::floor((double)inFrames * ratio);
	std::vector<float> out(outFrames * numChannels);
	std::vector<double> sum(numChannels);
	const double halfWidth = kZeroCrossings / cutoff; // in input frames
	for (size_t j = 0; j < outFrames; ++j) {
		double t = (double)j / ratio;
		int64_t first = std::max<int64_t>(0, (int64_t)std::ceil(t - halfWidth));
		int64_t last = std::min<int64_t>((int64_t)inFrames - 1, (int64_t)std::floor(t + halfWidth));
		std::fill(sum.begin(), sum.end(), 0.);
		for (int64_t i = first; i <= last; ++i) {
			double x = std::abs(t - (double)i) * cutoff * kPhases;
			size_t k = (size_t)x;
			if (k >= (size_t)kZeroCrossings * kPhases) continue;
			double h = kernel[k] + (x - (double)k) * (kernel[k + 1] - kernel[k]);
			const float* frame = &in[(size_t)i * numChannels];
			for (int c = 0; c < numChannels; ++c) sum[c] += h * frame[c];
		}
		float* frame = &out[j * numChannels];
		for (int c = 0; c < numChannels; ++c) frame[c] = (float)(sum[c] * cutoff);
	}
	return out;
}

static SoundFileReader* sfopenRead(Thread& th, const char* path, int64_t offset, int& outNumChannels)
{
	std::vector<uint8_t> fileData;
	if (!readWholeFile(path, fileData)) {
		post("failed to open file '%s'.\n", path);
		return nullptr;
	}
	drwav wav;
	if (!drwav_init_memory(&wav, fileData.data(), fileData.size(), nullptr)) {
		post("failed to open file '%s'. only WAV files can be read in this version.\n", path);
		return nullptr;
	}
	SoundFileReader* r = new SoundFileReader;
	r->numChannels = wav.channels;
	double fileRate = wav.sampleRate;
	r->samples.resize((size_t)wav.totalPCMFrameCount * wav.channels);
	r->numFrames = (size_t)drwav_read_pcm_frames_f32(&wav, wav.totalPCMFrameCount, r->samples.data());
	r->samples.resize(r->numFrames * wav.channels);
	drwav_uninit(&wav);

	if (r->numChannels < 1) {
		post("failed to open file '%s'. it has no channels.\n", path);
		delete r;
		return nullptr;
	}
	if (fileRate > 0. && fileRate != th.rate.sampleRate) {
		size_t frames = 0;
		r->samples = resampleFrames(r->samples, r->numFrames, r->numChannels, fileRate, th.rate.sampleRate, frames);
		r->numFrames = frames;
	}
	// the offset is in frames at the thread's rate, as with ExtAudioFile.
	r->position = (size_t)std::clamp<int64_t>(offset, 0, (int64_t)r->numFrames);
	outNumChannels = r->numChannels;
	return r;
}

static int sfreadFrames(SoundFileReader* r, double* const* chans, int numFrames)
{
	int nc = r->numChannels;
	int n = (int)std::min<size_t>((size_t)std::max(numFrames, 0), r->numFrames - r->position);
	const float* in = r->samples.data() + r->position * nc;
	for (int f = 0; f < n; ++f) {
		for (int c = 0; c < nc; ++c) chans[c][f] = *in++;
	}
	r->position += n;
	return n;
}

static void sfcloseRead(SoundFileReader* r)
{
	delete r;
}

struct SoundFileWriter
{
	drwav wav;
	int numChannels;
	bool interleaved;
	std::vector<float> scratch;   // for interleaving

	// async (recording) ring buffer of interleaved frames. single producer (audio thread), single consumer
	// (whoever holds gAsyncMutex).
	std::vector<float> ring;
	size_t ringFrames = 0;        // power of two
	std::atomic<size_t> writeFrame { 0 };
	std::atomic<size_t> readFrame { 0 };
	std::atomic<size_t> droppedFrames { 0 };
	bool async = false;
};

static std::mutex gAsyncMutex;
static std::vector<SoundFileWriter*> gAsyncWriters;

SoundFileWriter* sfcreate(Thread& th, const char* path, int numChannels, double fileSampleRate, bool interleaved)
{
	if (fileSampleRate == 0.)
		fileSampleRate = th.rate.sampleRate;

	drwav_data_format format;
	format.container = drwav_container_riff;
	format.format = DR_WAVE_FORMAT_IEEE_FLOAT;
	format.channels = (drwav_uint32)numChannels;
	format.sampleRate = (drwav_uint32)fileSampleRate;
	format.bitsPerSample = 32;

	SoundFileWriter* w = new SoundFileWriter;
	if (!drwav_init_file_write(&w->wav, path, &format, nullptr)) {
		post("failed to create file '%s'.\n", path);
		delete w;
		return nullptr;
	}
	w->numChannels = numChannels;
	w->interleaved = interleaved;
	return w;
}

bool sfwriteFrames(SoundFileWriter* w, float* const* data, int numFrames)
{
	const float* frames = data[0];
	if (!w->interleaved) {
		int nc = w->numChannels;
		w->scratch.resize((size_t)numFrames * nc);
		float* out = w->scratch.data();
		for (int f = 0; f < numFrames; ++f)
			for (int c = 0; c < nc; ++c) *out++ = data[c][f];
		frames = w->scratch.data();
	}
	drwav_uint64 written = drwav_write_pcm_frames(&w->wav, (drwav_uint64)numFrames, frames);
	if ((int)written != numFrames) {
		post("sound file write failed\n");
		return false;
	}
	return true;
}

void sfbeginAsync(SoundFileWriter* w)
{
	// about 3 seconds at 48k. drained every 100 ms by the player watchdog thread.
	size_t frames = 1;
	while (frames < 131072) frames <<= 1;
	w->ringFrames = frames;
	w->ring.assign(frames * w->numChannels, 0.f);
	w->async = true;
	std::lock_guard<std::mutex> lock(gAsyncMutex);
	gAsyncWriters.push_back(w);
}

void sfwriteAsync(SoundFileWriter* w, float* const* channels, int numFrames)
{
	size_t wr = w->writeFrame.load(std::memory_order_relaxed);
	size_t rd = w->readFrame.load(std::memory_order_acquire);
	size_t space = w->ringFrames - (wr - rd);
	if ((size_t)numFrames > space) {
		w->droppedFrames.fetch_add(numFrames, std::memory_order_relaxed);
		return;
	}
	int nc = w->numChannels;
	size_t mask = w->ringFrames - 1;
	float* ring = w->ring.data();
	for (int f = 0; f < numFrames; ++f) {
		float* out = ring + ((wr + f) & mask) * nc;
		for (int c = 0; c < nc; ++c) out[c] = channels[c][f];
	}
	w->writeFrame.store(wr + numFrames, std::memory_order_release);
}

// caller holds gAsyncMutex.
static void drainAsync(SoundFileWriter* w)
{
	size_t rd = w->readFrame.load(std::memory_order_relaxed);
	size_t wr = w->writeFrame.load(std::memory_order_acquire);
	size_t mask = w->ringFrames - 1;
	int nc = w->numChannels;
	while (rd != wr) {
		size_t start = rd & mask;
		size_t n = std::min(wr - rd, w->ringFrames - start); // contiguous run
		drwav_write_pcm_frames(&w->wav, (drwav_uint64)n, w->ring.data() + start * nc);
		rd += n;
	}
	w->readFrame.store(rd, std::memory_order_release);
}

void sfserviceAsync()
{
	std::lock_guard<std::mutex> lock(gAsyncMutex);
	for (SoundFileWriter* w : gAsyncWriters) drainAsync(w);
}

void sfclose(SoundFileWriter* w)
{
	if (!w) return;
	if (w->async) {
		std::lock_guard<std::mutex> lock(gAsyncMutex);
		drainAsync(w);
		gAsyncWriters.erase(std::remove(gAsyncWriters.begin(), gAsyncWriters.end(), w), gAsyncWriters.end());
		size_t dropped = w->droppedFrames.load();
		if (dropped) post("warning: recording dropped %zu frames.\n", dropped);
	}
	drwav_uninit(&w->wav);
	delete w;
}

#endif

////////////////////////////////////////////////////////////////////////////////////////////////////

class SFReaderOutputChannel;

class SFReader : public Object
{
	SoundFileReader* mReader;
	int64_t mFramesRemaining;
	SFReaderOutputChannel* mOutputs;
	int mNumChannels;
	std::vector<double*> mChannelPtrs;
	bool mFinished = false;

public:

	SFReader(SoundFileReader* inReader, int inNumChannels, int64_t inDuration);

	~SFReader();

	virtual const char* TypeName() const override { return "SFReader"; }

	P<List> createOutputs(Thread& th);

	bool pull(Thread& th);
	void fulfillOutputs(int blockSize);
	void produceOutputs(int shrinkBy);
};

class SFReaderOutputChannel : public Gen
{
	friend class SFReader;
	P<SFReader> mSFReader;
	SFReaderOutputChannel* mNextOutput = nullptr;
	Z* mDummy = nullptr;

public:
	SFReaderOutputChannel(Thread& th, SFReader* inSFReader)
        : Gen(th, itemTypeZ, true), mSFReader(inSFReader)
	{
	}

	~SFReaderOutputChannel()
	{
		if (mDummy) free(mDummy);
	}

	virtual void norefs() override
	{
		mOut = nullptr;
		mSFReader = nullptr;
	}

	virtual const char* TypeName() const override { return "SFReaderOutputChannel"; }

	virtual void pull(Thread& th) override
	{
		if (mSFReader->pull(th)) {
			end();
		}
	}

};

SFReader::SFReader(SoundFileReader* inReader, int inNumChannels, int64_t inDuration)
	: mReader(inReader), mFramesRemaining(inDuration), mNumChannels(inNumChannels), mChannelPtrs(inNumChannels, nullptr)
{
}

SFReader::~SFReader()
{
	sfcloseRead(mReader);
	SFReaderOutputChannel* output = mOutputs;
	do {
		SFReaderOutputChannel* next = output->mNextOutput;
		delete output;
		output = next;
	} while (output);
}

void SFReader::fulfillOutputs(int blockSize)
{
	SFReaderOutputChannel* output = mOutputs;
	size_t bufSize = blockSize * sizeof(Z);
	for (int i = 0; output; ++i, output = output->mNextOutput){
		Z* out;
		if (output->mOut)
			out = output->mOut->fulfillz(blockSize);
		else {
			if (!output->mDummy)
				output->mDummy = (Z*)calloc(output->mBlockSize, sizeof(Z));

			out = output->mDummy;
		}

		mChannelPtrs[i] = out;
		memset(out, 0, bufSize);
	};
}

void SFReader::produceOutputs(int shrinkBy)
{
	SFReaderOutputChannel* output = mOutputs;
	do {
		if (output->mOut)
			output->produce(shrinkBy);
		output = output->mNextOutput;
	} while (output);
}

P<List> SFReader::createOutputs(Thread& th)
{
	P<List> s = new List(itemTypeV, mNumChannels);

	// fill s->mArray with ola's output channels.
    SFReaderOutputChannel* last = nullptr;
	P<Array> a = s->mArray;
	for (int i = 0; i < mNumChannels; ++i) {
        SFReaderOutputChannel* c = new SFReaderOutputChannel(th, this);
        if (last) last->mNextOutput = c;
        else mOutputs = c;
        last = c;
		a->add(new List(c));
	}

	return s;
}

bool SFReader::pull(Thread& th)
{
	if (mFramesRemaining == 0)
		mFinished = true;

	if (mFinished)
		return true;

	SFReaderOutputChannel* output = mOutputs;
	int blockSize = output->mBlockSize;
	if (mFramesRemaining > 0)
		blockSize = (int)std::min(mFramesRemaining, (int64_t)blockSize);

	fulfillOutputs(blockSize);

	// read file here.
	int framesRead = sfreadFrames(mReader, mChannelPtrs.data(), blockSize);

	if (framesRead == 0) {
		mFinished = true;
	}

	produceOutputs(blockSize - framesRead);
	if (mFramesRemaining > 0) mFramesRemaining -= blockSize;

	return mFinished;
}

static bool isFile(const std::string& path)
{
	struct stat st;
	return stat(path.c_str(), &st) == 0 && S_ISREG(st.st_mode);
}

// A name that isn't found as given (relative to the current directory) is looked for where >sf writes, so
// "take1" >sf and then "take1" sf> reads it back, and in $SAPF_SOUNDS. ".wav" is added if it has no extension.
static std::string findSoundFile(const char* name)
{
	std::string given = name;
	if (given.empty() || given[0] == '/' || isFile(given)) return given;
	size_t slash = given.rfind('/');
	bool hasExtension = given.find('.', slash == std::string::npos ? 0 : slash + 1) != std::string::npos;
	for (const char* var : { "SAPF_SOUNDS", "SAPF_RECORDINGS" }) {
		const char* dir = getenv(var);
		if (!dir || !*dir) continue;
		std::string path = std::string(dir) + "/" + given;
		if (isFile(path)) return path;
		if (!hasExtension && isFile(path + ".wav")) return path + ".wav";
	}
	if (!hasExtension && isFile(given + ".wav")) return given + ".wav";
	return given;
}

void sfread(Thread& th, Arg filename, int64_t offset, int64_t frames)
{
	std::string found = findSoundFile(((String*)filename.o())->s);
	const char* path = found.c_str();

	int numChannels = 0;
	SoundFileReader* reader = sfopenRead(th, path, offset, numChannels);
	if (!reader) return;

	SFReader* sfr = new SFReader(reader, numChannels, -1);

	th.push(sfr->createOutputs(th));
}

std::atomic<int32_t> gFileCount = 0;

void makeRecordingPath(Arg filename, char* path, int len)
{
	if (filename.isString()) {
		const char* recDir = getenv("SAPF_RECORDINGS");
		if (!recDir || strlen(recDir)==0) recDir = sapfTempDir();
		snprintf(path, len, "%s/%s.wav", recDir, ((String*)filename.o())->s);
	} else {
		int32_t count = ++gFileCount;
		snprintf(path, len, "%s/sapf-%s-%04d.wav", sapfTempDir(), gSessionTime, count);
	}
}

void sfwrite(Thread& th, V& v, Arg filename, bool openIt)
{
	std::vector<ZIn> in;

	int numChannels = 0;

	if (v.isZList()) {
		if (!v.isFinite()) indefiniteOp(">sf : s - indefinite number of frames", "");
		numChannels = 1;
		in.push_back(ZIn(v));
	} else {
		if (!v.isFinite()) indefiniteOp(">sf : s - indefinite number of channels", "");
		P<List> s = (List*)v.o();
		s = s->pack(th);
		Array* a = s->mArray();
		numChannels = (int)a->size();

		if (numChannels > kMaxSFChannels)
			throw errOutOfRange;

		bool allIndefinite = true;
		for (int i = 0; i < numChannels; ++i) {
			V va = a->at(i);
			if (va.isFinite()) allIndefinite = false;
			in.push_back(ZIn(va));
			va.o = nullptr;
		}

		s = nullptr;
		a = nullptr;

		if (allIndefinite) indefiniteOp(">sf : s - all channels have indefinite number of frames", "");
	}
	v.o = nullptr;

	char path[1024];

	makeRecordingPath(filename, path, 1024);

	SoundFileWriter* w = sfcreate(th, path, numChannels, 0., true);
	if (!w) return;

	std::valarray<float> buf(0., numChannels * kBufSize);
	float* data[1] = { &buf[0] };

	int64_t framesPulled = 0;
	int64_t framesWritten = 0;
	bool done = false;
	while (!done) {
		int minn = kBufSize;
		memset(&buf[0], 0, kBufSize * numChannels * sizeof(float));
		for (int i = 0; i < numChannels; ++i) {
			int n = kBufSize;
			bool imdone = in[i].fill(th, n, &buf[0]+i, numChannels);
			framesPulled += n;
			if (imdone) done = true;
			minn = std::min(n, minn);
		}

		if (!sfwriteFrames(w, data, minn)) break;

		framesWritten += minn;
	}

	post("wrote file '%s'  %d channels  %g secs\n", path, numChannels, framesWritten * th.rate.invSampleRate);

	sfclose(w);

	if (openIt) {
		openFileExternally(path);
	}
}
