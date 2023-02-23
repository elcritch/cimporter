import ../src/cimporter/configure

echo "hi"

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
    FileNameReplace(pattern: peg"^'string.' .+", repl: "rstring$1")
  renameFiles:listOf(FileNameReplace):
    (pattern: peg"^'string.' .+", repl: "rstring$1")
    (pattern: peg"^'strings.' .+", repl: "rstrings$1")

  includes:list:
    "deps/rcutils/include"

  echo "config: ", config
