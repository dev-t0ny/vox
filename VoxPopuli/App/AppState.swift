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
