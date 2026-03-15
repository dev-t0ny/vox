import Foundation

enum WhisperEngineError: Error {
    case modelLoadFailed
    case transcriptionFailed
    case notLoaded
}

final class WhisperEngine {
    private var context: OpaquePointer?

    var isLoaded: Bool { context != nil }

    func loadModel(at path: String) throws {
        unload()
        var cparams = whisper_context_default_params()
        #if targetEnvironment(simulator)
        cparams.use_gpu = false
        #endif
        guard let ctx = whisper_init_from_file_with_params(path, cparams) else {
            throw WhisperEngineError.modelLoadFailed
        }
        self.context = ctx
    }

    /// Synchronous transcription — caller dispatches to background queue
    func transcribe(samples: [Float], language: String? = nil) throws -> String {
        guard let ctx = context else { throw WhisperEngineError.notLoaded }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        params.no_timestamps = true
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.print_timestamps = false
        params.single_segment = false

        // Handle language string safely — strdup to avoid dangling pointer
        var langPtr: UnsafeMutablePointer<CChar>?
        if let lang = language {
            langPtr = strdup(lang)
            params.language = UnsafePointer(langPtr)
        }

        let result = samples.withUnsafeBufferPointer { bufferPtr -> Int32 in
            whisper_full(ctx, params, bufferPtr.baseAddress, Int32(samples.count))
        }

        free(langPtr)

        guard result == 0 else { throw WhisperEngineError.transcriptionFailed }

        let segmentCount = whisper_full_n_segments(ctx)
        var text = ""
        for i in 0..<segmentCount {
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
