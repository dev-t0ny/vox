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
        menuBarController.onLeftClick = { [weak self] in self?.toggleRecording() }

        hotkeyManager.delegate = self
        hotkeyManager.mode = appState.hotkeyMode
        hotkeyManager.start()

        if !AXIsProcessTrusted() {
            appState.status = .waitingForPermission
        }

        pipeline.loadModel()
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
        DispatchQueue.main.async { [weak self] in self?.pipeline.startRecording() }
    }
    func hotkeyManagerDidDeactivate(_ manager: HotkeyManager) {
        DispatchQueue.main.async { [weak self] in self?.pipeline.stopRecording() }
    }
}
