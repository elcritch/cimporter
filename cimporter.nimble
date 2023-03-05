# Package

version       = "0.2.4"
author        = "Jaremy Creechley"
description   = "Import C projects using c2nim"
license       = "MIT"
srcDir        = "src"
bin           = @["cimporter"]
installExt = @["nim"]

# Dependencies

requires "nim >= 1.6"
requires "c2nim >= 0.9.18"
requires "cligen >= 1.5"
requires "https://github.com/elcritch/ants >= 0.2.2"
requires "msgpack4nim >= 0.4.0"
requires "patty"
requires "glob"
requires "print"
# requires "yaml"
