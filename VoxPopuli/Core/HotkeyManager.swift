import Cocoa
import ApplicationServices

// MARK: - Hotkey Mode

enum HotkeyMode: String, CaseIterable {
    case doubleTap = "Double-tap"
    case holdToTalk = "Hold to talk"
    case toggle = "Toggle"
}

// MARK: - Delegate

protocol HotkeyManagerDelegate: AnyObject {
    func hotkeyManagerDidActivate(_ manager: HotkeyManager)
    func hotkeyManagerDidDeactivate(_ manager: HotkeyManager)
}

// MARK: - HotkeyManager

final class HotkeyManager {

    weak var delegate: HotkeyManagerDelegate?
    var mode: HotkeyMode = .doubleTap
    var targetKeyCode: UInt16 = 58 // Left Option (kVK_Option)

    private var globalMonitor: Any?
    private var localMonitor: Any?

    // Double-tap tracking
    private var lastKeyUpTime: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.3

    // Hold-to-talk tracking
    private var isKeyHeld: Bool = false

    // Toggle tracking
    private var isToggled: Bool = false

    // Active state
    private(set) var isActive: Bool = false

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Start / Stop

    func start() {
        print("🎙️ [Hotkey] Starting with NSEvent global monitor (no CGEvent tap needed)")
        installMonitors()
    }

    func stop() {
        removeMonitors()
    }

    // MARK: - NSEvent Monitors

    private func installMonitors() {
        // Global monitor — catches events when our app is NOT focused
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Local monitor — catches events when our app IS focused (e.g. settings popover open)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        if globalMonitor != nil {
            print("✅ [Hotkey] Global monitor installed")
        } else {
            print("❌ [Hotkey] Global monitor FAILED — accessibility may not be granted")
        }
    }

    private func removeMonitors() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    // MARK: - Event Handling

    private func handleFlagsChanged(_ event: NSEvent) {
        let keyCode = event.keyCode
        guard keyCode == targetKeyCode else { return }

        let isKeyDown = event.modifierFlags.contains(.option)
        print("🎹 [Hotkey] Left Option \(isKeyDown ? "DOWN" : "UP") (mode: \(mode.rawValue))")

        switch mode {
        case .doubleTap:
            handleDoubleTap(isKeyDown: isKeyDown)
        case .holdToTalk:
            handleHoldToTalk(isKeyDown: isKeyDown)
        case .toggle:
            handleToggle(isKeyDown: isKeyDown)
        }
    }

    // MARK: - Mode Handlers

    private func handleDoubleTap(isKeyDown: Bool) {
        if !isKeyDown {
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - lastKeyUpTime
            lastKeyUpTime = now

            if elapsed <= doubleTapWindow {
                if isActive {
                    deactivate()
                } else {
                    activate()
                }
                lastKeyUpTime = 0
            }
        }
    }

    private func handleHoldToTalk(isKeyDown: Bool) {
        if isKeyDown && !isKeyHeld {
            isKeyHeld = true
            activate()
        } else if !isKeyDown && isKeyHeld {
            isKeyHeld = false
            deactivate()
        }
    }

    private func handleToggle(isKeyDown: Bool) {
        if !isKeyDown {
            if isToggled {
                isToggled = false
                deactivate()
            } else {
                isToggled = true
                activate()
            }
        }
    }

    // MARK: - Activate / Deactivate

    private func activate() {
        guard !isActive else { return }
        isActive = true
        print("🎙️ [Hotkey] >>> ACTIVATED")
        delegate?.hotkeyManagerDidActivate(self)
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        print("🎙️ [Hotkey] <<< DEACTIVATED")
        delegate?.hotkeyManagerDidDeactivate(self)
    }

    deinit {
        stop()
    }
}
