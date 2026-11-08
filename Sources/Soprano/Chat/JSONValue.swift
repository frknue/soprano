import Foundation

/// A JSON document as a Sendable value, for the agent protocols a chat tab
/// speaks: their messages vary too much per method to decode into fixed types.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(parsing data: Data) throws {
        self = try JSONValue(any: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    /// Converts what `JSONSerialization` returns; anything else becomes null.
    init(any value: Any) {
        switch value {
        case let number as NSNumber:
            // JSONSerialization hands booleans over as NSNumber too.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// The value as `JSONSerialization` takes it.
    var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value):
            value.rounded() == value && abs(value) < 1e15 ? Int(value) as Any : value as Any
        case .string(let value): value
        case .array(let values): values.map(\.any)
        case .object(let values): values.mapValues(\.any)
        }
    }

    /// One line of compact JSON, without a trailing newline.
    func serialized() throws -> Data {
        try JSONSerialization.data(withJSONObject: any, options: [.fragmentsAllowed, .withoutEscapingSlashes])
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let values) = self { return values[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// A string that holds more than whitespace.
    var nonEmptyString: String? {
        guard let string, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return string
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var int: Int? {
        number.map { Int($0) }
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var object: [String: JSONValue]? {
        if case .object(let values) = self { return values }
        return nil
    }

    var isNull: Bool {
        self == .null
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    init(nilLiteral: ()) { self = .null }
}
