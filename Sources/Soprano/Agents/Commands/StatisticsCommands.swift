import AppKit
import SopranoAgentsCore

/// The statistics board (Statistics module).
@MainActor
enum StatisticsCommands {
    static var all: [AppCommand] {
        [
            AppCommand(
                id: "statistics.toggle",
                title: "Statistics",
                description: "Show tokens and estimated cost by model, project and day",
                category: .view,
                defaultKeys: ["cmd+shift+u"],
                icon: Icon.statistics
            ) { context in
                guard let state = context.state else { return }
                state.setStatisticsVisible(!state.isStatisticsVisible)
            },
        ]
    }
}
