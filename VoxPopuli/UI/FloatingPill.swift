import Cocoa

final class FloatingPill {

    // MARK: - Properties

    private var panel: NSPanel?
    private var waveformView: WaveformView?
    private let pillSize = NSSize(width: 120, height: 36)

    // MARK: - Setup

    private func createPanelIfNeeded() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: pillSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Visual effect background
        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: pillSize))
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 8
        effectView.layer?.masksToBounds = true

        panel.contentView = effectView

        // Waveform view
        let inset: CGFloat = 4
        let waveFrame = NSRect(
            x: inset,
            y: inset,
            width: pillSize.width - inset * 2,
            height: pillSize.height - inset * 2
        )
        let waveform = WaveformView(frame: waveFrame)
        waveform.autoresizingMask = [.width, .height]
        effectView.addSubview(waveform)

        self.waveformView = waveform
        self.panel = panel
    }

    // MARK: - Show / Hide

    func show(near point: NSPoint) {
        createPanelIfNeeded()
        guard let panel = panel else { return }

        // Position 20px above and 10px right of mouse
        var origin = NSPoint(
            x: point.x + 10,
            y: point.y + 20
        )

        // Flip if off-screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            if origin.x + pillSize.width > screenFrame.maxX {
                origin.x = point.x - pillSize.width - 10
            }
            if origin.y + pillSize.height > screenFrame.maxY {
                origin.y = point.y - pillSize.height - 20
            }
            if origin.x < screenFrame.minX {
                origin.x = screenFrame.minX
            }
            if origin.y < screenFrame.minY {
                origin.y = screenFrame.minY
            }
        }

        panel.setFrameOrigin(origin)
        panel.alphaValue = 0.0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1.0
        }
    }

    func updateRMS(_ rms: Float) {
        waveformView?.rmsLevel = rms
    }

    func setProcessing() {
        // Show a subtle indication that processing is happening
        waveformView?.rmsLevel = 0.15
    }

    func fadeOut() {
        guard let panel = panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }
}
