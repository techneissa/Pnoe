# Credits

## Base

Pnoe is built on [VoiceInk](https://github.com/Beingpax/VoiceInk) by Prakash Joshi Pax, licensed under GPL-3.0. Pnoe started from VoiceInk commit [`d791c15a`](https://github.com/Beingpax/VoiceInk/commit/d791c15a) and has been developed separately since. Pnoe is distributed under the same license; see [LICENSE](LICENSE).

## Borrowed features

Each feature taken from another project gets one line in this format:

`- [Project](link), License: what was taken`

- [betterwispr](https://github.com/opennookorg/betterwispr), Apache-2.0: the “Learned” toast with an Undo button that Auto Learn shows after it saves a correction (Pnoe's toast is its own code, built on its existing notification), and the idea of the word-diff acceptance rule (reply length bounds, share of new content words, a spoken question mark must survive) and the filler and repeated-word cleanup logic, both reimplemented in Swift in `Packages/PnoeFormatter`, plus stripping section tags from user text before it goes into a prompt.
- [FluidVoice](https://github.com/altic-dev/FluidVoice), GPL-3.0: sending the transcript to the model as a JSON `{"transcript": …}` envelope, and the occurrence counter behind Auto Learn (save a correction only after the same heard text was changed to the same corrected text a set number of times, with a 1 to 3 setting there, stale counts expiring and a cap on stored pairs), reimplemented in `Shared/CorrectionCounter.swift` with its own limits and file store.
- [Handy](https://github.com/cjpais/Handy), MIT: the transcript envelope and restating the rule after the transcript.
- [OpenWhispr](https://github.com/OpenWhispr/openwhispr), MIT: restating the rule after the transcript, the worked example of an injected instruction that comes back unchanged, and the idea of snippets (spoken trigger phrases that insert saved text; behavior only, Pnoe's code is its own).
- [TypeWhisper](https://github.com/TypeWhisper/typewhisper-mac), GPL-3.0: sanitizing model wrappers before paste, the lesson to apply dictionary fixes before the model, and the idea of a live transcript preview in the recording indicator with theme, placement and visibility choices, of the Pill and Dot indicator styles, and of configurable left and right side slots (concept only; Pnoe's indicator design and code are its own), and of a Workflows screen with a compact template picker for new workflows (concept only; Pnoe's layout, wording and code are its own).
- Ideas only, no code: [VoiceTypr](https://github.com/ideaplexa/voicetypr) (output guard classes, skip rule for short takes), [Whispering](https://github.com/EpicenterHQ/epicenter) (temperature 0), [Murmure](https://github.com/Kieirra/murmure) (output cap tied to input length).

## Not part of Pnoe

- VoiceInk Refine: VoiceInk's AI cleanup model (`beingpax/VoiceInk-Refine-V1`). Its weights are licensed for use with VoiceInk only, so Pnoe does not download, run or ship them. Pnoe removed the option that VoiceInk had.

## Sounds

- Pnoe's sound sets (Felt piano, Kalimba, Vibes, Harp, Bloop, Drop, Wood, Glass, Sine) are original Pnoe sounds, generated from code by the scripts in [`design/sounds`](design/sounds). They use no samples or recordings. VoiceInk's seven sound files were removed.
- The macOS sounds offered in the sound pickers (Basso, Blow, Bottle, Frog, Funk, Glass, Hero, Morse, Ping, Pop, Purr, Sosumi, Submarine, Tink) belong to Apple. Pnoe plays them from `/System/Library/Sounds` with `NSSound(named:)` and does not bundle or copy them.
