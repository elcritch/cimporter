# Package

version       = "0.1.0"
author        = "Jaremy Creechley"
description   = "Import C projects using c2nim"
license       = "MIT"
srcDir        = "src"
bin           = @["cimporter"]

# Dependencies

requires "nim >= 1.6"
requires "c2nim >= 0.9.18"
requires "cligen >= 1.5"
requires "patty"
requires "toml_serialization"
requires "glob"
requires "yaml"
