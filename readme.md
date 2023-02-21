# cimporter

Project that wraps c2nim to automate creating bindings for larger c projects. 

WIP! This currently relies on a pending PR on c2nim to make it useful. Also, the `.cimport.yml` is likely to be switched to a nim script variant. However, it does alreay work pretty well. 

## Usage

This works in two stages:
1. run C preprocessor on the source files
2. run c2nim on the processed C files

They're configured by two files that need to be placed in the root of the Nim project: 
- `<my_project>.cimport.yml`
- `<my_project>.c2nim`

### C Preprocessor Stage 

The first stage uses the C compilers `-E` flag (for gcc/clang) to output the result of running the C processor on a source file. This has the benefit of expanding the many pesky m4 macros (C macros) that larger C projects tend to use everywhere.

In addition, `cimporter` also provides the ability to do deletes, substitutions, or additions to the C source before it's passed to `c2nim` . This provides the ability to modify the C sources before it gets passed to `c2nim`. This enables automating importing a C project to keep it updated, or to change the format, etc. It's particularly helpful when first starting a wrapper / import project. 

These macros *aren't* always well formed C and often confuse the parsers like c2nim. Note gcc/clang both parse C code *after* the preprocessor stage has been run. 

For example: 

```c
RCUTILS_PUBLIC RCUTILS_WARN_UNUSED rcutils_allocator_t rcutils_get_zero_initialized_allocator(void);
```

Becomes: 

```c
__attribute__ ((visibility("default"))) __attribute__((warn_unused_result)) rcutils_allocator_t rcutils_get_zero_initialized_allocator(void);
```

The first is not readily parseable C without heuristic or setting up the proper c2nim defines. However, the expanded version `__attribute__ ((visibility("default")))` is valid C. 

`cimporter` handles properly stripping out expanded system headers from the pre-processed C code. This tends to leave behind a much simpler C source which can be parsed often with no c2nim defines. 

### c2nim stage

This runs `c2nim` on the C source files that have been pre-processed and possibly modified. `cimporter` supports a few different ways to pass arguments to `c2nim` and helps automate the process. 

The primary one is a global c2nim config file `<my_project>.c2nim` which is passed to each call to c2nim. Per-file c2nim configs can be passed in the `<my_project>.cimport.yml` as well under the `c2NimConfigs` yaml field. 

## Notes

There's still pain points, mainly due to how different each C project can be setup. Imports are often a pain, as are the various mangles. `nep1` can be a good option. 

Luckily `c2nim` has gained a number of new ways to tweak how it imports C headers that can help reduce much of the friction. 

Here's a good default c2nim recipie to use:

```c
#pragma c2nim strict
#pragma c2nim importc
#pragma c2nim cdecl
#pragma c2nim header

#pragma c2nim reordercomments // make C comments follow Nim style (mostly)
#pragma c2nim mergeDuplicates // merge duplicates that arise after preprocessing
#pragma c2nim skipFuncDefines // skip function bodies on inline c functions when using cdecl
#pragma c2nim importFuncDefines

#pragma c2nim mergeblocks // helps reduce number of times when certain C types can be defined out of order
#pragma c2nim stdints // convert modern standard int's like uint8_t, etc
#pragma c2nim cppSkipCallOp
#pragma c2nim cppSkipConverter
#pragma c2nim cppskipconverter

#pragma c2nim render nonNep1Imports // useful to enable using nep1 with imports -- otherwise C file names won't match
#pragma c2nim render extranewlines
#pragma c2nim render reindentlongcomments

#pragma c2nim mangle "'va_list'" "varargs[pointer]" // convert va_list to nim's version
#pragma c2nim mangle "'_Bool'" "bool" // how bools end up after preprocessing in clang -- should probably be handled in stdints above 

#pragma c2nim delete "RCUTILS_ERROR_STATE_FILE_MAX_LENGTH" // delete annoying C arrays or other bits
#pragma c2nim delete "'rcutils/stdatomic_helper'" // remove broken c include -> nim import mappings -- unfortunately relies on the '/' in the name
```

## Note on PEGs

PEGs are an alternative RegEx form that the Nim compiler uses because they're fast. However, they're fast because they don't allow ambiguous matches. 

This means that a `{\\w+} '_some_suffix'` would seem like it should match a regex `(\\w+)_some_suffix` it doesn't. The reason is that `\\w+` could match `var_name_some_suffix_some_suffix`. You can often do a `{@'_some_suffix'}` which would match this sequence. Unfortunately, this breaks with short expressions like `{@'_p'}` which can be matched multiple times. 

I may switch `cimporter` to use regexes, or support both. But currently PEGs work well enough.  

## Helpers

Example of populating a main file with imports/exports for every module: 

```zsh
PROJ=rmw
echo 'export' >> src/$PROJ.nim; ls src/$PROJ/**/*.nim  | perl -pe 's/src\/\w+\//  /; s/.nim/,/' >> src/$PROJ.nim

echo 'export' >> src/$PROJ.nim; ls src/$PROJ/**/*.nim  | perl -pe 's/src\/(\w+\/)+/  /; s/.nim/,/' >> src/$PROJ.nim
```
