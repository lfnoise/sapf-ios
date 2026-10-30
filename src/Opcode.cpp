//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#include "Opcode.hpp"
#include "clz.hpp"

const char* opcode_name[kNumOpcodes] = 
{
	"BAD OPCODE",
	"opNone",
	"opPushImmediate",
	"opPushLocalVar",
	"opPushFunVar",
	"opPushWorkspaceVar",
	
	"opPushFun",

	"opCallImmediate",
	"opCallLocalVar",
	"opCallFunVar",
	"opCallWorkspaceVar",

	"opDot",
	"opComma",
	"opBindLocal",
	"opBindLocalFromList",
	"opBindWorkspaceVar",
	"opBindWorkspaceVarFromList",
	
	"opParens",
	"opNewVList",
	"opNewZList",
	"opNewForm",
	"opInherit",
	"opEach",
	"opReturn"
};


static void printOpcode(Thread& th, Opcode* c)
{
	V& v = c->v;
	post("%p %s ", c, opcode_name[c->op]);
	switch (c->op) {
		case opPushImmediate :
		case opPushWorkspaceVar :
		case opPushFun : 
		case opCallImmediate :
		case opCallWorkspaceVar :
		case opDot :
		case opComma :
		case opInherit :
		case opNewForm :
		case opBindWorkspaceVar :
		case opBindWorkspaceVarFromList :
		case opParens :
		case opNewVList : 
		case opNewZList : 
			v.printShort(th);
			break;
			
		case opPushLocalVar :
		case opPushFunVar :
		case opCallLocalVar :
		case opCallFunVar :
		case opBindLocal :
		case opBindLocalFromList :
			post("%lld", (int64_t)v.i);
			break;
		case opEach :
			post("%llx", (int64_t)v.i);
			break;
		
		case opNone :
		case opReturn : 
			break;
		
		default :
			post("BAD OPCODE\n");
	}
	post("\n");
}

void Thread::run(Opcode* opc)
{
	Thread& th = *this;
	try {
		for (;;++opc) {

			V& v = opc->v;

			if (vm.traceon) {
				post("stack : "); th.printStack(); post("\n");
				printOpcode(th, opc);
			}

			switch (opc->op) {
				case opNone :
					break;
					
				case opPushImmediate :
					push(v);
					break;
					
				case opPushLocalVar :
					push(getLocal(v.i));
					break;
					
				case opPushFunVar :
					push(fun->mVars[v.i]);
					break;
					
				case opPushWorkspaceVar :
					push(fun->Workspace()->mustGet(th, v));
					break;
					
				case opPushFun : {
						push(new Fun(th, (FunDef*)v.o()));
					} break;
					
				case opCallImmediate :
					v.apply(th);
					break;
					
				case opCallLocalVar :
					getLocal(v.i).apply(th);
					break;
					
				case opCallFunVar :
					fun->mVars[v.i].apply(th);
					break;
					
				case opCallWorkspaceVar :
					fun->Workspace()->mustGet(th, v).apply(th);
					break;

				case opDot : {
					V ioValue;
					if (!pop().dot(th, v, ioValue))
						notFound(v);
					push(ioValue);
					break;
				}
				case opComma :
					push(pop().comma(th, v));
					break;
					
				case opBindLocal :
					getLocal(v.i) = pop();
					break;
				case opBindWorkspaceVar : {
                    V value = pop();
                    if (value.isList() && !value.isFinite()) {
                        post("WARNING: binding a possibly infinite list at the top level can leak unbounded memory!\n");
                    } else if (value.isFun()) {
						const char* mask = value.GetAutoMapMask();
						const char* help = value.OneLineHelp();
						if (mask || help) {
							char* name = ((String*)v.o())->s;
							vm.addUdfHelp(name, mask, help);
						}
					}
					fun->Workspace() = fun->Workspace()->putImpure(v, value); // workspace mutation
					th.mWorkspace = th.mWorkspace->putImpure(v, value); // workspace mutation
                } break;
                
				case opBindLocalFromList :
				case opBindWorkspaceVarFromList :
				{
					V list = pop();
					BothIn in(list);
					while (1) {
						if (opc->op == opNone) {
							break;
						} else {
							V value;
							if (in.one(th, value)) {
								post("not enough items in list for = [..]\n");
								throw errFailed;
							}
							if (opc->op == opBindLocalFromList) {
								getLocal(opc->v.i) = value;
							} else if (opc->op == opBindWorkspaceVarFromList) {
								v = opc->v;
								if (value.isList() && !value.isFinite()) {
									post("WARNING: binding a possibly infinite list at the top level can leak unbounded memory!\n");
								} else if (value.isFun()) {
									const char* mask = value.GetAutoMapMask();
									const char* help = value.OneLineHelp();
									if (mask || help) {
										char* name = ((String*)v.o())->s;
										vm.addUdfHelp(name, mask, help);
									}
								}
								fun->Workspace() = fun->Workspace()->putImpure(v, value); // workspace mutation
								th.mWorkspace = th.mWorkspace->putImpure(v, value); // workspace mutation
							}
						}
						++opc;
					}
				} break;
				case opParens : {
						ParenStack ss(th);
						run(((Code*)v.o())->getOps());
					} break;
				case opNewVList : {
						V x;
						{
							SaveStack ss(th);
							run(((Code*)v.o())->getOps());
							size_t len = stackDepth();
							vm.newVList->apply_n(th, len);
							x = th.pop();
						}
						th.push(x);
					} break;
				case opNewZList : {
						V x;
						{
							SaveStack ss(th);
							run(((Code*)v.o())->getOps());
							size_t len = stackDepth();
							vm.newZList->apply_n(th, len);
							x = th.pop();
						}
						th.push(x);
					} break;
				case opInherit : {
						V result;
						{
							SaveStack ss(th);
							run(((Code*)v.o())->getOps());
							size_t depth = stackDepth();
							if (depth < 1) {
								result = vm._ee;
							} else if (depth > 1) {
								fprintf(stderr, "more arguments than keys for form.\n");
								throw errFailed;
							} else {
								vm.inherit->apply_n(th, 1);
								result = th.pop();
							}
						}
						th.push(result);
					} break;
				case opNewForm : {
						V result;
						{
							SaveStack ss(th);
							run(((Code*)v.o())->getOps());
							size_t depth = stackDepth();
							TableMap* tmap = (TableMap*)th.top().o();
							size_t numArgs = tmap->mSize;
							if (depth == numArgs+1) {
								// no inheritance, must insert zero for parent.
								th.tuck(numArgs+1, V(0.));
							} else if (depth < numArgs+1) {
								fprintf(stderr, "fewer arguments than keys for form.\n");
								throw errStackUnderflow;
							} else if (depth > numArgs+2) {
								fprintf(stderr, "more arguments than keys for form.\n");
								throw errFailed;
							}
							vm.newForm->apply_n(th, numArgs+2);
							result = th.pop();
						}
						th.push(result);
					} break;
				case opEach :
					push(new EachOp(pop(), (int)v.i));
					break;
				
				case opReturn : return;
				
				default :
					post("BAD OPCODE\n");
					throw errInternalError;
			}
		}
	} catch (...) {
		post("backtrace: %s ", opcode_name[opc->op]);
		opc->v.printShort(th);
		post("\n");
		throw;
	}
}

Code::~Code() { }

void Code::shrinkToFit()
{
	std::vector<Opcode>(ops.begin(), ops.end()).swap(ops);
}

void Code::add(int _op, Arg v)
{
	ops.push_back(Opcode(_op, v));
}

void Code::add(int _op, double f)
{
	add(_op, V(f));
}

void Code::addAll(const P<Code> &that)
{
	for (Opcode& op : that->ops) {
		ops.push_back(op);
	}
}

void Code::decompile(Thread& th, std::string& out)
{
	for (Opcode& c : ops) {
		V& v = c.v;
		switch (c.op) {
			case opPushImmediate : {
				std::string s;
				v.printShort(th, s);
				out += s;
				break;
			}
			case opPushWorkspaceVar :
			case opPushFun : 
			case opCallImmediate :
			case opCallWorkspaceVar :
			case opDot :
			case opComma :
			case opInherit :
			case opNewForm :
			case opBindWorkspaceVar :
			case opBindWorkspaceVarFromList :
			case opParens :
			case opNewVList : 
			case opNewZList : 
				v.printShort(th);
				break;
				
			case opPushLocalVar :
			case opPushFunVar :
			case opCallLocalVar :
			case opCallFunVar :
			case opBindLocal :
			case opBindLocalFromList :
				post("%lld", (int64_t)v.i);
				break;
			case opEach :
				post("%llx", (int64_t)v.i);
				break;
			
			case opNone :
			case opReturn : 
				break;
			
			default :
				post("BAD OPCODE\n");
		}
	}
}

