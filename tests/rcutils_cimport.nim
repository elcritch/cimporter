import cimporter/configure


addConfig:cimport:
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
    cmods:
      fileMatch: peg"'rcutils/types/' !'rcutils_ret' .+"
      C2NimConfig:list:
        item C2NimConfig:
          fileContents: """
            #skipInclude
            """
          rawNims:"""
            import rcutils_ret
            import ../allocator
            """
    cmods:
      fileMatch: peg"'rcutils/testing/fault_injection.h'"
      C2NimConfig:list:
        item C2NimConfig:
          fileContents: """
            #skipInclude
            """
    cmods:
      fileMatch: peg"'rcutils/types/array_list.h'"
      substitutes:list:
        item Replace:
          pattern: peg"'struct rcutils_array_list_impl_s;'"
          repl: """
              typedef struct rcutils_array_list_impl_s
              {
                size_t size;
                size_t capacity;
                void * list;
                size_t data_size;
                rcutils_allocator_t allocator;
              } rcutils_array_list_impl_t;
              """
        item Replace:
          pattern: peg"'rcutils_array_list_impl_s'"
          repl: "rcutils_array_list_impl_t"
    cmods:
      fileMatch: peg"'test'"

  echo "\nconfigs:"
  for n, v in config.fieldPairs:
    echo n, " => "
    for m, u in config.fieldPairs:
      echo "  ", m, ".", n, " => ", u
