import numpy as np
import soundfile as sf
import os
import sys

SR = 44100


def envelope(n, attack=0.02, decay=0.15, sustain=1.0):
    """Smooth attack-hold-decay envelope."""
    t = np.arange(n) / SR
    env = np.ones_like(t) * sustain
    a = int(attack * SR)
    d = int(decay * SR)
    if a > 0:
        env[:a] = np.linspace(0, 1, a) ** 1.5
    if d > 0 and d < n:
        env[-d:] *= np.linspace(1, 0, d) ** 0.8
    return env


def soft_clip(wave, drive=1.2):
    """Gentle saturation for warmth."""
    return np.tanh(wave * drive) / np.tanh(drive)


def orb_bloom(duration=0.30, root=180.0, amplitude=0.20):
    """Orb igniting — warm low bloom with shimmer."""
    n = int(SR * duration)
    t = np.arange(n) / SR

    wave = 0.55 * np.sin(2 * np.pi * root * t)
    wave += 0.30 * np.sin(2 * np.pi * root * 1.5 * t)  # fifth
    wave += 0.12 * np.sin(2 * np.pi * root * 2.0 * t)  # octave
    wave += 0.06 * np.sin(2 * np.pi * root * 3.0 * t)  # shimmer

    # Slow swell in, soft glow tail
    env = envelope(n, attack=0.10, decay=0.18, sustain=0.85)
    shimmer = 0.04 * np.sin(2 * np.pi * 6 * t) * np.exp(-t * 4)
    wave = (wave + shimmer) * env * amplitude
    return soft_clip(wave, drive=1.15)


def orb_settle(duration=0.32, f1=350.0, f2=220.0, amplitude=0.16):
    """Orb settling — cozy descending pad with breath."""
    n = int(SR * duration)
    t = np.arange(n) / SR

    freq = np.linspace(f1, f2, n)
    phase = 2 * np.pi * np.cumsum(freq) / SR
    wave = 0.7 * np.sin(phase)
    wave += 0.25 * np.sin(phase * 0.5)
    wave += 0.15 * np.sin(2 * np.pi * f2 * t)

    # Faint filtered noise breath
    rng = np.random.default_rng(42)
    breath = rng.normal(0, 1, n)
    kernel = np.ones(int(0.008 * SR)) / int(0.008 * SR)
    breath = np.convolve(breath, kernel, mode="same") * 0.025
    breath *= envelope(n, attack=0.05, decay=0.22)

    env = envelope(n, attack=0.03, decay=0.24, sustain=0.7)
    wave = (wave * env + breath) * amplitude
    return soft_clip(wave, drive=1.1)


def orb_glow(duration=0.28, amplitude=0.14):
    """Completion glow — warm bell cluster."""
    n = int(SR * duration)
    t = np.arange(n) / SR

    freqs = [660.0, 880.0, 990.0]
    weights = [0.45, 0.40, 0.20]
    wave = np.zeros(n)
    for f, w in zip(freqs, weights):
        partial = np.sin(2 * np.pi * f * t)
        partial += 0.15 * np.sin(2 * np.pi * f * 2.01 * t)
        wave += w * partial

    env = envelope(n, attack=0.008, decay=0.20, sustain=0.6)
    tail = 0.03 * np.sin(2 * np.pi * 1320 * t) * np.exp(-t * 8)
    wave = (wave + tail) * env * amplitude
    return soft_clip(wave, drive=1.05)


def main():
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out_dir, exist_ok=True)

    start = orb_bloom()
    sf.write(os.path.join(out_dir, "start.wav"), start, SR, subtype="FLOAT")

    stop = orb_settle()
    sf.write(os.path.join(out_dir, "stop.wav"), stop, SR, subtype="FLOAT")

    done = orb_glow()
    sf.write(os.path.join(out_dir, "done.wav"), done, SR, subtype="FLOAT")

    print(f"Generated sounds in {out_dir}: start.wav, stop.wav, done.wav")


if __name__ == "__main__":
    main()
