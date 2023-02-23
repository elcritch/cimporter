import std/[os, sequtils, osproc, strutils, strformat, sets, json]
import std/[tables, pegs]

import cimporter/m4parser
import cimporter/configure

import nimscripter, nimscripter/variables

# import toml_serialization
import glob
import print

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
    res = cfg.renames.mapIt((it.pattern, it.repl))
    name = split.name.
              parallelReplace(res).
              changeFileExt("nim")
    tgtfile = cfg.outdir / split.dir / name
    tgtParentFile = tgtfile.parentDir()
    cfgC2nim = cfg.outdir/file.extractFilename().
                changeFileExt("c2nim")

  createDir(tgtParentFile)
  let post = @["--debug", "--header:\"" & file.splitFile().name & "\""] # modify progs
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
  print cfg
  # for f, v in cfg.fieldPairs():
  #   echo "\t", f, ": ", v
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
  var c2NimConfigs: Table[string, seq[C2NimConfigs]]
  var ppFiles: seq[string]
  let skips = cfg.skips.toHashSet()
  for f in files:
    let relFile = f.relativePath(&"{cfg.sources}")
    if relFile in skips:
      continue
    let mods = cfg.cSourceModifications.fileMatches(f)
    var subs: seq[(Peg, string)]
    for s in mods.mapIt(it.substitutes).concat():
      if s.comment: subs.add((s.peg, "// !!!ignoring!!! $1"))
      else: subs.add((s.peg, s.repl))
    
    var dels: seq[(Peg, (Option[Peg], bool))]
    for it in mods.mapIt(it.deletes).concat:
      # hack for lack of option type
      if $it.until == "":
        dels.add( (it.match, (Peg.none, it.inclusive)) )
      else:
        dels.add( (it.match, (it.until.some, it.inclusive)) )
    let
      pf = if opts.skipPreprocess:
              copyFile(f, f & ".pp")
              f & ".pp"
            else:
              ccpreprocess(f, ccopts, subs, dels, false)
    ppFiles.add(pf)

    let extras = mods.mapIt(it.c2NimConfigs).concat()
    if extras.len() > 0:
      c2NimConfigs[pf] = extras

  # Run C2NIM
  var c2n: seq[string]
  if opts.projC2Nim != "":
    c2n.insert(opts.projC2Nim, 0)

  var cmds: seq[string]
  var c2nCleanup: seq[string]
  # echo "PP FILES: ", ppFiles

  for pp in ppFiles:
    var c2n = c2n
    let c2extras = c2NimConfigs.getOrDefault(pp, @[])
    var extraArgs = c2extras.mapIt(it.extraArgs).concat().mapIt("--"&it)
    if cfg.removeModulePrefixes.len() > 0:
      let prefix = cfg.removeModulePrefixes %
                          [pp.splitFile().name.splitFile().name]
      extraArgs.add("--prefix:" & prefix)
    let c2files = c2extras.mapIt(it.fileContents).join("")
    let c2rawNims = c2extras.mapIt(it.rawNims).join("")
    if c2files.len() > 0 or c2rawNims.len() > 0:
      # echo "EXTRA C2N: ", pp
      let ppC2 = pp.changeFileExt(".c2nim")
      let raws = if c2rawNims.len() == 0: "" else: "#@\n" & c2rawNims & "\n@#"
      writeFile(ppC2 , c2files & raws)
      c2n.add ppC2
      c2nCleanup.add ppC2
    cmds.add(mkC2NimCmd(pp, c2n, cfg, extraArgs))
  # echo "C2NIM CMDS: ", cmds
  run cmds

  if not ccopts.skipClean:
    for pp in ppFiles:
      echo "removing output file: ", pp
      pp.removeFile()
    for c2n in c2nCleanup:
      echo "removing output file: ", c2n
      c2n.removeFile()

import compiler/[ast]

# proc toVm*[T: Peg](a: T): PNode = newStrNode(nkStrLit, a)

proc fromVm*(t: typedesc[Peg], node: PNode): Peg =
  if node.kind == nkStrLit:
    peg(node.strVal)
  else:
    raise newException(VMParseError, "Cannot convert to: " & $t)

proc runConfigScript*(path: string): ImporterConfig =

  # var cimportList = ImporterConfig()
  # proc addCImportConfig(config: ImportConfig) = 
  #   ## add cimport list
  #   cimportList.imports.add config
  
  # exportTo(scriptModule,
  #   addCImportConfig,
  # )


  let
    # scriptProcs = implNimScriptModule(scriptModule)
    intr = loadScript(
      NimScriptPath(path),
      # stdPath = "stdlib/",
      defines = @{"nimscript": "true",
                  "nimconfig": "true",
                  "nimscripter": "true"})
  
  getGlobalNimsVars intr:
    cimportList = ImporterConfig()
  result = cimportList


proc runImports*(opts: var CImporterOpts) =
  echo "importing..."
  opts.proj = opts.proj.absolutePath().AbsDir
  if opts.projName == "":
    opts.projName = opts.proj.lastPathPart()
  # let optsPath = opts.proj / opts.projName & ".cimport.yml"
  let optsPath = opts.proj / opts.projName & "_cimport.nims"
  if opts.projC2Nim == "":
    opts.projC2Nim = opts.proj / opts.projName & ".c2nim"
  if not opts.projC2Nim.fileExists():
    opts.projC2Nim = ""
  echo "Options Path: ", optsPath 
  echo "C2Nim Path: ", opts.projC2Nim 

  if not optsPath.fileExists():
    raise newException(ValueError, "couldn't find config file: " & optsPath)
  # var configs: ImporterConfig
  # var s = newFileStream(optsPath)
  # load(s, configs)
  let configs = runConfigScript(optsPath)
  # echo "config: ", $configs
  echo "configs: "
  # print configs
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
