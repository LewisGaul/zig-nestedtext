# zig-nestedtext

[![Build badge](https://img.shields.io/github/actions/workflow/status/LewisGaul/zig-nestedtext/tests.yml?branch=main)](https://github.com/LewisGaul/zig-nestedtext/actions/workflows/tests.yml?query=branch%3Amain)
[![Release badge](https://img.shields.io/github/v/release/LewisGaul/zig-nestedtext?include_prereleases&sort=semver)](https://github.com/LewisGaul/zig-nestedtext/releases/)


A NestedText parser written in Zig 0.13 targeting [NestedText v2.0](https://nestedtext.org/en/v2.0/) (note [Deviations From Specification](#deviations-from-specification) below).

See my [Zig NestedText Library blog post](https://www.lewisgaul.co.uk/blog/coding/2021/04/18/zig-nestedtext/).


## Usage

There are a few options for making use of this project:
 - Download from the [releases page](https://github.com/LewisGaul/zig-nestedtext/releases/)
 - Include as a dependency via git submodules
 - Clone and build manually, using a static copy of the built artefacts
 - Use the gyro package manager (untested)
 - Use the zigmod package manager (untested)

The Zig library has no external dependencies.

The CLI tool depends only on `Clap` for command line arg parsing (included as a git submodule under `deps/`).

Run `zig build` to build the static library `libnestedtext.a` under `zig-out/lib/`, which can then be linked with your program.


### CLI Tool

An executable CLI program `nt-cli` is included for exposing the core functionality of the project. When building with `zig build` this can be found under `zig-out/bin/`.

This tool can be used to convert between NestedText and JSON, for example:  
```
$./zig-out/bin/nt-cli -f samples/employees.nt
debug(cli):     +0 Starting up
debug(cli):     +0 Parsed args
debug(cli):     +1 Finished reading input
debug(cli):     +1 Parsed NestedText
debug(cli):     +1 Converted to JSON
debug(cli):     +1 Stringified JSON
{"president":{"name":"Katheryn McDaniel","address":"138 Almond Street\nTopeka, Kansas 20697","phone":{"cell":"1-210-555-5297","home":"1-210-555-8470"},"email":"KateMcD@aol.com","additional-roles":["board member"]},"vice-president":{"name":"Margaret Hodge","address":"2586 Marigold Lane\nTopeka, Kansas 20682","phone":"1-470-555-0398","email":"margaret.hodge@ku.edu","additional-roles":["new membership task force","accounting task force"]},"treasurer":[{"name":"Fumiko Purvis","address":"3636 Buffalo Ave\nTopeka, Kansas 20692","phone":"1-268-555-0280","email":"fumiko.purvis@hotmail.com","additional-roles":["accounting task force"]},{"name":"Merrill Eldridge","phone":"1-268-555-3602","email":"merrill.eldridge@yahoo.com"}]}
debug(cli):     +1 Exiting with: 0
```

Yes, that took around 1 millisecond ;)

And back to NestedText:
```
$./zig-out/bin/nt-cli -f samples/employees.nt | ./zig-out/bin/nt-cli -F json -O nt
president:
  name: Katheryn McDaniel
  address:
    > 138 Almond Street
    > Topeka, Kansas 20697
  phone:
    cell: 1-210-555-5297
    home: 1-210-555-8470
  email: KateMcD@aol.com
  additional-roles:
    - board member
vice-president:
  name: Margaret Hodge
  address:
    > 2586 Marigold Lane
    > Topeka, Kansas 20682
  phone: 1-470-555-0398
  email: margaret.hodge@ku.edu
  additional-roles:
    - new membership task force
    - accounting task force
treasurer:
  -
    name: Fumiko Purvis
    address:
      > 3636 Buffalo Ave
      > Topeka, Kansas 20692
    phone: 1-268-555-0280
    email: fumiko.purvis@hotmail.com
    additional-roles:
      - accounting task force
  -
    name: Merrill Eldridge
    phone: 1-268-555-3602
    email: merrill.eldridge@yahoo.com
```


## Deviations From Specification

The amount of deviation from the official NestedText spec is kept to a minimum, however there is one minor case to be aware of (as reflected in the [fork of the official testsuite](https://github.com/KenKundert/nestedtext_tests/compare/master...LewisGaul:dev) being used to test this project). Where possible these issues are resolved upstream.

Note that this project implements a *strict subset* of the official spec, to avoid compatibility issues.


### Empty Values in Flow-style

Empty values are officially allowed in flow-style NestedText, e.g. `{:}` -> `{"":""}`, however this is *disallowed* by this project.

The design choices behind handling for empty values in flow-style are explained in detail at <https://zigforum.org/t/zig-nestedtext-release-0-1-0/383/5>.

This has been discussed with the NestedText creators in GitHub issues ([here](https://github.com/KenKundert/nestedtext/issues/23#issuecomment-831195971) and [here](https://github.com/KenKundert/nestedtext/issues/25#issuecomment-860185422)) and over email, and discussions are ongoing.

To summarise the rationale behind this deviation:
 - Flow-style is only provided as a shorthand (and a way to represent empty lists/objects), so can be as strict as desired without preventing representation of arbitrary data.
 - The spec says that `[,]` -> `[""]`, `[,,]` -> `["", ""]` etc., where the trailing comma is required to indicate an empty value at the end of the list.
 - There is no other use for trailing commas in NestedText since flow-style cannot span multiple lines.
 - At first glance, `[,]` looks more like a list of *two* empty values than one.
 - The language states one of its primary goals as being "*easily understood and used by both programmers and non-programmers*".
 - On balance, the author of this project has decided that the potential confusion from the use of trailing commas to indicate empty values is not worth the convenience it brings to more experienced users.

If you have any thoughts about this either way, please consider posting a comment to <https://github.com/LewisGaul/zig-nestedtext/issues/17>.

### Line Endings Preserved

When a string contains newlines, those newlines are preserved from the NestedText content itself.
Without this, it is impossible to represent carriage return and newline characters in a platform-independent, implementation-independent way.

This has been discussed at <https://github.com/KenKundert/nestedtext_tests/issues/5>.


## Changelog

See [CHANGELOG.md](CHANGELOG.md).


## Development

Build with `zig build` - the library will be under `zig-out/lib/` and the CLI tool will be under `zig-out/bin/`.

Run the tests with `zig build test`.

Please feel free to propose changes via a PR, but please make sure all tests are passing, and also make sure to run `zig fmt .` (there are GitHub actions checks for both of these).
