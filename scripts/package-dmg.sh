#!/bin/bash
# Build Ledger Atlas.app with Xcode and wrap it in a drag-to-Applications DMG.
#
# Runs on macOS (a GitHub Actions macOS runner or your own Mac).
#
#   ./scripts/package-dmg.sh                 # ad-hoc signed DMG (no Apple account needed)
#   VERSION=1.2.0 ./scripts/package-dmg.sh   # set the version shown in Finder / About
#
# Signing modes (picked automatically):
#   ad-hoc     default. Installs and runs on your Mac, but macOS asks you to approve it
#              the first time (System Settings > Privacy & Security > Open Anyway).
#   developer  used when SIGN_IDENTITY is set (e.g. "Developer ID Application: Name (TEAMID)")
#              and that identity is in the keychain. Adds the hardened runtime.
#              Set NOTARY_PROFILE (a `xcrun notarytool store-credentials` profile) or
#              NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER to notarize and staple too.
#
# Optional provisioning profiles (only needed for Developer ID builds that keep the
# app-group entitlement): APP_PROFILE_PATH, WIDGET_PROFILE_PATH.
#
# Output: dist/LedgerAtlas-<version>.dmg plus a .sha256 file next to it.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

VERSION=${VERSION:-0.0.0-dev}
BUILD_NUMBER=${BUILD_NUMBER:-1}
# The app's own version must be plain numbers (1.2.0); the DMG name can carry -dev tags.
MARKETING_VERSION=${MARKETING_VERSION:-${VERSION%%[-+]*}}
[[ "$MARKETING_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || MARKETING_VERSION=0.0.0
CONFIGURATION=${CONFIGURATION:-Release}
DERIVED=${DERIVED_DATA:-"$REPO_ROOT/.build/xcode"}
DIST="$REPO_ROOT/dist"
SIGN_IDENTITY=${SIGN_IDENTITY:-}
APP_NAME="Ledger Atlas"

log() { printf '\n==> %s\n' "$*"; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "package-dmg.sh needs macOS (xcodebuild, codesign, hdiutil)." >&2
  exit 2
fi

log "Xcode: $(xcodebuild -version | tr '\n' ' ')"

log "Building LedgerAtlas ($CONFIGURATION, version $VERSION build $BUILD_NUMBER)"
# Signing is done by hand below, so Xcode never needs the team's provisioning profiles.
xcodebuild build \
  -project LedgerAtlas.xcodeproj \
  -scheme LedgerAtlas \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  | tee "$DERIVED.log" | grep -E '^(\*\*|error:|warning: .*deprecated)|BUILD' || true
if ! grep -q '\*\* BUILD SUCCEEDED \*\*' "$DERIVED.log"; then
  tail -60 "$DERIVED.log" >&2
  echo "xcodebuild failed; full log: $DERIVED.log" >&2
  exit 1
fi

BUILT_APP="$DERIVED/Build/Products/$CONFIGURATION/LedgerAtlas.app"
[ -d "$BUILT_APP" ] || { echo "missing $BUILT_APP" >&2; exit 1; }

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/$APP_NAME.app"
ditto "$BUILT_APP" "$APP"

if [ -n "$SIGN_IDENTITY" ]; then
  MODE=developer
  SIGN_ARGS=(--force --timestamp --options runtime --sign "$SIGN_IDENTITY")
else
  MODE=ad-hoc
  SIGN_ARGS=(--force --sign -)
fi
log "Signing ($MODE)"

# Sign inside-out: nested code first, then the widget, then the app.
find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.bundle' \) \
  -print0 | while IFS= read -r -d '' nested; do
  codesign "${SIGN_ARGS[@]}" "$nested"
done

WIDGET="$APP/Contents/PlugIns/LedgerAtlasWidget.appex"
if [ -d "$WIDGET" ]; then
  if [ -n "${WIDGET_PROFILE_PATH:-}" ]; then
    cp "$WIDGET_PROFILE_PATH" "$WIDGET/Contents/embedded.provisionprofile"
  fi
  codesign "${SIGN_ARGS[@]}" --entitlements LedgerAtlasWidget.entitlements "$WIDGET"
fi
if [ -n "${APP_PROFILE_PATH:-}" ]; then
  cp "$APP_PROFILE_PATH" "$APP/Contents/embedded.provisionprofile"
fi
codesign "${SIGN_ARGS[@]}" --entitlements LedgerAtlas.entitlements "$APP"

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | sed 's/^/    /' || true

log "Creating DMG"
mkdir -p "$DIST"
DMG="$DIST/LedgerAtlas-$VERSION.dmg"
rm -f "$DMG"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null

if [ "$MODE" = developer ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  NOTARY_ARGS=()
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [ -n "${NOTARY_KEY_PATH:-}" ]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  fi
  if [ ${#NOTARY_ARGS[@]} -gt 0 ]; then
    log "Notarizing (this can take a few minutes)"
    xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
    xcrun stapler staple "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose "$DMG"
  else
    echo "No notary credentials set; DMG is signed but not notarized."
  fi
fi

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
log "Done: $DMG ($MODE)"
echo "dmg=$DMG" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "mode=$MODE" >> "${GITHUB_OUTPUT:-/dev/null}"
