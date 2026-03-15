import Cocoa

final class FloatingPill {

    private var panel: NSPanel?
    private var effectView: NSVisualEffectView?
    private var waveformView: WaveformView?
    private var textLabel: NSTextField?
    private let pillSize = NSSize(width: 200, height: 48)
    private var lastMouseLocation: NSPoint = .zero

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

        let ev = NSVisualEffectView(frame: NSRect(origin: .zero, size: pillSize))
        ev.material = .hudWindow
        ev.blendingMode = .behindWindow
        ev.state = .active
        ev.wantsLayer = true
        ev.layer?.cornerRadius = 12
        ev.layer?.masksToBounds = true
        self.effectView = ev

        panel.contentView = ev

        // Waveform
        let inset: CGFloat = 6
        let waveFrame = NSRect(x: inset, y: inset, width: pillSize.width - inset * 2, height: pillSize.height - inset * 2)
        let waveform = WaveformView(frame: waveFrame)
        waveform.autoresizingMask = [.width, .height]
        ev.addSubview(waveform)
        self.waveformView = waveform

        // Text label (hidden by default, shown when transcript is ready)
        let label = NSTextField(frame: NSRect(x: 8, y: 0, width: pillSize.width - 16, height: pillSize.height))
        label.isEditable = false
        label.isBordered = false
        label.isBezeled = false
        label.backgroundColor = .clear
        label.textColor = .white
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.isHidden = true
        label.alphaValue = 0
        ev.addSubview(label)
        self.textLabel = label

        self.panel = panel
    }

    // MARK: - Show / Hide

    func show(near point: NSPoint) {
        createPanelIfNeeded()
        guard let panel else { return }

        lastMouseLocation = point

        // Hide text, show waveform
        textLabel?.isHidden = true
        textLabel?.alphaValue = 0
        waveformView?.isHidden = false
        waveformView?.alphaValue = 1

        positionPanel(panel, near: point)

        panel.alphaValue = 0.0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1.0
        }
    }

    func showTranscript(_ text: String) {
        createPanelIfNeeded()
        guard let panel, let label = textLabel, let ev = effectView else { return }

        // Resize pill to fit text
        let preview = String(text.prefix(80)) + (text.count > 80 ? "…" : "")
        label.stringValue = "📋 \(preview)"

        let textWidth = min(max(label.intrinsicContentSize.width + 24, 160), 400)
        let newSize = NSSize(width: textWidth, height: 48)

        panel.setContentSize(newSize)
        ev.frame = NSRect(origin: .zero, size: newSize)
        label.frame = NSRect(x: 8, y: 0, width: newSize.width - 16, height: newSize.height)
        waveformView?.frame = NSRect(x: 6, y: 6, width: newSize.width - 12, height: newSize.height - 12)

        positionPanel(panel, near: lastMouseLocation)

        // Crossfade: waveform out, text in
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            waveformView?.animator().alphaValue = 0
        } completionHandler: {
            self.waveformView?.isHidden = true
            label.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                label.animator().alphaValue = 1
            }
        }

        // Auto-fade after 2.5s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.fadeOut()
        }
    }

    func resetWaveform() {
        waveformView?.reset()
    }

    func updateRMS(_ rms: Float) {
        waveformView?.rmsLevel = rms
    }

    func setProcessing() {
        waveformView?.rmsLevel = 0.15
    }

    func fadeOut() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
            // Reset pill size
            if let self, let ev = self.effectView {
                self.panel?.setContentSize(self.pillSize)
                ev.frame = NSRect(origin: .zero, size: self.pillSize)
            }
        })
    }

    // MARK: - Positioning

    private func positionPanel(_ panel: NSPanel, near point: NSPoint) {
        var origin = NSPoint(x: point.x + 10, y: point.y + 20)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            let size = panel.frame.size
            if origin.x + size.width > f.maxX { origin.x = point.x - size.width - 10 }
            if origin.y + size.height > f.maxY { origin.y = point.y - size.height - 20 }
            if origin.x < f.minX { origin.x = f.minX }
            if origin.y < f.minY { origin.y = f.minY }
        }

        panel.setFrameOrigin(origin)
    }
}
