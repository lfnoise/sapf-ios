//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "symbol.hpp"
#include "VM.hpp"
#include "Hash.hpp"
#include <string.h>
#include <atomic>

const int kSymbolTableSize = 4096;
const int kSymbolTableMask = kSymbolTableSize - 1;
	
// global atomic symbol table
volatile std::atomic<String*> sSymbolTable[kSymbolTableSize];



static String* SymbolTable_lookup(String* list, const char* name, int32_t hash)
{
	while (list) {
		if (list->hash == hash && strcmp(list->s, name) == 0)
			return list;
		list = list->nextSymbol;
	}
	return nullptr;
}

static String* SymbolTable_lookup(const char* name, int hash)
{
	return SymbolTable_lookup(sSymbolTable[hash & kSymbolTableMask].load(), name, hash);
}

static String* SymbolTable_lookup(const char* name)
{
	uintptr_t hash = Hash(name);
	return SymbolTable_lookup(name, (int)hash);
}

P<String> getsym(const char* name)
{
	// thread safe

	int32_t hash = Hash(name);
    int32_t binIndex = hash & kSymbolTableMask;
	volatile std::atomic<String*>* bin = &sSymbolTable[binIndex];
	while (1) {
        // get the head of the list.
		String* head = bin->load();
        // search the list for the symbol
		String* existingSymbol = head;
		while (existingSymbol) {
			if (existingSymbol->hash == hash && strcmp(existingSymbol->s, name) == 0) {
				return existingSymbol;
			}
			existingSymbol = existingSymbol->nextSymbol;
		}
		String* newSymbol = new String(name, hash, head);
		if (bin->compare_exchange_weak(head, newSymbol)) {
			newSymbol->retain(); 
			return newSymbol;
		}
        delete newSymbol;
	}	
}
