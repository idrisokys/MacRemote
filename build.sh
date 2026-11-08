#!/bin/bash
# Evrensel (Apple Silicon + Intel) KumandaMac.app üretir.
# Gerekli: Xcode Command Line Tools (xcode-select --install)
set -euo pipefail
APP="build/KumandaMac.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -target arm64-apple-macos12  KumandaMac.swift -o build/KumandaMac-arm64
swiftc -O -target x86_64-apple-macos12 KumandaMac.swift -o build/KumandaMac-x86_64
lipo -create -output "$APP/Contents/MacOS/KumandaMac" build/KumandaMac-arm64 build/KumandaMac-x86_64
rm build/KumandaMac-arm64 build/KumandaMac-x86_64

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"   # ad-hoc imza

echo "Derlendi: $APP"
