//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "MathFuns.hpp"
#include "VM.hpp"

double gSineTable[kSineTableSize+1];
double gDBAmpTable[kDBAmpTableSize+2];
double gDecayTable[kDecayTableSize+1];
double gFirstOrderCoeffTable[kFirstOrderCoeffTableSize+1];


inline double freqToTableF(double freq)
{
	return std::clamp(3. * log2(freq * .05), 0., 28.999);
}

Z gFreqToTable[20001];

static void initFreqToTable()
{
	for (int freq = 0; freq < 20001; ++freq) {
		gFreqToTable[freq] = freqToTableF(freq);
	}
}

inline double freqToTable(double freq)
{
	double findex = std::clamp(freq, 0., 20000.);
	double iindex = floor(findex);
	return lut(gFreqToTable, (int)iindex, findex - iindex);
}

////////////////////////////////////////////////////////////////////////////////////

void fillSineTable()
{
	for (int i = 0; i < kSineTableSize; ++i) {
		gSineTable[i] = sin(gSineTableOmega * i);
	}
	gSineTable[kSineTableSize] = gSineTable[0];
}

void fillDBAmpTable()
{
	for (int i = 0; i < kDBAmpTableSize+2; ++i) {
		double dbgain = i * kInvDBAmpScale - kDBAmpOffset;
		double amp = pow(10., .05 * dbgain);
		gDBAmpTable[i] = amp;
	}
}

void fillDecayTable()
{
	for (int i = 0; i < kDecayTableSize+1; ++i) {
		gDecayTable[i] = exp(log001 * i * .001);
	}	
}

void fillFirstOrderCoeffTable()
{
	double k = M_PI * kInvFirstOrderCoeffTableSize;
	for (int i = 0; i < kFirstOrderCoeffTableSize+1; ++i) {
		double x = k * i;
		Z b = 2. - cos(x);
		gFirstOrderCoeffTable[i] = b - sqrt(b*b - 1.);
	}	
}


