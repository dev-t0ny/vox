import Cocoa

final class TextOutput {

    /// If true, tries to auto-paste. If false (or auto-paste fails), copies to clipboard.
    var autoPasteEnabled: Bool = true

    /// Returns true if auto-paste succeeded
    @discardableResult
    func type(_ text: String, targetApp: NSRunningApplication? = nil) -> Bool {
        // Always copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        guard autoPasteEnabled else {
            print("📋 [TextOutput] Auto-paste off — copied to clipboard")
            return false
        }

        // Re-focus target app
        if let app = targetApp {
            app.activate(options: [])
        }

        // Try CGEvent Cmd+V (needs Accessibility)
        if AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                self.simulateCmdV()
            }
            print("✅ [TextOutput] Auto-pasted via CGEvent")
            return true
        }

        // Try AppleScript (needs Automation)
        if pasteViaAppleScript() {
            print("✅ [TextOutput] Auto-pasted via AppleScript")
            return true
        }

        print("📋 [TextOutput] Auto-paste failed — copied to clipboard")
        return false
    }

    private func simulateCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        usleep(50000)
        up.post(tap: .cghidEventTap)
    }

    private func pasteViaAppleScript() -> Bool {
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
