#
#
#      c2nim - C to Nim source converter
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## This module implements an ANSI C / C++ parser.
## It translates a C source file into a Nim AST. Then the renderer can be
## used to convert the AST to its text representation.
##
## The parser is a hand-written LL(infinity) parser. We accomplish this
## by using exceptions to bail out of failed parsing attemps and via
## backtracking. The tokens are stored in a singly linked list so we can
## easily go back. The token list is patched so that `>>` is converted to
## `> >` for C++ template support.

import std / [ os, streams, strutils, pegs, tables, strtabs, hashes, algorithm ]

import pegs except Token, Tokkind

import lineinfos, ast, clexer

type
  ParserFlag* = enum
    pfStrict,         ## do not use the "best effort" parsing approach
                        ## with sync points.
    pfRefs,             ## use "ref" instead of "ptr" for C's typ*
    pfCDecl,            ## annotate procs with cdecl
    pfStdCall,          ## annotate procs with stdcall
    pfImportc,          ## annotate procs with importc
    pfNoConv,           ## annotate procs with noconv
    pfSkipInclude,      ## skip all ``#include``
    pfC2NimInclude,     ## include c2nim in concat mode
    pfTypePrefixes,     ## all generated types start with 'T' or 'P'
    pfSkipComments,     ## do not generate comments
    pfCpp,              ## process C++
    pfIgnoreRValueRefs, ## transform C++'s 'T&&' to 'T'
    pfKeepBodies,       ## do not skip C++ method bodies
    pfAssumeIfIsTrue,   ## assume #if is true
    pfStructStruct,     ## do not treat struct Foo Foo as a forward decl
    pfReorderComments   ## reorder comments to match Nim's style
    pfFileNameIsPP      ## fixup pre-processor file name
    pfMergeBlocks       ## fixup pre-processor file name

  Macro* = object
    name*: string
    params*: int # number of parameters; 0 for empty (); -1 for no () at all
    body*: seq[ref Token] # can contain pxMacroParam tokens

  ParserOptions = object ## shared parser state!
    flags*: set[ParserFlag]
    # renderFlags*: TRenderFlags
    prefixes, suffixes: seq[string]
    assumeDef, assumenDef: seq[string]
    mangleRules: seq[tuple[pattern: Peg, frmt: string]]
    privateRules: seq[Peg]
    dynlibSym, headerOverride, headerPrefix: string
    macros*: seq[Macro]
    deletes*: Table[string, string]
    toMangle: StringTableRef
    classes: StringTableRef
    toPreprocess: StringTableRef
    inheritable: StringTableRef
    debugMode, followNep1: bool
    useHeader, importdefines, importfuncdefines: bool
    discardablePrefixes: seq[string]
    constructor, destructor, importcLit: string
    exportPrefix*: string
    paramPrefix*: string
    isArray: StringTableRef

  PParserOptions* = ref ParserOptions

  Section* = ref object # used for "parseClassSnippet"
    genericParams: PNode
    pragmas: PNode
    private: bool

  Parser* = object
    lex*: Lexer
    tok*: ref Token       # current token
    header: string
    options: PParserOptions
    backtrack: seq[ref Token]
    backtrackB: seq[(ref Token, bool)] # like backtrack, but with the possibility to ignore errors
    inTypeDef: int
    scopeCounter: int
    currentClass: PNode   # type that needs to be added as 'this' parameter
    currentClassOrig: string # original class name
    classHierarchy: seq[string] # used for nested types
    classHierarchyGP: seq[PNode]
    currentNamespace: string
    inAngleBracket, inPreprocessorExpr: int
    lastConstType: PNode # another hack to be able to translate 'const Foo& foo'
                         # to 'foo: Foo' and not 'foo: var Foo'.
    continueActions: seq[PNode]
    currentSection: Section # can be nil
    anoTypeCount: int

  ReplaceTuple* = array[0..1, string]

  ERetryParsing = object of ValueError

  SectionParser = proc(p: var Parser): PNode {.nimcall.}


proc newParserOptions*(): PParserOptions =
  PParserOptions(
    prefixes: @[],
    suffixes: @[],
    assumeDef: @[],
    assumenDef: @["__cplusplus"],
    macros: @[],
    mangleRules: @[],
    privateRules: @[],
    discardablePrefixes: @[],
    flags: {},
    # renderFlags: {},
    dynlibSym: "",
    headerOverride: "",
    headerPrefix: "",
    toMangle: newStringTable(modeCaseSensitive),
    classes: newStringTable(modeCaseSensitive),
    toPreprocess: newStringTable(modeCaseSensitive),
    inheritable: newStringTable(modeCaseSensitive),
    constructor: "construct",
    destructor: "destroy",
    importcLit: "importc",
    exportPrefix: "",
    paramPrefix: "a",
    isArray: newStringTable(modeCaseSensitive))

proc setOption*(parserOptions: PParserOptions, key: string, val=""): bool =
  result = true
  case key.normalize
  of "strict": incl(parserOptions.flags, pfStrict)
  of "ref": incl(parserOptions.flags, pfRefs)
  of "dynlib": parserOptions.dynlibSym = val
  of "header":
    parserOptions.useHeader = true
    if val.len > 0: parserOptions.headerOverride = val
  of "headerprefix":
    if val.len > 0: parserOptions.headerPrefix = val
  of "importfuncdefines":
    parserOptions.importfuncdefines = true
  of "importdefines":
    parserOptions.importdefines = true
  of "cdecl": incl(parserOptions.flags, pfCdecl)
  of "stdcall": incl(parserOptions.flags, pfStdCall)
  of "importc": incl(parserOptions.flags, pfImportc)
  of "noconv": incl(parserOptions.flags, pfNoConv)
  of "prefix": parserOptions.prefixes.add(val)
  of "suffix": parserOptions.suffixes.add(val)
  of "paramprefix":
    if val.len > 0: parserOptions.paramPrefix = val
  of "assumedef": parserOptions.assumeDef.add(val)
  of "assumendef": parserOptions.assumenDef.add(val)
  of "mangle":
    let vals = val.split("=")
    parserOptions.mangleRules.add((parsePeg(vals[0]), vals[1]))
  of "stdints":
    let vals = (r"{u?}int{\d+}_t", r"$1int$2")
    parserOptions.mangleRules.add((parsePeg(vals[0]), vals[1]))
  of "skipinclude": incl(parserOptions.flags, pfSkipInclude)
  of "typeprefixes": incl(parserOptions.flags, pfTypePrefixes)
  of "skipcomments": incl(parserOptions.flags, pfSkipComments)
  of "cpp":
    incl(parserOptions.flags, pfCpp)
    parserOptions.importcLit = "importcpp"
  of "keepbodies": incl(parserOptions.flags, pfKeepBodies)
  of "ignorervaluerefs": incl(parserOptions.flags, pfIgnoreRValueRefs)
  of "class": parserOptions.classes[val] = "true"
  of "debug": parserOptions.debugMode = true
  of "nep1": parserOptions.followNep1 = true
  of "constructor": parserOptions.constructor = val
  of "destructor": parserOptions.destructor = val
  of "assumeifistrue": incl(parserOptions.flags, pfAssumeIfIsTrue)
  of "discardableprefix": parserOptions.discardablePrefixes.add(val)
  of "structstruct": incl(parserOptions.flags, pfStructStruct)
  of "reordercomments": incl(parserOptions.flags, pfReorderComments)
  of "mergeblocks": incl(parserOptions.flags, pfMergeBlocks)
  of "isarray": parserOptions.isArray[val] = "true"
  of "delete": parserOptions.deletes[val] = ""
  else: result = false

proc openParser*(p: var Parser, filename: string,
                inputStream: Stream, options: PParserOptions) =
  openLexer(p.lex, filename, inputStream)
  p.options = options
  p.header = filename.extractFilename
  if pfFileNameIsPP in options.flags:
    p.header = p.header.splitFile().name
  p.lex.debugMode = options.debugMode
  p.backtrack = @[]
  p.currentNamespace = ""
  p.currentClassOrig = ""
  p.classHierarchy = @[]
  p.classHierarchyGP = @[]
  new(p.tok)

proc debugTok*(p: Parser): string =
  result = debugTok(p.lex, p.tok[])

proc dumpTree*(node: PNode, prefix = "") =
  echo prefix, node.kind, " :: ", repr node
  for c in node:
    dumpTree(c, prefix & "  ")

proc parMessage(p: Parser, msg: TMsgKind, arg = "") =
  lexMessage(p.lex, msg, arg)

proc parError(p: Parser, arg = "") =
  # raise newException(Exception, arg)
  if p.backtrackB.len == 0:
    lexMessage(p.lex, errGenerated, arg)
  else:
    if p.backtrackB[^1][1]:
      lexMessage(p.lex, warnSyntaxError, arg)
    raise newException(ERetryParsing, arg)

proc closeParser*(p: var Parser) = closeLexer(p.lex)

proc saveContext(p: var Parser) = p.backtrack.add(p.tok)
# EITHER call 'closeContext' or 'backtrackContext':
proc closeContext(p: var Parser) = discard p.backtrack.pop()
proc backtrackContext(p: var Parser) = p.tok = p.backtrack.pop()

proc saveContextB(p: var Parser; produceWarnings=false) = p.backtrackB.add((p.tok, produceWarnings))
proc closeContextB(p: var Parser) = discard p.backtrackB.pop()
proc backtrackContextB(p: var Parser) = p.tok = p.backtrackB.pop()[0]

proc rawGetTok*(p: var Parser) =
  if p.tok.next != nil:
    p.tok = p.tok.next
  elif p.backtrack.len == 0 and p.backtrackB.len == 0:
    p.tok.next = nil
    getTok(p.lex, p.tok[])
  else:
    # We need the next token and must be able to backtrack. So we need to
    # allocate a new token.
    var t: ref Token
    new(t)
    getTok(p.lex, t[])
    p.tok.next = t
    p.tok = t

proc rawEat(p: var Parser, xkind: Tokkind) =
  if p.tok.xkind == xkind: rawGetTok(p)
  else:
    parError(p, "token expected: " & tokKindToStr(xkind))

proc getTok*(p: var Parser) =
  rawGetTok(p)
  while p.tok.xkind == pxSymbol:
    var idx = findMacro(p)
    if idx >= 0 and p.inPreprocessorExpr == 0:
      expandMacro(p, p.options.macros[idx])
    else:
      break

proc parLineInfo(p: Parser): TLineInfo =
  result = getLineInfo(p.lex)

proc skipComAux(p: var Parser, n: PNode) =
  if n != nil and n.kind != nkEmpty:
    if pfSkipComments notin p.options.flags:
      if n.comment.len == 0: n.comment = p.tok.s
      else: add(n.comment, "\n" & p.tok.s)
      n.info.line = p.tok.lineNumber.uint16
  else:
    parMessage(p, warnCommentXIgnored, p.tok.s)
  getTok(p)

proc skipCom*(p: var Parser, n: PNode) =
  while p.tok.xkind in {pxLineComment, pxStarComment}: skipComAux(p, n)

proc skipStarCom*(p: var Parser, n: PNode) =
  while p.tok.xkind == pxStarComment: skipComAux(p, n)

proc getTok*(p: var Parser, n: PNode) =
  getTok(p)
  skipCom(p, n)

proc expectIdent(p: Parser) =
  if p.tok.xkind != pxSymbol:
    # raise newException(Exception, "error")
    parError(p, "identifier expected, but got: " & debugTok(p.lex, p.tok[]))

proc eat*(p: var Parser, xkind: Tokkind, n: PNode) =
  if p.tok.xkind == xkind: getTok(p, n)
  else: parError(p, "token expected: " & tokKindToStr(xkind) & " but got: " & tokKindToStr(p.tok.xkind))

proc eat*(p: var Parser, xkind: Tokkind) =
  if p.tok.xkind == xkind: getTok(p)
  else: parError(p, "token expected: " & tokKindToStr(xkind) & " but got: " & tokKindToStr(p.tok.xkind))

proc eat*(p: var Parser, tok: string, n: PNode) =
  if p.tok.s == tok: getTok(p, n)
  else: parError(p, "token expected: " & tok & " but got: " & tokKindToStr(p.tok.xkind))

proc opt(p: var Parser, xkind: Tokkind, n: PNode) =
  if p.tok.xkind == xkind: getTok(p, n)

proc addSon(father, a, b: PNode) =
  addSon(father, a)
  addSon(father, b)

proc addSon(father, a, b, c: PNode) =
  addSon(father, a)
  addSon(father, b)
  addSon(father, c)

proc newNodeP*(kind: TNodeKind, p: Parser): PNode =
  var info = getLineInfo(p.lex)
  info.line = p.tok.lineNumber.uint16
  result = newNodeI(kind, info)


template initExpr(p: untyped): untyped = expression(p, 11)

proc declKeyword(p: Parser, s: string): bool =
  # returns true if it is a keyword that introduces a declaration
  case s
  of  "extern", "static", "auto", "register", "const", "volatile",
      "restrict", "inline", "__inline", "__cdecl", "__stdcall", "__syscall",
      "__fastcall", "__safecall", "void", "struct", "union", "enum", "typedef",
      "size_t", "short", "int", "long", "float", "double", "signed", "unsigned",
      "char", "__declspec", "__attribute__":
    result = true
  of "class", "mutable", "constexpr", "consteval", "constinit", "decltype":
    result = p.options.flags.contains(pfCpp)
  else: discard

proc isAttribute(t: ref Token): tuple[isattr: bool, parens: uint] =
  if t.xkind != pxSymbol:
    return (isattr: false, parens: 0'u)
  case t.s
  of "__attribute__":
    result = (isattr: true, parens: 2'u)
  of "__alignof", "__declspec":
    result = (isattr: true, parens: 1'u)
  of "alignas":
    result = (isattr: true, parens: 1'u)
  of "__asm":
    result = (isattr: true, parens: 1'u)
  of "_Nullable", "_Nonnull":
    result = (isattr: true, parens: 0'u)
  of "__unaligned", "__packed":
    result = (isattr: true, parens: 0'u)
  else: discard

proc skipAttribute*(p: var Parser): bool {.discardable.} =
  ## skip type attributes
  ## TODO: these should be changed to pragmas
  result = true
  let (isattr, parens) = p.tok.isAttribute()
  if not isattr: return false

  if parens == 0:
    getTok(p, nil)
  else:
    getTok(p, nil)
    for i in 1..parens:
      eat(p, pxParLe, nil)
    while p.tok.xkind != pxParRi:
      getTok(p, nil)
      ## get args
      if p.tok.xkind == pxParLe:
        getTok(p, nil)
        while p.tok.xkind != pxParRi:
          getTok(p, nil)
        eat(p, pxParRi, nil)

    for i in 1..parens:
      eat(p, pxParRi, nil)

proc skipAttributes*(p: var Parser): bool {.discardable.} =
  while skipAttribute(p):
    result = true

proc stmtKeyword(s: string): bool =
  case s
  of  "if", "for", "while", "do", "switch", "break", "continue", "return",
      "goto":
    result = true
  else: discard

# ------------------- type desc -----------------------------------------------

# proc typeDesc(p: var Parser): PNode

proc isBaseIntType(s: string): bool =
  case s
  of "short", "int", "long", "float", "double", "signed", "unsigned":
    result = true
  else: discard

proc isIntType(s: string): bool =
  if isBaseIntType(s):
    return true
  elif s == "size_t":
    return true

proc skipConst(p: var Parser): bool =
  while p.tok.xkind == pxSymbol and
      (p.tok.s in ["const", "volatile", "restrict"] or
      (p.tok.s in ["mutable", "constexpr", "consteval", "constinit"] and pfCpp in p.options.flags)):
    if p.tok.s in ["const", "constexpr"]: result = true
    getTok(p, nil)

proc isTemplateAngleBracket(p: var Parser): bool =
  if pfCpp notin p.options.flags: return false
  saveContext(p)
  getTok(p, nil) # skip "<"
  var i: array[pxParLe..pxCurlyLe, int]
  var angles = 0
  while true:
    let kind = p.tok.xkind
    case kind
    of pxEof: break
    of pxParLe, pxBracketLe, pxCurlyLe: inc(i[kind])
    of pxGt, pxAngleRi:
      # end of arguments?
      if i[pxParLe] == 0 and i[pxBracketLe] == 0 and i[pxCurlyLe] == 0 and
          angles == 0:
        # mark as end token:
        p.tok.xkind = pxAngleRi
        result = true;
        break
      if angles > 0: dec(angles)
    of pxShr:
      # >> can end a template too:
      if i[pxParLe] == 0 and i[pxBracketLe] == 0 and i[pxCurlyLe] == 0 and
          angles == 1:
        p.tok.xkind = pxAngleRi
        insertAngleRi(p.tok)
        result = true
        break
      if angles > 1: dec(angles)
    of pxLt: inc(angles)
    of pxParRi, pxBracketRi, pxCurlyRi:
      let kind = pred(kind, 3)
      if i[kind] > 0: dec(i[kind])
      else: break
    of pxSemicolon, pxBarBar, pxAmpAmp: break
    else: discard
    getTok(p, nil)
  backtrackContext(p)

proc hasValue(t: StringTableRef, s: string): bool =
  for v in t.values:
    if v == s: return true
