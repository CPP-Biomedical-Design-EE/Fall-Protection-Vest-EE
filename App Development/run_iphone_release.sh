#!/bin/zsh
# Builds from a temporary clean copy so macOS metadata cannot break iPhone signing.

set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_TMP="$(mktemp -d /private/tmp/vest-iphone.XXXXXX)"
trap 'rm -rf "$BUILD_TMP"' EXIT

rsync -a \
  --exclude build \
  --exclude .dart_tool \
  --exclude .venv \
  --exclude Pods \
  --exclude 'ios/Flutter/ephemeral' \
  "$PROJECT_DIR/" "$BUILD_TMP/"

xattr -cr "$BUILD_TMP"
cd "$BUILD_TMP"
flutter pub get
flutter run --release -d "Phong" --no-resident
