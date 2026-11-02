#!/bin/bash
# Pick the Xcode a CI job uses. Package.swift needs swift-tools 6.2, so Xcode 26 or newer.
# XCODE_VERSION=26.1 pins a version; otherwise the newest non-beta Xcode on the runner wins.
set -euo pipefail
want=${XCODE_VERSION:-}
if [ -n "$want" ]; then
  app="/Applications/Xcode_${want}.app"
else
  app=$(printf '%s\n' /Applications/Xcode_*.app | grep -viE 'beta|_rc' | sort -V | tail -1)
fi
[ -d "$app" ] || { echo "Xcode not found: $app"; ls -d /Applications/Xcode*.app; exit 1; }
sudo xcode-select -s "$app/Contents/Developer"
xcodebuild -version
swift --version
