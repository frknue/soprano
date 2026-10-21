extension AgentStatus {
    /// The Folio status mark and label this agent state is drawn with, in the
    /// pane header, the sidebar, tab badges and the Agent Dashboard alike.
    var chromeStatus: ChromeStatus {
        switch self {
        case .idle: .ready
        case .starting: .starting
        case .running: .working
        case .waiting: .needsInput
        case .error: .error
        case .stopped: .stopped
        }
    }
}
