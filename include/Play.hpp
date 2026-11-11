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
// Starts the output of every player that hasn't finished again, e.g. after an audio interruption,
// which stops them. They carry on from where they were.
void restartPlaying();

// Size of the per-player ring buffers used for displaying output. Must be a power of two.
const int kScopeBufferSize = 16384;

// Fills out with the most recent n frames (n <= kScopeBufferSize) of the mono sum of
// everything currently playing. Returns the number of active players. Safe from any thread.
int getScopeSamples(float* out, int n);

// For longer views of the output, each player also keeps the minimum and maximum of each block of
// kScopeEnvelopeBlockSize frames, for the most recent kScopeEnvelopeBlocks blocks.
const int kScopeEnvelopeBlockSize = 128;
const int kScopeEnvelopeBlocks = 16384; // power of two

// Fills outMin and outMax with the most recent n blocks (n <= kScopeEnvelopeBlocks), oldest first.
// With more than one player, the minimums and maximums of each are summed, which bounds the mix.
// Returns the number of active players. Safe from any thread.
int getScopeEnvelope(float* outMin, float* outMax, int n);

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

#include "Platform.hpp"
#if SAPF_SHARED_MIXER
// The web: one audio callback mixes every player. left and right are zeroed first. Called on the audio
// thread; never blocks (if the player list is being changed, that buffer is left silent).
void renderSharedMix(float* left, float* right, int numFrames);
// Silence the output while still feeding the scope (for automated tests).
void setOutputMuted(bool muted);
// Number of players that haven't finished.
int numPlayersPlaying();
#endif

