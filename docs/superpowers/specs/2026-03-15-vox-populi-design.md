# Vox Populi — Design Specification

**Date:** 2026-03-15
**Status:** Approved
**Author:** Claude Opus 4.6 + Tony Boudreau

## Overview

Vox Populi is a macOS-native, fully offline, open-source voice-to-text application. Users press a hotkey, speak, and text appears at their cursor in any application. It uses OpenAI's Whisper model (via whisper.cpp) for transcription and optionally a local LLM (via llama.cpp) for AI post-processing — all running on Apple Silicon with Metal acceleration.

**Mission:** Make high-quality voice input free and accessible to everyone. No accounts, no cloud, no subscriptions.

**Primary use case:** Developers dictating prompts, messages, and technical content into tools like Claude Code, terminals, editors, and chat apps.

## Core User Experience

### The Flow

1. User double-taps `Fn` (configurable hotkey)
2. A small floating pill (~120x36px) appears near the cursor with a live waveform
3. User speaks naturally
4. User releases `Fn` (or taps again in toggle mode)
5. Audio is transcribed by Whisper (Metal-accelerated)
6. Optionally, transcription is cleaned up by a local LLM
7. Text is typed at the cursor position via macOS Accessibility API
8. Floating pill fades away

**Target latency:** <1 second from end of speech to text appearing (with `base` model), <2 seconds with `large-v3`.

### Hotkey Behavior

- **Default:** Double-tap `Fn` to start, single tap `Fn` to stop
- **Alternative modes:** Hold-to-talk (hold key, speak, release), Toggle (tap to start, tap to stop)
- Hotkey is globally registered — works regardless of which app is focused
- Implemented via CGEvent tap (requires Accessibility permission)

## Architecture

### System Components

```
┌─────────────────────────────────────────────┐
│              VoxPopuli.app                   │
│                                              │
│  ┌─────────────┐    ┌────────────────────┐   │
│  │  AppDelegate │    │  MenuBarController │   │
│  │  (lifecycle) │    │  (status dot + UI) │   │
│  └──────┬──────┘    └─────────┬──────────┘   │
│         │                     │              │
│  ┌──────▼──────┐    ┌─────────▼──────────┐   │
│  │  HotkeyMgr  │    │   SettingsView     │   │
│  │  (CGEvent)  │    │   (SwiftUI popover)│   │
│  └──────┬──────┘    └────────────────────┘   │
│         │                                    │
│  ┌──────▼──────────────────────────────┐     │
│  │         AudioPipeline               │     │
│  │  AVAudioEngine → ring buffer → VAD  │     │
│  └──────┬──────────────────────────────┘     │
│         │                                    │
│  ┌──────▼──────────────────────────────┐     │
│  │       WhisperEngine                 │     │
│  │  whisper.cpp (Swift binding, Metal) │     │
│  └──────┬──────────────────────────────┘     │
│         │                                    │
│  ┌──────▼──────────────────────────────┐     │
│  │       TextProcessor (optional)      │     │
│  │  llama.cpp (Swift binding, Metal)   │     │
│  │  Cleanup: filler words, grammar,    │     │
│  │  punctuation, prompt sharpening     │     │
│  └──────┬──────────────────────────────┘     │
│         │                                    │
│  ┌──────▼──────────────────────────────┐     │
│  │       TextOutput                    │     │
│  │  Primary: AXUIElement (Accessibility)│    │
│  │  Fallback: NSPasteboard + Cmd+V     │     │
│  └─────────────────────────────────────┘     │
│                                              │
│  ┌─────────────────────────────────────┐     │
│  │       ModelManager                  │     │
│  │  Download, verify, store, select    │     │
│  └─────────────────────────────────────┘     │
│                                              │
│  ┌─────────────────────────────────────┐     │
│  │       FloatingPill                  │     │
│  │  NSPanel (non-activating, floating) │     │
│  │  Frosted glass + waveform viz       │     │
│  └─────────────────────────────────────┘     │
└─────────────────────────────────────────────┘
```

### Component Details

#### HotkeyManager
- Registers a global CGEvent tap for the configured hotkey
- Supports three modes: double-tap, hold-to-talk, toggle
- Requires Accessibility permission (prompts on first launch)
- Debounces to prevent accidental triggers

#### AudioPipeline
- Uses AVAudioEngine for mic capture (16kHz, mono, Float32 — Whisper's native format)
- Ring buffer accumulates audio while user speaks
- Simple energy-based Voice Activity Detection (VAD) to trim silence
- Handles mic permission request on first use

#### WhisperEngine
- Wraps whisper.cpp compiled as a Swift package with Metal support
- Loads model into memory on app launch (stays resident for fast inference)
- Processes audio buffer → returns transcribed text with timestamps
- Supports language auto-detection or fixed language setting
- Built-in voice commands: "new line" → \n, "new paragraph" → \n\n, punctuation words

#### TextProcessor (AI Cleanup — Optional)
- Wraps llama.cpp compiled as a Swift package with Metal support
- Uses a small model (~3B parameters, e.g., Llama 3.2 3B or Phi-3 mini)
- System prompt: "Clean up this voice transcription. Remove filler words (uh, um, like, you know), fix grammar and punctuation, keep the speaker's intent and tone intact. Do not add or change meaning. Output only the cleaned text."
- Toggled on/off from settings (OFF by default)
- Model downloaded separately only when first toggled on

#### TextOutput
- **Primary method:** macOS Accessibility API (AXUIElement) — finds the focused text field and inserts text directly
- **Fallback:** Copies text to clipboard and simulates Cmd+V via CGEvent
- Fallback activates automatically for apps that block accessibility insertion (e.g., some Electron apps)

#### ModelManager
- Downloads models from Hugging Face (whisper.cpp GGML format, llama.cpp GGUF format)
- Stores in `~/Library/Application Support/VoxPopuli/models/`
- Verifies SHA256 checksums after download
- Shows download progress in menu bar
- First launch auto-downloads `base` Whisper model (~150MB)
- Supports models: tiny (~75MB), base (~150MB), small (~500MB), medium (~1.5GB), large-v3 (~3GB)

#### FloatingPill
- NSPanel with `.nonactivatingPanel` and `.floating` style masks (doesn't steal focus)
- Frosted glass background (NSVisualEffectView with .hudWindow material)
- Real-time waveform visualization driven by audio buffer RMS values
- Positioned near the cursor (offset slightly so it doesn't obscure text)
- Fade-in on hotkey press, fade-out on completion
- ~120x36px, rounded corners

#### MenuBarController
- NSStatusItem with a custom dot icon
- **Idle:** Static dot
- **Listening:** Gentle pulse animation
- **Processing:** Spinning animation
- **Downloading:** Progress indicator
- Left-click: Toggle listening (alternative to hotkey)
- Right-click (or left-click when idle): Opens settings popover

#### SettingsView (SwiftUI Popover)
- **Hotkey:** Picker with recorder (press keys to set)
- **Model:** Dropdown — tiny / base / small / medium / large-v3 (with download buttons)
- **Language:** Auto-detect or select from list
- **AI Cleanup:** Toggle on/off (downloads model on first enable)
- Settings stored in UserDefaults
- That's it. Four settings. Clean, minimal.

## Data Flow

```
Hotkey pressed
    │
    ▼
AudioPipeline.startCapture()
FloatingPill.show(near: cursorPosition)
MenuBar.setState(.listening)
    │
    ▼
[User speaks — audio accumulates in ring buffer]
[FloatingPill waveform animates from RMS values]
    │
    ▼
Hotkey released / VAD silence detected
    │
    ▼
AudioPipeline.stopCapture() → audioBuffer
FloatingPill.setState(.processing)
MenuBar.setState(.processing)
    │
    ▼
WhisperEngine.transcribe(audioBuffer) → rawText
    │
    ▼
[if AI cleanup enabled]
TextProcessor.cleanup(rawText) → cleanedText
[else]
cleanedText = rawText
    │
    ▼
TextOutput.type(cleanedText)
FloatingPill.fadeOut()
MenuBar.setState(.idle)
```

## First Launch Experience

1. App opens — no window appears, just the menu bar dot
2. System prompts for **Microphone** permission → user grants
3. System prompts for **Accessibility** permission → user grants (required for hotkey + text insertion)
4. Menu bar dot shows download progress as `base` model downloads (~150MB)
5. Download complete → dot goes idle
6. User double-taps Fn → it works
7. Total time from install to first transcription: ~60 seconds on decent internet

No onboarding wizard. No tutorial. No "create account." The two OS permission dialogs are unavoidable, everything else is.

## Voice Commands

Built into WhisperEngine post-processing (no AI model needed):

| Voice | Output |
|-------|--------|
| "new line" | `\n` |
| "new paragraph" | `\n\n` |
| "period" / "full stop" | `.` |
| "comma" | `,` |
| "question mark" | `?` |
| "exclamation mark" / "exclamation point" | `!` |
| "colon" | `:` |
| "semicolon" | `;` |
| "open quote" / "close quote" | `"` |
| "open paren" / "close paren" | `(` / `)` |

## Tech Stack

| Component | Technology | Reason |
|-----------|-----------|--------|
| Language | Swift 5.9+ | Native macOS, first-class Metal support |
| UI | SwiftUI | Minimal UI, fast to build, native feel |
| Floating panel | AppKit (NSPanel) | SwiftUI can't do non-activating floating panels |
| Audio | AVFoundation / AVAudioEngine | Apple's audio framework, low-latency |
| Transcription | whisper.cpp (C++) | Best Whisper implementation, Metal support |
| AI cleanup | llama.cpp (C++) | Best local LLM runtime, Metal support |
| Build system | Swift Package Manager | No external dependency managers |
| Hotkey | CGEvent tap | Only way to do global hotkeys on macOS |
| Text insertion | Accessibility API (AXUIElement) | System-level text input |
| Storage | UserDefaults + filesystem | No database needed |

## Project Structure

```
vox-populi/
├── VoxPopuli/
│   ├── App/
│   │   ├── VoxPopuliApp.swift          # @main, app lifecycle
│   │   └── AppDelegate.swift           # NSApplicationDelegate, menu bar setup
│   ├── Core/
│   │   ├── HotkeyManager.swift         # Global hotkey registration
│   │   ├── AudioPipeline.swift         # Mic capture, ring buffer, VAD
│   │   ├── WhisperEngine.swift         # whisper.cpp Swift wrapper
│   │   ├── TextProcessor.swift         # llama.cpp Swift wrapper (AI cleanup)
│   │   ├── TextOutput.swift            # Accessibility API text insertion
│   │   └── ModelManager.swift          # Model download and management
│   ├── UI/
│   │   ├── MenuBarController.swift     # Status item + animations
│   │   ├── FloatingPill.swift          # NSPanel waveform overlay
│   │   ├── SettingsView.swift          # SwiftUI settings popover
│   │   └── WaveformView.swift          # Audio waveform visualization
│   └── Resources/
│       ├── Assets.xcassets              # App icon, menu bar icons
│       └── Info.plist                   # Permissions descriptions
├── Libraries/
│   ├── whisper.cpp/                    # Git submodule
│   └── llama.cpp/                      # Git submodule
├── Package.swift                        # SPM manifest
├── LICENSE                              # MIT
├── README.md
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-03-15-vox-populi-design.md
```

## Distribution

- **GitHub Releases:** Signed .dmg with the app bundle
- **Homebrew:** `brew install --cask vox-populi`
- **License:** MIT
- **Min macOS:** 13.0 (Ventura) — for Metal 3 and modern SwiftUI
- **Min hardware:** Any Apple Silicon Mac (M1+)

## Error Handling

- **No mic permission:** Menu bar dot turns red, clicking shows "Microphone access required" with button to open System Settings
- **No accessibility permission:** Same pattern, explains why it's needed
- **Model download fails:** Retry button in menu bar, works offline with whatever model is already downloaded
- **Whisper fails:** Silent failure, no text output, menu bar briefly shows error state. No modal dialogs ever.
- **App blocked from inserting text:** Automatic clipboard fallback, brief tooltip "Pasted from clipboard"

## Performance Targets (M1 Pro 32GB)

| Model | Load time | Transcribe 10s audio | Memory |
|-------|-----------|----------------------|--------|
| base | <1s | <1s | ~200MB |
| small | <2s | <2s | ~600MB |
| medium | <3s | <3s | ~1.7GB |
| large-v3 | <5s | <5s | ~3.5GB |
| AI cleanup (3B) | <3s | <1s per paragraph | ~2.5GB |

## Security & Privacy

- **Zero network calls** after model download (verify with Little Snitch or similar)
- No analytics, no telemetry, no crash reporting
- No data stored beyond settings (UserDefaults) and models
- Audio is processed in memory and immediately discarded
- Open source — anyone can verify
