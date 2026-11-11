# SAPF - Sound As Pure Form
# Copyright (C) 2019 James McCartney
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Shortcuts for the CMake build. The program ends up in build/sapf.

.PHONY: all universal portable test web web-dev web-test clean

all:
	cmake -S . -B build
	cmake --build build

universal:
	cmake -S . -B build -DUNIVERSAL=ON
	cmake --build build

# The program built with the portable code the web version uses (no Accelerate or ExtAudioFile).
portable:
	cmake -S . -B build/portable -DSAPF_PORTABLE=ON
	cmake --build build/portable

# Unit tests through both builds, and the portable vector math and FFT checked against Accelerate.
test: all portable
	./build/accel_test | tail -1
	@./build/sapf-run -p sapf-prelude.txt unit-tests.txt | grep -c Passed | xargs echo "Apple build, unit tests passed:"
	@./build/portable/sapf-run -p sapf-prelude.txt unit-tests.txt | grep -c Passed | xargs echo "portable build, unit tests passed:"

# The web version. Needs Emscripten and Node; see web/README.md.
web:
	cd web && npm install && npm run engine && npm run build

web-dev:
	cd web && npm run dev

web-test:
	cd web && npm test && npm run test:browser

clean:
	rm -rf build
