#!/bin/bash
set -euo pipefail

# Usage:
#   scripts/bundle.sh [release|debug]           # ad-hoc signed dev build
#   scripts/bundle.sh debug --fast              # fastest: skip dSYM + deep sign, just env+build
#   scripts/bundle.sh debug --speech             # include bundled speech and MLX
#   scripts/bundle.sh debug --all                # include all optional traits
#   scripts/bundle.sh release --sign            # build + Developer ID codesign
#   scripts/bundle.sh release --dist            # build + sign + notarize + staple + DMG
#
# SIGNING_IDENTITY defaults to "-" (ad-hoc). --sign and --dist require a Developer ID identity and TEAM_ID.

CONFIG="release"
MODE="dev"
ENABLE_ALL_TRAITS=false
INCLUDE_BUNDLED_SPEECH=false
INCLUDE_BACKEND_RUNTIME=false
for arg in "$@"; do
  case "$arg" in
    release|debug) CONFIG="$arg" ;;
    --fast)        MODE="fast" ;;
    --sign)        MODE="sign" ;;
    --dist)        MODE="dist" ;;
    --speech)      INCLUDE_BUNDLED_SPEECH=true ;;
    --all)
      ENABLE_ALL_TRAITS=true
      INCLUDE_BUNDLED_SPEECH=true
      ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

if [ "$CONFIG" = "release" ]; then
  ENABLE_ALL_TRAITS=true
  INCLUDE_BUNDLED_SPEECH=true
  INCLUDE_BACKEND_RUNTIME=true
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/app"

ENV_FILE=".env"
if [ "$CONFIG" = "release" ] && [ -f "$ROOT/.env.prod" ]; then
  ENV_FILE=".env.prod"
fi
if [ -f "$ROOT/$ENV_FILE" ]; then
  echo "==> Loading $ENV_FILE"
  set -a
  # shellcheck disable=SC1091
  . "$ROOT/$ENV_FILE"
  set +a
fi

SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"   # "-" = ad-hoc; set a Developer ID to sign for distribution
NOTARY_PROFILE="${NOTARY_PROFILE:-lenora-notary}"
PROVISION_PROFILE="${PROVISION_PROFILE:-$ROOT/scripts/Lenora_Developer_ID.provisionprofile}"
ENTITLEMENTS="$PKG/.build/Lenora.entitlements"
RESOURCES="$PKG/Sources/Lenora/Resources"
APP="$PKG/.build/Lenora.app"
ZIP="$PKG/.build/Lenora.zip"
DMG="$PKG/.build/Lenora.dmg"

sign_backend_runtime() {
  local runtime="$APP/Contents/Resources/Backend" f
  [ -d "$runtime" ] || return 0
  echo "==> Signing backend runtime"
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q 'Mach-O'; then
      codesign --force --sign "$SIGNING_IDENTITY" "$@" "$f"
    fi
  done < <(find "$runtime" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0)
}

make_dmg() {
  echo "==> Building DMG"
  rm -f "$DMG"
  local staging
  staging="$(mktemp -d)"
  cp -R "$APP" "$staging/Lenora.app"
  ln -s /Applications "$staging/Applications"
  cp "$RESOURCES/AppIcon.icns" "$staging/.VolumeIcon.icns"
  hdiutil create -volname "Lenora" -srcfolder "$staging" -ov -format UDZO "$DMG"
  rm -rf "$staging"
}

BUILD_ARGS=(-c "$CONFIG")
if $ENABLE_ALL_TRAITS; then
  TRAITS="all"
  BUILD_ARGS+=(--enable-all-traits)
else
  TRAITS=""
  if $INCLUDE_BUNDLED_SPEECH; then
    TRAITS="BundledSpeech"
  fi
  if [ -n "$TRAITS" ]; then
    BUILD_ARGS+=(--traits "$TRAITS")
  fi
fi

echo "==> Building ($CONFIG, traits: ${TRAITS:-none})"
(cd "$PKG" && swift build "${BUILD_ARGS[@]}")
BIN="$(cd "$PKG" && swift build "${BUILD_ARGS[@]}" --show-bin-path)/Lenora"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Lenora"
cp "$RESOURCES/Info.plist" "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "!! VERSION must look like 1.2.3" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi

cp "$RESOURCES/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Flatten SwiftPM's resource bundle into the app's Resources tree.
RES_BUNDLE="$(dirname "$BIN")/Lenora_Lenora.bundle"
if [ -d "$RES_BUNDLE/Fonts" ]; then
  cp -R "$RES_BUNDLE/Fonts" "$APP/Contents/Resources/"
else
  echo "!! missing Fonts/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -f "$RES_BUNDLE/Skills/catalog.json" ]; then
  cp -R "$RES_BUNDLE/Skills" "$APP/Contents/Resources/"
else
  echo "!! missing Skills/catalog.json in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

# Ensure the shipped Claude Desktop connector is always up to date with mcpb/ sources.
MCPB_SRC="$ROOT/mcpb"
MCPB_CHECKED_IN="$PKG/Sources/Lenora/Resources/MCPB/lenora.mcpb"
MCPB_FRESH="$(mktemp -d)/lenora.mcpb"
(cd "$MCPB_SRC" && zip -q -X -r "$MCPB_FRESH" manifest.json icon.png server/index.js server/package.json)
if ! unzip -p "$MCPB_CHECKED_IN" server/index.js 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" server/index.js) >/dev/null 2>&1 \
  || ! unzip -p "$MCPB_CHECKED_IN" manifest.json 2>/dev/null | diff -q - <(unzip -p "$MCPB_FRESH" manifest.json) >/dev/null 2>&1; then
  echo "==> refreshing checked-in lenora.mcpb from mcpb/ sources"
  cp "$MCPB_FRESH" "$MCPB_CHECKED_IN"
fi
cp "$MCPB_FRESH" "$APP/Contents/Resources/lenora.mcpb"
rm -rf "$(dirname "$MCPB_FRESH")"
if [ -d "$RES_BUNDLE/Images" ]; then
  cp -R "$RES_BUNDLE/Images" "$APP/Contents/Resources/"
fi
# .lproj folders must live at the bundle root for macOS to resolve them.
LOCALIZATION_COUNT=0
for locale_dir in "$RES_BUNDLE"/*.lproj; do
  [ -d "$locale_dir" ] || continue
  for strings_file in Localizable.strings InfoPlist.strings; do
    if [ ! -f "$locale_dir/$strings_file" ]; then
      echo "!! missing $strings_file in $locale_dir" >&2
      exit 1
    fi
  done
  cp -R "$locale_dir" "$APP/Contents/Resources/"
  LOCALIZATION_COUNT=$((LOCALIZATION_COUNT + 1))
done
if [ "$LOCALIZATION_COUNT" -eq 0 ]; then
  echo "!! no compiled localizations in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Changelog" ]; then
  cp -R "$RES_BUNDLE/Changelog" "$APP/Contents/Resources/"
else
  echo "!! missing Changelog/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi
if [ -d "$RES_BUNDLE/Models" ]; then
  cp -R "$RES_BUNDLE/Models" "$APP/Contents/Resources/"
else
  echo "!! missing Models/ in SwiftPM resource bundle at $RES_BUNDLE" >&2
  exit 1
fi

if ! ls "$RES_BUNDLE"/*.metallib >/dev/null 2>&1; then
  echo "!! no .metallib in SwiftPM resource bundle at $RES_BUNDLE — Metal effects would be missing" >&2
  exit 1
fi
cp "$RES_BUNDLE"/*.metallib "$APP/Contents/Resources/"

if $INCLUDE_BUNDLED_SPEECH; then
  MLX_METALLIB="$PKG/.build/$CONFIG/mlx.metallib"
  if [ ! -f "$MLX_METALLIB" ]; then
    echo "==> Building MLX metallib ($CONFIG)"
    BUILD_DIR="$PKG/.build" "$PKG/.build/checkouts/speech-swift/scripts/build_mlx_metallib.sh" "$CONFIG"
  fi
  if [ ! -f "$MLX_METALLIB" ]; then
    echo "!! missing $MLX_METALLIB — on-device speech features (VAD) would die silently" >&2
    exit 1
  fi
  mkdir -p "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
  cp "$MLX_METALLIB" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
fi

if $INCLUDE_BACKEND_RUNTIME; then
  echo "==> Building backend runtime"
  "$ROOT/scripts/build_backend_runtime.sh" "$APP/Contents/Resources/Backend"
fi

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Lenora"
touch "$APP"

if [ "$MODE" = "fast" ]; then
  echo "==> Codesigning main app with $SIGNING_IDENTITY (no timestamp, no helpers)"
  codesign --force --sign "$SIGNING_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
  echo "==> Done: $APP (fast mode — stable identity, no dSYM)"
  exit 0
fi

DSYM="$PKG/.build/Lenora.dSYM"
echo "==> Generating dSYM"
rm -rf "$DSYM"
dsymutil "$APP/Contents/MacOS/Lenora" -o "$DSYM"

if [ "$MODE" = "dev" ]; then
  echo "==> Signing dev app with $SIGNING_IDENTITY"
  sign_backend_runtime
  codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"
  echo "==> Done: $APP (dev signed)"
  if [ "$CONFIG" = "release" ]; then
    "$ROOT/scripts/check_backend_runtime.sh" "$APP/Contents/Resources/Backend"
    make_dmg
    echo "   DMG: $DMG"
  fi
  exit 0
fi

if [ "$SIGNING_IDENTITY" = "-" ]; then
  echo "!! --$MODE needs SIGNING_IDENTITY set to a Developer ID Application identity (ad-hoc is only for dev and --fast builds)" >&2
  exit 1
fi

if [ -z "${TEAM_ID:-}" ]; then
  echo "!! --$MODE needs TEAM_ID set to your Apple Developer team ID" >&2
  exit 1
fi
sed "s/TEAM_ID/$TEAM_ID/g" "$ROOT/scripts/Lenora.entitlements" > "$ENTITLEMENTS"

echo "==> Embedding provisioning profile"
if [ ! -f "$PROVISION_PROFILE" ]; then
  echo "!! provisioning profile not found at $PROVISION_PROFILE" >&2
  exit 1
fi
cp "$PROVISION_PROFILE" "$APP/Contents/embedded.provisionprofile"

sign_backend_runtime --options runtime --timestamp

echo "==> Codesigning main app"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGNING_IDENTITY" \
  "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$MODE" = "sign" ]; then
  echo "==> Done: $APP (signed, not notarized)"
  exit 0
fi

echo "==> Zipping .app for notarization"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notary (this can take several minutes)"
xcrun notarytool submit "$ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling ticket to .app"
xcrun stapler staple "$APP"
rm -f "$ZIP"

make_dmg

echo "==> Codesigning DMG"
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG"

echo "==> Submitting DMG to notary"
xcrun notarytool submit "$DMG" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG"


echo ""
echo "==> Done"
echo "   App: $APP"
echo "   DMG: $DMG"
