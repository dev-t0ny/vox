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

1. User presses the hotkey (default: double-tap `Right Option`, configurable)
2. A small floating pill (~120x36px) appears near the mouse cursor with a live waveform
3. User speaks naturally
4. User presses the hotkey again (or releases in hold-to-talk mode)
5. Audio is transcribed by Whisper (Metal-accelerated)
6. Optionally, transcription is cleaned up by a local LLM
7. Text is typed at the cursor position via macOS Accessibility API
8. Floating pill fades away

**Target latency:** <1 second from end of speech to text appearing (with `base` model), <2 seconds with `large-v3`.

### Hotkey Behavior

- **Default:** Double-tap `Right Option` to start, single tap to stop
- **Alternative modes:** Hold-to-talk (hold key, speak, release), Toggle (tap to start, tap to stop)
- Hotkey is globally registered — works regardless of which app is focused
- Implemented via CGEvent tap for standard keys (requires Accessibility permission)
- Note: `Fn` key cannot be intercepted via CGEvent tap (handled at HID level by macOS). Default uses `Right Option` which is reliably interceptable and rarely used alone.
- User can configure any standard modifier+key combo or standalone modifier (Left/Right Option, Left/Right Control, etc.)
- Debounces with 300ms window to prevent accidental triggers

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
- Debounces with 300ms window to prevent accidental triggers
- Tracks modifier key up/down events (flagsChanged) for standalone modifier hotkeys
- **Accessibility bootstrap:** On launch, calls `AXIsProcessTrusted()` to check if Accessibility permission is granted. If not, calls `AXIsProcessTrustedWithOptions` with `kAXTrustedCheckOptionPrompt: true` to show the system prompt directing the user to System Settings > Privacy & Security > Accessibility. The menu bar dot shows an orange state with a tooltip "Grant Accessibility permission to enable hotkey." Polls `AXIsProcessTrusted()` every 2 seconds until granted, then creates the CGEvent tap. This avoids the silent-failure problem where `CGEvent.tapCreate` returns nil without explanation.

#### AudioPipeline
- Uses AVAudioEngine for mic capture (16kHz, mono, Float32 — Whisper's native format)
- Ring buffer: 16kHz * 60s * 4 bytes = ~3.8MB max (60 second max recording). Implemented as a single-producer single-consumer (SPSC) lock-free ring buffer using Swift `Atomic<Int>` (from the Atomics package or os_unfair_lock as fallback) for read/write indices. The audio thread writes, the inference queue reads. No locks on the audio thread's hot path.
- Energy-based Voice Activity Detection (VAD):
  - RMS energy threshold: 0.01 (configurable internally, tuned per-mic via initial calibration)
  - Silence timeout: 2 seconds of continuous silence triggers auto-stop in toggle mode
  - In hold-to-talk mode, VAD is used only for trimming leading/trailing silence, not for auto-stop
  - Initial 500ms of audio captured on activation is used to calibrate background noise floor
- Handles mic permission request on first use

#### WhisperEngine
- Wraps whisper.cpp compiled with Metal support, integrated via C bridging headers in the Xcode project
- Loads model into memory on app launch (stays resident for fast inference)
- Processes audio buffer → returns transcribed text with timestamps
- Supports language auto-detection or fixed language setting
- Voice commands are applied as a post-processing text replacement pass on the raw transcription string (regex-based), producing the final output with literal characters substituted
- When AI cleanup is enabled, voice command markers are converted to special tokens (e.g., `<NEWLINE>`, `<PARAGRAPH>`) before LLM processing. The LLM system prompt instructs it to preserve these tokens. After LLM cleanup, tokens are converted back to their literal characters (`\n`, `\n\n`, etc.)

#### TextProcessor (AI Cleanup — Optional)
- Wraps llama.cpp compiled with Metal support, integrated via C bridging headers in the Xcode project
- Uses a small model (~3B parameters, e.g., Llama 3.2 3B or Phi-3 mini)
- System prompt: "Clean up this voice transcription. Remove filler words (uh, um, like, you know), fix grammar and punctuation, keep the speaker's intent and tone intact. Do not add or change meaning. Preserve all <NEWLINE> and <PARAGRAPH> tokens exactly as they appear. Output only the cleaned text."
- Toggled on/off from settings (OFF by default)
- Model downloaded separately only when first toggled on

#### TextOutput
- **Primary method (AX string surgery):** macOS Accessibility API — queries `NSWorkspace.shared.frontmostApplication` to get the focused app, then uses `AXUIElementCopyAttributeValue` to find the focused UI element (`kAXFocusedUIElementAttribute`). Reads the full text via `kAXValueAttribute` and the cursor/selection position via `kAXSelectedTextRangeAttribute`. Performs string insertion at the cursor position (or replaces the selection), then writes the full updated string back via `AXUIElementSetAttributeValue` on `kAXValueAttribute`. Finally, updates `kAXSelectedTextRangeAttribute` to place the cursor after the inserted text. If `kAXValueAttribute` is not writable (read-only text fields), falls through to the clipboard fallback.
- **Fallback (clipboard paste):** Saves current `NSPasteboard.general` contents, copies transcribed text to clipboard, simulates `Cmd+V` via CGEvent. Restores previous clipboard contents after a 500ms delay. This delay is a known limitation — very slow apps (heavy Electron apps) may not have consumed the paste in time. Documented as a known edge case; if users report issues, the delay can be made configurable.
- Fallback activates automatically when AX insertion fails or the focused element lacks writable text attributes.

#### ModelManager
- Downloads models from Hugging Face (whisper.cpp GGML format, llama.cpp GGUF format)
- Stores in `~/Library/Application Support/VoxPopuli/models/`
- Verifies SHA256 checksums after download
- Shows download progress in menu bar
- First launch auto-downloads `base` Whisper model (~150MB)
- Supports models: tiny (~75MB), base (~150MB), small (~500MB), medium (~1.5GB), large-v3 (~3GB)
- Before loading a model, checks available system memory via `os_proc_available_memory()`. If the model's expected memory footprint exceeds 80% of available memory, shows a warning in the settings UI suggesting a smaller model. Does not hard-block — user can override, but the app won't silently OOM.

#### FloatingPill
- NSPanel with `.nonactivatingPanel` and `.floating` style masks (doesn't steal focus)
- Frosted glass background (NSVisualEffectView with .hudWindow material)
- Real-time waveform visualization driven by audio buffer RMS values
- **Positioning:** Uses `NSEvent.mouseLocation` (mouse cursor position), offset 20px above and 10px right to avoid obscuring the click target. If the pill would go off-screen, it flips to below the cursor. Falls back to center of the active screen if mouse position is unavailable.
- Fade-in on hotkey press (0.15s), fade-out on completion (0.3s)
- ~120x36px, rounded corners (8px radius)

#### MenuBarController
- NSStatusItem with a custom dot icon
- **Idle:** Static dot
- **Listening:** Gentle pulse animation (Core Animation opacity oscillation)
- **Processing:** Spinning animation
- **Downloading:** Progress indicator
- Left-click: Always toggles listening (start/stop recording) — this is the alternative to the hotkey
- Right-click: Always opens settings popover (regardless of state)

#### SettingsView (SwiftUI Popover)
- **Hotkey:** Picker with recorder (press keys to set)
- **Model:** Dropdown — tiny / base / small / medium / large-v3 (with download buttons)
- **Language:** Auto-detect or select from list
- **AI Cleanup:** Toggle on/off (downloads model on first enable)
- Settings stored in UserDefaults
- That's it. Four settings. Clean, minimal.

## Concurrency Model

- **Main thread:** All UI updates (menu bar animations, floating pill, settings). SwiftUI and AppKit views are main-actor isolated.
- **Audio thread:** AVAudioEngine's real-time render thread handles mic capture. The install-tap closure copies samples into the ring buffer (lock-free write). No heavy processing here.
- **Inference queue:** A dedicated serial `DispatchQueue` ("com.voxpopuli.inference") runs Whisper and LLM inference off the main thread. Metal compute is dispatched to GPU from this queue. On completion, results are dispatched back to main thread for text output and UI updates.
- **Download queue:** `URLSession` tasks run on their own background queue. Progress updates are dispatched to main thread for menu bar UI.

This ensures the UI never freezes during inference, and audio capture never drops frames.

## Concurrent Invocation Handling

- If the user triggers the hotkey while a previous transcription is still processing (inference queue busy):
  - The new recording starts immediately (audio pipeline is independent of inference)
  - The previous inference completes and outputs its text normally
  - The new recording queues behind it on the inference queue
  - The floating pill shows the new recording state (listening), not the old processing state
- If the user triggers the hotkey while already recording:
  - In toggle mode: stops the current recording (normal flow)
  - In hold-to-talk mode: ignored (release is the stop signal)
  - In double-tap mode: stops the current recording (treated as the stop tap)

## Data Flow

```
Hotkey pressed
    │
    ▼
AudioPipeline.startCapture()
FloatingPill.show(near: NSEvent.mouseLocation)
MenuBar.setState(.listening)
    │
    ▼
[User speaks — audio accumulates in ring buffer]
[FloatingPill waveform animates from RMS values]
    │
    ▼
Hotkey released / VAD silence detected (toggle mode only)
    │
    ▼
AudioPipeline.stopCapture() → audioBuffer
FloatingPill.setState(.processing)
MenuBar.setState(.processing)
    │
    ▼
[Dispatched to inference queue]
WhisperEngine.transcribe(audioBuffer) → rawText
    │
    ▼
VoiceCommandProcessor.apply(rawText) → processedText
(regex replacements: "new line" → \n, etc.)
(if AI cleanup enabled: convert to tokens first)
    │
    ▼
[if AI cleanup enabled]
TextProcessor.cleanup(processedText) → cleanedText
VoiceCommandProcessor.restoreTokens(cleanedText) → finalText
[else]
finalText = processedText
    │
    ▼
[Dispatched back to main thread]
TextOutput.type(finalText)
FloatingPill.fadeOut()
MenuBar.setState(.idle)
```

## First Launch Experience

1. App opens — no window appears, just the menu bar dot
2. App calls `AXIsProcessTrustedWithOptions` → system shows prompt directing user to System Settings > Accessibility → user grants (required for hotkey + text insertion). Menu bar dot shows orange "waiting" state until granted.
3. Once Accessibility is granted, first audio capture triggers **Microphone** permission prompt → user grants
4. Menu bar dot shows download progress as `base` model downloads (~150MB)
5. Download complete → dot goes idle
6. User double-taps Right Option → it works
7. Total time from install to first transcription: ~60 seconds on decent internet

No onboarding wizard. No tutorial. No "create account." The two OS permission dialogs are unavoidable, everything else is.

## Voice Commands

Built into VoiceCommandProcessor as **case-insensitive** regex post-processing (no AI model needed). Whisper may output "New line", "new line", or "NEW LINE" depending on context — all are matched:

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
| Build system | Xcode project + SPM for Swift dependencies | App bundle requires Xcode for signing, entitlements, and Info.plist |
| C++ integration | C bridging headers + modulemaps | whisper.cpp and llama.cpp compiled as static libraries linked into the Xcode target |
| Hotkey | CGEvent tap | Standard macOS global hotkey mechanism |
| Text insertion | Accessibility API (AXUIElement) | System-level text input |
| Storage | UserDefaults + filesystem | No database needed |

## Build System Details

This is an **Xcode project** (`.xcodeproj`), not a pure SPM package. Reasons:
- macOS app bundles require code signing and entitlements
- `Info.plist` with privacy usage descriptions (mic, accessibility)
- `Assets.xcassets` for app icon and menu bar icons
- Hardened runtime for notarization
- SPM is used for any pure-Swift dependencies, but whisper.cpp and llama.cpp are integrated as:
  1. Git submodules in `Libraries/`
  2. Compiled via custom build phases that invoke their CMake builds to produce static libraries (`.a` files)
  3. Linked into the main target via "Link Binary With Libraries" build phase
  4. Exposed to Swift via C bridging headers (`VoxPopuli-Bridging-Header.h`)

## Project Structure

```
vox-populi/
├── VoxPopuli.xcodeproj/                 # Xcode project
├── VoxPopuli/
│   ├── App/
│   │   ├── VoxPopuliApp.swift           # @main, app lifecycle
│   │   └── AppDelegate.swift            # NSApplicationDelegate, menu bar setup
│   ├── Core/
│   │   ├── HotkeyManager.swift          # Global hotkey registration
│   │   ├── AudioPipeline.swift          # Mic capture, ring buffer, VAD
│   │   ├── WhisperEngine.swift          # whisper.cpp Swift wrapper
│   │   ├── TextProcessor.swift          # llama.cpp Swift wrapper (AI cleanup)
│   │   ├── TextOutput.swift             # Accessibility API text insertion
│   │   ├── VoiceCommandProcessor.swift  # Voice command regex replacements
│   │   └── ModelManager.swift           # Model download and management
│   ├── UI/
│   │   ├── MenuBarController.swift      # Status item + animations
│   │   ├── FloatingPill.swift           # NSPanel waveform overlay
│   │   ├── SettingsView.swift           # SwiftUI settings popover
│   │   └── WaveformView.swift           # Audio waveform visualization
│   ├── Bridging/
│   │   ├── VoxPopuli-Bridging-Header.h  # C bridging header for whisper.cpp + llama.cpp
│   │   └── whisper-swift.h              # Minimal C API wrapper if needed
│   └── Resources/
│       ├── Assets.xcassets               # App icon, menu bar icons
│       ├── Info.plist                    # Permissions descriptions
│       └── VoxPopuli.entitlements        # App entitlements
├── Libraries/
│   ├── whisper.cpp/                     # Git submodule
│   └── llama.cpp/                       # Git submodule
├── Scripts/
│   └── build-libraries.sh              # Builds whisper.cpp and llama.cpp static libs
├── LICENSE                              # MIT
├── README.md
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-03-15-vox-populi-design.md
```

## Entitlements (VoxPopuli.entitlements)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <!-- audio-input entitlement is for sandboxed apps; kept here for documentation
         but has no effect with sandbox disabled. Mic access is governed by TCC at runtime. -->
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <!-- Hardened Runtime is NOT an entitlement — it's enabled via Xcode build setting
         ENABLE_HARDENED_RUNTIME = YES (or Signing & Capabilities > Hardened Runtime).
         Required for notarization. -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
```

Notes:
- App sandbox is **disabled** — required for CGEvent tap (global hotkey) and AXUIElement (text insertion). These APIs do not work in sandboxed apps.
- `allow-unsigned-executable-memory` is required for llama.cpp Metal shader compilation at runtime.
- Hardened runtime is enabled for notarization (required for distribution outside App Store).
- The app requests Accessibility permission at runtime (not an entitlement — it's a user-granted TCC permission).

## Distribution

- **GitHub Releases:** Signed and notarized .dmg with the app bundle
- **Homebrew:** `brew install --cask vox-populi`
- **License:** MIT
- **Min macOS:** 13.0 (Ventura) — for modern SwiftUI and Metal 2 GPU family support on Apple Silicon
- **Min hardware:** Any Apple Silicon Mac (M1+) — uses Metal 2 (Apple7 GPU family), not Metal 3

## Error Handling

- **No mic permission:** Menu bar dot turns red, clicking shows "Microphone access required" with button to open System Settings
- **No accessibility permission:** Same pattern, explains why it's needed
- **Model download fails:** Retry button in menu bar, works offline with whatever model is already downloaded
- **Whisper fails:** Silent failure, no text output, menu bar briefly shows error state (red flash, 2s). No modal dialogs ever.
- **App blocked from inserting text:** Automatic clipboard fallback, brief tooltip "Pasted from clipboard"
- **Concurrent invocation:** New recordings queue behind in-progress inference (see Concurrent Invocation Handling section)

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
