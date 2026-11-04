#!/usr/bin/env bash
# Builds, signs, packages and notarizes Top NotchSH as a drag-to-Applications DMG.
#
#   ./scripts/release.sh
#       Signs with the best identity in your keychain: "Developer ID
#       Application" (for distribution), else "Apple Development" (runs on
#       this Mac), else ad-hoc. With a Developer ID it also notarizes and
#       staples, so the DMG opens on any Mac without warnings.
#
#   ./scripts/release.sh --no-notarize
#       Skips notarization, for a quick test build.
#
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"   pick an identity
#   NOTARY_PROFILE=other-profile                              use another profile
#
# Notarization uses the keychain profile "top-notchsh". Create it once with:
#   xcrun notarytool store-credentials top-notchsh --apple-id you@example.com --team-id TEAMID
#
# Output: dist/TopNotchSH-<version>.dmg
set -euo pipefail

NOTARIZE=1
for argument in "$@"; do
  case "$argument" in
    --no-notarize) NOTARIZE=0 ;;
    -h|--help) sed -n '2,/^# Output/s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) printf 'Unknown option: %s (see --help)\n' "$argument" >&2; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Top NotchSH"
VOLUME_NAME="Top NotchSH"
BUILD_DIR="$ROOT/build/release"
WORK_DIR="$BUILD_DIR/package"
DIST_DIR="$ROOT/dist"
ENTITLEMENTS="$ROOT/TopNotchSH/Resources/TopNotchSH.entitlements"
VERSION="$(sed -n 's/^ *CFBundleShortVersionString: *"\(.*\)"/\1/p' "$ROOT/project.yml")"
DMG="$DIST_DIR/TopNotchSH-$VERSION.dmg"

step() { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[33m! %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

if [[ "$(xcode-select -p 2>/dev/null)" == "/Library/Developer/CommandLineTools" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
command -v xcodegen >/dev/null || die "xcodegen not found (brew install xcodegen)"

# --- Signing identity ---------------------------------------------------------

identity_matching() {
  security find-identity -v -p codesigning | sed -n "s/.*\"\($1[^\"]*\)\".*/\1/p" | head -1
}

IDENTITY="${SIGN_IDENTITY:-}"
[[ -n "$IDENTITY" ]] || IDENTITY="$(identity_matching "Developer ID Application")"
[[ -n "$IDENTITY" ]] || IDENTITY="$(identity_matching "Apple Development")"
[[ -n "$IDENTITY" ]] || IDENTITY="-"

case "$IDENTITY" in
  "Developer ID Application"*) DISTRIBUTABLE=1 ;;
  *) DISTRIBUTABLE=0 ;;
esac

# Notarize by default with a Developer ID. An explicitly named profile must
# work; the default one is skipped with a warning if it hasn't been set up.
PROFILE="${NOTARY_PROFILE:-top-notchsh}"
if [[ $NOTARIZE -eq 1 && $DISTRIBUTABLE -eq 0 ]]; then
  [[ -n "${NOTARY_PROFILE:-}" ]] && die "Notarization needs a \"Developer ID Application\" certificate; found only: $IDENTITY"
  NOTARIZE=0
fi
if [[ $NOTARIZE -eq 1 ]] && ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  [[ -n "${NOTARY_PROFILE:-}" ]] && die "Notary profile \"$PROFILE\" isn't usable (see xcrun notarytool store-credentials)"
  warn "Notary profile \"$PROFILE\" not found; building without notarization"
  NOTARIZE=0
fi

# --- Build --------------------------------------------------------------------

step "Building $APP_NAME $VERSION (Apple silicon)"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" --quiet
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
BUILD_LOG="$BUILD_DIR/xcodebuild.log"
xcodebuild \
  -project "$ROOT/TopNotchSH.xcodeproj" \
  -scheme TopNotchSH \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  ARCHS=arm64 \
  -derivedDataPath "$BUILD_DIR/derived" \
  -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  build >"$BUILD_LOG" 2>&1 || { tail -40 "$BUILD_LOG"; die "Build failed (full log: ${BUILD_LOG#"$ROOT"/})"; }

BUILT_APP="$BUILD_DIR/derived/Build/Products/Release/$APP_NAME.app"
[[ -d "$BUILT_APP" ]] || die "Build product not found at $BUILT_APP"

# --- Sign ---------------------------------------------------------------------

step "Signing with: $([[ "$IDENTITY" == "-" ]] && echo "ad-hoc" || echo "$IDENTITY")"
STAGING="$WORK_DIR/staging"
rm -rf "$WORK_DIR"
mkdir -p "$STAGING"
ditto "$BUILT_APP" "$STAGING/$APP_NAME.app"

SIGN_ARGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
[[ $DISTRIBUTABLE -eq 1 ]] && SIGN_ARGS+=(--timestamp)
codesign "${SIGN_ARGS[@]}" "$STAGING/$APP_NAME.app"
codesign --verify --strict --deep --verbose=1 "$STAGING/$APP_NAME.app"

# --- Disk image ---------------------------------------------------------------

step "Creating disk image"
swift "$ROOT/scripts/dmg-background.swift" "$WORK_DIR"
mkdir -p "$STAGING/.background"
tiffutil -cathidpicheck "$WORK_DIR/background.png" "$WORK_DIR/background@2x.png" -out "$STAGING/.background/background.tiff" >/dev/null 2>&1
ln -s /Applications "$STAGING/Applications"
cp "$STAGING/$APP_NAME.app/Contents/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"

RW_DMG="$WORK_DIR/rw.dmg"
hdiutil create -quiet -srcfolder "$STAGING" -volname "$VOLUME_NAME" -fs HFS+ -format UDRW -ov "$RW_DMG"

# Finder only lays out volumes under /Volumes. The first run asks to let your
# terminal control Finder; without that the DMG still works, just unstyled.
VOLUME_PATH="/Volumes/$VOLUME_NAME"
[[ -e "$VOLUME_PATH" ]] && die "$VOLUME_PATH is already mounted; eject it and retry"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW_DMG"
trap 'hdiutil detach -quiet -force "$VOLUME_PATH" 2>/dev/null || true' EXIT

xcrun SetFile -a C "$VOLUME_PATH" || warn "Could not set the volume icon"

if ! perl -e 'alarm 60; exec @ARGV' osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 548}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 112
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {170, 200}
    set position of item "Applications" of container window to {490, 200}
    -- Park hidden items out of sight for people who show hidden files.
    repeat with hiddenName in {".background", ".VolumeIcon.icns", ".fseventsd", ".DS_Store"}
      try
        set position of item hiddenName of container window to {900, 900}
      end try
    end repeat
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
then
  warn "Finder layout skipped (allow your terminal to control Finder in System Settings → Privacy & Security → Automation)"
fi

# Finder writes the layout (.DS_Store) a moment after the window closes;
# ejecting before then loses it. Wait until the file stops changing.
DS_STORE="$VOLUME_PATH/.DS_Store"
last=""
for _ in $(seq 1 20); do
  sleep 0.5
  current="$(stat -f '%m %z' "$DS_STORE" 2>/dev/null || true)"
  [[ -n "$current" && "$current" == "$last" ]] && break
  last="$current"
done
[[ -f "$DS_STORE" ]] || warn "Finder did not save a window layout"
rm -rf "$VOLUME_PATH/.fseventsd"
sync
hdiutil detach -quiet "$VOLUME_PATH"
trap - EXIT

mkdir -p "$DIST_DIR"
rm -f "$DMG"
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG"
DMG_SIGN_ARGS=(--force --sign "$IDENTITY")
[[ $DISTRIBUTABLE -eq 1 ]] && DMG_SIGN_ARGS+=(--timestamp)
codesign "${DMG_SIGN_ARGS[@]}" "$DMG"

# --- Notarize -----------------------------------------------------------------

if [[ $NOTARIZE -eq 1 ]]; then
  step "Notarizing (this usually takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose "$DMG"
fi

step "Done: ${DMG#"$ROOT"/}"
if [[ $NOTARIZE -eq 0 ]]; then
  if [[ $DISTRIBUTABLE -eq 1 ]]; then
    warn "Signed for distribution but not notarized; other Macs will warn when opening it."
  else
    warn "Signed for this Mac only. Other Macs will refuse to open it until it is signed"
    warn "with a \"Developer ID Application\" certificate and notarized (see the top of this script)."
  fi
fi
