import Foundation
import SopranoAgentsCore

extension Subagent {
    /// The subagent as the timeline shows it: its runs as the turns of a thread (not editable).
    /// One that has not reported a run yet shows its assignment, working while it runs.
    func timelineThread(in parent: AgentThread) -> AgentThread {
        var turns = turns
        if turns.isEmpty {
            turns = [Turn(
                id: "\(id):assignment",
                ordinal: 1,
                userMessage: UserMessage(id: "\(id):assignment", text: assignment ?? description ?? "", createdAt: startedAt),
                modelSelection: parent.modelSelection,
                status: isRunning ? .running : .completed,
                startedAt: startedAt,
                completedAt: completedAt
            )]
        }
        return AgentThread(
            id: "\(parent.id)/subagent/\(id)",
            projectID: parent.projectID,
            title: name,
            createdAt: startedAt,
            updatedAt: updatedAt,
            modelSelection: parent.modelSelection,
            runtimeMode: parent.runtimeMode,
            turns: turns
        )
    }
}
