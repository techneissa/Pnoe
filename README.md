<div align="center">
  <img src="Pnoe/Assets.xcassets/AppIcon.appiconset/256-mac.png" width="180" height="180" />
  <h1>Pnoe</h1>
  <p>Voice to text for macOS</p>

  [![License](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
  ![Platform](https://img.shields.io/badge/platform-macOS%2015.0%2B-brightgreen)
</div>

---

Pnoe (πνοή, "breath") is a native macOS app that turns what you say into text, almost instantly, in whatever app you are typing in.

Pnoe is based on [VoiceInk](https://github.com/Beingpax/VoiceInk) by Prakash Joshi Pax, under GPL-3.0. See [CREDITS.md](CREDITS.md).

## Features

- **Transcription**: local models (Whisper, Parakeet and others) or a cloud provider of your choice
- **Private by default**: with a local model, audio and text stay on your Mac
- **Modes**: settings that switch on their own based on the app or website you are in
- **Context awareness**: optional use of on-screen context to improve results
- **Global shortcuts**: keyboard or mouse shortcuts for toggle and push-to-talk recording
- **Personal dictionary**: custom words and text replacements, with Auto Learn from your corrections
- **AI enhancement**: clean up or rewrite a transcript with the LLM provider you configure

## Requirements

- macOS 15.0 or later
- Xcode with Command Line Tools, to build

## Build

```bash
git clone https://github.com/techneissa/Pnoe.git
cd Pnoe
make local
open ~/Downloads/Pnoe.app
```

See [BUILDING.md](BUILDING.md) for signing options, the development build and Xcode.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE).

## Acknowledgments

Pnoe's base is VoiceInk; [CREDITS.md](CREDITS.md) has the details and lists features taken from other projects.

### Core technology
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp): inference of OpenAI's Whisper model
- [FluidAudio](https://github.com/FluidInference/FluidAudio): Parakeet model implementation
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax (MIT): runs Whisper on Core ML and the Neural Engine, with the Core ML builds from [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml)
- [TranscribeCpp for Swift](https://github.com/Beingpax/Transcribe-cpp-swift): SwiftPM distribution of [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), used for local GGUF transcription models
- [SenseVoice Small](https://huggingface.co/FunAudioLLM/SenseVoiceSmall) by FunAudioLLM / Alibaba: multilingual model under the [FunASR Model Open Source License Agreement](https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE)

### Dependencies
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts): user-customizable keyboard shortcuts
- [LaunchAtLogin](https://github.com/sindresorhus/LaunchAtLogin): launch at login
- [Zip](https://github.com/marmelroy/Zip): file compression and decompression
- [SelectedTextKit](https://github.com/tisfeng/SelectedTextKit): reading the selected text
- [Swift Atomics](https://github.com/apple/swift-atomics): atomic operations
