# SAPF - Sound As Pure Form
# Copyright (C) 2019 James McCartney
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Builds the sapf command line program for macOS:
#   cmake -S . -B build && cmake --build build
# Add -DUNIVERSAL=ON for an arm64 + x86_64 binary.
# Add -DSAPF_PORTABLE=ON to use the portable math, FFT, sound file and image code that the web version uses.
#
# With Emscripten (emcmake cmake ...) it builds the web version's engine instead; see web/README.md.

cmake_minimum_required(VERSION 3.15)

if(EMSCRIPTEN)
	project(sapf LANGUAGES C CXX)
else()
	project(sapf LANGUAGES C CXX OBJCXX)
endif()

option(UNIVERSAL "Build for both arm64 and x86_64" OFF)
option(SAPF_PORTABLE "macOS: use the portable code the web version uses instead of Accelerate, ExtAudioFile and Cocoa" OFF)
if(UNIVERSAL)
	set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0)

if(NOT CMAKE_BUILD_TYPE)
	set(CMAKE_BUILD_TYPE Release)
endif()

# The iOS app builds the same sources from ios/project.yml.
# makeImage.mm and makeImage.cpp each compile to nothing where the other one is used.
file(GLOB SAPF_SOURCES CONFIGURE_DEPENDS src/*.cpp src/*.mm)
list(FILTER SAPF_SOURCES EXCLUDE REGEX ".*/main\\.cpp$")

if(EMSCRIPTEN)

	# The web engine: the interpreter plus the bridge in web/engine, as an ES module for a cross-origin
	# isolated page (pthreads and the Wasm Audio Worklet share one heap).
	list(FILTER SAPF_SOURCES EXCLUDE REGEX ".*\\.mm$")
	set(WEB_DIR ${CMAKE_SOURCE_DIR}/web/engine)
	add_executable(sapf_engine ${SAPF_SOURCES} ${WEB_DIR}/sapf_web.cpp)
	target_include_directories(sapf_engine PRIVATE include ${WEB_DIR})
	target_compile_features(sapf_engine PRIVATE cxx_std_17)

	set(WEB_COMPILE_OPTIONS -pthread -fwasm-exceptions -msimd128)
	target_compile_options(sapf_engine PRIVATE ${WEB_COMPILE_OPTIONS})
	target_link_options(sapf_engine PRIVATE
		${WEB_COMPILE_OPTIONS}
		-sAUDIO_WORKLET
		-sWASM_WORKERS
		-sMODULARIZE
		-sEXPORT_ES6
		-sEXPORT_NAME=createSapfEngine
		-sENVIRONMENT=web,worker
		-sPTHREAD_POOL_SIZE=4
		-sSTACK_SIZE=8MB
		-sDEFAULT_PTHREAD_STACK_SIZE=2MB
		-sALLOW_MEMORY_GROWTH
		-sINITIAL_MEMORY=256MB
		-sMAXIMUM_MEMORY=2GB
		-sFORCE_FILESYSTEM
		-lidbfs.js
		"-sEXPORTED_RUNTIME_METHODS=FS,IDBFS,ENV,UTF8ToString,stringToUTF8,lengthBytesUTF8,wasmMemory,emscriptenGetAudioObject"
		"-sEXPORTED_FUNCTIONS=_main,_malloc,_free"
	)
	set_target_properties(sapf_engine PROPERTIES OUTPUT_NAME "sapf-engine" SUFFIX ".mjs")

else()

	set(APPLE_LIBRARIES
		edit
		"-framework Accelerate"
		"-framework AudioToolbox"
		"-framework AudioUnit"
		"-framework Carbon"
		"-framework Cocoa"
		"-framework CoreFoundation"
		"-framework CoreMIDI"
		"-framework CoreServices"
	)

	# the interpreter, compiled once for the program and the test tools.
	add_library(sapf_core OBJECT ${SAPF_SOURCES})
	target_include_directories(sapf_core PUBLIC include)
	target_compile_features(sapf_core PUBLIC cxx_std_17)
	if(SAPF_PORTABLE)
		target_compile_definitions(sapf_core PUBLIC SAPF_PORTABLE=1)
	endif()

	add_executable(sapf src/main.cpp)
	target_link_libraries(sapf PRIVATE sapf_core ${APPLE_LIBRARIES})

	# non-interactive runner for tests: sapf-run [-r rate] [-p prelude] [-e code | file]...
	add_executable(sapf_run tests/sapf_run.cpp)
	set_target_properties(sapf_run PROPERTIES OUTPUT_NAME "sapf-run")
	target_link_libraries(sapf_run PRIVATE sapf_core ${APPLE_LIBRARIES})

	# checks PortableAccel.hpp against Accelerate.
	add_executable(accel_test tests/accel_test.cpp)
	target_include_directories(accel_test PRIVATE include)
	target_compile_features(accel_test PRIVATE cxx_std_17)
	target_link_libraries(accel_test PRIVATE "-framework Accelerate")

endif()
