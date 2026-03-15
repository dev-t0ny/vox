import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var modelManager: ModelManager!
    private var menuBarController: MenuBarController!
    private var hotkeyManager: HotkeyManager!
    private var pipeline: TranscriptionPipeline!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🎙️ Vox launching...")

        appState = AppState()
        modelManager = ModelManager()
        pipeline = TranscriptionPipeline(appState: appState, modelManager: modelManager)
        menuBarController = MenuBarController(appState: appState, modelManager: modelManager)
        hotkeyManager = HotkeyManager()

        menuBarController.setup()
        print("🎙️ Menu bar dot created")

        menuBarController.onToggleRecording = { [weak self] in self?.toggleRecording() }
        menuBarController.onModelChange = { [weak self] name in
            print("🎙️ Switching model to: \(name)")
            self?.pipeline.loadModel()
        }

        hotkeyManager.delegate = self
        hotkeyManager.mode = appState.hotkeyMode
        print("🎙️ Hotkey mode: \(appState.hotkeyMode.rawValue)")
        hotkeyManager.start()

        if !AXIsProcessTrusted() {
            print("⚠️ Accessibility NOT granted — hotkey won't work until you grant it in System Settings > Privacy > Accessibility")
            appState.status = .waitingForPermission
        } else {
            print("✅ Accessibility granted")
        }

        pipeline.loadModel()
        print("🎙️ Loading model: \(appState.selectedWhisperModel)")
    }

    private func toggleRecording() {
        switch appState.status {
        case .listening: pipeline.stopRecording()
        case .idle: pipeline.startRecording()
        default: break
        }
    }
}

extension AppDelegate: HotkeyManagerDelegate {
    func hotkeyManagerDidActivate(_ manager: HotkeyManager) {
        print("🎙️ HOTKEY ACTIVATED — starting recording")
        DispatchQueue.main.async { [weak self] in self?.pipeline.startRecording() }
    }
    func hotkeyManagerDidDeactivate(_ manager: HotkeyManager) {
        print("🎙️ HOTKEY DEACTIVATED — stopping recording")
        DispatchQueue.main.async { [weak self] in self?.pipeline.stopRecording() }
    }
}
