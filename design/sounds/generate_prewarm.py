#!/usr/bin/env python3
"""Writes prewarm.wav: one second of near-silence (16 kHz, mono, 16-bit, about -70 dBFS noise).

The app transcribes it once after a model loads, to warm the model up. It is never played.
The noise is seeded, so a rerun gives an identical file.

Run:  python3 generate_prewarm.py [--out FILE]     (standard library only; FILE defaults to Pnoe/Resources/prewarm.wav)
"""
import argparse
import random
import struct
import wave
from pathlib import Path

SR = 16_000
SECONDS = 1.0
AMPLITUDE = 10  # of 32767, about -70 dBFS
DEFAULT_OUT = Path(__file__).resolve().parent.parent.parent / "Pnoe" / "Resources" / "prewarm.wav"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="WAV file to write")
    out = parser.parse_args().out
    rng = random.Random(7)
    samples = [rng.randint(-AMPLITUDE, AMPLITUDE) for _ in range(int(SR * SECONDS))]
    out.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(out), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(struct.pack(f"<{len(samples)}h", *samples))
    print(f"{out.name}  {SECONDS * 1000:.0f} ms")


if __name__ == "__main__":
    main()
