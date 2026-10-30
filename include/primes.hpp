//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include <stdint.h>

extern const  int gLowPrimes[10];
extern const  int gPrimeOffsets[8];
extern const  int gPrimesShift[30];

const int kPrimesMaskSize = 33334;
extern uint8_t gPrimesMask[];

bool isprime(int64_t n);

int64_t nextPrime(int64_t x);
