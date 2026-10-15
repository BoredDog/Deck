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

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.nav.deck</string>
  <key>CFBundleName</key><string>Deck</string>
  <key>CFBundleDisplayName</key><string>Deck</string>
  <key>CFBundleExecutable</key><string>Deck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Deck shows your events and adds the ones you type in. Nothing leaves your Mac.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Deck shows your tasks and lets you check them off. Nothing leaves your Mac.</string>
  <key>NSAppleEventsUsageDescription</key><string>Deck controls Spotify and Music for you, and asks for your password to block distracting websites while you focus.</string>
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

codesign --force --sign - "$APP"
rm -rf /Applications/Deck.app
cp -R "$APP" /Applications/Deck.app
/System/Library/CoreServices/pbs -update 2>/dev/null || true  # refresh the Services menu
echo "Installed /Applications/Deck.app"
