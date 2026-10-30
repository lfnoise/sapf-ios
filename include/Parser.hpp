//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __Parser_h__
#define __Parser_h__

#include "VM.hpp"

bool parseElems(Thread& th, P<Code>& code);

//////////////////////////////////

#pragma mark PIPER SYNTAX

struct AST : RCObj
{
	virtual const char* TypeName() const { return "AST"; }
	virtual void dump(std::ostream& ost, int indent) = 0;
	virtual void codegen(P<Code>& code) = 0;
};

typedef P<AST> ASTPtr;

ASTPtr parseExpr(const char*& in);

void printi(std::ostream& ost, int indent, const char* fmt, ...);
void prints(std::ostream& ost, const char* fmt, ...);

#endif
