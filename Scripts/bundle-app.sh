#!/usr/bin/env bash
# Assembles TypeWiser.app. A bundle is required: macOS TCC keys Accessibility and
# Microphone permission to a bundle ID + stable signature, which a bare
# `swift run` binary does not have.
#
#   UNIVERSAL=1  build arm64 + x86_64 (release.sh sets this)
#   SKIP_SIGN=1  leave the bundle unsigned (release.sh signs it with Developer ID)
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi

swift build -c release --product TypeWiserApp ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="build/TypeWiser.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/TypeWiserApp" "$APP/Contents/MacOS/TypeWiserApp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Referenced by CFBundleIconFile in Info.plist. Regenerate with
# Scripts/make-icon.sh when Resources/AppIcon.png changes.
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# `ditto`, not `cp -R`: the framework is built from symlinks (Versions/Current)
# and a flattened copy fails code signing.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

if [[ "${SKIP_SIGN:-0}" == "1" ]]; then
    echo "Built $APP (unsigned)"
    exit 0
fi

# macOS ties Accessibility permission to the code signature. An ad-hoc
# signature is identified by CDHash — a hash of the exact binary — so every
# rebuild would silently void the user's granted permission while System
# Settings still shows the checkbox ON. Signing with a real (self-signed)
# identity makes the designated requirement identifier+certificate, which is
# stable across rebuilds. See Scripts/create-signing-cert.sh.
IDENTITY="TypeWiser Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "WARNING: signing identity '$IDENTITY' not found — falling back to ad-hoc."
    echo "         Accessibility permission will break on every rebuild."
    echo "         Fix: ./Scripts/create-signing-cert.sh"
    codesign --force --deep --sign - "$APP"
fi

echo "Built $APP"
echo "Run: open $APP"
