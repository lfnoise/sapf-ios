//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Keeps the interpreter's and unit generators' code in memory.
//
// iOS brings code pages in (and checks their signatures) the first time they're used, and can
// drop them again under memory pressure. When `ola` starts a new event on the audio thread, the
// generators it creates may run for the first time, and each cold page costs a page fault. Reading
// every page of this image at startup avoids that, without needing to know which generators a
// program will use: the whole image is only a few MB.

#pragma once

#include <cstddef>

struct CodeWarmth {
	size_t pages = 0;   // pages touched
	size_t bytes = 0;
	bool locked = false; // mlock succeeded, so the pages stay in memory
};

// Touches every page of this image's code and constant data, and tries to lock them in memory.
// If they can't be locked, touches them again every few seconds from a low priority thread.
CodeWarmth warmCode();
