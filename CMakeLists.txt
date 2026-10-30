# SAPF - Sound As Pure Form
# Copyright (C) 2019 James McCartney
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# Builds the sapf command line program for macOS:
#   cmake -S . -B build && cmake --build build
# Add -DUNIVERSAL=ON for an arm64 + x86_64 binary.

cmake_minimum_required(VERSION 3.15)
project(sapf LANGUAGES C CXX OBJCXX)

option(UNIVERSAL "Build for both arm64 and x86_64" OFF)
if(UNIVERSAL)
	set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
endif()
set(CMAKE_OSX_DEPLOYMENT_TARGET 11.0)

if(NOT CMAKE_BUILD_TYPE)
	set(CMAKE_BUILD_TYPE Release)
endif()

# The iOS app builds the same sources from ios/project.yml.
file(GLOB SAPF_SOURCES CONFIGURE_DEPENDS src/*.cpp src/*.mm)

add_executable(sapf ${SAPF_SOURCES})
target_include_directories(sapf PRIVATE include)
target_compile_features(sapf PRIVATE cxx_std_17)
target_link_libraries(sapf PRIVATE
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
