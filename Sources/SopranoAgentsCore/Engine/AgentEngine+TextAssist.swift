import Foundation

// The composer's typing aids: spelling preferences and ghost-text word completion, served by the
// provider's `TextAssistant` (`EngineEnvironment.textAssistants`) outside any conversation, so
// drafts have them too.

extension AgentEngine {
    /// The provider's settings for the typing aids. Without an assistant: spelling marks on,
    /// autocorrect and word completion off.
    public func textAssistPreferences(_ provider: ProviderKind) async -> TextAssistPreferences {
        guard let assistant = environment.textAssistants[provider] else { return TextAssistPreferences(wordCompletion: false) }
        return await assistant.preferences()
    }

    /// Ghost-text suffix completing the word that ends at `cursor` (UTF-16 offset into `text`), or
    /// nil. Cancelling the calling task abandons the request.
    public func predictWord(_ provider: ProviderKind, text: String, cursor: Int) async -> String? {
        await environment.textAssistants[provider]?.predictWord(text: text, cursor: cursor)
    }

    /// Reports that the user accepted or typed past `suggestion`, shown at `cursor` of `text`.
    public func reportWordCompletion(_ provider: ProviderKind, text: String, cursor: Int, suggestion: String, accepted: Bool) {
        guard let assistant = environment.textAssistants[provider] else { return }
        Task { await assistant.wordFeedback(text: text, cursor: cursor, suggestion: suggestion, accepted: accepted) }
    }
}
