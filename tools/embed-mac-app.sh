#!/usr/bin/env bash
# Builds the Mac app in Release and zips it to dist/iPad-Mouse-for-Mac.zip. The next iPad build copies that
# zip into the iPad app, which can then AirDrop it to a Mac (Macs > Send the Mac app to another Mac...).
# Run this before building the iPad app whenever the Mac code or Shared/Protocol.swift has changed.
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${TMPDIR:-/tmp}/iPadMouse-DerivedData"       # outside the iCloud-synced project folder
xcodebuild -project iPadMouse.xcodeproj -scheme iPadMouseMac -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$DD" -allowProvisioningUpdates build | grep -E "error:|BUILD"
mkdir -p dist
rm -f dist/iPad-Mouse-for-Mac.zip
ditto -c -k --keepParent "$DD/Build/Products/Release/iPad Mouse.app" dist/iPad-Mouse-for-Mac.zip
echo "Built dist/iPad-Mouse-for-Mac.zip"
