import std/strutils
import std/parseutils

import strutils, lexbase, streams, tables
import lexbase, streams

type
  PpLine* = seq[string] ## A row in a Pp file.
  PpParser* = object of BaseLexer ## The parser object.
    line*: PpLine
    filename: string
    sep, quote, esc: char
    skipWhite: bool
    currRow: int
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
           separator = ',', quote = '"', escape = '\0',
           skipInitialSpace = false) =
  ## Initializes the parser with an input stream. `Filename` is only used
  ## for nice error messages. The parser's behaviour can be controlled by
  ## the diverse optional parameters:
  lexbase.open(self, input)
  self.filename = filename
  self.sep = separator
  self.quote = quote
  self.esc = escape
  self.skipWhite = skipInitialSpace

proc open*(self: var PpParser, filename: string,
           separator = ',', quote = '"', escape = '\0',
           skipInitialSpace = false) =
  ## Similar to the `other open proc<#open,PpParser,Stream,string,char,char,char>`_,
  ## but creates the file stream for you.
  var s = newFileStream(filename, fmRead)
  if s == nil: self.error(0, "cannot open: " & filename)
  open(self, s, filename, separator,
       quote, escape, skipInitialSpace)

proc parseLine(self: var PpParser, val: var string) =
  var pos = self.bufpos

  val.setLen(0) # reuse memory
  if self.buf[pos] == self.quote and self.quote != '\0':
    inc(pos)
    while true:
      let c = self.buf[pos]
      if c == '\0':
        self.bufpos = pos # can continue after exception?
        error(self, pos, self.quote & " expected")
        break
      elif c in {'"', '\''}:
        if self.buf[pos+1] in {'"', '\''}:
          val.add(self.buf[pos+1])
          inc(pos, 2)
        else:
          inc(pos)
          break
      elif c == '/':
        if self.esc == '\0' and self.buf[pos+1] in {'"', '\''}:
          val.add(self.buf[pos+1])
          inc(pos, 2)
        else:
          inc(pos)
          break
      elif c == '\\':
        val.add self.buf[pos+1]
        inc(pos, 2)
      else:
        case c
        of '\c':
          pos = handleCR(self, pos)
          val.add "\n"
        of '\l':
          pos = handleLF(self, pos)
          val.add "\n"
        else:
          val.add c
          inc(pos)
  else:
    while true:
      let c = self.buf[pos]
      # if c == self.sep: break
      # if c in {'\c', '\l', '\0'}: break
      val.add c
      inc(pos)
  self.bufpos = pos

proc readLine*(self: var PpParser, columns = 0): bool =
  ## Reads the next row; if `columns` > 0, it expects the row to have
  ## exactly this many columns. Returns false if the end of the file
  ## has been encountered else true.
  ##
  ## Blank lines are skipped.

  var col = 0 # current column
  let oldpos = self.bufpos

  # skip initial empty lines
  while true:
    case self.buf[self.bufpos]
    of '\c': self.bufpos = handleCR(self, self.bufpos)
    of '\l': self.bufpos = handleLF(self, self.bufpos)
    else: break

  while self.buf[self.bufpos] != '\0':
    let oldlen = self.line.len
    if oldlen < col + 1:
      setLen(self.line, col + 1)
      self.line[col] = ""
    parseLine(self, self.line[col])
    inc(col)
    if self.buf[self.bufpos] == self.sep:
      inc(self.bufpos)
    else:
      case self.buf[self.bufpos]
      of '\c', '\l':
        # skip empty lines:
        while true:
          case self.buf[self.bufpos]
          of '\c': self.bufpos = handleCR(self, self.bufpos)
          of '\l': self.bufpos = handleLF(self, self.bufpos)
          else: break
      of '\0': discard
      else: error(self, self.bufpos, self.sep & " expected")
      break

  setLen(self.line, col)
  result = col > 0
  if result and col != columns and columns > 0:
    error(self, oldpos + 1, $columns & " columns expected, but found " &
          $col & " columns")
  inc(self.currRow)

proc close*(self: var PpParser) {.inline.} =
  ## Closes the parser `self` and its associated input stream.
  lexbase.close(self)


when not defined(testing) and isMainModule:
  import os
  var s = newFileStream(paramStr(1), fmRead)
  if s == nil: quit("cannot open the file" & paramStr(1))

  var x: PpParser
  open(x, s, paramStr(1))
  while readLine(x):
    echo "new row: "
    echo ">>", x.line
  close(x)
