# Changelog


## v0.5.0 (2024-09-29)

- Move to support Zig 0.13
- Update the `toJson()` methods in line with `std.json` changes


## v0.4.0 (2022-01-03)

- Move to support Zig 0.9, use `zig-0.8` branch for v0.8 support


## v0.3.2 (2021-07-11)

- Fix compile error in handling of strings in `fromArbitraryType()` [#21](https://github.com/LewisGaul/zig-nestedtext/pull/21)


## v0.3.1 (2021-07-10)

- Add support for converting arbitrary Zig types to NestedText via `fromArbitraryType()` (inverse of `Parser.parseTyped()`) [#20](https://github.com/LewisGaul/zig-nestedtext/pull/20)
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
