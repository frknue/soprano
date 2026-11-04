import Foundation

/// The composer's typing aids as the provider's own settings configure them (omp: `spelling.*`),
/// so the app behaves like the provider's terminal UI.
public struct TextAssistPreferences: Sendable, Hashable {
    /// Mark misspelled words and grammar problems with the macOS dictionaries.
    public var typoDetection: Bool
    /// Apply confident spelling corrections while typing.
    public var autocorrect: Bool
    /// Show ghost-text completions of the word being typed.
    public var wordCompletion: Bool

    /// omp's defaults.
    public init(typoDetection: Bool = true, autocorrect: Bool = false, wordCompletion: Bool = true) {
        self.typoDetection = typoDetection
        self.autocorrect = autocorrect
        self.wordCompletion = wordCompletion
    }
}

/// Typing aids for the composer, shared by every composer of the app and long-lived.
public protocol TextAssistant: AnyObject, Sendable {
    /// The provider's current settings for the typing aids (read fresh; defaults when unreadable).
    func preferences() async -> TextAssistPreferences

    /// Ghost-text suffix completing the word that ends at `cursor` (a UTF-16 offset into `text`).
    /// nil when nothing applies, word completion is off, or the provider can't answer.
    func predictWord(text: String, cursor: Int) async -> String?

    /// The user accepted (Tab/→) or typed past `suggestion`, shown at `cursor` of `text`, so the
    /// provider's engine learns from it. Never starts the provider just to report.
    func wordFeedback(text: String, cursor: Int, suggestion: String, accepted: Bool) async

    /// Stops whatever the assistant started. Safe to call twice.
    func close() async
}
