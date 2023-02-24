import cimporter/configure

# var cimportList = ImporterConfig()

cimport:
  name: "rcutils"
  sources: "deps/rcutils/include"
  globs: ["**/*.h"]
  skipFiles:list:
    "rcutils/stdatomic_helper/win32/stdatomic.h"
    "rcutils/stdatomic_helper/gcc/stdatomic.h"
    "rcutils/stdatomic_helper.h"
  renameFiles:list:
    Replace(pattern: peg"^'string.' .+", repl: "rstring$1")
  renameFiles:listOf Replace:
    (pattern: peg"^'string.' .+", repl: "rstring$1")
    (pattern: peg"^'strings.' .+", repl: "rstrings$1")

  includes:list:
    "deps/rcutils/include"

  sourceMods:list:
    item CSrcMods:
      fileMatch: peg"'rcutils/visibility_control.h'"

  echo "config: ", config
