#!/usr/bin/env python3
"""Pnoe sound sets Wood, Glass and Sine: 3 styles x 4 events (start, stop, cancel, error), synthesized from nothing.

No samples, no recordings, no downloads. Everything below is numpy maths.
Output: <out>/<set>-<event>.wav  (48 kHz, mono, 16-bit, peak -12 dBFS).

Run:  python3 generate_tones.py [--out DIR]     (needs numpy and scipy; DIR defaults to Pnoe/Resources/Sounds)
"""
from __future__ import annotations

import argparse
import wave
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfiltfilt

SR = 48_000
PEAK_DBFS = -12.0
DEFAULT_OUT = Path(__file__).resolve().parent.parent.parent / "Pnoe" / "Resources" / "Sounds"
RNG_SEED = 11  # deterministic noise, so a rerun gives identical files


# ---------------------------------------------------------------- helpers
def t_axis(ms: float) -> np.ndarray:
    return np.arange(int(round(SR * ms / 1000))) / SR


def sine_phase(freq: np.ndarray) -> np.ndarray:
    """Phase of a sine whose frequency follows `freq` (Hz per sample)."""
    return 2 * np.pi * np.cumsum(freq) / SR


def raised_cos(n: int, rising: bool) -> np.ndarray:
    ramp = 0.5 - 0.5 * np.cos(np.pi * np.arange(n) / max(n - 1, 1))
    return ramp if rising else ramp[::-1]


def place(buf: np.ndarray, sig: np.ndarray, at_ms: float) -> None:
    """Add `sig` into `buf` starting at `at_ms`."""
    i = int(round(SR * at_ms / 1000))
    j = min(len(buf), i + len(sig))
    buf[i:j] += sig[: j - i]


def finish(x: np.ndarray, total_ms: float, fade_in_ms: float = 4, fade_out_ms: float = 25) -> np.ndarray:
    """Pad or trim to total_ms, remove rumble/DC, fade both ends, set peak to -12 dBFS."""
    n = int(round(SR * total_ms / 1000))
    x = np.pad(x, (0, max(0, n - len(x))))[:n]
    x = sosfiltfilt(butter(2, 70, "highpass", fs=SR, output="sos"), x)
    x = x * np.concatenate([
        raised_cos(int(SR * fade_in_ms / 1000), True),
        np.ones(n - int(SR * fade_in_ms / 1000) - int(SR * fade_out_ms / 1000)),
        raised_cos(int(SR * fade_out_ms / 1000), False),
    ])
    x *= 10 ** (PEAK_DBFS / 20) / np.max(np.abs(x))
    return x.astype(np.float64)


def lowpass(x: np.ndarray, hz: float, order: int = 4) -> np.ndarray:
    return sosfiltfilt(butter(order, hz, "lowpass", fs=SR, output="sos"), x)


# ---------------------------------------------------------------- style 02: wood
def mallet(freq: float, ms: float, tau: float, bright: float = 0.35, thump: float = 0.5) -> np.ndarray:
    """Marimba-like bar: partials 1 and ~3.9 (bar tuning), each decaying exponentially, plus a soft mallet thump."""
    t = t_axis(ms)
    body = np.sin(2 * np.pi * freq * t) * np.exp(-t / tau)
    body += bright * np.sin(2 * np.pi * freq * 3.92 * t + 0.6) * np.exp(-t / (tau * 0.32))
    rng = np.random.default_rng(RNG_SEED + int(freq))
    knock = lowpass(rng.standard_normal(len(t)), 1800, 2) * np.exp(-t / 0.004)
    body += thump * 0.5 * knock
    body *= np.minimum(1.0, t / 0.0015)  # 1.5 ms attack so the strike is soft
    return body


def style_wood() -> dict[str, np.ndarray]:
    def two(f_a: float, f_b: float, gap_ms: float, total: float, tau: float, bright: float, b_gain: float) -> np.ndarray:
        buf = np.zeros(int(SR * total / 1000))
        place(buf, mallet(f_a, total, tau, bright), 0)
        place(buf, b_gain * mallet(f_b, total, tau, bright), gap_ms)
        return buf

    start = finish(two(659.3, 987.8, 75, 280, 0.055, 0.35, 1.0), 280, fade_out_ms=40)   # E5 -> B5
    stop = finish(two(987.8, 659.3, 75, 280, 0.055, 0.35, 0.9), 280, fade_out_ms=40)    # B5 -> E5
    cancel = finish(mallet(440, 150, 0.026, 0.2, 0.7), 150, fade_out_ms=35)             # one dull A4 knock
    err = np.zeros(int(SR * 0.36))
    place(err, mallet(311.1, 360, 0.05, 0.6), 0)       # Eb4
    place(err, 0.9 * mallet(277.2, 360, 0.06, 0.6), 130)  # Db4, a whole step down
    return {"start": start, "stop": stop, "cancel": cancel, "error": finish(err, 360, fade_out_ms=50)}


# ---------------------------------------------------------------- style 03: glass
def chime(freq: float, ms: float, tau: float, shimmer: float = 0.22) -> np.ndarray:
    """A struck-glass note: fundamental + inharmonic partial (x2.76) + a slightly detuned twin for a gentle beat."""
    t = t_axis(ms)
    note = np.sin(2 * np.pi * freq * t) + 0.35 * np.sin(2 * np.pi * freq * 1.004 * t + 1.1)
    note = note * np.exp(-t / tau)
    note += shimmer * np.sin(2 * np.pi * freq * 2.76 * t + 0.4) * np.exp(-t / (tau * 0.35))
    note *= np.minimum(1.0, t / 0.002)
    return note


def style_glass() -> dict[str, np.ndarray]:
    def pair(f_a: float, f_b: float, gap_ms: float, total: float, tau: float, shimmer: float) -> np.ndarray:
        buf = np.zeros(int(SR * total / 1000))
        place(buf, 0.85 * chime(f_a, total, tau, shimmer), 0)
        place(buf, chime(f_b, total, tau, shimmer), gap_ms)
        return buf

    start = finish(pair(880.0, 1318.5, 85, 360, 0.085, 0.22), 360, fade_out_ms=60)   # A5 -> E6
    stop = finish(pair(1318.5, 880.0, 85, 340, 0.075, 0.22), 340, fade_out_ms=60)    # E6 -> A5
    cancel = finish(chime(784.0, 190, 0.04, 0.12), 190, fade_out_ms=45)              # one short G5
    err = np.zeros(int(SR * 0.4))
    place(err, 0.9 * chime(587.3, 400, 0.09, 0.08), 0)    # D5
    place(err, chime(466.2, 400, 0.11, 0.08), 120)        # Bb4, a minor third down, duller
    return {"start": start, "stop": stop, "cancel": cancel, "error": finish(err, 400, fade_out_ms=70)}


# ---------------------------------------------------------------- style 04: sine
def blip(f_from: float, f_to: float, ms: float, harm2: float = 0.12) -> np.ndarray:
    """A smooth sine blip, optionally gliding f_from -> f_to, in a sin^2 window (no hard edges anywhere)."""
    n = int(SR * ms / 1000)
    pos = np.linspace(0, 1, n)
    glide = 0.5 - 0.5 * np.cos(np.pi * pos)
    freq = f_from + (f_to - f_from) * glide
    ph = sine_phase(freq)
    sig = np.sin(ph) + harm2 * np.sin(2 * ph)
    return sig * np.sin(np.pi * pos) ** 2


def style_sine() -> dict[str, np.ndarray]:
    start = finish(blip(440, 700, 110), 110, fade_in_ms=6, fade_out_ms=20)    # glide up
    stop = finish(blip(700, 440, 110), 110, fade_in_ms=6, fade_out_ms=20)     # glide down
    cancel = finish(blip(392, 392, 70, 0.08), 70, fade_in_ms=5, fade_out_ms=15)  # one flat G4 blip
    err = np.zeros(int(SR * 0.27))
    place(err, blip(294, 294, 100, 0.3), 0)       # D4
    place(err, blip(247, 247, 120, 0.3), 140)     # B3, a minor third lower, slightly longer
    return {"start": start, "stop": stop, "cancel": cancel, "error": finish(err, 270, fade_in_ms=6, fade_out_ms=25)}


# ---------------------------------------------------------------- io
STYLES = [
    ("wood", style_wood),
    ("glass", style_glass),
    ("sine", style_sine),
]


def write_wav(path: Path, x: np.ndarray) -> None:
    pcm = np.round(np.clip(x, -1, 1) * 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="folder for the WAV files")
    out = parser.parse_args().out
    out.mkdir(parents=True, exist_ok=True)
    for name, make in STYLES:
        for event, x in make().items():
            write_wav(out / f"{name}-{event}.wav", x)
            print(f"{name}-{event}.wav  {len(x) / SR * 1000:.0f} ms")


if __name__ == "__main__":
    main()
