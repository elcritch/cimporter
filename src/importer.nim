import std/[os, sequtils, osproc, strutils, strformat, sets, json]
import std/[tables]

import importer/m4parser
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

proc cp(a, b: string) =
  echo &"Copying: {a} to {b}"
  copyFile(a, b)
proc mv(a, b: string) =
  echo &"Moving: {a} to {b}"
  moveFile(a, b)
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
    tgtfile = cfg.outdir / relfile.changeFileExt("nim")
    tgtParentFile = tgtfile.parentDir()
    cfgC2nim = cfg.outdir / $(file.extractFilename()).changeFileExt("c2nim")
  var cfgFile = ""
  if cfgC2nim.fileExists():
    echo "CFGFILE: ", cfgC2nim
    cfgFile = cfgC2nim

  echo "c2nim OUTFILE:file: ", file
  echo "c2nim OUTFILE:cfgC2nim: ", cfgC2nim
  echo "c2nim OUTFILE:out: ", file.relativePath(cfg.outdir)
  echo "c2nim OUTFILE:tgtfile: ", tgtfile
  echo "c2nim OUTFILE:tgtParentFile: ", tgtParentFile
  createDir(tgtParentFile)
  let post: seq[string] = @["--debug"] # modify progs
  let mangles = projMangles(cfg.name)
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
  # let outdir = if outdir.len() == 0: nimDir/proj else: outdir
  createDir cfg.outdir
  echo "IMPORTPROJECT: ", cfg

  # let c2nImports = "tests"/"imports.c2nim"
  let c2nProj = (cfg.outdir/cfg.name).addFileExt(".proj.c2nim")
  if not fileExists c2nProj:
    # raise newException(ValueError, "missing file: "&c2nProj)
    let fl = open(c2nProj, fmWrite)
    fl.write("\n")
    fl.close()
  echo "PROJ CNIM: ", c2nProj
  # let c2n = @[c2nImports, c2nProj.absolutePath]
  let c2n = @[c2nProj.absolutePath]

  # run commands
  var cmds: seq[string]
  var files: seq[string]
  for pat in cfg.globs:
    let fileGlob = fmt"{cfg.sources}/{pat}"
    echo "File glob: ", fileGlob
    let pattern = glob(fileGlob)
    files.add toSeq(walkGlob(pattern))
  echo "Found files: ", files
  echo ""

  for f in files:
    if f.relativePath(&"{cfg.sources}") in skips:
      echo "SKIPPING: ", f
    else:
      cmds.add(mkC2NimCmd(f, c2n, cfg))
  run(cmds)

  # move nim files
  for f in toSeq(walkFiles cfg.sources / cfg.name / "*.nim"):
    mv f, cfg.outdir / f.extractFilename
  
proc runImports*(opts: var ImporterOpts) =
  echo "importing..."
  opts.proj = opts.proj.absolutePath().AbsDir
  if opts.projName == "":
    opts.projName = opts.proj.lastPathPart()
  let optsPath = opts.proj / opts.projName & ".import.toml"

  var toml = Toml.loadFile(optsPath, ImporterConfig)
  echo "toml_value: ", toml
  echo "toml_value:skips: ", toml.skips
  let skips = toml.skips.toHashSet()
  for item in toml.imports:
    var imp = item
    echo "import: ", imp
    imp.outdir =  if imp.outdir.len() == 0: opts.proj / "src"
                  else: imp.outdir
    imp.sources = opts.proj / imp.sources
    importproject(imp, skips)

  echo "PWD: ", getCurrentDir()

  # importproject "opencv2", &"{srcDir}/include/", ["opencv2/*.hpp",]
  # importproject "core", &"{srcDir}/modules/core/include/opencv2/", ["*.hpp",]

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
