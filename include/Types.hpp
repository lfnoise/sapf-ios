//    SAPF - Sound As Pure Form
//    Copyright (C) 2019 James McCartney
//
//    This Source Code Form is subject to the terms of the Mozilla Public
//    License, v. 2.0. If a copy of the MPL was not distributed with this
//    file, You can obtain one at https://mozilla.org/MPL/2.0/.

#ifndef __boxeddoubles__Types__
#define __boxeddoubles__Types__

#include "Object.hpp"

enum {
	stackEffectUnknown = -1
};

enum {
	rankUnknown = -2,
	rankVariable = -1
};

enum {
	shapeUnknown    = -4,
	shapeInfinite   = -3,
	shapeIndefinite = -2,
	shapeFinite     = -1
};

class StackEffect : public Object
{
	int mTakes;
	int mLeaves;
	
	StackEffect() : mTakes(stackEffectUnknown), mLeaves(stackEffectUnknown) {}
	StackEffect(int inTakes, int inLeaves) : mTakes(stackEffectUnknown), mLeaves(stackEffectUnknown) {}
};

class TypeEnvir;

struct TypeShape
{
	int mRank = rankUnknown;
	std::vector<int> mShape;
	
	TypeShape() {}
	TypeShape(TypeShape const& that) : mRank(that.mRank), mShape(that.mShape) {}
	TypeShape& operator=(TypeShape const& that) { mRank = that.mRank; mShape = that.mShape; return *this; }
	
	bool unify(TypeShape const& inThat, TypeShape& outResult)
	{
		if (mRank == rankUnknown) {
			if (inThat.mRank == rankUnknown) {
				outResult = *this;
				return true;
			}
			outResult = inThat;
			return true;
		}
		if (mRank != inThat.mRank)
			return false;
		outResult = inThat;
		for (int i = 0; i < mRank; ++i) {
			int  a = mShape[i];
			int  b = inThat.mShape[i];
			int& c = outResult.mShape[i];
			if (a == shapeUnknown) {
				c = b;
			} else if (b == shapeUnknown) {
				c = a;
			} else if (a != b) {
				return false;
			} else {
				c = a;
			}
		}
		return true;
	}
	
	// determine shape of auto mapped result
	// determing shape of binary operator results
	// e.g.    [r...] * r  -> [r...]
	//         [[r]] * [r] -> [[r]]
	//         [r..] * [r] -> [r]   maximum rank, minimum shape.
	// also with each operators
	
};

class Type : public Object
{
public:
	TypeShape mShape;

	Type() {}
	Type(TypeShape const& inShape) : mShape(inShape) {}
	virtual ~Type() {}
	
	virtual bool unify(P<Type> const& inThat, P<TypeEnvir>& ioEnvir, P<Type>& outResult) = 0;

	virtual bool isTypeReal() const { return false; }
	virtual bool isTypeSignal() const { return false; }
	virtual bool isTypeRef() const { return false; }
	virtual bool isTypeFun() const { return false; }
	virtual bool isTypeForm() const { return false; }
	virtual bool isTypeTuple() const { return false; }
};

class TypeUnknown : public Type
{
	const char* TypeName() const { return "TypeReal"; }
	virtual bool unify(P<Type> const& inThat, P<TypeEnvir>& ioEnvir, P<Type>& outResult)
	{
		TypeShape shape;
		if (!mShape.unify(inThat->mShape, shape))
			return false;
			
		outResult = inThat;
		return true;
	}
};

class TypeVar : public Object
{
	int32_t mID;
	P<Type> mType;
};

class TypeEnvir : public Object
{
	std::vector<P<TypeVar>> mTypeVars;
};

class TypeReal : public Type
{
public:
	TypeReal() {}
	TypeReal(TypeShape const& inShape) : Type(inShape) {}
	

	const char* TypeName() const { return "TypeReal"; }
	
	virtual bool unify(P<Type> const& inThat, P<TypeEnvir>& ioEnvir, P<Type>& outResult)
	{
		TypeShape shape;
		if (!mShape.unify(inThat->mShape, shape))
			return false;

		if (inThat->isTypeReal() || inThat->isTypeSignal()) {
			outResult = new TypeReal(shape);
			return true;
		}
		return false;
	}
};

class TypeSignal : public Type
{
	int mSignalShape = shapeUnknown;
public:

	TypeSignal() {}
	TypeSignal(TypeShape const& inShape, int inSignalShape) : Type(inShape), mSignalShape(inSignalShape) {}

	const char* TypeName() const { return "TypeSignal"; }

	virtual bool unify(P<Type> const& inThat, P<TypeEnvir>& ioEnvir, P<Type>& outResult)
	{
		TypeShape shape;
		if (!mShape.unify(inThat->mShape, shape))
			return false;
		
		if (inThat->isTypeReal()) {
			outResult = new TypeReal(shape);
			return true;
		}
		if (inThat->isTypeSignal()) {
			// unify signal shape
			outResult = new TypeSignal(shape, mSignalShape);
			return true;
		}
		return false;
	}
};

class TypeRef : public Type
{
public:
	P<Type> mRefType;


	const char* TypeName() const { return "TypeRef"; }
};

class TypeFun : public Type
{
	std::vector<P<Type>> mInTypes;
	std::vector<P<Type>> mOutTypes;

	const char* TypeName() const { return "TypeFun"; }
};

struct FieldType
{
	P<String> mLabel;
	P<Type> mType;
};

class TypeForm : public Type
{
	std::vector<FieldType> mFieldTypes;

	const char* TypeName() const { return "TypeForm"; }
};

class TypeTuple : public Type
{
	std::vector<P<Type>> mTypes;

	const char* TypeName() const { return "TypeTuple"; }
};

#endif /* defined(__boxeddoubles__Types__) */
