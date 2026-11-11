//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __taggeddoubles__dsp__
#define __taggeddoubles__dsp__

#include "Accel.hpp"

const int kMinFFTLogSize = 2;
const int kMaxFFTLogSize = 16;

extern FFTSetupD fftSetups[kMaxFFTLogSize+1];

void initFFT();
void fft (int n, double* ioReal, double* ioImag);
void ifft(int n, double* ioReal, double* ioImag);

void fft (int n, double* inReal, double* inImag, double* outReal, double* outImag);
void ifft(int n, double* inReal, double* inImag, double* outReal, double* outImag);

void rfft(int n, double* inReal, double* outReal, double* outImag);
void rifft(int n, double* inReal, double* inImag, double* outReal);

#endif /* defined(__taggeddoubles__dsp__) */
