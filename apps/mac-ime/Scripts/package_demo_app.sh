#!/usr/bin/env bash
set -euo pipefail

APP_EXECUTABLE="MyTypeIMEDemo"
PRODUCT_NAME="${MYTYPE_PRODUCT_NAME:-MyType}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$PROJECT_DIR/dist"
BUILD_CONFIGURATION="release"
BUNDLE_ID="${MYTYPE_BUNDLE_ID:-com.mytype.demo}"
APP_VERSION="${MYTYPE_APP_VERSION:-0.1.0}"
APP_BUILD="${MYTYPE_APP_BUILD:-$(date +%Y%m%d%H%M)}"
CODESIGN_IDENTITY="${MYTYPE_CODESIGN_IDENTITY:--}"
INCLUDE_MODELS=0
SKIP_DMG=0
SKIP_ZIP=0

cd "$PROJECT_DIR"

usage() {
  cat <<'EOF'
Usage: ./Scripts/package_demo_app.sh [options]

Options:
  --include-models              Copy the local .models cache into the app bundle.
  --skip-dmg                    Do not create a DMG.
  --skip-zip                    Do not create a ZIP archive.
  --bundle-id <id>              Override CFBundleIdentifier.
  --version <version>           Override CFBundleShortVersionString.
  --build-number <number>       Override CFBundleVersion.
  --codesign-identity <value>   Signing identity. Use "-" for ad-hoc signing.
  --help                        Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --include-models)
      INCLUDE_MODELS=1
      shift
      ;;
    --skip-dmg)
      SKIP_DMG=1
      shift
      ;;
    --skip-zip)
      SKIP_ZIP=1
      shift
      ;;
    --bundle-id)
      BUNDLE_ID="$2"
      shift 2
      ;;
    --version)
      APP_VERSION="$2"
      shift 2
      ;;
    --build-number)
      APP_BUILD="$2"
      shift 2
      ;;
    --codesign-identity)
      CODESIGN_IDENTITY="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BIN_DIR="$(DEVELOPER_DIR="$DEVELOPER_DIR" swift build -c "$BUILD_CONFIGURATION" --product "$APP_EXECUTABLE" --show-bin-path)"
APP_BUNDLE="$DIST_DIR/$PRODUCT_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ASR_DIR="$RESOURCES_DIR/ASR"
APP_ICON_SOURCE="$PROJECT_DIR/Sources/MyTypeIMEDemo/Resources/AppLogo.png"
ASR_SCRIPT_SOURCE="$PROJECT_DIR/Scripts/faster_whisper_transcribe.py"
README_SOURCE="$PROJECT_DIR/Distribution/README.md"
README_PATH="$DIST_DIR/README.md"
INSTALL_NOTES="$DIST_DIR/${PRODUCT_NAME} Install Notes.txt"
LEGACY_INSTALL_NOTES="$DIST_DIR/Install MyType Demo.txt"
ZIP_PATH="$DIST_DIR/${PRODUCT_NAME}-${APP_VERSION}-macOS.zip"
DMG_PATH="$DIST_DIR/${PRODUCT_NAME}-${APP_VERSION}.dmg"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mytype-package.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

generate_icns() {
  local source_png="$1"
  local destination_icns="$2"
  local iconset_dir="$TMP_DIR/AppIcon.iconset"

  mkdir -p "$iconset_dir"
  sips -z 16 16 "$source_png" --out "$iconset_dir/icon_16x16.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 "$source_png" --out "$iconset_dir/icon_32x32.png" >/dev/null
  sips -z 64 64 "$source_png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 "$source_png" --out "$iconset_dir/icon_128x128.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 "$source_png" --out "$iconset_dir/icon_256x256.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 "$source_png" --out "$iconset_dir/icon_512x512.png" >/dev/null
  cp "$source_png" "$iconset_dir/icon_512x512@2x.png"
  iconutil -c icns "$iconset_dir" -o "$destination_icns"
}

write_info_plist() {
  local plist_path="$1"
  local icon_block=""
  if [[ -f "$APP_ICON_SOURCE" ]]; then
    icon_block='  <key>CFBundleIconFile</key>
  <string>AppIcon</string>'
  fi
  cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_EXECUTABLE</string>
$icon_block
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>MyType needs microphone access to record speech for transcription.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF
}

write_install_notes() {
  cat >"$INSTALL_NOTES" <<EOF
${PRODUCT_NAME} install notes
=============================

1. Drag ${PRODUCT_NAME}.app into Applications.
2. Launch the app once.
3. Grant Microphone permission when prompted.
4. Grant Accessibility permission in System Settings if you want text insertion into other apps.

Important:
- This package contains the current installable app build, not a full system Input Method installer.
- A bilingual README.md is included in this DMG for setup and usage details.
- Cloud API credentials are not bundled. Users should configure their own API in settings.
EOF
}

copy_resource_bundles() {
  find "$BIN_DIR" -maxdepth 1 -type d -name "*.bundle" -print0 | while IFS= read -r -d '' bundle_path; do
    cp -R "$bundle_path" "$RESOURCES_DIR/"
  done
}

build_release_binary() {
  echo "[package] building $PRODUCT_NAME ($BUILD_CONFIGURATION)"
  DEVELOPER_DIR="$DEVELOPER_DIR" swift build -c "$BUILD_CONFIGURATION" --product "$APP_EXECUTABLE"
}

prepare_bundle() {
  echo "[package] preparing app bundle"
  rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$DMG_PATH" "$LEGACY_INSTALL_NOTES"
  mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$ASR_DIR" "$DIST_DIR"

  cp "$BIN_DIR/$APP_EXECUTABLE" "$MACOS_DIR/$APP_EXECUTABLE"
  chmod 755 "$MACOS_DIR/$APP_EXECUTABLE"
  copy_resource_bundles

  cp "$ASR_SCRIPT_SOURCE" "$ASR_DIR/faster_whisper_transcribe.py"
  chmod 755 "$ASR_DIR/faster_whisper_transcribe.py"

  if [[ $INCLUDE_MODELS -eq 1 && -d "$PROJECT_DIR/.models" ]]; then
    echo "[package] copying local model cache"
    cp -R "$PROJECT_DIR/.models" "$ASR_DIR/.models"
  fi

  if [[ -f "$APP_ICON_SOURCE" ]]; then
    generate_icns "$APP_ICON_SOURCE" "$RESOURCES_DIR/AppIcon.icns"
  fi
  write_info_plist "$CONTENTS_DIR/Info.plist"
  write_install_notes
  if [[ -f "$README_SOURCE" ]]; then
    cp "$README_SOURCE" "$README_PATH"
  fi
}

sign_bundle() {
  echo "[package] signing app bundle with identity: $CODESIGN_IDENTITY"
  xattr -cr "$APP_BUNDLE"
  codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict "$APP_BUNDLE"
}

create_zip() {
  [[ $SKIP_ZIP -eq 1 ]] && return
  echo "[package] creating zip archive"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
}

create_dmg() {
  [[ $SKIP_DMG -eq 1 ]] && return
  echo "[package] creating dmg"
  local dmg_root="$TMP_DIR/dmg-root"
  mkdir -p "$dmg_root"
  cp -R "$APP_BUNDLE" "$dmg_root/"
  cp "$INSTALL_NOTES" "$dmg_root/"
  if [[ -f "$README_PATH" ]]; then
    cp "$README_PATH" "$dmg_root/"
  fi
  ln -s /Applications "$dmg_root/Applications"
  hdiutil create -volname "$PRODUCT_NAME" -srcfolder "$dmg_root" -ov -format UDZO "$DMG_PATH" >/dev/null
}

build_release_binary
prepare_bundle
sign_bundle
create_zip
create_dmg

echo "[package] done"
echo "[package] app: $APP_BUNDLE"
[[ $SKIP_ZIP -eq 1 ]] || echo "[package] zip: $ZIP_PATH"
[[ $SKIP_DMG -eq 1 ]] || echo "[package] dmg: $DMG_PATH"
[[ -f "$README_PATH" ]] && echo "[package] readme: $README_PATH"
echo "[package] notes: $INSTALL_NOTES"
