import AppKit

extension Notification.Name {
    /// Posted with the run's id under `runId` when a banner for an
    /// automation run is clicked.
    static let sopranoOpenAutomationRun = Notification.Name("com.soprano.open-automation-run")
}

/// Runs the automations `settings.json` declares while Soprano is open: it
/// checks every half minute (and when the Mac wakes) which are due, prepares
/// each run (precheck, worktree), opens its agent in the Automations session
/// without switching to it, follows the agent to the end of its turn, keeps
/// what it said, and closes the run's window if nobody opened it.
@MainActor
final class AutomationController {
    /// What runs need from the window that hosts the terminals, and from
    /// the system. Injectable so tests drive runs without a display.
    struct Environment {
        var startTerminal: (TerminalTarget) -> Bool
        var submitPrompt: (String, TerminalTarget) -> Bool
        var visibleText: (TerminalTarget) -> String?
        var notify: (_ title: String, _ body: String, _ runId: String) -> Void
        var displayIsAwake: () -> Bool = AutomationController.anyDisplayIsActive
        var now: () -> Date = Date.init
        var calendar: Calendar = .current
        var worktreeDirectory: URL = AutomationWorktree.defaultDirectory()
        var claudeConfig: URL? = ClaudeWorkspaceTrust.configURL()
        var home: URL = FileManager.default.homeDirectoryForCurrentUser
        /// The login shell prechecks run in.
        var shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Seconds a run's agent may take to say anything at all before the run
    /// counts as failed: long enough for a slow CLI to come up, short enough
    /// that a dialog nobody answers does not hold the automation for hours.
    static let startTimeout: TimeInterval = 180
    static let waitingForDisplayMessage = "Waiting for a display to wake."

    let store: AutomationStore
    private let agentManager: AgentManager
    private let configStore: ConfigStore
    private var environment: Environment
    private let workQueue = DispatchQueue(label: "com.soprano.automations", qos: .utility)
    nonisolated(unsafe) private var timer: Timer?
    nonisolated(unsafe) private var displayRetryTimer: Timer?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?
    /// Runs whose terminal could not start because every display slept.
    private var waitingForDisplay: Set<String> = []
    private var observers: [String: () -> Void] = [:]
    private static let observerId = "AutomationController"

    init(
        store: AutomationStore,
        agentManager: AgentManager,
        configStore: ConfigStore = .shared,
        environment: Environment
    ) {
        self.store = store
        self.agentManager = agentManager
        self.configStore = configStore
        self.environment = environment

        // Their agents went with the Soprano that quit; a restored window
        // resumes the conversation as an ordinary agent.
        for run in store.openRuns {
            store.update(run.id) {
                $0.status = .failed
                $0.finishedAt = $0.finishedAt ?? environment.now()
                $0.message = "Soprano quit before the run finished."
                $0.paneId = nil
                $0.tabId = nil
            }
        }

        store.addObserver(id: Self.observerId) { [weak self] in
            self?.notifyObservers()
        }
        agentManager.addObserver(id: Self.observerId) { [weak self] change in
            guard change == .model else { return }
            self?.followRuns()
        }
        configStore.addObserver(id: Self.observerId) { [weak self] in
            self?.tick()
            self?.notifyObservers()
        }
    }

    deinit {
        timer?.invalidate()
        displayRetryTimer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Starts checking schedules.
    func start(checkingEvery interval: TimeInterval = 30) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        self.timer = timer
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
        tick()
    }

    nonisolated static func anyDisplayIsActive() -> Bool {
        var count: UInt32 = 0
        return CGGetActiveDisplayList(0, nil, &count) == .success && count > 0
    }

    // MARK: - Reading

    var automations: [Automation] { configStore.resolved.automations }

    func automation(_ id: String) -> Automation? {
        automations.first { $0.id == id }
    }

    /// Newest first.
    func runs(for automationId: String) -> [AutomationRun] {
        store.runs(for: automationId)
    }

    func run(_ runId: String) -> AutomationRun? {
        store.run(runId)
    }

    func lastRun(for automationId: String) -> AutomationRun? {
        store.lastRun(for: automationId)
    }

    /// When the automation runs next, or nil while it is paused.
    func nextRunDate(for automationId: String) -> Date? {
        guard let automation = automation(automationId), automation.enabled else { return nil }
        if let state = store.schedules[automationId],
           state.signature == AutomationScheduling.signature(of: automation) {
            return state.nextRunAt
        }
        return automation.schedule.nextOccurrence(after: environment.now(), calendar: environment.calendar)
    }

    // MARK: - Editing

    /// Writes the automation to `settings.json`; the store's reload brings
    /// it back here as configuration.
    @discardableResult
    func save(_ automation: Automation) -> Bool {
        configStore.write(automation.configObject, at: ["automations", automation.id])
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, for automationId: String) -> Bool {
        guard automation(automationId) != nil else { return false }
        if enabled {
            return configStore.remove(at: ["automations", automationId, "enabled"])
        }
        return configStore.write(false, at: ["automations", automationId, "enabled"])
    }

    /// Removes the automation and its run history. Windows of runs still
    /// open stay, and so do worktrees runs left work in.
    @discardableResult
    func delete(_ automationId: String) -> Bool {
        guard configStore.remove(at: ["automations", automationId]) else { return false }
        store.removeAll(for: automationId)
        return true
    }

    /// Starts a run now, skipping the precheck: the person asking is the check.
    func runNow(_ automationId: String) {
        guard let automation = automation(automationId) else { return }
        begin(automation, trigger: .manual, scheduledFor: nil)
    }

    /// Shows the run's agent: its tab while it is open, or its conversation
    /// resumed in a new window when the run's window was closed. False when
    /// there is neither.
    @discardableResult
    func openRun(_ runId: String) -> Bool {
        guard let run = store.run(runId) else { return false }
        if let target = run.target, agentManager.panes[target.paneId]?.tabs.contains(where: { $0.id == target.tabId }) == true {
            store.update(runId) { $0.viewed = true }
            agentManager.focusTab(paneId: target.paneId, tabId: target.tabId)
            return true
        }
        guard let conversation = run.conversation,
              AgentConversation.supports(profileId: run.profileId)
        else { return false }
        let automation = automation(run.automationId)
        let title = Self.runTitle(name: automation?.name ?? run.automationId, number: run.number)
        guard let target = agentManager.openAutomationWindow(
            title: title,
            profileId: run.profileId,
            cwd: conversation.cwd ?? run.folder,
            runId: nil,
            launch: AgentLaunch(prompt: "", model: automation?.model, skipsApprovals: true),
            conversation: conversation
        ) else { return false }
        agentManager.focusTab(paneId: target.paneId, tabId: target.tabId)
        return true
    }

    static func runTitle(name: String, number: Int) -> String {
        "\(name) #\(number)"
    }

    // MARK: - Observers

    func addObserver(id: String, _ handler: @escaping () -> Void) {
        observers[id] = handler
    }

    func removeObserver(id: String) {
        observers[id] = nil
    }

    private func notifyObservers() {
        for handler in observers.values {
            handler()
        }
    }

    // MARK: - Schedules

    /// Starts every automation that came due, records the ones that are too
    /// late, and fails runs whose agent never said anything.
    func tick() {
        let now = environment.now()
        let automations = automations
        let ids = Set(automations.map(\.id))
        for id in store.schedules.keys where !ids.contains(id) {
            store.setSchedule(nil, for: id)
        }
        for automation in automations {
            let (state, decision) = AutomationScheduling.evaluate(
                automation,
                state: store.schedules[automation.id],
                now: now,
                calendar: environment.calendar
            )
            store.setSchedule(state, for: automation.id)
            switch decision {
            case .run(let scheduledFor):
                begin(automation, trigger: .scheduled, scheduledFor: scheduledFor)
            case .missed(let scheduledFor):
                record(
                    automation,
                    scheduledFor: scheduledFor,
                    status: .skipped,
                    message: "It was due while the Mac slept or Soprano was closed, and is past its grace period."
                )
            case nil:
                break
            }
        }
        for run in store.openRuns where run.status == .starting && !waitingForDisplay.contains(run.id) {
            guard let target = run.target,
                  agentManager.agent(paneId: target.paneId, tabId: target.tabId)?.status == .starting,
                  now.timeIntervalSince(run.startedAt) > Self.startTimeout
            else { continue }
            finish(run.id, status: .failed, message: "The agent didn't start within \(Int(Self.startTimeout / 60)) minutes. Open its window to see what it's waiting for.")
        }
    }

    private func record(_ automation: Automation, scheduledFor: Date?, status: AutomationRun.Status, message: String) {
        let now = environment.now()
        store.insert(AutomationRun(
            id: UUID().uuidString,
            automationId: automation.id,
            number: store.nextRunNumber(for: automation.id),
            trigger: .scheduled,
            scheduledFor: scheduledFor,
            startedAt: now,
            finishedAt: now,
            status: status,
            message: message,
            profileId: automation.agentId,
            folder: automation.folder
        ))
    }

    // MARK: - Starting runs

    private func begin(_ automation: Automation, trigger: AutomationRun.Trigger, scheduledFor: Date?) {
        let runs = store.runs(for: automation.id)
        if trigger == .scheduled, let open = runs.first(where: { !$0.status.isFinal }) {
            record(
                automation,
                scheduledFor: scheduledFor,
                status: .skipped,
                message: "Run #\(open.number) was still working."
            )
            return
        }

        let run = AutomationRun(
            id: UUID().uuidString,
            automationId: automation.id,
            number: store.nextRunNumber(for: automation.id),
            trigger: trigger,
            scheduledFor: scheduledFor,
            startedAt: environment.now(),
            status: .starting,
            profileId: automation.agentId,
            folder: automation.folder
        )
        store.insert(run)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: automation.folder, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            finish(run.id, status: .skipped, message: "\(ConfigFile.abbreviatingHome(automation.folder)) is not a folder.")
            return
        }

        if automation.session == .reuse, let previous = reusableRun(for: automation, excluding: run.id),
           let target = previous.target,
           environment.submitPrompt(automation.prompt, target) {
            store.update(previous.id) {
                $0.paneId = nil
                $0.tabId = nil
            }
            store.update(run.id) {
                $0.paneId = target.paneId
                $0.tabId = target.tabId
                $0.conversation = previous.conversation
                $0.viewed = previous.viewed
                $0.sawWork = true
                $0.status = .running
            }
            agentManager.agent(paneId: target.paneId, tabId: target.tabId)?.automationRunId = run.id
            return
        }

        let precheck = trigger == .scheduled ? automation.precheck : nil
        let timeout = TimeInterval(automation.precheckTimeoutSeconds)
        let worktreeBase: String?? = {
            if case .worktree(let baseBranch) = automation.workspace { return .some(baseBranch) }
            return .none
        }()
        let worktreeDirectory = environment.worktreeDirectory
        let claudeConfig = automation.agentId == "claude-code" ? environment.claudeConfig : nil
        let date = environment.now()
        let shell = environment.shell
        let folder = automation.folder
        let automationId = automation.id
        let runId = run.id
        workQueue.async {
            var preparation = Preparation()
            preparation.precheck = precheck.map {
                AutomationPrecheck.run($0, in: folder, timeout: timeout, shell: shell)
            }
            let proceeds = preparation.precheck?.passed ?? true
            if proceeds, case .some(let baseBranch) = worktreeBase {
                do {
                    preparation.checkout = try AutomationWorktree.create(
                        from: folder,
                        automationId: automationId,
                        baseBranch: baseBranch,
                        date: date,
                        under: worktreeDirectory
                    )
                } catch {
                    preparation.failure = error.localizedDescription
                }
            }
            if let claudeConfig, proceeds, preparation.failure == nil {
                ClaudeWorkspaceTrust.trust(
                    preparation.checkout?.workingDirectory ?? folder,
                    configURL: claudeConfig
                )
            }
            let result = preparation
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.prepared(runId, automation: automation, preparation: result)
                }
            }
        }
    }

    /// What was done off the main thread before a run's window opens.
    private struct Preparation: Sendable {
        var precheck: AutomationPrecheck.Outcome?
        var checkout: AutomationWorktree.Checkout?
        var failure: String?
    }

    private func prepared(_ runId: String, automation: Automation, preparation: Preparation) {
        if let precheck = preparation.precheck, !precheck.passed {
            finish(runId, status: .skipped, message: precheck.summary)
            return
        }
        if let failure = preparation.failure {
            finish(runId, status: .failed, message: failure)
            return
        }
        var workingDirectory = automation.folder
        if let checkout = preparation.checkout {
            workingDirectory = checkout.workingDirectory
            store.update(runId) {
                $0.worktree = checkout.worktree
                $0.folder = checkout.workingDirectory
            }
        }
        guard let run = store.run(runId) else { return }
        guard let target = agentManager.openAutomationWindow(
            title: Self.runTitle(name: automation.name, number: run.number),
            profileId: automation.agentId,
            cwd: workingDirectory,
            runId: runId,
            launch: AgentLaunch(prompt: automation.prompt, model: automation.model, skipsApprovals: true)
        ) else {
            finish(runId, status: .failed, message: "Soprano couldn't open a window for the run.")
            return
        }
        store.update(runId) {
            $0.paneId = target.paneId
            $0.tabId = target.tabId
            $0.startedAt = environment.now()
        }
        startTerminal(of: runId, at: target)
    }

    /// Starts the run's terminal, or waits for a display to wake: libghostty
    /// draws on one, so a run due at night begins when a display wakes.
    private func startTerminal(of runId: String, at target: TerminalTarget) {
        if environment.startTerminal(target) {
            waitingForDisplay.remove(runId)
            store.update(runId) { if $0.message == Self.waitingForDisplayMessage { $0.message = nil } }
            return
        }
        waitingForDisplay.insert(runId)
        store.update(runId) { $0.message = Self.waitingForDisplayMessage }
        guard displayRetryTimer == nil else { return }
        displayRetryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.retryWaitingTerminals() }
        }
    }

    private func retryWaitingTerminals() {
        guard environment.displayIsAwake() else { return }
        for runId in waitingForDisplay {
            guard let run = store.run(runId), !run.status.isFinal, let target = run.target else {
                waitingForDisplay.remove(runId)
                continue
            }
            startTerminal(of: runId, at: target)
        }
        if waitingForDisplay.isEmpty {
            displayRetryTimer?.invalidate()
            displayRetryTimer = nil
        }
    }

    /// The newest run of a reuse automation whose agent is still open and
    /// done with its turn.
    private func reusableRun(for automation: Automation, excluding runId: String) -> AutomationRun? {
        for run in store.runs(for: automation.id) where run.id != runId {
            guard let target = run.target,
                  let agent = agentManager.agent(paneId: target.paneId, tabId: target.tabId),
                  agent.profileId == automation.agentId
            else { continue }
            let isDone = agent.status == .idle
                || (agent.status == .waiting && !(agent.waitingReason ?? .turnEnded).blocks)
            return isDone ? run : nil
        }
        return nil
    }

    // MARK: - Following runs

    /// Moves every open run along with what its agent reports.
    private func followRuns() {
        for run in store.openRuns {
            guard let target = run.target else { continue }
            let tab = agentManager.panes[target.paneId]?.tabs.first { $0.id == target.tabId }
            let agent = tab?.agent
            let isLookedAt = agentManager.activePaneId == target.paneId
                && agentManager.panes[target.paneId]?.activeTab?.id == target.tabId
            if isLookedAt && !run.viewed || agent?.conversation != nil && agent?.conversation != run.conversation {
                store.update(run.id) {
                    if isLookedAt { $0.viewed = true }
                    if let conversation = agent?.conversation { $0.conversation = conversation }
                }
            }
            let observation = AutomationRunTracking.Observation(
                tabExists: tab != nil,
                hasAgent: agent != nil,
                status: agent?.status,
                waitingReason: agent?.waitingReason,
                message: agent?.lastMessage
            )
            guard let current = store.run(run.id),
                  let change = AutomationRunTracking.change(for: current, observing: observation)
            else { continue }
            apply(change, to: current, target: target)
        }
    }

    private func apply(_ change: AutomationRunTracking.Change, to run: AutomationRun, target: TerminalTarget) {
        let name = automation(run.automationId)?.name ?? run.automationId
        switch change {
        case .running:
            store.update(run.id) {
                $0.status = .running
                $0.sawWork = true
                $0.message = nil
            }
        case .needsInput(let message):
            store.update(run.id) {
                $0.status = .needsInput
                $0.message = message
            }
            let reason = agentManager.agent(paneId: target.paneId, tabId: target.tabId)?.waitingReason
            environment.notify(
                reason == .approval ? "\(name) needs approval" : "\(name) has a question",
                message.flatMap(AgentEventCommand.summarize) ?? "Open the run to answer.",
                run.id
            )
        case .failed(let message):
            finish(run.id, status: .failed, message: message)
        case .completed:
            complete(run, target: target, automationName: name)
        }
    }

    /// Keeps what the agent said, closes the run's window when nobody opened
    /// it, and takes back a worktree the run left untouched.
    private func complete(_ run: AutomationRun, target: TerminalTarget, automationName: String) {
        let agent = agentManager.agent(paneId: target.paneId, tabId: target.tabId)
        let fallback = AutomationRun.trimmedOutput(agent?.lastMessage ?? environment.visibleText(target))
        let conversation = agent?.conversation ?? run.conversation
        finish(run.id, status: .completed, message: nil, output: fallback)
        environment.notify(
            "\(automationName) is done",
            fallback.flatMap(AgentEventCommand.summarize) ?? "Its report is in Automations.",
            run.id
        )

        let automation = automation(run.automationId)
        if !run.viewed, automation?.session != .reuse {
            agentManager.closeAutomationRun(target)
            store.update(run.id) {
                $0.paneId = nil
                $0.tabId = nil
            }
        }

        let worktree = run.worktree
        let profileId = run.profileId
        let home = environment.home
        workQueue.async {
            let reply = conversation.flatMap { Self.finalReply(profileId: profileId, conversation: $0, home: home) }
            let untouched = worktree.map(AutomationWorktree.isUntouched) ?? false
            if let worktree, untouched {
                AutomationWorktree.remove(worktree)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.store.update(run.id) {
                        if let reply = AutomationRun.trimmedOutput(reply) { $0.output = reply }
                        if untouched { $0.worktree?.removed = true }
                    }
                }
            }
        }
    }

    private func finish(
        _ runId: String,
        status: AutomationRun.Status,
        message: String?,
        output: String? = nil
    ) {
        waitingForDisplay.remove(runId)
        let now = environment.now()
        store.update(runId) {
            $0.status = status
            $0.finishedAt = now
            $0.message = message
            if let output { $0.output = output }
        }
        // A window left open after the run is an ordinary agent again, whose
        // banners name its pane like any other.
        if let target = store.run(runId)?.target,
           let agent = agentManager.agent(paneId: target.paneId, tabId: target.tabId),
           agent.automationRunId == runId {
            agent.automationRunId = nil
        }
        guard status == .failed, let run = store.run(runId) else { return }
        let name = automation(run.automationId)?.name ?? run.automationId
        environment.notify("\(name) failed", message.flatMap(AgentEventCommand.summarize) ?? "Open the run to see why.", runId)
    }

    /// The agent's last reply from its transcript, for the CLIs that write one.
    nonisolated static func finalReply(profileId: String, conversation: AgentConversation, home: URL) -> String? {
        guard let source = AgentTranscriptSource(profileId: profileId, conversation: conversation) else { return nil }
        let timeline = TranscriptFollower(source: source, home: home).readAppended()
        for item in timeline?.items.reversed() ?? [] {
            if case .reply(let text) = item.kind { return text }
        }
        return nil
    }
}
