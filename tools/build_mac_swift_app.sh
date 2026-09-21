#!/usr/bin/env bash
# Build the native macOS app and stage it at build/DataRover.app (the path the
# retired SDL launcher bundle used to occupy).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/apple/DataRover/DataRover.xcodeproj"
CONFIG="${CONFIG:-Debug}"

xcodebuild -project "$PROJECT" -scheme DataRoverMac -configuration "$CONFIG" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$REPO_ROOT/build/DerivedData" build

PRODUCT="$(xcodebuild -project "$PROJECT" -scheme DataRoverMac -configuration "$CONFIG" \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$REPO_ROOT/build/DerivedData" -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {print $2; exit}')/DataRover.app"
rm -rf "$REPO_ROOT/build/DataRover.app"
cp -R "$PRODUCT" "$REPO_ROOT/build/DataRover.app"
codesign --force -s - "$REPO_ROOT/build/DataRover.app"
printf 'staged %s\n' "$REPO_ROOT/build/DataRover.app"