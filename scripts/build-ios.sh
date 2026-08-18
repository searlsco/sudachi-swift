#!/usr/bin/env bash
# Build Sudachi.xcframework from the Rust workspace (Apple Silicon only).
#
# Outputs:
#   build/Sudachi.xcframework  — binary target for SPM
#   build/generated/sudachi_swiftFFI.{h,modulemap}  — C header + modulemap
#   swift/Sudachi/Sources/Sudachi/Sudachi.swift — Swift bindings
#
# Requires: rustup with the Apple targets below installed; Xcode CLT. The
# pinned sudachi.rs sources are fetched automatically if missing.

set -euo pipefail

# Ensure cargo is on PATH even when invoked from non-interactive shells.
if [ -f "$HOME/.cargo/env" ]; then
  # shellcheck source=/dev/null
  source "$HOME/.cargo/env"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
LIB_NAME="sudachi_swift"
STATIC_LIB="lib${LIB_NAME}.a"

mkdir -p "$BUILD"

# The wrapper crate has a path dependency on third_party/sudachi.rs, which is
# fetched on demand at a pinned commit rather than vendored as a submodule
# (see scripts/fetch-sudachi-rs.sh). No-op once it is present at the pin.
"$ROOT/scripts/fetch-sudachi-rs.sh"

# Apple Silicon only: arm64 device, arm64 simulator, arm64 macOS. The x86_64
# (Intel) simulator/macOS slices are intentionally dropped — it roughly halves
# the artifact, and Intel Macs can build from source if ever needed.
echo "==> Building Rust staticlibs for Apple targets (arm64)"
cd "$ROOT"
TARGETS=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  aarch64-apple-darwin
)
for target in "${TARGETS[@]}"; do
  echo "    [$target]"
  cargo build -p sudachi-swift-uniffi --release --target "$target"
done

echo "==> Generating Swift bindings"
cargo run --features cli --bin uniffi-bindgen --release -- generate \
  "$ROOT/crates/sudachi-swift-uniffi/src/${LIB_NAME}.udl" \
  --language swift \
  --out-dir "$BUILD/generated"

# UniFFI generates: <lib>.swift, <lib>FFI.h, <lib>FFI.modulemap
# The .modulemap must be named "module.modulemap" inside the framework headers dir.
SWIFT_OUT="$ROOT/swift/Sudachi/Sources/Sudachi"
mkdir -p "$SWIFT_OUT"
cp "$BUILD/generated/${LIB_NAME}.swift" "$SWIFT_OUT/Sudachi.swift"

HEADERS_DIR="$BUILD/headers"
rm -rf "$HEADERS_DIR"
mkdir -p "$HEADERS_DIR"
cp "$BUILD/generated/${LIB_NAME}FFI.h" "$HEADERS_DIR/${LIB_NAME}FFI.h"
# Rename modulemap to canonical name expected by xcframework
cp "$BUILD/generated/${LIB_NAME}FFI.modulemap" "$HEADERS_DIR/module.modulemap"

# Copy each arm64 slice into build/ and strip it in place. `strip -S -x` removes
# debug sections (-S) and local symbols (-x) while preserving the external FFI
# contract symbols the Swift bindings link against — ~6 MB off per slice. `ranlib`
# rebuilds the archive's table of contents afterwards so the linker still resolves
# the members. Done on copies so target/ stays pristine across re-runs.
echo "==> Stripping slices (strip -S -x)"
SLICES_DIR="$BUILD/slices"
rm -rf "$SLICES_DIR"
mkdir -p "$SLICES_DIR"
strip_slice() {  # <target-triple> <output-basename>
  local src="$ROOT/target/$1/release/$STATIC_LIB"
  local dst="$SLICES_DIR/$2"
  cp "$src" "$dst"
  strip -S -x "$dst"
  ranlib "$dst" >/dev/null 2>&1 || true
}
strip_slice aarch64-apple-ios      "lib${LIB_NAME}-ios.a"
strip_slice aarch64-apple-ios-sim  "lib${LIB_NAME}-sim.a"
strip_slice aarch64-apple-darwin   "lib${LIB_NAME}-macos.a"

# Tripwire: no slice may carry embedded LLVM bitcode (__LLVM segments), and
# each must expose the uniffi constructor as a native symbol. Xcode's previews
# JIT statically links its own LLVM and crashes parsing bitcode produced by
# Rust's newer LLVM, so a bitcode-laden release would break every consumer's
# SwiftUI previews. Requires `lto = false` in the release profile.
echo "==> Verifying slices are bitcode-free"
for slice in "$SLICES_DIR"/*.a; do
  if otool -l "$slice" | grep "segname __LLVM" > /dev/null; then
    echo "error: $slice contains embedded LLVM bitcode (__LLVM segment)." >&2
    echo "       Check [profile.release] in Cargo.toml: lto must stay off." >&2
    exit 1
  fi
  # No `grep -q` here: under pipefail its early exit SIGPIPEs nm and fails
  # the pipeline even on a match. Plain grep consumes the whole stream.
  if ! nm "$slice" 2>/dev/null | grep "_uniffi_${LIB_NAME}_fn_constructor_sudachidictionary_new" > /dev/null; then
    echo "error: $slice is missing the uniffi FFI symbols (or nm failed to parse it)." >&2
    exit 1
  fi
done

echo "==> Building xcframework (ios device + ios sim + macOS, all arm64)"
XCF="$BUILD/Sudachi.xcframework"
rm -rf "$XCF"
xcodebuild -create-xcframework \
  -library "$SLICES_DIR/lib${LIB_NAME}-ios.a"   -headers "$HEADERS_DIR" \
  -library "$SLICES_DIR/lib${LIB_NAME}-sim.a"   -headers "$HEADERS_DIR" \
  -library "$SLICES_DIR/lib${LIB_NAME}-macos.a" -headers "$HEADERS_DIR" \
  -output "$XCF"

echo ""
echo "==> Done."
echo "    Swift sources:    swift/Sudachi/Sources/Sudachi/Sudachi.swift"
echo "    xcframework:      build/Sudachi.xcframework"
echo ""
du -sh "$XCF"
