import AppKit

/// The Automations page (Orca's Automations view): every scheduled prompt in
/// a table, one automation's settings and run history, and one run's report.
/// It covers the workspace to the right of the sidebar and reads and writes
/// everything through `AutomationController`, whose observer brings a run
/// finishing or a hand edit to settings.json onto the page while it shows.
final class AutomationsViewController: NSViewController {
    private enum Page: Equatable {
        case list
        case automation(String)
        case run(String)
    }

    let controller: AutomationController
    let themeManager: ThemeManager

    /// Asks the host to close the page.
    var onDismiss: (() -> Void)?
    /// A run's agent is on screen now; the host closes the page so its
    /// terminal shows.
    var onRunOpened: (() -> Void)?
    /// Whether a run's tab is still open, which decides between Open Run and
    /// Resume Conversation.
    var isTargetLive: (TerminalTarget) -> Bool = { _ in false }

    private var page: Page = .list
    private var rootView: AutomationsRootView!
    private var headerView: SettingsHeaderView!
    private var contentView: NSView!
    private var listView: AutomationListView!
    private var detailView: AutomationDetailView?
    private var runView: AutomationRunDetailView?
    private var editor: AutomationEditorPanel?
    /// Whether the page itself, which drives the list with J/K, has the keyboard.
    private var hasKeyboard = false
    nonisolated(unsafe) private var refreshTimer: Timer?
    private var isObserving = false

    private static let observerId = "AutomationsViewController"
    /// "in 3 hr" and "5 min ago" are recomputed this often while the page shows.
    private static let refreshInterval: TimeInterval = 30

    init(controller: AutomationController, themeManager: ThemeManager) {
        self.controller = controller
        self.themeManager = themeManager
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        refreshTimer?.invalidate()
    }

    override func loadView() {
        let theme = themeManager.currentTheme
        let root = AutomationsRootView()
        root.identifier = NSUserInterfaceItemIdentifier("automations")
        root.wantsLayer = true
        root.onEscape = { [weak self] in self?.handleEscape() }
        root.onNew = { [weak self] in self?.presentEditor(for: nil, template: nil) }
        root.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        root.onActivate = { [weak self] in self?.activateSelection() }
        root.onFocusChange = { [weak self] focused in self?.setHasKeyboard(focused) }
        rootView = root

        headerView = SettingsHeaderView(title: "Automations", theme: theme)
        headerView.onClose = { [weak self] in self?.onDismiss?() }
        root.addSubview(headerView)

        contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)

        listView = AutomationListView(theme: theme)
        listView.onOpen = { [weak self] id in self?.display(.automation(id)) }
        listView.onAction = { [weak self] action, id in self?.perform(action, on: id) }
        listView.onNew = { [weak self] template in self?.presentEditor(for: nil, template: template) }
        listView.onRowClicked = { [weak self] in self?.focusPage() }
        listView.onEscape = { [weak self] in self?.handleEscape() }
        install(listView)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: root.topAnchor),

            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        view = root
        applyColors(theme: theme)
        start()
        reload()
    }

    // MARK: - Lifecycle

    /// Follows the controller and refreshes relative times while the page shows.
    private func start() {
        guard !isObserving else { return }
        isObserving = true
        controller.addObserver(id: Self.observerId) { [weak self] in
            self?.reload()
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
    }

    /// Detaches from the controller; the host calls it as the page closes,
    /// since the observer cannot be removed from `deinit`.
    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if isObserving {
            controller.removeObserver(id: Self.observerId)
            isObserving = false
        }
        if let editor {
            editor.sheetParent?.endSheet(editor)
            self.editor = nil
        }
    }

    func apply(theme: AppTheme) {
        guard isViewLoaded else { return }
        applyColors(theme: theme)
        listView.apply(theme: theme)
        detailView?.apply(theme: theme)
        runView?.apply(theme: theme)
        editor?.apply(theme: theme)
        reload()
    }

    private func applyColors(theme: AppTheme) {
        view.layer?.backgroundColor = theme.colors.bgBase.cgColor
        headerView.apply(theme: theme)
    }

    // MARK: - Navigation

    /// Opens a run's report, as clicking its banner asks; an unknown run
    /// leaves the list.
    func showRun(_ runId: String) {
        loadViewIfNeeded()
        guard controller.run(runId) != nil else {
            display(.list)
            return
        }
        display(.run(runId))
    }

    /// Hands the keyboard to the page so J/K, Return and Esc work at once.
    func focusPage() {
        view.window?.makeFirstResponder(rootView)
    }

    private func display(_ page: Page, selectingRun runId: String? = nil) {
        self.page = page
        detailView?.removeFromSuperview()
        detailView = nil
        runView?.removeFromSuperview()
        runView = nil
        let theme = themeManager.currentTheme
        switch page {
        case .list:
            listView.isHidden = false
        case .automation:
            listView.isHidden = true
            let detail = AutomationDetailView(theme: theme)
            detail.onBack = { [weak self] in self?.goBack() }
            detail.onAction = { [weak self] action in
                guard let self, case .automation(let id) = self.page else { return }
                self.perform(action, on: id)
            }
            detail.onOpenRun = { [weak self] runId in self?.display(.run(runId)) }
            detail.onRowClicked = { [weak self] in self?.focusPage() }
            detail.keyHandler = { [weak rootView] event in rootView?.handleKey(event) ?? false }
            detail.isListFocused = hasKeyboard
            detail.pendingRunSelection = runId
            install(detail)
            detailView = detail
        case .run:
            listView.isHidden = true
            let runDetail = AutomationRunDetailView(theme: theme)
            runDetail.onBack = { [weak self] in self?.goBack() }
            runDetail.onOpenRun = { [weak self] runId in self?.openRun(runId) }
            runDetail.keyHandler = { [weak rootView] event in rootView?.handleKey(event) ?? false }
            install(runDetail)
            runView = runDetail
        }
        reload()
        focusPage()
    }

    private func goBack() {
        switch page {
        case .list:
            onDismiss?()
        case .automation(let id):
            listView.select(id)
            display(.list)
        case .run(let runId):
            guard let run = controller.run(runId) else {
                display(.list)
                return
            }
            display(.automation(run.automationId), selectingRun: runId)
        }
    }

    private func install(_ pageView: NSView) {
        pageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    /// Brings the visible page up to date with the controller. A page whose
    /// automation or run went away (deleted, or removed from settings.json)
    /// falls back to the list.
    private func reload() {
        guard isViewLoaded else { return }
        let now = Date()
        let automations = controller.automations
        let subtitle = subtitle(for: automations, now: now)
        if headerView.subtitle != subtitle {
            headerView.subtitle = subtitle
        }
        switch page {
        case .list:
            listView.update(
                items: automations.map {
                    AutomationListView.Item(
                        automation: $0,
                        nextRun: controller.nextRunDate(for: $0.id),
                        lastRun: controller.lastRun(for: $0.id)
                    )
                },
                now: now
            )
        case .automation(let id):
            guard let automation = controller.automation(id) else {
                display(.list)
                return
            }
            detailView?.update(
                automation: automation,
                runs: controller.runs(for: id),
                nextRun: controller.nextRunDate(for: id),
                now: now
            )
        case .run(let runId):
            guard let run = controller.run(runId) else {
                display(.list)
                return
            }
            runView?.update(
                run: run,
                automation: controller.automation(run.automationId),
                isLive: run.target.map(isTargetLive) ?? false,
                now: now
            )
        }
    }

    /// `4 automations · next run in 2 hr`.
    private func subtitle(for automations: [Automation], now: Date) -> String {
        var parts = [AutomationFormat.count(automations.count, "automation")]
        let next = automations.compactMap { controller.nextRunDate(for: $0.id) }.min()
        if let next {
            parts.append("next run \(AutomationFormat.relative(next, now: now))")
        } else if !automations.isEmpty {
            parts.append("all paused")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Keyboard

    private func handleEscape() {
        if editor != nil { return }
        switch page {
        case .list:
            if listView.clearSearch() { return }
            onDismiss?()
        case .automation, .run:
            goBack()
        }
    }

    private func moveSelection(by delta: Int) {
        switch page {
        case .list: listView.moveSelection(by: delta)
        case .automation: detailView?.moveSelection(by: delta)
        case .run: break
        }
    }

    private func activateSelection() {
        switch page {
        case .list: listView.activateSelection()
        case .automation: detailView?.activateSelection()
        case .run: break
        }
    }

    private func setHasKeyboard(_ focused: Bool) {
        guard hasKeyboard != focused else { return }
        hasKeyboard = focused
        listView.isListFocused = focused
        detailView?.isListFocused = focused
    }

    // MARK: - Actions

    private func perform(_ action: AutomationAction, on id: String) {
        guard let automation = controller.automation(id) else { return }
        switch action {
        case .runNow:
            controller.runNow(id)
        case .edit:
            presentEditor(for: automation, template: nil)
        case .toggleEnabled:
            if !controller.setEnabled(!automation.enabled, for: id) {
                showWriteFailure()
            }
        case .delete:
            confirmDelete(automation)
        }
    }

    private func openRun(_ runId: String) {
        if controller.openRun(runId) {
            onRunOpened?()
        } else {
            NSSound.beep()
            reload()
        }
    }

    private func confirmDelete(_ automation: Automation) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(automation.name)?"
        alert.informativeText = "Its run history goes too. Windows and worktrees of earlier runs stay."
        let deleteButton = alert.addButton(withTitle: "Delete")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self, response == .alertFirstButtonReturn else { return }
                if !self.controller.delete(automation.id) {
                    self.showWriteFailure()
                }
                self.focusPage()
            }
        }
    }

    private func showWriteFailure() {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Soprano couldn't change settings.json"
        alert.informativeText = "Check that \(ConfigStore.shared.displayPath) is writable, then try again."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func presentEditor(for automation: Automation?, template: AutomationTemplate?) {
        guard editor == nil, let window = view.window else { return }
        let panel = AutomationEditorPanel(
            theme: themeManager.currentTheme,
            automation: automation,
            template: template,
            automations: controller.automations,
            projectDirectories: ConfigStore.shared.settings.projectDirectories
        )
        panel.onSave = { [weak self] automation in
            self?.save(automation) ?? false
        }
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            panel.sheetParent?.endSheet(panel)
            panel.orderOut(nil)
            self.editor = nil
            self.focusPage()
        }
        editor = panel
        window.beginSheet(panel)
    }

    private func save(_ automation: Automation) -> Bool {
        guard controller.save(automation) else {
            if let editor {
                let alert = NSAlert()
                alert.messageText = "Soprano couldn't save the automation"
                alert.informativeText = "Check that \(ConfigStore.shared.displayPath) is writable, then try again."
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: editor)
            }
            return false
        }
        if page == .list {
            listView.select(automation.id)
        }
        return true
    }
}

/// What a row's ⋯ menu, its context menu and the detail's buttons do to one
/// automation.
enum AutomationAction {
    case runNow
    case edit
    case toggleEnabled
    case delete

    /// The four actions as menu items in Orca's order, with Delete after a
    /// separator. `perform` receives the chosen action.
    @MainActor
    static func menu(for automation: Automation, perform: @escaping (AutomationAction) -> Void) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let entries: [(String, AutomationAction)] = [
            ("Run Now", .runNow),
            ("Edit…", .edit),
            (automation.enabled ? "Pause" : "Resume", .toggleEnabled),
        ]
        for (title, action) in entries {
            menu.addItem(AutomationMenuItem(title: title, perform: { perform(action) }))
        }
        menu.addItem(.separator())
        menu.addItem(AutomationMenuItem(title: "Delete…", perform: { perform(.delete) }))
        return menu
    }
}

/// A menu item that runs a closure, so per-row menus need no selector table.
final class AutomationMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, perform: @escaping () -> Void) {
        handler = perform
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

// MARK: - Root view

/// The page's root and keyboard owner: Esc steps back (run → automation →
/// list → workspace), ⌘N opens the editor, and J/K or the arrows with Return
/// drive whichever list the page shows. `MainWindowController` recognizes it
/// so ⌘N reaches the page instead of opening a window.
final class AutomationsRootView: NSView {
    var onEscape: (() -> Void)?
    var onNew: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onActivate: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            onFocusChange?(true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }

    /// AppKit offers Esc to key equivalents first, so the header's Done
    /// button would otherwise close the whole page from a detail view.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53, flags.isEmpty {
            onEscape?()
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "n" {
            onNew?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) {
            super.keyDown(with: event)
        }
    }

    /// Runs the list shortcut `event` stands for; false when it is none.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard event.type == .keyDown, flags.isEmpty else { return false }
        switch event.keyCode {
        case 125:
            onMove?(1)
            return true
        case 126:
            onMove?(-1)
            return true
        case 36, 76:
            onActivate?()
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "j":
            onMove?(1)
        case "k":
            onMove?(-1)
        case " ":
            onActivate?()
        default:
            return false
        }
        return true
    }
}

// MARK: - Formatting

/// The page's wording for times, durations and settings, in one place so the
/// list, the detail and the run report read alike.
@MainActor
enum AutomationFormat {
    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter
    }()

    /// `Oct 29, 9:00 AM`.
    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    /// `in 3 hr`, `in 12 min`, `5 min ago`, `just now`, `2 days ago`.
    static func relative(_ date: Date, now: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        let magnitude = abs(seconds)
        let isFuture = seconds > 0
        guard magnitude >= 60 else { return isFuture ? "in under a minute" : "just now" }
        let amount: String
        if magnitude < 3_600 {
            amount = "\(Int(magnitude / 60)) min"
        } else if magnitude < 86_400 {
            amount = "\(Int(magnitude / 3_600)) hr"
        } else {
            let days = Int(magnitude / 86_400)
            amount = days == 1 ? "1 day" : "\(days) days"
        }
        return isFuture ? "in \(amount)" : "\(amount) ago"
    }

    /// `38s`, `4m 12s`, `2h 7m`.
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    /// `None`, `30 minutes`, `12 hours`, `1 hour 30 minutes`.
    static func grace(_ minutes: Int) -> String {
        guard minutes > 0 else { return "None" }
        let hours = minutes / 60
        let rest = minutes % 60
        let hourText = hours == 1 ? "1 hour" : "\(hours) hours"
        let minuteText = rest == 1 ? "1 minute" : "\(rest) minutes"
        if hours == 0 { return minuteText }
        return rest == 0 ? hourText : "\(hourText) \(minuteText)"
    }

    /// `30 sec`, `1 min`, `90 sec`.
    static func timeout(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) sec"
    }

    /// `~/git/shop`.
    static func path(_ path: String) -> String {
        ConfigFile.abbreviatingHome(path)
    }

    /// The agent's catalog name, or its id when the catalog lost it.
    static func agentName(_ agentId: String) -> String {
        AgentCatalog.profile(for: agentId)?.name ?? agentId
    }

    static func workspace(_ workspace: Automation.Workspace) -> String {
        switch workspace {
        case .folder:
            "Its folder"
        case .worktree(let baseBranch):
            "New worktree from \(baseBranch ?? "origin's default branch")"
        }
    }

    static func session(_ session: Automation.Session) -> String {
        switch session {
        case .fresh: "Fresh each run"
        case .reuse: "Reuses the open agent"
        }
    }

    static func trigger(_ trigger: AutomationRun.Trigger) -> String {
        switch trigger {
        case .scheduled: "Scheduled"
        case .manual: "Manual"
        }
    }

    /// `1 automation`, `4 automations`.
    static func count(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// A message's first paragraph, without the precheck output after it,
    /// for the failure banner.
    static func firstParagraph(of text: String) -> String {
        let paragraph = text.components(separatedBy: "\n\n").first ?? text
        return paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prompt's first non-empty line, for the list's second line.
    static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }
}

/// How a run's status is marked: ring = nothing happening, dot = activity
/// or your turn, diamond = failure, as `ChromeStatus` marks agents.
enum AutomationStatusStyle {
    static func shape(for status: AutomationRun.Status) -> ChromeStatusMark.Shape {
        switch status {
        case .starting, .completed, .skipped: .ring
        case .running, .needsInput: .dot
        case .failed: .diamond
        }
    }

    static func color(for status: AutomationRun.Status, in colors: ThemeColors) -> NSColor {
        switch status {
        case .starting, .needsInput: colors.yellow
        case .running, .completed: colors.success
        case .failed: colors.danger
        case .skipped: colors.gray
        }
    }
}

// MARK: - Shared views

/// Label and layout helpers shared by the page's views.
@MainActor
enum AutomationViews {
    static func label(
        _ text: String = "",
        font: NSFont = ChromeFont.label,
        color: NSColor,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = lineBreakMode
        label.cell?.truncatesLastVisibleLine = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setChromeText(text, font: font, color: color)
        return label
    }

    static func wrappingLabel(_ text: NSAttributedString) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = text
        label.maximumNumberOfLines = 0
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    /// A vertical page in a scroll view: content runs from the top, sits in
    /// the page gutter, and stops widening at a readable width.
    static func scrollingPage(stack: NSStackView) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let document = AutomationFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let fill = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -Chrome.Space.page * 2)
        fill.priority = .defaultHigh
        // The document fills the viewport when the page is shorter, but the
        // stack keeps its own height at the top: with an equal bottom it
        // stretched to the viewport and the spare height landed inside
        // whichever row hugged least (the failure notice, the run's grid).
        // The lowest priority shrink-wraps a taller page without ever
        // outweighing a row's own hugging.
        let hug = document.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: Chrome.Space.page)
        hug.priority = .init(1)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Chrome.Space.page),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Chrome.Space.s16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -Chrome.Space.page),
            hug,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 1_040),
            fill,
        ])
        return scrollView
    }

    /// Settings shown as a grid of eyebrow-over-value cells, `columns` wide.
    static func metricsGrid(_ cells: [(String, NSView)], columns: Int, theme: AppTheme) -> NSStackView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = Chrome.Space.s16
        grid.translatesAutoresizingMaskIntoConstraints = false
        var index = 0
        while index < cells.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = Chrome.Space.s24
            row.translatesAutoresizingMaskIntoConstraints = false
            for column in 0..<columns {
                let cellIndex = index + column
                guard cellIndex < cells.count else {
                    row.addArrangedSubview(NSView())
                    continue
                }
                let (title, value) = cells[cellIndex]
                let cell = NSStackView(views: [ChromeEyebrowView(title: title, theme: theme), value])
                cell.orientation = .vertical
                cell.alignment = .leading
                cell.spacing = Chrome.Space.s4
                row.addArrangedSubview(cell)
                value.widthAnchor.constraint(equalTo: cell.widthAnchor).isActive = true
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            index += columns
        }
        return grid
    }

    /// A tinted notice: the error wash, a diamond and the text, like the
    /// Settings config notices.
    static func notice(_ text: NSAttributedString, theme: AppTheme, button: NSButton? = nil) -> NSView {
        let colors = theme.colors
        let notice = NSView()
        notice.wantsLayer = true
        notice.layer?.cornerRadius = Chrome.Radius.control
        notice.layer?.backgroundColor = colors.errorWash.cgColor
        notice.translatesAutoresizingMaskIntoConstraints = false

        let mark = ChromeStatusMark(shape: .diamond, color: colors.danger)
        notice.addSubview(mark)
        let label = wrappingLabel(text)
        notice.addSubview(label)

        var constraints = [
            mark.leadingAnchor.constraint(equalTo: notice.leadingAnchor, constant: 10),
            mark.topAnchor.constraint(equalTo: label.topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: notice.topAnchor, constant: 8),
            notice.bottomAnchor.constraint(greaterThanOrEqualTo: label.bottomAnchor, constant: 8),
        ]
        if let button {
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            notice.addSubview(button)
            constraints += [
                button.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 10),
                button.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -6),
                button.topAnchor.constraint(equalTo: notice.topAnchor, constant: 6),
                notice.bottomAnchor.constraint(greaterThanOrEqualTo: button.bottomAnchor, constant: 6),
            ]
        } else {
            constraints.append(label.trailingAnchor.constraint(equalTo: notice.trailingAnchor, constant: -10))
        }
        // The bottoms above are only floors; this keeps the notice as short
        // as its text or button allows.
        let fit = notice.heightAnchor.constraint(equalToConstant: 0)
        fit.priority = .init(1)
        constraints.append(fit)
        NSLayoutConstraint.activate(constraints)
        return notice
    }

    /// A status mark and its UPPERCASE word, for a run.
    static func statusView(_ status: AutomationRun.Status, theme: AppTheme) -> NSStackView {
        let color = AutomationStatusStyle.color(for: status, in: theme.colors)
        let mark = ChromeStatusMark(shape: AutomationStatusStyle.shape(for: status), color: color)
        let word = NSTextField(labelWithString: "")
        word.setStatusText(status.label, color: color)
        let stack = NSStackView(views: [mark, word])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setHuggingPriority(.required, for: .horizontal)
        return stack
    }

    /// A row's back button and breadcrumb: `‹ Automations / Weekday audit`.
    static func breadcrumb(_ trail: [String], theme: AppTheme, target: AnyObject, action: Selector) -> NSStackView {
        let colors = theme.colors
        let back = ChromeIconButton(
            symbolName: "chevron.left",
            accessibilityLabel: "Back to \(trail.dropLast().last ?? "Automations")",
            target: target,
            action: action
        )
        back.apply(theme: theme)
        let text = NSMutableAttributedString()
        for (index, part) in trail.enumerated() {
            if index > 0 {
                text.append(ChromeText.attributed("  /  ", font: ChromeFont.label, color: colors.textMuted))
            }
            let isLast = index == trail.count - 1
            text.append(ChromeText.attributed(
                part,
                font: ChromeFont.label,
                color: isLast ? colors.textPrimary : colors.textMuted
            ))
        }
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [back, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Chrome.Space.s4
        return stack
    }

    /// A horizontal row whose trailing views are pushed to the far edge.
    static func spreadRow(leading: [NSView], trailing: [NSView], spacing: CGFloat = Chrome.Space.s8) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let row = NSStackView(views: leading + [spacer] + trailing)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = spacing
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }
}

final class AutomationFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Read-only, selectable text that is as tall as its text at the width it
/// gets, optionally on a card: the prompt and a run's report. Keys it does
/// not use go to `keyHandler`, so J/K keep driving the page after a click
/// into the text.
final class AutomationTextBlockView: NSView {
    private let textView = AutomationReadOnlyTextView()
    private let inset: CGFloat
    private let boxed: Bool
    private var measuredHeight: CGFloat = 20
    private var measuredWidth: CGFloat = -1

    var keyHandler: ((NSEvent) -> Bool)? {
        get { textView.keyHandler }
        set { textView.keyHandler = newValue }
    }

    init(text: NSAttributedString, theme: AppTheme, boxed: Bool) {
        self.boxed = boxed
        inset = boxed ? Chrome.Space.s12 : 0
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textStorage?.setAttributedString(text)
        addSubview(textView)
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func apply(theme: AppTheme) {
        let colors = theme.colors
        textView.insertionPointColor = colors.caret
        textView.selectedTextAttributes = [.backgroundColor: colors.textSelection]
        textView.linkTextAttributes = [.foregroundColor: colors.blue, .underlineStyle: NSUnderlineStyle.single.rawValue]
        if boxed {
            layer?.cornerRadius = Chrome.Radius.card
            layer?.backgroundColor = colors.raised.cgColor
            layer?.borderWidth = Chrome.hairline
            layer?.borderColor = colors.borderSubtle.cgColor
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width - inset * 2)
        textView.frame = NSRect(x: inset, y: inset, width: width, height: max(0, bounds.height - inset * 2))
        guard width != measuredWidth,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return }
        measuredWidth = width
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height) + inset * 2
        if height != measuredHeight {
            measuredHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override var isFlipped: Bool { true }
}

final class AutomationReadOnlyTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}
