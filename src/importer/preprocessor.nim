import std / strutils

import lineinfos, pathutils
import ast, clexer, cparser

proc eatNewLine(p: var Parser, n: PNode) =
  if p.tok.xkind == pxLineComment:
    skipCom(p, n)
    if p.tok.xkind == pxNewLine: getTok(p)
  elif p.tok.xkind == pxNewLine:
    eat(p, pxNewLine)

proc skipLine(p: var Parser) =
  while p.tok.xkind notin {pxEof, pxNewLine, pxLineComment}:
    getTok(p)
  eatNewLine(p, nil)

proc parseRemoveIncludes*(p: var Parser, infile: string): PNode =
  # parse everything but strip extra includes

  proc parseLineDir(p: var Parser): (PNode, AbsoluteFile) = 
    try:
      let num = parseInt(p.tok.s)
      # ignore unimportant/unknown directive ("undef", "pragma", "error")
      rawGetTok(p)
      let li = newLineInfo(AbsoluteFile p.tok.s, num, 0)
      # echo "SKIP: ", num, " :: ", toProjPath(gConfig, li)
      result = (newNodeI(nkComesFrom, li), AbsoluteFile p.tok.s)
    except ValueError:
      var code = newNodeP(nkRawCode, p)
      code.strVals.add(p.lex.getCurrentLine())
      result = (code, AbsoluteFile "")
    skipLine(p)
    # eatNewLine(p, nil)
  
  var lastfile = AbsoluteFile ""
  result = newNode(nkStmtList)
  var isInFile = false

  while true:
    if p.tok.xkind == pxEof:
      break

    while p.tok.xkind in {pxDirective}:
      if p.tok.xkind == pxEof:
        break
      let res = parseLineDir(p)
      if res[1] != AbsoluteFile "":
        lastfile = res[1]
        isInFile = infile == lastfile.string
        # echo "IS_IN_FILE: ", isInFile, " file: ", lastfile.string

      if isInFile:
        result.add(res[0])

    var code = newNodeP(nkRawCode, p)
    while p.tok.xkind notin {pxEof, pxDirective}:
      if p.tok.xkind == pxLineComment:
        code.strVals.add("\n")
        for line in p.tok.s.splitLines():
          code.strVals.add("\n")
          code.strVals.add("//")
          code.strVals.add(line)
        code.strVals.add("\n")
      elif p.tok.xkind == pxStarComment:
        code.strVals.add("/*")
        code.strVals.add(p.tok.s)
        code.strVals.add("*/")
      # elif lastpos >= p.lex.bufpos:
      #   var tmp = " "
      #   tmp.add($p.tok[])
      #   code.strVal.add(tmp)
      else:
        # let tmp = p.lex.buf[lastpos..<p.lex.bufpos]
        code.strVals.add(p.lex.getCurrentLine())
      # lastpos = p.lex.bufpos
      # lastlen = p.lex.sentinel - lastpos
      getTok(p)
    
    # add code
    if isInFile:
      result.add(code)

  echo "done parsing preprocessed C file"
