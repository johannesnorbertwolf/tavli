#!/usr/bin/env bash
# Generates the TavliApp Xcode project from project.yml.
# Run once from anywhere: bash ios/TavliApp/setup.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "→ Checking xcodegen…"
if ! command -v xcodegen &>/dev/null; then
  echo "  Installing xcodegen via Homebrew…"
  if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew not found. Install it from https://brew.sh then re-run this script."
    exit 1
  fi
  brew install xcodegen
fi

echo "→ Generating TavliApp.xcodeproj…"
xcodegen generate

echo "→ Resolving Swift Package dependencies…"
xcodebuild -resolvePackageDependencies -project TavliApp.xcodeproj

echo ""
echo "Done. Next steps:"
echo "  1. open ios/TavliApp/TavliApp.xcodeproj"
echo "  2. Select an iPad simulator as the run destination"
echo "  3. Press ⌘R to build and run"
