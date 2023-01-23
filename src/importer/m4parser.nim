import std/strutils
import std/parseutils

import strutils, lexbase, streams, tables
import lexbase, streams

import patty

type
  SourceLineKind {.pure.} = enum
    m4Directive, m4Source, m4Comment, m4Eof
  SourceLine = ref object
    case kind: SourceLineKind
    of m4Directive:
      line: int
      file: string
    of m4Source:
      source: string
    of m4Comment:
      comment: string
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
  echo "handle: ", repr(self.buf[pos])
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
  echo "got: ", repr(c)
  if c == lexbase.EndOfFile:
    result = SourceLine(kind: m4Eof)
  elif c == '\0':
    echo "empty char: "
    result = SourceLine(kind: m4Eof)
    self.bufpos = pos # can continue after exception?
    error(self, pos, " expected")
  elif c == '/':
    echo "maybe comment: "
    if self.buf[pos+1] == '*':
      echo "star comment: "
      result = SourceLine(kind: m4Comment)
      result.comment.add "/*"
      pos.inc(2)
      while self.buf[pos] != '*':
        echo "comment:got: ", repr(self.buf[pos])
        if result.comment.handleChar(self, pos):
          break
    elif self.buf[pos+1] == '/':
      echo "comment"
      result = SourceLine(kind: m4Comment)
      while self.buf[pos] != self.sep:
        if result.comment.handleChar(self, pos):
          break
    else:
      echo "not comment: ", self.buf[pos]
      result.source.handleChar(self, pos)
  elif c == '#': # get line
    echo "dir: ", repr self.buf[pos]
    result = SourceLine(kind: m4Directive)
    while self.buf[pos] != self.sep:
      # echo "char:curr: ", repr(self.buf[pos])
      if self.buf[pos] == lexbase.EndOfFile:
        break
      if result.file.handleChar(self, pos):
        break
  else: # get line
    echo "char: ", repr self.buf[pos]
    result = SourceLine(kind: m4Source)
    inc(pos)
    while self.buf[pos] != self.sep:
      # echo "char:curr: ", repr(self.buf[pos])
      if self.buf[pos] == lexbase.EndOfFile:
        break
      if result.source.handleChar(self, pos):
        break
  
  self.bufpos = pos

proc readLine*(self: var PpParser, columns = 0): bool =
  ## Reads the next row; if `columns` > 0, it expects the row to have
  ## exactly this many columns. Returns false if the end of the file
  ## has been encountered else true.
  ##
  ## Blank lines are skipped.

  let oldpos = self.bufpos
  # skip initial empty lines
  while true:
    case self.buf[self.bufpos]
    of '\c': self.bufpos = handleCR(self, self.bufpos)
    of '\l': self.bufpos = handleLF(self, self.bufpos)
    else: break

  for i in 1..6:
    let res = parseLine(self)
    echo "result: ", self.bufpos, " :: ", repr res
    echo ""

  inc(self.currLine)

proc close*(self: var PpParser) {.inline.} =
  ## Closes the parser `self` and its associated input stream.
  lexbase.close(self)


when not defined(testing) and isMainModule:
  import os
  let fl = "tests/ctests/simple.full.c"
  var s = newFileStream(fl, fmRead)
  if s == nil: quit("cannot open the file: " & fl)

  var x: PpParser
  open(x, s, fl)
  while readLine(x):
    echo "new row: "
    echo ">>", x.line
  close(x)
