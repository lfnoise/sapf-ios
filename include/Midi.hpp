//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __taggeddoubles__Midi__
#define __taggeddoubles__Midi__

#include <stdint.h>

void AddMidiOps();

#include "Platform.hpp"
#if !SAPF_APPLE
// without CoreMIDI the host feeds incoming MIDI bytes here, e.g. from Web MIDI.
void sapfMidiInput(int srcIndex, const uint8_t* data, int length);
#endif

#endif /* defined(__taggeddoubles__Midi__) */
