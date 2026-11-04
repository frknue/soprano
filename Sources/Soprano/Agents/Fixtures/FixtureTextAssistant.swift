import Foundation
import SopranoAgentsCore

/// Typing aids for the snapshot harness: omp's default preferences, and word completion from a
/// fixed vocabulary (the first word the typed letters start, matched case-insensitively), so
/// `--type "fix the redi"` shows the ghost "rect".
final class FixtureTextAssistant: TextAssistant {
    static let vocabulary = ["redirect", "refactor", "repository", "regression", "test", "tests", "login", "branch", "worktree", "please"]

    func preferences() async -> TextAssistPreferences {
        TextAssistPreferences()
    }

    func predictWord(text: String, cursor: Int) async -> String? {
        let before = (text as NSString).substring(to: cursor)
        let prefix = String(before.reversed().prefix { $0.isLetter }.reversed())
        guard !prefix.isEmpty else { return nil }
        let word = Self.vocabulary.first { $0.count > prefix.count && $0.hasPrefix(prefix.lowercased()) }
        return word.map { String($0.dropFirst(prefix.count)) }
    }

    func wordFeedback(text: String, cursor: Int, suggestion: String, accepted: Bool) async {}

    func close() async {}
}
