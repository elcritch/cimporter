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

proc handleChar( val: var string, self: var PpParser, pos: var int) =
  case self.buf[pos]
  of '\r':
    pos = handleCR(self, pos)
    val.add "\n"
  of '\n':
    pos = handleLF(self, pos)
    val.add "\n"
  else:
    val.add self.buf[pos]
    inc(pos)

proc parseLine(self: var PpParser): SourceLine =
  var pos = self.bufpos

  while true:
    let c = self.buf[pos]
    if c == lexbase.EndOfFile:
      result = SourceLine(kind: m4Eof)
    if c == '\0':
      result = SourceLine(kind: m4Eof)
      self.bufpos = pos # can continue after exception?
      error(self, pos, " expected")
      break
    elif c == '/':
      if self.buf[pos+1] == '*':
        echo "star comment: "
        result = SourceLine(kind: m4Comment)
        result.comment.add "/*"
        pos.inc(2)
        while self.buf[pos] != '*':
          result.comment.handleChar(self, pos)
          inc(pos)
      elif self.buf[pos+1] == '/':
        echo "comment"
        result = SourceLine(kind: m4Comment)
        while self.buf[pos+1] != self.sep:
          result.comment.add self.buf[pos+1]
      else:
        result.source.handleChar(self, pos)
        break
    else:
      result = SourceLine(kind: m4Source)
      while self.buf[pos+1] != self.sep:
        result.source.add self.buf[pos+1]
  
  # while true:
  #   let c = self.buf[pos]
  #   if c == '\n': break
  #   if c in {'\c', '\l', '\0'}: break
  #   val.add c
  #   inc(pos)
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

  while true:
    let res = parseLine(self)
    echo "result: ", repr res

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
