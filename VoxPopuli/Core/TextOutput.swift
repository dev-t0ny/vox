import Cocoa

final class TextOutput {

    func type(_ text: String, targetApp: NSRunningApplication? = nil) {
        print("📋 [TextOutput] Typing: \"\(text.prefix(60))\"")
        print("📋 [TextOutput] AXIsProcessTrusted: \(AXIsProcessTrusted())")

        // Step 1: Copy to clipboard
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Step 2: Re-focus target app
        if let app = targetApp {
            print("📋 [TextOutput] Activating: \(app.localizedName ?? "?")")
            app.activate(options: .activateIgnoringOtherApps)
        }

        // Step 3: Paste after a short delay (let app come to focus)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.simulateCmdV()
            print("📋 [TextOutput] Cmd+V sent")

            // Step 4: Restore clipboard later
            if let prev = previousString {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    pasteboard.clearContents()
                    pasteboard.setString(prev, forType: .string)
                }
            }
        }
    }

    private func simulateCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)

        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false) else {
            print("❌ [TextOutput] Failed to create CGEvent")
            return
        }

        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cghidEventTap)
        usleep(50000) // 50ms between down and up
        up.post(tap: .cghidEventTap)
    }
}
