import Foundation

/// The code a write or edit call carries in its arguments, as unified hunks (`FileChange.diff`),
/// so the timeline shows it while the model still streams the call and before omp reports the
/// applied diff.
///
/// - `write {path, content}` → every line added, numbered from 1. Internal URLs (`xd://`,
///   `agent://`, `local://`, …) carry no code: none.
/// - `edit {input}` → per `[path#TAG]` section (hashline; ops start hunks, `+` rows are added
///   lines), `*** Update|Add|Delete File:` section (apply_patch; `@@` starts a hunk, `+`/`-`/` `
///   lines) or `*** Edit File:` section (sloppy; `*** Find` lines removed, `*** Replace` and
///   `*** Insert …` lines added). `*** Begin Patch` / `*** End Patch` wrappers are skipped.
/// - `edit {path, old_string, new_string}` (replace) → old lines removed, new lines added.
/// - `edit {path, edits:[{op?, rename?, diff?}]}` (patch) → the entries' diff lines.
///
/// Positions the arguments do not state (everything but a write) give hunks starting at line 0;
/// the timeline shows those without line numbers.
public enum OmpEditPreview {
    public static func changes(tool: String, args: JSONValue, relative: (String) -> String = { $0 }) -> [FileChange] {
        switch tool {
        case "write":
            guard let path = args["path"]?.nonEmptyString, !path.contains("://"),
                  let content = args["content"]?.stringValue else { return [] }
            var hunk = Hunk(numbered: true)
            for line in lines(content) { hunk.add(.added, line) }
            return [FileChange(path: relative(path), kind: .update, diff: render([hunk]), isFullContent: true)]
        case "edit", "apply_patch":
            if let input = args["input"]?.stringValue {
                return sections(input).map { section in
                    FileChange(path: relative(section.path), kind: section.kind, movePath: section.movePath.map(relative), diff: render(section.hunks))
                }
            }
            guard let path = args["path"]?.nonEmptyString else { return [] }
            if let edits = args["edits"]?.arrayValue {
                var kind = FileChange.Kind.update
                var movePath: String?
                var hunks: [Hunk] = []
                for edit in edits {
                    switch edit["op"]?.stringValue {
                    case "create": kind = .add
                    case "delete": kind = .delete
                    default: break
                    }
                    if let rename = edit["rename"]?.nonEmptyString {
                        movePath = relative(rename)
                        kind = .move
                    }
                    var section = Section(path: path)
                    for line in lines(edit["diff"]?.stringValue ?? "") { section.patchLine(line) }
                    hunks += section.hunks
                }
                return [FileChange(path: relative(path), kind: kind, movePath: movePath, diff: render(hunks))]
            }
            let old = args["old_string"]?.stringValue
            let new = args["new_string"]?.stringValue
            guard old != nil || new != nil else { return [] }
            var hunk = Hunk()
            for line in lines(old ?? "") { hunk.add(.removed, line) }
            for line in lines(new ?? "") { hunk.add(.added, line) }
            return [FileChange(path: relative(path), kind: .update, diff: render([hunk]))]
        default:
            return []
        }
    }

    // MARK: - Hunks

    private enum LineKind {
        case added
        case removed
        case context

        var marker: Character {
            switch self {
            case .added: "+"
            case .removed: "-"
            case .context: " "
            }
        }
    }

    private struct Hunk {
        /// Lines are numbered from 1 (a whole new file); else the position is unknown (0).
        var numbered = false
        var section = ""
        var lines: [(LineKind, String)] = []

        mutating func add(_ kind: LineKind, _ text: String) {
            lines.append((kind, text))
        }

        var header: String {
            let old = lines.count { $0.0 != .added }
            let new = lines.count { $0.0 != .removed }
            let range = numbered ? "-0,0 +1,\(new)" : "-0,\(old) +0,\(new)"
            return section.isEmpty ? "@@ \(range) @@" : "@@ \(range) @@ \(section)"
        }
    }

    private static func render(_ hunks: [Hunk]) -> String? {
        let shown = hunks.filter { !$0.lines.isEmpty || !$0.section.isEmpty }
        guard !shown.isEmpty else { return nil }
        return shown.map { hunk in
            ([hunk.header] + hunk.lines.map { String($0.0.marker) + $0.1 }).joined(separator: "\n")
        }.joined(separator: "\n")
    }

    /// Lines of a text (`\n` or `\r\n`, which Swift reads as one character); a final line break
    /// ends the last line rather than starting an empty one.
    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.map(String.init)
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    // MARK: - Sections

    private struct Section {
        enum Mode {
            case hashline
            case patch
            case find
            case insert
        }

        var path: String
        var kind = FileChange.Kind.update
        var movePath: String?
        var mode = Mode.patch
        var hunks: [Hunk] = []

        mutating func startHunk(_ section: String) {
            hunks.append(Hunk(section: section))
        }

        mutating func add(_ kind: LineKind, _ text: String) {
            if hunks.isEmpty { hunks.append(Hunk()) }
            hunks[hunks.count - 1].add(kind, text)
        }

        /// One body line of an apply_patch / patch section.
        mutating func patchLine(_ line: String) {
            if line.hasPrefix("@@") {
                // "@@ -1,3 +1,4 @@ func f()" or apply_patch's "@@ class Foo": the text after the markers.
                var rest = line.dropFirst(2)
                if let close = rest.range(of: "@@") { rest = rest[close.upperBound...] }
                startHunk(rest.trimmingCharacters(in: .whitespaces))
                return
            }
            guard let marker = line.first else { return }
            let text = String(line.dropFirst())
            switch marker {
            case "+": add(.added, text)
            case "-": add(.removed, text)
            case " ": add(.context, text)
            default: break
            }
        }
    }

    private static func sections(_ input: String) -> [Section] {
        let hashlineOp = #/^(PUT|CUT|REM|MV)\b/#
        /// "[src/app.ts#1A2B]".
        let hashlineHeader = #/^\[(.+)#[0-9A-Fa-f]{4}\]$/#
        var sections: [Section] = []
        func open(_ path: String, mode: Section.Mode, kind: FileChange.Kind = .update) {
            var section = Section(path: path)
            section.mode = mode
            section.kind = kind
            sections.append(section)
        }
        for line in lines(input) {
            if line.hasPrefix("*** ") {
                let directive = line.dropFirst(4)
                if let path = value(directive, "Update File:") {
                    open(path, mode: .patch)
                } else if let path = value(directive, "Add File:") {
                    open(path, mode: .patch, kind: .add)
                } else if let path = value(directive, "Delete File:") {
                    open(path, mode: .patch, kind: .delete)
                } else if let path = value(directive, "Move to:"), !sections.isEmpty {
                    sections[sections.count - 1].movePath = path
                    sections[sections.count - 1].kind = .move
                } else if var path = value(directive, "Edit File:") {
                    if path.hasSuffix(" all") { path = String(path.dropLast(4)) }
                    if path.isEmpty, let current = sections.last?.path {
                        path = current
                    }
                    open(path, mode: .find)
                } else if !sections.isEmpty {
                    let last = sections.count - 1
                    if directive.hasPrefix("Find") {
                        sections[last].mode = .find
                        sections[last].startHunk("")
                    } else if directive.hasPrefix("Replace") || directive.hasPrefix("Insert") {
                        sections[last].mode = .insert
                    }
                }
                continue
            }
            if let header = line.wholeMatch(of: hashlineHeader) {
                open(String(header.1), mode: .hashline)
                continue
            }
            guard !sections.isEmpty else { continue }
            let last = sections.count - 1
            switch sections[last].mode {
            case .hashline:
                if line.allSatisfy(\.isWhitespace) { continue }
                if line.prefixMatch(of: hashlineOp) != nil {
                    sections[last].startHunk(line.trimmingCharacters(in: .whitespaces))
                } else if line.hasPrefix("+") {
                    sections[last].add(.added, String(line.dropFirst()))
                }
            case .patch:
                sections[last].patchLine(line)
            case .find:
                sections[last].add(.removed, line)
            case .insert:
                sections[last].add(.added, line)
            }
        }
        return sections.filter { !$0.path.isEmpty }
    }

    private static func value(_ directive: Substring, _ name: String) -> String? {
        guard directive.hasPrefix(name) else { return nil }
        return directive.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Partial JSON

    /// A streamed tool-call argument object cut anywhere, closed so it parses: an open string
    /// ends (a dangling escape dropped), a key without a value gets `null`, a trailing comma goes,
    /// open objects and arrays close. nil when even that does not parse (a cut number or literal).
    public static func partialObject(_ text: String) -> JSONValue? {
        enum State {
            case key
            case colon
            case value
            case afterValue
        }
        // One frame per open container: arrays carry nil.
        var frames: [State?] = []
        var inString = false
        var stringIsKey = false
        var escaped = false
        var lastEscape: String.Index?

        func valueStarted() {
            if let top = frames.last, top == .value { frames[frames.count - 1] = .afterValue }
        }

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                    lastEscape = index
                } else if character == "\"" {
                    inString = false
                    if stringIsKey { frames[frames.count - 1] = .colon }
                }
                continue
            }
            switch character {
            case "\"":
                inString = true
                stringIsKey = frames.last == .some(.key)
                if !stringIsKey { valueStarted() }
            case "{":
                valueStarted()
                frames.append(.key)
            case "[":
                valueStarted()
                frames.append(nil)
            case "}", "]":
                if !frames.isEmpty { frames.removeLast() }
            case ":":
                if frames.last == .some(.colon) { frames[frames.count - 1] = .value }
            case ",":
                if frames.last != .some(nil), !frames.isEmpty { frames[frames.count - 1] = .key }
            case " ", "\n", "\r", "\t":
                break
            default:
                valueStarted()
            }
        }
        guard !frames.isEmpty || inString else {
            return try? JSONValue.parse(text)
        }
        var closed = text
        if inString {
            if escaped {
                closed.removeLast()
            } else if let lastEscape, text[lastEscape...].count < 6,
                      text[text.index(after: lastEscape)...].first == "u" {
                // A cut \uXXXX escape.
                closed = String(text[..<lastEscape])
            }
            closed += "\""
            if stringIsKey { closed += ":null" }
        } else {
            while let last = closed.last, last.isWhitespace { closed.removeLast() }
            switch frames.last {
            case .some(.colon): closed += ":null"
            case .some(.value): closed += "null"
            default: if closed.hasSuffix(",") { closed.removeLast() }
            }
        }
        for frame in frames.reversed() {
            closed += frame == nil ? "]" : "}"
        }
        return try? JSONValue.parse(closed)
    }
}
