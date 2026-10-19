# Credits

## Base

Pnoe is built on [VoiceInk](https://github.com/Beingpax/VoiceInk) by Prakash Joshi Pax, licensed under GPL-3.0. Pnoe started from VoiceInk commit [`d791c15a`](https://github.com/Beingpax/VoiceInk/commit/d791c15a) and has been developed separately since. Pnoe is distributed under the same license; see [LICENSE](LICENSE).

## Borrowed features

Each feature taken from another project gets one line in this format:

`- [Project](link), License: what was taken`

None yet.

## Sounds

- Pnoe's sound sets (Felt piano, Kalimba, Vibes, Harp, Bloop, Drop, Wood, Glass, Sine) are original Pnoe sounds, generated from code by the scripts in [`design/sounds`](design/sounds). They use no samples or recordings. VoiceInk's seven sound files were removed.
- The macOS sounds offered in the sound pickers (Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink) belong to Apple. Pnoe plays them from `/System/Library/Sounds` with `NSSound(named:)` and does not bundle or copy them.
