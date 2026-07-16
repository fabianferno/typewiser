#!/usr/bin/env bash
# Assembles TypeWiser.app. A bundle is required: macOS TCC keys Accessibility and
# Microphone permission to a bundle ID + stable signature, which a bare
# `swift run` binary does not have.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product TypeWiserApp

APP="build/TypeWiser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/TypeWiserApp "$APP/Contents/MacOS/TypeWiserApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature keeps the TCC grant stable across rebuilds.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
echo "Run: open $APP"
