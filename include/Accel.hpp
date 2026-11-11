//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __Accel_h__
#define __Accel_h__

// Vector math and FFT: Apple's Accelerate where available, otherwise PortableAccel.hpp.

#include "Platform.hpp"

#if SAPF_ACCELERATE
#include <Accelerate/Accelerate.h>
#else
#include "PortableAccel.hpp"
#endif

#endif
