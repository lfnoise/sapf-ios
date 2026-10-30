//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __no_web2__RCObj__
#define __no_web2__RCObj__

#include <stdint.h>
#include <atomic>
#include "rc_ptr.hpp"

class RCObj
{
public:
	mutable std::atomic<int32_t> refcount;

public:
	RCObj();
    RCObj(RCObj const&);
	virtual ~RCObj();
	
	void retain() const;
	void release();
	virtual void norefs();
		
	int32_t getRefcount() const { return refcount; }
	
	void negrefcount();
	void alreadyDead();
	

	virtual const char* TypeName() const = 0;
};

inline void retain(RCObj* o) { o->retain(); }
inline void release(RCObj* o) { o->release(); }

#endif /* defined(__no_web2__RCObj__) */
