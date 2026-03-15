import Foundation

/// Wraps llama.cpp to perform AI text cleanup on voice transcriptions.
/// All public methods are synchronous and must be called from the shared inference queue.
final class TextProcessor {

    private var model: OpaquePointer?   // llama_model *
    private var ctx: OpaquePointer?     // llama_context *

    private let maxOutputTokens: Int32 = 512

    private static let systemPrompt = """
        Clean up this voice transcription. Remove filler words (uh, um, like, you know), \
        fix grammar and punctuation, keep the speaker's intent and tone intact. Do not add \
        or change meaning. Preserve all <NEWLINE> and <PARAGRAPH> tokens exactly as they \
        appear. Output only the cleaned text.
        """

    var isLoaded: Bool { model != nil && ctx != nil }

    // MARK: - Load / Unload

    func loadModel(at path: String) throws {
        unload()

        llama_backend_init()

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = -1 // offload everything

        guard let m = llama_model_load_from_file(path, mparams) else {
            throw TextProcessorError.modelLoadFailed
        }
        model = m

        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048
        cparams.n_batch = 512
        cparams.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))
        cparams.n_threads_batch = cparams.n_threads

        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            self.model = nil
            throw TextProcessorError.contextCreationFailed
        }
        ctx = c
    }

    func unload() {
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil
        model = nil
    }

    deinit {
        unload()
        llama_backend_free()
    }

    // MARK: - Cleanup

    /// Synchronous AI cleanup. Called from the shared inference queue.
    func cleanup(_ text: String) -> String {
        guard let model = model, let ctx = ctx else { return text }

        let vocab = llama_model_get_vocab(model)!

        // Build Llama 3.2 Instruct prompt
        let prompt = """
            <|begin_of_text|><|start_header_id|>system<|end_header_id|>

            \(Self.systemPrompt)<|eot_id|><|start_header_id|>user<|end_header_id|>

            \(text)<|eot_id|><|start_header_id|>assistant<|end_header_id|>

            """

        // Tokenize
        let promptTokens = tokenize(vocab: vocab, text: prompt, addSpecial: false, parseSpecial: true)
        guard !promptTokens.isEmpty else { return text }

        // Clear KV cache
        let memory = llama_get_memory(ctx)
        llama_memory_clear(memory, true)

        // Evaluate prompt
        var batch = llama_batch_init(Int32(promptTokens.count), 0, 1)
        defer { llama_batch_free(batch) }

        for (i, token) in promptTokens.enumerated() {
            batch.token[i] = token
            batch.pos[i] = Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = (i == promptTokens.count - 1) ? 1 : 0
        }
        batch.n_tokens = Int32(promptTokens.count)

        let decodeResult = llama_decode(ctx, batch)
        guard decodeResult == 0 else { return text }

        // Generate
        let nVocab = llama_vocab_n_tokens(vocab)
        var outputTokens: [llama_token] = []
        var currentPos = Int32(promptTokens.count)

        for _ in 0..<maxOutputTokens {
            // Greedy sampling: pick the token with the highest logit
            guard let logits = llama_get_logits_ith(ctx, -1) else { break }

            var bestToken: llama_token = 0
            var bestLogit: Float = logits[0]
            for j in 1..<Int(nVocab) {
                if logits[j] > bestLogit {
                    bestLogit = logits[j]
                    bestToken = Int32(j)
                }
            }

            // Check for end of generation
            if llama_vocab_is_eog(vocab, bestToken) { break }

            outputTokens.append(bestToken)

            // Prepare next batch (single token)
            llama_batch_free(batch)
            batch = llama_batch_init(1, 0, 1)
            batch.token[0] = bestToken
            batch.pos[0] = currentPos
            batch.n_seq_id[0] = 1
            batch.seq_id[0]![0] = 0
            batch.logits[0] = 1
            batch.n_tokens = 1
            currentPos += 1

            let result = llama_decode(ctx, batch)
            if result != 0 { break }
        }

        let generated = detokenize(vocab: vocab, tokens: outputTokens)
        let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed.isEmpty ? text : trimmed
    }

    // MARK: - Tokenization Helpers

    private func tokenize(vocab: OpaquePointer, text: String, addSpecial: Bool, parseSpecial: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8)
        let maxTokens = Int32(utf8.count + 16)
        var tokens = [llama_token](repeating: 0, count: Int(maxTokens))

        let nTokens = utf8.withUnsafeBufferPointer { buf -> Int32 in
            let ptr = buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { $0 }
            return llama_tokenize(vocab, ptr, Int32(buf.count), &tokens, maxTokens, addSpecial, parseSpecial)
        }

        if nTokens < 0 {
            // Buffer too small, retry with exact size
            let needed = -nTokens
            tokens = [llama_token](repeating: 0, count: Int(needed))
            let n2 = utf8.withUnsafeBufferPointer { buf -> Int32 in
                let ptr = buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { $0 }
                return llama_tokenize(vocab, ptr, Int32(buf.count), &tokens, needed, addSpecial, parseSpecial)
            }
            if n2 < 0 { return [] }
            return Array(tokens.prefix(Int(n2)))
        }

        return Array(tokens.prefix(Int(nTokens)))
    }

    private func detokenize(vocab: OpaquePointer, tokens: [llama_token]) -> String {
        var result = ""
        var buf = [CChar](repeating: 0, count: 256)

        for token in tokens {
            let nChars = llama_token_to_piece(vocab, token, &buf, Int32(buf.count), 0, false)
            if nChars > 0 {
                buf[Int(nChars)] = 0
                result += String(cString: buf)
            }
        }

        return result
    }
}

// MARK: - Errors

enum TextProcessorError: Error, LocalizedError {
    case modelLoadFailed
    case contextCreationFailed

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed: return "Failed to load LLM model"
        case .contextCreationFailed: return "Failed to create LLM context"
        }
    }
}
