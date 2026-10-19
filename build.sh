#!/bin/zsh
# Builds Timbre and installs it to /Applications.
#   ./build.sh            build + install + launch
#   ./build.sh --no-open  build + install only
set -euo pipefail
cd "$(dirname "$0")"

export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Timbre-cli"   # outside ~/Documents, or codesign trips on Finder metadata

xcodegen generate --quiet
# Your own bundle identifier (e.g. com.yourname.Timbre) can go in a local, untracked .bundle-id file.
BUNDLE_ID=$(cat .bundle-id 2>/dev/null || echo com.example.Timbre)
xcodebuild -project Timbre.xcodeproj -scheme Timbre -configuration Release -derivedDataPath "$DERIVED" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build \
  | grep -E "error:|warning: .*Sources|BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/Release/Timbre.app"
[[ -d "$APP" ]] || { echo "build failed"; exit 1; }

pkill -x Timbre 2>/dev/null || true
rm -rf /Applications/Timbre.app
ditto "$APP" /Applications/Timbre.app

# Sign with the local Apple Development certificate when there is one, so macOS remembers
# the audio + Spotify permissions across rebuilds (ad-hoc signatures change every build).
IDENTITY=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --entitlements Support/Timbre.entitlements /Applications/Timbre.app
# Remove the build-folder copies so Launchpad / the App Library only shows the installed app.
rm -rf "$DERIVED/Build/Products"
echo "Installed /Applications/Timbre.app (signed with ${IDENTITY:-ad-hoc})"

[[ "${1:-}" == "--no-open" ]] || open /Applications/Timbre.app
