# Changelog


## v0.3.1 (2021-07-10)

- Add support for converting arbitrary Zig types to NestedText via `fromArbitraryType()` (inverse of `Parser.parseTyped()`)
- Fix bug in `parseTypedFree()` when passing in a `Void` type
- Fix bug parsing into enum types with `parseTyped()`


## v0.3.0 (2021-06-24)

- Add initial support for parsing into a comptime type [#15](https://github.com/LewisGaul/zig-nestedtext/pull/15)


## v0.2.0 (2021-06-06)

- Implement [NestedText spec v2.0](https://nestedtext.org/en/v2.0/) (except no support for empty values in flow-style, see [Deviations From Specification](https://github.com/LewisGaul/zig-nestedtext/blob/v0.2.0/README.md#deviations-from-specification))
- Move to Zig 0.8
- Fix various dumping bugs


## v0.1.0 (2021-04-20)

Initial release, implementing a subset of [NestedText spec v1.3](https://nestedtext.org/en/v1.3/) in Zig 0.7.
