# zig-nestedtext

A NestedText parser written in Zig 0.7 targeting [NestedText v1.3](https://nestedtext.org/en/v1.3/).

See my [Zig NestedText Library](https://www.lewisgaul.co.uk/blog/coding/2021/04/18/zig-nestedtext/) blog post.


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
