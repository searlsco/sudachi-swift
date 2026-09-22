# Contributing to sudachi-swift

Thanks for your interest in improving this project. It is a Swift binding to
[sudachi.rs](https://github.com/WorksApplications/sudachi.rs) generated via
[UniFFI](https://github.com/mozilla/uniffi-rs), so contributions usually touch
one of three layers:

1. **Rust wrapper** — `crates/sudachi-swift-uniffi/src/lib.rs` and the UniFFI
   interface `crates/sudachi-swift-uniffi/src/sudachi_swift.udl`.
2. **Generated Swift bindings** — `swift/Sudachi/Sources/Sudachi/Sudachi.swift`
   (auto-generated; **do not edit by hand** — regenerate via the build script).
3. **Swift tests** — `swift/Sudachi/Tests/SudachiTests/`.

## Prerequisites

- macOS with Xcode command line tools (`xcode-select --install`)
- Rust toolchain with the Apple targets:

  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin \
    aarch64-apple-ios-macabi
  ```

  The xcframework is **Apple Silicon only** (arm64 device, arm64 simulator,
  arm64 macOS, arm64 Mac Catalyst) — the x86_64/Intel slices are intentionally dropped to roughly
  halve the artifact.

## Local setup

```bash
git clone https://github.com/searlsco/sudachi-swift.git
cd sudachi-swift
scripts/fetch-sudachi-rs.sh                 # pinned sudachi.rs sources (shallow)
scripts/fetch-dictionary.sh core            # ~70 MB download, needed by tests
scripts/build-ios.sh                        # builds build/Sudachi.xcframework
```

## Running tests

Tests link against the **locally built** xcframework (via
`swift/Sudachi/Package.swift`). Dictionary-dependent tests are **skipped**
without the **core** dictionary at `dictionaries/system_core.dic`, so fetch it
first for a meaningful run (CI runs with it, and the coverage gates need it):

```bash
scripts/fetch-dictionary.sh core   # if not already done
scripts/build-ios.sh               # rebuild after any Rust/UDL change
cd swift/Sudachi && swift test
```

If your dictionary lives elsewhere, point the tests at it with
`SUDACHI_DICT_DIR=/path/to/dir swift test`.

The Rust side has its own tests too — pure unit tests plus a dictionary-gated
integration suite (`crates/sudachi-swift-uniffi/tests/`):

```bash
cargo test -p sudachi-swift-uniffi     # runs both; integration tests skip w/o dict
```

## Linting & coverage

Both are enforced in CI; run them locally before opening a PR.

```bash
# Rust: format + lints (warnings are errors, same as CI)
cargo fmt --all --check
cargo clippy -p sudachi-swift-uniffi --all-targets -- -D warnings

# Swift: swift-format (config in .swift-format; generated Sudachi.swift excluded)
scripts/lint-swift.sh          # check
scripts/lint-swift.sh --fix    # reformat in place

# Coverage gates: Rust 100% lines on the wrapper crate + Swift 100% lines on
# the hand-written Sudachi+Extensions.swift. Needs cargo-llvm-cov and the dict.
cargo install cargo-llvm-cov   # one-time
rustup component add llvm-tools-preview
scripts/coverage.sh
```

New code is expected to keep both crates at 100% line coverage. Where a branch
is genuinely unreachable (e.g. mapping an error from a compile-time-constant that
never fails), extract it into a helper whose error path a test can drive, rather
than leaving it uncovered — see how `SudachiDictionary::config_builder` /
`validate_paths` / `apply_user_dicts` are split out of `new`.

## Changing the API

When you add or change a function/type exposed to Swift:

1. Edit the Rust in `crates/sudachi-swift-uniffi/src/lib.rs`.
2. Update the matching declaration in `crates/sudachi-swift-uniffi/src/sudachi_swift.udl`.
3. Run `scripts/build-ios.sh` — this regenerates `Sudachi.swift` and the
   xcframework. Commit the regenerated `Sudachi.swift`.
4. Add/adjust tests under `swift/Sudachi/Tests/`.
5. Update `README.md` (API table) and `docs/ARCHITECTURE.md` if the surface or
   design rationale changed.

Keep additions **additive and thin** — the goal is to stay a small wrapper over
sudachi.rs, not to fork it. See `docs/ARCHITECTURE.md` for what is intentionally
custom and why.

## Commit / PR guidelines

- Keep PRs focused; describe the *why*, not just the *what*.
- Do not commit build artifacts (`build/`, `target/`), downloaded dictionaries
  (`dictionaries/`), or editor scratch — these are gitignored.
- CI runs rustfmt + clippy, swift-format, and the Rust + Swift test suites under
  coverage (with 100%-line gates) against a freshly built xcframework and the
  core dictionary. Make sure it all passes locally first.
- By contributing you agree that your contributions are licensed under the
  project's Apache-2.0 license.

## Upstream awareness

This binding pins sudachi.rs to a specific upstream commit in
`third_party/sudachi.rs.pin`; `scripts/fetch-sudachi-rs.sh` checks that commit
out (shallow) into `third_party/sudachi.rs/`, which is gitignored. It is
deliberately **not** a git submodule: SwiftPM initialises submodules recursively
on every package checkout, so a submodule here would make every consumer of the
Swift package clone the whole sudachi.rs history before compiling anything.

To bump upstream, edit the SHA in the pin file, re-run the script, and commit
the resulting `Cargo.lock` change. Bumping can require code changes in the
wrapper (sudachi.rs 0.7 in particular is a format/loader rewrite). If your
change depends on newer sudachi.rs behavior, note that in the PR.
