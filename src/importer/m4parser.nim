import std/strutils
import std/parseutils

import strutils, lexbase, streams, tables
import lexbase, streams

type
  PpLine* = seq[string] ## A row in a Pp file.
  PpParser* = object of BaseLexer ## The parser object.
                                   ##
                                   ## It consists of two public fields:
                                   ## * `row` is the current row
                                   ## * `headers` are the columns that are defined in the Pp file
                                   ##   (read using `readHeaderRow <#readHeaderRow,PpParser>`_).
                                   ##   Used with `rowEntry <#rowEntry,PpParser,string>`_).
    row*: PpLine
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

proc parseField(self: var PpParser, a: var string) =
  var pos = self.bufpos
  if self.skipWhite:
    while self.buf[pos] in {' ', '\t'}: inc(pos)
  setLen(a, 0) # reuse memory
  if self.buf[pos] == self.quote and self.quote != '\0':
    inc(pos)
    while true:
      let c = self.buf[pos]
      if c == '\0':
        self.bufpos = pos # can continue after exception?
        error(self, pos, self.quote & " expected")
        break
      elif c == self.quote:
        if self.esc == '\0' and self.buf[pos + 1] == self.quote:
          add(a, self.quote)
          inc(pos, 2)
        else:
          inc(pos)
          break
      elif c == self.esc:
        add(a, self.buf[pos + 1])
        inc(pos, 2)
      else:
        case c
        of '\c':
          pos = handleCR(self, pos)
          add(a, "\n")
        of '\l':
          pos = handleLF(self, pos)
          add(a, "\n")
        else:
          add(a, c)
          inc(pos)
  else:
    while true:
      let c = self.buf[pos]
      if c == self.sep: break
      if c in {'\c', '\l', '\0'}: break
      add(a, c)
      inc(pos)
  self.bufpos = pos

proc processedRows*(self: var PpParser): int {.inline.} =
  ## Returns number of the processed rows.
  ##
  ## But even if `readLine <#readLine,PpParser,int>`_ arrived at EOF then
  ## processed rows counter is incremented.
  runnableExamples:
    import std/streams

    var strm = newStringStream("One,Two,Three\n1,2,3")
    var parser: PpParser
    parser.open(strm, "tmp.Pp")
    doAssert parser.readLine()
    doAssert parser.processedRows() == 1
    doAssert parser.readLine()
    doAssert parser.processedRows() == 2
    ## Even if `readLine` arrived at EOF then `processedRows` is incremented.
    doAssert parser.readLine() == false
    doAssert parser.processedRows() == 3
    doAssert parser.readLine() == false
    doAssert parser.processedRows() == 4
    parser.close()
    strm.close()

  self.currRow

proc readLine*(self: var PpParser, columns = 0): bool =
  ## Reads the next row; if `columns` > 0, it expects the row to have
  ## exactly this many columns. Returns false if the end of the file
  ## has been encountered else true.
  ##
  ## Blank lines are skipped.
  runnableExamples:
    import std/streams
    var strm = newStringStream("One,Two,Three\n1,2,3\n\n10,20,30")
    var parser: PpParser
    parser.open(strm, "tmp.Pp")
    doAssert parser.readLine()
    doAssert parser.row == @["One", "Two", "Three"]
    doAssert parser.readLine()
    doAssert parser.row == @["1", "2", "3"]
    ## Blank lines are skipped.
    doAssert parser.readLine()
    doAssert parser.row == @["10", "20", "30"]

    var emptySeq: seq[string]
    doAssert parser.readLine() == false
    doAssert parser.row == emptySeq
    doAssert parser.readLine() == false
    doAssert parser.row == emptySeq

    parser.close()
    strm.close()

  var col = 0 # current column
  let oldpos = self.bufpos
  # skip initial empty lines #8365
  while true:
    case self.buf[self.bufpos]
    of '\c': self.bufpos = handleCR(self, self.bufpos)
    of '\l': self.bufpos = handleLF(self, self.bufpos)
    else: break
  while self.buf[self.bufpos] != '\0':
    let oldlen = self.row.len
    if oldlen < col + 1:
      setLen(self.row, col + 1)
      self.row[col] = ""
    parseField(self, self.row[col])
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

  setLen(self.row, col)
  result = col > 0
  if result and col != columns and columns > 0:
    error(self, oldpos + 1, $columns & " columns expected, but found " &
          $col & " columns")
  inc(self.currRow)

proc close*(self: var PpParser) {.inline.} =
  ## Closes the parser `self` and its associated input stream.
  lexbase.close(self)

proc readHeaderRow*(self: var PpParser) =
  ## Reads the first row and creates a look-up table for column numbers
  ## See also:
  ## * `rowEntry proc <#rowEntry,PpParser,string>`_
  runnableExamples:
    import std/streams

    var strm = newStringStream("One,Two,Three\n1,2,3")
    var parser: PpParser
    parser.open(strm, "tmp.Pp")

    parser.readHeaderRow()
    doAssert parser.headers == @["One", "Two", "Three"]
    doAssert parser.row == @["One", "Two", "Three"]

    doAssert parser.readLine()
    doAssert parser.headers == @["One", "Two", "Three"]
    doAssert parser.row == @["1", "2", "3"]

    parser.close()
    strm.close()

  let present = self.readLine()
  if present:
    self.headers = self.row

proc rowEntry*(self: var PpParser, entry: string): var string =
  ## Accesses a specified `entry` from the current row.
  ##
  ## Assumes that `readHeaderRow <#readHeaderRow,PpParser>`_ has already been
  ## called.
  ##
  ## If specified `entry` does not exist, raises KeyError.
  runnableExamples:
    import std/streams
    var strm = newStringStream("One,Two,Three\n1,2,3\n\n10,20,30")
    var parser: PpParser
    parser.open(strm, "tmp.Pp")
    ## Requires calling `readHeaderRow`.
    parser.readHeaderRow()
    doAssert parser.readLine()
    doAssert parser.rowEntry("One") == "1"
    doAssert parser.rowEntry("Two") == "2"
    doAssert parser.rowEntry("Three") == "3"
    doAssertRaises(KeyError):
      discard parser.rowEntry("NonexistentEntry")
    parser.close()
    strm.close()

  let index = self.headers.find(entry)
  if index >= 0:
    result = self.row[index]
  else:
    raise newException(KeyError, "Entry `" & entry & "` doesn't exist")

when not defined(testing) and isMainModule:
  import os
  var s = newFileStream(paramStr(1), fmRead)
  if s == nil: quit("cannot open the file" & paramStr(1))
  var x: PpParser
  open(x, s, paramStr(1))
  while readLine(x):
    echo "new row: "
    for val in items(x.row):
      echo "##", val, "##"
  close(x)
