#!/usr/bin/env python3
"""Nimbus VTT CLI — local dictation with mlx-whisper.

Used by the Nimbus VTT macOS app (SwiftUI menu bar + Dock) and for debugging.

Subcommands:
  dictate    Record interactively (Enter to start/stop), transcribe, clipboard
  record     Record to a WAV file (for app orchestration via SIGINT/SIGTERM)
  transcribe Transcribe an audio file, print text, optional clipboard
  serve      Persistent server: preload model, JSON lines on stdin/stdout
  prefetch   Pre-download the whisper model
  devices    List audio input devices
  mic        Print resolved input device as JSON (for app UI)
"""

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

APP_NAME = "VoiceToText"  # Support dir name; product is "Nimbus VTT"
SUPPORT_DIR = Path.home() / "Library" / "Application Support" / APP_NAME
LOG_PATH = Path.home() / "Library" / "Logs" / f"{APP_NAME}.log"
DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
SAMPLE_RATE = 16000
CHANNELS = 1
MAX_RECORD_SEC = 1800

EXIT_OK = 0
EXIT_ERROR = 1
EXIT_MIC_PERM = 2
EXIT_MODEL_ERR = 3
EXIT_NO_INPUT = 4

DEFAULT_BLOCKED_INPUT_PATTERNS = ["iphone", "ipad", "continuity"]
DEFAULT_INITIAL_PROMPT = (
    "This is a dictated note for a macOS productivity app. "
    "Transcribe exactly what the speaker says, using proper punctuation, "
    "capitalization, and grammar. Preserve technical terms, identifiers, "
    "URLs, file paths, and email addresses verbatim. Use em-dashes for "
    "pauses, not hyphens. Do not add filler such as 'um', 'uh', 'like', "
    "or 'you know'. Do not add sign-offs like 'thank you' or 'thanks'. "
    "Keep the output concise and ready to paste into a document or chat."
)
# Whisper filler on near-silent audio; only filtered on short, low-energy clips.
PHANTOM_PHRASES = frozenset({
    "thank you.",
    "thank you",
    "thanks for watching.",
    "thanks for watching",
    "thanks for listening.",
    "thanks for listening",
    "subtitle by amara.org",
    "subtitles by amara.org",
})
PHANTOM_MAX_DURATION_SEC = 1.5
PHANTOM_MAX_RMS = 0.02

# ---- Post-processing (humanize) ----

POSTPROCESS_PRESETS = ("off", "agent_handoff", "natural_prose", "code_aware", "minimal")
DEFAULT_POSTPROCESS = "agent_handoff"
POSTPROCESS_CONFIG_KEY = "postprocess_mode"


def _looks_like_abbrev(text: str, period_pos: int) -> bool:
    """True if the period at ``period_pos`` looks like part of an abbreviation.

    Handles p.m., a.m., e.g., i.e., U.S., U.K., and other single-letter-
    sandwich abbreviations. Returns False if the period ends a real sentence.
    """
    if period_pos <= 0 or period_pos >= len(text) - 1:
        return False
    prev_char = text[period_pos - 1]
    next_char = text[period_pos + 1]
    prev2 = text[period_pos - 2] if period_pos >= 2 else ""
    # Mid-word period: "don.t" is a typo, not an abbreviation.
    if prev2.isalpha() and prev2.islower() and prev_char.isalpha() and prev_char.islower():
        return False
    # Acronym like U.S. — uppercase letter on both sides.
    if (
        prev_char.isalpha() and prev_char.isupper()
        and next_char.isalpha() and next_char.isupper()
        and (not prev2.isalpha() or prev2.isupper())
    ):
        return True
    # Acronym trailing period: U. in "U.S. and" — single uppercase letter
    # preceded by a period (the inner acronym period) and followed by a
    # non-alphabetic boundary.
    if (
        prev_char.isalpha() and prev_char.isupper()
        and not next_char.isalpha()
        and prev2 == "."
    ):
        return True
    # Single lowercase consonant letter (p.m., a.m., etc.).
    # Fires both for the inner "." in "p.m." (next is a letter) and for the
    # trailing "." in "p.m. and" (next is a space) when preceded by a
    # single-letter abbreviation letter.
    if prev_char.isalpha() and prev_char.islower() and prev_char not in "aeiouy":
        return True
    # Double-letter abbreviation like e.g., i.e. (must have letters on both
    # sides to distinguish from a normal sentence end).
    if (
        prev_char.isalpha() and prev_char.islower()
        and next_char.isalpha() and next_char.islower()
    ):
        return True
    return False


# Each entry: (pattern, replacement). Order matters: longer / more specific
# patterns first. Replacement is either a string (treated as a regex template)
# or a callable taking a match and returning a string.


def _insert_space_after_period(match):
    """Insert a space after a period unless the next letter continues an
    abbreviation (p.m., a.m., e.g., U.S., i.e., etc.).
    """
    if _looks_like_abbrev(match.string, match.start()):
        return "." + match.group(1)
    return ". " + match.group(1)


def _capitalize_sentence_start(match):
    """Capitalize the first letter after sentence-final punctuation, but skip
    the case where the preceding period is part of an abbreviation.
    """
    boundary = match.group(1)  # "" or ". " or "! " etc.
    letter = match.group(2)
    if boundary.startswith(".") and boundary.endswith(" "):
        # Find the period position in the original text.
        period_pos = match.start() + len(boundary) - 2
        if _looks_like_abbrev(match.string, period_pos):
            return match.group(0)  # leave unchanged
    return boundary + letter.upper()

COMMON_RULES = [
    # Whitespace
    (r"[ \t]+", " "),
    (r" *\n *", "\n"),
    (r"\n{3,}", "\n\n"),
    (r" {2,}", " "),
    # Common Whisper artifacts
    (r"\s+([,.;:!?])", r"\1"),
    # Insert a space after sentence punctuation, but not after a period that
    # is part of a single-letter abbreviation (e.g. p.m., a.m., e.g., U.S.).
    (r"([,;!?])([A-Za-z])", r"\1 \2"),
    (r"\.([A-Z])", _insert_space_after_period),
    (r"\.([a-z])(?=[A-Za-z])", _insert_space_after_period),
    (r"\.{2,}", "..."),
    (r"\?{2,}", "?"),
    (r"!{2,}", "!"),
    # Smart quotes / dashes
    (r"(\w)'(\w)", r"\1’\2"),
    (r"(\w)\"(\w)", r"\1”\2"),
    (r"\"(\w)", r"“\1"),
    (r'(\w)\"(\s|$|[,.!?])', r"\1”\2"),
    (r" - ", " — "),
    (r"(^|\n)- ", r"\1— "),
]

AGENT_HANDOFF_RULES = COMMON_RULES + [
    # Filler words
    (r"\b(?:um+|uh+|er+|ah+|hmm+|mmm+)\b[,.\s]*", ""),
    (r"\b(?:like|basically|actually|literally|i mean|you know|i guess|kind of|sort of)\b[,.\s]*", ""),
    # Self-corrections
    (r"\.\s*(no wait|correction|sorry|i meant|actually no)[,.:]?\s*", ". "),
    # Trailing thought fragments
    (r"\.{3}\s*$", "..."),
    # Capitalize after sentence-final punctuation + close quote
    (r'([.!?][”"])\s+([a-z])', lambda m: m.group(1) + " " + m.group(2).upper()),
    # Capitalize the first letter of each sentence (skip abbreviation periods)
    (r'(^|[.!?]\s+)([a-z])', _capitalize_sentence_start),
    # Capitalize standalone "i" -> "I"
    (r"\bi\b", "I"),
    # Trim leading/trailing whitespace
    (r"^\s+", ""),
    (r"\s+$", ""),
]

NATURAL_PROSE_RULES = COMMON_RULES + [
    # Capitalize sentences but keep conversational fillers (lighter than agent_handoff).
    (r'([.!?][”"])\s+([a-z])', lambda m: m.group(1) + " " + m.group(2).upper()),
    (r'(^|[.!?]\s+)([a-z])', _capitalize_sentence_start),
    (r"\bi\b", "I"),
    (r"^\s+", ""),
    (r"\s+$", ""),
]

CODE_MARKERS = ("{", "}", ";", "->", "::", "def ", "func ", "class ", "import ", "#include", "const ", "let ", "var ")
MINIMAL_RULES = [
    (r"[ \t]+", " "),
    (r" *\n *", "\n"),
    (r"\n{3,}", "\n\n"),
]

PRESET_RULES = {
    "off": [],
    "agent_handoff": AGENT_HANDOFF_RULES,
    "natural_prose": NATURAL_PROSE_RULES,
    "minimal": MINIMAL_RULES,
}


def _looks_like_code_line(line: str) -> bool:
    """Heuristic: line resembles code, a URL/path, or technical notation."""
    stripped = line.strip()
    if not stripped:
        return False
    if any(marker in stripped for marker in CODE_MARKERS):
        return True
    if re.search(r"\b[a-z]+[A-Z][a-zA-Z]*\b", stripped):
        return True
    if re.search(r"\b[a-z]+_[a-z0-9_]+\b", stripped):
        return True
    if re.search(r"[=<>]=|[+\-*/]=|::", stripped):
        return True
    if re.search(r"https?://\S+|/\S+/\S+", stripped):
        return True
    return False


def _humanize_code_aware(text: str) -> str:
    """Preserve identifiers and code-like lines; light cleanup elsewhere."""
    lines = text.split("\n")
    out_lines: list[str] = []
    for line in lines:
        if _looks_like_code_line(line):
            cleaned = re.sub(r"[ \t]+", " ", line.strip())
            out_lines.append(cleaned)
        elif line.strip():
            out_lines.append(humanize_text(line, "natural_prose"))
        else:
            out_lines.append("")
    return "\n".join(out_lines)


def humanize_text(text: str, mode: str) -> str:
    """Apply the rule table for ``mode`` to ``text``.

    Unknown modes are treated as ``off`` (raw text returned) and logged once
    per call. Each individual rule is wrapped in try/except so a bad regex
    can never break a dictation.
    """
    if not text:
        return text
    if not mode or mode == "off":
        return text
    if mode == "code_aware":
        return _humanize_code_aware(text)
    rules = PRESET_RULES.get(mode)
    if rules is None:
        log("postprocess unknown_mode", mode=mode)
        return text
    if not rules:
        return text

    out = text
    for i, (pattern, replacement) in enumerate(rules):
        try:
            out = re.sub(pattern, replacement, out, flags=re.UNICODE)
        except Exception as e:
            log("postprocess error", rule=i, error=repr(e))
            continue
    return out


def log(event, **kv):
    """Write grep-friendly log line to stderr + log file."""
    parts = [event]
    for k, v in kv.items():
        parts.append(f"{k}={v!r}")
    line = " ".join(parts)
    print(line, file=sys.stderr, flush=True)
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_PATH, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {line}\n")
    except OSError:
        pass


def config_load():
    """Load config, writing defaults if missing. Returns dict."""
    defaults = {
        "model": DEFAULT_MODEL,
        "language": "en",
        "primary_hotkey": "f1",
        "secondary_hotkey": "option+space",
        "dedicated_hotkeys": ["f1"],
        "output_mode": "paste",
        "notifications_enabled": True,
        "sound_enabled": True,
        "vad_threshold": 0.005,
        "initial_prompt": DEFAULT_INITIAL_PROMPT,
        "blocked_input_patterns": DEFAULT_BLOCKED_INPUT_PATTERNS,
        "input_device_index": None,
        POSTPROCESS_CONFIG_KEY: DEFAULT_POSTPROCESS,
    }
    cfg_path = SUPPORT_DIR / "config.json"
    if cfg_path.exists():
        try:
            with open(cfg_path) as f:
                defaults.update(json.load(f))
        except (json.JSONDecodeError, OSError) as e:
            log("config error", error=str(e))
    else:
        SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
        try:
            with open(cfg_path, "w") as f:
                json.dump(defaults, f, indent=2)
        except OSError as e:
            log("config write error", error=str(e))
    return defaults


def pbcopy(text):
    """Copy text to macOS clipboard via pbcopy."""
    try:
        proc = subprocess.Popen(
            ["/usr/bin/pbcopy"],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        proc.communicate(input=text.encode("utf-8"), timeout=5)
        return proc.returncode == 0
    except (OSError, subprocess.TimeoutExpired) as e:
        log("clipboard error", error=str(e))
        return False


# ---- Audio device listing ----


def list_input_devices(config: dict | None = None) -> list[dict]:
    """Return input devices as dicts for CLI JSON output and human listing."""
    import sounddevice as sd

    cfg = config or config_load()
    patterns = cfg.get("blocked_input_patterns") or DEFAULT_BLOCKED_INPUT_PATTERNS
    try:
        devices = sd.query_devices()
        default = sd.default.device[0]
    except Exception as e:
        log("audio query error", error=str(e))
        return []

    result: list[dict] = []
    for i, dev in enumerate(devices):
        if dev.get("max_input_channels", 0) > 0:
            name = dev.get("name", "unknown")
            try:
                host = sd.query_hostapis(dev.get("hostapi", 0))["name"]
            except Exception:
                host = "unknown"
            result.append({
                "index": i,
                "name": name,
                "host": host,
                "channels": dev.get("max_input_channels", 0),
                "sample_rate": int(dev.get("default_samplerate", 0)),
                "blocked": is_blocked_device(name, patterns),
                "default": i == default,
            })
    return result


def list_devices():
    """Print input devices to stderr. Returns count."""
    devices = list_input_devices()
    if not devices:
        return 0

    print(f"{'Idx':>4}  {'Name':<50} {'API':<20} {'Ch':>3} {'Rate':>8}", file=sys.stderr)
    print(f"{'---':>4}  {'----':<50} {'---':<20} {'--':>3} {'----':>8}", file=sys.stderr)
    for dev in devices:
        marker = " *" if dev["default"] else "  "
        print(
            f"{dev['index']:>4}{marker} {dev['name']:<50} {dev['host']:<20} "
            f"{dev['channels']:>3} {dev['sample_rate']:>8}",
            file=sys.stderr,
        )
    return len(devices)


def is_blocked_device(name: str, patterns: list) -> bool:
    """True if device name matches any blocked substring."""
    lowered = name.lower()
    return any(p.lower() in lowered for p in patterns)


def resolve_input_device(config: dict) -> tuple[int | None, str, str]:
    """Pick input device: user override, else system default unless blocked.

    Returns (device_index, device_name, source).
    device_index None means use live system default (device=None in sounddevice).
    """
    import sounddevice as sd

    patterns = config.get("blocked_input_patterns") or DEFAULT_BLOCKED_INPUT_PATTERNS
    try:
        devices = sd.query_devices()
        default_idx = sd.default.device[0]
    except Exception as e:
        log("audio query error", error=str(e))
        raise RuntimeError("no_input_device") from e

    num_devices = len(devices)

    explicit = config.get("input_device_index")
    if explicit is not None:
        try:
            idx = int(explicit)
            if 0 <= idx < num_devices:
                dev = devices[idx]
                if dev.get("max_input_channels", 0) > 0:
                    name = dev.get("name", "unknown")
                    return idx, name, "user_selected"
        except (TypeError, ValueError):
            log("input_device_index invalid", value=explicit)

    if default_idx is not None and 0 <= default_idx < num_devices:
        dev = devices[default_idx]
        if dev.get("max_input_channels", 0) > 0 and not is_blocked_device(dev.get("name", ""), patterns):
            return None, dev.get("name", "unknown"), "system_default"

    for i, dev in enumerate(devices):
        if dev.get("max_input_channels", 0) > 0 and not is_blocked_device(dev.get("name", ""), patterns):
            return i, dev.get("name", "unknown"), "fallback"

    if default_idx is not None and 0 <= default_idx < num_devices:
        dev = devices[default_idx]
        return default_idx, dev.get("name", "unknown"), "unfiltered_fallback"

    raise RuntimeError("no_input_device")


# ---- Recorder ----


class Recorder:
    """Record from default microphone to a WAV file."""

    def __init__(
        self,
        output_path: str,
        *,
        silence_threshold: float | None = None,
        silence_stop: float | None = None,
        min_duration: float = 0.4,
    ):
        self.output_path = Path(output_path)
        self._stream = None
        self._sf_file = None
        self._start_time = 0.0
        self._silence_threshold = silence_threshold
        self._silence_stop = silence_stop
        self._min_duration = min_duration
        self._heard_speech = False
        self._last_loud_at = 0.0
        self._last_rms_log_time = 0.0

    def _callback(self, indata, frames, time_info, status):
        if status:
            log("audio callback status", status=str(status))
        if self._sf_file is not None:
            self._sf_file.write(indata)

        import numpy as np

        rms = float(np.sqrt(np.mean(np.square(indata))))
        now = time.time()
        if now - self._last_rms_log_time >= 0.1:
            self._last_rms_log_time = now
            print(f"__RMS__{rms:.6f}", file=sys.stderr, flush=True)

        if self._silence_threshold is None or self._silence_stop is None:
            return

        if rms >= self._silence_threshold:
            self._heard_speech = True
            self._last_loud_at = now

    def should_stop_for_silence(self) -> bool:
        """True when speech was heard and trailing silence exceeded the threshold."""
        if self._silence_threshold is None or self._silence_stop is None:
            return False
        if not self._heard_speech:
            return False
        if self.elapsed < self._min_duration:
            return False
        return (time.time() - self._last_loud_at) >= self._silence_stop

    def start(self, config: dict | None = None) -> bool:
        """Open stream + WAV file. Returns False on failure."""
        import sounddevice as sd
        import soundfile as sf

        cfg = config or config_load()
        try:
            device_idx, dev_name, source = resolve_input_device(cfg)
        except RuntimeError:
            log("recording error no_default_device")
            return False

        log(
            "recording started",
            device=dev_name,
            resolved_index=device_idx,
            source=source,
        )

        self.output_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            self._sf_file = sf.SoundFile(
                str(self.output_path),
                mode="w",
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                subtype="FLOAT",
            )
        except OSError as e:
            log("recording file error", error=str(e))
            return False

        try:
            self._stream = sd.InputStream(
                device=device_idx,
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype="float32",
                callback=self._callback,
            )
            self._stream.start()
        except sd.PortAudioError as e:
            log("recording device error", error=str(e))
            self._sf_file.close()
            return False

        self._start_time = time.time()
        return True

    def stop(self) -> float:
        """Stop stream, finalize WAV. Returns duration in seconds."""
        if self._stream is not None:
            try:
                self._stream.stop()
                self._stream.close()
            except Exception:
                pass
            self._stream = None
        if self._sf_file is not None:
            try:
                self._sf_file.close()
            except Exception:
                pass
            self._sf_file = None
        duration = time.time() - self._start_time if self._start_time else 0.0
        log("recording stopped", duration=f"{duration:.1f}s")
        return duration

    @property
    def elapsed(self) -> float:
        return time.time() - self._start_time if self._start_time else 0.0


# ---- Transcription ----


def load_audio_mono(audio_path: str):
    """Load audio as mono float32 numpy array."""
    import soundfile as sf
    import numpy as np

    data, _sr = sf.read(audio_path, dtype="float32")
    if data.ndim > 1:
        data = data.mean(axis=1)
    return np.ascontiguousarray(data)


def compute_rms_from_audio(data) -> float:
    """Compute max RMS energy over 0.5s windows. Returns float in [0, 1]."""
    import numpy as np

    if len(data) == 0:
        return 0.0
    win = int(0.5 * SAMPLE_RATE)
    if win < 1 or len(data) < win:
        return float(np.sqrt(np.mean(data**2)))
    n_windows = len(data) // win
    chunks = data[: n_windows * win].reshape(n_windows, win)
    return float(np.sqrt(np.mean(chunks**2, axis=1)).max())


def compute_rms(audio_path: str) -> float:
    """Compute max RMS energy over 0.5s windows. Returns float in [0, 1]."""
    try:
        data = load_audio_mono(audio_path)
        return compute_rms_from_audio(data)
    except Exception as e:
        log("vad error", error=str(e))
        return -1.0


def build_transcribe_kwargs(config: dict) -> dict:
    """Build mlx-whisper kwargs tuned for low-latency dictation."""
    kwargs = {
        "path_or_hf_repo": config.get("model", DEFAULT_MODEL),
        "verbose": False,
        "condition_on_previous_text": False,
        "without_timestamps": True,
        "temperature": 0.0,
    }
    language = config.get("language")
    if language:
        kwargs["language"] = language
    prompt = config.get("initial_prompt") or DEFAULT_INITIAL_PROMPT
    kwargs["initial_prompt"] = prompt
    return kwargs


def is_phantom_transcription(text: str, duration_sec: float, rms: float) -> bool:
    """Drop known Whisper hallucinations on very short, quiet clips."""
    if duration_sec > PHANTOM_MAX_DURATION_SEC:
        return False
    normalized = text.strip().lower()
    if normalized not in PHANTOM_PHRASES:
        return False
    return rms < PHANTOM_MAX_RMS


def transcribe_audio(
    audio_path: str,
    config: dict,
    vad: bool = True,
    mode: str | None = None,
) -> tuple[str, str, int]:
    """Transcribe audio file. Returns (clean_text, raw_text, exit_code).

    ``raw_text`` is the unprocessed Whisper output (after phantom filtering).
    ``clean_text`` is ``raw_text`` after the humanizer for ``mode`` runs. The
    caller logs the raw text and uses the clean text for output.
    """
    try:
        vad_threshold = config.get("vad_threshold", 0.005)
        rms = -1.0

        try:
            audio = load_audio_mono(audio_path)
        except Exception as e:
            log("audio load error", error=str(e))
            return "", "", EXIT_ERROR

        duration_sec = len(audio) / SAMPLE_RATE
        try:
            rms = compute_rms_from_audio(audio)
        except Exception as e:
            log("rms compute error", error=str(e))
            rms = 0.0

        if vad:
            log("vad rms", rms=f"{rms:.4f}")
            if rms < vad_threshold:
                log("vad skipped silence", rms=f"{rms:.4f}")
                return "", "", EXIT_OK

        kwargs = build_transcribe_kwargs(config)
        log(
            "transcribing",
            model=kwargs["path_or_hf_repo"],
            language=kwargs.get("language", "auto"),
        )
        try:
            import mlx_whisper
        except ImportError as e:
            log("model error", error="mlx_whisper not installed", detail=str(e))
            return "", "", EXIT_MODEL_ERR

        try:
            result = mlx_whisper.transcribe(audio, **kwargs)
            text = (result.get("text") or "").strip()
        except Exception as e:
            log("model error", error=str(e))
            return "", "", EXIT_MODEL_ERR

        if text and is_phantom_transcription(text, duration_sec, rms):
            log("phantom filtered", text=text, duration=f"{duration_sec:.1f}s", rms=f"{rms:.4f}")
            text = ""

        raw_text = text
        chosen_mode = mode if mode is not None else config.get(POSTPROCESS_CONFIG_KEY, DEFAULT_POSTPROCESS)
        if raw_text:
            first = raw_text[:80].replace("\n", " ")
            log("raw_transcript", chars=len(raw_text), first=first)

        clean_text = humanize_text(raw_text, chosen_mode)
        if raw_text:
            log(
                "postprocess applied",
                mode=chosen_mode,
                before=len(raw_text),
                after=len(clean_text),
            )

        log("transcribed", chars=len(clean_text))
        return clean_text, raw_text, EXIT_OK
    except Exception as e:
        log("transcribe_audio internal error", error=str(e))
        return "", "", EXIT_ERROR


def transcribe_file(
    audio_path: str,
    config: dict,
    do_clipboard: bool = False,
    vad: bool = True,
    mode: str | None = None,
) -> int:
    """Transcribe with mlx-whisper, print text, optionally clip. Returns exit code."""
    text, _raw, rc = transcribe_audio(audio_path, config, vad=vad, mode=mode)
    if rc != EXIT_OK:
        return rc

    print(text, flush=True)

    if do_clipboard:
        if pbcopy(text):
            log("clipboard success")
        else:
            log("clipboard fallback", error="pbcopy failed")

    return EXIT_OK


def preload_model(config: dict) -> int:
    """Load whisper model into memory. Returns exit code."""
    model = config.get("model", DEFAULT_MODEL)
    log("serve loading", model=model)
    try:
        from mlx_whisper.load_models import load_model
        load_model(model)
    except ImportError as e:
        log("model error", error="mlx_whisper not installed", detail=str(e))
        return EXIT_MODEL_ERR
    except Exception as e:
        log("model error", error=str(e))
        return EXIT_MODEL_ERR

    log("serve ready", model=model)
    return EXIT_OK


# ---- Subcommands ----


def cmd_dictate(args, config):
    """Interactive record, transcribe, clipboard."""
    log("dictate ready")
    try:
        input("Press Enter to start recording... ")
    except (EOFError, KeyboardInterrupt):
        return

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp_path = f.name

    try:
        recorder = Recorder(tmp_path)
        if not recorder.start(config):
            sys.exit(EXIT_NO_INPUT)

        done = threading.Event()
        stop = threading.Event()

        def timer():
            while not stop.is_set():
                e = recorder.elapsed
                print(f"\r\033[K{int(e//60):02d}:{int(e%60):02d}", file=sys.stderr, end="", flush=True)
                time.sleep(0.2)
                if e >= MAX_RECORD_SEC:
                    done.set()
                    break

        t = threading.Thread(target=timer, daemon=True)
        t.start()

        try:
            input()
        except (EOFError, KeyboardInterrupt):
            pass
        finally:
            done.set()

        stop.set()
        print("\r\033[K", file=sys.stderr, end="", flush=True)
        recorder.stop()

        rc = transcribe_file(tmp_path, config, do_clipboard=True)
        sys.exit(rc)
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def _sample_ambient_rms(duration: float = 0.2) -> float | None:
    """Record `duration` seconds from the default mic and return RMS amplitude.
    Returns None if the input device cannot be opened."""
    import sounddevice as sd
    import numpy as np

    cfg = config_load()
    try:
        device_idx, dev_name, source = resolve_input_device(cfg)
    except RuntimeError:
        return None
    try:
        sample = sd.rec(
            int(duration * SAMPLE_RATE),
            samplerate=SAMPLE_RATE,
            channels=CHANNELS,
            device=device_idx,
            blocking=True,
        )
    except Exception as exc:
        log("ambient sample failed", error=str(exc))
        return None
    rms = float(np.sqrt(np.mean(np.square(sample))))
    log("ambient sample", rms=rms, device=dev_name)
    return rms


def cmd_record(args, config):
    """Record to WAV. SIGINT/SIGTERM stops cleanly."""
    done = threading.Event()

    def handle_signal(signum, _frame):
        log("caught signal", signal=signum)
        done.set()

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    silence_threshold = args.silence_threshold
    if silence_threshold is None and args.silence_stop is not None:
        silence_threshold = float(config.get("vad_threshold", 0.005))

    # Adaptive threshold: sample 200ms of ambient noise and adjust.
    if args.adaptive_threshold and silence_threshold is not None:
        ambient = _sample_ambient_rms(duration=0.2)
        if ambient is not None:
            adjusted = max(silence_threshold, ambient * 3.0)
            log("vad adaptive", user=silence_threshold, ambient=ambient, adjusted=adjusted)
            silence_threshold = adjusted

    recorder = Recorder(
        args.output,
        silence_threshold=silence_threshold,
        silence_stop=args.silence_stop,
        min_duration=args.min_duration,
    )
    if not recorder.start(config):
        sys.exit(EXIT_NO_INPUT)

    stop = threading.Event()

    def timer():
        while not stop.is_set():
            e = recorder.elapsed
            print(f"\r\033[K{int(e//60):02d}:{int(e%60):02d}", file=sys.stderr, end="", flush=True)
            time.sleep(0.2)
            if e >= MAX_RECORD_SEC:
                log("recording max duration")
                done.set()
                break
            if recorder.should_stop_for_silence():
                log("recording silence stop", elapsed=f"{e:.1f}s")
                done.set()
                break

    t = threading.Thread(target=timer, daemon=True)
    t.start()

    if args.duration and args.duration > 0:
        done.wait(timeout=args.duration)
        done.set()
    else:
        while not done.wait(timeout=0.1):
            pass

    stop.set()
    print("\r\033[K", file=sys.stderr, end="", flush=True)
    recorder.stop()
    log("recorded output", file=args.output)


def cmd_transcribe(args, config):
    """Transcribe audio file."""
    mode = getattr(args, "mode", None) or None
    rc = transcribe_file(args.input, config, do_clipboard=args.clipboard, mode=mode)
    sys.exit(rc)


def cmd_prefetch(args, config):
    """Pre-download model by transcribing 1s of silence."""
    model = args.model or config.get("model", DEFAULT_MODEL)
    log("prefetch", model=model)

    import numpy as np
    import soundfile as sf

    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmp_path = f.name

    try:
        silence = np.zeros((SAMPLE_RATE * 1, CHANNELS), dtype=np.float32)
        sf.write(tmp_path, silence, SAMPLE_RATE, subtype="FLOAT")
        rc = transcribe_file(tmp_path, {"model": model, "language": None}, do_clipboard=False)
        if rc == EXIT_OK:
            log("prefetch complete", model=model)
        sys.exit(rc)
    finally:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass


def cmd_serve(args, config):
    """Persistent transcription server: JSON lines on stdin/stdout.

    When --framed is passed, outputs use 4-byte big-endian length prefix
    before each JSON message (no trailing newline). This prevents desync
    from embedded newlines in error messages.
    """
    rc = preload_model(config)
    if rc != EXIT_OK:
        _serve_write({"ready": False, "error": "model load failed"}, args.framed)
        sys.exit(rc)

    _serve_write({"ready": True}, args.framed)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            _serve_write({"text": "", "error": f"invalid json: {e}"}, args.framed)
            continue

        audio_path = req.get("audio_path")
        if not audio_path:
            _serve_write({"text": "", "error": "missing audio_path"}, args.framed)
            continue

        if not os.path.isfile(audio_path):
            _serve_write({"text": "", "error": f"file not found: {audio_path}"}, args.framed)
            continue

        config = config_load()
        mode = req.get("mode")
        text, raw, trc = transcribe_audio(audio_path, config, vad=True, mode=mode)
        resp = {"text": text, "raw": raw}
        if trc != EXIT_OK:
            resp["error"] = "transcription failed"
        _serve_write(resp, args.framed)


def _serve_write(data: dict, framed: bool) -> None:
    """Write a JSON response to stdout."""
    import struct

    encoded = json.dumps(data, ensure_ascii=False).encode("utf-8")
    if framed:
        sys.stdout.buffer.write(struct.pack(">I", len(encoded)))
        sys.stdout.buffer.write(encoded)
        sys.stdout.buffer.flush()
    else:
        sys.stdout.write(encoded.decode("utf-8", errors="replace") + "\n")
        sys.stdout.flush()


def cmd_mic(args, config):
    """Print resolved input device as JSON for the app UI."""
    try:
        device_idx, name, source = resolve_input_device(config)
    except RuntimeError:
        log("no_input_device")
        print(json.dumps({"name": "", "index": None, "source": "none", "error": "no_input_device"}))
        sys.exit(EXIT_NO_INPUT)

    payload = {"name": name, "index": device_idx, "source": source}
    print(json.dumps(payload), flush=True)
    sys.exit(EXIT_OK)


def cmd_devices(args, config):
    """List audio input devices."""
    devices = list_input_devices(config)
    if not devices:
        log("no_input_device")
        if getattr(args, "json", False):
            print(json.dumps({"devices": [], "error": "no_input_device"}))
        else:
            print("No audio input devices found.", file=sys.stderr)
        sys.exit(EXIT_NO_INPUT)
    log("listing devices", count=len(devices))
    if getattr(args, "json", False):
        print(json.dumps({"devices": devices}), flush=True)
    else:
        list_devices()
    sys.exit(EXIT_OK)


# ---- Main ----


def main():
    parser = argparse.ArgumentParser(
        prog="nimbus-vtt",
        description="Nimbus VTT CLI — local dictation with mlx-whisper",
    )
    parser.add_argument("--version", action="store_true", help="Show version and exit")

    sub = parser.add_subparsers(dest="command", metavar="COMMAND")

    p_dictate = sub.add_parser("dictate", help="Record interactively, transcribe, clip")
    p_record = sub.add_parser("record", help="Record to WAV file")
    p_record.add_argument("--output", "-o", required=True)
    p_record.add_argument("--duration", "-d", type=float, default=None)
    p_record.add_argument(
        "--silence-stop",
        type=float,
        default=None,
        help="Stop after this many seconds of trailing silence (assistant mode)",
    )
    p_record.add_argument(
        "--silence-threshold",
        type=float,
        default=None,
        help="RMS threshold for speech detection (defaults to config vad_threshold)",
    )
    p_record.add_argument(
        "--adaptive-threshold",
        action="store_true",
        help="Sample ambient noise and auto-adjust VAD threshold",
    )
    p_record.add_argument(
        "--min-duration",
        type=float,
        default=0.4,
        help="Minimum seconds before silence-stop can fire",
    )
    p_transcribe = sub.add_parser("transcribe", help="Transcribe audio file")
    p_transcribe.add_argument("--input", "-i", required=True)
    p_transcribe.add_argument("--clipboard", "-c", action="store_true", help="Copy to clipboard")
    p_transcribe.add_argument(
        "--mode",
        default=None,
        choices=list(POSTPROCESS_PRESETS),
        help="Postprocess mode override (default: from config)",
    )
    p_prefetch = sub.add_parser("prefetch", help="Pre-download model")
    p_prefetch.add_argument("--model", default=None, help="Model repo ID")
    p_serve = sub.add_parser("serve", help="Persistent transcription server (JSON stdin/stdout)")
    p_serve.add_argument(
        "--framed",
        action="store_true",
        help="Use 4-byte length-prefixed framing instead of newline-delimited JSON",
    )
    p_devices = sub.add_parser("devices", help="List audio input devices")
    p_devices.add_argument("--json", action="store_true", help="Emit JSON for app UI")
    sub.add_parser("mic", help="Print resolved input device as JSON")

    args = parser.parse_args()

    if args.version:
        print("Nimbus VTT CLI 0.3.0")
        print(f"  default-model: {DEFAULT_MODEL}")
        sys.exit(EXIT_OK)

    if not args.command:
        parser.print_help()
        sys.exit(EXIT_ERROR)

    config = config_load()

    dispatch = {
        "dictate": cmd_dictate,
        "record": cmd_record,
        "transcribe": cmd_transcribe,
        "serve": cmd_serve,
        "prefetch": cmd_prefetch,
        "devices": cmd_devices,
        "mic": cmd_mic,
    }
    fn = dispatch.get(args.command)
    if fn:
        fn(args, config)
    else:
        parser.print_help()
        sys.exit(EXIT_ERROR)


if __name__ == "__main__":
    main()
