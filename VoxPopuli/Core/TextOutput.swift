import Cocoa

final class TextOutput {

    func type(_ text: String, targetApp: NSRunningApplication? = nil) {
        // Copy to clipboard
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        print("📋 [TextOutput] Copied to clipboard: \"\(text.prefix(60))\"")
    }
}
