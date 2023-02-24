import cimporter/configure

# var cimportList = ImporterConfig()
proc cmodsImpl(): CSrcMods =
  discard

cimport:
  name: "rcutils"
  sources: "deps/rcutils/include"
  globs: ["**/*.h"]
  skipFiles:list:
    "rcutils/stdatomic_helper/win32/stdatomic.h"
    "rcutils/stdatomic_helper/gcc/stdatomic.h"
    "rcutils/stdatomic_helper.h"
  includes:list:
    "deps/rcutils/include"

  renameFiles:list:
    Replace(pattern: peg"^'string.' .+", repl: "rstring$1")
  renameFiles:listOf Replace:
    (pattern: peg"^'string.' .+", repl: "rstring$1")
  renameFiles:list:
    item Replace:
      pattern: peg"^'string.' .+"
      repl: "rstring$1"

  sourceMods:list:
    cmods:
      fileMatch: peg"'rcutils/visibility_control.h'"
      deletes:list:
        LineDelete(match: peg"'RCUTILS_PUBLIC'")
        LineDelete(match: peg"'RCUTILS_PUBLIC_TYPE'")
    item CSrcMods:
      fileMatch: peg"'rcutils/visibility_control.h'"

  echo "config: ", config
