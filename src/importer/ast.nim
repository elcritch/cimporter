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
  PNode* = ref TNode
  TNodeSeq* = seq[PNode]
  TNode*{.final, acyclic.} = object # on a 32bit machine, this takes 32 bytes
    when defined(useNodeIds):
      id*: int
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

type Indexable = PNode

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

const                         # for all kind of hash tables:
  GrowthFactor* = 2           # must be power of 2, > 0
  StartSize* = 8              # must be power of 2, > 0

# proc copyStrTable*(dest: var TStrTable, src: TStrTable) =
#   dest.counter = src.counter
#   setLen(dest.data, len(src.data))
#   for i in 0 .. high(src.data): dest.data[i] = src.data[i]

proc discardSons*(father: PNode) =
  when defined(nimNoNilSeqs):
    father.sons = @[]
  else:
    father.sons = nil

proc withInfo*(n: PNode, info: TLineInfo): PNode =
  n.info = info
  return n


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

proc newNode*(kind: TNodeKind, info: TLineInfo, sons: TNodeSeq = @[]): PNode =
  new(result)
  result.kind = kind
  result.info = info
  result.sons = sons
  when defined(useNodeIds):
    result.id = gNodeId
    if result.id == nodeIdToDebug:
      echo "KIND ", result.kind
      writeStackTrace()
    inc gNodeId


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
