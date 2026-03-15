import Cocoa

final class WaveformView: NSView {

    // MARK: - Properties

    private let historyCount = 30
    private var rmsHistory: [Float] = []
    private var historyIndex: Int = 0

    var rmsLevel: Float = 0.0 {
        didSet {
            appendToHistory(rmsLevel)
            needsDisplay = true
        }
    }

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        rmsHistory = [Float](repeating: 0.0, count: historyCount)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        rmsHistory = [Float](repeating: 0.0, count: historyCount)
    }

    // MARK: - History

    private func appendToHistory(_ value: Float) {
        if rmsHistory.count < historyCount {
            rmsHistory.append(value)
        } else {
            rmsHistory[historyIndex % historyCount] = value
        }
        historyIndex += 1
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !rmsHistory.isEmpty else { return }

        let count = rmsHistory.count
        let barWidth = bounds.width / CGFloat(count)
        let maxBarHeight = bounds.height

        for i in 0..<count {
            // Read in order starting from the oldest entry
            let index = (historyIndex + i) % count
            let amplitude = CGFloat(rmsHistory[index])

            let barHeight = max(2.0, amplitude * maxBarHeight)
            let x = CGFloat(i) * barWidth
            let y = (bounds.height - barHeight) / 2.0

            let barRect = NSRect(
                x: x + 1,
                y: y,
                width: max(barWidth - 2, 1),
                height: barHeight
            )

            let opacity = max(0.3, amplitude)
            NSColor.white.withAlphaComponent(opacity).setFill()

            let path = NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5)
            path.fill()
        }
    }
}
