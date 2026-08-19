# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-08-19

### Changed
- **The xcframework now ships dynamic frameworks instead of static archives.**
  Xcode 27's previews JIT (XOJIT) cannot materialize symbols out of static
  archive members, so any `#Preview` whose compiled object references the FFI
  symbols failed with `JITError: Runtime linking failure / Symbols not found`.
  XOJIT loads dylibs fine, so each slice is now a `sudachi_swiftFFI.framework`
  wrapping the Rust cdylib. Xcode embeds and signs it in consuming apps
  automatically.
- Host `swift test` runs against the dynamic framework need a one-line bridge:
  Swift Build copies the framework into `Products/Debug` but only rpaths
  `Products/Debug/PackageFrameworks`, so consumers must symlink
  `PackageFrameworks/sudachi_swiftFFI.framework -> ../sudachi_swiftFFI.framework`
  inside their build directory before testing (see `scripts/coverage.sh`).
- `scripts/build-ios.sh` prefers the rustup-managed toolchain over a Homebrew
  `rust` that shadows it on PATH (the Homebrew rustc has no iOS targets).

## [0.1.1] - 2026-07-27

### Changed
- **sudachi.rs is no longer a git submodule.** SwiftPM initialises submodules
  recursively on every fresh package checkout, so consumers of this package were
  cloning the entire `sudachi.rs` history — hundreds of megabytes of sources
  nothing in the Swift package graph reads — before compiling a single file, and
  on cold CI that could stall a build for tens of minutes. The Swift package is
  unaffected in every other way: same products, same API, same prebuilt
  `.xcframework`. Consumers only need to update to this version.
- Building from source now fetches the pinned upstream sources on demand:
  `third_party/sudachi.rs.pin` holds the commit SHA and
  `scripts/fetch-sudachi-rs.sh` checks it out (shallow) into the gitignored
  `third_party/sudachi.rs/`. `scripts/build-ios.sh` and
  `scripts/fetch-dictionary.sh` call it automatically; `git clone
  --recurse-submodules` is no longer needed.

## [0.1.0] - 2026-07-16

First public release.

### Added
- Swift bindings to [sudachi.rs](https://github.com/WorksApplications/sudachi.rs)
  (pinned to v0.6.11) via UniFFI: `SudachiDictionary`, `SudachiTokenizer`,
  `Morpheme`, `SplitMode` (A/B/C), and a `SudachiError` taxonomy conforming to
  `LocalizedError`.
- `tokenize` / `tokenizeWithMode` — full-fidelity tokenization, including
  re-tokenizing a substring at a different granularity.
- Lean API: `MorphemeLite` (compact morpheme with `partOfSpeech` pre-joined and
  an integer `posId`) via `tokenizeLite` / `tokenizeLiteWithMode` — roughly half
  the FFI marshalling of the full path.
- Batch API: `tokenizeMany` / `tokenizeManyWithMode` — many strings in a single
  FFI crossing under one lock, for document/catalog-scale workloads.
- Codepoint-based morpheme offsets (`begin`/`end`) safe for Swift `String`
  indexing, plus the `Morpheme.range(in:)` convenience.
- `SudachiDictionary(systemDictionary:userDictionaries:)` — URL-based
  convenience initializer matching the `fetch-dictionary.sh` directory layout.
- `katakanaToHiragana` helper for furigana display.
- Distribution: SPM package with a prebuilt binary `.xcframework`
  (arm64 iOS device / simulator / macOS); iOS 17+, macOS 14+.
- Tooling: build, dictionary-fetch, lint, and coverage scripts; CI with
  rustfmt + clippy + swift-format and 100% line-coverage gates on the
  hand-written layers; manual release workflow that rewrites the binary
  target URL/checksum atomically with the tag.

[0.1.1]: https://github.com/iasnezhkov/sudachi-swift/releases/tag/v0.1.1
[0.1.0]: https://github.com/iasnezhkov/sudachi-swift/releases/tag/v0.1.0
