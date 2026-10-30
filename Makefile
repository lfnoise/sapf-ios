# SAPF - Sound As Pure Form
# Copyright (C) 2019 James McCartney
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Shortcuts for the CMake build. The program ends up in build/sapf.

.PHONY: all universal clean

all:
	cmake -S . -B build
	cmake --build build

universal:
	cmake -S . -B build -DUNIVERSAL=ON
	cmake --build build

clean:
	rm -rf build
