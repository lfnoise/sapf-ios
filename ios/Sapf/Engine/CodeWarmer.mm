//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "CodeWarmer.h"

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <unistd.h>
#include <vector>

namespace {

struct Range {
	const uint8_t* start;
	size_t size;
};

// The segments of the image this file is linked into (the app, or Sapf.debug.dylib in Debug
// builds), which also holds the interpreter and every unit generator.
std::vector<Range> imageRanges()
{
	std::vector<Range> ranges;
	Dl_info info;
	if (!dladdr((const void*)&warmCode, &info) || !info.dli_fbase) return ranges;
	auto header = (const struct mach_header_64*)info.dli_fbase;
	// __TEXT is the code and its constants; __DATA_CONST and __DATA hold tables and vtables.
	for (const char* name : {"__TEXT", "__DATA_CONST", "__DATA"}) {
		unsigned long size = 0;
		uint8_t* start = getsegmentdata(header, name, &size);
		if (start && size) ranges.push_back({start, (size_t)size});
	}
	return ranges;
}

size_t touch(std::vector<Range> const& ranges)
{
	const size_t pageSize = (size_t)getpagesize();
	size_t pages = 0;
	uint8_t sum = 0;
	for (auto& r : ranges) {
		for (size_t offset = 0; offset < r.size; offset += pageSize, ++pages) {
			sum += ((const volatile uint8_t*)r.start)[offset];
		}
	}
	static volatile uint8_t sink;
	sink = sum;
	return pages;
}

} // namespace

CodeWarmth warmCode()
{
	CodeWarmth warmth;
	static std::vector<Range> ranges = imageRanges();
	warmth.pages = touch(ranges);
	for (auto& r : ranges) warmth.bytes += r.size;

	warmth.locked = !ranges.empty();
	for (auto& r : ranges) {
		if (mlock(r.start, r.size) != 0) warmth.locked = false;
	}

	if (!warmth.locked) {
		// Pages that are in memory cost nothing to touch, so this is cheap to keep doing.
		static dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
			dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
		dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
		dispatch_source_set_event_handler(timer, ^{ touch(ranges); });
		dispatch_resume(timer);
	}
	return warmth;
}
