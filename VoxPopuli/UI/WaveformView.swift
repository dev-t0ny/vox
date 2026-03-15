import Cocoa

final class WaveformView: NSView {

    private let barCount = 24
    private var rmsHistory: [Float] = []
    private var historyIndex: Int = 0
    private var displayLink: CVDisplayLink?
    private var isAnimating = false

    var rmsLevel: Float = 0.0 {
        didSet {
            appendToHistory(rmsLevel)
        }
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rmsHistory = [Float](repeating: 0.0, count: barCount)
        wantsLayer = true
        layer?.backgroundColor = .clear
        startDisplayLink()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        rmsHistory = [Float](repeating: 0.0, count: barCount)
        startDisplayLink()
    }

    deinit {
        stopDisplayLink()
    }

    // MARK: - Display Link (smooth 60fps animation)

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let link = displayLink else { return }

        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo = userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<WaveformView>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async {
                view.needsDisplay = true
            }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())

        CVDisplayLinkStart(link)
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    // MARK: - History

    private func appendToHistory(_ value: Float) {
        guard rmsHistory.count == barCount else { return }
        rmsHistory[historyIndex % barCount] = value
        historyIndex += 1
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(dirtyRect)

        let count = barCount
        let spacing: CGFloat = 1.5
        let totalSpacing = spacing * CGFloat(count - 1)
        let barWidth = (bounds.width - totalSpacing) / CGFloat(count)
        let centerY = bounds.height / 2.0

        for i in 0..<count {
            let index = (historyIndex + i) % count
            let rawAmplitude = rmsHistory[index]

            // Amplify the signal — raw RMS is typically 0.001 to 0.1
            // Scale up aggressively so speech is visible
            let amplified = min(rawAmplitude * 12.0, 1.0)

            // Smooth with a minimum so bars are always visible
            let amplitude = max(0.08, amplified)

            let barHeight = CGFloat(amplitude) * bounds.height * 0.85
            let x = CGFloat(i) * (barWidth + spacing)
            let y = centerY - barHeight / 2.0

            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)

            // Color: white with opacity that follows amplitude
            let opacity = 0.4 + 0.6 * Double(amplitude)
            context.setFillColor(NSColor.white.withAlphaComponent(CGFloat(opacity)).cgColor)

            // Rounded bars
            let radius = min(barWidth / 2, 2.0)
            let path = CGPath(roundedRect: barRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            context.addPath(path)
            context.fillPath()
        }
    }
}
