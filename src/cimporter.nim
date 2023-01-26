import std/[os, sequtils, osproc, strutils, strformat, sets, json]
import std/[tables]

import cimporter/m4parser
import toml_serialization
import glob

type
  ImporterOpts* = object
    proj: AbsFile
    projName: string
    compiler: string
    ccExpandFlag: string
    ccFlag: seq[string]
    noDefaultFlags: bool
    `include`: seq[string]

  ImportConfig* = object
    name: string
    sources: string
    globs: seq[string]
    outdir: string
    skipProjMangle: bool

  ImporterConfig* = object
    skips: seq[string]
    imports: seq[ImportConfig]

const dflOpts* = ImporterOpts(
    proj: "./",
    compiler: "cc",
    ccExpandFlag: "-E",
    noDefaultFlags: false,
    ccFlag: @["-CC","-dI","-dD"]
)

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
    tgtfile = cfg.outdir/relfile.changeFileExt("nim")
    tgtParentFile = tgtfile.parentDir()
    cfgC2nim = cfg.outdir/file.extractFilename().
                changeFileExt("c2nim")
  var cfgFile = ""
  if cfgC2nim.fileExists():
    cfgFile = cfgC2nim

  createDir(tgtParentFile)
  let post: seq[string] = @["--debug"] # modify progs
  let mangles = if cfg.skipProjMangle: @[""]
                else: projMangles(cfg.name)
  let files = @[ &"--concat:all"] & pre &
              @[ $cfgFile, $file, "--out:" & tgtfile]

  result = mkCmd("c2nim", post & mangles & files)
  
proc run(cmds: seq[string], flags: set[ProcessOption] = {}) =
  let res = execProcesses(cmds, options = flags +
                {poParentStreams, poStdErrToStdOut, poEchoCmd})
  if res != 0:
    raise newException(ValueError, "c2nim failed")
  echo "RESULT: ", res

proc importproject(cfg: ImportConfig, skips: HashSet[string]) =
  createDir cfg.outdir

  let c2nProj = (cfg.outdir/cfg.name).addFileExt(".c2nim")
  if not fileExists c2nProj:
    let fl = open(c2nProj, fmWrite); fl.write("\n"); fl.close()
  let c2n = @[c2nProj.absolutePath]

  # run commands
  var cmds: seq[string]
  var files: seq[string]
  for pat in cfg.globs:
    let fileGlob = fmt"{cfg.sources}/{pat}"
    files.add toSeq(walkGlob(glob(fileGlob)))
  echo "Found files: ", files

  for f in files:
    if f.relativePath(&"{cfg.sources}") in skips:
      echo "SKIPPING: ", f
    else:
      cmds.add(mkC2NimCmd(f, c2n, cfg))
  run(cmds)


proc runImports*(opts: var ImporterOpts) =
  echo "importing..."
  opts.proj = opts.proj.absolutePath().AbsDir
  if opts.projName == "":
    opts.projName = opts.proj.lastPathPart()
  let optsPath = opts.proj / opts.projName & ".import.toml"

  var toml = Toml.loadFile(optsPath, ImporterConfig)
  echo "config: ", toml
  echo "config:skips: ", toml.skips
  let skips = toml.skips.toHashSet()
  for item in toml.imports:
    var imp = item
    echo "import: ", imp
    imp.outdir =  if imp.outdir.len() == 0: opts.proj / "src"
                  else: imp.outdir
    imp.sources = opts.proj / imp.sources
    importproject(imp, skips)

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
