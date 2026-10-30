#!/bin/bash
# Builds Notchy.app into ./build.
#   --install  copies it to ~/Applications and opens it
#   --dmg      also makes build/Notchy.dmg to share with teammates
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Notchy.app
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

# One binary for Apple silicon and Intel Macs.
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $ARCH-apple-macos14.0 \
    -framework AppKit -framework SwiftUI -framework IOKit -framework ServiceManagement -framework Carbon -framework CoreAudio \
    Sources/*.swift -o build/obj/Notchy-$ARCH
done
lipo -create build/obj/Notchy-arm64 build/obj/Notchy-x86_64 -output "$APP/Contents/MacOS/Notchy"

# App icon, drawn by the app itself.
"$APP/Contents/MacOS/Notchy" icon build/obj/icon.png
ICONSET=build/obj/Notchy.iconset
mkdir -p "$ICONSET"
for S in 16 32 128 256 512; do
  sips -z $S $S build/obj/icon.png --out "$ICONSET/icon_${S}x${S}.png" >/dev/null
  sips -z $((S*2)) $((S*2)) build/obj/icon.png --out "$ICONSET/icon_${S}x${S}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Notchy.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Notchy</string>
  <key>CFBundleDisplayName</key><string>Notchy</string>
  <key>CFBundleIdentifier</key><string>com.sergifont.notchy</string>
  <key>CFBundleExecutable</key><string>Notchy</string>
  <key>CFBundleIconFile</key><string>Notchy</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Ad-hoc signature. A Developer ID certificate would remove the first-open warning on other Macs.
codesign --force --sign "${NOTCHY_SIGN_ID:--}" "$APP"
echo "Built $APP"

if [[ " $* " == *" --dmg "* ]]; then
  STAGE=build/obj/dmg
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cat > "$STAGE/Read me first.txt" <<'TXT'
Notchy: a status light for Claude in your MacBook's notch.

1. Drag Notchy onto Applications.
2. Open Notchy from Applications.
   If macOS says it can't check it for malware: open System Settings,
   Privacy & Security, scroll down and click "Open Anyway".
3. Click "Connect and show me". That's it.

Hover the notch, or press Control-Option-N, to open it.
TXT
  # makehybrid + convert never mounts a disk, so it also works in sandboxes and CI.
  rm -f build/Notchy.dmg build/obj/raw.dmg
  hdiutil makehybrid -hfs -hfs-volume-name Notchy -o build/obj/raw.dmg "$STAGE" >/dev/null
  hdiutil convert build/obj/raw.dmg -format UDZO -o build/Notchy.dmg >/dev/null
  echo "Made build/Notchy.dmg"
fi

if [[ " $* " == *" --install "* ]]; then
  mkdir -p ~/Applications
  pkill -x Notchy 2>/dev/null || true
  rm -rf ~/Applications/Notchy.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Notchy.app
  echo "Installed to ~/Applications/Notchy.app"
fi
