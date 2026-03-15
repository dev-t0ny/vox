import Cocoa
import Combine

final class MenuBarController: NSObject {

    private let appState: AppState
    private let modelManager: ModelManager

    private var statusItem: NSStatusItem?
    private var animationTimer: Timer?
    private var animationAlpha: CGFloat = 1.0
    private var animationDirection: CGFloat = -1.0
    private var cancellables = Set<AnyCancellable>()

    var onToggleRecording: (() -> Void)?
    var onModelChange: ((String) -> Void)?

    init(appState: AppState, modelManager: ModelManager) {
        self.appState = appState
        self.modelManager = modelManager
        super.init()
    }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = statusIcon(for: .idle)
            button.action = #selector(statusBarClicked(_:))
            button.target = self
        }

        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.updateForStatus(status) }
            .store(in: &cancellables)
    }

    // MARK: - Click → Menu

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        showMenu()
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.minimumWidth = 260

        // ─── Status ───
        addStatusSection(to: menu)
        menu.addItem(NSMenuItem.separator())

        // ─── Record button ───
        let recordTitle = appState.status == .listening ? "⏹  Stop Recording" : "🎙  Start Recording"
        let recordItem = NSMenuItem(title: recordTitle, action: #selector(toggleRecording(_:)), keyEquivalent: "")
        recordItem.target = self
        recordItem.attributedTitle = NSAttributedString(
            string: recordTitle,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        )
        menu.addItem(recordItem)
        menu.addItem(NSMenuItem.separator())

        // ─── Recent Transcriptions ───
        addTranscriptSection(to: menu)
        menu.addItem(NSMenuItem.separator())

        // ─── Settings ───
        addSettingsSection(to: menu)
        menu.addItem(NSMenuItem.separator())

        // ─── Quit ───
        menu.addItem(NSMenuItem(title: "Quit Vox", action: #selector(quitApp(_:)), keyEquivalent: "q").with(target: self))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Menu Sections

    private func addStatusSection(to menu: NSMenu) {
        let statusText: String
        let color: NSColor
        switch appState.status {
        case .idle: statusText = "Ready"; color = .systemGreen
        case .listening: statusText = "Listening..."; color = .systemGreen
        case .processing: statusText = "Transcribing..."; color = .systemBlue
        case .waitingForPermission: statusText = "Needs permissions"; color = .systemOrange
        case .downloading(let p): statusText = "Downloading \(Int(p * 100))%"; color = .systemPurple
        case .error(let msg): statusText = msg; color = .systemRed
        }

        let header = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(
            string: "  ● \(statusText)    ·    \(appState.selectedWhisperModel)",
            attributes: [
                .foregroundColor: color,
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]
        )
        header.isEnabled = false
        menu.addItem(header)
    }

    private func addTranscriptSection(to menu: NSMenu) {
        let sectionHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sectionHeader.attributedTitle = NSAttributedString(
            string: "  Recent",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.tertiaryLabelColor]
        )
        sectionHeader.isEnabled = false
        menu.addItem(sectionHeader)

        if appState.recentTranscripts.isEmpty {
            let empty = NSMenuItem(title: "  Hold Left Option and speak", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.attributedTitle = NSAttributedString(
                string: "  Hold ⌥ and speak",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]
            )
            menu.addItem(empty)
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated

            for (i, entry) in appState.recentTranscripts.prefix(6).enumerated() {
                let preview = String(entry.text.prefix(45)) + (entry.text.count > 45 ? "…" : "")
                let timeAgo = formatter.localizedString(for: entry.date, relativeTo: Date())

                let item = NSMenuItem(title: "", action: #selector(copyTranscript(_:)), keyEquivalent: "")
                item.target = self
                item.tag = i

                let attrStr = NSMutableAttributedString()
                attrStr.append(NSAttributedString(
                    string: "  \(preview)",
                    attributes: [.font: NSFont.systemFont(ofSize: 12)]
                ))
                attrStr.append(NSAttributedString(
                    string: "  \(timeAgo)",
                    attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor]
                ))
                item.attributedTitle = attrStr
                item.toolTip = "Click to copy"
                menu.addItem(item)
            }
        }
    }

    private func addSettingsSection(to menu: NSMenu) {
        let sectionHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sectionHeader.attributedTitle = NSAttributedString(
            string: "  Settings",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.tertiaryLabelColor]
        )
        sectionHeader.isEnabled = false
        menu.addItem(sectionHeader)

        // Model
        let modelMenu = NSMenu()
        for model in ModelManager.whisperModels {
            let downloaded = modelManager.isModelDownloaded(model.name)
            let title = downloaded ? model.displayName : "\(model.displayName)  ⬇️"
            let item = NSMenuItem(title: title, action: downloaded ? #selector(selectModel(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.representedObject = model.name
            if model.name == appState.selectedWhisperModel { item.state = .on }
            if !downloaded { item.isEnabled = false }
            modelMenu.addItem(item)
        }
        let modelItem = NSMenuItem(title: "  Model: \(appState.selectedWhisperModel)", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // Language
        let langMenu = NSMenu()
        for (code, name) in [("auto", "Auto-detect"), ("en", "English"), ("fr", "Français"), ("es", "Español"), ("de", "Deutsch"), ("ja", "日本語"), ("zh", "中文")] {
            let item = NSMenuItem(title: name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            if code == appState.selectedLanguage { item.state = .on }
            langMenu.addItem(item)
        }
        let langDisplay = appState.selectedLanguage == "auto" ? "Auto" : appState.selectedLanguage.uppercased()
        let langItem = NSMenuItem(title: "  Language: \(langDisplay)", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        // Activation mode
        let hotkeyMenu = NSMenu()
        for mode in HotkeyMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(selectHotkeyMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            if mode == appState.hotkeyMode { item.state = .on }
            hotkeyMenu.addItem(item)
        }
        let hotkeyItem = NSMenuItem(title: "  Activation: \(appState.hotkeyMode.rawValue)", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        // AI Cleanup
        let cleanupItem = NSMenuItem(title: "  AI Cleanup", action: #selector(toggleAICleanup(_:)), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = appState.aiCleanupEnabled ? .on : .off
        menu.addItem(cleanupItem)
    }

    // MARK: - Actions

    @objc private func toggleRecording(_ sender: NSMenuItem) {
        onToggleRecording?()
    }

    @objc private func copyTranscript(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < appState.recentTranscripts.count else { return }
        let text = appState.recentTranscripts[index].text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        appState.selectedWhisperModel = name
        appState.save()
        onModelChange?(name)
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        appState.selectedLanguage = code
        appState.save()
    }

    @objc private func toggleAICleanup(_ sender: NSMenuItem) {
        appState.aiCleanupEnabled.toggle()
        appState.save()
    }

    @objc private func selectHotkeyMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = HotkeyMode(rawValue: raw) else { return }
        appState.hotkeyMode = mode
        appState.save()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Icon

    private func statusIcon(for status: AppStatus) -> NSImage {
        let symbolName: String
        switch status {
        case .listening: symbolName = "mic.fill"
        case .processing: symbolName = "brain"
        default: symbolName = "mic"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Vox") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            return image.withSymbolConfiguration(config) ?? image
        }
        return NSImage()
    }

    // MARK: - Status Animation

    private func updateForStatus(_ status: AppStatus) {
        stopAnimation()
        statusItem?.button?.image = statusIcon(for: status)

        switch status {
        case .listening:
            startPulse(symbol: "mic.fill", speed: 0.05, range: 0.4...1.0)
        case .processing:
            startPulse(symbol: "brain", speed: 0.03, range: 0.3...1.0)
        default:
            break
        }
    }

    private func startPulse(symbol: String, speed: TimeInterval, range: ClosedRange<CGFloat>) {
        animationAlpha = 1.0
        animationDirection = -1.0
        animationTimer = Timer.scheduledTimer(withTimeInterval: speed, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.animationAlpha += self.animationDirection * 0.05
            if self.animationAlpha <= range.lowerBound {
                self.animationAlpha = range.lowerBound
                self.animationDirection = 1.0
            } else if self.animationAlpha >= range.upperBound {
                self.animationAlpha = range.upperBound
                self.animationDirection = -1.0
            }
            self.statusItem?.button?.alphaValue = self.animationAlpha
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationAlpha = 1.0
        statusItem?.button?.alphaValue = 1.0
    }

    deinit { stopAnimation() }
}

// Helper
private extension NSMenuItem {
    func with(target: AnyObject) -> NSMenuItem {
        self.target = target
        return self
    }
}
