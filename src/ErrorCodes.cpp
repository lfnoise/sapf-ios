//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "ErrorCodes.hpp"

const char* errString[kNumErrors] = { 
	"halt", "failed", "indefinite operation", "wrong type", "out of range", "syntax", "internal bug",
	"wrong state", "not found", "stack overflow", "stack underflow",
	"inconsistent inheritance", "undefined operation", "user quit"
};
