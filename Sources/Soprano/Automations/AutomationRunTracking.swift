import Foundation

/// How a run follows its agent: what the agent reports moves the run along.
/// Kept as plain values so the rules read, and test, without a terminal.
enum AutomationRunTracking {
    /// The run's tab as the agent manager has it.
    struct Observation: Equatable {
        /// False once the tab is gone: someone closed it.
        var tabExists: Bool
        /// False once the agent exited and its tab fell back to a shell.
        var hasAgent: Bool
        var status: AgentStatus?
        var waitingReason: AgentWaitingReason?
        var message: String?
    }

    enum Change: Equatable {
        case running
        case needsInput(message: String?)
        case completed
        case failed(message: String)
    }

    /// What `observation` means for `run`, or nil when nothing changed.
    ///
    /// A finished turn completes the run: the agent got its prompt at launch,
    /// so its first turn is the run. Some CLIs say they are working only when
    /// hooks are installed, so a finished turn counts without having seen the
    /// work; a bare READY counts only after the agent was seen working, since
    /// every CLI also reports READY when it first comes up.
    static func change(for run: AutomationRun, observing observation: Observation) -> Change? {
        guard !run.status.isFinal else { return nil }
        guard observation.tabExists else {
            return .failed(message: "Its window was closed before the run finished.")
        }
        guard observation.hasAgent, let status = observation.status, status != .stopped else {
            return .failed(message: run.sawWork
                ? "The agent exited before it finished its turn."
                : "The agent exited before it started working.")
        }
        switch status {
        case .starting:
            return nil
        case .running:
            return run.status == .running ? nil : .running
        case .waiting:
            if (observation.waitingReason ?? .turnEnded).blocks {
                return run.status == .needsInput ? nil : .needsInput(message: observation.message)
            }
            return .completed
        case .idle:
            return run.sawWork ? .completed : nil
        case .error:
            return .failed(message: observation.message ?? "The agent stopped with an error.")
        case .stopped:
            return nil
        }
    }
}
