#!/bin/zsh
# Builds Deck.app and installs it into /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --scratch-path .build
BIN=.build/release/Deck
APP=Deck.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Deck"

# Website-blocker helper (installed once from Focus, then runs as a root daemon).
cp .build/release/DeckHelper "$APP/Contents/MacOS/DeckHelper"
mkdir -p "$APP/Contents/Library/LaunchDaemons" "$APP/Contents/Frameworks"
cp Vendor/helper/com.nav.deck.helper.plist "$APP/Contents/Library/LaunchDaemons/"

# Now Playing for any app (mediaremote-adapter, BSD-3).
[ -d Vendor/mediaremote-adapter/build/MediaRemoteAdapter.framework ] || Vendor/mediaremote-adapter/build.sh
ditto Vendor/mediaremote-adapter/build/MediaRemoteAdapter.framework "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
cp Vendor/mediaremote-adapter/bin/mediaremote-adapter.pl "$APP/Contents/Resources/"

# App icon: lime D on black, teal dot (the default theme; the running app follows the chosen theme).
ICONSET=$(mktemp -d)/Deck.iconset
mkdir -p "$ICONSET"
swift scripts/make-icon.swift teal "$ICONSET/base.png" 1024
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
rm "$ICONSET/base.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Deck.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.nav.deck</string>
  <key>CFBundleName</key><string>Deck</string>
  <key>CFBundleDisplayName</key><string>Deck</string>
  <key>CFBundleExecutable</key><string>Deck</string>
  <key>CFBundleIconFile</key><string>Deck</string>
  <key>LSUIElement</key><true/>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Deck shows your events and adds the ones you type in. Nothing leaves your Mac.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Deck shows your tasks and lets you check them off. Nothing leaves your Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>Deck controls Spotify and Music for you, exports Pages, Numbers and Keynote files you ask it to convert, and blocks distracting websites while you focus.</string>
  <key>NSLocationUsageDescription</key><string>Only if you turn on the weather: your area, rounded to about 1 km, is used to get a forecast.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>Only if you turn on the weather: your area, rounded to about 1 km, is used to get a forecast.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Deck's equalizer needs to hear your Mac's sound to adjust it. Audio is never recorded or saved.</string>
  <key>NSRemindersUsageDescription</key><string>Deck shows your tasks and lets you check them off. Nothing leaves your Mac.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Convert with Deck</string></dict>
      <key>NSMessage</key><string>convertFiles</string>
      <key>NSPortName</key><string>Deck</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
    </dict>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>Make Smaller with Deck</string></dict>
      <key>NSMessage</key><string>compressFiles</string>
      <key>NSPortName</key><string>Deck</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendFileTypes</key><array><string>public.item</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Sign the inside first, the app last (no --deep). The helper only trusts the exact signature of the app it sits in.
# Your Apple ID's "Apple Development" certificate when there is one: the signature then stays the same across
# rebuilds, so macOS stops re-asking for Keychain, Accessibility and helper approval. Otherwise sign for this Mac only.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
IDENTITY=${IDENTITY:--}
echo "Signing with: $IDENTITY"
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
codesign --force --sign "$IDENTITY" --identifier com.nav.deck.helper "$APP/Contents/MacOS/DeckHelper"
codesign --force --sign "$IDENTITY" "$APP"
rm -rf /Applications/Deck.app
cp -R "$APP" /Applications/Deck.app
/System/Library/CoreServices/pbs -update 2>/dev/null || true  # refresh the Services menu
echo "Installed /Applications/Deck.app"
