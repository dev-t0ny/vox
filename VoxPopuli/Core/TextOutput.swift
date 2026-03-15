import Cocoa
import ApplicationServices

final class TextOutput {

    /// Insert text at the cursor position in the frontmost application.
    /// Tries Accessibility API first, falls back to clipboard paste.
    func type(_ text: String) {
        if !insertViaAccessibility(text) {
            insertViaClipboard(text)
        }
    }

    // MARK: - Accessibility API (primary)

    private func insertViaAccessibility(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard focusResult == .success, let element = focusedElement else {
            return false
        }

        let axElement = element as! AXUIElement

        // Check if kAXValueAttribute is settable
        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            axElement,
            kAXValueAttribute as CFString,
            &settable
        )
        guard settableResult == .success, settable.boolValue else {
            return false
        }

        // Read the current text value
        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            &currentValue
        )
        guard valueResult == .success, let currentText = currentValue as? String else {
            return false
        }

        // Read the selected text range (cursor position)
        var rangeValue: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            axElement,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        )
        guard rangeResult == .success, let rangeRef = rangeValue else {
            return false
        }

        var cfRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &cfRange) else {
            return false
        }

        // Perform string surgery: insert text at cursor position
        let startIndex = currentText.index(
            currentText.startIndex,
            offsetBy: min(cfRange.location, currentText.count)
        )
        let endIndex = currentText.index(
            startIndex,
            offsetBy: min(cfRange.length, currentText.count - cfRange.location)
        )

        var newText = currentText
        newText.replaceSubrange(startIndex..<endIndex, with: text)

        // Write back the modified string
        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXValueAttribute as CFString,
            newText as CFTypeRef
        )
        guard setResult == .success else {
            return false
        }

        // Move cursor to after the inserted text
        let newCursorLocation = cfRange.location + text.count
        var newRange = CFRange(location: newCursorLocation, length: 0)
        guard let newRangeValue = AXValueCreate(.cfRange, &newRange) else {
            return true // Text was inserted, cursor positioning is non-critical
        }

        AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextRangeAttribute as CFString,
            newRangeValue
        )

        return true
    }

    // MARK: - Clipboard paste (fallback)

    private func insertViaClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        } ?? []

        // Set transcribed text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after 500ms
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            for (typeRaw, data) in savedItems {
                let type = NSPasteboard.PasteboardType(typeRaw)
                pasteboard.setData(data, forType: type)
            }
        }
    }

    private func simulatePaste() {
        let vKeyCode: CGKeyCode = 9 // 'v' key

        let source = CGEventSource(stateID: .hidSystemState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
