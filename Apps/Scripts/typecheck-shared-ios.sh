#!/bin/sh
# Type-checks Apps/Shared for iOS, so the design system and model the iOS remote will reuse
# never pick up a Mac-only API unnoticed. Run from anywhere; exits non-zero on any error.
set -eu
here="$(cd "$(dirname "$0")/.." && pwd)"
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
xcrun --sdk iphonesimulator swiftc -typecheck \
    -sdk "$sdk" \
    -target arm64-apple-ios17.0-simulator \
    -swift-version 5 \
    "$here"/Shared/*/*.swift
echo "Apps/Shared type-checks for iOS."
