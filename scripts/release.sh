#!/usr/bin/env bash
#
# Summa release script: archive, sign, notarize, staple, and package as DMG.
#
# Prerequisites (one-time setup):
#   1. Apple Developer membership active (Developer ID certificate available).
#   2. Developer ID Application cert installed in login keychain.
#        Verify:  security find-identity -v -p codesigning
#   3. App Store Connect app-specific password stored in a notarytool profile
#      called "summa-notary":
#        xcrun notarytool store-credentials summa-notary \
#          --apple-id "you@example.com" \
#          --team-id  "XXXXXXXXXX" \
#          --password "xxxx-xxxx-xxxx-xxxx"
#   4. Xcode build settings updated (see RELEASE.md):
#        ENABLE_HARDENED_RUNTIME = YES
#        DEVELOPMENT_TEAM = <your team id>
#        CODE_SIGN_STYLE   = Automatic (or Manual + Developer ID Application)
#        CODE_SIGN_ENTITLEMENTS = Resources/Summa.entitlements
#        ENABLE_APP_SANDBOX = NO   (Developer ID path — see RELEASE.md)
#
# Usage:
#   ./scripts/release.sh              # full pipeline
#   ./scripts/release.sh --skip-notary   # build + sign only, skip notarization
#   ./scripts/release.sh --version 1.0.1 --build 4   # override version numbers
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCHEME="ScreenGlossMVP"
CONFIGURATION="Release"
PROJECT="ScreenGlossMVP.xcodeproj"
APP_NAME="Summa"                       # Display name inside the DMG
BUNDLE_ID="com.josephruocco.ScreenGlossMVP"
NOTARY_PROFILE="summa-notary"
ENTITLEMENTS="Resources/Summa.entitlements"

BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/Summa.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_DIR="$BUILD_DIR/dmg"
DMG_PATH=""  # set below after we know the version

SKIP_NOTARY=0
VERSION_OVERRIDE=""
BUILD_OVERRIDE=""

# ---------------------------------------------------------------------------
# Arg parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-notary) SKIP_NOTARY=1; shift ;;
    --version)     VERSION_OVERRIDE="$2"; shift 2 ;;
    --build)       BUILD_OVERRIDE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf "\n\033[1;34m==>\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m!!\033[0m %s\n" "$*" >&2; exit 1; }

require() { command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
require xcodebuild
require codesign
require xcrun
require hdiutil
require plutil

# Find Developer ID Application identity; require exactly one.
IDENTITY=$(security find-identity -v -p codesigning | \
  awk -F'"' '/Developer ID Application/ {print $2; exit}')
[[ -n "$IDENTITY" ]] || die "No 'Developer ID Application' certificate found in keychain. Install it before releasing."
log "Signing identity: $IDENTITY"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ---------------------------------------------------------------------------
# 1. Archive
# ---------------------------------------------------------------------------
log "Archiving $SCHEME ($CONFIGURATION)"

# Feed version/build overrides at the xcodebuild level, so the archive's
# Info.plist is stamped correctly without mutating the pbxproj.
XCBUILD_ARGS=(
  -project "$PROJECT"
  -scheme  "$SCHEME"
  -configuration "$CONFIGURATION"
  -archivePath   "$ARCHIVE_PATH"
  -destination   "generic/platform=macOS"
  archive
  CODE_SIGN_STYLE=Automatic
  ENABLE_HARDENED_RUNTIME=YES
)
[[ -n "$VERSION_OVERRIDE" ]] && XCBUILD_ARGS+=("MARKETING_VERSION=$VERSION_OVERRIDE")
[[ -n "$BUILD_OVERRIDE"   ]] && XCBUILD_ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_OVERRIDE")

xcodebuild "${XCBUILD_ARGS[@]}"

# ---------------------------------------------------------------------------
# 2. Export archive as a signed Developer ID app
# ---------------------------------------------------------------------------
log "Exporting signed .app"

EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
cat > "$EXPORT_OPTIONS_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath  "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH=$(find "$EXPORT_DIR" -maxdepth 2 -name "*.app" -print -quit)
[[ -n "$APP_PATH" && -d "$APP_PATH" ]] || die "Couldn't find exported .app in $EXPORT_DIR"
log "Exported: $APP_PATH"

# ---------------------------------------------------------------------------
# 3. Re-sign verify (belt & suspenders — -exportArchive already signs)
# ---------------------------------------------------------------------------
log "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose "$APP_PATH" || true   # will fail pre-notarization; that's expected

# Sanity-check that hardened runtime is on.
CODESIGN_INFO=$(codesign -dvv "$APP_PATH" 2>&1)
if ! echo "$CODESIGN_INFO" | grep -q 'runtime'; then
  die "Hardened runtime not enabled. Set ENABLE_HARDENED_RUNTIME=YES in the Xcode Release config."
fi

# ---------------------------------------------------------------------------
# 4. Derive version for DMG name
# ---------------------------------------------------------------------------
APP_PLIST="$APP_PATH/Contents/Info.plist"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_PLIST")
BUILD=$(plutil   -extract CFBundleVersion            raw "$APP_PLIST")
log "App version: $VERSION ($BUILD)"

DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"

# ---------------------------------------------------------------------------
# 5. Notarize the .app, then staple
# ---------------------------------------------------------------------------
if [[ $SKIP_NOTARY -eq 0 ]]; then
  log "Submitting to notary service (this can take a few minutes)"
  NOTARY_ZIP="$BUILD_DIR/Summa-for-notary.zip"
  ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"

  xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

  log "Stapling notarization ticket"
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl --assess --type execute --verbose "$APP_PATH"
else
  log "--skip-notary: leaving .app unnotarized (unsuitable for distribution)"
fi

# ---------------------------------------------------------------------------
# 6. Build DMG
# ---------------------------------------------------------------------------
log "Building DMG at $DMG_PATH"

rm -rf "$DMG_DIR"
mkdir -p "$DMG_DIR"
cp -R "$APP_PATH" "$DMG_DIR/${APP_NAME}.app"
ln -s /Applications "$DMG_DIR/Applications"

hdiutil create \
  -volname   "$APP_NAME" \
  -srcfolder "$DMG_DIR" \
  -ov -format UDZO \
  "$DMG_PATH"

# Sign the DMG itself so Gatekeeper's first-run check on the disk image
# passes without a warning.
log "Signing DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG_PATH"

if [[ $SKIP_NOTARY -eq 0 ]]; then
  log "Notarizing + stapling DMG"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

log "Done. Release artifact: $DMG_PATH"
