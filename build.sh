#!/bin/bash
# Builds MKVClipper.app from source using only the Swift compiler that ships
# with Xcode Command Line Tools — no .xcodeproj, no full Xcode required.
#
# Usage:
#   ./build.sh              # arm64 (Apple Silicon) build
#   ./build.sh --universal  # universal arm64 + x86_64 build
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="MKVClipper"
BUNDLE="${APP_NAME}.app"
SOURCES=(Sources/*.swift)

UNIVERSAL=false
if [[ "${1:-}" == "--universal" ]]; then
  UNIVERSAL=true
fi

echo "==> Cleaning previous build"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

build_arch() {
  local arch="$1"
  local out="$2"
  echo "==> Compiling for $arch"
  xcrun swiftc \
    -parse-as-library \
    -O \
    -target "${arch}-apple-macosx13.0" \
    -o "$out" \
    "${SOURCES[@]}"
}

if $UNIVERSAL; then
  build_arch "arm64" "/tmp/${APP_NAME}-arm64"
  build_arch "x86_64" "/tmp/${APP_NAME}-x86_64"
  echo "==> Creating universal binary"
  lipo -create -output "$BUNDLE/Contents/MacOS/$APP_NAME" \
    "/tmp/${APP_NAME}-arm64" "/tmp/${APP_NAME}-x86_64"
  rm -f "/tmp/${APP_NAME}-arm64" "/tmp/${APP_NAME}-x86_64"
else
  build_arch "$(uname -m)" "$BUNDLE/Contents/MacOS/$APP_NAME"
fi

echo "==> Assembling bundle"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"

echo "==> Ad-hoc signing (local use only — not for distribution outside GitHub)"
codesign --force --deep --sign - "$BUNDLE"

echo "==> Done: $BUNDLE"
codesign -dv "$BUNDLE" 2>&1 | sed 's/^/    /'
