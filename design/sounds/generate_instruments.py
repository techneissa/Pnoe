#!/usr/bin/env python3
"""Pnoe sound sets Felt piano, Kalimba, Vibes, Harp, Bloop and Drop: 6 instrument sets x 4 events, synthesized from nothing.

No samples, no recordings, no downloads, no noise-as-sound: every note is a few partials, a pitch curve
or a filtered oscillator. Output: <out>/<set>-<event>.wav  (48 kHz, mono, 16-bit, rms -25 dBFS).

Run:  python3 generate_instruments.py [--out DIR]     (needs numpy and scipy; DIR defaults to Pnoe/Resources/Sounds)
"""
from __future__ import annotations

import argparse
import wave
from pathlib import Path

import numpy as np
from scipy.signal import butter, sosfiltfilt

SR = 48_000
RMS_DBFS = -25.0          # matches r1 Wood and Glass
LOWPASS_HZ = 5000         # nothing above this survives; the 6 kHz limit then holds with margin
DEFAULT_OUT = Path(__file__).resolve().parent.parent.parent / "Pnoe" / "Resources" / "Sounds"
RNG_SEED = 31


# ---------------------------------------------------------------- helpers
def hz(name: str) -> float:
    """Note name like 'C4', 'F#5', 'Bb3' -> Hz (A4 = 440)."""
    steps = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}
    n = steps[name[0]]
    rest = name[1:]
    while rest[0] in "#b":
        n += 1 if rest[0] == "#" else -1
        rest = rest[1:]
    midi = 12 * (int(rest) + 1) + n
    return 440.0 * 2 ** ((midi - 69) / 12)


def t_axis(ms: float) -> np.ndarray:
    return np.arange(int(round(SR * ms / 1000))) / SR


def rise(n: int) -> np.ndarray:
    return 0.5 - 0.5 * np.cos(np.pi * np.arange(n) / max(n - 1, 1))


def attack(t: np.ndarray, ms: float) -> np.ndarray:
    """Soft raised-cosine attack; never a step."""
    n = max(int(SR * ms / 1000), 2)
    env = np.ones(len(t))
    env[:n] = rise(n)[: len(t)]
    return env


def place(buf: np.ndarray, sig: np.ndarray, at_ms: float, gain: float = 1.0) -> None:
    i = int(round(SR * at_ms / 1000))
    j = min(len(buf), i + len(sig))
    buf[i:j] += gain * sig[: j - i]


def lowpass(x: np.ndarray, hz_: float, order: int = 4) -> np.ndarray:
    return sosfiltfilt(butter(order, hz_, "lowpass", fs=SR, output="sos"), x)


def finish(x: np.ndarray, total_ms: float, fade_in_ms: float = 4, fade_out_ms: float = 40) -> np.ndarray:
    """Pad or trim to total_ms, drop rumble above 5 kHz and below 70 Hz, fade both ends, set rms to -25 dBFS."""
    n = int(round(SR * total_ms / 1000))
    x = np.pad(x, (0, max(0, n - len(x))))[:n]
    x = lowpass(x, LOWPASS_HZ)
    x = sosfiltfilt(butter(2, 70, "highpass", fs=SR, output="sos"), x)
    fi, fo = int(SR * fade_in_ms / 1000), int(SR * fade_out_ms / 1000)
    x = x * np.concatenate([rise(fi), np.ones(n - fi - fo), rise(fo)[::-1]])
    x *= 10 ** (RMS_DBFS / 20) / np.sqrt(np.mean(x**2))
    return x


def seq(total_ms: float, notes: list[tuple[float, np.ndarray, float]]) -> np.ndarray:
    """Mix (start_ms, signal, gain) notes into one buffer."""
    buf = np.zeros(int(round(SR * total_ms / 1000)))
    for at, sig, g in notes:
        place(buf, sig, at, g)
    return buf


# ---------------------------------------------------------------- instruments
def piano(f: float, ms: float, tau: float, bright: float) -> np.ndarray:
    """Felt-damped piano: 7 stretched partials, higher ones falling off fast, two slightly detuned strings, soft hammer."""
    t = t_axis(ms)
    out = np.zeros(len(t))
    for n in range(1, 8):
        fn = n * f * np.sqrt(1 + 0.0003 * n * n)
        amp = bright ** (n - 1) / n**0.6
        dec = np.exp(-t / (tau / (1 + 0.45 * (n - 1))))
        out += amp * dec * (np.sin(2 * np.pi * fn * t) + 0.8 * np.sin(2 * np.pi * fn * 1.0006 * t + 0.7))
    rng = np.random.default_rng(RNG_SEED + int(f))
    thud = lowpass(rng.standard_normal(len(t)), 450, 2) * np.exp(-t / 0.010)
    out += 0.05 * thud * np.max(np.abs(out))
    return out * attack(t, 9)


def kalimba(f: float, ms: float, tau: float) -> np.ndarray:
    """Thumb-piano tine: fundamental, a little octave from the wooden box, and a quick-dying bent-bar overtone (x6.27)."""
    t = t_axis(ms)
    out = np.exp(-t / tau) * np.sin(2 * np.pi * f * t)
    out += 0.22 * np.exp(-t / (tau * 0.6)) * np.sin(2 * np.pi * 2 * f * t + 0.3)
    out += 0.16 * np.exp(-t / (tau * 0.12)) * np.sin(2 * np.pi * 6.27 * f * t + 1.0)
    return out * attack(t, 8)


def vibes(f: float, ms: float, tau: float, motor: float = 0.14) -> np.ndarray:
    """Vibraphone bar struck with a soft mallet: partials 1 : 4 : 10, a gentle 5 Hz motor tremolo."""
    t = t_axis(ms)
    out = np.exp(-t / tau) * np.sin(2 * np.pi * f * t)
    out += 0.20 * np.exp(-t / (tau * 0.45)) * np.sin(2 * np.pi * 4.0 * f * t + 0.5)
    out += 0.04 * np.exp(-t / (tau * 0.15)) * np.sin(2 * np.pi * 10.0 * f * t)
    return out * (1 + motor * np.sin(2 * np.pi * 5 * t - np.pi / 2)) * attack(t, 7)


def harp(f: float, ms: float, tau: float, harmonic: bool = False) -> np.ndarray:
    """Plucked string: partials weighted by pluck position (1/5 along the string), higher ones decaying faster.
    harmonic=True is a flageolet: nearly a pure sine with a faint octave."""
    t = t_axis(ms)
    if harmonic:
        out = np.exp(-t / tau) * (np.sin(2 * np.pi * f * t) + 0.10 * np.sin(2 * np.pi * 2 * f * t + 0.4))
        return out * attack(t, 8)
    out = np.zeros(len(t))
    for n in range(1, 9):
        w = abs(np.sin(n * np.pi * 0.2)) / n**1.3
        out += w * np.exp(-t / (tau / (1 + 0.55 * (n - 1)))) * np.sin(2 * np.pi * n * f * 1.0002**(n * n) * t + 0.2 * n)
    return out * attack(t, 8)


def svf_lowpass(x: np.ndarray, fc: np.ndarray, q: float) -> np.ndarray:
    """State-variable lowpass with a moving cutoff (Hz per sample)."""
    out = np.empty_like(x)
    low = band = 0.0
    damp = 1.0 / q
    k = 2 * np.sin(np.pi * np.minimum(fc, 0.24 * SR) / SR)
    for i in range(len(x)):
        low += k[i] * band
        high = x[i] - low - damp * band
        band += k[i] * high
        out[i] = low
    return out


def ease(t: np.ndarray, t0: float, t1: float) -> np.ndarray:
    """0 before t0, 1 after t1, smooth in between."""
    u = np.clip((t - t0) / (t1 - t0), 0, 1)
    return 0.5 - 0.5 * np.cos(np.pi * u)


def bloop(f0: float, f1: float, glide_ms: float, ms: float, tau: float, cut0: float, cut1: float, cut2: float,
          open_ms: float = 90, q: float = 1.3) -> np.ndarray:
    """Warm soft-synth note: band-limited saw plus a quiet sub, pitch gliding f0 -> f1, filter opening cut0 -> cut1 then settling to cut2."""
    t = t_axis(ms)
    f = f0 * (f1 / f0) ** ease(t, 0, glide_ms / 1000)
    ph = 2 * np.pi * np.cumsum(f) / SR
    saw = sum(np.sin(k * ph) / k for k in range(1, 13)) + 0.35 * np.sin(0.5 * ph)
    cut = cut0 + (cut1 - cut0) * ease(t, 0, open_ms / 1000)
    cut = cut + (cut2 - cut1) * ease(t, open_ms / 1000, ms / 1000)
    body = svf_lowpass(saw, cut, q)
    return body * np.exp(-t / tau) * attack(t, 12)


def drop(f0: float, f1: float, ms: float, tau: float, chirp_tau: float = 0.03) -> np.ndarray:
    """A soft water-drop 'plip': a sine whose pitch glides f0 -> f1 (up for a drop, down for a swallow), plus a faint octave."""
    t = t_axis(ms)
    f = f0 * (f1 / f0) ** (1 - np.exp(-t / chirp_tau))
    ph = 2 * np.pi * np.cumsum(f) / SR
    return (np.sin(ph) + 0.10 * np.sin(2 * ph)) * np.exp(-t / tau) * attack(t, 7)


# ---------------------------------------------------------------- sets
# Each set returns start / stop / cancel / error. Contours: start rises, stop falls and lands lower and rounder,
# cancel is one neutral note, error is two notes falling by a semitone or a minor third.
def set_piano() -> dict[str, np.ndarray]:
    L = 380
    start = seq(330, [(0, piano(hz("C4"), L, .075, .50), .85), (62, piano(hz("E4"), L, .08, .55), .9),
                      (124, piano(hz("G4"), L, .10, .62), 1.0)])
    stop = seq(350, [(0, piano(hz("G4"), L, .08, .42), 1.0), (70, piano(hz("E4"), L, .09, .36), .9),
                     (140, piano(hz("C4"), L, .14, .28), 1.0)])
    cancel = piano(hz("E4"), 160, .045, .30)
    error = seq(380, [(0, piano(hz("F4"), L, .08, .38), 1.0), (135, piano(hz("D4"), L, .10, .32), .95)])
    return {"start": finish(start, 330, fade_out_ms=70), "stop": finish(stop, 350, fade_out_ms=80),
            "cancel": finish(cancel, 150, fade_out_ms=40), "error": finish(error, 380, fade_out_ms=80)}


def set_kalimba() -> dict[str, np.ndarray]:
    start = seq(300, [(0, kalimba(hz("E4"), 300, .075), .9), (85, kalimba(hz("C#5"), 300, .085), 1.0)])
    stop = seq(340, [(0, kalimba(hz("C#5"), 340, .07), .9), (90, kalimba(hz("A4"), 340, .13), 1.0)])
    cancel = kalimba(hz("B4"), 150, .03)
    error = seq(380, [(0, kalimba(hz("G4"), 380, .08), 1.0), (125, kalimba(hz("E4"), 380, .10), .95)])
    return {"start": finish(start, 300, fade_out_ms=60), "stop": finish(stop, 340, fade_out_ms=80),
            "cancel": finish(cancel, 140, fade_out_ms=40), "error": finish(error, 380, fade_out_ms=80)}


def set_vibes() -> dict[str, np.ndarray]:
    start = seq(340, [(0, vibes(hz("Bb4"), 340, .11), .9), (90, vibes(hz("Eb5"), 340, .13), 1.0)])
    stop = seq(350, [(0, vibes(hz("Bb4"), 350, .10), 1.0), (95, vibes(hz("Eb4"), 350, .17), 1.0)])
    cancel = vibes(hz("G4"), 160, .05, 0)
    error = seq(390, [(0, vibes(hz("C5"), 390, .10), 1.0), (120, vibes(hz("A4"), 390, .13), .95)])
    return {"start": finish(start, 340, fade_out_ms=80), "stop": finish(stop, 350, fade_out_ms=90),
            "cancel": finish(cancel, 150, fade_out_ms=45), "error": finish(error, 390, fade_out_ms=90)}


def set_harp() -> dict[str, np.ndarray]:
    start = seq(280, [(0, harp(hz("G4"), 280, .09), .8), (70, harp(hz("G5"), 280, .075, True), 1.0)])
    stop = seq(300, [(0, harp(hz("D5"), 300, .08), .9), (80, harp(hz("G4"), 300, .12), 1.0)])
    cancel = harp(hz("A4"), 140, .035)
    error = seq(360, [(0, harp(hz("Ab4"), 360, .08), 1.0), (110, harp(hz("G4"), 360, .09), 1.0)])
    return {"start": finish(start, 280, fade_out_ms=60), "stop": finish(stop, 300, fade_out_ms=70),
            "cancel": finish(cancel, 130, fade_out_ms=40), "error": finish(error, 360, fade_out_ms=80)}


def set_bloop() -> dict[str, np.ndarray]:
    start = bloop(hz("C4"), hz("G4"), 150, 280, .12, 500, 2300, 1100)
    stop = bloop(hz("G4"), hz("B3") * 1.0, 190, 340, .15, 2200, 700, 420, open_ms=60)
    cancel = bloop(330, 300, 60, 150, .045, 900, 900, 600, open_ms=40, q=1.0)
    e1 = bloop(hz("D4"), hz("D4") * .96, 70, 190, .07, 1100, 900, 500, open_ms=50, q=1.0)
    e2 = bloop(hz("B3"), hz("B3") * .96, 80, 230, .09, 900, 750, 420, open_ms=50, q=1.0)
    error = seq(390, [(0, e1, 1.0), (140, e2, 1.0)])
    return {"start": finish(start, 280, fade_out_ms=70), "stop": finish(stop, 340, fade_out_ms=90),
            "cancel": finish(cancel, 150, fade_out_ms=50), "error": finish(error, 390, fade_out_ms=90)}


def set_drop() -> dict[str, np.ndarray]:
    start = seq(300, [(0, drop(450, 700, 300, .05), .9), (95, drop(720, 1150, 300, .065), 1.0)])
    stop = seq(340, [(0, drop(1100, 760, 340, .05, .05), .9), (100, drop(720, 430, 340, .09, .06), 1.0)])
    cancel = drop(520, 600, 150, .03)
    error = seq(390, [(0, drop(440, 470, 390, .07), 1.0), (135, drop(370, 395, 390, .09), 1.0)])
    return {"start": finish(start, 300, fade_out_ms=70), "stop": finish(stop, 340, fade_out_ms=90),
            "cancel": finish(cancel, 130, fade_out_ms=45), "error": finish(error, 390, fade_out_ms=90)}


SETS = [
    ("felt-piano", set_piano),
    ("kalimba", set_kalimba),
    ("vibes", set_vibes),
    ("harp", set_harp),
    ("bloop", set_bloop),
    ("drop", set_drop),
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
    for name, make in SETS:
        for event, x in make().items():
            write_wav(out / f"{name}-{event}.wav", x)
            print(f"{name}-{event}.wav  {len(x) / SR * 1000:.0f} ms")


if __name__ == "__main__":
    main()
