#!/bin/sh
# Removes the Multicast output device. Run it yourself, with sudo:
#   sudo Drivers/MulticastDevice/uninstall.sh
# Restarting coreaudiod stops every sound for a moment; macOS then picks another output if
# "Multicast" was the current one.
set -eu
DEST=/Library/Audio/Plug-Ins/HAL/MulticastDevice.driver
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
if [ -d "$DEST" ]; then
  rm -rf "$DEST"
  killall coreaudiod
  echo "Removed $DEST and restarted coreaudiod."
else
  echo "Nothing to remove: $DEST is not installed."
fi
