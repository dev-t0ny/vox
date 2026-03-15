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
    var targetKeyCode: CGKeyCode = 61 // Right Option

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityPollTimer: Timer?

    // Double-tap tracking
    private var lastKeyUpTime: TimeInterval = 0
    private let doubleTapWindow: TimeInterval = 0.3

    // Hold-to-talk tracking
    private var isKeyHeld: Bool = false

    // Toggle tracking
    private var isToggled: Bool = false

    // Active state
    private(set) var isActive: Bool = false

    // MARK: - Start / Stop

    func start() {
        if AXIsProcessTrusted() {
            installEventTap()
        } else {
            requestAccessibilityPermission()
            pollForAccessibility()
        }
    }

    func stop() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        removeEventTap()
    }

    // MARK: - Accessibility Bootstrap

    private func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    private func pollForAccessibility() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0,
            repeats: true
        ) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.accessibilityPollTimer = nil
                self?.installEventTap()
            }
        }
    }

    // MARK: - Event Tap

    private func installEventTap() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue

        // Use an unretained pointer to self for the callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyEventCallback,
            userInfo: refcon
        ) else {
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Event Handling

    fileprivate func handleFlagsChanged(_ event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == targetKeyCode else { return }

        let flags = event.flags
        // Right Option is flagged as .maskAlternate. Key down when flag is present.
        let isKeyDown = flags.contains(.maskAlternate)

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
            // Key up — check for double-tap
            let now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - lastKeyUpTime
            lastKeyUpTime = now

            if elapsed <= doubleTapWindow {
                if isActive {
                    deactivate()
                } else {
                    activate()
                }
                // Reset to prevent triple-tap from toggling again
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
        delegate?.hotkeyManagerDidActivate(self)
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        delegate?.hotkeyManagerDidDeactivate(self)
    }

    deinit {
        stop()
    }
}

// MARK: - C callback

private func hotkeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

    if type == .flagsChanged {
        manager.handleFlagsChanged(event)
    }

    // If the tap is disabled by the system, re-enable it
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = manager.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    return Unmanaged.passUnretained(event)
}
