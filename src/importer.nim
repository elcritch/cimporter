import std/[os, sequtils, osproc, strutils, strformat, sets, json]
import std/[tables]

import importer/m4parser

type
  ImporterOpts* = object
    srcDir: string
    compiler: string
    ccExpandFlag: string
    ccFlag: seq[string]
    noDefaultFlags: bool
    `include`: seq[string]

const dflOpts* = ImporterOpts(
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
  
proc mkC2NimCmd(proj, file: string,
                pre: seq[string],
                outdir: string): string =
  let cfgC2nim = outdir / $(file.extractFilename()).changeFileExt("c2nim")
  var cfgFile = ""
  if cfgC2nim.fileExists():
    echo "CFGFILE: ", cfgC2nim
    cfgFile = cfgC2nim

  let post: seq[string] = @["--debug"] # modify progs
  let mangles = projMangles(proj) &
        @[ fmt"--mangle:'rcutils/' {{\w+}}=../rcutils/$1" ] 
  let files = @[ &"--concat:all"] & pre & @[ $cfgFile, $file ]

  result = mkCmd("c2nim", post & mangles & files)
  
proc run(cmds: seq[string], flags: set[ProcessOption] = {}) =
  let res = execProcesses(cmds, options = flags +
                {poParentStreams, poStdErrToStdOut, poEchoCmd})
  if res != 0:
    raise newException(ValueError, "c2nim failed")
  echo "RESULT: ", res

proc importproject(proj, dir: string,
                    globs: openArray[string],
                    skips: HashSet[string],
                    nimDir: string,
                    outdir = "") =
  let outdir = if outdir.len() == 0: nimDir/proj else: outdir
  createDir outdir

  let c2nImports = "tests/imports.c2nim"
  let c2nPre = dir / &"{proj}.pre.c2nim"
  echo "C2N: ", c2nPre
  # let fixup= "fix_" & proj.replace(os.DirSep,"_")
  # let c2nimStrExtra = "\n#@\n" & fmt"import {fixup}" & "\n@#\n\n"
  # let c2nimStrExtra = ""
  # writeFile c2nPre, c2nimStr & c2nimStrExtra
  let c2nProj = (nimDir/proj).addFileExt(".proj.c2nim")
  if not fileExists c2nProj:
    raise newException(ValueError, "missing file: "&c2nProj)
  echo "PROJ CNIM: ", c2nProj
  let c2n = @[c2nImports, c2nProj.absolutePath]

  # run commands
  var cmds: seq[string]
  var files: seq[string]
  for pat in globs:
    let fileGlob = fmt"{dir}/{pat}"
    echo "file glob: ", fileGlob
    files.add toSeq(walkFiles(fileGlob))
  echo "found files: ", files
  for f in files:
    if f.relativePath(&"{dir}") in skips:
      echo "SKIPPING: ", f
    else:
      cmds.add(mkC2NimCmd(proj, f, c2n, outdir))
  run(cmds)

  # move nim files
  for f in toSeq(walkFiles dir / proj / "*.nim"):
    mv f, outdir / f.extractFilename
  
proc runImports*(cfg: ImporterOpts) =
  echo "importing..."

  let options = toSeq(walkDirs(cfg.srcDir / "*.importer.toml"))
  echo "options: ", options
  # let paths = toSeq(walkDirs(cfg.srcDir / "*.proj.c2nim"))
  # echo "paths: ", paths
  # let c2nimStr = readFile("tests/imports.c2nim")

  # let skips = cfg.srcDir / "imports.skips"
  # let skips = readFile().  split("\n").mapIt(it.strip()).toHashSet()
  
  # echo "SKIPS: ", skips
  echo "PWD: ", getCurrentDir()

  # importproject "opencv2", &"{srcDir}/include/", ["opencv2/*.hpp",]
  # importproject "core", &"{srcDir}/modules/core/include/opencv2/", ["*.hpp",]

  echo "[Success]"

when isMainModule: # Preserve ability to `import api`/call from Nim
  const
    Short = { "srcDir": 'p',
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
