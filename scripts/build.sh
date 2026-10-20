#!/bin/bash
# Build LiteScroller.app dari Sources/LiteScroller/main.swift
# Syarat: Xcode Command Line Tools  →  xcode-select --install
# Opsi:   ARCH=universal ./scripts/build.sh   (arm64 + x86_64, dipakai di GitHub Actions)
set -e
cd "$(dirname "$0")/.."

APP="build/LiteScroller.app"
SRC="Sources/LiteScroller/main.swift"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▶ Compile..."
if [ "${ARCH:-}" = "universal" ]; then
  swiftc -O -swift-version 5 -target arm64-apple-macos13.0  "$SRC" -o build/LiteScroller-arm64
  swiftc -O -swift-version 5 -target x86_64-apple-macos13.0 "$SRC" -o build/LiteScroller-x86_64
  lipo -create build/LiteScroller-arm64 build/LiteScroller-x86_64 -output "$APP/Contents/MacOS/LiteScroller"
  rm -f build/LiteScroller-arm64 build/LiteScroller-x86_64
else
  swiftc -O -swift-version 5 "$SRC" -o "$APP/Contents/MacOS/LiteScroller"
fi

cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▶ Codesign (ad-hoc)..."
codesign --force --sign - "$APP"

echo "✅ Selesai: $APP"
echo "   Pasang:  cp -R $APP /Applications/ && open /Applications/LiteScroller.app"
