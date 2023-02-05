import std/[os, sequtils, osproc, strutils, strformat, sets, json]
import std/[tables, pegs]

import yaml
import yaml/parser
import yaml/stream
import yaml/serialization, streams

import cimporter/m4parser
# import toml_serialization
import glob

type
  CImporterOpts* = object
    proj: AbsFile
    projDir: AbsFile
    projName: string
    projC2Nim: string
    compiler: string
    ccExpandFlag: string
    ccFlag: seq[string]
    includes: seq[string]
    defines*: seq[string]
    skipClean: bool
    skipPreprocess: bool
    noDefaultFlags: bool
    `include`: seq[string]

  ImporterConfig* = object
    imports: seq[ImportConfig]

  ImportConfig* = object
    name: string
    sources: string
    globs: seq[string]
    skips {.defaultVal: @[].}: seq[string]
    includes {.defaultVal: @[].}: seq[string]
    defines {.defaultVal: @[].}: seq[string]
    outdir {.defaultVal: "".}: string
    skipProjMangle {.defaultVal: false.}: bool
    cSourceModifications {.defaultVal: @[].}: seq[CSrcMods]
  
  CSrcMods* = object
    cSourceModification*: Peg
    substitutes {.defaultVal: @[].}: seq[SourceReplace]
    deletes {.defaultVal: @[].}: seq[SourceDelete]
    c2NimExtras {.defaultVal: @[].}: seq[C2NimExtras]

  C2NimExtras* = object
    extraArgs* {.defaultVal: @[].}: seq[string]
    fileContents* {.defaultVal: "".}: string
    rawNims* {.defaultVal: "".}: string

  SourceReplace* = object
    peg*: Peg
    repl* {.defaultVal: "".}: string
  
  SourceDelete* = object
    match*: Peg
    until* {.defaultVal: Peg.none.}: Option[Peg]
    inclusive* {.defaultVal: false.}: bool

const defMangles = @[
  # handle expanded null pointers
  "--mangle:'__null'=NULL",
  "--mangle:'__nullptr'=NULL"
]

const dflOpts* = CImporterOpts(
    proj: "./",
    compiler: "cc",
    ccExpandFlag: "-E",
    noDefaultFlags: false,
    ccFlag: @["-CC","-dI","-dD"]
)

proc constructObject*(
    s: var YamlStream, c: ConstructionContext, result: var Peg) =
  constructScalarItem(s, item, Peg):
    let s = item.scalarContent
    try: result = peg(s)
    except: raise newException(YamlConstructionError, "peg: " & getCurrentExceptionMsg())

proc mkCmd(bin: string, args: openArray[string]): string =
  result = bin
  for arg in args:
    if arg.len() > 0:
      result &= " " & quoteShell(arg)

proc projMangles(proj: string): seq[string] =
  let pj = proj.split(os.DirSep)
  for i in 0..<pj.len():
    let p1 = pj[0..i].join($os.DirSep) & $os.DirSep
    let pp = relativePath(p1, proj) & os.DirSep
    result.add fmt"--mangle:'{p1}' {{\w+}}={pp}$1"

proc mkC2NimCmd(file: AbsFile,
                pre: seq[string],
                cfg: ImportConfig,
                extraArgs: seq[string],
                ): string =
  let
    relfile = file.relativePath(cfg.sources)
    split = relfile.splitFile()
    tgtfile = cfg.outdir / split.dir / split.name.changeFileExt("nim")
    tgtParentFile = tgtfile.parentDir()
    cfgC2nim = cfg.outdir/file.extractFilename().
                changeFileExt("c2nim")

  createDir(tgtParentFile)
  let post: seq[string] = @["--debug"] # modify progs
  var mangles = if cfg.skipProjMangle: @[""]
                else: projMangles(cfg.name)
  mangles.add defMangles
  let files = @[ &"--concat:all"] & pre &
              @[ $file, "--out:" & tgtfile]

  result = mkCmd("c2nim", post & mangles & files & extraArgs)
  

proc run(cmds: seq[string], flags: set[ProcessOption] = {}) =
  let res = execProcesses(cmds, options = flags +
                {poParentStreams, poStdErrToStdOut, poEchoCmd})
  if res != 0:
    raise newException(ValueError, "c2nim failed")
  echo "RESULT: ", res

proc importproject(opts: CImporterOpts,
                    cfg: ImportConfig
                    ) =
  createDir cfg.outdir

  echo "=== Importing Project ==="
  for f, v in cfg.fieldPairs():
    echo "\t", f, ": ", v
  echo ""

  # run commands
  var files: seq[string]
  for pat in cfg.globs:
    let fileGlob = fmt"{cfg.sources}/{pat}"
    files.add toSeq(walkGlob(glob(fileGlob)))
  echo "Found files: ", files

  var ccopts = CcPreprocOptions()
  ccopts.cc = opts.compiler
  ccopts.flags.add opts.ccExpandFlag
  ccopts.extraFlags.add opts.ccFlag
  ccopts.skipClean = opts.skipClean
  ccopts.includes.add opts.includes
  ccopts.includes.add cfg.includes
  ccopts.defines.add opts.defines
  ccopts.defines.add cfg.defines

  template fileMatches(obj: untyped, f: string): auto =
    obj.filterIt(f.endsWith(it.cSourceModification))

  # Run pre-processor
  var c2nimExtras: Table[string, seq[C2NimExtras]]
  var ppFiles: seq[string]
  let skips = cfg.skips.toHashSet()
  for f in files:
    let skipFile = f.relativePath(&"{cfg.sources}") in skips
    let mods = cfg.cSourceModifications.fileMatches(f)
    let subs = mods.mapIt(it.substitutes.mapIt((it.peg, it.repl))).concat()
    let dels = mods.mapIt(it.deletes.mapIt((it.match, (it.until, it.inclusive)))).concat()
    let pf = 
      if opts.skipPreprocess:
        copyFile(f, f & ".pp")
        f & ".pp"
      else:
        ccpreprocess(f, ccopts, subs, dels, skipFile)
    ppFiles.add(pf)

    let extras = mods.mapIt(it.c2nimExtras).concat()
    if extras.len() > 0:
      c2nimExtras[pf] = extras

  # Run C2NIM
  # let c2nProj = (cfg.outdir/cfg.name).addFileExt(".c2nim")
  # if not fileExists c2nProj:
  #   let fl = open(c2nProj, fmWrite); fl.write("\n"); fl.close()
  # var c2n = @[c2nProj.absolutePath]
  var c2n: seq[string]
  if opts.projC2Nim != "":
    c2n.insert(opts.projC2Nim, 0)

  var cmds: seq[string]
  echo "PP FILES: ", ppFiles
  for pp in ppFiles:
    var c2n = c2n
    let c2extras = c2nimExtras.getOrDefault(pp, @[])
    let extraArgs = c2extras.mapIt(it.extraArgs).concat().mapIt("--"&it)
    let c2files = c2extras.mapIt(it.fileContents).join("")
    let c2rawNims = c2extras.mapIt(it.rawNims).join("")
    if c2files.len() > 0 or c2rawNims.len() > 0:
      echo "EXTRA C2N: ", pp
      let ppC2 = pp.changeFileExt(".c2nim")
      let raws = if c2rawNims.len() == 0: "" else: "#@\n" & c2rawNims & "\n@#"
      writeFile(ppC2 , c2files & raws)
      c2n.add ppC2
    cmds.add(mkC2NimCmd(pp, c2n, cfg, extraArgs))
  # echo "C2NIM CMDS: ", cmds
  run cmds

import print


proc runImports*(opts: var CImporterOpts) =
  echo "importing..."
  opts.proj = opts.proj.absolutePath().AbsDir
  if opts.projName == "":
    opts.projName = opts.proj.lastPathPart()
  let optsPath = opts.proj / opts.projName & ".cimport.yml"
  if opts.projC2Nim == "":
    opts.projC2Nim = opts.proj / opts.projName & ".c2nim"
  if not opts.projC2Nim.fileExists():
    opts.projC2Nim = ""
  echo "Options Path: ", optsPath 
  echo "C2Nim Path: ", opts.projC2Nim 

  var configs: ImporterConfig
  var s = newFileStream(optsPath)
  load(s, configs)
  # echo "config: ", configs
  echo "configs: "
  print configs
  # let skips = configs.skips.toHashSet()
  for item in configs.imports:
    var imp = item
    # echo "import: ", imp
    imp.outdir =  if imp.outdir.len() == 0: opts.proj / "src"
                  else: imp.outdir
    imp.sources = opts.proj / imp.sources
    importproject(opts, imp)

  echo "PWD: ", getCurrentDir()
  echo "[Success]"

when isMainModule: # Preserve ability to `import api`/call from Nim
  const
    Short = { "proj": 'p',
              "ccExpandFlag": 'r',
              "ccFlag": 'e',
              "include": 'I' }.toTable()
  import cligen
  # dispatch(runImports, short = Short)
  var app = initFromCL(dflOpts, short = Short)
  if app.noDefaultFlags:
    app.ccFlag = app.ccFlag[dflOpts.ccFlag.len()..^1]
  echo "app: ", $(app)
  app.runImports()
