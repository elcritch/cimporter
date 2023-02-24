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
    cmods:
      fileMatch: peg"'rcutils/error_handling.h'"
      deletes:list:
        item LineDelete:
          match: peg"'make sure our math is right'"
          until: peg"'Maximum length calculations incorrect'"
          inclusive: true
    cmods:
      fileMatch: peg"'rcutils/macros.h'"
      deletes:list:
        LineDelete(match: peg"'RCUTILS_THREAD_LOCAL'")
    cmods:
      fileMatch: peg"'rcutils/error_handling.h'"
      deletes:list:
        LineDelete(match: peg"'__STDC_WANT_LIB_EXT1__'")
    cmods:
      fileMatch: peg"'rcutils/testing/fault_injection.h'"
      C2NimConfig:list:
        item C2NimConfig:
          fileContents: """
            #mangle "'_rcutils_fault_injection_maybe_fail'" "rcutils_fault_injection_maybe_fail"
            """

  echo "config: ", config
