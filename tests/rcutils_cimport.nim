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
      substitutes:list:
        item Replace:
          pattern: peg"'rcutils_array_list_impl_s'"
          repl: "rcutils_array_list_impl_t"
    cmods:
      fileMatch: peg"'rcutils/types/hash_map.h'"
      substitutes:list:
        item Replace:
          pattern: peg"'rcutils_hash_map_impl_s'"
          repl: "rcutils_hash_map_impl_t"
        item Replace:
          pattern: peg"'struct rcutils_hash_map_impl_s;'"
          repl: """
            typedef struct rcutils_hash_map_impl_s
            {
              // This is the array of buckets that will store the keypairs
              rcutils_array_list_t * map;
              size_t capacity;
              size_t size;
              size_t key_size;
              size_t data_size;
              rcutils_hash_map_key_hasher_t key_hashing_func;
              rcutils_hash_map_key_cmp_t key_cmp_func;
              rcutils_allocator_t allocator;
            } rcutils_hash_map_impl_t;
            """
    cmods:
      fileMatch: peg"'rcutils/types/string_map.h'"
      substitutes:list:
        item Replace:
          pattern: peg"'rcutils_string_map_impl_s'"
          repl: "rcutils_string_map_impl_t"
        item Replace:
          pattern: peg"'struct rcutils_string_map_impl_s;'"
          repl:
            """
            typedef struct rcutils_string_map_impl_s
            {
              char ** keys;
              char ** values;
              size_t capacity;
              size_t size;
              rcutils_allocator_t allocator;
            } rcutils_string_map_impl_t;
            """
    cmods:
      fileMatch: peg"'rcutils/logging.h'"
      deletes:list:
        LineDelete(match: peg"'RCUTILS_LOGGING_AUTOINIT'")
        LineDelete(match: peg"'RCUTILS_DEFAULT_LOGGER_DEFAULT_LEVEL'")
        LineDelete(match: peg"'g_rcutils_log_severity_names'")
    cmods:
      fileMatch: peg"'.h'"
      deletes:list:
        LineDelete(match: peg"'RCUTILS_STEADY_TIME'")
      substitutes:list:
        replaces:
          pattern: peg"'va_list' \\s+ '*'"
          repl: "va_list"
  
  c2nimCfgs:list:
    C2Nims:
      fileMatch: peg"'rcutils/testing/fault_injection.h'"
      fileContents: """
        #mangle "'_rcutils_fault_injection_maybe_fail'" "rcutils_fault_injection_maybe_fail"
        """
    C2Nims:
      fileMatch: peg"'rcutils/types/' !'rcutils_ret' .+"
      fileContents: """
        #skipInclude
        """
      rawNims:"""
        import rcutils_ret
        import ../allocator
        """
    C2Nims:
      fileMatch: peg"'rcutils/testing/fault_injection.h'"
      fileContents: """
        #skipInclude
        """
    C2Nims:
      fileMatch: peg"'rcutils/types/hash_map.h'"
      rawNims: """
        import array_list
        """
    C2Nims:
      fileMatch: peg"'rcutils/types/string_map.h'"
      rawNims: """
        import ../allocator
        import ../types/array_list
        """
    C2Nims:
      fileMatch: peg"'rcutils/logging.h'"
      rawNims: """
        import ./time
        proc RCUTILS_LOGGING_AUTOINIT*() {.importc: "RCUTILS_LOGGING_AUTOINIT", header: "rcutils/logging.h".}
        """
    C2Nims:
      fileMatch: peg"'rcutils/isalnum_no_locale.h'"
      rawNims: """
        converter charToNum*(c: char): int = c.int 
        """


import json
proc `%`(n: Peg): JsonNode = %($n)
let res = % configs
echo res.pretty()
