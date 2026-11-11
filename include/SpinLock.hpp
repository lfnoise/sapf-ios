//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __SpinLock_h__
#define __SpinLock_h__

// A tiny lock for short critical sections that may be entered from the audio thread.
// On Apple platforms it is os_unfair_lock. Elsewhere it is a pure spin lock, because
// the browser's main thread and audio worklet are not allowed to block in the kernel.

#include "Platform.hpp"

#if SAPF_APPLE

#include <os/lock.h>

class SpinLock
{
	os_unfair_lock mLock = OS_UNFAIR_LOCK_INIT;
public:
	void lock() { os_unfair_lock_lock(&mLock); }
	void unlock() { os_unfair_lock_unlock(&mLock); }
};

#else

#include <atomic>

class SpinLock
{
	std::atomic_flag mFlag = ATOMIC_FLAG_INIT;
public:
	SpinLock() = default;
	// members holding a SpinLock are copied in a few places; a copy starts unlocked, as os_unfair_lock does.
	SpinLock(const SpinLock&) {}
	SpinLock& operator=(const SpinLock&) { return *this; }

	void lock()
	{
		while (mFlag.test_and_set(std::memory_order_acquire)) {}
	}
	void unlock() { mFlag.clear(std::memory_order_release); }
};

#endif

#endif
