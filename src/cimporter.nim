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

  ImportConfig* = object
    name: string
    sources: string
    globs: seq[string]
    includes {.defaultVal: @[].}: seq[string]
    defines {.defaultVal: @[].}: seq[string]
    outdir {.defaultVal: "".}: string
    skipProjMangle {.defaultVal: false.}: bool
    subs {.defaultVal: @[].}: seq[SourceReplace]
    dels {.defaultVal: @[].}: seq[SourceDelete]
    c2nims {.defaultVal: @[].}: seq[ConfigC2Nim]

  ImporterConfig* = object
    skips: seq[string]
    imports: seq[ImportConfig]

  ConfigC2Nim* = object
    file*: Peg
    contents*: string

  SourceReplace* = object
    file*: Peg
    peg*: Peg
    repl*: string
  
  SourceDelete* = object
    file*: Peg
    match*: Peg
    until* {.defaultVal: Peg.none.}: Option[Peg]


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
    result = peg(item.scalarContent)

# proc readValue*(r: var TomlReader, value: var Peg) =
#   let s = r.parseAsString()
#   try: value = peg(s)
#   except:
#     echo "Error parsing peg: ", s

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
                ): string =
  let
    relfile = file.relativePath(cfg.sources)
    split = relfile.splitFile()
    tgtfile = cfg.outdir / split.dir / split.name.changeFileExt("nim")
    tgtParentFile = tgtfile.parentDir()
    cfgC2nim = cfg.outdir/file.extractFilename().
                changeFileExt("c2nim")

  echo "PRE: ", pre
  createDir(tgtParentFile)
  let post: seq[string] = @["--debug"] # modify progs
  let mangles = if cfg.skipProjMangle: @[""]
                else: projMangles(cfg.name)
  let files = @[ &"--concat:all"] & pre &
              @[ $file, "--out:" & tgtfile]

  result = mkCmd("c2nim", post & mangles & files)
  

proc run(cmds: seq[string], flags: set[ProcessOption] = {}) =
  let res = execProcesses(cmds, options = flags +
                {poParentStreams, poStdErrToStdOut, poEchoCmd})
  if res != 0:
    raise newException(ValueError, "c2nim failed")
  echo "RESULT: ", res

proc importproject(opts: CImporterOpts,
                    cfg: ImportConfig,
                    skips: HashSet[string]
                    ) =
  createDir cfg.outdir

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
    obj.filterIt(f.endsWith(it.file))

  # Run pre-processor
  var ppFiles: seq[string]
  for f in files:
    let skipFile = f.relativePath(&"{cfg.sources}") in skips
    if opts.skipPreprocess:
      ppFiles.add(f)
    else:
      let subs = cfg.subs.fileMatches(f).mapIt((it.peg, it.repl))
      let dels = cfg.dels.fileMatches(f).mapIt((it.match, it.until))
      ppFiles.add ccpreprocess(f, ccopts, subs, dels, skipFile)

  # Run C2NIM
  let c2nProj = (cfg.outdir/cfg.name).addFileExt(".c2nim")
  if not fileExists c2nProj:
    let fl = open(c2nProj, fmWrite); fl.write("\n"); fl.close()
  var c2n = @[c2nProj.absolutePath]
  if opts.projC2Nim != "":
    c2n.insert(opts.projC2Nim, 0)

  var cmds: seq[string]
  echo "PP FILES: ", ppFiles
  for pp in ppFiles:
    var c2nLocal = c2n
    let c2ns = cfg.c2nims.fileMatches(pp).mapIt((it.contents))
    if c2ns.len() > 0:
      let fc2path = pp.changeFileExt("c2nim")
      writeFile(fc2path, c2ns.join("\n"))
      c2nLocal.add fc2path
    cmds.add(mkC2NimCmd(pp, c2nLocal, cfg))
  echo "C2NIM CMDS: ", cmds
  run cmds



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
  echo "config: ", configs
  let skips = configs.skips.toHashSet()
  for item in configs.imports:
    var imp = item
    echo "import: ", imp
    imp.outdir =  if imp.outdir.len() == 0: opts.proj / "src"
                  else: imp.outdir
    imp.sources = opts.proj / imp.sources
    importproject(opts, imp, skips)

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
