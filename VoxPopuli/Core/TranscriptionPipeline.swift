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

    func startRecording() {
        guard whisperEngine.isLoaded else { return }
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

        // ALL inference on the single shared queue
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
                    let tokenized = self.voiceCommandProcessor.convertToTokens(rawText)
                    let cleaned = processor.cleanup(tokenized)
                    let restored = self.voiceCommandProcessor.restoreTokens(cleaned)
                    finalText = self.voiceCommandProcessor.apply(restored)
                } else {
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
