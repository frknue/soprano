import Foundation

/// Helpers shared by the output parsers.
enum GitOutput {
    /// Splits NUL-separated output into fields, dropping a trailing empty one.
    static func nulFields(_ data: Data) -> [String] {
        var fields = data.split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if fields.last?.isEmpty == true { fields.removeLast() }
        return fields
    }

    /// Non-empty records separated by NUL, each without leading newlines
    /// (for-each-ref ends records with "\0\n").
    static func records(_ data: Data) -> [Data.SubSequence] {
        data.split(separator: 0).compactMap { record in
            let trimmed = record.drop(while: { $0 == 0x0A })
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Splits `bytes` on `separator` into at most `count` fields (the last
    /// keeps further separators); nil when there are fewer. Works on bytes so
    /// a separator followed by a combining mark still splits.
    static func fields(_ bytes: Data.SubSequence, separator: UInt8 = 0x1F, count: Int) -> [String]? {
        let parts = bytes.split(separator: separator, maxSplits: count - 1, omittingEmptySubsequences: false)
        guard parts.count == count else { return nil }
        return parts.map { String(decoding: $0, as: UTF8.self) }
    }

    /// Text output without its final newline(s).
    static func trimmedLines(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    static func firstLine(_ data: Data) -> String {
        trimmedLines(data).first ?? ""
    }

    static func date(_ seconds: String) -> Date {
        Date(timeIntervalSince1970: TimeInterval(Int64(seconds) ?? 0))
    }

    /// A pathspec matching exactly `path` (no glob or magic interpretation).
    static func literal(_ path: String) -> String {
        ":(literal)" + path
    }

    /// Undoes git's C-style quoting (`"a\tb"`, octal escapes) of a path in
    /// diff headers. Unquoted input is returned unchanged.
    static func unquote(_ text: Substring) -> String {
        guard text.count >= 2, text.first == "\"", text.last == "\"" else { return String(text) }
        var bytes: [UInt8] = []
        let inner = Array(text.dropFirst().dropLast().utf8)
        var index = 0
        while index < inner.count {
            let byte = inner[index]
            guard byte == UInt8(ascii: "\\"), index + 1 < inner.count else {
                bytes.append(byte)
                index += 1
                continue
            }
            let escaped = inner[index + 1]
            index += 2
            switch escaped {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "a"): bytes.append(0x07)
            case UInt8(ascii: "b"): bytes.append(0x08)
            case UInt8(ascii: "f"): bytes.append(0x0C)
            case UInt8(ascii: "v"): bytes.append(0x0B)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(escaped - UInt8(ascii: "0"))
                var digits = 1
                while digits < 3, index < inner.count,
                      (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(inner[index]) {
                    value = value * 8 + Int(inner[index] - UInt8(ascii: "0"))
                    index += 1
                    digits += 1
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default:
                bytes.append(escaped)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
