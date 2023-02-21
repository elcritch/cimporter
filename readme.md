# cimporter

Project that wraps c2nim to automate creating bindings for larger c projects. 

This works in two stages:
1. run C preprocessor on the source files
2. run c2nim on the processed C files

They're configured by two files that need to be placed in the root of the Nim project: 
- `<my_project>.cimport.yml`
- `<my_project>.c2nim`

## C Preprocessor Stage 

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

## c2nim stage

This runs `c2nim` on the C source files that have been pre-processed and possibly modified. `cimporter` supports a few different ways to pass arguments to `c2nim` and helps automate the process. 

The primary one is a global c2nim config file `<my_project>.c2nim` which is passed to each call to c2nim. Per-file c2nim configs can be passed in the `<my_project>.cimport.yml` as well under the `c2NimConfigs` yaml field. 


## Helpers

Example of populating a main file with imports/exports for every module: 

```zsh
PROJ=rmw
echo 'export' >> src/$PROJ.nim; ls src/$PROJ/**/*.nim  | perl -pe 's/src\/\w+\//  /; s/.nim/,/' >> src/$PROJ.nim

echo 'export' >> src/$PROJ.nim; ls src/$PROJ/**/*.nim  | perl -pe 's/src\/(\w+\/)+/  /; s/.nim/,/' >> src/$PROJ.nim
```
