# zig-nestedtext

A NestedText parser written in Zig 0.7 targeting [NestedText v1.3](https://nestedtext.org/en/v1.3/).


## Building and Usage

This library has no external dependencies. The CLI tool depends on `Clap` (included as a git submodule under `deps/`).

Run `zig build` to build the static library `libnestedtext.a` under `zig-cache/lib/`, which can then be linked with your program.

This will also create an executable CLI program `nt-cli` under `zig-cache/bin/`. This can be used to convert NestedText to JSON, for example:  
```
$ nt-cli -f samples/basic-list.nt
["foo","bar","string with spaces"]
```

Run the tests with `zig build test`.
