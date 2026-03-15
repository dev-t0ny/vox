import Cocoa

final class WaveformView: NSView {

    private let barCount = 32
    private var rmsHistory: [Float] = []
    private var historyIndex: Int = 0
    private var smoothedLevels: [Float] = []
    private var displayLink: CVDisplayLink?
    private var animationPhase: Double = 0

    var rmsLevel: Float = 0.0 {
        didSet { appendToHistory(rmsLevel) }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rmsHistory = [Float](repeating: 0.0, count: barCount)
        smoothedLevels = [Float](repeating: 0.0, count: barCount)
        wantsLayer = true
        layer?.backgroundColor = .clear
        startDisplayLink()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        rmsHistory = [Float](repeating: 0.0, count: barCount)
        smoothedLevels = [Float](repeating: 0.0, count: barCount)
        startDisplayLink()
    }

    deinit { stopDisplayLink() }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let link = displayLink else { return }
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let view = Unmanaged<WaveformView>.fromOpaque(userInfo).takeUnretainedValue()
            DispatchQueue.main.async { view.needsDisplay = true }
            return kCVReturnSuccess
        }, Unmanaged.passUnretained(self).toOpaque())
        CVDisplayLinkStart(link)
    }

    private func stopDisplayLink() {
        guard let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLink = nil
    }

    func reset() {
        rmsHistory = [Float](repeating: 0.0, count: barCount)
        smoothedLevels = [Float](repeating: 0.0, count: barCount)
        historyIndex = 0
        animationPhase = 0
    }

    private func appendToHistory(_ value: Float) {
        guard rmsHistory.count == barCount else { return }
        rmsHistory[historyIndex % barCount] = value
        historyIndex += 1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(dirtyRect)

        animationPhase += 0.04

        let count = barCount
        let spacing: CGFloat = 2.0
        let barWidth = (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        let centerY = bounds.height / 2.0

        for i in 0..<count {
            let index = (historyIndex + i) % count
            let raw = rmsHistory[index]

            // Massive amplification — raw RMS is 0.001-0.1, we want 0-1
            let amplified = min(raw * 50.0, 1.0)

            // Smooth transition (ease toward target)
            let target = max(0.05, amplified)
            smoothedLevels[i] += (target - smoothedLevels[i]) * 0.3
            let level = smoothedLevels[i]

            // Add a subtle idle wave so it never looks frozen
            let idleWave = Float(sin(animationPhase + Double(i) * 0.3)) * 0.03 + 0.05
            let finalLevel = max(level, idleWave)

            let barHeight = CGFloat(finalLevel) * bounds.height * 0.9
            let x = CGFloat(i) * (barWidth + spacing)
            let y = centerY - barHeight / 2.0
            let barRect = CGRect(x: x, y: y, width: barWidth, height: barHeight)

            // Gradient color: purple → cyan based on amplitude
            let t = CGFloat(finalLevel)
            let r = 0.6 * (1.0 - t) + 0.0 * t   // purple to cyan
            let g = 0.2 * (1.0 - t) + 0.9 * t
            let b = 1.0 * (1.0 - t) + 1.0 * t
            let alpha = 0.5 + 0.5 * t

            ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: alpha))
            let radius = min(barWidth / 2, 3.0)
            ctx.addPath(CGPath(roundedRect: barRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
    }
}
