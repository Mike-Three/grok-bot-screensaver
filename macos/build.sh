#!/bin/bash
# Builds "Grok Bot Screensaver.saver" (universal: Apple silicon and Intel, macOS 12 or later) and installs it for the
# current user. Needs only the Xcode Command Line Tools: xcode-select --install
# Usage: ./build.sh             build and install to ~/Library/Screen Savers
#        ./build.sh --no-install  build only (macos/build/Grok Bot Screensaver.saver)
set -euo pipefail
cd "$(dirname "$0")"
OUT="build/Grok Bot Screensaver.saver"
SRC="GrokFaces/Motion.swift GrokFaces/GrokFacesView.swift"
rm -rf build && mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"
cp GrokFaces/Info.plist "$OUT/Contents/Info.plist"
for ARCH in arm64 x86_64; do
  F="-target $ARCH-apple-macos12 -module-name GrokFaces -O -framework ScreenSaver -framework AppKit $SRC -o build/GrokFaces-$ARCH"
  # A loadable bundle (Mach-O MH_BUNDLE), what the screen saver host loads. If this toolchain refuses to link one, a
  # dynamic library also loads (the host opens the executable with dlopen).
  swiftc -emit-executable -Xlinker -bundle $F || { echo "bundle link failed, building a dynamic library instead"; swiftc -emit-library $F; }
done
lipo -create build/GrokFaces-arm64 build/GrokFaces-x86_64 -output "$OUT/Contents/MacOS/GrokFaces"
lipo -info "$OUT/Contents/MacOS/GrokFaces"
file "$OUT/Contents/MacOS/GrokFaces"
# Sprite sheets (one per shape) and the thumbnails shown in the Screen Saver picker
cp ../sprites/face-*.png "$OUT/Contents/Resources/"
cp GrokFaces/thumbnail.png GrokFaces/thumbnail@2x.png "$OUT/Contents/Resources/"
plutil -lint "$OUT/Contents/Info.plist"
# Clear extended attributes first (they break signing), then sign ad hoc
xattr -cr "$OUT"
codesign --force --deep -s - "$OUT"
codesign --verify --verbose "$OUT"
if [ "${1:-}" != "--no-install" ]; then
  mkdir -p ~/Library/Screen\ Savers
  rm -rf ~/Library/Screen\ Savers/GrokFaces.saver ~/Library/Screen\ Savers/"Grok Bot Screensaver.saver"
  cp -R "$OUT" ~/Library/Screen\ Savers/
  echo "Installed. Pick 'Grok Bot Screensaver' in System Settings > Screen Saver."
fi
