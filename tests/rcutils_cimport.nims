import ../src/cimporter/configure

echo "hi"

# var cimportList = ImporterConfig()

cimport:
  name: "rcutils"
  sources: "deps/rcutils/include"
  globs: ["**/*.h"]
  skips:list:
    "rcutils/stdatomic_helper/win32/stdatomic.h"
    "rcutils/stdatomic_helper/gcc/stdatomic.h"
    "rcutils/stdatomic_helper.h"
  skips:list:
    "abc"
  includes:list:
    "deps/rcutils/include"

  echo "config: ", config
