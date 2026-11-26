#!/bin/sh
# Installs the Multicast output device. Run it yourself, with sudo, after ./build.sh:
#   sudo Drivers/MulticastDevice/install.sh
# It copies the driver into /Library/Audio/Plug-Ins/HAL and restarts coreaudiod, which stops
# every sound on the Mac for a moment. Undo with uninstall.sh.
set -eu
cd "$(dirname "$0")"
DRIVER=../../.build-driver/Build/Products/Release/MulticastDevice.driver
DEST=/Library/Audio/Plug-Ins/HAL/MulticastDevice.driver
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
[ -d "$DRIVER" ] || { echo "Build it first: Drivers/MulticastDevice/build.sh" >&2; exit 1; }
codesign --verify --strict "$DRIVER"
rm -rf "$DEST"
ditto "$DRIVER" "$DEST"
chown -R root:wheel "$DEST"
chmod -R go-w "$DEST"
killall coreaudiod
echo "Installed $DEST and restarted coreaudiod."
echo "\"Multicast\" should now be listed in System Settings > Sound > Output."
