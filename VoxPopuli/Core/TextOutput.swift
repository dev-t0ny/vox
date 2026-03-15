import Cocoa
import ApplicationServices
import Carbon.HIToolbox

final class TextOutput {

    func type(_ text: String) {
        print("📋 [TextOutput] Attempting to type: \"\(text)\"")

        if insertViaAccessibility(text) {
            print("✅ [TextOutput] Inserted via Accessibility API")
            return
        }

        print("📋 [TextOutput] AX failed, trying clipboard paste...")
        insertViaClipboard(text)
    }

    // MARK: - Accessibility API (primary)

    private func insertViaAccessibility(_ text: String) -> Bool {
        guard AXIsProcessTrusted() else {
            print("📋 [TextOutput] AX not trusted, skipping")
            return false
        }

        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard focusResult == .success, let element = focusedElement else {
            print("📋 [TextOutput] No focused element found")
            return false
        }

        let axElement = element as! AXUIElement

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(axElement, kAXValueAttribute as CFString, &settable)
        guard settable.boolValue else {
            print("📋 [TextOutput] Focused element value not settable")
            return false
        }

        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue)
        guard valueResult == .success, let currentText = currentValue as? String else {
            return false
        }

        var rangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        guard rangeResult == .success, let rangeRef = rangeValue else {
            return false
        }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) else {
            return false
        }

        let startIndex = currentText.index(currentText.startIndex, offsetBy: min(cfRange.location, currentText.count))
        let endIndex = currentText.index(startIndex, offsetBy: min(cfRange.length, currentText.count - cfRange.location))

        var newText = currentText
        newText.replaceSubrange(startIndex..<endIndex, with: text)

        let setResult = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, newText as CFTypeRef)
        guard setResult == .success else { return false }

        let newCursorLocation = cfRange.location + text.count
        var newRange = CFRange(location: newCursorLocation, length: 0)
        if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
        }

        return true
    }

    // MARK: - Clipboard paste (fallback)

    private func insertViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard
        let previousString = pasteboard.string(forType: .string)

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        print("📋 [TextOutput] Text copied to clipboard")

        // Try multiple paste methods
        if simulatePasteViaCGEvent() {
            print("✅ [TextOutput] Pasted via CGEvent")
        } else if simulatePasteViaAppleScript() {
            print("✅ [TextOutput] Pasted via AppleScript")
        } else {
            print("⚠️ [TextOutput] Auto-paste failed — text is on clipboard, Cmd+V to paste manually")
        }

        // Restore clipboard after delay
        if let previous = previousString {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func simulatePasteViaCGEvent() -> Bool {
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

    private func simulatePasteViaAppleScript() -> Bool {
        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """)
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }
}
