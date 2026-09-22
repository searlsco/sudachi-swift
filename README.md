# sudachi-swift

> searlsco fork of [iasnezhkov/sudachi-swift](https://github.com/iasnezhkov/sudachi-swift): the Rust core ships as a dynamic framework (Xcode previews' JIT cannot link static archives) built with LTO off so it carries no embedded LLVM bitcode, which crashes that same JIT.

[![CI](https://github.com/searlsco/sudachi-swift/actions/workflows/ci.yml/badge.svg)](https://github.com/searlsco/sudachi-swift/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Package.swift)
[![Platforms: iOS 17+ | macOS 14+](https://img.shields.io/badge/Platforms-iOS_17%2B_|_macOS_14%2B-lightgrey)](Package.swift)

Swift bindings for [Sudachi](https://github.com/WorksApplications/sudachi.rs) —
the Japanese morphological analyzer from Works Applications — generated via
Mozilla [UniFFI](https://github.com/mozilla/uniffi-rs).

Tokenization runs **on-device**: no server round-trip, no fork of sudachi.rs.
The same way [SudachiPy](https://github.com/WorksApplications/sudachi.rs/tree/develop/python)
gives Sudachi to Python, this package gives it to Swift.

- **Targets:** iOS / iPadOS 17+, macOS 14+ (Apple Silicon; see
  [Building from source](#building-from-source) for Intel).
- **Distribution:** Swift Package Manager, with the Rust core shipped as a
  prebuilt binary `.xcframework`.

## Installation

In Xcode: **File → Add Package Dependencies…** and enter
`https://github.com/searlsco/sudachi-swift`. Or in your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/searlsco/sudachi-swift", from: "0.1.0")
]
```

The package does **not** include a dictionary — Sudachi needs one at runtime.
See [The dictionary](#the-dictionary) below; it's a one-time setup.

## Quick start

```swift
import Sudachi

// Point at a SudachiDict layout: system_core.dic with char.def / unk.def
// next to it (scripts/fetch-dictionary.sh produces exactly this).
let dict = try SudachiDictionary(
    systemDictionary: URL(fileURLWithPath: "/path/to/dictionaries/system_core.dic"))

let tokenizer = try SudachiTokenizer(dictionary: dict, mode: .c)

let morphemes = try tokenizer.tokenize(text: "毎日勉強しても上手にならない。")
for m in morphemes {
    let furigana = katakanaToHiragana(s: m.readingForm)
    print("\(m.surface) (\(furigana)) — \(m.partOfSpeech.joined(separator: "-"))")
}

// Multi-granularity: re-tokenize a substring with a different mode.
// The default mode (.c) is preserved for the next tokenize() call.
let compoundParts = try tokenizer.tokenizeWithMode(text: "国家公務員", mode: .a)
// → [国家, 公務, 員]
```

Highlight morphemes in the original string with `range(in:)` — offsets are
codepoint-based, and this helper does the index math correctly:

```swift
for m in try tokenizer.tokenize(text: text) {
    if let r = m.range(in: text) { print(text[r]) }   // == m.surface
}
```

## The dictionary

Sudachi analyzes text against a [SudachiDict](https://github.com/WorksApplications/SudachiDict)
system dictionary (`system_*.dic`) plus two small resource files
(`char.def`, `unk.def`). Three editions exist:

| Edition | Size on disk | Notes |
|---|---|---|
| `small` | ≈ 40 MB | UniDic vocabulary only |
| `core` | ≈ 207 MB | + common proper nouns — **recommended** |
| `full` | ≈ 700 MB | + the NEologd long tail of named entities |

### For development and tests

```bash
scripts/fetch-dictionary.sh                # core edition (≈70 MB download)
scripts/fetch-dictionary.sh small          # or: small / full
scripts/fetch-dictionary.sh core 20260723  # pin a specific version
```

This downloads into `dictionaries/` (gitignored) together with `char.def`,
`unk.def`, and SudachiDict's `LEGAL` / license files.

### For your app

The dictionary is loaded via `mmap`, so it must be a real file on the device.
Two common strategies:

**Bundle it with the app** — simplest. Drag the `dictionaries/` output into
your app target as a *folder reference* (e.g. named `SudachiDict`), then:

```swift
guard let url = Bundle.main.url(
    forResource: "system_core", withExtension: "dic", subdirectory: "SudachiDict")
else { fatalError("SudachiDict missing from bundle") }

let dict = try SudachiDictionary(systemDictionary: url)
```

Bundling `core` adds ≈ 207 MB to your app; `small` keeps it to ≈ 40 MB.

**Download on first launch** — keeps the initial install small. Fetch the zip,
unpack into `Application Support`, exclude it from iCloud backup, and load
from there:

```swift
let dir = try FileManager.default
    .url(for: .applicationSupportDirectory, in: .userDomainMask,
         appropriateFor: nil, create: true)
    .appendingPathComponent("SudachiDict", isDirectory: true)
// ...download + unzip system_core.dic, char.def, unk.def into `dir`...
var values = URLResourceValues(); values.isExcludedFromBackup = true
var dirURL = dir; try dirURL.setResourceValues(values)

let dict = try SudachiDictionary(
    systemDictionary: dir.appendingPathComponent("system_core.dic"))
```

> **License note:** SudachiDict is Apache-2.0 but contains third-party data
> (UniDic, NEologd). If you ship a `.dic` inside your app, keep its `LEGAL`
> attribution — `fetch-dictionary.sh` places it next to the `.dic`, and
> [`NOTICE`](NOTICE) explains the obligation.

## API surface

| Type | Purpose |
|---|---|
| `SudachiDictionary` | Loaded dictionary handle (`mmap`-backed, cheap to open). Init from a directory `URL` or explicit paths. Share one across tokenizers. |
| `SudachiTokenizer` | Tokenizer with a default split mode. Thread-safe (internally locked). |
| `Morpheme` | Full analyzed unit: `surface`, `readingForm`, `dictionaryForm`, `normalizedForm`, `partOfSpeech: [String]`, `synonymGroupIds: [UInt32]`, `isOov`, `wordId`, `begin`, `end`. |
| `MorphemeLite` | Compact unit for hot paths: `surface`, `dictionaryForm`, `readingForm`, `partOfSpeech` (pre-joined string), `posId`. |
| `SplitMode` | `.a` (short units) / `.b` (medium) / `.c` (long, named-entity-like). |
| `SudachiError` | `.DictionaryNotFound` / `.DictionaryInvalid` / `.ConfigInvalid` / `.Tokenization` — conforms to `LocalizedError`. |
| `tokenize(text:)` / `tokenizeWithMode(text:mode:)` | Full-fidelity tokenization. |
| `tokenizeLite(text:)` / `tokenizeLiteWithMode(text:mode:)` | Lean tokenization — roughly half the FFI marshalling of the full path. |
| `tokenizeMany(texts:)` / `tokenizeManyWithMode(texts:mode:)` | Batch: many strings in one FFI crossing under one lock (returns `MorphemeLite`; loop `tokenize` if you need full `Morpheme`s in bulk). |
| `katakanaToHiragana(s:)` | Reading → hiragana, for furigana display. |
| `Morpheme.range(in:)` | Maps a morpheme's offsets to `Range<String.Index>`. |

**Offsets are codepoint-based** (Unicode scalar offsets — `begin_c`/`end_c` in
sudachi.rs terms), not byte offsets. Resolve them against `text.unicodeScalars`
or use `range(in:)`. `MorphemeLite` intentionally carries no offsets — use the
full `Morpheme` when you need to map back into the source string.

> `SudachiError` case names are UpperCamelCase (`.DictionaryNotFound`) — a
> UniFFI convention for error enums that we surface as-is rather than wrap.

### Concurrency

A `SudachiTokenizer` serializes its calls with an internal lock, so sharing one
instance across tasks is safe but not parallel. For CPU parallelism, create
**one `SudachiDictionary` and one tokenizer per worker** — the dictionary is
immutable and `mmap`-shared, so extra tokenizers are nearly free.

## Performance (measured on M-series macOS)

| Op | Cold | Warm |
|---|---|---|
| `SudachiDictionary` init | 9 ms (207 MB core dict) | n/a |
| `SudachiTokenizer` init | < 1 ms | < 1 ms |
| `tokenize(text:)` short sentence | < 1 ms | < 0.1 ms |

Cold-start dictionary load stays under 10 ms because the `.dic` is `mmap`'d,
not parsed.

## Building from source

Only needed if you're contributing or need an architecture the prebuilt
`.xcframework` doesn't cover (it ships arm64-only; Intel builds fine from
source):

```bash
# 1. Rust toolchain + Apple targets
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin \
  aarch64-apple-ios-macabi

# 2. Clone (no submodules — the pinned sudachi.rs sources are fetched on demand
#    by the scripts below, into third_party/sudachi.rs)
git clone https://github.com/searlsco/sudachi-swift.git
cd sudachi-swift

# 3. Dictionary (for tests) + build
scripts/fetch-dictionary.sh
scripts/build-ios.sh          # → build/Sudachi.xcframework (~5 min cold)
```

Repository layout:

```
.
├── Cargo.toml                        Rust workspace (excludes third_party/)
├── crates/sudachi-swift-uniffi/      UniFFI wrapper crate
│   ├── src/lib.rs                    Tokenizer, Dictionary, Morpheme types
│   ├── src/sudachi_swift.udl         UniFFI interface definition
│   └── tests/                        Dictionary-gated integration tests
├── swift/Sudachi/                    SPM package (dev manifest + tests)
│   ├── Sources/Sudachi/              Generated bindings + hand-written helpers
│   └── Tests/SudachiTests/
├── scripts/                          build-ios / fetch-sudachi-rs / fetch-dictionary / lint / coverage
├── third_party/sudachi.rs.pin        Upstream commit pin (v0.6.11); the sources
│                                     are fetched into third_party/sudachi.rs/
│                                     and are not tracked here
└── docs/ARCHITECTURE.md              Design: what we add on top of sudachi.rs
```

## Tests

```bash
cd swift/Sudachi && swift test        # Swift suite (needs built xcframework)
cargo test -p sudachi-swift-uniffi    # Rust unit + integration tests
```

Dictionary-dependent tests are **skipped** (not failed) unless the core
dictionary is present at `dictionaries/system_core.dic` — fetch it with
`scripts/fetch-dictionary.sh`, or point elsewhere with `SUDACHI_DICT_DIR`.

## License

**Apache-2.0** — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

- [sudachi.rs](https://github.com/WorksApplications/sudachi.rs) (statically
  linked into the binary): Apache-2.0.
- [SudachiDict](https://github.com/WorksApplications/SudachiDict) (the runtime
  dictionary — **not** shipped by this package): Apache-2.0, containing
  third-party data whose notices must be preserved on redistribution —
  **UniDic** (BSD-3-Clause, © The UniDic Consortium 2011–2013), **NEologd**,
  and others. If you embed a `.dic` in your app, retain the attributions from
  SudachiDict's [LEGAL](https://github.com/WorksApplications/SudachiDict/blob/develop/LEGAL)
  notice. See [`NOTICE`](NOTICE).

This is an **independent, community-maintained binding** — not affiliated with
or endorsed by Works Applications.

## Project docs

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — how it fits together and
  what is intentionally custom on top of sudachi.rs.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — build, test, and API-change workflow.
- [`CHANGELOG.md`](CHANGELOG.md)
