#!/bin/sh
# SAPF - Sound As Pure Form. Copyright (C) 2019 James McCartney.
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
#
# Build the interpreter to WebAssembly and copy it into public/engine.
# Needs the Emscripten SDK: either emcmake on the PATH, or EMSDK pointing at an emsdk checkout (default ~/emsdk).
set -e

cd "$(dirname "$0")/.."
WEB_DIR="$(pwd)"
REPO_DIR="$(cd .. && pwd)"
BUILD_DIR="$REPO_DIR/build/web"

if ! command -v emcmake >/dev/null 2>&1; then
	EMSDK="${EMSDK:-$HOME/emsdk}"
	if [ -f "$EMSDK/emsdk_env.sh" ]; then
		# emsdk_env.sh finds its own folder only in bash, zsh and ksh; elsewhere (dash, the sh of Ubuntu and so of
		# GitHub's runners) it uses the current folder. So source it from there.
		cd "$EMSDK"
		. ./emsdk_env.sh >/dev/null
		cd "$WEB_DIR"
		if ! command -v emcmake >/dev/null 2>&1; then
			echo "emcmake still not found after sourcing $EMSDK/emsdk_env.sh." >&2
			exit 1
		fi
	else
		echo "Emscripten not found. Install emsdk (https://emscripten.org/docs/getting_started/downloads.html) or set EMSDK." >&2
		exit 1
	fi
fi

emcmake cmake -S "$REPO_DIR" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release
cmake --build "$BUILD_DIR" -j 8

mkdir -p "$WEB_DIR/public/engine"
cp "$BUILD_DIR/sapf-engine.mjs" "$BUILD_DIR/sapf-engine.wasm" "$WEB_DIR/public/engine/"
echo "engine copied to public/engine"
