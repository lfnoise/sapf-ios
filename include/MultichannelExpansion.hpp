//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __MultichannelExpansion_h__
#define __MultichannelExpansion_h__

#include "VM.hpp"

Prim* mcx(int n, Arg f, const char* name, const char* help);
Prim* automap(const char* mask, int n, Arg f, const char* inName, const char* inHelp);
List* handleEachOps(Thread& th, int numArgs, Arg fun);
void flop_(Thread& th, Prim* prim);
void flops_(Thread& th, Prim* prim);
void flop1_(Thread& th, Prim* prim);
void lace_(Thread& th, Prim* prim);
void sel_(Thread& th, Prim* prim);
void sell_(Thread& th, Prim* prim);

#endif

