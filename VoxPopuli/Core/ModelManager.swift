import Foundation
import Combine
import CommonCrypto

// MARK: - Model Info

struct WhisperModelInfo {
    let name: String
    let fileName: String
    let displayName: String
    let url: URL
    let sizeBytes: Int64
    let estimatedMemoryMB: Int
    let expectedSHA256: String?
}

// MARK: - Memory Check Result

enum MemoryCheckResult {
    case canLoad
    case lowMemory(availableMB: Int, requiredMB: Int)
    case insufficientMemory(availableMB: Int, requiredMB: Int)
}

// MARK: - ModelManager

final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate {

    // MARK: - Static model catalog

    static let whisperModels: [WhisperModelInfo] = [
        WhisperModelInfo(
            name: "tiny",
            fileName: "ggml-tiny.bin",
            displayName: "Tiny (75 MB)",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")!,
            sizeBytes: 75_000_000,
            estimatedMemoryMB: 150,
            expectedSHA256: nil
        ),
        WhisperModelInfo(
            name: "base",
            fileName: "ggml-base.bin",
            displayName: "Base (142 MB)",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")!,
            sizeBytes: 142_000_000,
            estimatedMemoryMB: 300,
            expectedSHA256: nil
        ),
        WhisperModelInfo(
            name: "small",
            fileName: "ggml-small.bin",
            displayName: "Small (466 MB)",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")!,
            sizeBytes: 466_000_000,
            estimatedMemoryMB: 600,
            expectedSHA256: nil
        ),
        WhisperModelInfo(
            name: "medium",
            fileName: "ggml-medium.bin",
            displayName: "Medium (1.5 GB)",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")!,
            sizeBytes: 1_500_000_000,
            estimatedMemoryMB: 1800,
            expectedSHA256: nil
        ),
        WhisperModelInfo(
            name: "large-v3",
            fileName: "ggml-large-v3.bin",
            displayName: "Large v3 (3.1 GB)",
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!,
            sizeBytes: 3_100_000_000,
            estimatedMemoryMB: 3800,
            expectedSHA256: nil
        ),
    ]

    // MARK: - Published properties

    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading: Bool = false
    @Published var currentDownloadModel: String?

    // MARK: - Properties

    let modelsDirectory: URL

    private var downloadTask: URLSessionDownloadTask?
    private var downloadCompletion: ((Result<URL, Error>) -> Void)?
    private lazy var downloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()

    // MARK: - Init

    init(modelsDirectory: URL? = nil) {
        if let dir = modelsDirectory {
            self.modelsDirectory = dir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.modelsDirectory = appSupport.appendingPathComponent("VoxPopuli/models")
        }
        super.init()

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: self.modelsDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    // MARK: - Model path helpers

    func modelPath(for name: String) -> URL {
        let info = Self.whisperModels.first { $0.name == name }
        let fileName = info?.fileName ?? "ggml-\(name).bin"
        return modelsDirectory.appendingPathComponent(fileName)
    }

    func isModelDownloaded(_ name: String) -> Bool {
        let path = modelPath(for: name)
        return FileManager.default.fileExists(atPath: path.path)
    }

    // MARK: - Memory check

    func checkMemoryForModel(_ name: String) -> MemoryCheckResult {
        guard let info = Self.whisperModels.first(where: { $0.name == name }) else {
            return .canLoad
        }

        let availableBytes = availableMemoryBytes()
        let availableMB = Int(availableBytes / (1024 * 1024))
        let requiredMB = info.estimatedMemoryMB

        if availableMB >= requiredMB {
            return .canLoad
        } else if availableMB >= requiredMB / 2 {
            return .lowMemory(availableMB: availableMB, requiredMB: requiredMB)
        } else {
            return .insufficientMemory(availableMB: availableMB, requiredMB: requiredMB)
        }
    }

    // MARK: - Download

    func downloadModel(
        name: String,
        progress: ((Double) -> Void)? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        guard let info = Self.whisperModels.first(where: { $0.name == name }) else {
            completion(.failure(ModelManagerError.unknownModel(name)))
            return
        }

        guard !isDownloading else {
            completion(.failure(ModelManagerError.downloadInProgress))
            return
        }

        isDownloading = true
        currentDownloadModel = name
        downloadProgress = 0.0
        downloadCompletion = completion

        let task = downloadSession.downloadTask(with: info.url)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        currentDownloadModel = nil
        downloadProgress = 0.0
        downloadCompletion?(.failure(ModelManagerError.cancelled))
        downloadCompletion = nil
    }

    // MARK: - SHA256

    static func sha256(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let modelName = currentDownloadModel else {
            downloadCompletion?(.failure(ModelManagerError.unknownModel("")))
            resetDownloadState()
            return
        }

        let destination = modelPath(for: modelName)

        do {
            // Remove existing file if present
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)

            // SHA256 verification (skipping for now — checksums are nil)
            if let info = Self.whisperModels.first(where: { $0.name == modelName }),
               let expectedHash = info.expectedSHA256 {
                if let actualHash = Self.sha256(of: destination), actualHash != expectedHash {
                    try? FileManager.default.removeItem(at: destination)
                    downloadCompletion?(.failure(ModelManagerError.checksumMismatch))
                    resetDownloadState()
                    return
                }
            }

            downloadCompletion?(.success(destination))
        } catch {
            downloadCompletion?(.failure(error))
        }

        resetDownloadState()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            downloadProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            downloadCompletion?(.failure(error))
            resetDownloadState()
        }
    }

    private func availableMemoryBytes() -> UInt64 {
        // os_proc_available_memory() is unavailable on macOS; use Mach VM stats instead
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pageSize = UInt64(vm_kernel_page_size)
            return UInt64(stats.free_count + stats.inactive_count) * pageSize
        }
        return 4 * 1024 * 1024 * 1024 // Assume 4 GB as safe fallback
    }

    private func resetDownloadState() {
        isDownloading = false
        currentDownloadModel = nil
        downloadProgress = 0.0
        downloadTask = nil
        downloadCompletion = nil
    }
}

// MARK: - Errors

enum ModelManagerError: Error, LocalizedError {
    case unknownModel(String)
    case downloadInProgress
    case cancelled
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .unknownModel(let name): return "Unknown model: \(name)"
        case .downloadInProgress: return "A download is already in progress"
        case .cancelled: return "Download was cancelled"
        case .checksumMismatch: return "Downloaded file checksum does not match expected value"
        }
    }
}
