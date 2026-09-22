#!/usr/bin/env bash
# Build the native macOS app and stage it at build/DataRover.app (the path the
# retired SDL launcher bundle used to occupy).
#
# Debug by default: this is a local developer staging step, so it reuses the
# default DerivedData (no -derivedDataPath) to stay incremental on the large
# macOS core. The destination pins arch=arm64, which project.yml already sets
# for every target (Apple silicon only). ONLY_ACTIVE_ARCH is passed as a build
# setting as well, because the project's ARCHS does not reach the SwiftPM
# package targets: in a Release build they would otherwise compile their Swift
# sources for x86_64 too, for an app that is arm64-only. Set CONFIG=Release
# for a release build.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/apple/DataRover/DataRover.xcodeproj"
CONFIG="${CONFIG:-Debug}"

xcodebuild -project "$PROJECT" -scheme DataRoverMac -configuration "$CONFIG" \
  -destination "platform=macOS,arch=arm64" ONLY_ACTIVE_ARCH=YES build

PRODUCT="$(xcodebuild -project "$PROJECT" -scheme DataRoverMac -configuration "$CONFIG" \
  -destination "platform=macOS,arch=arm64" ONLY_ACTIVE_ARCH=YES -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/DataRover.app"
rm -rf "$REPO_ROOT/build/DataRover.app"
cp -R "$PRODUCT" "$REPO_ROOT/build/DataRover.app"
# No re-sign here, deliberately. The product is already signed by the Xcode
# CodeSign step, and `cp -R` preserves that embedded signature because nothing
# modifies the bundle afterwards. Re-signing with a bare `codesign -s -` would
# strip the hardened-runtime flag (0x10002 -> 0x2) and the sandbox
# entitlements, producing a bundle that does not match the app that was tested.
printf 'staged %s\n' "$REPO_ROOT/build/DataRover.app"