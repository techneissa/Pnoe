# Pnoe sounds

Pnoe's own sound effects. They are synthesized from code (numpy maths, no samples, no recordings, no downloads), so there is no license question. The WAV files the app ships live in [`Pnoe/Resources/Sounds`](../../Pnoe/Resources/Sounds); the scripts here make them.

Every set has four sounds: `start`, `stop`, `cancel`, `error`, named `<set>-<event>.wav` (for example `kalimba-start.wav`). All are 48 kHz, mono, 16-bit and at most 400 ms.

| Script | Sets it makes |
|---|---|
| `generate_instruments.py` | `felt-piano`, `kalimba`, `vibes`, `harp`, `bloop`, `drop` (rms −25 dBFS, everything above 5 kHz filtered off) |
| `generate_tones.py` | `wood`, `glass`, `sine` (peak −12 dBFS) |
| `generate_prewarm.py` | `Pnoe/Resources/prewarm.wav`, one second of near-silence the app transcribes once to warm a model up. It is never played. |

The sets follow one rule: start rises, stop falls and lands lower and rounder, cancel is one short neutral note, error is two notes falling a semitone or a minor third.

## Regenerate

```sh
python3 -m pip install numpy scipy   # prewarm needs only the standard library
python3 design/sounds/generate_instruments.py
python3 design/sounds/generate_tones.py
python3 design/sounds/generate_prewarm.py
```

Each script writes into `Pnoe/Resources/Sounds` (or `--out DIR`). The output is deterministic: a rerun gives byte-identical files.

## Apple's sounds

The sounds in `/System/Library/Sounds` (Tink, Pop, Glass and the rest) are listed and played by name at runtime. They are never copied here or into the app: Apple's sounds may not be redistributed.
