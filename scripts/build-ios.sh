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

# Prefer the rustup-managed toolchain: a Homebrew `rust` install can shadow it
# on PATH, and that rustc has no iOS targets.
if command -v rustup >/dev/null 2>&1; then
  PATH="$(dirname "$(rustup which rustc)"):$PATH"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
LIB_NAME="sudachi_swift"

mkdir -p "$BUILD"

# The wrapper crate has a path dependency on third_party/sudachi.rs, which is
# fetched on demand at a pinned commit rather than vendored as a submodule
# (see scripts/fetch-sudachi-rs.sh). No-op once it is present at the pin.
"$ROOT/scripts/fetch-sudachi-rs.sh"

# Apple Silicon only: arm64 device, arm64 simulator, arm64 macOS, arm64 Mac
# Catalyst. The x86_64 (Intel) slices are intentionally dropped — it roughly
# halves the artifact, and Intel Macs can build from source if ever needed.
echo "==> Building Rust dylibs for Apple targets (arm64)"
cd "$ROOT"
TARGETS=(
  aarch64-apple-ios
  aarch64-apple-ios-sim
  aarch64-apple-darwin
  aarch64-apple-ios-macabi
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

# Package each arm64 dylib as a proper framework. Dynamic (not static) is
# load-bearing: Xcode 27's previews JIT (XOJIT) cannot materialize symbols out
# of static archive members, so any preview whose JIT'd object references the
# FFI symbols dies with "Symbols not found". XOJIT loads dylibs fine.
#
# The framework (and its module) is named after the FFI module the generated
# Swift bindings import, so clang's framework-module lookup resolves it.
FW_NAME="${LIB_NAME}FFI"
FRAMEWORKS_DIR="$BUILD/frameworks"
rm -rf "$FRAMEWORKS_DIR"

write_framework_modulemap() {  # <modules-dir>
  cat > "$1/module.modulemap" <<EOF
framework module ${FW_NAME} {
    umbrella header "${FW_NAME}.h"
    export *
    use "Darwin"
    use "_Builtin_stdbool"
    use "_Builtin_stdint"
}
EOF
}

write_info_plist() {  # <plist-path> <platform>
  local min_key min_value platform="$2"
  case "$platform" in
    # Mac Catalyst frameworks are macOS-family bundles.
    macosx | maccatalyst) min_key="LSMinimumSystemVersion"; min_value="14.0" ;;
    *)                    min_key="MinimumOSVersion";       min_value="17.0" ;;
  esac
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>co.searlsco.sudachi-swift.ffi</string>
    <key>CFBundleExecutable</key><string>${FW_NAME}</string>
    <key>CFBundleName</key><string>${FW_NAME}</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleSupportedPlatforms</key><array><string>$(supported_platform_name "$platform")</string></array>
    <key>${min_key}</key><string>${min_value}</string>
</dict>
</plist>
EOF
}

supported_platform_name() {
  case "$1" in
    iphoneos)             echo "iPhoneOS" ;;
    iphonesimulator)      echo "iPhoneSimulator" ;;
    macosx | maccatalyst) echo "MacOSX" ;;
  esac
}

build_framework() {  # <target-triple> <slice-dir-name> <platform>
  local triple="$1" slice="$2" platform="$3"
  local src="$ROOT/target/$triple/release/lib${LIB_NAME}.dylib"
  local fw="$FRAMEWORKS_DIR/$slice/${FW_NAME}.framework"
  local binary headers modules plist
  if [ "$platform" = "macosx" ] || [ "$platform" = "maccatalyst" ]; then
    # macOS-family frameworks (Catalyst included) are versioned bundles;
    # flat layouts fail codesign.
    mkdir -p "$fw/Versions/A/Headers" "$fw/Versions/A/Modules" "$fw/Versions/A/Resources"
    binary="$fw/Versions/A/${FW_NAME}"
    headers="$fw/Versions/A/Headers"
    modules="$fw/Versions/A/Modules"
    plist="$fw/Versions/A/Resources/Info.plist"
    ln -s A "$fw/Versions/Current"
    ln -s "Versions/Current/${FW_NAME}" "$fw/${FW_NAME}"
    ln -s Versions/Current/Headers "$fw/Headers"
    ln -s Versions/Current/Modules "$fw/Modules"
    ln -s Versions/Current/Resources "$fw/Resources"
    install_name_tool_id="@rpath/${FW_NAME}.framework/Versions/A/${FW_NAME}"
  else
    mkdir -p "$fw/Headers" "$fw/Modules"
    binary="$fw/${FW_NAME}"
    headers="$fw/Headers"
    modules="$fw/Modules"
    plist="$fw/Info.plist"
    install_name_tool_id="@rpath/${FW_NAME}.framework/${FW_NAME}"
  fi
  cp "$src" "$binary"
  chmod +w "$binary"
  install_name_tool -id "$install_name_tool_id" "$binary"
  strip -S -x "$binary"
  cp "$HEADERS_DIR/${LIB_NAME}FFI.h" "$headers/${FW_NAME}.h"
  write_framework_modulemap "$modules"
  write_info_plist "$plist" "$platform"
  codesign --force --sign - "$fw" >/dev/null 2>&1
}

echo "==> Assembling dynamic frameworks"
build_framework aarch64-apple-ios        ios      iphoneos
build_framework aarch64-apple-ios-sim    sim      iphonesimulator
build_framework aarch64-apple-darwin     macos    macosx
build_framework aarch64-apple-ios-macabi catalyst maccatalyst

# Tripwire: no binary may carry embedded LLVM bitcode (__LLVM segments), each
# must expose the uniffi constructor as a native symbol, and each must be a
# dylib (never a static archive — XOJIT can't materialize archive members).
echo "==> Verifying framework binaries (dylib, bitcode-free, FFI symbols)"
for triple_slice in "ios" "sim" "macos" "catalyst"; do
  fw="$FRAMEWORKS_DIR/$triple_slice/${FW_NAME}.framework"
  bin="$fw/${FW_NAME}"
  if ! file "$(readlink -f "$bin")" | grep "dynamically linked shared library" > /dev/null; then
    echo "error: $bin is not a dylib." >&2
    exit 1
  fi
  if otool -l "$bin" | grep "segname __LLVM" > /dev/null; then
    echo "error: $bin contains embedded LLVM bitcode (__LLVM segment)." >&2
    echo "       Check [profile.release] in Cargo.toml: lto must stay off." >&2
    exit 1
  fi
  # No `grep -q` here: under pipefail its early exit SIGPIPEs nm and fails
  # the pipeline even on a match. Plain grep consumes the whole stream.
  if ! nm -g "$bin" 2>/dev/null | grep "_uniffi_${LIB_NAME}_fn_constructor_sudachidictionary_new" > /dev/null; then
    echo "error: $bin is missing the uniffi FFI symbols (or nm failed to parse it)." >&2
    exit 1
  fi
done

echo "==> Building xcframework (ios device + ios sim + macOS + Mac Catalyst, all arm64)"
XCF="$BUILD/Sudachi.xcframework"
rm -rf "$XCF"
xcodebuild -create-xcframework \
  -framework "$FRAMEWORKS_DIR/ios/${FW_NAME}.framework" \
  -framework "$FRAMEWORKS_DIR/sim/${FW_NAME}.framework" \
  -framework "$FRAMEWORKS_DIR/macos/${FW_NAME}.framework" \
  -framework "$FRAMEWORKS_DIR/catalyst/${FW_NAME}.framework" \
  -output "$XCF"

echo ""
echo "==> Done."
echo "    Swift sources:    swift/Sudachi/Sources/Sudachi/Sudachi.swift"
echo "    xcframework:      build/Sudachi.xcframework"
echo ""
du -sh "$XCF"
