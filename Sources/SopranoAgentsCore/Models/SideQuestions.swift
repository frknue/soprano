import Foundation

public enum SideQuestionStatus: String, Sendable, Hashable {
    case running
    case complete
    case cancelled
    case failed
    /// The provider's process ended while it ran.
    case interrupted
}

/// One question of a side question and its answer.
public struct SideQuestionExchange: Sendable, Hashable {
    public var question: String
    /// Streamed text; partial while `.running`.
    public var answer: String
    public var status: SideQuestionStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var error: String?

    public init(question: String, answer: String = "", status: SideQuestionStatus, createdAt: Date, updatedAt: Date? = nil, error: String? = nil) {
        self.question = question
        self.answer = answer
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.error = error
    }
}

/// A question asked beside a thread's conversation (omp's `/btw`): the model answers from the
/// conversation's context, with no tools, and neither the question nor the answer joins the
/// conversation. A topic can take follow-ups, which see its earlier exchanges. The provider keeps
/// the history (omp: the session's BTW sidecar); the engine holds what it reported this run.
public struct SideQuestion: Sendable, Hashable, Identifiable {
    /// The provider's topic id.
    public var id: String
    /// The question that opened the topic.
    public var first: SideQuestionExchange
    /// Follow-ups, oldest first.
    public var followUps: [SideQuestionExchange]

    public init(id: String, first: SideQuestionExchange, followUps: [SideQuestionExchange] = []) {
        self.id = id
        self.first = first
        self.followUps = followUps
    }

    /// Every exchange, oldest first.
    public var exchanges: [SideQuestionExchange] { [first] + followUps }

    /// The last follow-up, else the first question.
    public var latest: SideQuestionExchange {
        get { followUps.last ?? first }
        set {
            if followUps.isEmpty { first = newValue } else { followUps[followUps.count - 1] = newValue }
        }
    }

    public var isRunning: Bool { latest.status == .running }
}
