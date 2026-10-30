//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __Opcode_h__
#define __Opcode_h__

#include "VM.hpp"

enum {
	BAD_OPCODE,
	opNone,
	opPushImmediate,
	opPushLocalVar,
	opPushFunVar,
	opPushWorkspaceVar,

	opPushFun,

	opCallImmediate,
	opCallLocalVar,
	opCallFunVar,
	opCallWorkspaceVar,

	
	opDot,
	opComma,
	opBindLocal,
	opBindLocalFromList,
	opBindWorkspaceVar,
	opBindWorkspaceVarFromList,

	opParens,
	opNewVList,
	opNewZList,
	opNewForm,
	opInherit,
	opEach,
	
	opReturn,
	
	kNumOpcodes
};

extern const char* opcode_name[kNumOpcodes];
	
#endif

