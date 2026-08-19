#!/usr/bin/env bash
# Coverage gates for the two hand-written layers:
#   - Rust wrapper crate     -> 100% line coverage (cargo-llvm-cov)
#   - Swift ergonomic helper  -> 100% line coverage on Sudachi+Extensions.swift
#
# Machine-generated code is excluded: the UniFFI scaffolding on the Rust side and
# the generated bindings (Sudachi.swift) on the Swift side aren't ours to cover.
#
# Requires cargo-llvm-cov (`cargo install cargo-llvm-cov` + `rustup component add
# llvm-tools-preview`). The Swift half additionally needs a built
# build/Sudachi.xcframework and the core dictionary — fetch it with
# `scripts/fetch-dictionary.sh core`, else the dictionary-gated tests are skipped
# and the extension falls short of 100%.

set -euo pipefail

if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> Rust coverage (gate: 100% lines on the wrapper crate)"
# The ignore-regex drops third_party, the uniffi-bindgen CLI, the generated
# scaffolding (*.uniffi.rs / OUT_DIR), the integration-test file itself, and
# registry deps — leaving just crates/sudachi-swift-uniffi/src/lib.rs.
cargo llvm-cov --package sudachi-swift-uniffi --tests \
  --ignore-filename-regex 'third_party|/src/bin/|\.uniffi\.rs|/tests/|/registry/|/out/' \
  --fail-under-lines 100

echo ""
echo "==> Swift coverage (gate: 100% lines on Sudachi+Extensions.swift)"
cd swift/Sudachi
# Swift Build copies the binary-target framework into Products/Debug but only
# adds an rpath for Products/Debug/PackageFrameworks, so `swift test` can't
# dlopen the dynamic framework without this bridge. Safe to create before the
# build: the symlink dangles until Swift Build copies the framework.
mkdir -p .build/out/Products/Debug/PackageFrameworks
ln -sfn ../sudachi_swiftFFI.framework \
  .build/out/Products/Debug/PackageFrameworks/sudachi_swiftFFI.framework
swift test --enable-code-coverage
COV_JSON="$(swift test --show-codecov-path)"
python3 - "$COV_JSON" <<'PY'
import json, sys

report = json.load(open(sys.argv[1]))
target = "Sudachi+Extensions.swift"
for export in report["data"]:
    for f in export["files"]:
        if f["filename"].endswith(target):
            lines = f["summary"]["lines"]
            pct = lines["percent"]
            print(f"   {target}: {lines['covered']}/{lines['count']} lines ({pct:.2f}%)")
            sys.exit(0 if pct >= 100.0 else 1)
sys.exit(f"   ERROR: {target} not found in the coverage report")
PY

echo ""
echo "==> Coverage gates passed."
