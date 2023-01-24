import std/strutils
import std/parseutils
import std/pegs
import strutils, lexbase, streams, tables
import lexbase, streams

import patty

type
  SourceLineKind {.pure.} = enum
    m4LineDirective, m4Directive, m4Source, m4Comment, m4NewLine, m4Eof
  SourceLine = ref object
    case kind: SourceLineKind
    of m4LineDirective:
      line: int
      file: string
    of m4Directive:
      rawdir: string
    of m4Source:
      source: string
    of m4Comment:
      comment: string
    of m4NewLine:
      newline: string
    of m4Eof:
      discard

type
  PpLineDirective* = object
    lineNumber*: int
    filename*: string
    remainder*: string

  PpParser* = object of BaseLexer ## The parser object.
    line*: string
    directive*: PpLineDirective
    filename: string
    sep, esc: char
    skipWhite: bool
    currLine: int
    headers*: seq[string]

  PpError* = object of IOError ## An exception that is raised if
                                ## a parsing error occurs.

proc raiseEInvalidPp(filename: string, line, col: int,
                      msg: string) {.noreturn.} =
  var e: ref PpError
  new(e)
  if filename.len == 0:
    e.msg = "Error: " & msg
  else:
    e.msg = filename & "(" & $line & ", " & $col & ") Error: " & msg
  raise e

proc error(self: PpParser, pos: int, msg: string) =
  raiseEInvalidPp(self.filename, self.lineNumber, getColNumber(self, pos), msg)

proc open*(self: var PpParser, input: Stream, filename: string,
           separator = '\n', escape = '\0',
           skipInitialSpace = false) =
  ## Initializes the parser with an input stream. `Filename` is only used
  ## for nice error messages. The parser's behaviour can be controlled by
  ## the diverse optional parameters:
  lexbase.open(self, input)
  self.filename = filename
  self.sep = separator
  self.esc = escape
  self.skipWhite = skipInitialSpace

proc open*(self: var PpParser, filename: string,
           separator = '\n', escape = '\0',
           skipInitialSpace = false) =
  ## Similar to the `other open proc<#open,PpParser,Stream,string,char,char,char>`_,
  ## but creates the file stream for you.
  var s = newFileStream(filename, fmRead)
  if s == nil: self.error(0, "cannot open: " & filename)
  open(self, s, filename, separator,
       escape, skipInitialSpace)

proc handleChar( val: var string, self: var PpParser, pos: var int): bool {.discardable.} =
  # echo "handle: ", repr(self.buf[pos])
  case self.buf[pos]
  of '\r':
    pos = handleCR(self, pos)
    val.add "\n"
    result = true
  of '\n':
    pos = handleLF(self, pos)
    val.add "\n"
    result = true
  of '\0':
    val.add "\0"
    result = true
  else:
    val.add self.buf[pos]
    inc(pos)

proc parseLine(self: var PpParser): SourceLine =
  var pos = self.bufpos

  let c = self.buf[pos]
  # echo "got: ", repr(c)
  if c == lexbase.EndOfFile:
    result = SourceLine(kind: m4Eof)
  elif c == '\0':
    # echo "empty char: "
    result = SourceLine(kind: m4Eof)
    self.bufpos = pos # can continue after exception?
    error(self, pos, " expected")
  elif c in lexbase.NewLines:
    # echo "newline char: "
    result = SourceLine(kind: m4NewLine, newline: "\n")
    result.newline.handleChar(self, pos)
  elif c == '/':
    # echo "maybe comment: "
    if self.buf[pos+1] == '*':
      # echo "star comment: "
      result = SourceLine(kind: m4Comment)
      result.comment.add "/*"
      pos.inc(2)
      while true:
        # echo "comment:got: ", repr(self.buf[pos])
        result.comment.handleChar(self, pos)
        if self.buf[pos] == lexbase.EndOfFile:
          break
        elif self.buf[pos] == '*' and self.buf[pos+1] == '/':
          result.comment.add "*/"
          pos.inc(2)
          break
    elif self.buf[pos+1] == '/':
      # echo "comment"
      result = SourceLine(kind: m4Comment)
      while true:
        if result.comment.handleChar(self, pos):
          break
    else:
      # echo "not comment: ", self.buf[pos]
      result.source.handleChar(self, pos)
  elif c == '#': # get line
    # echo "dir: ", repr self.buf[pos]
    var str = ""
    while true:
      # echo "char:curr: ", repr(self.buf[pos])
      if str.handleChar(self, pos):
        break
    # echo "directive: `", str, "`"
    if str =~ peg"""'#'\s {\d+}\s '"'{[^"]+}'"'\s+ ({\d+} \s+)* \s*""":
      let line = matches[0].parseInt()
      let file = matches[1]
      # echo("line dir: ", line, " ", file)
      result = SourceLine(kind: m4LineDirective, line: line, file: file)
    else:
      # echo("other dir: ", str)
      result = SourceLine(kind: m4Directive, rawdir: str)
  else: # get line
    # echo "char: ", repr self.buf[pos]
    result = SourceLine(kind: m4Source)
    result.source.add(self.buf[pos])
    inc(pos)
    while self.buf[pos] != self.sep:
      # echo "char:curr: ", repr(self.buf[pos])
      if result.source.handleChar(self, pos):
        break
  
  self.bufpos = pos

proc process*(self: var PpParser, pth: string, output: File) =
  ## Reads the next row; if `columns` > 0, it expects the row to have
  ## exactly this many columns. Returns false if the end of the file
  ## has been encountered else true.
  ##
  ## Blank lines are skipped.

  echo "Processing: ", pth
  var isOrigSource = false
  while true:
    let res = parseLine(self)
    # echo "result: ", self.bufpos, " :: ", repr res

    case res.kind: 
    of m4LineDirective:
      isOrigSource = res.file == pth
    of m4Directive:
      if isOrigSource:
        output.write(res.rawdir)
    of m4Source:
      if isOrigSource:
        output.write(res.source)
    of m4Comment:
      if isOrigSource:
        output.write(res.comment)
    of m4NewLine:
      if isOrigSource:
        output.write("\n")
    of m4Eof:
      break

proc close*(self: var PpParser) {.inline.} =
  ## Closes the parser `self` and its associated input stream.
  lexbase.close(self)


when not defined(testing) and isMainModule:
  # let fl = "tests/ctests/simple.full.c"
  let
    # pth = "tests/ctests/basic.c"
    pth = "tests/ctests/basic.full.c"
    outpth = pth & ".pp"
  var s = newFileStream(pth, fmRead)
  if s == nil: quit("cannot open the file: " & pth)

  var output = open(outpth, fmWrite)
  var x: PpParser
  open(x, s, pth)
  process(x, "tests/ctests/basic.c", output)
  output.close()

  close(x)
