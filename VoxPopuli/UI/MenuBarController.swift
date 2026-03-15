import Cocoa
import Combine
import SwiftUI

final class MenuBarController: NSObject {

    // MARK: - Properties

    private let appState: AppState
    private let modelManager: ModelManager

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var animationTimer: Timer?
    private var animationAlpha: CGFloat = 1.0
    private var animationDirection: CGFloat = -1.0
    private var cancellables = Set<AnyCancellable>()

    /// Called when the user left-clicks the menu bar icon.
    var onLeftClick: (() -> Void)?

    // MARK: - Init

    init(appState: AppState, modelManager: ModelManager) {
        self.appState = appState
        self.modelManager = modelManager
        super.init()
    }

    // MARK: - Setup

    func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item

        if let button = item.button {
            button.image = dotImage(color: .secondaryLabelColor)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(statusBarClicked(_:))
            button.target = self
        }

        // Observe status changes
        appState.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.updateForStatus(status)
            }
            .store(in: &cancellables)
    }

    // MARK: - Dot Icon

    private func dotImage(color: NSColor, alpha: CGFloat = 1.0) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let dotSize: CGFloat = 8
            let origin = NSPoint(
                x: (rect.width - dotSize) / 2,
                y: (rect.height - dotSize) / 2
            )
            let dotRect = NSRect(origin: origin, size: NSSize(width: dotSize, height: dotSize))
            let path = NSBezierPath(ovalIn: dotRect)
            color.withAlphaComponent(alpha).setFill()
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Status Update

    private func updateForStatus(_ status: AppStatus) {
        stopAnimation()

        let color: NSColor
        switch status {
        case .idle:
            color = .secondaryLabelColor
        case .waitingForPermission:
            color = .systemOrange
        case .listening:
            color = .systemGreen
            startListeningAnimation()
        case .processing:
            color = .systemBlue
            startProcessingAnimation()
        case .downloading:
            color = .systemPurple
        case .error:
            color = .systemRed
        }

        statusItem?.button?.image = dotImage(color: color)
    }

    // MARK: - Animation

    private func startListeningAnimation() {
        animationAlpha = 1.0
        animationDirection = -1.0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationAlpha += self.animationDirection * 0.05
            if self.animationAlpha <= 0.4 {
                self.animationAlpha = 0.4
                self.animationDirection = 1.0
            } else if self.animationAlpha >= 1.0 {
                self.animationAlpha = 1.0
                self.animationDirection = -1.0
            }
            self.statusItem?.button?.image = self.dotImage(color: .systemGreen, alpha: self.animationAlpha)
        }
    }

    private func startProcessingAnimation() {
        animationAlpha = 1.0
        animationDirection = -1.0
        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.animationAlpha += self.animationDirection * 0.05
            if self.animationAlpha <= 0.3 {
                self.animationAlpha = 0.3
                self.animationDirection = 1.0
            } else if self.animationAlpha >= 1.0 {
                self.animationAlpha = 1.0
                self.animationDirection = -1.0
            }
            self.statusItem?.button?.image = self.dotImage(color: .systemBlue, alpha: self.animationAlpha)
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationAlpha = 1.0
    }

    // MARK: - Click Handling

    @objc private func statusBarClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showSettingsPopover()
        } else {
            // Close popover if open, then toggle listening
            if let popover = popover, popover.isShown {
                popover.performClose(sender)
            }
            onLeftClick?()
        }
    }

    // MARK: - Settings Popover

    private func showSettingsPopover() {
        if let popover = popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let settingsView = SettingsView(appState: appState, modelManager: modelManager)
        let hostingController = NSHostingController(rootView: settingsView)

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 300, height: 420)
        pop.behavior = .transient
        pop.contentViewController = hostingController
        popover = pop

        if let button = statusItem?.button {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    deinit {
        stopAnimation()
        cancellables.removeAll()
    }
}
