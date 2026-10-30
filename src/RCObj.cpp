//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "RCObj.hpp"
#include "VM.hpp"


RCObj::RCObj()
	: refcount(0)
{
#if COLLECT_MINFO
	++vm.totalObjectsAllocated;
#endif
}

RCObj::RCObj(RCObj const& that)
	: refcount(0)
{
#if COLLECT_MINFO
	++vm.totalObjectsAllocated;
#endif
}

RCObj::~RCObj()
{
#if COLLECT_MINFO
	++vm.totalObjectsFreed;
#endif
}


void RCObj::norefs()
{
	refcount = -999;
	delete this; 
}

	
void RCObj::negrefcount()
{
	post("RELEASING WITH NEGATIVE REFCOUNT %s %p %d\n", TypeName(), this, refcount.load());
}
void RCObj::alreadyDead()
{
	post("RETAINING ALREADY DEAD OBJECT %s %p\n", TypeName(), this);
}
