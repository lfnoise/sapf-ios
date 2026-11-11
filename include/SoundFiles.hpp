//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __taggeddoubles__SoundFiles__
#define __taggeddoubles__SoundFiles__

#include "VM.hpp"

const int kMaxSFChannels = 1024;
const int kBufSize = 1024;

// A sound file being written: 32 bit float WAV. The implementation is ExtAudioFile on Apple platforms
// (unless SAPF_PORTABLE) and dr_wav elsewhere.
struct SoundFileWriter;

void makeRecordingPath(Arg filename, char* path, int len);

// create a WAV file at the thread's sample rate (fileSampleRate 0) or the given rate.
// interleaved selects the layout of the data passed to sfwriteFrames.
SoundFileWriter* sfcreate(Thread& th, const char* path, int numChannels, double fileSampleRate, bool interleaved);

// blocking write. for an interleaved writer, data[0] holds numFrames interleaved frames;
// otherwise data[c] holds numFrames samples of channel c.
bool sfwriteFrames(SoundFileWriter* w, float* const* data, int numFrames);

// prepare for sfwriteAsync. call on a non-audio thread before audio starts.
void sfbeginAsync(SoundFileWriter* w);
// real time safe write of non-interleaved channels, for the audio thread.
void sfwriteAsync(SoundFileWriter* w, float* const* channels, int numFrames);
// write out data queued by sfwriteAsync. call periodically from a non-audio thread.
void sfserviceAsync();

// finish writing (including any queued async data) and close the file.
void sfclose(SoundFileWriter* w);

void sfwrite(Thread& th, V& v, Arg filename, bool openIt);
void sfread(Thread& th, Arg filename, int64_t offset, int64_t frames);

#endif /* defined(__taggeddoubles__SoundFiles__) */
