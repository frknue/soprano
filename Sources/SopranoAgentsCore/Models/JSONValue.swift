import Foundation

/// A Sendable JSON tree for provider wire messages and structured text generation.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value):
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case let .number(value) = self { return Int(value) }
        return nil
    }

    public var doubleValue: Double? {
        if case let .number(value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    /// Compact single-line JSON (one message per line on stdio transports).
    public func jsonString(sortedKeys: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = sortedKeys ? [.sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Lone UTF-16 surrogate escapes (`"\udbc4"`, text cut inside an emoji or a private-use
    /// glyph) parse as U+FFFD, as JavaScript's `JSON.parse` keeps them: `JSONDecoder` would
    /// reject the whole document, e.g. omp's entire `get_entries` answer.
    public static func parse(_ text: String) throws -> JSONValue {
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            guard let repaired = replacingLoneSurrogateEscapes(in: text) else { throw error }
            return try JSONDecoder().decode(JSONValue.self, from: Data(repaired.utf8))
        }
    }

    /// `text` with every `\uD800`–`\uDFFF` escape that is not half of a high/low pair replaced by
    /// `\ufffd`; nil when there is none. Every backslash starts an escape, so `\\u…` is skipped.
    static func replacingLoneSurrogateEscapes(in text: String) -> String? {
        let bytes = Array(text.utf8)
        func unit(at index: Int) -> UInt16? {
            guard index + 5 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { return nil }
            var value: UInt16 = 0
            for byte in bytes[(index + 2)...(index + 5)] {
                guard let digit = Character(Unicode.Scalar(byte)).hexDigitValue else { return nil }
                value = value << 4 | UInt16(digit)
            }
            return value
        }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var changed = false
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count else {
                output.append(bytes[index])
                index += 1
                continue
            }
            guard let value = unit(at: index) else {
                output.append(contentsOf: bytes[index...(index + 1)])
                index += 2
                continue
            }
            if (0xD800...0xDBFF).contains(value), let low = unit(at: index + 6), (0xDC00...0xDFFF).contains(low) {
                output.append(contentsOf: bytes[index..<(index + 12)])
                index += 12
            } else if (0xD800...0xDFFF).contains(value) {
                output.append(contentsOf: Array(#"\ufffd"#.utf8))
                changed = true
                index += 6
            } else {
                output.append(contentsOf: bytes[index..<(index + 6)])
                index += 6
            }
        }
        return changed ? String(decoding: output, as: UTF8.self) : nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}
