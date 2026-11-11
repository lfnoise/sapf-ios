//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Non-interactive runner for tests: loads the prelude, then evaluates files and code strings in order,
// printing the stack after each.
//
//   sapf-run [-r rate] [-p prelude] [-e code | file]...
//
// Each file is evaluated as one program. Exits with status 1 if any evaluation failed.

#include "VM.hpp"
#include "Play.hpp"
#include "ErrorCodes.hpp"
#include <cstdio>
#include <cstring>
#include <string>

extern void AddCoreOps();
extern void AddMathOps();
extern void AddStreamOps();
extern void AddUGenOps();
extern void AddSetOps();
extern void AddRandomOps();
extern void AddMidiOps();

const char* gVersionString = "0.1.22";

static bool readFile(const char* path, std::string& out)
{
	FILE* f = fopen(path, "rb");
	if (!f) return false;
	char buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, f)) > 0) out.append(buf, n);
	fclose(f);
	return true;
}

static bool evaluate(Thread& th, const char* code)
{
	try {
		P<Fun> compiledFun;
		if (th.compile(code, compiledFun, true)) {
			compiledFun->runREPL(th);
			return true;
		}
	} catch (V& v) {
		post("error: ");
		v.print(th);
		post("\n");
	} catch (int err) {
		if (err <= -1000 && err > -1000 - kNumErrors) post("error: %s\n", errString[-1000 - err]);
		else post("error: %d\n", err);
	} catch (std::bad_alloc& xerr) {
		post("not enough memory\n");
	} catch (...) {
		post("unknown error\n");
	}
	return false;
}

int main(int argc, const char* argv[])
{
	double rate = 48000.;
	const char* prelude = nullptr;
	int first = 1;
	while (first < argc) {
		if (!strcmp(argv[first], "-r") && first + 1 < argc) { rate = atof(argv[first + 1]); first += 2; }
		else if (!strcmp(argv[first], "-p") && first + 1 < argc) { prelude = argv[first + 1]; first += 2; }
		else break;
	}

	vm.setSampleRate(rate);
	vm.addBifHelp("Argument Automapping legend:");
	vm.addBifHelp("   a - as is. argument is not automapped.");
	vm.addBifHelp("   z - argument is expected to be a signal or scalar, streams are auto mapped.");
	vm.addBifHelp("   k - argument is expected to be a scalar, signals and streams are automapped.");
	vm.addBifHelp("");
	AddCoreOps();
	AddMathOps();
	AddStreamOps();
	AddRandomOps();
	AddUGenOps();
	AddMidiOps();
	AddSetOps();

	Thread th;
	if (prelude) {
		vm.prelude_file = strdup(prelude);
		loadFile(th, prelude);
	}

	bool allOK = true;
	for (int i = first; i < argc; ++i) {
		std::string code;
		if (!strcmp(argv[i], "-e") && i + 1 < argc) {
			code = argv[++i];
		} else if (!readFile(argv[i], code)) {
			post("could not read '%s'\n", argv[i]);
			allOK = false;
			continue;
		}
		if (!evaluate(th, code.c_str())) allOK = false;
		std::string stack;
		for (size_t j = 0; j < th.stackDepth(); ++j) {
			if (j) stack += " ";
			th.stack[th.stackBase + j].print(th, stack);
		}
		post("stack: %s\n", stack.c_str());
	}
	stopPlaying();
	fflush(stdout);
	return allOK ? 0 : 1;
}
