#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

# abstract syntax tree + symbol table

import
  lineinfos, hashes, options, strutils, std / sha1, ropes,
  intsets

import pathutils

type
  TIdObj* = object of RootObj
    id*: int # unique id; use this for comparisons and not the pointers

  PIdObj* = ref TIdObj
  PIdent* = ref TIdent
  TIdent*{.acyclic.} = object of TIdObj
    s*: string
    next*: PIdent             # for hash-table chaining
    h*: Hash                 # hash value of s

  IdentCache* = ref object
    buckets: array[0..4096 * 2 - 1, PIdent]
    wordCounter: int
    idAnon*, idDelegator*, emptyIdent*: PIdent

proc resetIdentCache*() = discard

proc cmpIgnoreStyle*(a, b: cstring, blen: int): int =
  if a[0] != b[0]: return 1
  var i = 0
  var j = 0
  result = 1
  while j < blen:
    while a[i] == '_': inc(i)
    while b[j] == '_': inc(j)
    # tolower inlined:
    var aa = a[i]
    var bb = b[j]
    if aa >= 'A' and aa <= 'Z': aa = chr(ord(aa) + (ord('a') - ord('A')))
    if bb >= 'A' and bb <= 'Z': bb = chr(ord(bb) + (ord('a') - ord('A')))
    result = ord(aa) - ord(bb)
    if (result != 0) or (aa == '\0'): break
    inc(i)
    inc(j)
  if result == 0:
    if a[i] != '\0': result = 1

proc cmpExact(a, b: cstring, blen: int): int =
  var i = 0
  var j = 0
  result = 1
  while j < blen:
    var aa = a[i]
    var bb = b[j]
    result = ord(aa) - ord(bb)
    if (result != 0) or (aa == '\0'): break
    inc(i)
    inc(j)
  if result == 0:
    if a[i] != '\0': result = 1

proc getIdent*(ic: IdentCache; identifier: cstring, length: int, h: Hash): PIdent =
  var idx = h and high(ic.buckets)
  result = ic.buckets[idx]
  var last: PIdent = nil
  var id = 0
  while result != nil:
    if cmpExact(cstring(result.s), identifier, length) == 0:
      if last != nil:
        # make access to last looked up identifier faster:
        last.next = result.next
        result.next = ic.buckets[idx]
        ic.buckets[idx] = result
      return
    elif cmpIgnoreStyle(cstring(result.s), identifier, length) == 0:
      assert((id == 0) or (id == result.id))
      id = result.id
    last = result
    result = result.next
  new(result)
  result.h = h
  result.s = newString(length)
  for i in 0 ..< length: result.s[i] = identifier[i]
  result.next = ic.buckets[idx]
  ic.buckets[idx] = result
  if id == 0:
    inc(ic.wordCounter)
    result.id = -ic.wordCounter
  else:
    result.id = id

proc getIdent*(ic: IdentCache; identifier: string): PIdent =
  result = getIdent(ic, cstring(identifier), len(identifier),
                    hashIgnoreStyle(identifier))

proc getIdent*(ic: IdentCache; identifier: string, h: Hash): PIdent =
  result = getIdent(ic, cstring(identifier), len(identifier), h)

proc newIdentCache*(): IdentCache =
  result = IdentCache()
  result.idAnon = result.getIdent":anonymous"
  result.wordCounter = 1
  result.idDelegator = result.getIdent":delegator"
  result.emptyIdent = result.getIdent("")
  # initialize the keywords:
  # for s in succ(low(specialWords)) .. high(specialWords):
  #   result.getIdent(specialWords[s], hashIgnoreStyle(specialWords[s])).id = ord(s)

# proc whichKeyword*(id: PIdent): TSpecialWord =
#   if id.id < 0: result = wInvalid
#   else: result = TSpecialWord(id.id)

type
  TCallingConvention* = enum
    ccDefault,                # proc has no explicit calling convention
    ccStdCall,                # procedure is stdcall
    ccCDecl,                  # cdecl
    ccSafeCall,               # safecall
    ccSysCall,                # system call
    ccInline,                 # proc should be inlined
    ccNoInline,               # proc should not be inlined
    ccFastCall,               # fastcall (pass parameters in registers)
    ccClosure,                # proc has a closure
    ccNoConvention            # needed for generating proper C procs sometimes

const
  CallingConvToStr*: array[TCallingConvention, string] = ["", "stdcall",
    "cdecl", "safecall", "syscall", "inline", "noinline", "fastcall",
    "closure", "noconv"]

type
  TNodeKind* = enum # order is extremely important, because ranges are used
                    # to check whether a node belongs to a certain class
    nkNone,               # unknown node kind: indicates an error
                          # Expressions:
                          # Atoms:
    nkEmpty,              # the node is empty
    nkNilLit,             # the node is empty
    nkComesFrom,          # the node is empty
    nkRawCode,            # a character literal ''
    nkImportStmt,         # an import statement
    nkCommentStmt,        # a comment statement
    nkStmtList            # a comment statement


  TNodeKinds* = set[TNodeKind]

type
  TSymFlag* = enum    # already 36 flags!
    sfUsed,           # read access of sym (for warnings) or simply used
    sfExported,       # symbol is exported from module
    sfFromGeneric,    # symbol is instantiation of a generic; this is needed
                      # for symbol file generation; such symbols should always
                      # be written into the ROD file
    sfGlobal,         # symbol is at global scope

    sfForward,        # symbol is forward declared
    sfImportc,        # symbol is external; imported
    sfExportc,        # symbol is exported (under a specified name)
    sfVolatile,       # variable is volatile
    sfRegister,       # variable should be placed in a register
    sfPure,           # object is "pure" that means it has no type-information
                      # enum is "pure", its values need qualified access
                      # variable is "pure"; it's an explicit "global"
    sfNoSideEffect,   # proc has no side effects
    sfSideEffect,     # proc may have side effects; cannot prove it has none
    sfMainModule,     # module is the main module
    sfSystemModule,   # module is the system module
    sfNoReturn,       # proc never returns (an exit proc)
    sfAddrTaken,      # the variable's address is taken (ex- or implicitly);
                      # *OR*: a proc is indirectly called (used as first class)
    sfCompilerProc,   # proc is a compiler proc, that is a C proc that is
                      # needed for the code generator
    sfProcvar,        # proc can be passed to a proc var
    sfDiscriminant,   # field is a discriminant in a record/object
    sfDeprecated,     # symbol is deprecated
    sfExplain,        # provide more diagnostics when this symbol is used
    sfError,          # usage of symbol should trigger a compile-time error
    sfShadowed,       # a symbol that was shadowed in some inner scope
    sfThread,         # proc will run as a thread
                      # variable is a thread variable
    sfCompileTime,    # proc can be evaluated at compile time
    sfConstructor,    # proc is a C++ constructor
    sfDispatcher,     # copied method symbol is the dispatcher
                      # deprecated and unused, except for the con
    sfBorrow,         # proc is borrowed
    sfInfixCall,      # symbol needs infix call syntax in target language;
                      # for interfacing with C++, JS
    sfNamedParamCall, # symbol needs named parameter call syntax in target
                      # language; for interfacing with Objective C
    sfDiscardable,    # returned value may be discarded implicitly
    sfOverriden,      # proc is overriden
    sfCallsite        # A flag for template symbols to tell the
                      # compiler it should use line information from
                      # the calling side of the macro, not from the
                      # implementation.
    sfGenSym          # symbol is 'gensym'ed; do not add to symbol table
    sfNonReloadable   # symbol will be left as-is when hot code reloading is on -
                      # meaning that it won't be renamed and/or changed in any way
    sfGeneratedOp     # proc is a generated '='; do not inject destructors in it
                      # variable is generated closure environment; requires early
                      # destruction for --newruntime.


  TSymFlags* = set[TSymFlag]

const
  sfNoInit* = sfMainModule       # don't generate code to init the variable

  sfCursor* = sfDispatcher
    # local variable has been computed to be a "cursor".
    # see cursors.nim for details about what that means.

  sfAllUntyped* = sfVolatile # macro or template is immediately expanded \
    # in a generic context

  sfDirty* = sfPure
    # template is not hygienic (old styled template)
    # module, compiled from a dirty-buffer

  sfAnon* = sfDiscardable
    # symbol name that was generated by the compiler
    # the compiler will avoid printing such names
    # in user messages.

  sfHoisted* = sfForward
    # an expression was hoised to an anonymous variable.
    # the flag is applied to the var/let symbol

  sfNoForward* = sfRegister
    # forward declarations are not required (per module)
  sfReorder* = sfForward
    # reordering pass is enabled

  sfCompileToCpp* = sfInfixCall       # compile the module as C++ code
  sfCompileToObjc* = sfNamedParamCall # compile the module as Objective-C code
  sfExperimental* = sfOverriden       # module uses the .experimental switch
  sfGoto* = sfOverriden               # var is used for 'goto' code generation
  sfWrittenTo* = sfBorrow             # param is assigned to
  sfEscapes* = sfProcvar              # param escapes
  sfBase* = sfDiscriminant
  sfIsSelf* = sfOverriden             # param is 'self'
  sfCustomPragma* = sfRegister        # symbol is custom pragma template

type
  TTypeKind* = enum  # order is important!
                     # Don't forget to change hti.nim if you make a change here
                     # XXX put this into an include file to avoid this issue!
                     # several types are no longer used (guess which), but a
                     # spot in the sequence is kept for backwards compatibility
                     # (apparently something with bootstrapping)
                     # if you need to add a type, they can apparently be reused
    tyNone, tyBool, tyChar,
    tyEmpty, tyAlias, tyNil, tyUntyped, tyTyped, tyTypeDesc,
    tyGenericInvocation, # ``T[a, b]`` for types to invoke
    tyGenericBody,       # ``T[a, b, body]`` last parameter is the body
    tyGenericInst,       # ``T[a, b, realInstance]`` instantiated generic type
                         # realInstance will be a concrete type like tyObject
                         # unless this is an instance of a generic alias type.
                         # then realInstance will be the tyGenericInst of the
                         # completely (recursively) resolved alias.

    tyGenericParam,      # ``a`` in the above patterns
    tyDistinct,
    tyEnum,
    tyOrdinal,           # integer types (including enums and boolean)
    tyArray,
    tyObject,
    tyTuple,
    tySet,
    tyRange,
    tyPtr, tyRef,
    tyVar,
    tySequence,
    tyProc,
    tyPointer, tyOpenArray,
    tyString, tyCString, tyForward,
    tyInt, tyInt8, tyInt16, tyInt32, tyInt64, # signed integers
    tyFloat, tyFloat32, tyFloat64, tyFloat128,
    tyUInt, tyUInt8, tyUInt16, tyUInt32, tyUInt64,
    tyOwned, tySink, tyLent,
    tyVarargs,
    tyUncheckedArray
      # An array with boundaries [0,+∞]

    tyProxy # used as errornous type (for idetools)

    tyBuiltInTypeClass
      # Type such as the catch-all object, tuple, seq, etc

    tyUserTypeClass
      # the body of a user-defined type class

    tyUserTypeClassInst
      # Instance of a parametric user-defined type class.
      # Structured similarly to tyGenericInst.
      # tyGenericInst represents concrete types, while
      # this is still a "generic param" that will bind types
      # and resolves them during sigmatch and instantiation.

    tyCompositeTypeClass
      # Type such as seq[Number]
      # The notes for tyUserTypeClassInst apply here as well
      # sons[0]: the original expression used by the user.
      # sons[1]: fully expanded and instantiated meta type
      # (potentially following aliases)

    tyInferred
      # In the initial state `base` stores a type class constraining
      # the types that can be inferred. After a candidate type is
      # selected, it's stored in `lastSon`. Between `base` and `lastSon`
      # there may be 0, 2 or more types that were also considered as
      # possible candidates in the inference process (i.e. lastSon will
      # be updated to store a type best conforming to all candidates)

    tyAnd, tyOr, tyNot
      # boolean type classes such as `string|int`,`not seq`,
      # `Sortable and Enumable`, etc

    tyAnything
      # a type class matching any type

    tyStatic
      # a value known at compile type (the underlying type is .base)

    tyFromExpr
      # This is a type representing an expression that depends
      # on generic parameters (the expression is stored in t.n)
      # It will be converted to a real type only during generic
      # instantiation and prior to this it has the potential to
      # be any type.

    tyOpt
      # Builtin optional type

    tyVoid
      # now different from tyEmpty, hurray!

static:
  # remind us when TTypeKind stops to fit in a single 64-bit word
  assert TTypeKind.high.ord <= 63

const
  tyPureObject* = tyTuple
  GcTypeKinds* = {tyRef, tySequence, tyString}
  tyError* = tyProxy # as an errornous node should match everything
  tyUnknown* = tyFromExpr

  tyUnknownTypes* = {tyError, tyFromExpr}

  tyTypeClasses* = {tyBuiltInTypeClass, tyCompositeTypeClass,
                    tyUserTypeClass, tyUserTypeClassInst,
                    tyAnd, tyOr, tyNot, tyAnything}

  tyMetaTypes* = {tyGenericParam, tyTypeDesc, tyUntyped} + tyTypeClasses
  tyUserTypeClasses* = {tyUserTypeClass, tyUserTypeClassInst}

type
  TTypeKinds* = set[TTypeKind]

  TTypeFlag* = enum   # keep below 32 for efficiency reasons (now: ~38)
    tfVarargs,        # procedure has C styled varargs
                      # tyArray type represeting a varargs list
    tfNoSideEffect,   # procedure type does not allow side effects
    tfFinal,          # is the object final?
    tfInheritable,    # is the object inheritable?
    tfHasOwned,       # type contains an 'owned' type and must be moved
    tfEnumHasHoles,   # enum cannot be mapped into a range
    tfShallow,        # type can be shallow copied on assignment
    tfThread,         # proc type is marked as ``thread``; alias for ``gcsafe``
    tfFromGeneric,    # type is an instantiation of a generic; this is needed
                      # because for instantiations of objects, structural
                      # type equality has to be used
    tfUnresolved,     # marks unresolved typedesc/static params: e.g.
                      # proc foo(T: typedesc, list: seq[T]): var T
                      # proc foo(L: static[int]): array[L, int]
                      # can be attached to ranges to indicate that the range
                      # can be attached to generic procs with free standing
                      # type parameters: e.g. proc foo[T]()
                      # depends on unresolved static params.
    tfResolved        # marks a user type class, after it has been bound to a
                      # concrete type (lastSon becomes the concrete type)
    tfRetType,        # marks return types in proc (used to detect type classes
                      # used as return types for return type inference)
    tfCapturesEnv,    # whether proc really captures some environment
    tfByCopy,         # pass object/tuple by copy (C backend)
    tfByRef,          # pass object/tuple by reference (C backend)
    tfIterator,       # type is really an iterator, not a tyProc
    tfPartial,        # type is declared as 'partial'
    tfNotNil,         # type cannot be 'nil'

    tfNeedsInit,      # type constains a "not nil" constraint somewhere or some
                      # other type so that it requires initialization
    tfVarIsPtr,       # 'var' type is translated like 'ptr' even in C++ mode
    tfHasMeta,        # type contains "wildcard" sub-types such as generic params
                      # or other type classes
    tfHasGCedMem,     # type contains GC'ed memory
    tfPacked
    tfHasStatic
    tfGenericTypeParam
    tfImplicitTypeParam
    tfInferrableStatic
    tfConceptMatchedTypeSym
    tfExplicit        # for typedescs, marks types explicitly prefixed with the
                      # `type` operator (e.g. type int)
    tfWildcard        # consider a proc like foo[T, I](x: Type[T, I])
                      # T and I here can bind to both typedesc and static types
                      # before this is determined, we'll consider them to be a
                      # wildcard type.
    tfHasAsgn         # type has overloaded assignment operator
    tfBorrowDot       # distinct type borrows '.'
    tfTriggersCompileTime # uses the NimNode type which make the proc
                          # implicitly '.compiletime'
    tfRefsAnonObj     # used for 'ref object' and 'ptr object'
    tfCovariant       # covariant generic param mimicing a ptr type
    tfWeakCovariant   # covariant generic param mimicing a seq/array type
    tfContravariant   # contravariant generic param
    tfCheckedForDestructor # type was checked for having a destructor.
                           # If it has one, t.destructor is not nil.

  TTypeFlags* = set[TTypeFlag]

  TSymKind* = enum        # the different symbols (start with the prefix sk);
                          # order is important for the documentation generator!
    skUnknown,            # unknown symbol: used for parsing assembler blocks
                          # and first phase symbol lookup in generics
    skConditional,        # symbol for the preprocessor (may become obsolete)
    skDynLib,             # symbol represents a dynamic library; this is used
                          # internally; it does not exist in Nim code
    skParam,              # a parameter
    skGenericParam,       # a generic parameter; eq in ``proc x[eq=`==`]()``
    skTemp,               # a temporary variable (introduced by compiler)
    skModule,             # module identifier
    skType,               # a type
    skVar,                # a variable
    skLet,                # a 'let' symbol
    skConst,              # a constant
    skResult,             # special 'result' variable
    skProc,               # a proc
    skFunc,               # a func
    skMethod,             # a method
    skIterator,           # an iterator
    skConverter,          # a type converter
    skMacro,              # a macro
    skTemplate,           # a template; currently also misused for user-defined
                          # pragmas
    skField,              # a field in a record or object
    skEnumField,          # an identifier in an enum
    skForVar,             # a for loop variable
    skLabel,              # a label (for block statement)
    skStub,               # symbol is a stub and not yet loaded from the ROD
                          # file (it is loaded on demand, which may
                          # mean: never)
    skPackage,            # symbol is a package (used for canonicalization)
    skAlias               # an alias (needs to be resolved immediately)
  TSymKinds* = set[TSymKind]

const
  routineKinds* = {skProc, skFunc, skMethod, skIterator,
                   skConverter, skMacro, skTemplate}
  tfIncompleteStruct* = tfVarargs
  tfUnion* = tfNoSideEffect
  tfGcSafe* = tfThread
  tfObjHasKids* = tfEnumHasHoles
  tfReturnsNew* = tfInheritable
  skError* = skUnknown

  # type flags that are essential for type equality:
  eqTypeFlags* = {tfIterator, tfNotNil, tfVarIsPtr}

type
  TMagic* = enum # symbols that require compiler magic:
    mNone,
    mDefined, mDefinedInScope, mCompiles, mArrGet, mArrPut, mAsgn,
    mLow, mHigh, mSizeOf, mAlignOf, mOffsetOf, mTypeTrait,
    mIs, mOf, mAddr, mType, mTypeOf,
    mRoof, mPlugin, mEcho, mShallowCopy, mSlurp, mStaticExec, mStatic,
    mParseExprToAst, mParseStmtToAst, mExpandToAst, mQuoteAst,
    mUnaryLt, mInc, mDec, mOrd,
    mNew, mNewFinalize, mNewSeq, mNewSeqOfCap,
    mLengthOpenArray, mLengthStr, mLengthArray, mLengthSeq,
    mXLenStr, mXLenSeq,
    mIncl, mExcl, mCard, mChr,
    mGCref, mGCunref,
    mAddI, mSubI, mMulI, mDivI, mModI,
    mSucc, mPred,
    mAddF64, mSubF64, mMulF64, mDivF64,
    mShrI, mShlI, mAshrI, mBitandI, mBitorI, mBitxorI,
    mMinI, mMaxI,
    mMinF64, mMaxF64,
    mAddU, mSubU, mMulU, mDivU, mModU,
    mEqI, mLeI, mLtI,
    mEqF64, mLeF64, mLtF64,
    mLeU, mLtU,
    mLeU64, mLtU64,
    mEqEnum, mLeEnum, mLtEnum,
    mEqCh, mLeCh, mLtCh,
    mEqB, mLeB, mLtB,
    mEqRef, mEqUntracedRef, mLePtr, mLtPtr,
    mXor, mEqCString, mEqProc,
    mUnaryMinusI, mUnaryMinusI64, mAbsI, mNot,
    mUnaryPlusI, mBitnotI,
    mUnaryPlusF64, mUnaryMinusF64, mAbsF64,
    mToFloat, mToBiggestFloat,
    mToInt, mToBiggestInt,
    mCharToStr, mBoolToStr, mIntToStr, mInt64ToStr, mFloatToStr, mCStrToStr,
    mStrToStr, mEnumToStr,
    mAnd, mOr,
    mEqStr, mLeStr, mLtStr,
    mEqSet, mLeSet, mLtSet, mMulSet, mPlusSet, mMinusSet, mSymDiffSet,
    mConStrStr, mSlice,
    mDotDot, # this one is only necessary to give nice compile time warnings
    mFields, mFieldPairs, mOmpParFor,
    mAppendStrCh, mAppendStrStr, mAppendSeqElem,
    mInRange, mInSet, mRepr, mExit,
    mSetLengthStr, mSetLengthSeq,
    mIsPartOf, mAstToStr, mParallel,
    mSwap, mIsNil, mArrToSeq, mCopyStr, mCopyStrLast,
    mNewString, mNewStringOfCap, mParseBiggestFloat,
    mMove, mWasMoved, mDestroy,
    mDefault, mUnown, mAccessEnv, mReset,
    mArray, mOpenArray, mRange, mSet, mSeq, mOpt, mVarargs,
    mRef, mPtr, mVar, mDistinct, mVoid, mTuple,
    mOrdinal,
    mInt, mInt8, mInt16, mInt32, mInt64,
    mUInt, mUInt8, mUInt16, mUInt32, mUInt64,
    mFloat, mFloat32, mFloat64, mFloat128,
    mBool, mChar, mString, mCstring,
    mPointer, mEmptySet, mIntSetBaseType, mNil, mExpr, mStmt, mTypeDesc,
    mVoidType, mPNimrodNode, mShared, mGuarded, mLock, mSpawn, mDeepCopy,
    mIsMainModule, mCompileDate, mCompileTime, mProcCall,
    mCpuEndian, mHostOS, mHostCPU, mBuildOS, mBuildCPU, mAppType,
    mCompileOption, mCompileOptionArg,
    mNLen, mNChild, mNSetChild, mNAdd, mNAddMultiple, mNDel,
    mNKind, mNSymKind,

    mNccValue, mNccInc, mNcsAdd, mNcsIncl, mNcsLen, mNcsAt,
    mNctPut, mNctLen, mNctGet, mNctHasNext, mNctNext,

    mNIntVal, mNFloatVal, mNSymbol, mNIdent, mNGetType, mNStrVal, mNSetIntVal,
    mNSetFloatVal, mNSetSymbol, mNSetIdent, mNSetType, mNSetStrVal, mNLineInfo,
    mNNewNimNode, mNCopyNimNode, mNCopyNimTree, mStrToIdent, mNSigHash, mNSizeOf,
    mNBindSym, mLocals, mNCallSite,
    mEqIdent, mEqNimrodNode, mSameNodeType, mGetImpl, mNGenSym,
    mNHint, mNWarning, mNError,
    mInstantiationInfo, mGetTypeInfo,
    mNimvm, mIntDefine, mStrDefine, mBoolDefine, mRunnableExamples,
    mException, mBuiltinType, mSymOwner, mUncheckedArray, mGetImplTransf,
    mSymIsInstantiationOf

# things that we can evaluate safely at compile time, even if not asked for it:
const
  ctfeWhitelist* = {mNone, mUnaryLt, mSucc,
    mPred, mInc, mDec, mOrd, mLengthOpenArray,
    mLengthStr, mLengthArray, mLengthSeq, mXLenStr, mXLenSeq,
    mArrGet, mArrPut, mAsgn, mDestroy,
    mIncl, mExcl, mCard, mChr,
    mAddI, mSubI, mMulI, mDivI, mModI,
    mAddF64, mSubF64, mMulF64, mDivF64,
    mShrI, mShlI, mBitandI, mBitorI, mBitxorI,
    mMinI, mMaxI,
    mMinF64, mMaxF64,
    mAddU, mSubU, mMulU, mDivU, mModU,
    mEqI, mLeI, mLtI,
    mEqF64, mLeF64, mLtF64,
    mLeU, mLtU,
    mLeU64, mLtU64,
    mEqEnum, mLeEnum, mLtEnum,
    mEqCh, mLeCh, mLtCh,
    mEqB, mLeB, mLtB,
    mEqRef, mEqProc, mEqUntracedRef, mLePtr, mLtPtr, mEqCString, mXor,
    mUnaryMinusI, mUnaryMinusI64, mAbsI, mNot, mUnaryPlusI, mBitnotI,
    mUnaryPlusF64, mUnaryMinusF64, mAbsF64,
    mToFloat, mToBiggestFloat,
    mToInt, mToBiggestInt,
    mCharToStr, mBoolToStr, mIntToStr, mInt64ToStr, mFloatToStr, mCStrToStr,
    mStrToStr, mEnumToStr,
    mAnd, mOr,
    mEqStr, mLeStr, mLtStr,
    mEqSet, mLeSet, mLtSet, mMulSet, mPlusSet, mMinusSet, mSymDiffSet,
    mConStrStr, mAppendStrCh, mAppendStrStr, mAppendSeqElem,
    mInRange, mInSet, mRepr,
    mCopyStr, mCopyStrLast}

type
  PNode* = ref TNode
  TNodeSeq* = seq[PNode]
  PType* = ref TType
  PSym* = ref TSym
  TNode*{.final, acyclic.} = object # on a 32bit machine, this takes 32 bytes
    when defined(useNodeIds):
      id*: int
    typ*: PType
    info*: TLineInfo
    case kind*: TNodeKind
    of nkRawCode:
      strVals*: seq[string]
    of nkCommentStmt:
      comment*: string
    else:
      sons*: TNodeSeq

  # TStrTable* = object         # a table[PIdent] of PSym
  #   counter*: int
  #   data*: seq[PSym]

  # -------------- backend information -------------------------------
  TLocKind* = enum
    locNone,                  # no location
    locTemp,                  # temporary location
    locLocalVar,              # location is a local variable
    locGlobalVar,             # location is a global variable
    locParam,                 # location is a parameter
    locField,                 # location is a record field
    locExpr,                  # "location" is really an expression
    locProc,                  # location is a proc (an address of a procedure)
    locData,                  # location is a constant
    locCall,                  # location is a call expression
    locOther                  # location is something other
  TLocFlag* = enum
    lfIndirect,               # backend introduced a pointer
    lfFullExternalName, # only used when 'conf.cmd == cmdPretty': Indicates
      # that the symbol has been imported via 'importc: "fullname"' and
      # no format string.
    lfNoDeepCopy,             # no need for a deep copy
    lfNoDecl,                 # do not declare it in C
    lfDynamicLib,             # link symbol to dynamic library
    lfExportLib,              # export symbol for dynamic library generation
    lfHeader,                 # include header file for symbol
    lfImportCompilerProc,     # ``importc`` of a compilerproc
    lfSingleUse               # no location yet and will only be used once
    lfEnforceDeref            # a copyMem is required to dereference if this a
      # ptr array due to C array limitations. See #1181, #6422, #11171
  TStorageLoc* = enum
    OnUnknown,                # location is unknown (stack, heap or static)
    OnStatic,                 # in a static section
    OnStack,                  # location is on hardware stack
    OnHeap                    # location is on heap or global
                              # (reference counting needed)
  TLocFlags* = set[TLocFlag]
  TLoc* = object
    k*: TLocKind              # kind of location
    storage*: TStorageLoc
    flags*: TLocFlags         # location's flags
    lode*: PNode              # Node where the location came from; can be faked
    r*: Rope                  # rope value of location (code generators)

  # ---------------- end of backend information ------------------------------

  TLibKind* = enum
    libHeader, libDynamic

  TLib* = object              # also misused for headers!
    kind*: TLibKind
    generated*: bool          # needed for the backends:
    isOverriden*: bool
    name*: Rope
    path*: PNode              # can be a string literal!


  CompilesId* = int ## id that is used for the caching logic within
                    ## ``system.compiles``. See the seminst module.
  # TInstantiation* = object
  #   sym*: PSym
  #   concreteTypes*: seq[PType]
  #   compilesId*: CompilesId

  # PInstantiation* = ref TInstantiation

  # TScope* = object
  #   depthLevel*: int
  #   symbols*: TStrTable
  #   parent*: PScope

  # PScope* = ref TScope

  # PLib* = ref TLib

  TSym* {.acyclic.} = object of TIdObj
    # proc and type instantiations are cached in the generic symbol
    case kind*: TSymKind
    of skType, skGenericParam:
      typeInstCache*: seq[PType]
    of routineKinds:
      # procInstCache*: seq[PInstantiation]
      gcUnsafetyReason*: PSym  # for better error messages wrt gcsafe
      transformedBody*: PNode  # cached body after transf pass
    of skModule, skPackage:
      # modules keep track of the generic symbols they use from other modules.
      # this is because in incremental compilation, when a module is about to
      # be replaced with a newer version, we must decrement the usage count
      # of all previously used generics.
      # For 'import as' we copy the module symbol but shallowCopy the 'tab'
      # and set the 'usedGenerics' to ... XXX gah! Better set module.name
      # instead? But this doesn't work either. --> We need an skModuleAlias?
      # No need, just leave it as skModule but set the owner accordingly and
      # check for the owner when touching 'usedGenerics'.
      # usedGenerics*: seq[PInstantiation]
      # tab*: TStrTable         # interface table for modules
      discard
    of skLet, skVar, skField, skForVar:
      guard*: PSym
      bitsize*: int
    else: nil
    magic*: TMagic
    typ*: PType
    name*: PIdent
    info*: TLineInfo
    owner*: PSym
    flags*: TSymFlags
    ast*: PNode               # syntax tree of proc, iterator, etc.:
                              # the whole proc including header; this is used
                              # for easy generation of proper error messages
                              # for variant record fields the discriminant
                              # expression
                              # for modules, it's a placeholder for compiler
                              # generated code that will be appended to the
                              # module after the sem pass (see appendToModule)
    position*: int            # used for many different things:
                              # for enum fields its position;
                              # for fields its offset
                              # for parameters its position
                              # for a conditional:
                              # 1 iff the symbol is defined, else 0
                              # (or not in symbol table)
                              # for modules, an unique index corresponding
                              # to the module's fileIdx
                              # for variables a slot index for the evaluator
                              # for routines a superop-ID
    offset*: int              # offset of record field
    loc*: TLoc
    # annex*: PLib              # additional fields (seldom used, so we use a
    #                           # reference to another object to save space)
    constraint*: PNode        # additional constraints like 'lit|result'; also
                              # misused for the codegenDecl pragma in the hope
                              # it won't cause problems
                              # for skModule the string literal to output for
                              # deprecated modules.
    when defined(nimsuggest):
      allUsages*: seq[TLineInfo]

  TTypeSeq* = seq[PType]
  TLockLevel* = distinct int16

  TTypeAttachedOp* = enum ## as usual, order is important here
    attachedDestructor,
    attachedAsgn,
    attachedSink,
    attachedDeepCopy

  TType* {.acyclic.} = object of TIdObj # \
                              # types are identical iff they have the
                              # same id; there may be multiple copies of a type
                              # in memory!
    kind*: TTypeKind          # kind of type
    callConv*: TCallingConvention # for procs
    flags*: TTypeFlags        # flags of the type
    sons*: TTypeSeq           # base types, etc.
    n*: PNode                 # node for types:
                              # for range types a nkRange node
                              # for record types a nkRecord node
                              # for enum types a list of symbols
                              # for tyInt it can be the int literal
                              # for procs and tyGenericBody, it's the
                              # formal param list
                              # for concepts, the concept body
                              # else: unused
    # owner*: PSym              # the 'owner' of the type
    sym*: PSym                # types have the sym associated with them
                              # it is used for converting types to strings
    # attachedOps*: array[TTypeAttachedOp, PSym] # destructors, etc.
    methods*: seq[(int,PSym)] # attached methods
    size*: BiggestInt         # the size of the type in bytes
                              # -1 means that the size is unkwown
    align*: int16             # the type's alignment requirements
    lockLevel*: TLockLevel    # lock level as required for deadlock checking
    loc*: TLoc
    typeInst*: PType          # for generic instantiations the tyGenericInst that led to this
                              # type.
    uniqueId*: int            # due to a design mistake, we need to keep the real ID here as it
                              # required by the --incremental:on mode.

  TPair* = object
    key*, val*: RootRef

  TPairSeq* = seq[TPair]

  TIdPair* = object
    key*: PIdObj
    val*: RootRef

  TIdPairSeq* = seq[TIdPair]
  TIdTable* = object # the same as table[PIdent] of PObject
    counter*: int
    data*: TIdPairSeq

  TIdNodePair* = object
    key*: PIdObj
    val*: PNode

  TIdNodePairSeq* = seq[TIdNodePair]
  TIdNodeTable* = object # the same as table[PIdObj] of PNode
    counter*: int
    data*: TIdNodePairSeq

  TNodePair* = object
    h*: Hash                 # because it is expensive to compute!
    key*: PNode
    val*: int

  TNodePairSeq* = seq[TNodePair]
  TNodeTable* = object # the same as table[PNode] of int;
                                # nodes are compared by structure!
    counter*: int
    data*: TNodePairSeq

  TObjectSeq* = seq[RootRef]
  TObjectSet* = object
    counter*: int
    data*: TObjectSeq

  TImplication* = enum
    impUnknown, impNo, impYes

# BUGFIX: a module is overloadable so that a proc can have the
# same name as an imported module. This is necessary because of
# the poor naming choices in the standard library.

proc discardSons*(father: PNode)

proc len*(n: PNode): int {.inline.} =
  when defined(nimNoNilSeqs):
    result = len(n.sons)
  else:
    if isNil(n.sons): result = 0
    else: result = len(n.sons)

proc safeLen*(n: PNode): int {.inline.} =
  ## works even for leaves.
  if n.kind in {nkNone..nkNilLit}: result = 0
  else: result = len(n)

proc safeArrLen*(n: PNode): int {.inline.} =
  ## works for array-like objects (strings passed as openArray in VM).
  if n.kind in {nkRawCode..nkCommentStmt}:
    result = 0
    for v in n.strVals: result += len(n.strVals)
  elif n.kind in {nkNone, nkNilLit}:
    result = 0
  else: result = len(n)

proc add*(father, son: PNode) =
  assert son != nil
  when not defined(nimNoNilSeqs):
    if isNil(father.sons): father.sons = @[]
  add(father.sons, son)

type Indexable = PNode | PType

template `[]`*(n: Indexable, i: int): Indexable = n.sons[i]
template `[]=`*(n: Indexable, i: int; x: Indexable) = n.sons[i] = x

template `[]`*(n: Indexable, i: BackwardsIndex): Indexable = n[n.len - i.int]
template `[]=`*(n: Indexable, i: BackwardsIndex; x: Indexable) = n[n.len - i.int] = x

when defined(useNodeIds):
  const nodeIdToDebug* = -1 # 299750 # 300761 #300863 # 300879
  var gNodeId: int

proc newNode*(kind: TNodeKind): PNode =
  new(result)
  result.kind = kind
  #result.info = UnknownLineInfo() inlined:
  result.info.fileIndex = AbsoluteFile ""
  result.info.col = int16(-1)
  result.info.line = uint16(0)
  when defined(useNodeIds):
    result.id = gNodeId
    if result.id == nodeIdToDebug:
      echo "KIND ", result.kind
      writeStackTrace()
    inc gNodeId

proc newTree*(kind: TNodeKind; children: varargs[PNode]): PNode =
  result = newNode(kind)
  if children.len > 0:
    result.info = children[0].info
  result.sons = @children

template previouslyInferred*(t: PType): PType =
  if t.sons.len > 1: t.lastSon else: nil

proc newSym*(symKind: TSymKind, name: PIdent, owner: PSym,
             info: TLineInfo): PSym =
  # generates a symbol and initializes the hash field too
  new(result)
  result.name = name
  result.kind = symKind
  result.flags = {}
  result.info = info
  result.owner = owner
  result.offset = -1


template fileIdx*(c: PSym): FileIndex =
  # XXX: this should be used only on module symbols
  c.position.FileIndex

template filename*(c: PSym): string =
  # XXX: this should be used only on module symbols
  c.position.FileIndex.toFilename

const                         # for all kind of hash tables:
  GrowthFactor* = 2           # must be power of 2, > 0
  StartSize* = 8              # must be power of 2, > 0

# proc copyStrTable*(dest: var TStrTable, src: TStrTable) =
#   dest.counter = src.counter
#   setLen(dest.data, len(src.data))
#   for i in 0 .. high(src.data): dest.data[i] = src.data[i]

proc copyIdTable*(dest: var TIdTable, src: TIdTable) =
  dest.counter = src.counter
  newSeq(dest.data, len(src.data))
  for i in 0 .. high(src.data): dest.data[i] = src.data[i]

proc copyObjectSet*(dest: var TObjectSet, src: TObjectSet) =
  dest.counter = src.counter
  setLen(dest.data, len(src.data))
  for i in 0 .. high(src.data): dest.data[i] = src.data[i]

proc discardSons*(father: PNode) =
  when defined(nimNoNilSeqs):
    father.sons = @[]
  else:
    father.sons = nil

proc withInfo*(n: PNode, info: TLineInfo): PNode =
  n.info = info
  return n

# proc newIdentNode*(ident: PIdent, info: TLineInfo): PNode =
#   result = newNode(nkIdent)
#   result.ident = ident
#   result.info = info

# proc newSymNode*(sym: PSym): PNode =
#   result = newNode(nkSym)
#   result.sym = sym
#   result.typ = sym.typ
#   result.info = sym.info

# proc newSymNode*(sym: PSym, info: TLineInfo): PNode =
#   result = newNode(nkSym)
#   result.sym = sym
#   result.typ = sym.typ
#   result.info = info

proc newNodeI*(kind: TNodeKind, info: TLineInfo): PNode =
  new(result)
  result.kind = kind
  result.info = info
  when defined(useNodeIds):
    result.id = gNodeId
    if result.id == nodeIdToDebug:
      echo "KIND ", result.kind
      writeStackTrace()
    inc gNodeId

proc newNodeI*(kind: TNodeKind, info: TLineInfo, children: int): PNode =
  new(result)
  result.kind = kind
  result.info = info
  if children > 0:
    newSeq(result.sons, children)
  when defined(useNodeIds):
    result.id = gNodeId
    if result.id == nodeIdToDebug:
      echo "KIND ", result.kind
      writeStackTrace()
    inc gNodeId

proc newNode*(kind: TNodeKind, info: TLineInfo, sons: TNodeSeq = @[],
             typ: PType = nil): PNode =
  new(result)
  result.kind = kind
  result.info = info
  result.typ = typ
  # XXX use shallowCopy here for ownership transfer:
  result.sons = sons
  when defined(useNodeIds):
    result.id = gNodeId
    if result.id == nodeIdToDebug:
      echo "KIND ", result.kind
      writeStackTrace()
    inc gNodeId

proc newNodeIT*(kind: TNodeKind, info: TLineInfo, typ: PType): PNode =
  result = newNode(kind)
  result.info = info
  result.typ = typ



proc addSon*(father, son: PNode) =
  assert son != nil
  when not defined(nimNoNilSeqs):
    if isNil(father.sons): father.sons = @[]
  add(father.sons, son)

proc newProcNode*(kind: TNodeKind, info: TLineInfo, body: PNode,
                 params,
                 name, pattern, genericParams,
                 pragmas, exceptions: PNode): PNode =
  result = newNodeI(kind, info)
  result.sons = @[name, pattern, genericParams, params,
                  pragmas, exceptions, body]

const
  UnspecifiedLockLevel* = TLockLevel(-1'i16)
  MaxLockLevel* = 1000'i16
  UnknownLockLevel* = TLockLevel(1001'i16)
  AttachedOpToStr*: array[TTypeAttachedOp, string] = ["=destroy", "=", "=sink", "=deepcopy"]

proc `$`*(x: TLockLevel): string =
  if x.ord == UnspecifiedLockLevel.ord: result = "<unspecified>"
  elif x.ord == UnknownLockLevel.ord: result = "<unknown>"
  else: result = $int16(x)

proc `$`*(s: PSym): string =
  if s != nil:
    result = s.name.s & "@" & $s.id
  else:
    result = "<nil>"

proc newType*(kind: TTypeKind, owner: PSym): PType =
  new(result)
  result.kind = kind
  # result.owner = owner
  result.size = -1
  result.align = -1            # default alignment
  result.lockLevel = UnspecifiedLockLevel

proc mergeLoc(a: var TLoc, b: TLoc) =
  if a.k == low(TLocKind): a.k = b.k
  if a.storage == low(TStorageLoc): a.storage = b.storage
  a.flags = a.flags + b.flags
  if a.lode == nil: a.lode = b.lode
  if a.r == nil: a.r = b.r

proc newSons*(father: PNode, length: int) =
  when defined(nimNoNilSeqs):
    setLen(father.sons, length)
  else:
    if isNil(father.sons):
      newSeq(father.sons, length)
    else:
      setLen(father.sons, length)

proc newSons*(father: PType, length: int) =
  when defined(nimNoNilSeqs):
    setLen(father.sons, length)
  else:
    if isNil(father.sons):
      newSeq(father.sons, length)
    else:
      setLen(father.sons, length)

proc sonsLen*(n: PType): int = n.sons.len
proc len*(n: PType): int = n.sons.len
proc sonsLen*(n: PNode): int = n.sons.len
proc lastSon*(n: PNode): PNode = n.sons[^1]
proc lastSon*(n: PType): PType = n.sons[^1]



proc skipTypes*(t: PType, kinds: TTypeKinds): PType =
  ## Used throughout the compiler code to test whether a type tree contains or
  ## doesn't contain a specific type/types - it is often the case that only the
  ## last child nodes of a type tree need to be searched. This is a really hot
  ## path within the compiler!
  result = t
  while result.kind in kinds: result = lastSon(result)

proc skipTypes*(t: PType, kinds: TTypeKinds; maxIters: int): PType =
  result = t
  var i = maxIters
  while result.kind in kinds:
    result = lastSon(result)
    dec i
    if i == 0: return nil

proc skipTypesOrNil*(t: PType, kinds: TTypeKinds): PType =
  ## same as skipTypes but handles 'nil'
  result = t
  while result != nil and result.kind in kinds:
    if result.len == 0: return nil
    result = lastSon(result)

proc isGCedMem*(t: PType): bool {.inline.} =
  result = t.kind in {tyString, tyRef, tySequence} or
           t.kind == tyProc and t.callConv == ccClosure

# proc rawAddSon*(father, son: PType) =
#   when not defined(nimNoNilSeqs):
#     if isNil(father.sons): father.sons = @[]
#   add(father.sons, son)
#   # if not son.isNil: propagateToOwner(father, son)

proc rawAddSonNoPropagationOfTypeFlags*(father, son: PType) =
  when not defined(nimNoNilSeqs):
    if isNil(father.sons): father.sons = @[]
  add(father.sons, son)

proc addSonNilAllowed*(father, son: PNode) =
  when not defined(nimNoNilSeqs):
    if isNil(father.sons): father.sons = @[]
  add(father.sons, son)

proc delSon*(father: PNode, idx: int) =
  when defined(nimNoNilSeqs):
    if father.len == 0: return
  else:
    if isNil(father.sons): return
  var length = sonsLen(father)
  for i in idx .. length - 2: father.sons[i] = father.sons[i + 1]
  setLen(father.sons, length - 1)

proc hasSonWith*(n: PNode, kind: TNodeKind): bool =
  for i in 0 ..< sonsLen(n):
    if n.sons[i].kind == kind:
      return true
  result = false

proc hasNilSon*(n: PNode): bool =
  for i in 0 ..< safeLen(n):
    if n.sons[i] == nil:
      return true
    elif hasNilSon(n.sons[i]):
      return true
  result = false

proc containsNode*(n: PNode, kinds: TNodeKinds): bool =
  if n == nil: return
  case n.kind
  of nkEmpty..nkNilLit: result = n.kind in kinds
  else:
    for i in 0 ..< sonsLen(n):
      if n.kind in kinds or containsNode(n.sons[i], kinds): return true

proc hasSubnodeWith*(n: PNode, kind: TNodeKind): bool =
  case n.kind
  of nkEmpty..nkNilLit: result = n.kind == kind
  else:
    for i in 0 ..< sonsLen(n):
      if (n.sons[i].kind == kind) or hasSubnodeWith(n.sons[i], kind):
        return true
    result = false

proc getStr*(a: PNode): string =
  case a.kind
  of nkRawCode:
    result = ""
    for v in a.strVals:
      result.add v
  of nkNilLit:
    result = ""
  else:
    raiseRecoverableError("cannot extract string from invalid AST node")
    #doAssert false, "getStr"
    #internalError(a.info, "getStr")
    #result = ""

# proc getStrOrChar*(a: PNode): string =
#   case a.kind
#   of nkCharLit..nkUInt64Lit, nkStrLit..nkTripleStrLit: result = a.strVal
#   else:
#     raiseRecoverableError("cannot extract string from invalid AST node")
#     #doAssert false, "getStrOrChar"
#     #internalError(a.info, "getStrOrChar")
#     #result = ""



iterator items*(n: PNode): PNode =
  for i in 0..<n.safeLen: yield n.sons[i]

iterator pairs*(n: PNode): tuple[i: int, n: PNode] =
  for i in 0..<n.safeLen: yield (i, n.sons[i])

proc isAtom*(n: PNode): bool {.inline.} =
  result = n.kind >= nkNone and n.kind <= nkNilLit
