import Foundation
import Cocoa

final class TranscriptionPipeline {
    let appState: AppState
    let audioPipeline: AudioPipeline
    let whisperEngine: WhisperEngine
    let voiceCommandProcessor: VoiceCommandProcessor
    let textOutput: TextOutput
    let floatingPill: FloatingPill
    let modelManager: ModelManager
    var textProcessor: TextProcessor?

    /// Single shared inference queue for all heavy compute (Whisper + LLM)
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
        let modelName = appState.selectedWhisperModel
        let modelPath = modelManager.modelPath(for: modelName)

        if modelManager.isModelDownloaded(modelName) {
            appState.status = .processing
            inferenceQueue.async { [weak self] in
                guard let self else { return }
                do {
                    try self.whisperEngine.loadModel(at: modelPath.path)
                    DispatchQueue.main.async {
                        self.appState.status = .idle
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.appState.status = .error(message: "Model load failed: \(error.localizedDescription)")
                    }
                }
            }
        } else {
            appState.status = .downloading(progress: 0.0)
            modelManager.downloadModel(name: modelName) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.appState.status = .processing
                    self.inferenceQueue.async {
                        do {
                            try self.whisperEngine.loadModel(at: url.path)
                            DispatchQueue.main.async {
                                self.appState.status = .idle
                            }
                        } catch {
                            DispatchQueue.main.async {
                                self.appState.status = .error(message: "Model load failed: \(error.localizedDescription)")
                            }
                        }
                    }
                case .failure(let error):
                    self.appState.status = .error(message: "Download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private var recordingStartTime: Date?
    private var targetApp: NSRunningApplication?

    func startRecording() {
        guard whisperEngine.isLoaded else {
            print("❌ [Pipeline] Model not loaded, can't record")
            return
        }
        do {
            // Capture the frontmost app NOW — before anything changes focus
            targetApp = NSWorkspace.shared.frontmostApplication
            print("🎙️ [Pipeline] Target app: \(targetApp?.localizedName ?? "unknown")")

            try audioPipeline.startCapture()
            recordingStartTime = Date()
            appState.status = .listening
            floatingPill.resetWaveform()
            floatingPill.show(near: NSEvent.mouseLocation)
            print("🎙️ [Pipeline] Recording started")
        } catch {
            print("❌ [Pipeline] Mic error: \(error)")
            appState.status = .error(message: "Mic error: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        let samples = audioPipeline.stopCapture()
        print("🎙️ [Pipeline] Stopped recording, got \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000.0))s audio)")

        guard !samples.isEmpty else {
            print("⚠️ [Pipeline] No audio samples captured")
            appState.status = .idle
            floatingPill.fadeOut()
            return
        }

        appState.status = .processing
        floatingPill.setProcessing()

        let language = appState.selectedLanguage == "auto" ? nil : appState.selectedLanguage
        let aiCleanup = appState.aiCleanupEnabled

        print("🎙️ [Pipeline] Transcribing \(samples.count) samples...")
        inferenceQueue.async { [weak self] in
            guard let self else { return }
            do {
                let rawText = try self.whisperEngine.transcribe(samples: samples, language: language)
                print("🎙️ [Pipeline] Whisper result: \"\(rawText)\"")

                guard !rawText.isEmpty else {
                    print("⚠️ [Pipeline] Empty transcription")
                    DispatchQueue.main.async { self.finish() }
                    return
                }

                let finalText: String
                if aiCleanup, let processor = self.textProcessor, processor.isLoaded {
                    let tokenized = self.voiceCommandProcessor.convertToTokens(rawText)
                    let cleaned = processor.cleanup(tokenized)
                    let restored = self.voiceCommandProcessor.restoreTokens(cleaned)
                    finalText = self.voiceCommandProcessor.apply(restored)
                } else {
                    finalText = self.voiceCommandProcessor.apply(rawText)
                }

                let duration = self.recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
                print("🎙️ [Pipeline] Final text: \"\(finalText)\"")
                print("🎙️ [Pipeline] Waiting 250ms for modifier keys to release...")
                DispatchQueue.main.async {
                    self.appState.addTranscript(finalText, duration: duration)
                    // Delay paste by 250ms to let the Option key fully release
                    // Otherwise Cmd+V becomes Option+Cmd+V which doesn't paste
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        self.textOutput.type(finalText, targetApp: self.targetApp)
                        self.finish()
                    }
                }
            } catch {
                print("❌ [Pipeline] Transcription error: \(error)")
                DispatchQueue.main.async {
                    self.appState.status = .error(message: error.localizedDescription)
                    self.floatingPill.fadeOut()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if case .error = self.appState.status { self.appState.status = .idle }
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

extension TranscriptionPipeline: AudioPipelineDelegate {
    func audioPipeline(_ pipeline: AudioPipeline, didUpdateRMS rms: Float) {
        appState.currentRMS = rms
        floatingPill.updateRMS(rms)
    }

    func audioPipelineDidDetectSilence(_ pipeline: AudioPipeline) {
        // ONLY auto-stop in toggle mode (spec requirement)
        guard appState.hotkeyMode == .toggle else { return }
        if case .listening = appState.status { stopRecording() }
    }
}
