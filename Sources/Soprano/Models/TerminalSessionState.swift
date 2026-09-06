import Foundation

/// A live group of windows. Switching groups leaves their terminals running.
struct TerminalSessionState: Identifiable, Codable {
    static let defaultID = "session-1"

    let id: String
    var name: String
    var activeWindowId: String
    var lastActiveWindowId: String? = nil
}
