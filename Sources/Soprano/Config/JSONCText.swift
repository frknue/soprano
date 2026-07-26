import Foundation

/// The text engine behind Soprano's VS Code-style `~/.config/soprano/settings.json`.
///
/// Two jobs a plain `JSONDecoder` cannot do:
///
/// 1. **Read what humans write.** Settings files collect `//` and `/* */`
///    comments and trailing commas. Rejecting them would mean telling the user
///    their hand-written file is invalid over a stray comma.
/// 2. **Write one value back without destroying the file.** Decoding a model,
///    mutating it and re-encoding would silently delete every comment, blank
///    line and hand-chosen key order in the document. So a write is applied as
///    a single surgical text splice over the original characters — the same
///    approach as VS Code's `jsonc-parser` `modify`/`applyEdits`.
///
/// The scanner is hand-written on purpose: the package has zero dependencies
/// and keeping it that way is worth a few hundred lines.
enum JSONCText {

    // MARK: - Errors

    /// A syntax problem, positioned in the *original* document.
    ///
    /// Comment stripping blanks characters in place instead of deleting them,
    /// so every index the parser reports still lines up with what the user sees
    /// in their editor.
    struct ParseError: Error, CustomStringConvertible, Equatable {
        /// Human-readable cause, without the position (the settings UI renders
        /// the line separately).
        let message: String
        /// 1-based line in the original text.
        let line: Int
        /// 1-based column in the original text, counted in characters.
        let column: Int

        var description: String { "\(message) (line \(line), column \(column))" }
    }

    // MARK: - Reading

    /// JSONC text -> strict JSON data (comments and trailing commas removed).
    ///
    /// The surviving bytes are the user's own: numbers and strings are passed
    /// through verbatim rather than re-serialized, so nothing is reformatted or
    /// rounded on the way to `JSONDecoder`.
    static func strictJSONData(from text: String) throws -> Data {
        let source = Array(text)
        var stripped = try strippingComments(source).text
        var parser = Parser(characters: stripped, source: source)
        _ = try parser.parseDocument()
        for index in parser.trailingCommas {
            stripped[index] = " "
        }
        return Data(String(stripped).utf8)
    }

    /// Decode a `Decodable` value from JSONC text.
    static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        try JSONDecoder().decode(type, from: strictJSONData(from: text))
    }

    // MARK: - Writing

    /// Surgically set the value at the given key path, preserving every
    /// comment, blank line, key order and indentation style in the rest of the
    /// document. Missing intermediate objects are created. `value` accepts
    /// JSONSerialization-compatible values (String, Int, Double, Bool, [Any],
    /// [String: Any], NSNull for JSON null).
    static func setting(_ value: Any, at path: [String], in text: String) throws -> String {
        guard !path.isEmpty else {
            throw ParseError(message: "Cannot set a value without a key path", line: 1, column: 1)
        }
        let source = Array(text)
        let (stripped, isComment) = try strippingComments(source)
        let unit = indentUnit(in: source)

        // Empty, whitespace-only or comment-only file: there is no document to
        // splice into, so write a fresh one under whatever the user had.
        guard stripped.contains(where: { !isWhitespace($0) }) else {
            return try newDocument(with: value, at: path, keeping: source, unit: unit)
        }

        var parser = Parser(characters: stripped, source: source)
        let root = try parser.parseDocument()
        guard case .object = root.kind else {
            throw parseError("Expected the document root to be a JSON object", at: root.start, in: source)
        }
        let edit = try settingEdit(
            value,
            path: path[...],
            in: root,
            source: source,
            stripped: stripped,
            isComment: isComment,
            unit: unit
        )
        return apply(edit, to: source)
    }

    /// Surgically remove the key at the given path. No-op when absent.
    static func removing(at path: [String], in text: String) throws -> String {
        guard !path.isEmpty else {
            throw ParseError(message: "Cannot remove a value without a key path", line: 1, column: 1)
        }
        let source = Array(text)
        let (stripped, isComment) = try strippingComments(source)
        guard stripped.contains(where: { !isWhitespace($0) }) else { return text }

        var parser = Parser(characters: stripped, source: source)
        let root = try parser.parseDocument()
        guard case .object = root.kind else {
            throw parseError("Expected the document root to be a JSON object", at: root.start, in: source)
        }
        guard let edit = removalEdit(
            path: path[...],
            in: root,
            source: source,
            stripped: stripped,
            isComment: isComment
        ) else {
            return text
        }
        return apply(edit, to: source)
    }

    // MARK: - Comment stripping

    /// Replaces every comment with spaces, leaving newlines alone, and reports
    /// which characters those comments occupied.
    ///
    /// Blanking rather than deleting is what keeps parser positions valid in
    /// the original document, and what lets the edit machinery treat "trailing
    /// comment on this line" as plain whitespace. The companion `isComment` map
    /// is what stops it from treating the *inside* of a multi-line block
    /// comment as whitespace too — splicing a new entry there would silently
    /// comment it out.
    private static func strippingComments(
        _ source: [Character]
    ) throws -> (text: [Character], isComment: [Bool]) {
        var output = source
        var isComment = [Bool](repeating: false, count: source.count)
        var index = 0
        var inString = false

        while index < source.count {
            let character = source[index]

            if inString {
                if character == "\\" {
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
                index += 1
                continue
            }

            if character == "\"" {
                inString = true
                index += 1
                continue
            }

            if character == "/", index + 1 < source.count {
                let next = source[index + 1]
                if next == "/" {
                    while index < source.count, !source[index].isNewline {
                        output[index] = " "
                        isComment[index] = true
                        index += 1
                    }
                    continue
                }
                if next == "*" {
                    let start = index
                    output[index] = " "
                    output[index + 1] = " "
                    isComment[index] = true
                    isComment[index + 1] = true
                    index += 2
                    var closed = false
                    while index < source.count {
                        if source[index] == "*", index + 1 < source.count, source[index + 1] == "/" {
                            output[index] = " "
                            output[index + 1] = " "
                            isComment[index] = true
                            isComment[index + 1] = true
                            index += 2
                            closed = true
                            break
                        }
                        if !source[index].isNewline { output[index] = " " }
                        isComment[index] = true
                        index += 1
                    }
                    guard closed else {
                        throw parseError("Unterminated block comment", at: start, in: source)
                    }
                    continue
                }
            }

            index += 1
        }
        return (output, isComment)
    }

    /// Advances past whitespace *and whole comments* — including the newlines
    /// inside a block comment, which are the trap: they look like the end of
    /// the line but are not a place any JSON may be written.
    private static func skippingTrailingFiller(
        from position: Int,
        stripped: [Character],
        isComment: [Bool]
    ) -> Int {
        var scan = position
        while scan < stripped.count {
            if isComment[scan] || isIndentCharacter(stripped[scan]) {
                scan += 1
                continue
            }
            break
        }
        return scan
    }

    // MARK: - Parsed shape

    /// A value plus its span in the document. Spans are the whole point: they
    /// are what an edit replaces.
    private struct ParsedValue {
        enum Kind {
            case object([ParsedMember])
            case array([ParsedValue])
            case scalar
        }

        let kind: Kind
        let start: Int
        let end: Int
    }

    private struct ParsedMember {
        let key: String
        /// Index of the opening quote of the key.
        let keyStart: Int
        let value: ParsedValue
    }

    /// Recursive-descent scanner over the comment-stripped characters, with the
    /// original text kept alongside purely for error positions.
    private struct Parser {
        let characters: [Character]
        let source: [Character]
        var index = 0
        /// Commas that sit directly before a `}` or `]`; blanked out when
        /// producing strict JSON.
        var trailingCommas: [Int] = []

        mutating func parseDocument() throws -> ParsedValue {
            skipWhitespace()
            let value = try parseValue()
            skipWhitespace()
            guard index >= characters.count else {
                throw error("Unexpected character '\(characters[index])' after the top-level value")
            }
            return value
        }

        private mutating func skipWhitespace() {
            while index < characters.count, isWhitespace(characters[index]) {
                index += 1
            }
        }

        private mutating func parseValue() throws -> ParsedValue {
            guard index < characters.count else {
                throw error("Unexpected end of input, expected a value")
            }
            switch characters[index] {
            case "{": return try parseObject()
            case "[": return try parseArray()
            case "\"":
                let start = index
                _ = try parseStringLiteral()
                return ParsedValue(kind: .scalar, start: start, end: index)
            case "t": return try parseLiteral("true")
            case "f": return try parseLiteral("false")
            case "n": return try parseLiteral("null")
            case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
                return try parseNumber()
            default:
                throw error("Unexpected character '\(characters[index])'")
            }
        }

        private mutating func parseObject() throws -> ParsedValue {
            let start = index
            index += 1
            var members: [ParsedMember] = []

            while true {
                skipWhitespace()
                guard index < characters.count else {
                    throw error("Unexpected end of input, expected '}'", at: characters.count)
                }
                if characters[index] == "}" {
                    index += 1
                    break
                }
                guard characters[index] == "\"" else {
                    throw error("Expected a double-quoted key")
                }
                let keyStart = index
                let key = try parseStringLiteral()
                skipWhitespace()
                guard index < characters.count, characters[index] == ":" else {
                    throw error("Expected ':'", at: min(index, characters.count))
                }
                index += 1
                skipWhitespace()
                let value = try parseValue()
                members.append(ParsedMember(key: key, keyStart: keyStart, value: value))

                skipWhitespace()
                guard index < characters.count else {
                    throw error("Unexpected end of input, expected '}'", at: characters.count)
                }
                if characters[index] == "," {
                    let comma = index
                    index += 1
                    skipWhitespace()
                    if index < characters.count, characters[index] == "}" {
                        trailingCommas.append(comma)
                    }
                    continue
                }
                if characters[index] == "}" {
                    index += 1
                    break
                }
                throw error("Expected ','")
            }
            return ParsedValue(kind: .object(members), start: start, end: index)
        }

        private mutating func parseArray() throws -> ParsedValue {
            let start = index
            index += 1
            var elements: [ParsedValue] = []

            while true {
                skipWhitespace()
                guard index < characters.count else {
                    throw error("Unexpected end of input, expected ']'", at: characters.count)
                }
                if characters[index] == "]" {
                    index += 1
                    break
                }
                elements.append(try parseValue())
                skipWhitespace()
                guard index < characters.count else {
                    throw error("Unexpected end of input, expected ']'", at: characters.count)
                }
                if characters[index] == "," {
                    let comma = index
                    index += 1
                    skipWhitespace()
                    if index < characters.count, characters[index] == "]" {
                        trailingCommas.append(comma)
                    }
                    continue
                }
                if characters[index] == "]" {
                    index += 1
                    break
                }
                throw error("Expected ','")
            }
            return ParsedValue(kind: .array(elements), start: start, end: index)
        }

        private mutating func parseLiteral(_ literal: String) throws -> ParsedValue {
            let start = index
            for expected in literal {
                guard index < characters.count, characters[index] == expected else {
                    throw error("Expected '\(literal)'", at: start)
                }
                index += 1
            }
            return ParsedValue(kind: .scalar, start: start, end: index)
        }

        private mutating func parseNumber() throws -> ParsedValue {
            let start = index
            if index < characters.count, characters[index] == "-" { index += 1 }
            guard consumeDigits() else { throw error("Invalid number", at: start) }
            if index < characters.count, characters[index] == "." {
                index += 1
                guard consumeDigits() else { throw error("Invalid number", at: start) }
            }
            if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" {
                    index += 1
                }
                guard consumeDigits() else { throw error("Invalid number", at: start) }
            }
            return ParsedValue(kind: .scalar, start: start, end: index)
        }

        private mutating func consumeDigits() -> Bool {
            let start = index
            while index < characters.count, characters[index].isNumber, characters[index].isASCII {
                index += 1
            }
            return index > start
        }

        /// Consumes a string literal and returns its decoded contents (needed
        /// so key paths match keys that were written with escapes).
        private mutating func parseStringLiteral() throws -> String {
            let start = index
            index += 1
            var value = ""

            while index < characters.count {
                let character = characters[index]
                if character == "\"" {
                    index += 1
                    return value
                }
                if character == "\\" {
                    let escapeStart = index
                    index += 1
                    guard index < characters.count else { break }
                    switch characters[index] {
                    case "\"": value.append("\"")
                    case "\\": value.append("\\")
                    case "/": value.append("/")
                    case "b": value.append("\u{08}")
                    case "f": value.append("\u{0C}")
                    case "n": value.append("\n")
                    case "r": value.append("\r")
                    case "t": value.append("\t")
                    case "u":
                        value.append(try consumeUnicodeEscape(startingAt: escapeStart))
                        continue
                    default:
                        throw error(
                            "Invalid escape sequence '\\\(characters[index])' in string",
                            at: escapeStart
                        )
                    }
                    index += 1
                    continue
                }
                value.append(character)
                index += 1
            }
            throw error("Unterminated string", at: start)
        }

        /// Reads `\uXXXX` (already positioned on the `u`), pairing surrogates so
        /// astral-plane keys survive the round trip.
        private mutating func consumeUnicodeEscape(startingAt escapeStart: Int) throws -> Character {
            let first = try readHexQuad(after: escapeStart)
            index += 5

            if first >= 0xD800, first <= 0xDBFF,
               index + 1 < characters.count,
               characters[index] == "\\",
               characters[index + 1] == "u",
               let second = try? readHexQuad(after: index),
               second >= 0xDC00, second <= 0xDFFF {
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                index += 6
                guard let scalar = Unicode.Scalar(combined) else {
                    throw error("Invalid \\u escape in string", at: escapeStart)
                }
                return Character(scalar)
            }
            guard let scalar = Unicode.Scalar(first) else {
                throw error("Invalid \\u escape in string", at: escapeStart)
            }
            return Character(scalar)
        }

        /// Reads the four hex digits that follow a `\u` whose backslash is at
        /// `backslash`.
        private func readHexQuad(after backslash: Int) throws -> UInt32 {
            var digits = ""
            for offset in 2...5 {
                let position = backslash + offset
                guard position < characters.count, characters[position].isHexDigit else {
                    throw error("Invalid \\u escape in string", at: backslash)
                }
                digits.append(characters[position])
            }
            guard let value = UInt32(digits, radix: 16) else {
                throw error("Invalid \\u escape in string", at: backslash)
            }
            return value
        }

        private func error(_ message: String, at position: Int? = nil) -> ParseError {
            parseError(message, at: position ?? index, in: source)
        }
    }

    // MARK: - Edits

    /// A single splice: replace `[start, end)` with `text`.
    private struct Edit {
        let start: Int
        let end: Int
        let text: String
    }

    private static func apply(_ edit: Edit, to source: [Character]) -> String {
        String(source[0..<edit.start]) + edit.text + String(source[edit.end...])
    }

    private static func settingEdit(
        _ value: Any,
        path: ArraySlice<String>,
        in object: ParsedValue,
        source: [Character],
        stripped: [Character],
        isComment: [Bool],
        unit: String
    ) throws -> Edit {
        guard let key = path.first, case let .object(members) = object.kind else {
            throw parseError("Expected a JSON object", at: object.start, in: source)
        }
        let rest = path.dropFirst()

        guard let member = members.first(where: { $0.key == key }) else {
            return try insertion(
                of: nested(value, under: rest),
                key: key,
                into: object,
                members: members,
                source: source,
                stripped: stripped,
                isComment: isComment,
                unit: unit
            )
        }

        if rest.isEmpty {
            let indent = lineIndent(of: member.keyStart, in: source)
            return Edit(
                start: member.value.start,
                end: member.value.end,
                text: try formatValue(value, indent: indent, unit: unit)
            )
        }
        if case .object = member.value.kind {
            return try settingEdit(
                value,
                path: rest,
                in: member.value,
                source: source,
                stripped: stripped,
                isComment: isComment,
                unit: unit
            )
        }
        // The path continues but the existing value cannot hold it (a string
        // where an object is needed): replace it wholesale.
        let indent = lineIndent(of: member.keyStart, in: source)
        return Edit(
            start: member.value.start,
            end: member.value.end,
            text: try formatValue(nested(value, under: rest), indent: indent, unit: unit)
        )
    }

    private static func insertion(
        of value: Any,
        key: String,
        into object: ParsedValue,
        members: [ParsedMember],
        source: [Character],
        stripped: [Character],
        isComment: [Bool],
        unit: String
    ) throws -> Edit {
        let objectIndent = lineIndent(of: object.start, in: source)
        let closeIndex = object.end - 1
        let singleLine = !stripped[object.start..<object.end].contains { $0.isNewline }

        guard let last = members.last else {
            let childIndent = objectIndent + unit
            let entry = try entryText(key: key, value: value, indent: childIndent, unit: unit)
            let lineStart = lineStartIndex(of: closeIndex, in: source)
            if source[lineStart..<closeIndex].allSatisfy(isIndentCharacter) {
                // The `}` already owns its line, so the new entry gets the line above.
                return Edit(start: lineStart, end: lineStart, text: childIndent + entry + "\n")
            }
            return Edit(
                start: closeIndex,
                end: closeIndex,
                text: "\n" + childIndent + entry + "\n" + objectIndent
            )
        }

        var position = last.value.end
        var needsComma = true
        var scan = position
        while scan < stripped.count, isWhitespace(stripped[scan]) { scan += 1 }
        if scan < stripped.count, stripped[scan] == "," {
            // Any comma after the last member is a trailing comma; write after it.
            position = scan + 1
            needsComma = false
        }

        let childIndent = siblingIndent(of: last, in: source) ?? objectIndent + unit
        let entry = try entryText(key: key, value: value, indent: childIndent, unit: unit)
        if singleLine {
            return Edit(start: position, end: position, text: (needsComma ? ", " : " ") + entry)
        }

        // A trailing comment (blanked to spaces here) documents the entry it
        // follows, so the new entry goes below it while the separating comma
        // stays where JSON needs it — before the comment, not inside it.
        var tail = position
        let lineScan = skippingTrailingFiller(from: position, stripped: stripped, isComment: isComment)
        if lineScan < stripped.count, stripped[lineScan].isNewline {
            tail = lineScan
        }
        let preserved = String(source[position..<tail])
        return Edit(
            start: position,
            end: tail,
            text: (needsComma ? "," : "") + preserved + "\n" + childIndent + entry
        )
    }

    private static func removalEdit(
        path: ArraySlice<String>,
        in object: ParsedValue,
        source: [Character],
        stripped: [Character],
        isComment: [Bool]
    ) -> Edit? {
        guard let key = path.first,
              case let .object(members) = object.kind,
              let member = members.first(where: { $0.key == key })
        else { return nil }

        let rest = path.dropFirst()
        if !rest.isEmpty {
            return removalEdit(
                path: rest,
                in: member.value,
                source: source,
                stripped: stripped,
                isComment: isComment
            )
        }

        // Sole member and nothing else inside the braces: collapse to `{}`
        // rather than leaving a hollow, oddly indented shell.
        if members.count == 1 {
            let interior = ((object.start + 1)..<(object.end - 1)).filter {
                $0 < member.keyStart || $0 >= member.value.end
            }
            if interior.allSatisfy({ isWhitespace(source[$0]) }) {
                return Edit(start: object.start, end: object.end, text: "{}")
            }
        }

        var start = member.keyStart
        var end = member.value.end

        var forward = end
        while forward < stripped.count, isWhitespace(stripped[forward]) { forward += 1 }
        if forward < stripped.count, stripped[forward] == "," {
            end = forward + 1
        } else {
            var backward = start - 1
            while backward >= 0, isWhitespace(stripped[backward]) { backward -= 1 }
            if backward >= 0, stripped[backward] == "," {
                start = backward
            }
        }

        // When the entry had its line to itself, take the line with it —
        // including a trailing comment, which documented the entry being
        // removed. The prefix check reads the original text so a *leading*
        // comment on that line keeps the line alive.
        let lineStart = lineStartIndex(of: start, in: source)
        if source[lineStart..<start].allSatisfy(isIndentCharacter) {
            let trailing = skippingTrailingFiller(from: end, stripped: stripped, isComment: isComment)
            if trailing < source.count, source[trailing].isNewline {
                start = lineStart
                end = trailing + 1
            }
        }
        return Edit(start: start, end: end, text: "")
    }

    /// Builds the document for an empty (or comment-only) file, keeping
    /// whatever the user already typed above it.
    private static func newDocument(
        with value: Any,
        at path: [String],
        keeping source: [Character],
        unit: String
    ) throws -> String {
        let entry = try entryText(
            key: path[0],
            value: nested(value, under: path[1...]),
            indent: unit,
            unit: unit
        )
        let body = "{\n" + unit + entry + "\n}\n"

        var prefix = source
        while let last = prefix.last, isWhitespace(last) { prefix.removeLast() }
        return prefix.isEmpty ? body : String(prefix) + "\n" + body
    }

    /// Wraps `value` in the objects named by `keys`, innermost last.
    private static func nested(_ value: Any, under keys: ArraySlice<String>) -> Any {
        guard let key = keys.first else { return value }
        return [key: nested(value, under: keys.dropFirst())] as [String: Any]
    }

    // MARK: - Formatting

    private static func entryText(key: String, value: Any, indent: String, unit: String) throws -> String {
        let formatted = try formatValue(value, indent: indent, unit: unit)
        return "\(quoted(key)): \(formatted)"
    }

    /// Renders a JSONSerialization-compatible value, pretty-printed with sorted
    /// keys and every continuation line sitting at `indent`.
    private static func formatValue(_ value: Any, indent: String, unit: String) throws -> String {
        if value is NSNull { return "null" }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if let string = value as? String { return quoted(string) }

        if let dictionary = value as? [String: Any] {
            guard !dictionary.isEmpty else { return "{}" }
            let inner = indent + unit
            var entries: [String] = []
            for key in dictionary.keys.sorted() {
                let child = dictionary[key] ?? NSNull()
                entries.append(inner + (try entryText(key: key, value: child, indent: inner, unit: unit)))
            }
            return "{\n" + entries.joined(separator: ",\n") + "\n" + indent + "}"
        }

        if let array = value as? [Any] {
            guard !array.isEmpty else { return "[]" }
            let inner = indent + unit
            var entries: [String] = []
            for element in array {
                entries.append(inner + (try formatValue(element, indent: inner, unit: unit)))
            }
            return "[\n" + entries.joined(separator: ",\n") + "\n" + indent + "]"
        }

        if let integer = value as? Int { return String(integer) }
        if let double = value as? Double {
            guard double.isFinite else {
                throw ParseError(message: "Cannot write a non-finite number", line: 1, column: 1)
            }
            return double == double.rounded() && abs(double) < 1e15
                ? String(Int64(double))
                : String(double)
        }
        if let number = value as? NSNumber { return number.stringValue }

        throw ParseError(
            message: "Cannot write a value of type \(type(of: value))",
            line: 1,
            column: 1
        )
    }

    private static func quoted(_ string: String) -> String {
        var output = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        return output + "\""
    }

    // MARK: - Layout helpers

    /// The document's indent unit, guessed from the first indented line.
    /// Two spaces when the file has nothing to learn from.
    private static func indentUnit(in source: [Character]) -> String {
        var lineStart = 0
        var index = 0
        while index <= source.count {
            if index == source.count || source[index].isNewline {
                var scan = lineStart
                while scan < index, isIndentCharacter(source[scan]) { scan += 1 }
                if scan > lineStart, scan < index {
                    let prefix = String(source[lineStart..<scan])
                    return prefix.contains("\t") ? "\t" : prefix
                }
                lineStart = index + 1
            }
            index += 1
        }
        return "  "
    }

    private static func lineStartIndex(of index: Int, in source: [Character]) -> Int {
        var start = min(index, source.count)
        while start > 0, !source[start - 1].isNewline { start -= 1 }
        return start
    }

    private static func lineIndent(of index: Int, in source: [Character]) -> String {
        let start = lineStartIndex(of: index, in: source)
        var scan = start
        while scan < index, scan < source.count, isIndentCharacter(source[scan]) { scan += 1 }
        return String(source[start..<scan])
    }

    /// The indentation a sibling entry uses, or `nil` when the member shares its
    /// line with other content and therefore teaches us nothing.
    private static func siblingIndent(of member: ParsedMember, in source: [Character]) -> String? {
        let lineStart = lineStartIndex(of: member.keyStart, in: source)
        let prefix = source[lineStart..<member.keyStart]
        guard prefix.allSatisfy(isIndentCharacter) else { return nil }
        return String(prefix)
    }

    private static func isWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character.isNewline
    }

    private static func isIndentCharacter(_ character: Character) -> Bool {
        character == " " || character == "\t"
    }

    private static func parseError(_ message: String, at index: Int, in source: [Character]) -> ParseError {
        var line = 1
        var column = 1
        var position = 0
        let limit = min(index, source.count)
        while position < limit {
            if source[position].isNewline {
                line += 1
                column = 1
            } else {
                column += 1
            }
            position += 1
        }
        return ParseError(message: message, line: line, column: column)
    }
}
