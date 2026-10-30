//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __taggeddoubles__SoundFiles__
#define __taggeddoubles__SoundFiles__

#include "VM.hpp"
#include <AudioToolbox/ExtendedAudioFile.h>

const int kMaxSFChannels = 1024;
const int kBufSize = 1024;

void makeRecordingPath(Arg filename, char* path, int len);

ExtAudioFileRef sfcreate(Thread& th, const char* path, int numChannels, double fileSampleRate, bool interleaved);
void sfwrite(Thread& th, V& v, Arg filename, bool openIt);
void sfread(Thread& th, Arg filename, int64_t offset, int64_t frames);

#endif /* defined(__taggeddoubles__SoundFiles__) */
