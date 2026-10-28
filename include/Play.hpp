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

