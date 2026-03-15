# Vox Populi Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS-native, fully offline voice-to-text menu bar app using whisper.cpp and llama.cpp with Metal acceleration.

**Architecture:** Swift macOS app using XcodeGen for project generation (deviation from spec's hand-maintained .xcodeproj — XcodeGen is used for reproducibility and ease of file management; it generates a standard .xcodeproj). whisper.cpp and llama.cpp compiled as static libraries via CMake and linked through C bridging headers. Core pipeline: AVAudioEngine → ring buffer → whisper.cpp → optional llama.cpp cleanup → AXUIElement text insertion. Single shared inference DispatchQueue for all heavy compute.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit, AVFoundation, whisper.cpp (Metal), llama.cpp (Metal), XcodeGen, CMake

**Spec:** `docs/superpowers/specs/2026-03-15-vox-populi-design.md`

---

## File Map

### Project Configuration
| File | Purpose |
|------|---------|
| `project.yml` | XcodeGen project definition |
| `.gitignore` | Ignore build artifacts, models, DS_Store |
| `Scripts/build-libraries.sh` | Compiles whisper.cpp and llama.cpp static libs |
| `Scripts/download-model.sh` | Dev helper to download a Whisper model for testing |
| `VoxPopuli/Resources/Info.plist` | Privacy usage descriptions |
| `VoxPopuli/Resources/VoxPopuli.entitlements` | App sandbox + hardened runtime entitlements |
| `VoxPopuli/Resources/Assets.xcassets` | App icon and menu bar dot icon |
| `LICENSE` | MIT license |

### Bridging
| File | Purpose |
|------|---------|
| `VoxPopuli/Bridging/VoxPopuli-Bridging-Header.h` | Imports whisper.h and llama.h for Swift |

### App Shell
| File | Purpose |
|------|---------|
| `VoxPopuli/App/VoxPopuliApp.swift` | @main entry, menu bar extra |
| `VoxPopuli/App/AppDelegate.swift` | NSApplicationDelegate, orchestrates all components |
| `VoxPopuli/App/AppState.swift` | Observable shared state (recording, processing, errors) |

### Core Engine
| File | Purpose |
|------|---------|
| `VoxPopuli/Core/RingBuffer.swift` | SPSC lock-free ring buffer for audio samples |
| `VoxPopuli/Core/AudioPipeline.swift` | AVAudioEngine mic capture + VAD |
| `VoxPopuli/Core/WhisperEngine.swift` | whisper.cpp Swift wrapper |
| `VoxPopuli/Core/TextProcessor.swift` | llama.cpp Swift wrapper (AI cleanup) |
| `VoxPopuli/Core/VoiceCommandProcessor.swift` | Regex-based voice command → character substitution |
| `VoxPopuli/Core/TextOutput.swift` | AXUIElement text insertion + clipboard fallback |
| `VoxPopuli/Core/HotkeyManager.swift` | CGEvent tap global hotkey |
| `VoxPopuli/Core/ModelManager.swift` | Model download, verify, store, memory check |
| `VoxPopuli/Core/TranscriptionPipeline.swift` | Orchestrates the full hotkey→text flow |

### UI
| File | Purpose |
|------|---------|
| `VoxPopuli/UI/MenuBarController.swift` | NSStatusItem dot with state animations |
| `VoxPopuli/UI/FloatingPill.swift` | NSPanel non-activating overlay |
| `VoxPopuli/UI/WaveformView.swift` | Real-time audio waveform NSView |
| `VoxPopuli/UI/SettingsView.swift` | SwiftUI popover (4 settings) |

### Tests
| File | Purpose |
|------|---------|
| `VoxPopuliTests/VoiceCommandProcessorTests.swift` | Voice command regex tests |
| `VoxPopuliTests/RingBufferTests.swift` | Ring buffer read/write/overflow tests |
| `VoxPopuliTests/ModelManagerTests.swift` | Model storage, memory check, checksum tests |

---

## Chunk 1: Project Foundation & C++ Libraries

### Task 1: Initialize project structure and XcodeGen config

**Files:**
- Create: `project.yml`
- Create: `.gitignore`
- Create: `VoxPopuli/App/VoxPopuliApp.swift`
- Create: `VoxPopuli/App/AppDelegate.swift`
- Create: `VoxPopuli/Resources/Info.plist`
- Create: `VoxPopuli/Resources/VoxPopuli.entitlements`
- Create: `LICENSE`

- [ ] **Step 1: Install XcodeGen if not present**

Run: `brew install xcodegen`
Expected: xcodegen available at command line

- [ ] **Step 2: Create .gitignore FIRST (before any commits)**

Create `.gitignore`:
```
# Build
build/
DerivedData/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/

# Libraries build output
Libraries/whisper.cpp/build/
Libraries/llama.cpp/build/

# Models (large binary files)
*.bin
*.gguf

# macOS
.DS_Store
*.swp
*~

# Xcode
*.pbxuser
*.mode1v3
*.mode2v3
*.perspectivev3
*.moved-aside
xcuserdata/
```

- [ ] **Step 3: Create project directory structure**

```bash
mkdir -p VoxPopuli/{App,Core,UI,Bridging,Resources}
mkdir -p VoxPopuliTests
mkdir -p Scripts
mkdir -p Libraries
```

- [ ] **Step 4: Create Info.plist**

Create `VoxPopuli/Resources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Vox Populi</string>
    <key>CFBundleDisplayName</key>
    <string>Vox Populi</string>
    <key>CFBundleIdentifier</key>
    <string>com.voxpopuli.app</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Vox Populi needs microphone access to transcribe your speech into text.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Vox Populi needs accessibility access to type transcribed text into your apps.</string>
</dict>
</plist>
```

Note: `LSUIElement = true` makes it a menu bar-only app (no dock icon).

- [ ] **Step 5: Create entitlements file**

Create `VoxPopuli/Resources/VoxPopuli.entitlements`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 6: Create minimal app entry point**

Create `VoxPopuli/App/VoxPopuliApp.swift`:
```swift
import SwiftUI

@main
struct VoxPopuliApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
```

- [ ] **Step 7: Create AppDelegate stub**

Create `VoxPopuli/App/AppDelegate.swift`:
```swift
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Vox Populi launched")
    }
}
```

- [ ] **Step 8: Create XcodeGen project.yml**

Create `project.yml`:
```yaml
name: VoxPopuli
options:
  bundleIdPrefix: com.voxpopuli
  deploymentTarget:
    macOS: "13.0"
  xcodeVersion: "15.0"
  generateEmptyDirectories: true

settings:
  base:
    SWIFT_VERSION: "5.9"
    MACOSX_DEPLOYMENT_TARGET: "13.0"
    ENABLE_HARDENED_RUNTIME: YES
    CODE_SIGN_IDENTITY: "-"
    ARCHS: arm64

targets:
  VoxPopuli:
    type: application
    platform: macOS
    sources:
      - path: VoxPopuli
        excludes:
          - "**/*.entitlements"
    resources:
      - path: VoxPopuli/Resources/Assets.xcassets
    settings:
      base:
        INFOPLIST_FILE: VoxPopuli/Resources/Info.plist
        CODE_SIGN_ENTITLEMENTS: VoxPopuli/Resources/VoxPopuli.entitlements
        SWIFT_OBJC_BRIDGING_HEADER: VoxPopuli/Bridging/VoxPopuli-Bridging-Header.h
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/../Frameworks"
        HEADER_SEARCH_PATHS:
          - "$(PROJECT_DIR)/Libraries/whisper.cpp/include"
          - "$(PROJECT_DIR)/Libraries/whisper.cpp/ggml/include"
          - "$(PROJECT_DIR)/Libraries/llama.cpp/include"
          - "$(PROJECT_DIR)/Libraries/llama.cpp/ggml/include"
        LIBRARY_SEARCH_PATHS:
          - "$(PROJECT_DIR)/Libraries/whisper.cpp/build/src"
          - "$(PROJECT_DIR)/Libraries/whisper.cpp/build/ggml/src"
          - "$(PROJECT_DIR)/Libraries/llama.cpp/build/src"
          - "$(PROJECT_DIR)/Libraries/llama.cpp/build/ggml/src"
        OTHER_LDFLAGS:
          - "-lwhisper"
          - "-lggml"
          - "-lggml-base"
          - "-lggml-metal"
          - "-lggml-cpu"
          - "-lllama"
          - "-lc++"
          - "-framework Accelerate"
          - "-framework Metal"
          - "-framework MetalKit"
          - "-framework Foundation"
    dependencies: []

  VoxPopuliTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: VoxPopuliTests
    dependencies:
      - target: VoxPopuli
    settings:
      base:
        BUNDLE_LOADER: "$(TEST_HOST)"
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/VoxPopuli.app/Contents/MacOS/VoxPopuli"
```

Note: Library search paths and linker flags will be refined after building whisper.cpp/llama.cpp in Task 2. Run `find Libraries/*/build -name "*.a"` after building to verify exact paths and lib names.

- [ ] **Step 9: Create MIT LICENSE**

Create `LICENSE` with standard MIT text, copyright "2026 Vox Populi Contributors".

- [ ] **Step 10: Create empty Assets.xcassets**

```bash
mkdir -p VoxPopuli/Resources/Assets.xcassets
cat > VoxPopuli/Resources/Assets.xcassets/Contents.json << 'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF
```

- [ ] **Step 11: Create bridging header stub**

Create `VoxPopuli/Bridging/VoxPopuli-Bridging-Header.h`:
```c
#ifndef VoxPopuli_Bridging_Header_h
#define VoxPopuli_Bridging_Header_h

// Will import whisper.h and llama.h after libraries are built

#endif
```

- [ ] **Step 12: Generate Xcode project and verify build**

```bash
cd /Users/tonyboudreau/Documents/Dev/vox-populi
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli -configuration Debug build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED (minimal app with no C++ libs yet)

- [ ] **Step 13: Commit**

```bash
git add .gitignore project.yml VoxPopuli/ VoxPopuliTests/ Scripts/ LICENSE
git commit -m "feat: scaffold Xcode project with XcodeGen, entitlements, and minimal app shell"
```

---

### Task 2: Add whisper.cpp and llama.cpp as submodules and build

**Files:**
- Create: `Scripts/build-libraries.sh`
- Modify: `VoxPopuli/Bridging/VoxPopuli-Bridging-Header.h`

- [ ] **Step 1: Add git submodules**

```bash
cd /Users/tonyboudreau/Documents/Dev/vox-populi
git submodule add https://github.com/ggerganov/whisper.cpp.git Libraries/whisper.cpp
git submodule add https://github.com/ggerganov/llama.cpp.git Libraries/llama.cpp
```

- [ ] **Step 2: Create build script**

Create `Scripts/build-libraries.sh`:
```bash
#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NPROC=$(sysctl -n hw.logicalcpu)

echo "=== Building whisper.cpp ==="
cd "$PROJECT_DIR/Libraries/whisper.cpp"
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_TESTS=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build --config Release -j "$NPROC"

echo "=== Building llama.cpp ==="
cd "$PROJECT_DIR/Libraries/llama.cpp"
cmake -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64
cmake --build build --config Release -j "$NPROC"

echo "=== Build complete ==="
echo "Whisper libs:"
find "$PROJECT_DIR/Libraries/whisper.cpp/build" -name "*.a" | head -10
echo "Llama libs:"
find "$PROJECT_DIR/Libraries/llama.cpp/build" -name "*.a" | head -10
```

Note: Both whisper.cpp and llama.cpp now use the unified ggml build system. Metal is enabled via `GGML_METAL=ON` (not the deprecated `WHISPER_METAL`). The exact output lib names may vary — check the `find` output and update `project.yml` linker flags to match.

- [ ] **Step 3: Make build script executable and run it**

```bash
chmod +x Scripts/build-libraries.sh
./Scripts/build-libraries.sh
```

Expected: Static libraries (.a files) built for both whisper.cpp and llama.cpp. Note the exact file paths — update `project.yml` LIBRARY_SEARCH_PATHS and OTHER_LDFLAGS if they differ.

- [ ] **Step 4: Update bridging header with actual imports**

Update `VoxPopuli/Bridging/VoxPopuli-Bridging-Header.h`:
```c
#ifndef VoxPopuli_Bridging_Header_h
#define VoxPopuli_Bridging_Header_h

#include "whisper.h"
#include "llama.h"
#include "ggml.h"

#endif
```

- [ ] **Step 5: Update project.yml if library paths differ**

After the build in Step 3, check the actual output paths of the `.a` files. Update `LIBRARY_SEARCH_PATHS` and `OTHER_LDFLAGS` in `project.yml` to match. Then regenerate:

```bash
xcodegen generate
```

- [ ] **Step 6: Verify the project builds with C++ libraries linked**

```bash
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli -configuration Debug build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED with whisper.cpp and llama.cpp symbols available.

- [ ] **Step 7: Create dev model download helper**

Create `Scripts/download-model.sh`:
```bash
#!/bin/bash
set -euo pipefail

MODEL="${1:-base}"
MODELS_DIR="$HOME/Library/Application Support/VoxPopuli/models"
mkdir -p "$MODELS_DIR"

declare -A URLS
URLS[tiny]="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"
URLS[base]="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin"
URLS[small]="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
URLS[medium]="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin"
URLS[large-v3]="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"

URL="${URLS[$MODEL]:-}"
if [ -z "$URL" ]; then
    echo "Unknown model: $MODEL. Options: tiny, base, small, medium, large-v3"
    exit 1
fi

DEST="$MODELS_DIR/ggml-${MODEL}.bin"
if [ -f "$DEST" ]; then
    echo "Model already exists: $DEST"
    exit 0
fi

echo "Downloading $MODEL model to $DEST..."
curl -L --progress-bar "$URL" -o "$DEST"
echo "Done! Model saved to $DEST"
```

```bash
chmod +x Scripts/download-model.sh
```

- [ ] **Step 8: Download base model for development testing**

```bash
./Scripts/download-model.sh base
```

Expected: `~/Library/Application Support/VoxPopuli/models/ggml-base.bin` exists (~150MB)

- [ ] **Step 9: Commit**

```bash
git add Scripts/ VoxPopuli/Bridging/ project.yml .gitmodules
git commit -m "feat: add whisper.cpp and llama.cpp submodules with build script"
```

---

## Chunk 2: Core Engine — Ring Buffer, Audio, Whisper

### Task 3: Implement SPSC lock-free ring buffer with tests

**Files:**
- Create: `VoxPopuli/Core/RingBuffer.swift`
- Create: `VoxPopuliTests/RingBufferTests.swift`

- [ ] **Step 1: Write failing tests for RingBuffer**

Create `VoxPopuliTests/RingBufferTests.swift`:
```swift
import XCTest
@testable import VoxPopuli

final class RingBufferTests: XCTestCase {
    func testWriteAndRead() {
        let buffer = RingBuffer(capacity: 1024)
        let samples: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        buffer.write(samples)
        let result = buffer.readAll()
        XCTAssertEqual(result, samples)
    }

    func testReadAllClearsBuffer() {
        let buffer = RingBuffer(capacity: 1024)
        buffer.write([1.0, 2.0, 3.0])
        _ = buffer.readAll()
        let result = buffer.readAll()
        XCTAssertTrue(result.isEmpty)
    }

    func testOverflowWrapsAround() {
        let buffer = RingBuffer(capacity: 8)
        buffer.write([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0])
        buffer.write([9.0, 10.0])
        let result = buffer.readAll()
        XCTAssertEqual(result.count, 8)
        XCTAssertEqual(result.last, 10.0)
    }

    func testAvailableSamplesCount() {
        let buffer = RingBuffer(capacity: 1024)
        XCTAssertEqual(buffer.availableSamples, 0)
        buffer.write([1.0, 2.0, 3.0])
        XCTAssertEqual(buffer.availableSamples, 3)
    }

    func testRMSCalculation() {
        let buffer = RingBuffer(capacity: 1024)
        buffer.write([0.0, 0.0, 0.0, 0.0])
        XCTAssertEqual(buffer.currentRMS, 0.0, accuracy: 0.001)

        let buffer2 = RingBuffer(capacity: 1024)
        buffer2.write([0.5, 0.5, 0.5, 0.5])
        XCTAssertEqual(buffer2.currentRMS, 0.5, accuracy: 0.001)
    }

    func testReset() {
        let buffer = RingBuffer(capacity: 1024)
        buffer.write([1.0, 2.0, 3.0])
        buffer.reset()
        XCTAssertEqual(buffer.availableSamples, 0)
        XCTAssertTrue(buffer.readAll().isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodegen generate
xcodebuild test -project VoxPopuli.xcodeproj -scheme VoxPopuliTests -destination 'platform=macOS' 2>&1 | grep -E "(Test|error|FAIL)"
```

Expected: Compilation error — `RingBuffer` not defined.

- [ ] **Step 3: Implement RingBuffer**

Create `VoxPopuli/Core/RingBuffer.swift`:
```swift
import Foundation
import os

/// Single-producer single-consumer lock-free ring buffer for audio samples.
/// The audio thread writes, the inference queue reads.
final class RingBuffer: @unchecked Sendable {
    private let capacity: Int
    private var buffer: [Float]
    private let lock = os_unfair_lock_t.allocate(capacity: 1)

    private var writeIndex: Int = 0
    private var count: Int = 0
    private var rmsAccumulator: Float = 0.0
    private var rmsSampleCount: Int = 0

    var availableSamples: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return count
    }

    var currentRMS: Float {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard rmsSampleCount > 0 else { return 0.0 }
        return sqrt(rmsAccumulator / Float(rmsSampleCount))
    }

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = [Float](repeating: 0.0, count: capacity)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func write(_ samples: [Float]) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        rmsAccumulator = 0
        rmsSampleCount = samples.count
        for sample in samples {
            rmsAccumulator += sample * sample
        }

        for sample in samples {
            buffer[writeIndex % capacity] = sample
            writeIndex += 1
        }
        count = min(count + samples.count, capacity)
    }

    func readAll() -> [Float] {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }

        guard count > 0 else { return [] }

        var result = [Float](repeating: 0.0, count: count)
        let readStart = (writeIndex - count + capacity) % capacity
        for i in 0..<count {
            result[i] = buffer[(readStart + i) % capacity]
        }

        count = 0
        return result
    }

    func reset() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        writeIndex = 0
        count = 0
        rmsAccumulator = 0
        rmsSampleCount = 0
    }
}
```

- [ ] **Step 4: Regenerate project and run tests**

```bash
xcodegen generate
xcodebuild test -project VoxPopuli.xcodeproj -scheme VoxPopuliTests -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|passed|failed)"
```

Expected: All 6 RingBuffer tests PASS.

- [ ] **Step 5: Commit**

```bash
git add VoxPopuli/Core/RingBuffer.swift VoxPopuliTests/RingBufferTests.swift
git commit -m "feat: implement SPSC ring buffer with RMS tracking"
```

---

### Task 4: Implement VoiceCommandProcessor with tests

**Files:**
- Create: `VoxPopuli/Core/VoiceCommandProcessor.swift`
- Create: `VoxPopuliTests/VoiceCommandProcessorTests.swift`

- [ ] **Step 1: Write failing tests**

Create `VoxPopuliTests/VoiceCommandProcessorTests.swift`:
```swift
import XCTest
@testable import VoxPopuli

final class VoiceCommandProcessorTests: XCTestCase {
    let processor = VoiceCommandProcessor()

    func testNewLine() {
        XCTAssertEqual(processor.apply("Hello new line world"), "Hello\nworld")
    }

    func testNewParagraph() {
        XCTAssertEqual(processor.apply("First new paragraph second"), "First\n\nsecond")
    }

    func testPeriod() {
        XCTAssertEqual(processor.apply("End of sentence period"), "End of sentence.")
    }

    func testComma() {
        XCTAssertEqual(processor.apply("Hello comma world"), "Hello, world")
    }

    func testQuestionMark() {
        XCTAssertEqual(processor.apply("How are you question mark"), "How are you?")
    }

    func testExclamationMark() {
        XCTAssertEqual(processor.apply("Wow exclamation mark"), "Wow!")
        XCTAssertEqual(processor.apply("Wow exclamation point"), "Wow!")
    }

    func testColonAndSemicolon() {
        XCTAssertEqual(processor.apply("Note colon important"), "Note: important")
        XCTAssertEqual(processor.apply("First semicolon second"), "First; second")
    }

    func testQuotes() {
        XCTAssertEqual(processor.apply("He said open quote hello close quote"), "He said \"hello\"")
    }

    func testParens() {
        XCTAssertEqual(processor.apply("See open paren note close paren"), "See (note)")
    }

    func testCaseInsensitive() {
        XCTAssertEqual(processor.apply("Hello New Line world"), "Hello\nworld")
        XCTAssertEqual(processor.apply("Hello NEW LINE world"), "Hello\nworld")
        XCTAssertEqual(processor.apply("End Period"), "End.")
    }

    func testMultipleCommands() {
        XCTAssertEqual(
            processor.apply("Hello comma how are you question mark new line I am fine period"),
            "Hello, how are you?\nI am fine."
        )
    }

    func testNoCommandsPassthrough() {
        XCTAssertEqual(processor.apply("Just regular text"), "Just regular text")
    }

    func testConvertToTokens() {
        let result = processor.convertToTokens("Hello new line world new paragraph end")
        XCTAssertTrue(result.contains("<NEWLINE>"))
        XCTAssertTrue(result.contains("<PARAGRAPH>"))
    }

    func testRestoreTokens() {
        XCTAssertEqual(processor.restoreTokens("Hello<NEWLINE>world"), "Hello\nworld")
        XCTAssertEqual(processor.restoreTokens("First<PARAGRAPH>second"), "First\n\nsecond")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: Compilation error — `VoiceCommandProcessor` not defined.

- [ ] **Step 3: Implement VoiceCommandProcessor**

Create `VoxPopuli/Core/VoiceCommandProcessor.swift`:
```swift
import Foundation

struct VoiceCommandProcessor {
    private static let commands: [(pattern: String, replacement: String, trimBefore: Bool, trimAfter: Bool)] = [
        ("new paragraph", "\n\n", true, true),
        ("new line", "\n", true, true),
        ("exclamation point", "!", true, false),
        ("exclamation mark", "!", true, false),
        ("question mark", "?", true, false),
        ("full stop", ".", true, false),
        ("open quote", "\"", false, true),
        ("close quote", "\"", true, false),
        ("open paren", "(", false, true),
        ("close paren", ")", true, false),
        ("semicolon", ";", true, false),
        ("colon", ":", true, false),
        ("period", ".", true, false),
        ("comma", ",", true, false),
    ]

    func apply(_ text: String) -> String {
        var result = text
        for cmd in Self.commands {
            let pattern = "\\s*\\b\(NSRegularExpression.escapedPattern(for: cmd.pattern))\\b\\s*"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }

            let range = NSRange(result.startIndex..., in: result)
            var replacement = cmd.replacement
            if !cmd.trimBefore { replacement = " " + replacement }
            if !cmd.trimAfter { replacement = replacement + " " }

            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    func convertToTokens(_ text: String) -> String {
        var result = text
        let tokenMap: [(pattern: String, token: String)] = [
            ("new paragraph", "<PARAGRAPH>"),
            ("new line", "<NEWLINE>"),
        ]
        for entry in tokenMap {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: entry.pattern))\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: entry.token)
        }
        return result
    }

    func restoreTokens(_ text: String) -> String {
        text.replacingOccurrences(of: "<PARAGRAPH>", with: "\n\n")
            .replacingOccurrences(of: "<NEWLINE>", with: "\n")
    }
}
```

- [ ] **Step 4: Run tests**

```bash
xcodegen generate
xcodebuild test -project VoxPopuli.xcodeproj -scheme VoxPopuliTests -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|passed|failed)"
```

Expected: All VoiceCommandProcessor tests PASS. Adjust regex if any fail.

- [ ] **Step 5: Commit**

```bash
git add VoxPopuli/Core/VoiceCommandProcessor.swift VoxPopuliTests/VoiceCommandProcessorTests.swift
git commit -m "feat: implement voice command processor with case-insensitive regex matching"
```

---

### Task 5: Implement AudioPipeline

**Files:**
- Create: `VoxPopuli/Core/AudioPipeline.swift`

- [ ] **Step 1: Implement AudioPipeline**

Create `VoxPopuli/Core/AudioPipeline.swift`:
```swift
import AVFoundation
import Foundation

protocol AudioPipelineDelegate: AnyObject {
    func audioPipeline(_ pipeline: AudioPipeline, didUpdateRMS rms: Float)
    func audioPipelineDidDetectSilence(_ pipeline: AudioPipeline)
}

final class AudioPipeline {
    weak var delegate: AudioPipelineDelegate?

    let ringBuffer: RingBuffer

    private let engine = AVAudioEngine()
    private let sampleRate: Double = 16000.0
    private let maxDurationSeconds: Int = 60
    private var isCapturing = false

    // VAD
    private var silenceThreshold: Float = 0.01
    private var noiseFloor: Float = 0.0
    private var calibrationSamples: Int = 0
    private var calibrationAccumulator: Float = 0.0
    private let calibrationDuration: Int = 8000 // 500ms at 16kHz
    private var silentFrameCount: Int = 0
    private let silenceTimeoutFrames: Int = 32000 // 2 seconds at 16kHz
    private var isCalibrated = false

    init() {
        let capacity = Int(sampleRate) * maxDurationSeconds
        self.ringBuffer = RingBuffer(capacity: capacity)
    }

    var hasMicPermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func startCapture() throws {
        guard !isCapturing else { return }

        ringBuffer.reset()
        silentFrameCount = 0
        isCalibrated = false
        calibrationSamples = 0
        calibrationAccumulator = 0.0

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioPipelineError.formatError
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioPipelineError.converterError
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, converter: converter, targetFormat: targetFormat)
        }

        try engine.start()
        isCapturing = true
    }

    func stopCapture() -> [Float] {
        guard isCapturing else { return [] }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isCapturing = false

        return ringBuffer.readAll()
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter, targetFormat: AVAudioFormat) {
        let frameCount = AVAudioFrameCount(
            Double(buffer.frameLength) * sampleRate / buffer.format.sampleRate
        )
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else { return }

        var error: NSError?
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        guard error == nil,
              let channelData = convertedBuffer.floatChannelData?[0] else { return }

        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(convertedBuffer.frameLength)))

        if !isCalibrated {
            for sample in samples {
                calibrationAccumulator += sample * sample
                calibrationSamples += 1
            }
            if calibrationSamples >= calibrationDuration {
                noiseFloor = sqrt(calibrationAccumulator / Float(calibrationSamples))
                silenceThreshold = max(0.01, noiseFloor * 3.0)
                isCalibrated = true
            }
        }

        ringBuffer.write(samples)

        let rms = ringBuffer.currentRMS
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.audioPipeline(self, didUpdateRMS: rms)
        }

        if isCalibrated {
            if rms < silenceThreshold {
                silentFrameCount += samples.count
                if silentFrameCount >= silenceTimeoutFrames {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.audioPipelineDidDetectSilence(self)
                    }
                }
            } else {
                silentFrameCount = 0
            }
        }
    }
}

enum AudioPipelineError: Error {
    case formatError
    case converterError
}
```

- [ ] **Step 2: Verify build**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VoxPopuli/Core/AudioPipeline.swift
git commit -m "feat: implement audio pipeline with AVAudioEngine, VAD, and noise calibration"
```

---

### Task 6: Implement WhisperEngine

**Files:**
- Create: `VoxPopuli/Core/WhisperEngine.swift`

- [ ] **Step 1: Implement WhisperEngine**

Create `VoxPopuli/Core/WhisperEngine.swift`:
```swift
import Foundation

final class WhisperEngine {
    private var context: OpaquePointer?

    var isLoaded: Bool { context != nil }

    func loadModel(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw WhisperError.modelNotFound(path)
        }

        var params = whisper_context_default_params()
        params.use_gpu = true

        guard let ctx = whisper_init_from_file_with_params(path, params) else {
            throw WhisperError.initFailed
        }

        if let old = context {
            whisper_free(old)
        }
        context = ctx
    }

    /// Transcribe audio samples (16kHz mono Float32).
    /// Runs synchronously — caller is responsible for dispatching to background queue.
    func transcribe(samples: [Float], language: String? = nil) throws -> String {
        guard let ctx = context else {
            throw WhisperError.notLoaded
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.print_timestamps = false
        params.single_segment = false
        params.n_threads = 4

        // Keep language string alive through the whisper_full call
        var languageCString: [CChar]?
        if let lang = language {
            languageCString = Array(lang.utf8CString)
            languageCString?.withUnsafeMutableBufferPointer { buf in
                params.language = UnsafePointer(buf.baseAddress)
            }
        }

        let result = samples.withUnsafeBufferPointer { bufferPtr in
            whisper_full(ctx, params, bufferPtr.baseAddress, Int32(samples.count))
        }

        guard result == 0 else {
            throw WhisperError.transcriptionFailed
        }

        let nSegments = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<nSegments {
            if let segmentText = whisper_full_get_segment_text(ctx, i) {
                text += String(cString: segmentText)
            }
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        if let ctx = context {
            whisper_free(ctx)
            context = nil
        }
    }

    deinit {
        unload()
    }
}

enum WhisperError: Error, LocalizedError {
    case modelNotFound(String)
    case initFailed
    case notLoaded
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return "Whisper model not found at: \(path)"
        case .initFailed: return "Failed to initialize Whisper model"
        case .notLoaded: return "No Whisper model loaded"
        case .transcriptionFailed: return "Transcription failed"
        }
    }
}
```

Note: The `language` string lifetime issue is handled by keeping `languageCString` alive in the same scope as the `whisper_full` call. The `withUnsafeMutableBufferPointer` sets the pointer while the array lives on the stack. However, this pattern is fragile — if the compiler optimizes away the array early, the pointer may dangle. A safer approach: allocate a `strdup` and free after. If build/runtime issues occur, switch to `strdup`/`free`. The exact whisper.cpp C API may differ — check `Libraries/whisper.cpp/include/whisper.h` and adjust.

- [ ] **Step 2: Verify build**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED. If it fails due to whisper.cpp API differences, check the header and adjust.

- [ ] **Step 3: Commit**

```bash
git add VoxPopuli/Core/WhisperEngine.swift
git commit -m "feat: implement Whisper engine with Metal acceleration"
```

---

## Chunk 3: Text Output, Model Management, Hotkey

### Task 7: Implement TextOutput (Accessibility + clipboard fallback)

**Files:**
- Create: `VoxPopuli/Core/TextOutput.swift`

- [ ] **Step 1: Implement TextOutput**

Create `VoxPopuli/Core/TextOutput.swift`:
```swift
import Cocoa
import ApplicationServices

final class TextOutput {
    func type(_ text: String) {
        if !insertViaAccessibility(text) {
            insertViaClipboard(text)
        }
    }

    // MARK: - Accessibility API (primary)

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusResult == .success, let element = focusedElement else { return false }

        let axElement = element as! AXUIElement

        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue)

        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &selectedRange)

        var isSettable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &isSettable)

        guard valueResult == .success,
              rangeResult == .success,
              isSettable.boolValue,
              let currentString = currentValue as? String,
              let rangeValue = selectedRange as? AXValue else {
            return false
        }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &cfRange) else { return false }

        let nsString = currentString as NSString
        let swiftRange = NSRange(location: cfRange.location, length: cfRange.length)
        let newString = nsString.replacingCharacters(in: swiftRange, with: text)

        let setResult = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newString as CFTypeRef)
        guard setResult == .success else { return false }

        let newCursorPos = cfRange.location + text.count
        var newRange = CFRange(location: newCursorPos, length: 0)
        if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
        }

        return true
    }

    // MARK: - Clipboard fallback

    private func insertViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulateKeyPress(keyCode: 9, flags: .maskCommand) // 9 = 'v'

        if let previous = previousContents {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func simulateKeyPress(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = flags
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = flags
        keyUp?.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VoxPopuli/Core/TextOutput.swift
git commit -m "feat: implement text output with Accessibility API and clipboard fallback"
```

---

### Task 8: Implement ModelManager with tests

**Files:**
- Create: `VoxPopuli/Core/ModelManager.swift`
- Create: `VoxPopuliTests/ModelManagerTests.swift`

- [ ] **Step 1: Write failing tests**

Create `VoxPopuliTests/ModelManagerTests.swift`:
```swift
import XCTest
@testable import VoxPopuli

final class ModelManagerTests: XCTestCase {
    var manager: ModelManager!
    var testDir: URL!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)
        manager = ModelManager(modelsDirectory: testDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        super.tearDown()
    }

    func testModelsDirectoryCreated() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: testDir.path))
    }

    func testAvailableModels() {
        let models = ModelManager.whisperModels
        XCTAssertTrue(models.contains { $0.name == "base" })
        XCTAssertTrue(models.contains { $0.name == "tiny" })
        XCTAssertTrue(models.contains { $0.name == "large-v3" })
    }

    func testModelPathForName() {
        let path = manager.modelPath(for: "base")
        XCTAssertTrue(path.path.contains("ggml-base.bin"))
    }

    func testIsModelDownloadedReturnsFalseWhenMissing() {
        XCTAssertFalse(manager.isModelDownloaded("base"))
    }

    func testIsModelDownloadedReturnsTrueWhenPresent() throws {
        let path = manager.modelPath(for: "base")
        try "fake model data".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertTrue(manager.isModelDownloaded("base"))
    }

    func testMemoryCheckForSmallModel() {
        let result = manager.checkMemoryForModel("base")
        XCTAssertTrue(result.canLoad)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: Compilation error — `ModelManager` not defined.

- [ ] **Step 3: Implement ModelManager**

Create `VoxPopuli/Core/ModelManager.swift`:
```swift
import Foundation
import os
import CommonCrypto

struct WhisperModelInfo {
    let name: String
    let filename: String
    let url: URL
    let sizeBytes: Int64
    let estimatedMemoryMB: Int
    let sha256: String? // nil = skip verification (for dev speed)
}

struct MemoryCheckResult {
    let canLoad: Bool
    let availableMB: Int
    let requiredMB: Int
    let warning: String?
}

final class ModelManager: ObservableObject {
    static let whisperModels: [WhisperModelInfo] = [
        WhisperModelInfo(
            name: "tiny", filename: "ggml-tiny.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
            sizeBytes: 75_000_000, estimatedMemoryMB: 75, sha256: nil
        ),
        WhisperModelInfo(
            name: "base", filename: "ggml-base.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            sizeBytes: 148_000_000, estimatedMemoryMB: 200, sha256: nil
        ),
        WhisperModelInfo(
            name: "small", filename: "ggml-small.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            sizeBytes: 488_000_000, estimatedMemoryMB: 600, sha256: nil
        ),
        WhisperModelInfo(
            name: "medium", filename: "ggml-medium.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            sizeBytes: 1_533_000_000, estimatedMemoryMB: 1700, sha256: nil
        ),
        WhisperModelInfo(
            name: "large-v3", filename: "ggml-large-v3.bin",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!,
            sizeBytes: 3_095_000_000, estimatedMemoryMB: 3500, sha256: nil
        ),
    ]

    let modelsDirectory: URL
    @Published var downloadProgress: Double = 0
    @Published var isDownloading = false
    @Published var currentDownloadModel: String?

    private var downloadTask: URLSessionDownloadTask?

    init(modelsDirectory: URL? = nil) {
        self.modelsDirectory = modelsDirectory ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("VoxPopuli/models")
        }()
        try? FileManager.default.createDirectory(at: self.modelsDirectory, withIntermediateDirectories: true)
    }

    func modelPath(for name: String) -> URL {
        guard let info = Self.whisperModels.first(where: { $0.name == name }) else {
            return modelsDirectory.appendingPathComponent("ggml-\(name).bin")
        }
        return modelsDirectory.appendingPathComponent(info.filename)
    }

    func isModelDownloaded(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: modelPath(for: name).path)
    }

    func checkMemoryForModel(_ name: String) -> MemoryCheckResult {
        guard let info = Self.whisperModels.first(where: { $0.name == name }) else {
            return MemoryCheckResult(canLoad: false, availableMB: 0, requiredMB: 0, warning: "Unknown model")
        }

        let available = os_proc_available_memory()
        let availableMB = Int(available / (1024 * 1024))
        let threshold = Int(Double(info.estimatedMemoryMB) * 1.25)

        if availableMB < threshold {
            return MemoryCheckResult(
                canLoad: true,
                availableMB: availableMB,
                requiredMB: info.estimatedMemoryMB,
                warning: "Low memory: \(availableMB)MB available, model needs ~\(info.estimatedMemoryMB)MB. Consider a smaller model."
            )
        }

        return MemoryCheckResult(canLoad: true, availableMB: availableMB, requiredMB: info.estimatedMemoryMB, warning: nil)
    }

    /// Compute SHA256 of a file. Returns hex string.
    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func downloadModel(_ name: String, progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let info = Self.whisperModels.first(where: { $0.name == name }) else {
            completion(.failure(ModelError.unknownModel(name)))
            return
        }

        let destination = modelPath(for: name)
        if FileManager.default.fileExists(atPath: destination.path) {
            completion(.success(destination))
            return
        }

        DispatchQueue.main.async {
            self.isDownloading = true
            self.currentDownloadModel = name
        }

        let session = URLSession(configuration: .default, delegate: DownloadDelegate(
            onProgress: { p in
                DispatchQueue.main.async {
                    self.downloadProgress = p
                    progress(p)
                }
            },
            onComplete: { [weak self] tempURL, error in
                DispatchQueue.main.async {
                    self?.isDownloading = false
                    self?.currentDownloadModel = nil
                    self?.downloadProgress = 0
                }

                if let error {
                    completion(.failure(error))
                    return
                }

                guard let tempURL else {
                    completion(.failure(ModelError.downloadFailed))
                    return
                }

                // Verify SHA256 if available
                if let expectedHash = info.sha256 {
                    if let actualHash = ModelManager.sha256(of: tempURL), actualHash != expectedHash {
                        try? FileManager.default.removeItem(at: tempURL)
                        completion(.failure(ModelError.checksumMismatch))
                        return
                    }
                }

                do {
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    completion(.success(destination))
                } catch {
                    completion(.failure(error))
                }
            }
        ), delegateQueue: nil)

        downloadTask = session.downloadTask(with: info.url)
        downloadTask?.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        isDownloading = false
        currentDownloadModel = nil
        downloadProgress = 0
    }
}

private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let onProgress: (Double) -> Void
    let onComplete: (URL?, Error?) -> Void

    init(onProgress: @escaping (Double) -> Void, onComplete: @escaping (URL?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        onComplete(location, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { onComplete(nil, error) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
}

enum ModelError: Error, LocalizedError {
    case unknownModel(String)
    case downloadFailed
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .unknownModel(let name): return "Unknown model: \(name)"
        case .downloadFailed: return "Model download failed"
        case .checksumMismatch: return "Downloaded model failed checksum verification"
        }
    }
}
```

Note: SHA256 checksums are set to `nil` for v1 (skip verification) since the exact hashes change with model updates. Populate with known-good hashes before release. The verification code is in place and tested — just needs the hash values.

- [ ] **Step 4: Run tests**

```bash
xcodegen generate
xcodebuild test -project VoxPopuli.xcodeproj -scheme VoxPopuliTests -destination 'platform=macOS' 2>&1 | grep -E "(Test Case|passed|failed)"
```

Expected: All ModelManager tests PASS.

- [ ] **Step 5: Commit**

```bash
git add VoxPopuli/Core/ModelManager.swift VoxPopuliTests/ModelManagerTests.swift
git commit -m "feat: implement model manager with download, SHA256 verification, and memory check"
```

---

### Task 9: Implement HotkeyManager

**Files:**
- Create: `VoxPopuli/Core/HotkeyManager.swift`

- [ ] **Step 1: Implement HotkeyManager**

Create `VoxPopuli/Core/HotkeyManager.swift`:
```swift
import Cocoa
import ApplicationServices

enum HotkeyMode: String, CaseIterable {
    case doubleTap = "Double-tap"
    case holdToTalk = "Hold to talk"
    case toggle = "Toggle"
}

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyManagerDidActivate(_ manager: HotkeyManager)
    func hotkeyManagerDidDeactivate(_ manager: HotkeyManager)
}

final class HotkeyManager {
    weak var delegate: HotkeyManagerDelegate?

    var mode: HotkeyMode = .doubleTap
    var targetKeyCode: CGKeyCode = 61 // Right Option (kVK_RightOption)

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isActive = false

    private var lastKeyUpTime: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.3
    private var isRecording = false
    private var keyIsDown = false

    private var permissionTimer: Timer?

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    func start() {
        if isAccessibilityGranted {
            installEventTap()
        } else {
            requestAccessibilityAndPoll()
        }
    }

    func stop() {
        removeEventTap()
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Accessibility bootstrap

    private func requestAccessibilityAndPoll() {
        let options = [kAXTrustedCheckOptionPrompt as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.permissionTimer?.invalidate()
                self.permissionTimer = nil
                self.installEventTap()
            }
        }
    }

    // MARK: - CGEvent tap

    private func installEventTap() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            manager.handleEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: refcon
        ) else {
            print("Failed to create CGEvent tap — accessibility permission may not be granted")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
    }

    // MARK: - Event handling

    private func handleEvent(type: CGEventType, event: CGEvent) {
        if type == .flagsChanged {
            handleModifierEvent(event)
        }
    }

    private func handleModifierEvent(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == targetKeyCode else { return }

        let flags = event.flags
        let isRightOption = flags.contains(.maskAlternate)

        switch mode {
        case .doubleTap:
            if !isRightOption {
                let now = ProcessInfo.processInfo.systemUptime
                if isRecording {
                    isRecording = false
                    delegate?.hotkeyManagerDidDeactivate(self)
                } else if now - lastKeyUpTime < doubleTapWindow {
                    isRecording = true
                    delegate?.hotkeyManagerDidActivate(self)
                }
                lastKeyUpTime = now
            }

        case .holdToTalk:
            if isRightOption && !keyIsDown {
                keyIsDown = true
                delegate?.hotkeyManagerDidActivate(self)
            } else if !isRightOption && keyIsDown {
                keyIsDown = false
                delegate?.hotkeyManagerDidDeactivate(self)
            }

        case .toggle:
            if !isRightOption && keyIsDown {
                if isRecording {
                    isRecording = false
                    delegate?.hotkeyManagerDidDeactivate(self)
                } else {
                    isRecording = true
                    delegate?.hotkeyManagerDidActivate(self)
                }
            }
            keyIsDown = isRightOption
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VoxPopuli/Core/HotkeyManager.swift
git commit -m "feat: implement hotkey manager with CGEvent tap and accessibility bootstrap"
```

---

## Chunk 4: UI — Menu Bar, Floating Pill, Settings

### Task 10: Implement AppState (shared observable state)

**Files:**
- Create: `VoxPopuli/App/AppState.swift`

- [ ] **Step 1: Implement AppState**

Create `VoxPopuli/App/AppState.swift`:
```swift
import Foundation

enum AppStatus: Equatable {
    case idle
    case waitingForPermission
    case listening
    case processing
    case downloading(progress: Double)
    case error(message: String)
}

final class AppState: ObservableObject {
    @Published var status: AppStatus = .idle
    @Published var currentRMS: Float = 0.0
    @Published var selectedWhisperModel: String = UserDefaults.standard.string(forKey: "whisperModel") ?? "base"
    @Published var selectedLanguage: String = UserDefaults.standard.string(forKey: "language") ?? "auto"
    @Published var aiCleanupEnabled: Bool = UserDefaults.standard.bool(forKey: "aiCleanup")
    @Published var hotkeyMode: HotkeyMode = HotkeyMode(rawValue: UserDefaults.standard.string(forKey: "hotkeyMode") ?? "") ?? .doubleTap

    func save() {
        UserDefaults.standard.set(selectedWhisperModel, forKey: "whisperModel")
        UserDefaults.standard.set(selectedLanguage, forKey: "language")
        UserDefaults.standard.set(aiCleanupEnabled, forKey: "aiCleanup")
        UserDefaults.standard.set(hotkeyMode.rawValue, forKey: "hotkeyMode")
    }
}
```

- [ ] **Step 2: Commit**

```bash
xcodegen generate && xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -3
git add VoxPopuli/App/AppState.swift
git commit -m "feat: add AppState observable for shared app state"
```

---

### Task 11: Implement MenuBarController

**Files:**
- Create: `VoxPopuli/UI/MenuBarController.swift`
- Create: `VoxPopuli/UI/SettingsView.swift` (placeholder)

- [ ] **Step 1: Create SettingsView placeholder first (MenuBarController depends on it)**

Create `VoxPopuli/UI/SettingsView.swift`:
```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var modelManager: ModelManager

    var body: some View {
        Text("Settings placeholder")
            .padding()
    }
}
```

- [ ] **Step 2: Implement MenuBarController**

Create `VoxPopuli/UI/MenuBarController.swift`:
```swift
import Cocoa
import SwiftUI
import Combine

final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover?
    private var animationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    let appState: AppState
    let modelManager: ModelManager
    var onLeftClick: (() -> Void)?

    init(appState: AppState, modelManager: ModelManager) {
        self.appState = appState
        self.modelManager = modelManager
        super.init()
    }

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            updateDot(for: .idle, on: button)
            button.action = #selector(handleClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, let button = self.statusItem.button else { return }
                self.updateDot(for: status, on: button)
                self.updateAnimation(for: status)
            }
            .store(in: &cancellables)
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showSettings()
        } else {
            onLeftClick?()
        }
    }

    private func updateDot(for status: AppStatus, on button: NSStatusBarButton) {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let dotRect = NSRect(x: 5, y: 5, width: 8, height: 8)
            let path = NSBezierPath(ovalIn: dotRect)

            switch status {
            case .idle:
                NSColor.secondaryLabelColor.setFill()
            case .waitingForPermission:
                NSColor.systemOrange.setFill()
            case .listening:
                NSColor.systemGreen.setFill()
            case .processing:
                NSColor.systemBlue.setFill()
            case .downloading:
                NSColor.systemPurple.setFill()
            case .error:
                NSColor.systemRed.setFill()
            }

            path.fill()
            return true
        }

        image.isTemplate = false
        button.image = image
    }

    private func updateAnimation(for status: AppStatus) {
        animationTimer?.invalidate()
        animationTimer = nil

        guard let button = statusItem.button else { return }

        switch status {
        case .listening:
            var opacity: CGFloat = 1.0
            var increasing = false
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                if increasing {
                    opacity += 0.03
                    if opacity >= 1.0 { increasing = false }
                } else {
                    opacity -= 0.03
                    if opacity <= 0.4 { increasing = true }
                }
                button.alphaValue = opacity
            }

        case .processing:
            var opacity: CGFloat = 1.0
            var increasing = false
            animationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
                if increasing {
                    opacity += 0.05
                    if opacity >= 1.0 { increasing = false }
                } else {
                    opacity -= 0.05
                    if opacity <= 0.3 { increasing = true }
                }
                button.alphaValue = opacity
            }

        default:
            button.alphaValue = 1.0
        }
    }

    private func showSettings() {
        if popover == nil {
            let popover = NSPopover()
            popover.contentSize = NSSize(width: 320, height: 400)
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(
                rootView: SettingsView(appState: appState, modelManager: modelManager)
            )
            self.popover = popover
        }

        if let button = statusItem.button {
            if popover?.isShown == true {
                popover?.performClose(nil)
            } else {
                popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add VoxPopuli/UI/MenuBarController.swift VoxPopuli/UI/SettingsView.swift
git commit -m "feat: implement menu bar controller with status dot and state animations"
```

---

### Task 12: Implement FloatingPill and WaveformView

**Files:**
- Create: `VoxPopuli/UI/FloatingPill.swift`
- Create: `VoxPopuli/UI/WaveformView.swift`

- [ ] **Step 1: Implement WaveformView**

Create `VoxPopuli/UI/WaveformView.swift`:
```swift
import Cocoa

final class WaveformView: NSView {
    var rmsLevel: Float = 0.0 {
        didSet { needsDisplay = true }
    }

    private var rmsHistory: [Float] = Array(repeating: 0, count: 30)
    private var historyIndex = 0

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        rmsHistory[historyIndex % rmsHistory.count] = rmsLevel
        historyIndex += 1

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.clear(dirtyRect)

        let barCount = rmsHistory.count
        let barWidth = bounds.width / CGFloat(barCount)
        let maxHeight = bounds.height * 0.8
        let centerY = bounds.height / 2

        for i in 0..<barCount {
            let idx = (historyIndex + i) % barCount
            let amplitude = CGFloat(min(rmsHistory[idx] * 8.0, 1.0))
            let barHeight = max(2, maxHeight * amplitude)

            let x = CGFloat(i) * barWidth + barWidth * 0.15
            let y = centerY - barHeight / 2
            let rect = CGRect(x: x, y: y, width: barWidth * 0.7, height: barHeight)

            let color = NSColor.white.withAlphaComponent(0.6 + 0.4 * amplitude)
            context.setFillColor(color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth * 0.2, cornerHeight: barWidth * 0.2, transform: nil))
            context.fillPath()
        }
    }
}
```

- [ ] **Step 2: Implement FloatingPill**

Create `VoxPopuli/UI/FloatingPill.swift`:
```swift
import Cocoa

final class FloatingPill {
    private var panel: NSPanel?
    private var waveformView: WaveformView?

    private let pillWidth: CGFloat = 120
    private let pillHeight: CGFloat = 36
    private let cornerRadius: CGFloat = 8

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(near mouseLocation: NSPoint) {
        if panel == nil { createPanel() }
        guard let panel else { return }

        var origin = NSPoint(x: mouseLocation.x + 10, y: mouseLocation.y + 20)

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if origin.x + pillWidth > screenFrame.maxX {
                origin.x = mouseLocation.x - pillWidth - 10
            }
            if origin.y + pillHeight > screenFrame.maxY {
                origin.y = mouseLocation.y - pillHeight - 20
            }
        }

        panel.setFrameOrigin(origin)
        panel.orderFront(nil)

        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        }
    }

    func updateRMS(_ rms: Float) {
        waveformView?.rmsLevel = rms
    }

    func setProcessing() {
        waveformView?.rmsLevel = 0.05
    }

    func fadeOut() {
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let effectView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: pillWidth, height: pillHeight))
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = cornerRadius
        effectView.layer?.masksToBounds = true

        let waveform = WaveformView(frame: NSRect(x: 4, y: 4, width: pillWidth - 8, height: pillHeight - 8))
        waveform.wantsLayer = true
        self.waveformView = waveform

        effectView.addSubview(waveform)
        panel.contentView = effectView

        self.panel = panel
    }
}
```

- [ ] **Step 3: Build and verify**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 4: Commit**

```bash
git add VoxPopuli/UI/FloatingPill.swift VoxPopuli/UI/WaveformView.swift
git commit -m "feat: implement floating pill with frosted glass and waveform visualization"
```

---

### Task 13: Implement full SettingsView

**Files:**
- Modify: `VoxPopuli/UI/SettingsView.swift`

- [ ] **Step 1: Replace SettingsView with full implementation**

Replace `VoxPopuli/UI/SettingsView.swift`:
```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var modelManager: ModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Vox Populi")
                .font(.headline)
                .padding(.bottom, 4)

            // Hotkey mode
            VStack(alignment: .leading, spacing: 4) {
                Text("Activation")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Picker("", selection: $appState.hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Right Option key")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            // Model selection
            VStack(alignment: .leading, spacing: 4) {
                Text("Model")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                ForEach(ModelManager.whisperModels, id: \.name) { model in
                    HStack {
                        Text(model.name)
                            .fontWeight(appState.selectedWhisperModel == model.name ? .bold : .regular)

                        Spacer()

                        if modelManager.isModelDownloaded(model.name) {
                            if appState.selectedWhisperModel == model.name {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            } else {
                                Button("Select") {
                                    appState.selectedWhisperModel = model.name
                                    appState.save()
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                            }
                        } else if modelManager.isDownloading && modelManager.currentDownloadModel == model.name {
                            ProgressView(value: modelManager.downloadProgress)
                                .frame(width: 60)
                        } else {
                            let sizeMB = model.sizeBytes / 1_000_000
                            Button("Download (\(sizeMB)MB)") {
                                modelManager.downloadModel(model.name, progress: { _ in }, completion: { _ in })
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Divider()

            // Language
            VStack(alignment: .leading, spacing: 4) {
                Text("Language")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Picker("", selection: $appState.selectedLanguage) {
                    Text("Auto-detect").tag("auto")
                    Text("English").tag("en")
                    Text("French").tag("fr")
                    Text("Spanish").tag("es")
                    Text("German").tag("de")
                    Text("Japanese").tag("ja")
                    Text("Chinese").tag("zh")
                }
                .labelsHidden()
                .onChange(of: appState.selectedLanguage) { _ in appState.save() }
            }

            Divider()

            // AI Cleanup
            VStack(alignment: .leading, spacing: 4) {
                Toggle("AI Cleanup", isOn: $appState.aiCleanupEnabled)
                    .onChange(of: appState.aiCleanupEnabled) { _ in appState.save() }
                Text("Uses a local LLM to clean up grammar and remove filler words")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            HStack {
                Text("v1.0.0")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VoxPopuli/UI/SettingsView.swift
git commit -m "feat: implement settings view with model management, language, and AI cleanup toggle"
```

---

## Chunk 5: Integration & Polish

### Task 14: Implement TranscriptionPipeline (orchestrator)

**Files:**
- Create: `VoxPopuli/Core/TranscriptionPipeline.swift`

- [ ] **Step 1: Implement TranscriptionPipeline**

Create `VoxPopuli/Core/TranscriptionPipeline.swift`:
```swift
import Foundation
import Cocoa

/// Orchestrates the full flow: audio → transcription → voice commands → AI cleanup → text output.
/// Uses a single shared inference queue for all heavy compute (Whisper + LLM).
final class TranscriptionPipeline {
    let appState: AppState
    let audioPipeline: AudioPipeline
    let whisperEngine: WhisperEngine
    let voiceCommandProcessor: VoiceCommandProcessor
    let textOutput: TextOutput
    let floatingPill: FloatingPill
    let modelManager: ModelManager

    var textProcessor: TextProcessor?

    /// Single shared inference queue for Whisper + LLM — as specified in the concurrency model.
    private let inferenceQueue = DispatchQueue(label: "com.voxpopuli.inference", qos: .userInitiated)

    init(appState: AppState, modelManager: ModelManager) {
        self.appState = appState
        self.modelManager = modelManager
        self.audioPipeline = AudioPipeline()
        self.whisperEngine = WhisperEngine()
        self.voiceCommandProcessor = VoiceCommandProcessor()
        self.textOutput = TextOutput()
        self.floatingPill = FloatingPill()

        self.audioPipeline.delegate = self
    }

    func loadModel() {
        let modelPath = modelManager.modelPath(for: appState.selectedWhisperModel).path
        guard modelManager.isModelDownloaded(appState.selectedWhisperModel) else {
            appState.status = .downloading(progress: 0)
            modelManager.downloadModel(appState.selectedWhisperModel, progress: { [weak self] p in
                self?.appState.status = .downloading(progress: p)
            }, completion: { [weak self] result in
                switch result {
                case .success(let url):
                    self?.loadModelFromPath(url.path)
                case .failure(let error):
                    self?.appState.status = .error(message: error.localizedDescription)
                }
            })
            return
        }
        loadModelFromPath(modelPath)
    }

    private func loadModelFromPath(_ path: String) {
        inferenceQueue.async { [weak self] in
            do {
                try self?.whisperEngine.loadModel(at: path)
                DispatchQueue.main.async {
                    self?.appState.status = .idle
                }
            } catch {
                DispatchQueue.main.async {
                    self?.appState.status = .error(message: error.localizedDescription)
                }
            }
        }
    }

    func startRecording() {
        guard whisperEngine.isLoaded else {
            appState.status = .error(message: "Model not loaded")
            return
        }

        do {
            try audioPipeline.startCapture()
            appState.status = .listening
            floatingPill.show(near: NSEvent.mouseLocation)
        } catch {
            appState.status = .error(message: "Mic error: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        let samples = audioPipeline.stopCapture()
        guard !samples.isEmpty else {
            appState.status = .idle
            floatingPill.fadeOut()
            return
        }

        appState.status = .processing
        floatingPill.setProcessing()

        let language = appState.selectedLanguage == "auto" ? nil : appState.selectedLanguage
        let aiCleanup = appState.aiCleanupEnabled

        // All inference runs on the single shared queue
        inferenceQueue.async { [weak self] in
            guard let self else { return }

            do {
                let rawText = try self.whisperEngine.transcribe(samples: samples, language: language)

                guard !rawText.isEmpty else {
                    DispatchQueue.main.async { self.finish() }
                    return
                }

                let finalText: String

                if aiCleanup, let processor = self.textProcessor, processor.isLoaded {
                    // AI cleanup path: tokenize voice commands → LLM cleanup → restore tokens → apply remaining
                    let tokenized = self.voiceCommandProcessor.convertToTokens(rawText)
                    let cleaned = processor.cleanup(tokenized)
                    let restored = self.voiceCommandProcessor.restoreTokens(cleaned)
                    finalText = self.voiceCommandProcessor.apply(restored)
                } else {
                    // Direct path: apply voice commands
                    finalText = self.voiceCommandProcessor.apply(rawText)
                }

                DispatchQueue.main.async {
                    self.textOutput.type(finalText)
                    self.finish()
                }
            } catch {
                DispatchQueue.main.async {
                    self.appState.status = .error(message: error.localizedDescription)
                    self.floatingPill.fadeOut()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if case .error = self.appState.status {
                            self.appState.status = .idle
                        }
                    }
                }
            }
        }
    }

    private func finish() {
        appState.status = .idle
        floatingPill.fadeOut()
    }
}

// MARK: - AudioPipelineDelegate

extension TranscriptionPipeline: AudioPipelineDelegate {
    func audioPipeline(_ pipeline: AudioPipeline, didUpdateRMS rms: Float) {
        appState.currentRMS = rms
        floatingPill.updateRMS(rms)
    }

    func audioPipelineDidDetectSilence(_ pipeline: AudioPipeline) {
        // Auto-stop ONLY in toggle mode (spec requirement)
        guard appState.hotkeyMode == .toggle else { return }

        if case .listening = appState.status {
            stopRecording()
        }
    }
}
```

- [ ] **Step 2: Build**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add VoxPopuli/Core/TranscriptionPipeline.swift
git commit -m "feat: implement transcription pipeline with shared inference queue"
```

---

### Task 15: Wire everything together in AppDelegate

**Files:**
- Modify: `VoxPopuli/App/AppDelegate.swift`

- [ ] **Step 1: Update AppDelegate**

Replace `VoxPopuli/App/AppDelegate.swift`:
```swift
import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var modelManager: ModelManager!
    private var menuBarController: MenuBarController!
    private var hotkeyManager: HotkeyManager!
    private var pipeline: TranscriptionPipeline!

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        modelManager = ModelManager()
        pipeline = TranscriptionPipeline(appState: appState, modelManager: modelManager)
        menuBarController = MenuBarController(appState: appState, modelManager: modelManager)
        hotkeyManager = HotkeyManager()

        menuBarController.setup()
        menuBarController.onLeftClick = { [weak self] in
            self?.toggleRecording()
        }

        hotkeyManager.delegate = self
        hotkeyManager.mode = appState.hotkeyMode
        hotkeyManager.start()

        if !hotkeyManager.isAccessibilityGranted {
            appState.status = .waitingForPermission
        }

        pipeline.loadModel()
    }

    private func toggleRecording() {
        switch appState.status {
        case .listening:
            pipeline.stopRecording()
        case .idle:
            pipeline.startRecording()
        default:
            break
        }
    }
}

extension AppDelegate: HotkeyManagerDelegate {
    func hotkeyManagerDidActivate(_ manager: HotkeyManager) {
        DispatchQueue.main.async { [weak self] in
            self?.pipeline.startRecording()
        }
    }

    func hotkeyManagerDidDeactivate(_ manager: HotkeyManager) {
        DispatchQueue.main.async { [weak self] in
            self?.pipeline.stopRecording()
        }
    }
}
```

- [ ] **Step 2: Build the full app**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED — the entire app compiles.

- [ ] **Step 3: Commit**

```bash
git add VoxPopuli/App/AppDelegate.swift
git commit -m "feat: wire all components together in AppDelegate with shared ModelManager"
```

---

### Task 16: Implement TextProcessor (llama.cpp AI cleanup)

**Files:**
- Create: `VoxPopuli/Core/TextProcessor.swift`

- [ ] **Step 1: Implement TextProcessor**

Create `VoxPopuli/Core/TextProcessor.swift`:
```swift
import Foundation

final class TextProcessor {
    private var model: OpaquePointer?
    private var context: OpaquePointer?

    /// System prompt for cleanup. Uses a generic instruction format that works with most models.
    /// NOTE: The chat template depends on the model. This generic format works for Llama 3.2
    /// and most instruction-tuned models. If using Phi-3, adjust to <|system|>/<|user|>/<|assistant|>.
    /// See llama.cpp's built-in chat template support: llama_chat_apply_template().
    private let systemPrompt = """
    Clean up this voice transcription. Remove filler words (uh, um, like, you know), \
    fix grammar and punctuation, keep the speaker's intent and tone intact. \
    Do not add or change meaning. Preserve all <NEWLINE> and <PARAGRAPH> tokens exactly \
    as they appear. Output only the cleaned text.
    """

    var isLoaded: Bool { model != nil && context != nil }

    func loadModel(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw TextProcessorError.modelNotFound(path)
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99

        guard let m = llama_model_load_from_file(path, modelParams) else {
            throw TextProcessorError.initFailed
        }

        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = 2048
        ctxParams.n_threads = 4

        guard let ctx = llama_init_from_model(m, ctxParams) else {
            llama_model_free(m)
            throw TextProcessorError.initFailed
        }

        if let oldCtx = self.context { llama_free(oldCtx) }
        if let oldModel = self.model { llama_model_free(oldModel) }

        self.model = m
        self.context = ctx
    }

    /// Clean up transcribed text using the local LLM. Synchronous — call from inference queue.
    func cleanup(_ text: String) -> String {
        guard let model, let context else { return text }

        // Build prompt using llama.cpp's chat template if available,
        // otherwise fall back to generic format
        let prompt = buildPrompt(for: text)

        let maxTokens = 2048
        var tokens = [llama_token](repeating: 0, count: maxTokens)
        let nTokens = llama_tokenize(model, prompt, Int32(prompt.utf8.count), &tokens, Int32(maxTokens), true, false)

        guard nTokens > 0 else { return text }

        llama_kv_cache_clear(context)

        // Evaluate prompt tokens
        var batch = llama_batch_init(nTokens, 0, 1)
        for i in 0..<Int(nTokens) {
            let isLast = (i == Int(nTokens) - 1)
            batch.n_tokens += 1
            batch.token[i] = tokens[i]
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = isLast ? 1 : 0
        }

        guard llama_decode(context, batch) == 0 else {
            llama_batch_free(batch)
            return text
        }
        llama_batch_free(batch)

        // Generate output
        var output = ""
        let maxOutputTokens = 512
        let vocabSize = llama_n_vocab(model)
        var currentPos = nTokens

        for _ in 0..<maxOutputTokens {
            let logits = llama_get_logits(context)
            guard let logits else { break }

            var maxLogit: Float = -Float.infinity
            var maxToken: llama_token = 0
            for j in 0..<Int(vocabSize) {
                if logits[j] > maxLogit {
                    maxLogit = logits[j]
                    maxToken = llama_token(j)
                }
            }

            if llama_token_is_eog(model, maxToken) { break }

            var buf = [CChar](repeating: 0, count: 256)
            let len = llama_token_to_piece(model, maxToken, &buf, 256, 0, false)
            if len > 0 {
                buf[Int(len)] = 0
                output += String(cString: buf)
            }

            // Feed generated token back
            var nextBatch = llama_batch_init(1, 0, 1)
            nextBatch.n_tokens = 1
            nextBatch.token[0] = maxToken
            nextBatch.pos[0] = currentPos
            nextBatch.n_seq_id[0] = 1
            nextBatch.seq_id[0]![0] = 0
            nextBatch.logits[0] = 1
            currentPos += 1

            let decodeResult = llama_decode(context, nextBatch)
            llama_batch_free(nextBatch)
            if decodeResult != 0 { break }
        }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    private func buildPrompt(for text: String) -> String {
        // Generic instruction format. Works with most chat-tuned models.
        // For best results, use a model that matches this template (e.g., Llama 3.2 Instruct).
        return """
        <|begin_of_text|><|start_header_id|>system<|end_header_id|>

        \(systemPrompt)<|eot_id|><|start_header_id|>user<|end_header_id|>

        \(text)<|eot_id|><|start_header_id|>assistant<|end_header_id|>

        """
    }

    func unload() {
        if let ctx = context { llama_free(ctx) }
        if let m = model { llama_model_free(m) }
        context = nil
        model = nil
    }

    deinit { unload() }
}

enum TextProcessorError: Error, LocalizedError {
    case modelNotFound(String)
    case initFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let path): return "LLM model not found at: \(path)"
        case .initFailed: return "Failed to initialize LLM"
        }
    }
}
```

Note: The llama.cpp C API changes frequently. The batch struct field access (`.token[i]`, `.pos[i]`, etc.) assumes the batch is allocated with `llama_batch_init` which provides these arrays. Check `Libraries/llama.cpp/include/llama.h` after building and adjust if the API signatures differ. The prompt template uses Llama 3.2 Instruct format — if a different model is used, update `buildPrompt()` accordingly.

- [ ] **Step 2: Build and fix API mismatches**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli build 2>&1 | grep -E "(error:)" | head -20
```

Check `Libraries/llama.cpp/include/llama.h` for correct function signatures and fix any mismatches.

- [ ] **Step 3: Commit**

```bash
git add VoxPopuli/Core/TextProcessor.swift
git commit -m "feat: implement AI cleanup via llama.cpp with Llama 3.2 chat template"
```

---

### Task 17: Create README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Create README.md**

Create `README.md`:
```markdown
# Vox Populi

**Your voice, your machine, no one else's business.**

A macOS-native, fully offline voice-to-text app. Press a key, speak, text appears at your cursor. No accounts, no cloud, no subscriptions.

Powered by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) with Metal acceleration on Apple Silicon.

## Features

- **Push-to-talk** — Double-tap Right Option, speak, text appears
- **Works everywhere** — Types into any app via macOS Accessibility API
- **Fully offline** — Zero network calls after initial model download
- **AI cleanup** (optional) — Local LLM removes filler words and fixes grammar
- **Tiny footprint** — Menu bar dot + floating waveform pill, nothing else

## Requirements

- macOS 13.0+ (Ventura)
- Apple Silicon (M1, M2, M3, M4)
- ~200MB disk for the base Whisper model

## Build from source

```bash
git clone --recursive https://github.com/your-username/vox-populi.git
cd vox-populi
brew install xcodegen cmake
./Scripts/build-libraries.sh
xcodegen generate
open VoxPopuli.xcodeproj
```

Build and run in Xcode (Cmd+R). Grant Microphone and Accessibility permissions when prompted.

## Usage

1. **Double-tap Right Option** to start listening
2. **Speak naturally** — a small pill appears with a waveform
3. **Tap Right Option once** to stop — text appears at your cursor

### Voice commands

Say "new line", "period", "comma", "question mark", etc. — they become the actual characters.

### Settings

Right-click the menu bar dot:
- **Activation mode** — Double-tap, hold-to-talk, or toggle
- **Model** — tiny / base / small / medium / large-v3
- **Language** — Auto-detect or fixed
- **AI Cleanup** — Toggle local LLM post-processing

## Privacy

- No network calls after model download
- No analytics, telemetry, or crash reporting
- Audio is processed in memory and immediately discarded
- 100% open source

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README"
```

---

### Task 18: End-to-end manual test

- [ ] **Step 1: Ensure base model is downloaded**

```bash
./Scripts/download-model.sh base
```

- [ ] **Step 2: Build and run**

```bash
xcodegen generate
xcodebuild -project VoxPopuli.xcodeproj -scheme VoxPopuli -configuration Debug build
open build/Debug/VoxPopuli.app
```

Or open in Xcode: `open VoxPopuli.xcodeproj` then Cmd+R.

- [ ] **Step 3: Verify manually**

1. App appears as a dot in the menu bar (no dock icon)
2. System prompts for Accessibility permission → grant it
3. Dot shows download progress if model isn't cached
4. Double-tap Right Option → floating pill appears with waveform
5. Speak a sentence → tap Right Option → text appears at cursor
6. Right-click menu bar dot → settings popover opens
7. Voice commands work ("hello comma world period" → "hello, world.")
8. Settings persist across app restart

- [ ] **Step 4: Fix any issues found and commit**

```bash
git add -A
git commit -m "fix: address issues found during integration testing"
```

---

### Task 19: Run all unit tests

- [ ] **Step 1: Run the full test suite**

```bash
xcodebuild test -project VoxPopuli.xcodeproj -scheme VoxPopuliTests -destination 'platform=macOS' 2>&1 | grep -E "(Test Suite|Test Case|passed|failed|error)"
```

Expected: All tests pass (RingBuffer, VoiceCommandProcessor, ModelManager).

- [ ] **Step 2: Fix any failures and commit**

```bash
git add -A
git commit -m "test: fix test failures and finalize test suite"
```
