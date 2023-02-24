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
      c2NimConfig:list:
        item C2NimConfig:
          fileContents: """
            #mangle "'_rcutils_fault_injection_maybe_fail'" "rcutils_fault_injection_maybe_fail"
            """
    cmods:
      fileMatch: peg"'rcutils/types/' !'rcutils_ret' .+"
      c2NimConfig:list:
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
      c2NimConfig:list:
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
      c2NimConfig:list:
        c2nims:
          rawNims: """
            import array_list
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
      c2NimConfig:list:
        c2nims:
          rawNims: """
            import ../allocator
            import ../types/array_list
            """


import json
proc `%`(n: Peg): JsonNode = %($n)
let res = % configs
echo res.pretty()
