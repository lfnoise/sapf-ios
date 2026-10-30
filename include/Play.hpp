//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "VM.hpp"

void playWithAudioUnit(Thread& th, V& v);
void recordWithAudioUnit(Thread& th, V& v, Arg filename);

void stopPlaying();
void stopPlayingIfDone();

// Size of the per-player ring buffers used for displaying output. Must be a power of two.
const int kScopeBufferSize = 16384;

// Fills out with the most recent n frames (n <= kScopeBufferSize) of the mono sum of
// everything currently playing. Returns the number of active players. Safe from any thread.
int getScopeSamples(float* out, int n);

// Audio timing, for spotting glitches. A dropout is a gap in the output's timestamps, whatever
// caused it. A late render is one of ours that took longer than the audio it produced lasts.
// The peak load is the largest render time as a fraction of that duration since the last reset.
struct AudioTimingStats
{
	uint32_t dropouts;
	uint32_t lateRenders;
	float peakLoad;
};
AudioTimingStats getAudioTimingStats(bool resetPeakLoad);

