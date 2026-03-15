# Vox

**Your voice, your machine, no one else's business.**

Vox is a fully offline, macOS-native voice-to-text app. Speak naturally and your words appear wherever the cursor is -- in any app, any text field. Everything runs locally on your Mac using whisper.cpp for speech recognition and an optional llama.cpp-powered AI cleanup pass.

## Features

- **Push-to-talk or toggle** -- Double-tap Right Option to start/stop, or hold it down, or toggle with a single tap
- **Works everywhere** -- Types into any app via Accessibility API with clipboard fallback
- **Fully offline** -- All processing happens on-device after the initial model download
- **AI cleanup** -- Optional LLM-powered pass removes filler words, fixes grammar, and cleans punctuation
- **Tiny footprint** -- Menu bar app with a floating waveform pill; no dock icon, no windows
- **Voice commands** -- Say "period", "comma", "new line", "new paragraph", and more for hands-free formatting

## Requirements

- macOS 13.0 (Ventura) or later
- Apple Silicon (M1 or newer)
- ~200 MB disk space for the base Whisper model (larger models available)
- Accessibility permission (for typing into other apps)
- Microphone permission

## Build from Source

```bash
# Clone with submodules (whisper.cpp + llama.cpp)
git clone --recursive https://github.com/your-org/vox-populi.git
cd vox-populi

# Install build tools
brew install xcodegen cmake

# Build native libraries (whisper.cpp and llama.cpp)
./Scripts/build-libraries.sh

# Generate Xcode project
xcodegen generate

# Open and build
open VoxPopuli.xcodeproj
```

Or build from the command line:

```bash
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli -configuration Release build
```

## Usage

1. Launch the app -- a small dot appears in your menu bar
2. **Double-tap Right Option** to start listening (dot turns green)
3. Speak naturally
4. **Tap Right Option again** to stop -- your text is typed at the cursor
5. Right-click the menu bar dot to open Settings

### Voice Commands

| Say this             | Inserts       |
|----------------------|---------------|
| period               | .             |
| comma                | ,             |
| question mark        | ?             |
| exclamation mark     | !             |
| colon                | :             |
| semicolon            | ;             |
| new line             | line break    |
| new paragraph        | double break  |
| open quote           | "             |
| close quote          | "             |
| open paren           | (             |
| close paren          | )             |

### Settings

Right-click the menu bar icon to access:

- **Whisper model** -- Choose from Tiny (75 MB) to Large v3 (3.1 GB) for accuracy vs. speed
- **Language** -- Auto-detect or select a specific language
- **Hotkey mode** -- Double-tap, hold-to-talk, or toggle
- **AI cleanup** -- Enable the LLM cleanup pass for polished output

## Privacy

Vox makes **zero network requests** after the initial model download. There is no analytics, no telemetry, no crash reporting, and no data collection of any kind. Your voice data never leaves your machine.

## License

MIT License. See [LICENSE](LICENSE) for details.
