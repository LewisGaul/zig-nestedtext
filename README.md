# zig-nestedtext

[![Build badge](https://img.shields.io/github/workflow/status/LewisGaul/zig-nestedtext/Run%20tests/main)](https://github.com/LewisGaul/zig-nestedtext/actions/workflows/tests.yml?query=branch%3Amain)
[![Release badge](https://img.shields.io/github/v/release/LewisGaul/zig-nestedtext?include_prereleases&sort=semver)](https://github.com/LewisGaul/zig-nestedtext/releases/)
[![Gyro badge](https://img.shields.io/badge/gyro-nestedtext-blue)](https://astrolabe.pm/#/tag/nestedtext)


A NestedText parser written in Zig 0.8 targeting [NestedText v2.0](https://nestedtext.org/en/v2.0/).

See my [Zig NestedText Library blog post](https://www.lewisgaul.co.uk/blog/coding/2021/04/18/zig-nestedtext/).


## Building and Usage

This library has no external dependencies. The CLI tool depends on `Clap` (included as a git submodule under `deps/`).

Run `zig build` to build the static library `libnestedtext.a` under `zig-cache/lib/`, which can then be linked with your program.

This will also create an executable CLI program `nt-cli` under `zig-cache/bin/`. This can be used to convert NestedText to JSON, for example:  
```
$./zig-cache/bin/nt-cli -f samples/nested.nt | jq
{
  "A": "1",
  "B": "2\n3",
  "C": {
    "a": "4",
    "b": {
      "x": "5"
    },
    "c": "6\n7"
  },
  "D": [
    "8",
    [
      "9"
    ],
    {
      "d": "10"
    },
    "11\n12"
  ]
}
```

Run the tests with `zig build test`.
