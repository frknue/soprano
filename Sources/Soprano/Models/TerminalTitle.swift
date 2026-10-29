import Foundation

/// What the sidebar calls a terminal or agent tab, where a row has room for
/// a word or two.
///
/// A shell's own title is its prompt location — zsh's `user@host:~/git/shop`
/// or oh-my-zsh's `…/git/shop` — which only says where it is, so it reads as
/// that folder; a command's title (`npm run dev`, `vim index.ts`) stays. An
/// agent's title loses the brand and state glyphs its CLI puts in front
/// (omp's `π > `, Claude Code's `✳ `), which the row's status mark already
/// shows, and falls back to the agent's name. Nerd-font icons go too: they
/// live in the Private Use Areas, which the system fonts cannot draw.
enum TerminalTitle {
    static func display(
        _ title: String,
        workingDirectory: String?,
        agentName: String?,
        home: String = NSHomeDirectory()
    ) -> String {
        let label = withoutDecorations(title)
        let folder = workingDirectory.map { folderName($0, home: home) }
        guard isGeneric(label, agentName: agentName) else {
            return label
        }
        if let agentName {
            return agentName
        }
        if let folder {
            return folder
        }
        if let location = shellLocation(in: label), !location.isEmpty {
            return folderName(location, home: "~")
        }
        return label.isEmpty ? "Terminal" : label
    }

    /// `soprano` for `~/git/private/soprano`, `~` for the home folder itself.
    static func folderName(_ path: String, home: String = NSHomeDirectory()) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if trimmed == home || trimmed == "~" {
            return "~"
        }
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? trimmed : name
    }

    /// The title without private-use icons and without the leading brand and
    /// state glyphs agent CLIs add.
    static func withoutDecorations(_ title: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: title.unicodeScalars.filter { !isPrivateUse($0) })
        var text = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        text = withoutOmpBrand(text)
        // Claude Code spins through `·✢✳✶✻✽` in front of its task; other
        // CLIs use braille spinners or an emoji. A glyph's trailing variation
        // selector or joiner goes with it.
        while let first = text.unicodeScalars.first, isLeadingDecoration(first) {
            text = String(String.UnicodeScalarView(text.unicodeScalars.dropFirst()))
                .trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    /// omp titles its terminal `π > label` (your turn), `π ⠋ label` (working,
    /// one spinner column), `π ! label` (blocked on you), or `π: label`.
    private static func withoutOmpBrand(_ text: String) -> String {
        guard text.hasPrefix("π") else { return text }
        var rest = text.dropFirst()
        if rest.first == ":" {
            rest = rest.dropFirst()
        } else if rest.first?.isWhitespace == true {
            rest = rest.drop(while: \.isWhitespace)
            if let separator = rest.first,
               !separator.isLetter, !separator.isNumber,
               rest.dropFirst().first?.isWhitespace ?? true {
                rest = rest.dropFirst()
            }
        } else if !rest.isEmpty {
            // A word that starts with π, not omp's brand.
            return text
        }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the title says nothing the row does not already: empty, the
    /// shell's location, the agent's bare name, or Soprano's own
    /// `Agent: folder` placeholder from before the agent titled itself — the
    /// folder it started in, which need not be the one it is in now.
    private static func isGeneric(_ label: String, agentName: String?) -> Bool {
        if label.isEmpty || label == "Terminal" || shellLocation(in: label) != nil {
            return true
        }
        guard let agentName else { return false }
        if label.caseInsensitiveCompare(agentName) == .orderedSame {
            return true
        }
        let prefix = "\(agentName): "
        guard label.hasPrefix(prefix) else { return false }
        let folder = label.dropFirst(prefix.count)
        return !folder.isEmpty && !folder.contains(where: \.isWhitespace)
    }

    /// The path a prompt title shows — `~/git/shop` from
    /// `user@host:~/git/shop`, `…/git/shop` as is, empty for a bare
    /// `user@host` — or nil when the title is not a location.
    static func shellLocation(in label: String) -> String? {
        if let match = label.wholeMatch(of: /[A-Za-z0-9._-]+@[A-Za-z0-9._-]+(?::\s*(.*))?/) {
            return match.1.map(String.init) ?? ""
        }
        for prefix in ["~", "/", "…", ".."] where label.hasPrefix(prefix) {
            return label
        }
        return nil
    }

    private static func isPrivateUse(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0xE000...0xF8FF, 0xF0000...0x10FFFF: true
        default: false
        }
    }

    private static func isLeadingDecoration(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .otherSymbol, .nonspacingMark, .enclosingMark, .format:
            return true
        default:
            // Claude Code's dimmest spinner frame.
            return scalar == "\u{00B7}"
        }
    }
}
