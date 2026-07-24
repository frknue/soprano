import AppKit
import Foundation
import UserNotifications

enum AgentEventState: String {
    case ready
    case running
    case needsInput = "needs-input"
    case error
    case stopped

    var agentStatus: AgentStatus {
        switch self {
        case .ready: return .idle
        case .running: return .running
        case .needsInput: return .waiting
        case .error: return .error
        case .stopped: return .stopped
        }
    }
}

struct AgentEventPayload {
    let paneId: String
    let tabId: String
    let profileId: String?
    let state: AgentEventState
    let shouldNotify: Bool
    let title: String
    let body: String
}

/// A distributed notification prepared for delivery by a command bridge.
/// Keeping envelope construction separate from posting makes command routing
/// deterministic and safe to exercise without sending system notifications.
struct DistributedNotificationEnvelope {
    let name: Notification.Name
    let userInfo: [String: String]
}

/// Small command-line bridge used by agent lifecycle hooks. Invoking the
/// Soprano executable with `agent-event` posts to the already-running app and
/// exits before AppKit or libghostty are initialized.
enum AgentEventCommand {
    private static let notificationPrefix = "com.soprano.agent-event"

    static func notificationName(appProcessId: String) -> Notification.Name {
        Notification.Name("\(notificationPrefix).\(appProcessId)")
    }

    static func handle(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard arguments.count >= 2, arguments[1] == "agent-event" else { return false }
        guard let envelope = notificationEnvelope(arguments: arguments, environment: environment)
        else { return true }

        DistributedNotificationCenter.default().postNotificationName(
            envelope.name,
            object: nil,
            userInfo: envelope.userInfo,
            deliverImmediately: true
        )
        return true
    }

    static func notificationEnvelope(
        arguments: [String],
        environment: [String: String]
    ) -> DistributedNotificationEnvelope? {
        guard arguments.count >= 3,
              let state = AgentEventState(rawValue: arguments[2]),
              let appProcessId = environment["SOPRANO_APP_PID"], !appProcessId.isEmpty,
              let paneId = environment["SOPRANO_PANE_ID"], !paneId.isEmpty,
              let tabId = environment["SOPRANO_TAB_ID"], !tabId.isEmpty
        else { return nil }

        var shouldNotify = false
        var profileId = environment["SOPRANO_AGENT_PROFILE"]
        var title = environment["SOPRANO_AGENT_NAME"] ?? "Agent"
        var body = defaultBody(for: state)
        var index = 3

        while index < arguments.count {
            switch arguments[index] {
            case "--notify":
                shouldNotify = true
                index += 1
            case "--profile" where index + 1 < arguments.count:
                profileId = arguments[index + 1]
                index += 2
            case "--title" where index + 1 < arguments.count:
                title = arguments[index + 1]
                index += 2
            case "--body" where index + 1 < arguments.count:
                body = arguments[index + 1]
                index += 2
            default:
                // Codex appends its JSON notification payload as one final
                // argument. It is intentionally ignored here.
                index += 1
            }
        }

        var userInfo: [String: String] = [
            "paneId": paneId,
            "tabId": tabId,
            "state": state.rawValue,
            "notify": shouldNotify ? "1" : "0",
            "title": title,
            "body": body,
        ]
        if let profileId {
            userInfo["profileId"] = profileId
        }

        return DistributedNotificationEnvelope(
            name: notificationName(appProcessId: appProcessId),
            userInfo: userInfo
        )
    }

    private static func defaultBody(for state: AgentEventState) -> String {
        switch state {
        case .ready: return "Ready for a prompt"
        case .running: return "Working"
        case .needsInput: return "Input required"
        case .error: return "The agent stopped with an error"
        case .stopped: return "Stopped"
        }
    }
}

/// Converts agent lifecycle events and terminal OSC notifications into model
/// state, unread attention markers, and native macOS notifications.
final class AgentNotificationManager: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private struct Target: Hashable {
        let paneId: String
        let tabId: String
    }

    private struct EventFingerprint: Equatable {
        let state: AgentEventState
        let shouldNotify: Bool
        let title: String
        let body: String
    }

    private let agentManager: AgentManager
    private let notificationCenter: UNUserNotificationCenter?
    private var distributedObserver: NSObjectProtocol?
    private var desktopObserver: NSObjectProtocol?
    private var surfaceFocusObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var deliveredNotificationIds: [Target: Set<String>] = [:]
    private var recentEvents: [Target: (fingerprint: EventFingerprint, date: Date)] = [:]
    private let observerId = "AgentNotificationManager"

    init(agentManager: AgentManager) {
        self.agentManager = agentManager
        self.notificationCenter = Self.makeNotificationCenter()
        super.init()

        notificationCenter?.delegate = self
        let appProcessId = String(ProcessInfo.processInfo.processIdentifier)
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentEventCommand.notificationName(appProcessId: appProcessId),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleDistributedEvent(notification)
        }
        desktopObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDesktopNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleDesktopNotification(notification)
        }
        surfaceFocusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleSurfaceFocus(notification)
        }
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.clearDeliveredNotificationsForFocusedAgent()
        }
        agentManager.addObserver(id: observerId) { [weak self] in
            self?.clearDeliveredNotificationsForFocusedAgent()
        }
    }

    /// UserNotifications requires a Launch Services application bundle. SwiftPM
    /// executables launched with `swift run` or directly from `.build` do not
    /// have one, and calling `UNUserNotificationCenter.current()` in that state
    /// raises an Objective-C exception that Swift cannot catch.
    private static func makeNotificationCenter() -> UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil
        else { return nil }

        return UNUserNotificationCenter.current()
    }

    deinit {
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        if let desktopObserver {
            NotificationCenter.default.removeObserver(desktopObserver)
        }
        if let surfaceFocusObserver {
            NotificationCenter.default.removeObserver(surfaceFocusObserver)
        }
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
        agentManager.removeObserver(id: observerId)
    }

    private func handleDistributedEvent(_ notification: Notification) {
        guard let info = notification.userInfo,
              let paneId = info["paneId"] as? String,
              let tabId = info["tabId"] as? String,
              let rawState = info["state"] as? String,
              let state = AgentEventState(rawValue: rawState)
        else { return }

        handle(AgentEventPayload(
            paneId: paneId,
            tabId: tabId,
            profileId: info["profileId"] as? String,
            state: state,
            shouldNotify: info["notify"] as? String == "1",
            title: info["title"] as? String ?? "Agent",
            body: info["body"] as? String ?? "Ready for a prompt"
        ))
    }

    private func handleDesktopNotification(_ notification: Notification) {
        guard let info = notification.userInfo,
              let paneId = info["paneId"] as? String,
              let tabId = info["tabId"] as? String
        else { return }

        let title = info["title"] as? String ?? "Terminal"
        let body = info["body"] as? String ?? ""
        let combined = "\(title) \(body)".lowercased()
        let profileId = agentManager.agent(paneId: paneId, tabId: tabId)?.profileId
        let needsInput = profileId == "codex"
            || ["approval", "permission", "question", "input required"]
                .contains { combined.contains($0) }

        if profileId == nil {
            let isFocused = MainActor.assumeIsolated {
                isFocusedSurface(paneId: paneId, tabId: tabId)
            }
            guard !isFocused
            else { return }
            deliverNotification(title: title, body: body, paneId: paneId, tabId: tabId)
            return
        }

        handle(AgentEventPayload(
            paneId: paneId,
            tabId: tabId,
            profileId: profileId,
            state: needsInput ? .needsInput : .ready,
            shouldNotify: true,
            title: title.isEmpty ? agentName(for: profileId) : title,
            body: body.isEmpty ? (needsInput ? "Input required" : "Ready for a prompt") : body
        ))
    }

    private func handleSurfaceFocus(_ notification: Notification) {
        guard let info = notification.userInfo,
              let paneId = info["paneId"] as? String,
              let tabId = info["tabId"] as? String
        else { return }

        agentManager.clearAttention(paneId: paneId, tabId: tabId)
        let target = Target(paneId: paneId, tabId: tabId)
        guard let identifiers = deliveredNotificationIds.removeValue(forKey: target) else { return }
        notificationCenter?.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
    }

    private func handle(_ event: AgentEventPayload) {
        if let profileId = event.profileId {
            agentManager.attachAgentIfNeeded(
                paneId: event.paneId,
                tabId: event.tabId,
                profileId: profileId
            )
        }

        guard agentManager.agent(paneId: event.paneId, tabId: event.tabId) != nil else { return }
        let target = Target(paneId: event.paneId, tabId: event.tabId)
        let fingerprint = EventFingerprint(
            state: event.state,
            shouldNotify: event.shouldNotify,
            title: event.title,
            body: event.body
        )
        let now = Date()
        if let recent = recentEvents[target],
           recent.fingerprint == fingerprint,
           now.timeIntervalSince(recent.date) < 1
        {
            return
        }
        recentEvents[target] = (fingerprint, now)

        let isFocused = MainActor.assumeIsolated {
            isFocusedSurface(paneId: event.paneId, tabId: event.tabId)
        }
        let needsAttention = event.shouldNotify && !isFocused

        if event.state == .stopped {
            agentManager.agentProcessDidExit(
                target: TerminalTarget(paneId: event.paneId, tabId: event.tabId)
            )
            return
        }

        agentManager.updateAgentStatus(
            paneId: event.paneId,
            tabId: event.tabId,
            status: event.state.agentStatus,
            needsAttention: needsAttention
        )

        if needsAttention {
            deliverNotification(
                title: event.title,
                body: event.body,
                paneId: event.paneId,
                tabId: event.tabId
            )
        }
    }

    private func agentName(for profileId: String?) -> String {
        profileId.flatMap { DefaultAgents.profile(for: $0)?.name } ?? "Agent"
    }

    private func deliverNotification(title: String, body: String, paneId: String, tabId: String) {
        guard let notificationCenter else { return }

        notificationCenter.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.scheduleNotification(title: title, body: body, paneId: paneId, tabId: tabId)
            case .notDetermined:
                self.notificationCenter?.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    self.scheduleNotification(title: title, body: body, paneId: paneId, tabId: tabId)
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private func scheduleNotification(title: String, body: String, paneId: String, tabId: String) {
        guard let notificationCenter else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["paneId": paneId, "tabId": tabId]

        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        notificationCenter.add(request) { [weak self] error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                let target = Target(paneId: paneId, tabId: tabId)
                guard let self else { return }
                if self.isFocusedSurface(paneId: paneId, tabId: tabId) {
                    self.notificationCenter?.removeDeliveredNotifications(withIdentifiers: [identifier])
                } else {
                    self.deliveredNotificationIds[target, default: []].insert(identifier)
                }
            }
        }
    }

    private func clearDeliveredNotificationsForFocusedAgent() {
        guard let target = MainActor.assumeIsolated({ focusedSurfaceTarget() })
        else { return }

        agentManager.clearAttention(paneId: target.paneId, tabId: target.tabId)
        guard let identifiers = deliveredNotificationIds.removeValue(forKey: target) else { return }

        notificationCenter?.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
    }

    @MainActor
    private func isFocusedSurface(paneId: String, tabId: String) -> Bool {
        focusedSurfaceTarget() == Target(paneId: paneId, tabId: tabId)
    }

    @MainActor
    private func focusedSurfaceTarget() -> Target? {
        guard NSApp.isActive,
              var view = NSApp.keyWindow?.firstResponder as? NSView
        else { return nil }

        while true {
            if let terminalView = view as? TerminalSurfaceView {
                return Target(paneId: terminalView.paneId, tabId: terminalView.tabId)
            }
            guard let parent = view.superview else { return nil }
            view = parent
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let paneId = info["paneId"] as? String,
           let tabId = info["tabId"] as? String {
            DispatchQueue.main.async { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
                self?.agentManager.focusTab(paneId: paneId, tabId: tabId)
            }
        }
        completionHandler()
    }
}
