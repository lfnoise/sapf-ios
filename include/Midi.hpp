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

// without CoreMIDI the host manages the devices, and the MIDI words ask it to through this hook. request is
// "start", "restart", "stop", "list", "connect" or "disconnect"; uid (the source's unique ID) and index (the input
// port, 0-15) are for connect and disconnect. Called on the interpreter's thread. If it isn't set, the words say
// MIDI isn't available.
extern void (*gMidiRequestHook)(const char* request, int uid, int index);
#endif

#endif /* defined(__taggeddoubles__Midi__) */
