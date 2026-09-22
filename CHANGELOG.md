# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project aims
to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.3] - 2026-09-22

### Changed
- The Rust crate no longer builds an unused `staticlib`; the xcframework has
  shipped the dynamic framework since 0.3.0, so the artifact is unchanged.
- The Release workflow now runs the same coverage gates as CI (core dictionary
  plus `scripts/coverage.sh`) before anything is committed or tagged, and CI
  builds the Mac Catalyst target.

### Removed
- Upstream's community files (SECURITY.md, CODE_OF_CONDUCT.md, issue and PR
  templates, dependabot config), which routed reports to the upstream author.

## [0.3.2] - 2026-08-29

### Added
- **Per-slice `.dSYM`s in the xcframework**, so crash reports from consuming
  apps symbolicate the Rust core. The release profile now emits
  line-tables-only debug info, `build-ios.sh` lifts a `.dSYM` with `dsymutil`
  before stripping each framework binary, and `-create-xcframework` gets a
  `-debug-symbols` for every slice. Previously every consuming app's TestFlight
  upload warned `Upload Symbols Failed ... did not include a dSYM for the
  sudachi_swiftFFI.framework`, and Rust frames arrived unsymbolicated. The
  shipped framework binaries are byte-for-byte as stripped as before (2.2 MB,
  155 symbols); only the artifact grows, from a 4 MB to a 14 MB zip. A new
  tripwire fails the build if a slice's dSYM is missing or its UUID does not
  match the binary that ships.

## [0.3.1] - 2026-08-25

### Added
- **Mac Catalyst slice** (`ios-arm64-maccatalyst`) in the xcframework, so
  Catalyst apps can link the tokenizer. Built from the
  `aarch64-apple-ios-macabi` Rust target with the same macOS-family
  versioned-framework layout as the native macOS slice.

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
