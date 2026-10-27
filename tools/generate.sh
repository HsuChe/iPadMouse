#!/usr/bin/env bash
# Generates iPadMouse.xcodeproj from project.yml using XcodeGen (downloaded on first run).
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="tools/xcodegen/bin/xcodegen"
if [ ! -x "$BIN" ]; then
  echo "Downloading XcodeGen…"
  rm -rf tools/xcodegen tools/.xcodegen-tmp
  mkdir -p tools/.xcodegen-tmp
  curl -fsSL -o tools/.xcodegen-tmp/xcodegen.zip \
    https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip
  unzip -q tools/.xcodegen-tmp/xcodegen.zip -d tools/.xcodegen-tmp
  mv tools/.xcodegen-tmp/xcodegen tools/xcodegen
  rm -rf tools/.xcodegen-tmp
fi
"$BIN" generate --spec project.yml
echo "Open iPadMouse.xcodeproj in Xcode."
