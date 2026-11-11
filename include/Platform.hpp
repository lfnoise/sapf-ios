//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __Platform_h__
#define __Platform_h__

// Which platform is being built, and which platform libraries to use.
//
//   SAPF_APPLE          macOS or iOS
//   SAPF_IOS            iOS
//   SAPF_WEB            the browser, built with Emscripten
//   SAPF_DESKTOP_MAC    the macOS command line tool (Apple, not iOS)
//   SAPF_ACCELERATE     vector math and FFT from Apple's Accelerate; otherwise PortableAccel.hpp
//   SAPF_EXTAUDIOFILE   sound files through ExtAudioFile; otherwise dr_wav
//   SAPF_APPLE_IMAGE    spectrogram images through makeImage.mm; otherwise makeImage.cpp
//   SAPF_COREAUDIO      sound output through AudioUnits
//   SAPF_SHARED_MIXER   all players are mixed into one output by renderSharedMix() (the web)
//
// Defining SAPF_PORTABLE on macOS builds the command line tool with the portable math, FFT, sound file
// and image code that the web build uses, while keeping CoreAudio output, so that code can be tested natively.

#if defined(__APPLE__)
#	include <TargetConditionals.h>
#	define SAPF_APPLE 1
#	if TARGET_OS_IPHONE
#		define SAPF_IOS 1
#	else
#		define SAPF_DESKTOP_MAC 1
#	endif
#	define SAPF_COREAUDIO 1
#	if !defined(SAPF_PORTABLE)
#		define SAPF_ACCELERATE 1
#		define SAPF_EXTAUDIOFILE 1
#		define SAPF_APPLE_IMAGE 1
#	endif
#endif

#if defined(__EMSCRIPTEN__)
#	define SAPF_WEB 1
#	define SAPF_SHARED_MIXER 1
#endif

#endif
