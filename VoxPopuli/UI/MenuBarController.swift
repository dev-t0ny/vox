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

    var onLeftClick: (() -> Void)?
    var onModelChange: ((String) -> Void)?

    init(appState: AppState, modelManager: ModelManager) {
        self.appState = appState
        self.modelManager = modelManager
        super.init()
    }

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.image = dotImage(color: .secondaryLabelColor)
            button.action = #selector(statusBarClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.updateForStatus(status) }
            .store(in: &cancellables)
    }

    // MARK: - Click

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            // Right-click or ctrl-click → show menu
            showMenu()
        } else {
            // Left-click → toggle recording
            onLeftClick?()
        }
    }

    // MARK: - Menu

    private func showMenu() {
        let menu = NSMenu()

        // Status header
        let statusText: String
        switch appState.status {
        case .idle: statusText = "Ready"
        case .listening: statusText = "Listening..."
        case .processing: statusText = "Processing..."
        case .waitingForPermission: statusText = "Waiting for permissions"
        case .downloading(let p): statusText = "Downloading... \(Int(p * 100))%"
        case .error(let msg): statusText = "Error: \(msg)"
        }

        let statusItem = NSMenuItem(title: "● \(statusText)", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        let color: NSColor = {
            switch appState.status {
            case .idle: return .systemGreen
            case .listening: return .systemGreen
            case .processing: return .systemBlue
            case .error: return .systemRed
            case .waitingForPermission: return .systemOrange
            case .downloading: return .systemPurple
            }
        }()
        statusItem.attributedTitle = NSAttributedString(
            string: "● \(statusText)",
            attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: 13, weight: .medium)]
        )
        menu.addItem(statusItem)

        // Model info
        let modelName = appState.selectedWhisperModel
        let modelItem = NSMenuItem(title: "Model: \(modelName)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        menu.addItem(NSMenuItem.separator())

        // Recent transcriptions
        let historyHeader = NSMenuItem(title: "Recent Transcriptions", action: nil, keyEquivalent: "")
        historyHeader.isEnabled = false
        historyHeader.attributedTitle = NSAttributedString(
            string: "Recent Transcriptions",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
        )
        menu.addItem(historyHeader)

        if appState.recentTranscripts.isEmpty {
            let emptyItem = NSMenuItem(title: "  No transcriptions yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short

            for (index, entry) in appState.recentTranscripts.prefix(8).enumerated() {
                let preview = entry.text.prefix(50) + (entry.text.count > 50 ? "..." : "")
                let timeAgo = formatter.localizedString(for: entry.date, relativeTo: Date())
                let item = NSMenuItem(
                    title: "\(preview)  (\(timeAgo))",
                    action: #selector(copyTranscript(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = index
                item.toolTip = "Click to copy: \(entry.text)"
                menu.addItem(item)
            }

            if appState.recentTranscripts.count > 8 {
                let moreItem = NSMenuItem(title: "  ... and \(appState.recentTranscripts.count - 8) more", action: nil, keyEquivalent: "")
                moreItem.isEnabled = false
                menu.addItem(moreItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Model submenu
        let modelMenu = NSMenu()
        for model in ModelManager.whisperModels {
            let item = NSMenuItem(
                title: model.displayName,
                action: #selector(selectModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = model.name
            if model.name == appState.selectedWhisperModel {
                item.state = .on
            }
            if !modelManager.isModelDownloaded(model.name) {
                let sizeMB = model.sizeBytes / 1_000_000
                item.title = "\(model.displayName) (\(sizeMB)MB — not downloaded)"
                item.isEnabled = false
            }
            modelMenu.addItem(item)
        }
        let modelSubmenu = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelSubmenu.submenu = modelMenu
        menu.addItem(modelSubmenu)

        // Language submenu
        let langMenu = NSMenu()
        let languages = [("auto", "Auto-detect"), ("en", "English"), ("fr", "French"), ("es", "Spanish"), ("de", "German"), ("ja", "Japanese"), ("zh", "Chinese")]
        for (code, name) in languages {
            let item = NSMenuItem(title: name, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = code
            if code == appState.selectedLanguage { item.state = .on }
            langMenu.addItem(item)
        }
        let langSubmenu = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langSubmenu.submenu = langMenu
        menu.addItem(langSubmenu)

        // AI Cleanup toggle
        let cleanupItem = NSMenuItem(title: "AI Cleanup", action: #selector(toggleAICleanup(_:)), keyEquivalent: "")
        cleanupItem.target = self
        cleanupItem.state = appState.aiCleanupEnabled ? .on : .off
        menu.addItem(cleanupItem)

        // Hotkey mode submenu
        let hotkeyMenu = NSMenu()
        for mode in HotkeyMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(selectHotkeyMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            if mode == appState.hotkeyMode { item.state = .on }
            hotkeyMenu.addItem(item)
        }
        let hotkeySubmenu = NSMenuItem(title: "Activation: \(appState.hotkeyMode.rawValue)", action: nil, keyEquivalent: "")
        hotkeySubmenu.submenu = hotkeyMenu
        menu.addItem(hotkeySubmenu)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit Vox", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Show the menu
        if let button = self.statusItem?.button {
            self.statusItem?.menu = menu
            button.performClick(nil)
            self.statusItem?.menu = nil  // Reset so left-click works again
        }
    }

    // MARK: - Menu Actions

    @objc private func copyTranscript(_ sender: NSMenuItem) {
        let index = sender.tag
        guard index < appState.recentTranscripts.count else { return }
        let text = appState.recentTranscripts[index].text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("📋 Copied to clipboard: \"\(text.prefix(50))...\"")
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
        guard let raw = sender.representedObject as? String,
              let mode = HotkeyMode(rawValue: raw) else { return }
        appState.hotkeyMode = mode
        appState.save()
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Icon

    private func dotImage(color: NSColor, alpha: CGFloat = 1.0) -> NSImage {
        // Use SF Symbol microphone icon — much more visible than a tiny dot
        if let image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Vox") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let configured = image.withSymbolConfiguration(config) ?? image
            // Tint the image
            let tinted = NSImage(size: configured.size, flipped: false) { rect in
                configured.draw(in: rect)
                color.withAlphaComponent(alpha).set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false
            return tinted
        }

        // Fallback: colored dot
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let dotSize: CGFloat = 10
            let origin = NSPoint(x: (rect.width - dotSize) / 2, y: (rect.height - dotSize) / 2)
            let dotRect = NSRect(origin: origin, size: NSSize(width: dotSize, height: dotSize))
            NSBezierPath(ovalIn: dotRect).fill(using: color.withAlphaComponent(alpha))
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Status Animation

    private func updateForStatus(_ status: AppStatus) {
        stopAnimation()
        let color: NSColor
        switch status {
        case .idle: color = .secondaryLabelColor
        case .waitingForPermission: color = .systemOrange
        case .listening: color = .systemGreen; startPulse(color: .systemGreen, speed: 0.05, range: 0.4...1.0)
        case .processing: color = .systemBlue; startPulse(color: .systemBlue, speed: 0.03, range: 0.3...1.0)
        case .downloading: color = .systemPurple
        case .error: color = .systemRed
        }
        statusItem?.button?.image = dotImage(color: color)
    }

    private func startPulse(color: NSColor, speed: TimeInterval, range: ClosedRange<CGFloat>) {
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
            self.statusItem?.button?.image = self.dotImage(color: color, alpha: self.animationAlpha)
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationAlpha = 1.0
    }

    deinit {
        stopAnimation()
    }
}

// Helper for NSBezierPath
private extension NSBezierPath {
    func fill(using color: NSColor) {
        color.setFill()
        fill()
    }
}
