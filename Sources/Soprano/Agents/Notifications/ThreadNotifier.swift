import AppKit
import SopranoAgentsCore
import UserNotifications

/// Why a thread wants the user.
enum ThreadAlert: String, Equatable, Sendable {
    case completed
    case failed
    case approval
    case input

    var title: String {
        switch self {
        case .completed: "Thread completed"
        case .failed: "Thread failed"
        case .approval: "Approval needed"
        case .input: "Input needed"
        }
    }

    /// The alert a status pill stands for; nil for Working and idle threads.
    init?(_ status: ThreadStatus) {
        switch status {
        case .done: self = .completed
        case .failed: self = .failed
        case .approval: self = .approval
        case .input: self = .input
        case .working, .idle: return nil
        }
    }
}

/// Delivers OS notifications. The live one wraps `UNUserNotificationCenter`; tests record.
@MainActor
protocol ThreadNotificationPosting: AnyObject {
    func post(threadID: String, alert: ThreadAlert, body: String, sound: Bool)
}

/// Posts thread notifications and keeps the Dock badge:
///
/// - When a thread's status turns into Done, Failed, Approval or Input while the app is not
///   active, it posts "Thread completed" / "Thread failed" / "Approval needed" / "Input needed"
///   with the thread title as body (one notification per thread, replacing the last), with
///   sound per `notifications.sound`, unless `notifications.enabled` is off. Threads seen for
///   the first time (launch) and archived threads never notify.
/// - The Dock badge counts non-archived threads showing Done, Failed, Approval or Input, except
///   Done and Failed on the Settled shelf: the user filed those away, and the collapsed shelf
///   hides their pills. A settled thread waiting on Approval or Input still counts, and so does a
///   settled thread that is also pinned (it shows in Pinned).
/// - Clicking a notification calls `onOpen` with the thread id.
@MainActor
final class ThreadNotifier {
    private let engine: AgentEngine
    private let settings: () -> AgentsSettings
    private let isAppActive: () -> Bool
    private let poster: ThreadNotificationPosting?
    private let setBadge: @MainActor (Int) -> Void
    private var alerts: [String: ThreadAlert?] = [:]
    private(set) var badgeCount = 0

    init(
        engine: AgentEngine,
        settings: @escaping () -> AgentsSettings = { SettingsCenter.shared.settings },
        isAppActive: @escaping () -> Bool = { NSApp.isActive },
        poster: ThreadNotificationPosting?,
        setBadge: @escaping @MainActor (Int) -> Void = ThreadNotifier.setDockBadge
    ) {
        self.engine = engine
        self.settings = settings
        self.isAppActive = isAppActive
        self.poster = poster
        self.setBadge = setBadge
        for thread in engine.threads where thread.archivedAt == nil {
            // updateValue keeps threads without an alert as known (`nil` value, not a missing key).
            alerts.updateValue(ThreadAlert(ThreadStatus.of(thread)), forKey: thread.id)
        }
        updateBadge()
        engine.addObserver(self) { [weak self] event in
            switch event {
            case .threadListChanged, .threadChanged: self?.engineChanged()
            default: break
            }
        }
    }

    /// Compares every thread's alert with the last one seen and notifies on changes.
    func engineChanged() {
        var current: [String: ThreadAlert?] = [:]
        let preferences = settings()
        let active = isAppActive()
        for thread in engine.threads where thread.archivedAt == nil {
            let alert = ThreadAlert(ThreadStatus.of(thread))
            current.updateValue(alert, forKey: thread.id)
            guard let alert, let previous = alerts[thread.id], previous != alert else { continue }
            if !active, preferences.notificationsEnabled {
                poster?.post(threadID: thread.id, alert: alert, body: thread.title, sound: preferences.notificationSound)
            }
        }
        alerts = current
        updateBadge()
    }

    private func updateBadge() {
        let count = engine.threads.reduce(0) { count, thread in
            guard let alert = alerts[thread.id] ?? nil else { return count }
            let filedAway = InboxSection.of(thread) == .settled && (alert == .completed || alert == .failed)
            return filedAway ? count : count + 1
        }
        guard count != badgeCount else { return }
        badgeCount = count
        setBadge(count)
    }

    static func setDockBadge(_ count: Int) {
        NSApp?.dockTile.badgeLabel = count == 0 ? nil : String(count)
    }
}

/// `UNUserNotificationCenter` delivery. Authorization is requested on the first notification.
/// Unbundled runs (`swift run`, the snapshot harness) have no notification center; `make`
/// returns nil there so nothing touches it. Clicks arrive at Soprano's single notification
/// delegate (`AgentNotificationManager`), which hands `threadIDKey` notifications to
/// `AgentsAppController.openThread`.
@MainActor
final class UserNotificationPoster: ThreadNotificationPosting {
    nonisolated static let threadIDKey = "threadID"

    private let center: UNUserNotificationCenter
    private var authorization: Task<Bool, Never>?

    private init(center: UNUserNotificationCenter) {
        self.center = center
    }

    /// The live poster, or nil when the process is not a bundled app.
    static func make() -> UserNotificationPoster? {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UserNotificationPoster(center: .current())
    }

    func post(threadID: String, alert: ThreadAlert, body: String, sound: Bool) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = body
        content.threadIdentifier = threadID
        content.userInfo = [Self.threadIDKey: threadID]
        if sound { content.sound = .default }
        let request = UNNotificationRequest(identifier: "thread-\(threadID)", content: content, trigger: nil)
        let center = center
        let authorized = authorizationTask()
        Task {
            guard await authorized.value else { return }
            try? await center.add(request)
        }
    }

    private func authorizationTask() -> Task<Bool, Never> {
        if let authorization { return authorization }
        let center = center
        let task = Task<Bool, Never> {
            (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
        authorization = task
        return task
    }
}
