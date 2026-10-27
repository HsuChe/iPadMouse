#!/usr/bin/env bash
# Builds the Mac app in Release and zips it into dist/ (derived data kept out of the iCloud-synced project folder).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
DD="${TMPDIR:-/tmp}/iPadMouse-DerivedData"
xcodebuild -project iPadMouse.xcodeproj -scheme iPadMouseMac -configuration Release -derivedDataPath "$DD" -allowProvisioningUpdates build | grep -E "error:|BUILD"
mkdir -p dist
ditto -c -k --keepParent "$DD/Build/Products/Release/iPad Mouse.app" "dist/iPad-Mouse-mac-$VERSION.zip"
echo "Built dist/iPad-Mouse-mac-$VERSION.zip"
