import std/[os, sequtils, osproc, strutils, strformat, sets, json]

let
  srcDir="./".absolutePath
  nimDir="src/openvcv4/"

# let c2nimStr = readFile("tests/imports.c2nim")
let skips = readFile("tests/imports.skips").split("\n").mapIt(it.strip()).toHashSet()
echo "SKIPS: ", skips

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
  let pj = proj.split("/")
  for i in 0..<pj.len():
    let p1 = pj[0..i].join("/") & "/"
    let pp = relativePath(p1, proj) & "/"
    result.add fmt"--mangle:'{p1}' {{\w+}}={pp}$1"
  
proc mkC2NimCmd(proj, file: string, pre: seq[string], outdir: string): string =

  let cfgC2nim = outdir / $(file.extractFilename()).changeFileExt("c2nim")
  var cfgFile = ""
  if cfgC2nim.fileExists():
    echo "CFGFILE: ", cfgC2nim
    cfgFile = cfgC2nim

  let post: seq[string] = @["--debug"] # modify progs
            # # preprocessor
            # &"--preprocess:/opt/homebrew/bin/gcc-12",
            # &"--pp:flags=-E -CC -dI",
            # &"-D:RCL_ALIGNAS(N)=__attribute__ ((align(8)))",
            # &"-D:_Alignas(N)=__attribute__ ((align(8)))",
            # &"-I:{srcDir}/rcl/rcl/include/",
            # &"-I:{srcDir}/rcl/rcl_yaml_param_parser/include",
            # &"-I:{srcDir}/rcutils/include/",
            # &"-I:{srcDir}/rmw_fastrtps/rmw_fastrtps_cpp/include/",
            # &"-I:{srcDir}/rmw/rmw/include/",
            # &"-I:{srcDir}/rosidl/rosidl_runtime_c/include/",
            # &"-I:{srcDir}/rosidl/rosidl_typesupport_interface/include/"]
  
  let mangles = projMangles(proj) & @[ fmt"--mangle:'rcutils/' {{\w+}}=../rcutils/$1" ] 
  let files = @[ &"--concat:all"] & pre & @[ $cfgFile, $file ]

  result = mkCmd("c2nim", post & mangles & files)
  
proc run(cmds: seq[string], flags: set[ProcessOption] = {}) =
  let res = execProcesses(cmds, options = flags + {poParentStreams, poStdErrToStdOut, poEchoCmd})
  if res != 0:
    raise newException(ValueError, "c2nim failed")
  echo "RESULT: ", res

proc importproject(proj, dir: string, globs: openArray[string], outdir = "") =
  let outdir = if outdir.len() == 0: nimDir/proj else: outdir
  createDir outdir

  let c2nImports = "tests/imports.c2nim"
  let c2nPre = dir / &"{proj}.pre.c2nim"
  echo "C2N: ", c2nPre
  # let fixup= "fix_" & proj.replace("/","_")
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

  # let fixupPath = outdir/fixup & ".nim"
  # if not fileExists fixupPath:
  #   writeFile fixupPath, ""

echo "PWD: ", getCurrentDir()

importproject "opencv2", &"{srcDir}/include/", ["opencv2/*.hpp",]
importproject "core", &"{srcDir}/modules/core/include/opencv2/", ["*.hpp",]

echo "[Success]"
