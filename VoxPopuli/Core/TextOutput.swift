import Cocoa
import Carbon.HIToolbox
import UserNotifications

final class TextOutput {

    func type(_ text: String) {
        print("📋 [TextOutput] Typing: \"\(text.prefix(60))...\"")

        // Strategy 1: Try Accessibility API (best — inserts at cursor)
        if AXIsProcessTrusted() && insertViaAccessibility(text) {
            print("✅ [TextOutput] Inserted via Accessibility API")
            return
        }

        // Strategy 2: Clipboard + CGEvent Cmd+V
        if pasteViaClipboard(text, method: .cgEvent) {
            print("✅ [TextOutput] Pasted via CGEvent Cmd+V")
            return
        }

        // Strategy 3: Clipboard + key simulation via CGEvent source
        if pasteViaClipboard(text, method: .keyboardEvent) {
            print("✅ [TextOutput] Pasted via keyboard event")
            return
        }

        // Strategy 4: Just put it on clipboard and notify
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("📋 [TextOutput] Text copied to clipboard — press Cmd+V to paste")

        // Show a brief notification
        showCopiedNotification()
    }

    // MARK: - Accessibility API

    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement else { return false }

        let axElement = element as! AXUIElement

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else { return false }

        var currentValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue) == .success,
              let currentText = currentValue as? String else { return false }

        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeRef = rangeValue else { return false }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) else { return false }

        let startIndex = currentText.index(currentText.startIndex, offsetBy: min(cfRange.location, currentText.count))
        let endIndex = currentText.index(startIndex, offsetBy: min(cfRange.length, currentText.count - cfRange.location))

        var newText = currentText
        newText.replaceSubrange(startIndex..<endIndex, with: text)

        guard AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newText as CFTypeRef) == .success else { return false }

        let newCursorLocation = cfRange.location + text.count
        var newRange = CFRange(location: newCursorLocation, length: 0)
        if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
        }
        return true
    }

    // MARK: - Clipboard Paste

    private enum PasteMethod {
        case cgEvent
        case keyboardEvent
    }

    private func pasteViaClipboard(_ text: String, method: PasteMethod) -> Bool {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let success: Bool
        switch method {
        case .cgEvent:
            success = simulateCmdV()
        case .keyboardEvent:
            success = simulateCmdVViaKeyEvent()
        }

        // Restore clipboard after delay
        if success, let previous = previousString {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }

        return success
    }

    private func simulateCmdV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private func simulateCmdVViaKeyEvent() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    // MARK: - Notification

    private func showCopiedNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Vox"
        content.body = "Transcription copied — Cmd+V to paste"
        let request = UNNotificationRequest(identifier: "vox-copied", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
