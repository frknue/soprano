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
    /// so its first turn is the run. Every CLI reports a finished turn as
    /// needs-input (omp and OpenCode say so, Claude Code's Stop and Codex's
    /// turn notification read as one), and some say they are working only
    /// when hooks are installed, so it counts without having seen the work.
    /// READY never completes a run: CLIs report it when they come up, and
    /// Claude Code again after compacting its context in the middle of work.
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
        case .starting, .idle, .stopped:
            return nil
        case .running:
            return run.status == .running ? nil : .running
        case .waiting:
            if (observation.waitingReason ?? .turnEnded).blocks {
                return run.status == .needsInput ? nil : .needsInput(message: observation.message)
            }
            return .completed
        case .error:
            return .failed(message: observation.message ?? "The agent stopped with an error.")
        }
    }
}
