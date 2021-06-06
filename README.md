# zig-nestedtext

[![Build badge](https://img.shields.io/github/workflow/status/LewisGaul/zig-nestedtext/Run%20tests/main)](https://github.com/LewisGaul/zig-nestedtext/actions/workflows/tests.yml?query=branch%3Amain)
[![Release badge](https://img.shields.io/github/v/release/LewisGaul/zig-nestedtext?include_prereleases&sort=semver)](https://github.com/LewisGaul/zig-nestedtext/releases/)
[![Gyro badge](https://img.shields.io/badge/gyro-nestedtext-blue)](https://astrolabe.pm/#/tag/nestedtext)


A NestedText parser written in Zig 0.8 targeting [NestedText v2.0](https://nestedtext.org/en/v2.0/).

See my [Zig NestedText Library blog post](https://www.lewisgaul.co.uk/blog/coding/2021/04/18/zig-nestedtext/).


## Usage

There are a few options for making use of this project:
 - Download from the [releases page](https://github.com/LewisGaul/zig-nestedtext/releases/)
 - Include as a dependency via git submodules
 - Clone and build manually, using a static copy of the built artefacts
 - Use the gyro package manager (untested)

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


## Development

Build with `zig build` - the library will be under `zig-out/lib/` and the CLI tool will be under `zig-out/bin/`.

Run the tests with `zig build test`.

Please feel free to propose changes via a PR, but please make sure all tests are passing, and also make sure to run `zig fmt .` (there are GitHub actions checks for both of these).
