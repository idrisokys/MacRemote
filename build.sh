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

# Uygulama ikonu (icon/icon_1024.png -> AppIcon.icns)
mkdir -p "$APP/Contents/Resources" build/AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s icon/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) icon/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf build/AppIcon.iconset
codesign --force --deep --sign - "$APP"   # ad-hoc imza

echo "Derlendi: $APP"
