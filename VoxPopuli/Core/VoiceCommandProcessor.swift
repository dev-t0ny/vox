import Foundation

/// Regex-based voice command substitution processor.
struct VoiceCommandProcessor {

    private enum CommandType {
        case newline        // \n or \n\n — trim space before and after
        case openPunct      // opening " or ( — keep space before, trim space after
        case closePunct     // closing " or ) — trim space before, no extra space after
        case endPunct       // . , ? ! : ; — trim space before, add space after
    }

    private struct Command {
        let pattern: String
        let replacement: String
        let type: CommandType
    }

    // Longer phrases first to avoid partial matches.
    private static let commands: [Command] = [
        Command(pattern: "new paragraph",     replacement: "\n\n",  type: .newline),
        Command(pattern: "new line",          replacement: "\n",    type: .newline),
        Command(pattern: "question mark",     replacement: "?",     type: .endPunct),
        Command(pattern: "exclamation mark",  replacement: "!",     type: .endPunct),
        Command(pattern: "exclamation point", replacement: "!",     type: .endPunct),
        Command(pattern: "open quote",        replacement: "\"",    type: .openPunct),
        Command(pattern: "close quote",       replacement: "\"",    type: .closePunct),
        Command(pattern: "open paren",        replacement: "(",     type: .openPunct),
        Command(pattern: "close paren",       replacement: ")",     type: .closePunct),
        Command(pattern: "semicolon",         replacement: ";",     type: .endPunct),
        Command(pattern: "period",            replacement: ".",     type: .endPunct),
        Command(pattern: "comma",             replacement: ",",     type: .endPunct),
        Command(pattern: "colon",             replacement: ":",     type: .endPunct),
    ]

    /// Token mappings for AI cleanup preservation.
    private static let tokenMappings: [(phrase: String, token: String)] = [
        ("new paragraph", "<PARAGRAPH>"),
        ("new line",      "<NEWLINE>"),
    ]

    /// Apply all voice command substitutions to the input text.
    func apply(_ text: String) -> String {
        var result = text

        for command in Self.commands {
            let escaped = NSRegularExpression.escapedPattern(for: command.pattern)

            // Match the command word(s) with optional surrounding spaces (not newlines)
            let pattern = "[^\\S\\n]*\\b\(escaped)\\b[^\\S\\n]*"

            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
                continue
            }

            // Build replacement based on type
            let replacement: String
            switch command.type {
            case .newline:
                // Trim spaces on both sides, the newline replaces them
                replacement = command.replacement
            case .openPunct:
                // Space before opening char, no space after
                replacement = " \(command.replacement)"
            case .closePunct:
                // No space before closing char, no space after
                replacement = command.replacement
            case .endPunct:
                // No space before punctuation, space after
                replacement = "\(command.replacement) "
            }

            let nsRange = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: nsRange,
                withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
            )
        }

        // Trim leading/trailing whitespace
        result = result.trimmingCharacters(in: .whitespaces)

        // Clean up multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Clean up trailing spaces on lines (before newlines)
        result = result.replacingOccurrences(of: " \n", with: "\n")

        // Clean up leading spaces on lines (after newlines)
        result = result.replacingOccurrences(of: "\n ", with: "\n")

        return result
    }

    /// Convert voice command phrases to tokens for AI cleanup preservation.
    func convertToTokens(_ text: String) -> String {
        var result = text
        for mapping in Self.tokenMappings {
            guard let regex = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: mapping.phrase))\\b",
                options: .caseInsensitive
            ) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: mapping.token)
            )
        }
        return result
    }

    /// Restore tokens back to their actual characters.
    func restoreTokens(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: " <NEWLINE> ", with: "\n")
        result = result.replacingOccurrences(of: "<NEWLINE>", with: "\n")
        result = result.replacingOccurrences(of: " <PARAGRAPH> ", with: "\n\n")
        result = result.replacingOccurrences(of: "<PARAGRAPH>", with: "\n\n")
        return result
    }
}
