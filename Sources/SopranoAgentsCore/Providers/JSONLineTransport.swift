import Foundation

/// A bidirectional newline-delimited text channel: `LineProcess` in the app, a fake in tests.
public protocol JSONLineTransport: AnyObject, Sendable {
    /// Lines in arrival order, then exactly one `.exited` when the channel closes.
    var incoming: AsyncStream<LineProcessEvent> { get }
    func send(_ line: String) throws
    /// Closes the channel (terminates the process). Idempotent.
    func close()
}

extension LineProcess: JSONLineTransport {
    public var incoming: AsyncStream<LineProcessEvent> { events }
    public func close() { terminate() }
}

extension JSONValue {
    /// Multi-line, key-sorted JSON for the work log's expanded tool input.
    public func prettyJSONString() -> String {
        if case let .string(text) = self { return text }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return jsonString() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Non-empty trimmed string, else nil.
    var nonEmptyString: String? {
        guard let text = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Prompt text sent to omp.
enum ProviderPrompt {
    /// Message text with attachment paths: every attachment is listed after the
    /// text as `[Attached image "shot.png" is saved at: /path]`, so the agent can open it even
    /// when the image block alone is not enough.
    static func text(_ text: String, attachments: [Attachment]) -> String {
        var result = text
        for attachment in attachments {
            let context = "[Attached \(attachment.kind.rawValue) \"\(attachment.name)\" is saved at: \(attachment.path)]"
            result = result.isEmpty ? context : "\(result)\n\n\(context)"
        }
        return result
    }
}
