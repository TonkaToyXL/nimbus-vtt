#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPPORT_DIR="$HOME/Library/Application Support/VoiceToText"
VENV="$SUPPORT_DIR/venv"
APP_NAME="Nimbus VTT"
APP_DIR="/Applications/$APP_NAME.app"
OLD_APP_DIRS=("$HOME/Applications/VoiceToText.app" "/Applications/VoiceToText.app")
BUILD_DIR="$SCRIPT_DIR/build"

usage() {
  echo "Usage: $0 --install | --check"
  echo "  --install  Set up venv, build Swift app, install to /Applications"
    echo "  --check    Verify dependencies, resources, Swift typecheck, and Python tests when available"
  exit 1
}

MODE="${1:-}"
if [[ "$MODE" != "--install" && "$MODE" != "--check" ]]; then
  usage
fi

require_cmd() {
  local cmd="$1"
  local hint="$2"
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: $cmd not found. $hint"
    exit 1
  }
}

swift_args() {
  local sdk="$1"
  printf '%s\n' \
    -target arm64-apple-macos13 \
    -sdk "$sdk" \
    -framework SwiftUI \
    -framework AppKit \
    -framework Carbon \
    -framework AVFoundation \
    -framework ApplicationServices \
    -framework UserNotifications \
    -framework ServiceManagement \
    -parse-as-library
}

run_check() {
  echo "=== Nimbus VTT check ==="
  require_cmd python3.12 "Install: brew install python@3.12"
  require_cmd swiftc "Install: xcode-select --install"
  require_cmd xcrun "Install: xcode-select --install"

  [[ -f "$SCRIPT_DIR/requirements.txt" ]] || { echo "ERROR: requirements.txt missing"; exit 1; }
  [[ -f "$SCRIPT_DIR/cli/voice_to_text.py" ]] || { echo "ERROR: CLI script missing"; exit 1; }
  [[ -f "$SCRIPT_DIR/app/Info.plist" ]] || { echo "ERROR: Info.plist missing"; exit 1; }
  [[ -f "$SCRIPT_DIR/scripts/generate_sounds.py" ]] || { echo "ERROR: sound generator missing"; exit 1; }
  [[ -f "$SCRIPT_DIR/scripts/generate_icon.py" ]] || { echo "ERROR: icon generator missing"; exit 1; }
  [[ -f "$SCRIPT_DIR/scripts/generate_menu_bar_icon.py" ]] || { echo "ERROR: menu bar icon generator missing"; exit 1; }

  local sdk
  sdk="$(xcrun --show-sdk-path)"
  echo "Typechecking Swift sources..."
  swiftc $(swift_args "$sdk") -typecheck "$SCRIPT_DIR/app/"*.swift

    echo "Checking Python syntax..."
    python3.12 -m py_compile "$SCRIPT_DIR/cli/voice_to_text.py"

    if [[ -x "$VENV/bin/python" ]] && "$VENV/bin/python" -c "import pytest" >/dev/null 2>&1; then
        echo "Running Python tests..."
        "$VENV/bin/python" -m pytest "$SCRIPT_DIR/tests" -q
    elif python3.12 -c "import pytest" >/dev/null 2>&1; then
        echo "Running Python tests..."
        python3.12 -m pytest "$SCRIPT_DIR/tests" -q
    else
        echo "Skipping Python tests: pytest is not installed."
    fi

    echo "Check complete: OK"
}

backup_path_for() {
  local path="$1"
  local stamp="$2"
  local base
  base="$(basename "$path")"
  echo "$SUPPORT_DIR/Backups/$stamp/$base"
}

move_to_backup() {
  local path="$1"
  local stamp="$2"
  [[ -e "$path" ]] || return 0

  local dest
  dest="$(backup_path_for "$path" "$stamp")"
  mkdir -p "$(dirname "$dest")"
  echo "Backing up existing bundle: $path -> $dest"
  mv "$path" "$dest"
}

if [[ "$MODE" == "--check" ]]; then
  run_check
  exit 0
fi

echo "=== Nimbus VTT build & install ==="

# ---- Preflight ----
require_cmd python3.12 "Install: brew install python@3.12"
require_cmd swiftc "Install: xcode-select --install"
require_cmd xcrun "Install: xcode-select --install"

# ---- 1. Python venv + deps ----
if [[ ! -d "$VENV" ]]; then
  echo "Creating venv at $VENV..."
  mkdir -p "$SUPPORT_DIR"
  python3.12 -m venv "$VENV"
else
  echo "Venv exists at $VENV"
fi

echo "Installing Python dependencies..."
"$VENV/bin/pip" install --quiet --upgrade pip wheel "setuptools<82"
"$VENV/bin/pip" install --quiet -r "$SCRIPT_DIR/requirements.txt"
"$VENV/bin/pip" install --quiet Pillow

# ---- 2. Prefetch model ----
echo "Ensuring model downloaded..."
"$VENV/bin/python" "$SCRIPT_DIR/cli/voice_to_text.py" prefetch || {
  echo "WARNING: prefetch failed. Model will download on first use."
}

# ---- 3. Generate sounds ----
echo "Generating feedback sounds..."
SOUNDS_DIR="$BUILD_DIR/sounds"
mkdir -p "$SOUNDS_DIR"
"$VENV/bin/python" "$SCRIPT_DIR/scripts/generate_sounds.py" "$SOUNDS_DIR"

# ---- 4. Generate app icon ----
echo "Generating app icon..."
ICON_PATH="$BUILD_DIR/AppIcon.icns"
"$VENV/bin/python" "$SCRIPT_DIR/scripts/generate_icon.py" "$ICON_PATH"

# ---- 4b. Generate menu bar icons ----
echo "Generating menu bar icons..."
ICONS_DIR="$BUILD_DIR/icons"
"$VENV/bin/python" "$SCRIPT_DIR/scripts/generate_menu_bar_icon.py" "$ICONS_DIR"

# ---- 5. Build Swift app ----
echo "Building Swift app..."
SDK="$(xcrun --show-sdk-path)"
mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR/$APP_NAME"

swiftc \
  $(swift_args "$SDK") \
  -O \
  -o "$BUILD_DIR/$APP_NAME" \
  "$SCRIPT_DIR/app/"*.swift

# ---- 6. Assemble staged .app bundle ----
echo "Assembling staged .app bundle..."
STAGED_APP="$BUILD_DIR/$APP_NAME.app"
rm -rf "$STAGED_APP"
mkdir -p "$STAGED_APP/Contents/MacOS"
mkdir -p "$STAGED_APP/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$STAGED_APP/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/app/Info.plist" "$STAGED_APP/Contents/Info.plist"
cp "$SCRIPT_DIR/cli/voice_to_text.py" "$STAGED_APP/Contents/Resources/voice_to_text.py"
cp "$SOUNDS_DIR/start.wav" "$STAGED_APP/Contents/Resources/start.wav"
cp "$SOUNDS_DIR/stop.wav" "$STAGED_APP/Contents/Resources/stop.wav"
cp "$SOUNDS_DIR/done.wav" "$STAGED_APP/Contents/Resources/done.wav"
cp "$ICON_PATH" "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$ICONS_DIR"/MenuBar*.png "$STAGED_APP/Contents/Resources/"

# ---- 7. Code sign (ad-hoc) ----
echo "Code signing (ad-hoc)..."
codesign --force --deep --sign - "$STAGED_APP"

# ---- 8. Kill existing instance + recoverable replace ----
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5

STAMP="$(date +%Y%m%d-%H%M%S)"
move_to_backup "$APP_DIR" "$STAMP"
for old in "${OLD_APP_DIRS[@]}"; do
  move_to_backup "$old" "$STAMP"
done

echo "Installing app bundle: $APP_DIR"
mv "$STAGED_APP" "$APP_DIR"
touch "$APP_DIR"

# Refresh Dock/Finder icon caches so new brand icon shows immediately.
killall Dock 2>/dev/null || true

# ---- 9. Smoke tests ----
echo ""
echo "--- Smoke tests ---"
"$VENV/bin/python" "$SCRIPT_DIR/cli/voice_to_text.py" --version
echo "App bundle: $([ -d "$APP_DIR" ] && echo 'OK' || echo 'MISSING')"
echo "Executable: $([ -x "$APP_DIR/Contents/MacOS/$APP_NAME" ] && echo 'OK' || echo 'MISSING')"
echo "CLI script: $([ -f "$APP_DIR/Contents/Resources/voice_to_text.py" ] && echo 'OK' || echo 'MISSING')"
echo "Sounds: $([ -f "$APP_DIR/Contents/Resources/start.wav" ] && [ -f "$APP_DIR/Contents/Resources/stop.wav" ] && [ -f "$APP_DIR/Contents/Resources/done.wav" ] && echo 'OK' || echo 'MISSING')"
echo "Icon: $([ -f "$APP_DIR/Contents/Resources/AppIcon.icns" ] && echo 'OK' || echo 'MISSING')"
echo "Menu bar icons: $([ -f "$APP_DIR/Contents/Resources/MenuBarIdle.png" ] && echo 'OK' || echo 'MISSING')"
echo "LSUIElement: $(defaults read "$APP_DIR/Contents/Info.plist" LSUIElement 2>/dev/null || echo 'false')"
echo ""
echo "=== Install complete ==="
echo ""
echo " App: $APP_DIR"
echo " Log: ~/Library/Logs/VoiceToText.log"
echo " Config: ~/Library/Application Support/VoiceToText/config.json"
echo ""
echo "Launch: open \"$APP_DIR\""
echo ""
echo "Permissions needed:"
echo " 1. Microphone (requested on first recording)"
echo " 2. Accessibility (for paste into focused app)"
echo " 3. Notifications (optional, status alerts)"
echo ""
echo "Hotkeys:"
echo " F1 toggle recording (dictation)"
echo " Option+Space toggle recording"
echo ""
echo "Nimbus VTT appears in Dock with the cloud-mic icon and in the menu bar with status glyphs."
echo "Grant permissions in System Settings > Privacy & Security"
echo ""
echo "Login Items: if you had Launch at Login enabled before rename, re-enable it in Settings"
echo "so it points at /Applications/Nimbus VTT.app (not retired VoiceToText.app)."
