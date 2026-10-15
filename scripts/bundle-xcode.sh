#!/bin/zsh
# Builds Deck.app with Xcode (app + helper + Notification Center widgets) and installs it into /Applications.
# Needs Xcode and XcodeGen. Without them, scripts/bundle.sh builds the same app minus the widgets.
# Signing: ad-hoc ("Sign to Run Locally") unless you pass a team: TEAM=ABCDE12345 scripts/bundle-xcode.sh
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=${DERIVED:-/tmp/deck-xcode}
[ -d Vendor/mediaremote-adapter/build/MediaRemoteAdapter.framework ] || Vendor/mediaremote-adapter/build.sh

xcodegen generate --quiet
# Pin the same package versions `swift build` uses.
mkdir -p Deck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Deck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

SIGN=(CODE_SIGN_IDENTITY="-")
[ -n "${TEAM:-}" ] && SIGN=(DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates)
xcodebuild -project Deck.xcodeproj -scheme Deck -configuration Release -derivedDataPath "$DERIVED" \
  -quiet -skipPackagePluginValidation -skipMacroValidation build CODE_SIGNING_REQUIRED=YES "${SIGN[@]}"

APP="$DERIVED/Build/Products/Release/Deck.app"
pkill -x Deck 2>/dev/null || true
rm -rf /Applications/Deck.app
cp -R "$APP" /Applications/Deck.app
/System/Library/CoreServices/pbs -update 2>/dev/null || true  # refresh the Services menu
# Let WidgetKit see the (new) widget extension.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Deck.app
pluginkit -a /Applications/Deck.app/Contents/PlugIns/DeckWidgets.appex 2>/dev/null || true
echo "Installed /Applications/Deck.app"
