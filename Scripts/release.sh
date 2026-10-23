#!/usr/bin/env bash
# Builds a public TypeWiser release: universal binary, Developer ID signature
# with the hardened runtime, notarized and stapled app inside a notarized DMG,
# and a Sparkle appcast for auto-update. See RELEASING.md for the one-time setup.
#
#   ./Scripts/release.sh 0.2.0
#
# Produces build/release/TypeWiser.dmg and build/release/appcast.xml, then
# prints the `gh release create` command that publishes them. It never
# publishes on its own.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: Scripts/release.sh <version>   e.g. 0.2.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-typewiser}"
REPO="fabianferno/typewiser"
TAG="v$VERSION"
APP="build/TypeWiser.app"
OUT="build/release"
DMG="$OUT/TypeWiser.dmg"
ENTITLEMENTS="Resources/TypeWiser.entitlements"
SPARKLE_BIN=".build/artifacts/sparkle/Sparkle/bin"
# GitHub serves the newest release's assets here, so the feed URL never changes.
FEED_URL="https://github.com/$REPO/releases/latest/download/appcast.xml"

die() { echo "error: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# ---- Preflight: fail before a 10-minute build, not after it ----------------

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "version must look like 1.2.3, got '$VERSION'"

if [[ -n "$(git status --porcelain)" && "${ALLOW_DIRTY:-0}" != "1" ]]; then
    die "working tree has uncommitted changes. Commit first, or ALLOW_DIRTY=1 for a test run."
fi

IDENTITY="$(security find-identity -v -p codesigning \
    | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')" || true
[[ -n "$IDENTITY" ]] || die "no 'Developer ID Application' certificate in the keychain. See RELEASING.md §1."

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "no notarytool credentials named '$NOTARY_PROFILE'. See RELEASING.md §2."

swift package resolve >/dev/null
PUBLIC_KEY="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" \
    || die "no Sparkle signing key in the keychain. See RELEASING.md §3."

echo "Version:  $VERSION ($TAG)"
echo "Identity: $IDENTITY"

# ---- Build ------------------------------------------------------------------

step "Building universal app"
UNIVERSAL=1 SKIP_SIGN=1 ./Scripts/bundle-app.sh

PLIST="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
pb "Set :CFBundleShortVersionString $VERSION"
# Sparkle compares CFBundleVersion, so it must only ever go up.
pb "Set :CFBundleVersion $(git rev-list --count HEAD)"
pb "Add :SUFeedURL string $FEED_URL"
pb "Add :SUPublicEDKey string $PUBLIC_KEY"
pb "Add :SUEnableAutomaticChecks bool true"

# ---- Sign, inside out -------------------------------------------------------
# Not `--deep`: it signs nested code without the options each piece needs.
# Order and flags follow Sparkle's "Distributing outside the App Store" guide.

step "Signing with $IDENTITY"
sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
FW="$APP/Contents/Frameworks/Sparkle.framework"
sign "$FW/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
sign "$FW/Versions/B/Autoupdate"
sign "$FW/Versions/B/Updater.app"
sign "$FW"
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ---- Notarize ---------------------------------------------------------------

rm -rf "$OUT" && mkdir -p "$OUT"

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json \
        > "$OUT/notary.json" || true
    if ! grep -q '"status" *: *"Accepted"' "$OUT/notary.json"; then
        cat "$OUT/notary.json" >&2
        local id; id="$(grep -o '"id" *: *"[^"]*"' "$OUT/notary.json" | head -1 | cut -d'"' -f4)"
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        die "notarization of $1 was not accepted"
    fi
}

step "Notarizing app (usually 1–5 minutes)"
ditto -c -k --keepParent "$APP" "$OUT/TypeWiser-notarize.zip"
notarize "$OUT/TypeWiser-notarize.zip"
rm "$OUT/TypeWiser-notarize.zip"
xcrun stapler staple "$APP"

step "Building DMG"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/TypeWiser.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TypeWiser $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

step "Notarizing DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

step "Gatekeeper check"
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# ---- Appcast ----------------------------------------------------------------

step "Generating appcast"
"$SPARKLE_BIN/generate_appcast" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    -o "$OUT/appcast.xml" "$OUT"
rm -f "$OUT/notary.json"

step "Done"
cat <<EOF
Built $DMG and $OUT/appcast.xml.

To publish (this is public, and existing installs will be offered the update):

  git tag $TAG && git push origin $TAG
  gh release create $TAG $DMG $OUT/appcast.xml --title "TypeWiser $VERSION" --generate-notes

The landing page links to releases/latest/download/TypeWiser.dmg, so it
picks up the new build as soon as the release is published.
EOF
