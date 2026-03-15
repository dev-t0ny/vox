import Foundation

// MARK: - App Status

enum AppStatus: Equatable {
    case idle
    case waitingForPermission
    case listening
    case processing
    case downloading(progress: Double)
    case error(message: String)
}

// MARK: - AppState

struct TranscriptEntry {
    let text: String
    let date: Date
    let duration: TimeInterval
}

final class AppState: ObservableObject {
    @Published var status: AppStatus = .idle
    @Published var currentRMS: Float = 0.0
    @Published var selectedWhisperModel: String = UserDefaults.standard.string(forKey: "whisperModel") ?? "large-v3"
    @Published var selectedLanguage: String = UserDefaults.standard.string(forKey: "language") ?? "auto"
    @Published var aiCleanupEnabled: Bool = UserDefaults.standard.bool(forKey: "aiCleanup")
    @Published var hotkeyMode: HotkeyMode = HotkeyMode(rawValue: UserDefaults.standard.string(forKey: "hotkeyMode") ?? "") ?? .holdToTalk

    /// Recent transcriptions (newest first, max 20)
    @Published var recentTranscripts: [TranscriptEntry] = []

    func addTranscript(_ text: String, duration: TimeInterval) {
        let entry = TranscriptEntry(text: text, date: Date(), duration: duration)
        recentTranscripts.insert(entry, at: 0)
        if recentTranscripts.count > 20 {
            recentTranscripts.removeLast()
        }
    }

    func save() {
        UserDefaults.standard.set(selectedWhisperModel, forKey: "whisperModel")
        UserDefaults.standard.set(selectedLanguage, forKey: "language")
        UserDefaults.standard.set(aiCleanupEnabled, forKey: "aiCleanup")
        UserDefaults.standard.set(hotkeyMode.rawValue, forKey: "hotkeyMode")
    }
}
