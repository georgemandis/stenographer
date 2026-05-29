# stenographer

Speech-to-text from the command line, powered by native macOS Speech Recognition.

Transcribe audio files or live microphone input into text. Supports 63 languages, on-device recognition (no network required), and partial results for real-time transcription. No API keys, no downloads — uses Apple's built-in speech recognizer.

Written in Zig. Uses Apple's Speech and AVFoundation frameworks via Objective-C runtime bindings.

## Install

```bash
zig build -Doptimize=ReleaseFast
cp zig-out/bin/stenographer /usr/local/bin/
```

## Usage

### Transcribe an audio file

```bash
$ stenographer transcribe recording.wav
Hello world this is a test of the sound classification system

$ stenographer transcribe interview.mp3 --json
{"text":"Hello world this is a test of the sound classification system"}

$ stenographer transcribe podcast.m4a --on-device
# Forces on-device recognition (no network, lower latency)
```

### Transcribe from the microphone

```bash
$ stenographer listen
Listening for 10.0s...
The quick brown fox jumps over the lazy dog

$ stenographer listen --duration=5000
Listening for 5.0s...
Hello world

$ stenographer listen --duration=30000 --json
Listening for 30.0s...
{"text":"This is a longer recording with multiple sentences"}
```

### Multi-language support

```bash
$ stenographer transcribe french_audio.aiff --locale=fr-FR
Bonjour le monde comment allez-vous aujourd'hui

$ stenographer transcribe japanese.wav --locale=ja-JP --on-device

$ stenographer locales
ar-SA
ca-ES
cs-CZ
da-DK
de-AT
de-CH
de-DE
...
zh-TW

$ stenographer locales --json
["ar-SA","ca-ES","cs-CZ",...]
```

## Composability

```bash
# Transcribe then detect language
stenographer transcribe audio.wav | lingua detect

# Transcribe and extract entities
stenographer transcribe meeting.wav | lingua entities

# Transcribe and analyze sentiment
stenographer transcribe review.wav | lingua sentiment --per-sentence

# Save a transcript to a file
stenographer transcribe meeting.wav --on-device > transcript.txt
```

## Options

```
stenographer <command> [options]

Commands:
  transcribe <file>  Transcribe an audio file
  listen             Transcribe from the microphone
  locales            List supported languages

Options:
  --locale=CODE      Language locale (default: en-US)
  --on-device        Force on-device recognition (no network)
  --duration=MS      Listen duration in ms (default: 10000)
  --json             Output as JSON
  --help, -h         Show this help message
  --version, -v      Show version
```

## Requirements

- macOS 10.15+ (Catalina or later)
- Zig 0.16+
- Speech recognition permission (prompted on first use)
- For `--on-device`: macOS will download language models as needed

## How It Works

stenographer uses Apple's [Speech](https://developer.apple.com/documentation/speech) framework with `SFSpeechRecognizer` for both file and live transcription.

- **File transcription:** `SFSpeechURLRecognitionRequest` loads audio files and runs recognition via a result handler block
- **Live mic:** `AVAudioEngine` captures microphone input, feeding buffers to `SFSpeechAudioBufferRecognitionRequest`
- **Block ABI:** ObjC block construction (`_NSConcreteStackBlock` / `_NSConcreteGlobalBlock`) for recognition result handlers and audio tap callbacks
- **Run loop:** `CFRunLoopRunInMode` pumps the event loop for async recognition callbacks

## Related Projects

- [lingua](https://github.com/georgemandis/lingua) — NLP CLI (NaturalLanguage framework)
- [cacophony](https://github.com/georgemandis/cacophony) — Sound classification CLI (SoundAnalysis framework)
- [tezcatl](https://github.com/georgemandis/tezcatl) — Headless web rendering CLI (WebKit)
- [loupe](https://github.com/georgemandis/loupe) — Computer vision CLI (Vision framework)
- [whereami](https://github.com/georgemandis/whereami) — Location CLI (CoreLocation)
- [nearme](https://github.com/georgemandis/nearme) — Local search CLI (MapKit)

## Credits

Created by [George Mandis](https://george.mand.is) during [Recurse Center](https://www.recurse.com/).
