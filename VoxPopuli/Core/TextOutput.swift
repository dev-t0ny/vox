import Cocoa
import UserNotifications

final class TextOutput {

    func type(_ text: String, targetApp: NSRunningApplication? = nil) {
        print("📋 [TextOutput] Typing: \"\(text.prefix(60))\"")

        // Re-focus the target app that was active when recording started
        if let app = targetApp {
            print("📋 [TextOutput] Re-activating: \(app.localizedName ?? "unknown")")
            app.activate()
            Thread.sleep(forTimeInterval: 0.15) // Wait for app to come to front
        }

        // Put text on clipboard first (needed for all paste strategies)
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Try paste strategies in order
        if pasteViaAppleScript() {
            print("✅ [TextOutput] Pasted via AppleScript")
            restoreClipboardLater(previousString)
            return
        }

        if pasteViaOsascript() {
            print("✅ [TextOutput] Pasted via osascript")
            restoreClipboardLater(previousString)
            return
        }

        if AXIsProcessTrusted() {
            if insertViaAccessibility(text) {
                print("✅ [TextOutput] Inserted via Accessibility API")
                if let prev = previousString {
                    pasteboard.clearContents()
                    pasteboard.setString(prev, forType: .string)
                }
                return
            }

            if pasteViaCGEvent() {
                print("✅ [TextOutput] Pasted via CGEvent")
                restoreClipboardLater(previousString)
                return
            }
        }

        // Last resort: text is on clipboard, notify user
        print("📋 [TextOutput] Text on clipboard — Cmd+V to paste")
    }

    // MARK: - AppleScript paste (inline, triggers permission prompt from our app)

    private func pasteViaAppleScript() -> Bool {
        print("📋 [TextOutput] Trying AppleScript paste")

        let script = NSAppleScript(source: """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """)

        var errorInfo: NSDictionary?
        script?.executeAndReturnError(&errorInfo)

        if let error = errorInfo {
            print("📋 [TextOutput] AppleScript error: \(error)")
            return false
        }
        return true
    }

    // MARK: - osascript paste (subprocess fallback)

    private func pasteViaOsascript() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", """
            tell application "System Events"
                keystroke "v" using command down
            end tell
        """]

        let errPipe = Pipe()
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()

            if task.terminationStatus != 0 {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errStr = String(data: errData, encoding: .utf8) ?? "unknown"
                print("📋 [TextOutput] osascript error: \(errStr)")
            }

            return task.terminationStatus == 0
        } catch {
            print("📋 [TextOutput] osascript failed: \(error)")
            return false
        }
    }

    // MARK: - CGEvent paste

    private func pasteViaCGEvent() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    // MARK: - Accessibility API (direct text insertion)

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

    // MARK: - Helpers

    private func restoreClipboardLater(_ previousString: String?) {
        guard let previous = previousString else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(previous, forType: .string)
        }
    }
}
