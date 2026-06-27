#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV="$HOME/Library/Application Support/VoiceToText/venv"
PYTHON="$VENV/bin/python"
CLI="$ROOT_DIR/cli/voice_to_text.py"
APP_DIR="/Applications/Nimbus VTT.app"
APP_NAME="Nimbus VTT"
APP_EXEC="$APP_DIR/Contents/MacOS/$APP_NAME"
CRASH_DIR="$HOME/Library/Logs/DiagnosticReports"
MODE="${1:-}"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

pass() {
    echo "OK: $1"
}

app_pids() {
    pgrep -x "$APP_NAME" || true
}

snapshot_crashes() {
    find "$CRASH_DIR" -maxdepth 1 -type f -name "Nimbus VTT*.ips" -print 2>/dev/null | sort
}

assert_no_new_crashes() {
    local before_file="$1"
    local label="$2"
    local after_file
    after_file="$(mktemp)"
    snapshot_crashes > "$after_file"
    local new_crashes
    new_crashes="$(comm -13 "$before_file" "$after_file")"
    rm -f "$after_file"
    [[ -z "$new_crashes" ]] || fail "new crash report after $label: $new_crashes"
    pass "no new crash report after $label"
}

run_cli_fixture() {
    local fixture stdout stderr
    fixture="$(mktemp "${TMPDIR:-/tmp}/nimbusvtt_smoke_XXXXXX.wav")"
    stdout="$(mktemp)"
    stderr="$(mktemp)"

    "$PYTHON" - "$fixture" <<'PY'
import sys
import numpy as np
import soundfile as sf

path = sys.argv[1]
sample_rate = 16000
audio = np.zeros((sample_rate, 1), dtype=np.float32)
sf.write(path, audio, sample_rate, subtype="FLOAT")
PY

    if ! "$PYTHON" "$CLI" transcribe --input "$fixture" --mode minimal >"$stdout" 2>"$stderr"; then
        cat "$stderr" >&2 || true
        rm -f "$fixture" "$stdout" "$stderr"
        fail "CLI fixture transcription failed"
    fi

    rm -f "$fixture" "$stdout" "$stderr"
    pass "CLI fixture transcription"
}

run_hud_cycle() {
    local before_crashes="$1"
    local stdout stderr hud_pid attempt
    stdout="$(mktemp)"
    stderr="$(mktemp)"

    NIMBUS_VTT_HUD_SMOKE=1 "$APP_EXEC" >"$stdout" 2>"$stderr" &
    hud_pid=$!

    for attempt in {1..30}; do
        if ! kill -0 "$hud_pid" >/dev/null 2>&1; then
            wait "$hud_pid" || {
                cat "$stderr" >&2 || true
                rm -f "$stdout" "$stderr"
                fail "HUD state-cycle smoke exited with failure"
            }
            rm -f "$stdout" "$stderr"
            assert_no_new_crashes "$before_crashes" "HUD state-cycle"
            pass "HUD state-cycle"
            return
        fi
        sleep 0.25
    done

    kill "$hud_pid" >/dev/null 2>&1 || true
    cat "$stderr" >&2 || true
    rm -f "$stdout" "$stderr"
    fail "HUD state-cycle smoke timed out"
}

runtime_smoke() {
    echo "=== Nimbus VTT runtime smoke test ==="

    [[ -x "$PYTHON" ]] || fail "venv python missing at $PYTHON"
    [[ -f "$CLI" ]] || fail "CLI script missing at $CLI"
    [[ -d "$APP_DIR" ]] || fail "installed app missing at $APP_DIR"
    [[ -x "$APP_EXEC" ]] || fail "app executable missing"

    run_cli_fixture

    local before_crashes before_pids after_pids started_by_test
    before_crashes="$(mktemp)"
    before_pids="$(mktemp)"
    after_pids="$(mktemp)"
    started_by_test=false

    cleanup_runtime() {
        if [[ "$started_by_test" == true && -f "$after_pids" ]]; then
            osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
            sleep 1
            while read -r pid; do
                [[ -n "$pid" ]] || continue
                if kill -0 "$pid" >/dev/null 2>&1; then
                    kill "$pid" >/dev/null 2>&1 || true
                fi
            done < "$after_pids"
        fi
        rm -f "$before_pids" "$after_pids"
    }

    snapshot_crashes > "$before_crashes"
    app_pids | sort > "$before_pids"
    if [[ ! -s "$before_pids" ]]; then
        started_by_test=true
    fi

    open "$APP_DIR" || {
        cleanup_runtime
        rm -f "$before_crashes"
        fail "failed to launch app"
    }

    local attempt
    for attempt in {1..20}; do
        app_pids | sort > "$after_pids"
        if [[ -s "$after_pids" ]]; then
            break
        fi
        sleep 0.5
    done

    [[ -s "$after_pids" ]] || {
        cleanup_runtime
        rm -f "$before_crashes"
        fail "app process did not start"
    }
    pass "app process running"

    sleep 4
    app_pids | sort > "$after_pids"
    [[ -s "$after_pids" ]] || {
        cleanup_runtime
        rm -f "$before_crashes"
        fail "app exited during runtime smoke"
    }
    pass "app remained running"

    cleanup_runtime
    if [[ "$started_by_test" == true ]]; then
        pass "quit app launched by runtime smoke"
    else
        pass "left pre-existing app running"
    fi
    assert_no_new_crashes "$before_crashes" "launch/quit"

    run_hud_cycle "$before_crashes"
    rm -f "$before_crashes"

    echo ""
    echo "=== Runtime smoke checks passed ==="
}

if [[ "$MODE" == "--runtime" ]]; then
    runtime_smoke
    exit 0
elif [[ -n "$MODE" ]]; then
    fail "usage: $0 [--runtime]"
fi

echo "=== Nimbus VTT smoke test ==="

[[ -x "$PYTHON" ]] || fail "venv python missing at $PYTHON"
pass "venv python"

[[ -f "$CLI" ]] || fail "CLI script missing at $CLI"
pass "CLI script"

version="$("$PYTHON" "$CLI" --version 2>/dev/null | head -1)"
[[ "$version" == *"0.3.0"* ]] || fail "unexpected CLI version: $version"
pass "CLI version $version"

"$PYTHON" "$CLI" transcribe --help 2>/dev/null | grep -q code_aware \
    || fail "transcribe --mode missing code_aware"
pass "transcribe --mode code_aware"

devices_json="$("$PYTHON" "$CLI" devices --json 2>/dev/null)"
echo "$devices_json" | "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); assert 'devices' in d" \
    || fail "devices --json returned invalid payload"
pass "devices --json"

mic_json="$("$PYTHON" "$CLI" mic 2>/dev/null)"
echo "$mic_json" | "$PYTHON" -c "import json,sys; d=json.load(sys.stdin); assert 'name' in d" \
    || fail "mic command returned invalid payload"
pass "mic JSON"

[[ -d "$APP_DIR" ]] || fail "installed app missing at $APP_DIR"
pass "installed app bundle"

for resource in AppIcon.icns MenuBarIdle.png MenuBarRecording.png MenuBarTranscribing.png voice_to_text.py; do
    [[ -f "$APP_DIR/Contents/Resources/$resource" ]] \
        || fail "missing bundle resource: $resource"
done
pass "bundle resources"

[[ -x "$APP_EXEC" ]] || fail "app executable missing"
pass "app executable"

plutil -extract NSAppleEventsUsageDescription raw "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 \
    || fail "Info.plist missing NSAppleEventsUsageDescription"
pass "Info.plist NSAppleEventsUsageDescription"

cd "$ROOT_DIR"
"$PYTHON" -m pytest -q tests/ || fail "pytest failed"
pass "pytest"

echo ""
echo "=== All smoke checks passed ==="
