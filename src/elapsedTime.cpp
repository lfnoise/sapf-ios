//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "elapsedTime.hpp"
#include <mach/mach_time.h>
#include <pthread.h>

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
