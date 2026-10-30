//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __ErrorCodes_h__
#define __ErrorCodes_h__

const int errNone = 0;
const int errHalt = -1000;
const int errFailed = -1001;
const int errIndefiniteOperation = -1002;
const int errWrongType = -1003;
const int errOutOfRange = -1004;
const int errSyntax = -1005;
const int errInternalError = -1006;
const int errWrongState = -1007;
const int errNotFound = -1008;
const int errStackOverflow = -1009;
const int errStackUnderflow = -1010;
const int errInconsistentInheritance = -1011;
const int errUndefinedOperation = -1012;
const int errUserQuit = -1013;
const int kNumErrors = 14;

extern const char* errString[kNumErrors];

#endif

