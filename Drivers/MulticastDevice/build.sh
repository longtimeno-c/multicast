#!/bin/sh
# Builds the Multicast output device driver (no admin rights needed).
# Output: .build-driver/Build/Products/Release/MulticastDevice.driver at the repository root.
set -eu
cd "$(dirname "$0")"
xcodebuild -project MulticastDevice.xcodeproj -scheme MulticastDevice -configuration Release \
  -derivedDataPath ../../.build-driver -allowProvisioningUpdates build | grep -E " error:|\*\* BUILD" || true
DRIVER=../../.build-driver/Build/Products/Release/MulticastDevice.driver
[ -d "$DRIVER" ] || { echo "Build failed: $DRIVER is missing." >&2; exit 1; }
codesign --verify --strict "$DRIVER"
echo "Built $(cd "$DRIVER" && pwd)"
