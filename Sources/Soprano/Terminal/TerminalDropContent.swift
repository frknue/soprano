import AppKit

enum TerminalDropContent {
    static let acceptedPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
        .URL,
    ]

    static func text(from pasteboard: NSPasteboard) -> String? {
        if let url = pasteboard.string(forType: .URL) {
            return shellEscape(url)
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
           !urls.isEmpty {
            return urls
                .map { shellEscape($0.path) }
                .joined(separator: " ")
        }

        return pasteboard.string(forType: .string)
    }

    static func shellEscape(_ value: String) -> String {
        let characters = "\\ ()[]{}<>\"'`!#$&;|*?\t"
        var escaped = value
        for character in characters {
            escaped = escaped.replacingOccurrences(
                of: String(character),
                with: "\\\(character)"
            )
        }
        return escaped
    }
}
