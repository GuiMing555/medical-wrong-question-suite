#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
MIN_SYSTEM_VERSION="13.0"

CAPTURE_PRODUCT="WrongQuestionDailyOrganizer"
CAPTURE_DISPLAY_NAME="错题每日自动化整理"
CAPTURE_BUNDLE_ID="com.guiming.wrong-question-daily-organizer"

PRACTICE_PRODUCT="MedicalQuestionPractice"
PRACTICE_DISPLAY_NAME="医学综合练习"
PRACTICE_BUNDLE_ID="com.guiming.medical-question-practice"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
CAPTURE_BUNDLE="$DIST_DIR/$CAPTURE_DISPLAY_NAME.app"
PRACTICE_BUNDLE="$DIST_DIR/$PRACTICE_DISPLAY_NAME.app"

pkill -x "$CAPTURE_PRODUCT" >/dev/null 2>&1 || true
pkill -x "WrongQuestionCapture" >/dev/null 2>&1 || true
pkill -x "$PRACTICE_PRODUCT" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build --configuration release
BUILD_DIR="$(swift build --configuration release --show-bin-path)"

stage_bundle() {
  local product="$1"
  local display_name="$2"
  local bundle_id="$3"
  local bundle_path="$4"
  local ui_element="$5"
  local copy_resources="$6"
  local contents="$bundle_path/Contents"
  local macos_dir="$contents/MacOS"
  local resources_dir="$contents/Resources"
  local executable="$macos_dir/$product"

  rm -rf "$bundle_path"
  mkdir -p "$macos_dir" "$resources_dir"
  cp "$BUILD_DIR/$product" "$executable"
  chmod +x "$executable"

  if [[ "$copy_resources" == "true" ]]; then
    cp -R "$ROOT_DIR/Resources/DocxFonts" "$resources_dir/DocxFonts"
  fi

  cat >"$contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$product</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleName</key>
  <string>$display_name</string>
  <key>CFBundleDisplayName</key>
  <string>$display_name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <$ui_element/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

  /usr/bin/codesign --force --deep --sign - "$bundle_path" >/dev/null
  /usr/bin/plutil -lint "$contents/Info.plist" >/dev/null
}

stage_bundle "$CAPTURE_PRODUCT" "$CAPTURE_DISPLAY_NAME" "$CAPTURE_BUNDLE_ID" "$CAPTURE_BUNDLE" true true
stage_bundle "$PRACTICE_PRODUCT" "$PRACTICE_DISPLAY_NAME" "$PRACTICE_BUNDLE_ID" "$PRACTICE_BUNDLE" false false

open_capture() {
  /usr/bin/open -n "$CAPTURE_BUNDLE"
}

open_practice() {
  /usr/bin/open -n "$PRACTICE_BUNDLE"
}

install_bundles() {
  /usr/bin/ditto "$CAPTURE_BUNDLE" "/Applications/$CAPTURE_DISPLAY_NAME.app"
  /usr/bin/ditto "$PRACTICE_BUNDLE" "/Applications/$PRACTICE_DISPLAY_NAME.app"
}

verify_processes() {
  sleep 2
  pgrep -x "$CAPTURE_PRODUCT" >/dev/null
  pgrep -x "$PRACTICE_PRODUCT" >/dev/null
}

case "$MODE" in
  run)
    open_capture
    open_practice
    ;;
  --capture|capture)
    open_capture
    ;;
  --practice|practice)
    open_practice
    ;;
  --debug|debug)
    lldb -- "$PRACTICE_BUNDLE/Contents/MacOS/$PRACTICE_PRODUCT"
    ;;
  --logs|logs)
    open_capture
    open_practice
    /usr/bin/log stream --info --style compact --predicate "process == \"$CAPTURE_PRODUCT\" OR process == \"$PRACTICE_PRODUCT\""
    ;;
  --telemetry|telemetry)
    open_capture
    open_practice
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$CAPTURE_BUNDLE_ID\" OR subsystem == \"$PRACTICE_BUNDLE_ID\""
    ;;
  --verify|verify)
    open_capture
    open_practice
    verify_processes
    ;;
  --install|install)
    install_bundles
    ;;
  --install-verify|install-verify)
    install_bundles
    /usr/bin/open -n "/Applications/$CAPTURE_DISPLAY_NAME.app"
    /usr/bin/open -n "/Applications/$PRACTICE_DISPLAY_NAME.app"
    verify_processes
    ;;
  --build-only|build-only)
    ;;
  *)
    echo "usage: $0 [run|--capture|--practice|--debug|--logs|--telemetry|--verify|--install|--install-verify|--build-only]" >&2
    exit 2
    ;;
esac
