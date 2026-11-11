//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "elapsedTime.hpp"
#include "Platform.hpp"

#if SAPF_APPLE

#include <mach/mach_time.h>

extern "C" {

static double gHostClockFreq;

void initElapsedTime()
{
	struct mach_timebase_info info;
	mach_timebase_info(&info);
	// The timebase converts ticks to nanoseconds: ns = ticks * numer / denom.
	gHostClockFreq = 1e9 * ((double)info.denom / (double)info.numer);
}

double elapsedTime()
{
	return (double)mach_absolute_time() / gHostClockFreq;
}

}

#elif SAPF_WEB

#include <emscripten.h>

extern "C" {

void initElapsedTime()
{
}

// Not std::chrono::steady_clock: in the audio worklet the browser has no monotonic clock, and asking for one
// throws. emscripten_get_now() falls back to Date.now() there.
double elapsedTime()
{
	return emscripten_get_now() * 1e-3;
}

}

#else

#include <chrono>

extern "C" {

void initElapsedTime()
{
}

double elapsedTime()
{
	using namespace std::chrono;
	return duration<double>(steady_clock::now().time_since_epoch()).count();
}

}

#endif
