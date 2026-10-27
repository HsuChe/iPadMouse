#!/usr/bin/env bash
# Publishes dist/iPad-Mouse-mac-<version>.zip as a GitHub release. Run after tools/build-release.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-0.1.0}"
gh release create "v$VERSION" "dist/iPad-Mouse-mac-$VERSION.zip" --repo HsuChe/iPadMouse \
  --title "iPad Mouse $VERSION" --notes-file dist/RELEASE_NOTES.md
echo "Published: https://github.com/HsuChe/iPadMouse/releases/tag/v$VERSION"
