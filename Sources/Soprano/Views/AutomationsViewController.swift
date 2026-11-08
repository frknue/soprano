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
    private var headerView: ShellPageHeaderView!
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
        let root = AutomationsRootView()
        root.identifier = NSUserInterfaceItemIdentifier("automations")
        root.onEscape = { [weak self] in self?.handleEscape() }
        root.onNew = { [weak self] in self?.presentEditor(for: nil, template: nil) }
        root.onMove = { [weak self] delta in self?.moveSelection(by: delta) }
        root.onActivate = { [weak self] in self?.activateSelection() }
        root.onFocusChange = { [weak self] focused in self?.setHasKeyboard(focused) }
        rootView = root

        headerView = ShellPageHeaderView(title: "Automations")
        headerView.onClose = { [weak self] in self?.onDismiss?() }
        root.addSubview(headerView)

        contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(contentView)

        listView = AutomationListView()
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
            editor.dismiss()
            self.editor = nil
        }
    }

    /// Colors follow `PaletteCenter`; a theme change only re-renders the page.
    func apply(theme: AppTheme) {
        guard isViewLoaded else { return }
        reload()
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
        switch page {
        case .list:
            listView.isHidden = false
        case .automation:
            listView.isHidden = true
            let detail = AutomationDetailView()
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
            let runDetail = AutomationRunDetailView()
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
    /// falls back to the list. A rebuild that replaced the view holding the
    /// keyboard hands it back to the page, so J/K and ⌘N keep working.
    private func reload() {
        guard isViewLoaded else { return }
        let hadKeyboard = keyboardIsInPage
        defer {
            if hadKeyboard, !keyboardIsInPage {
                focusPage()
            }
        }
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

    /// Whether the keyboard is on the page or a view inside it (the search
    /// field's editor counts).
    private var keyboardIsInPage: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === rootView || responder.isDescendant(of: rootView)
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
        ShellDialogs.confirm(
            title: "Delete \(automation.name)?",
            message: "Its run history goes too. Windows and worktrees of earlier runs stay.",
            confirmTitle: "Delete",
            isDestructive: true,
            in: window
        ) { [weak self] confirmed in
            guard let self else { return }
            if confirmed, !self.controller.delete(automation.id) {
                self.showWriteFailure()
            }
            self.focusPage()
        }
    }

    private func showWriteFailure() {
        guard let window = view.window else { return }
        ShellDialogs.alert(
            title: "Soprano couldn't change settings.json",
            message: "Check that \(ConfigStore.shared.displayPath) is writable, then try again.",
            in: window
        )
    }

    private func presentEditor(for automation: Automation?, template: AutomationTemplate?) {
        guard editor == nil, let window = view.window else { return }
        let panel = AutomationEditorPanel(
            automation: automation,
            template: template,
            automations: controller.automations,
            takenIds: controller.takenIds,
            projectDirectories: ConfigStore.shared.settings.projectDirectories
        )
        panel.onSave = { [weak self] automation in
            self?.save(automation) ?? false
        }
        panel.onClose = { [weak self] in
            guard let self else { return }
            self.editor = nil
            self.focusPage()
        }
        editor = panel
        panel.present(over: window)
    }

    /// Writes `automation`; false (the editor stays open and says why) when
    /// settings.json could not be written.
    private func save(_ automation: Automation) -> Bool {
        guard controller.save(automation) else { return false }
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
        menu.appearance = PaletteCenter.shared.palette.appearance
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
final class AutomationsRootView: PaletteView {
    var onEscape: (() -> Void)?
    var onNew: (() -> Void)?
    var onMove: ((Int) -> Void)?
    var onActivate: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        applyPalette(palette)
    }

    override func applyPalette(_ palette: Palette) {
        layer?.backgroundColor = palette.background.cgColor
    }

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

// MARK: - Shared views

/// Layout helpers shared by the page's views: Soprano Agents' board column
/// (`StatisticsDocumentView`), tile grid and header rows.
@MainActor
enum AutomationViews {
    /// The page column's padding (`px-6`).
    static let pagePadding: CGFloat = 24
    /// The page column's reading width.
    static let maxWidth: CGFloat = 1_040
    /// Fills the column up to its cap: below the window's own size
    /// priorities, so the capped column never resizes the window.
    static let fillPriority = NSLayoutConstraint.Priority.dragThatCannotResizeWindow

    /// A vertical page in a scroll view: content runs from the top, sits in
    /// the page padding, and stops widening at a readable width.
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

        let fill = stack.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -pagePadding * 2)
        fill.priority = fillPriority
        // The document fills the viewport when the page is shorter, but the
        // stack keeps its own height at the top: with an equal bottom it
        // stretched to the viewport and the spare height landed inside
        // whichever row hugged least. The lowest priority shrink-wraps a
        // taller page without ever outweighing a row's own hugging.
        let hug = document.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: pagePadding + 8)
        hug.priority = .init(1)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            document.bottomAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: pagePadding),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor, constant: -(pagePadding + 8)),
            hug,
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            fill,
        ])
        return scrollView
    }

    /// Tiles `columns` wide, `gap-3`, every tile in a row as tall as the tallest.
    static func tileGrid(_ tiles: [NSView], columns: Int) -> NSStackView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        var index = 0
        while index < tiles.count {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.distribution = .fillEqually
            row.spacing = 12
            row.translatesAutoresizingMaskIntoConstraints = false
            for column in 0..<columns {
                let tileIndex = index + column
                let tile = tileIndex < tiles.count ? tiles[tileIndex] : NSView()
                row.addArrangedSubview(tile)
                tile.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
            }
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
            index += columns
        }
        return grid
    }

    /// The back button and trail above a page's title: `‹ Automations / Weekday audit`.
    static func breadcrumb(_ trail: [String], target: AnyObject, action: Selector) -> NSStackView {
        let back = ShellGhostButton(
            symbol: "chevron.left",
            label: "Back to \(trail.dropLast().last ?? "Automations")",
            size: 24,
            symbolSize: 12,
            target: target,
            action: action
        )
        var views: [NSView] = [back]
        for (index, part) in trail.enumerated() {
            let isLast = index == trail.count - 1
            if index > 0 {
                views.append(AutoUIThemedLabel("/", size: Typography.rowSize) { $0.mutedForeground.shellScaled(by: 0.6) })
            }
            let label = AutoUIThemedLabel(part, size: Typography.rowSize, weight: isLast ? .medium : .regular) {
                isLast ? $0.foreground : $0.mutedForeground
            }
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(label)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.setCustomSpacing(4, after: back)
        return stack
    }

    /// A page's title row: the 20 pt title and its status pill, the actions
    /// at the far edge.
    static func titleRow(_ title: String, pill: ShellStatusPill, now: Date, buttons: [NSView]) -> NSStackView {
        let titleLabel = AutoUIThemedLabel(title, size: 20, weight: .semibold)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let pillView = AutoUIPillView(pill, now: now)
        let row = spreadRow(leading: [titleLabel, pillView], trailing: buttons)
        row.setCustomSpacing(12, after: titleLabel)
        return row
    }

    /// A page action: Agents' text button, kept at its own width.
    static func button(_ title: String, variant: ShellTextButton.Variant, target: AnyObject, action: Selector) -> ShellTextButton {
        let button = ShellTextButton(title: title, variant: variant)
        button.target = target
        button.action = action
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    /// A horizontal row whose trailing views are pushed to the far edge.
    static func spreadRow(leading: [NSView], trailing: [NSView], spacing: CGFloat = 8) -> NSStackView {
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

    /// Column titles over a card's rows (12 pt medium, muted, sentence case).
    static func columnTitle(_ title: String) -> AutoUIThemedLabel {
        AutoUIThemedLabel(title, size: Typography.smallSize, weight: .medium) { $0.mutedForeground }
    }
}

final class AutomationFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Read-only, selectable text that is as tall as its text at the width it
/// gets: the prompt and a run's messages. Keys it does not use go to
/// `keyHandler`, so J/K keep driving the page after a click into the text.
final class AutomationTextBlockView: PaletteView {
    private let textView = AutomationReadOnlyTextView()
    private let text: String
    private let font: NSFont
    private let role: (Palette) -> NSColor
    private let lineBreakMode: NSLineBreakMode
    private var measuredHeight: CGFloat = 20
    private var measuredWidth: CGFloat = -1

    var keyHandler: ((NSEvent) -> Bool)? {
        get { textView.keyHandler }
        set { textView.keyHandler = newValue }
    }

    init(
        text: String,
        font: NSFont = Typography.ui(Typography.bodySize),
        lineBreakMode: NSLineBreakMode = .byWordWrapping,
        role: @escaping (Palette) -> NSColor = { $0.foreground }
    ) {
        self.text = text
        self.font = font
        self.role = role
        self.lineBreakMode = lineBreakMode
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        addSubview(textView)
        applyPalette(palette)
    }

    var string: String { textView.string }

    override func applyPalette(_ palette: Palette) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = lineBreakMode
        paragraph.lineHeightMultiple = font.isFixedPitch ? 1.25 : 1.4
        textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: role(palette),
            .paragraphStyle: paragraph,
        ]))
        textView.insertionPointColor = palette.foreground
        textView.selectedTextAttributes = [.backgroundColor: palette.primary.withAlphaComponent(palette.isDark ? 0.45 : 0.22)]
        textView.linkTextAttributes = [.foregroundColor: palette.infoForeground, .cursor: NSCursor.pointingHand]
        measuredWidth = -1
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        let width = max(0, bounds.width)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(0, bounds.height))
        guard width != measuredWidth,
              let container = textView.textContainer,
              let layoutManager = textView.layoutManager
        else { return }
        measuredWidth = width
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = ceil(layoutManager.usedRect(for: container).height)
        if height != measuredHeight {
            measuredHeight = height
            invalidateIntrinsicContentSize()
        }
    }
}

final class AutomationReadOnlyTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// Markdown rendered by the chat's renderer (`Views/Chat/Markdown`), as tall
/// as it is at the width it gets: a run's report and a precheck's output.
/// Keys its selectable text does not use go to `keyHandler`.
final class AutomationMarkdownBlockView: NSView {
    private let markdown = MarkdownView(frame: .zero)
    private let source: String
    private var measuredHeight: CGFloat = 0
    private var measuredWidth: CGFloat = -1
    nonisolated(unsafe) private var keyMonitor: Any?

    var keyHandler: ((NSEvent) -> Bool)?

    init(markdown source: String) {
        self.source = source
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(markdown)
        render()
        PaletteCenter.shared.addObserver(self) { [weak self] _ in self?.render() }
    }

    /// `text` as a fenced code block, fenced past any backtick run inside it.
    convenience init(code text: String) {
        let longestRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        self.init(markdown: "\(fence)\n\(text)\n\(fence)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    private func render() {
        markdown.apply(MarkdownRenderer.render(source, style: .assistant))
        markdown.setQuoteColor(PaletteCenter.shared.palette.foreground.timelineAlpha(0.9 * 0.35))
        measuredWidth = -1
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layout() {
        super.layout()
        guard bounds.width != measuredWidth else { return }
        measuredWidth = bounds.width
        let height = markdown.layoutMarkdown(width: bounds.width)
        markdown.frame.origin = .zero
        if height != measuredHeight {
            measuredHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard window != nil else { return }
        // The rendered text views are the renderer's own; the page's keys
        // reach them first while one holds a selection.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = self.window, incoming.window === window,
                      let responder = window.firstResponder as? NSView,
                      responder.isDescendant(of: self)
                else { return false }
                return self.keyHandler?(incoming) == true
            }
            return consumed ? nil : incoming
        }
    }
}
