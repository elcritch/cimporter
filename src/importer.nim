#
#
#      c2nim - C to Nim source converter
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

import std / [strutils, os, osproc, times, md5, parseopt, strscans, sequtils, tables]


const
  Usage = """
importer - C to Nim source converter
Usage:  [options] [optionfile(s)] inputfile(s) [options]
  Optionfiles are C files with the 'c2nim' extension. These are parsed like
  other C files but produce no output file.
Options:
  -h, --help             show this help
"""

proc isCppFile(s: string): bool =
  splitFile(s).ext.toLowerAscii in [".cpp", ".cxx", ".hpp"]
proc isPPFile(s: string): bool =
  splitFile(s).ext.toLowerAscii == ".pp"
proc stripPPFile(s: string): string =
  if s.isPPFile():
    let res = splitFile(s)
    result = res.dir / res.name
  else:
    result = s

when not declared(NimCompilerApiVersion):
  type AbsoluteFile = string

proc isC2nimFile(s: string): bool = splitFile(s).ext.toLowerAscii == ".c2nim"

proc parseDefines(val: string): seq[ref Token] =
  let tpath = getTempDir() / "macro_" & getMD5(val) & ".h"
  let tfl = (open(tpath, fmReadWrite), tpath)
  let ss = llStreamOpen(val)
  var lex: Lexer
  openLexer(lex, tfl[1], ss)
  var tk = new Token
  var idx = 0
  result = newSeq[ref Token]()
  while tk.xkind != pxEof:
    tk = new Token
    lex.getTok(tk[])
    if tk.xkind == pxEof:
      break
    result.add tk
    inc idx
    if idx > 1_000: raise newException(Exception, "parse error")
  tfl[0].close()
  tfl[1].removeFile()

proc parseDefineArgs(parserOptions: var PParserOptions, val: string) =
  let defs = val.split("=")
  var mc: cparser.Macro
  let macs = parseDefines(defs[0])
  let toks = parseDefines(defs[1])
  mc.name = macs[0].s
  mc.params = -1
  mc.body = toks
  for m in macs[1..^1]:
    if m.xkind == pxParLe: mc.params = 0
    if m.xkind == pxSymbol: inc mc.params
  parserOptions.macros.add(mc)

type
  CcPreprocOptions* = ref object
    run: bool
    cc: string
    skipClean: bool
    flags: seq[string]
    extraFlags: seq[string]
    includes: seq[string]

proc newPPOpts(val: string): CcPreprocOptions =
  new result
  if val == "": result.cc = "cc"
  else: result.cc = val
  result.flags = @["-E", "-CC", "-dI", "-dD"]

proc ccpreprocess(infile: string,
                  options: PParserOptions;
                  ppoptions: CcPreprocOptions
                 ): AbsoluteFile =
  ## use C compiler to preprocess
  if infile.isAbsolute():
    gConfig.projectPath = getCurrentDir().AbsoluteDir
  let infile = infile.absolutePath()
  # echo "gConfig: ", string gConfig.projectPath
  let outfile = infile & ".pre"
  let postfile = infile & ".pp"
  var args = newSeq[string]()
  args.add(ppoptions.flags)
  args.add(ppoptions.extraFlags)
  args.add([infile, "-o", outfile])
  for pth in ppoptions.includes: args.add("-I" & pth)
  let res = execCmdEx(ppoptions.cc & " " & args.mapIt(it.quoteShell()).join(" "),
                         options={poUsePath, poStdErrToStdOut})
  if res.exitCode != 0:
    raise newException(ValueError, "[c2nim] Error running CC preprocessor: " & res.output)
  var stream = llStreamOpen(AbsoluteFile outfile, fmRead)
  if stream == nil:
    when declared(NimCompilerApiVersion):
      rawMessage(gConfig, errGenerated, "cannot open file: " & outfile)
    else:
      rawMessage(errGenerated, "cannot open file: " & outfile)
  let isCpp = pfCpp notin options.flags and isCppFile(outfile)
  var p: Parser
  if isCpp: options.flags.incl pfCpp
  openParser(p, outfile, stream, options)
  let rawNodes = parseRemoveIncludes(p, infile)
  closeParser(p)

  let tfl = open(postfile, fmWrite)
  for node in rawNodes:
    case node.kind:
    of nkComesFrom:
      discard
      tfl.write(" ")
    of nkTripleStrLit:
      tfl.write(node.strVal)
    else:
      discard
  tfl.close()

  if not ppoptions.skipClean:
    outfile.removeFile()
  result = AbsoluteFile postfile

var dummy: PNode

when not compiles(renderModule(dummy, "")):
  # newer versions of 'renderModule' take 2 parameters. We workaround this
  # problem here:
  proc renderModule(tree: PNode; filename: string, renderFlags: TRenderFlags) =
    renderModule(tree, filename, filename, renderFlags)

proc myRenderModule(tree: PNode; filename: string, renderFlags: TRenderFlags) =
  # also ensure we produced no trailing whitespace:
  let tmpFile = filename & ".tmp"
  renderModule(tree, tmpFile, renderFlags)

  let b = readFile(tmpFile)
  removeFile(tmpFile)
  let L = b.len
  var i = 0
  let f = open(filename, fmWrite)
  while i < L:
    let ch = b[i]
    if ch > ' ':
      f.write(ch)
    elif ch == ' ':
      let j = i
      while i < L and b[i] == ' ': inc i
      if i < L and b[i] == '\L':
        f.write('\L')
      else:
        for ii in j..i-1:
          f.write(' ')
        dec i
    elif ch == '\L':
      f.write('\L')
    else:
      f.write(ch)
    inc(i)
  f.close

proc main(infiles: seq[string], outfile: var string,
          options: PParserOptions,
          concat: bool,
          preprocessOptions: CcPreprocOptions) =
  var start = getTime()
  var dllexport: PNode = nil
  var infiles = infiles
  if not preprocessOptions.isNil:
    let rawfiles = infiles[0..^1]
    infiles.setLen(0)
    for fl in rawfiles:
      if not isC2nimFile(fl):
        infiles.add ccpreprocess(fl, options, preprocessOptions).string
      else:
        infiles.add fl
  
  if concat:
    var tree = newNode(nkStmtList)
    for infile in infiles:
      let m = parse(infile.addFileExt("h"), options, dllexport)
      if not isC2nimFile(infile):
        if outfile.len == 0:
          outfile = changeFileExt(infile.stripPPFile(), "nim")
      if not isC2nimFile(infile) or pfC2NimInclude in options.flags:
        for n in m: tree.add(n)
    myRenderModule(tree, outfile, options.renderFlags)
  else:
    for infile in infiles:
      let m = parse(infile, options, dllexport)
      if not isC2nimFile(infile):
        if outfile.len > 0:
          myRenderModule(m, outfile, options.renderFlags)
          outfile = ""
        else:
          let outfile = changeFileExt(infile.stripPPFile(), "nim")
          myRenderModule(m, outfile, options.renderFlags)
  if dllexport != nil:
    let (path, name, _) = infiles[0].splitFile
    let outfile = path / name & "_dllimpl" & ".nim"
    myRenderModule(dllexport, outfile, options.renderFlags)
  when declared(NimCompilerApiVersion):
    rawMessage(gConfig, hintSuccessX, [$gLinesCompiled, $(getTime() - start),
                              formatSize(getTotalMem()), ""])
  else:
    rawMessage(hintSuccessX, [$gLinesCompiled, $(getTime() - start),
                              formatSize(getTotalMem()), ""])

var
  infiles = newSeq[string](0)
  outfile = ""
  concat = false
  parserOptions = newParserOptions()
  preprocessOptions: CcPreprocOptions

for kind, key, val in getopt():
  case kind
  of cmdArgument:
    infiles.add key
  of cmdLongOption, cmdShortOption:
    case key.normalize
    of "help", "h":
      stdout.write(Usage)
      quit(0)
    of "version", "v":
      stdout.write(Version & "\n")
      quit(0)
    of "o", "out": outfile = val
    of "concat":
      concat = true
      if val == "all":
        incl(parserOptions.flags, pfC2NimInclude)
    of "spliceheader":
      quit "[Error] 'spliceheader' doesn't exist anymore" &
           " use a list of files and --concat instead"
    of "exportdll":
      parserOptions.exportPrefix = val
    of "def":
      parserOptions.parseDefineArgs(val)
    of "render":
      if not parserOptions.renderFlags.setOption(val):
        quit("[Error] unknown option: " & key)
    of "preprocess":
      preprocessOptions = newPPOpts(val)
    of "i", "d": # shortcut preprocessor includes
      if preprocessOptions.isNil:
        quit("[Error] must specify `--preprocess` first")
      if key == "I":
        preprocessOptions.includes.add(val)
      elif key == "D":
        preprocessOptions.extraFlags.add("-D" & val)
    of "pp": # preprocess opts
      if preprocessOptions.isNil:
        quit("[Error] must specify `--preprocess` first")
      if val == "skipclean":
        preprocessOptions.skipClean = true
      elif val.startsWith("flags="):
        let flags = val.split("=")[1]
        preprocessOptions.flags = flags.split()
    else:
      if not parserOptions.setOption(key, val):
        quit("[Error] unknown option: " & key)
  of cmdEnd: assert(false)
if infiles.len == 0:
  # no filename has been given, so we show the help:
  stdout.write(Usage)
else:
  main(infiles, outfile, parserOptions, concat, preprocessOptions)
