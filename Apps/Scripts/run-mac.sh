#!/bin/sh
# Builds the Mac app and runs it from /Applications.
#
# Run it from one fixed place: macOS ties Local Network access (finding speakers, being found
# by iPhone remotes) to where the app lives as well as to who signed it, so a copy launched
# from a build folder or another checkout can be refused even though the switch in
# Privacy & Security is on.
set -eu
cd "$(dirname "$0")/../.."
xcodebuild -project Apps/Multicast.xcodeproj -scheme Multicast -configuration Debug \
  -derivedDataPath .build-xcode -allowProvisioningUpdates build | grep -E " error:|\*\* BUILD" || true
APP=.build-xcode/Build/Products/Debug/Multicast.app
[ -d "$APP" ] || { echo "Build failed: $APP is missing." >&2; exit 1; }
pkill -TERM -x Multicast 2>/dev/null && sleep 2 || true
rm -rf /Applications/Multicast.app
ditto "$APP" /Applications/Multicast.app
open /Applications/Multicast.app --args "$@"
echo "Multicast is running from /Applications/Multicast.app"
