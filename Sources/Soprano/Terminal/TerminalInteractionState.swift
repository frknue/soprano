import Foundation

/// The dashboard-facing state of one exact terminal surface.
struct TerminalInteractionState: Equatable {
    let isAvailable: Bool
    let visibleText: String

    static let unavailable = TerminalInteractionState(
        isAvailable: false,
        visibleText: ""
    )
}
