import AppKit
import SopranoAgentsCore

/// Composer slice: the floating composer (editor, attachments, model/effort/permissions chips,
/// context meter, send/stop), the `/` command menu and the draft context strip.
///
/// ```
/// [draft hero: What should we build in <project>? / or start without a project]
/// [/ menu: passive list above the composer while the caret is in a line-start /command token]
/// ┌ surface r16 glass ──────────────────────────────────────────────────────┐
/// │ [approval: Command approval · detail        Decline  Approve  …]         │
/// │ [question: header chip · question · options]                             │
/// │ [attachment shelf]                                                       │
/// │ Ask anything                                                             │
/// │ 📎                    ⊙ GPT-6.1 Sol High  🔒 Supervised  Build  ◔  (↑)  │
/// └──────────────────────────────────────────────────────────────────────────┘
/// [draft context strip: Current checkout                         ⎇ main]
/// ```
@MainActor
final class ComposerViewController: NSViewController, FocusRegionController, NSTextViewDelegate {
    let engine: AgentEngine
    let state: WorkspaceState

    /// Called when the composer's height changes so the container can re-pin it and pad the timeline.
    var onHeightChange: ((CGFloat) -> Void)?
    /// Called when a draft became a thread, before the thread is selected, so the container can
    /// hand the draft's terminals and tabs to it.
    var onDraftLaunched: ((ThreadDraft, _ threadID: String) -> Void)?

    // MARK: Views

    private let hero = DraftHeroView()
    private let surface = ComposerSurfaceView()
    private let approvalPanel = ComposerApprovalPanel()
    private let questionPanel = ComposerQuestionPanel()
    private let shelf = ComposerAttachmentShelf()
    private let editor = ComposerEditorView()
    private var bodyTop: NSLayoutConstraint?
    private let attachButton = GhostIconButton(symbol: Icon.paperclip, size: 28, symbolSize: 15, toolTip: "Attach files")
    private let modelChip = ComposerChip()
    private let traitsChip = ComposerChip()
    private let permissionsChip = ComposerChip()
    private let previousButton = TextButton("Previous", variant: .outline, size: .sm)
    private let answerButton = ComposerPillButton("Submit answer")
    private let primaryButton = ComposerPrimaryButton()
    private let contextMeter = ContextMeterView()
    private let contextStrip = DraftContextStrip()

    // MARK: State

    /// Whose text the editor holds: a thread, a subagent, or the draft of a project (nil = no
    /// project).
    enum Target: Hashable {
        case thread(String)
        case subagent(threadID: String, subagentID: String)
        case draft(String?)
    }

    private struct StoredDraft {
        var text: String
        var attachments: [Attachment]
    }

    /// The choices of a thread that has not been sent yet.
    struct NewThreadOptions: Equatable {
        var modelSelection: ModelSelection
        var runtimeMode: RuntimeMode
        var usesWorktree = false
        /// Base ref of the new worktree; nil = the current branch.
        var baseBranch: String?
    }

    private struct DraftGit {
        var isRepository: Bool
        var currentBranch: String?
        var branches: [GitBranchRef]?
    }

    /// Answers being drafted for a pending question set.
    private struct AnswerDraft {
        var index = 0
        var selections: [String: [String]] = [:]
        /// Free text per question (the editor holds the current question's).
        var custom: [String: String] = [:]
    }

    private enum PopoverKind {
        case model, traits, permissions, workspace, branch, project, context
    }

    private var target: Target = .draft(nil)
    private var stored: [Target: StoredDraft] = [:]
    private var attachments: [Attachment] = []
    /// Keyed by project id ("" = no project).
    private var newThreadOptions: [String: NewThreadOptions] = [:]
    private var draftGit: [String: DraftGit] = [:]
    private var history = ComposerHistory(entries: [])
    private var popover: ComposerPopover?
    private var popoverKind: PopoverKind?
    private weak var branchContent: BranchPickerContent?
    private var isAlternateHeld = false
    private nonisolated(unsafe) var flagsMonitor: Any?
    private var answers: [String: AnswerDraft] = [:]
    /// The pending question set the editor is answering, if any.
    private var questionRequestID: String?
    /// The composer's own text while the editor answers a question.
    private var stashedText: String?
    private var lastHeight: CGFloat = 0
    private var autoAdvance: Task<Void, Never>?
    private weak var contextCard: ContextMeterCardContent?
    /// Threads whose compaction this composer started and that has not finished yet.
    private var compacting: Set<String> = []
    /// The `/` command menu, while it shows.
    private var slashMenu: ComposerPopover?
    private weak var slashContent: SlashCommandMenuContent?
    private var slashToken: SlashToken?
    /// Escape (or a programmatic text change) hid the menu until the caret leaves the token.
    private var slashDismissed = false
    private var slashKeyObserver: NSObjectProtocol?

    init(engine: AgentEngine, state: WorkspaceState) {
        self.engine = engine
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }

    // MARK: Focus

    var focusRegion: FocusRegion { .composer }
    var focusRootView: NSView { view }
    func takeFocus() { focusEditor() }

    /// Moves keyboard focus into the editor; never while the statistics board covers it (commands
    /// that want the composer close the board first, `WorkspaceViewController.revealChat()`).
    func focusEditor() {
        guard !state.isStatisticsVisible else { return }
        view.window?.makeFirstResponder(editor.textView)
    }

    // MARK: Building

    override func loadView() {
        let root = PaletteView(frame: NSRect(x: 0, y: 0, width: Metrics.chatMaxWidth, height: 140))
        view = root

        let body = NSView()
        let bodyStack = ComposerColumn([shelf, editor])
        body.addSubview(bodyStack)
        let bodyTop = bodyStack.topAnchor.constraint(equalTo: body.topAnchor, constant: 16)
        self.bodyTop = bodyTop
        NSLayoutConstraint.activate([
            bodyStack.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            bodyStack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -16),
            bodyTop,
            bodyStack.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -8),
        ])

        let modelGroup = NSStackView(views: [modelChip, traitsChip])
        modelGroup.orientation = .horizontal
        modelGroup.spacing = 0
        // Each chip keeps room on both sides of its content for its own hover fill; the model
        // chip's leading inset is 2 pt smaller to offset its glyph's built-in side bearing.
        modelChip.setPadding(leading: 6, trailing: 8)
        traitsChip.setPadding(leading: 7, trailing: 7)
        traitsChip.mutesTitle = true
        let chips = NSStackView(views: [modelGroup, permissionsChip])
        chips.orientation = .horizontal
        chips.spacing = 2
        let actions = NSStackView(views: [previousButton, answerButton, contextMeter, primaryButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        let spacer = composerSpacer()
        let footerRow = NSStackView(views: [attachButton, spacer, chips, actions])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = 8
        footerRow.fillsWidth()
        footerRow.setCustomSpacing(2, after: spacer)
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSView()
        footer.addSubview(footerRow)
        NSLayoutConstraint.activate([
            footerRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 8),
            footerRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -8),
            footerRow.topAnchor.constraint(equalTo: footer.topAnchor),
            footerRow.bottomAnchor.constraint(equalTo: footer.bottomAnchor, constant: -8),
            footerRow.heightAnchor.constraint(equalToConstant: 32),
        ])
        for view in [approvalPanel, questionPanel, body, footer] {
            surface.content.add(view)
        }

        let stack = ComposerColumn([hero, surface, contextStrip])
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        wireActions()
        observe()
        selectionChanged()
        if state.pendingComposerRestore != nil { takeRestore() }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let slashMenu, let slashContent {
            slashContent.setWidth(surface.frame.width)
            slashMenu.reposition()
        }
        let height = view.frame.height
        guard abs(height - lastHeight) > 0.5 else { return }
        lastHeight = height
        onHeightChange?(height)
    }

    private func wireActions() {
        let textView = editor.textView
        textView.delegate = self
        textView.onSubmit = { [weak self] alternate in self?.submit(alternate: alternate) }
        textView.onHistory = { [weak self] up in self?.recallHistory(up: up) ?? false }
        textView.onEscape = { [weak self] in self?.closePopoverIfOpen() }
        textView.onFiles = { [weak self] urls in self?.importFiles(urls) }
        textView.onImageData = { [weak self] data in self?.importImageData(data) }
        textView.onDragHighlight = { [weak self] on in self?.surface.isDragHighlighted = on }
        textView.menuKeyHandler = { [weak self] event in self?.handleSlashKey(event) ?? false }
        textView.onResignFocus = { [weak self] in self?.closeSlashMenu() }
        contextMeter.onClick = { [weak self] in self?.toggleContextCard() }
        surface.onFiles = { [weak self] urls in self?.importFiles(urls) }
        surface.onImageData = { [weak self] data in self?.importImageData(data) }
        editor.onHeightChange = { [weak self] in self?.view.needsLayout = true }
        shelf.onRemove = { [weak self] id in self?.removeAttachment(id) }
        attachButton.onClick = { [weak self] in self?.chooseFiles() }
        modelChip.onClick = { [weak self] in self?.toggleModelPicker() }
        traitsChip.onClick = { [weak self] in self?.toggleTraits() }
        permissionsChip.onClick = { [weak self] in self?.togglePermissions() }
        primaryButton.onClick = { [weak self] in self?.primaryClicked() }
        previousButton.onClick = { [weak self] in self?.previousQuestion() }
        answerButton.onClick = { [weak self] in self?.advanceQuestion() }
        approvalPanel.onDecision = { [weak self] decision in self?.respond(decision) }
        questionPanel.onToggleOption = { [weak self] index in self?.toggleOption(index) }
        questionPanel.onDismiss = { [weak self] in self?.dismissQuestion() }
        hero.onProjectPicker = { [weak self] button in self?.toggleProjectPicker(anchor: button) }
        hero.onStartWithoutProject = { [weak self] in self?.state.select(.draft(projectID: nil)) }
        hero.onAddProject = { [weak self] in self?.perform("project.open") }
        contextStrip.workspaceChip.onClick = { [weak self] in self?.toggleWorkspaceMenu() }
        contextStrip.branchChip.onClick = { [weak self] in self?.toggleBranchPicker() }
    }

    private func observe() {
        state.addObserver(self) { [weak self] change in
            switch change {
            case .selection: self?.selectionChanged()
            case .composerRestore: self?.takeRestore()
            case .panels, .filter: break
            }
        }
        engine.addObserver(self) { [weak self] event in
            guard let self else { return }
            switch event {
            case let .threadChanged(threadID) where threadID == state.selectedThreadID:
                if history.position == nil {
                    history = ComposerHistory(entries: ComposerHistory.entries(of: currentThread))
                }
                refresh()
                if slashMenu != nil { showSlashMenu() }
            case .commandsChanged:
                if slashMenu != nil { showSlashMenu() }
            case .providersChanged, .projectsChanged, .threadListChanged:
                refresh()
            case let .subagentListChanged(threadID) where threadID == state.selectedThreadID && state.selectedSubagentID != nil:
                // The selected subagent may have started or stopped running.
                refresh()
            case .threadChanged, .itemChanged, .subagentChanged, .subagentListChanged:
                break
            }
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            MainActor.assumeIsolated {
                self?.setAlternateHeld(incoming.modifierFlags.contains(.command))
            }
            return incoming
        }
    }

    // MARK: Reading

    private var currentThread: AgentThread? {
        engine.thread(state.selectedThreadID)
    }

    /// The selected subagent: messages go to it, Stop stops it.
    private var currentSubagent: Subagent? {
        engine.subagent(state.selectedThreadID, state.selectedSubagentID)
    }

    /// Model, effort and permissions apply to the thread; a selected subagent hides them.
    var showsThreadSettings: Bool { currentSubagent == nil }

    private var pendingApproval: ApprovalRequest? {
        currentThread?.activeTurn?.pendingApproval
    }

    private var pendingInput: UserInputRequest? {
        guard pendingApproval == nil else { return nil }
        return currentThread?.activeTurn?.pendingUserInput
    }

    private var editorText: String { editor.textView.string }

    private var hasContent: Bool {
        !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    private var followUp: AppSettings.FollowUp { SettingsCenter.shared.settings.followUp }

    private var draftKey: String { state.draftProjectID ?? "" }

    private var draftOptions: NewThreadOptions {
        get {
            if let options = newThreadOptions[draftKey] { return options }
            let project = engine.project(state.draftProjectID)
            return NewThreadOptions(
                modelSelection: project?.defaultModel ?? engine.settings.defaultModel,
                runtimeMode: engine.settings.defaultRuntimeMode
            )
        }
        set { newThreadOptions[draftKey] = newValue }
    }

    private var selection: ModelSelection { currentThread?.modelSelection ?? draftOptions.modelSelection }
    private var runtimeMode: RuntimeMode { currentThread?.runtimeMode ?? draftOptions.runtimeMode }

    /// Git facts of the draft's project, once loaded and only for repositories.
    private var draftRepository: DraftGit? {
        guard state.isDraft, let projectID = state.draftProjectID, let git = draftGit[projectID], git.isRepository else { return nil }
        return git
    }

    // MARK: Selection

    private func selectionChanged() {
        closePopoverIfOpen()
        closeSlashMenu()
        saveCurrent()
        target = switch state.selection {
        case let .thread(id): .thread(id)
        case let .subagent(threadID, subagentID): .subagent(threadID: threadID, subagentID: subagentID)
        case let .draft(projectID): .draft(projectID)
        }
        let restored = stored[target]
        attachments = restored?.attachments ?? []
        shelf.setAttachments(attachments)
        editor.textView.setText(restored?.text ?? "")
        history = ComposerHistory(entries: ComposerHistory.entries(of: currentThread))
        if case let .draft(projectID) = target { loadDraftGit(projectID) }
        refresh()
        let label = currentSubagent.map { "Message \($0.id)" } ?? currentThread.map { "Message \($0.title)" } ?? "Message"
        editor.textView.setAccessibilityLabel(label)
        if let window = view.window, !Self.isForeignTextInput(window.firstResponder, in: view) {
            focusEditor()
        }
    }

    /// A text field elsewhere in the window (sidebar search) keeps focus across selection changes.
    private static func isForeignTextInput(_ responder: NSResponder?, in root: NSView) -> Bool {
        guard let view = responder as? NSView, view is NSText || view is NSTextField else { return false }
        return !view.isDescendant(of: root)
    }

    /// Keeps the editor's text and attachments for the target it is leaving.
    private func saveCurrent() {
        if let requestID = questionRequestID, var draft = answers[requestID], let question = currentQuestion(draft) {
            draft.custom[question.id] = editorText
            answers[requestID] = draft
        }
        let text = questionRequestID != nil ? (stashedText ?? "") : editorText
        questionRequestID = nil
        stashedText = nil
        if text.isEmpty, attachments.isEmpty {
            stored[target] = nil
        } else {
            stored[target] = StoredDraft(text: text, attachments: attachments)
        }
    }

    private func takeRestore() {
        guard let message = state.takeComposerRestore() else { return }
        if questionRequestID != nil {
            let existing = stashedText ?? ""
            stashedText = existing.isEmpty ? message.text : existing + "\n\n" + message.text
        } else {
            let existing = editorText
            editor.textView.setText(existing.isEmpty ? message.text : existing + "\n\n" + message.text)
        }
        attachments += message.attachments
        shelf.setAttachments(attachments)
        updatePrimary()
        focusEditor()
    }

    private func loadDraftGit(_ projectID: String?) {
        guard let projectID, let project = engine.project(projectID) else { return }
        let git = engine.environment.git
        let path = project.path
        Task { [weak self] in
            let isRepository = await git.isRepository(path)
            let status = isRepository ? try? await git.status(cwd: path) : nil
            let branches = isRepository ? try? await git.branches(cwd: path) : nil
            guard let self else { return }
            draftGit[projectID] = DraftGit(isRepository: isRepository, currentBranch: status?.branch, branches: branches ?? [])
            if state.draftProjectID == projectID {
                branchContent?.setBranches(branches ?? [])
                refresh()
            }
        }
    }

    // MARK: Rendering

    private func refresh() {
        guard isViewLoaded else { return }
        refreshHero()
        let approval = pendingApproval
        approvalPanel.isHidden = approval == nil
        if let approval { approvalPanel.configure(approval) }
        updateQuestion(pendingInput)
        bodyTop?.constant = approval != nil || questionRequestID != nil ? 10 : 16
        refreshChips()
        refreshContextStrip()
        editor.textView.placeholder = placeholder
        updatePrimary()
        refreshMeter()
    }

    private func refreshHero() {
        hero.isHidden = !state.isDraft
        guard state.isDraft else { return }
        if engine.projects.isEmpty {
            hero.configure(.noProjects)
        } else if let project = engine.project(state.draftProjectID) {
            hero.configure(.project(project.title))
        } else {
            hero.configure(.scratch)
        }
    }

    private var placeholder: String {
        if let input = pendingInput, let draft = answers[input.id], let question = currentQuestion(draft, in: input) {
            return question.allowsOther ? "Type your own answer, or leave this blank to use the selected option" : "Choose an option above"
        }
        if let subagent = currentSubagent {
            return subagent.isRunning ? "Message \(subagent.name)" : "\(subagent.name) is not running, so it can’t take messages"
        }
        if pendingApproval != nil { return "Send a message to decline and redirect the agent" }
        return "Ask anything"
    }

    private func refreshChips() {
        let isSubagent = currentSubagent != nil
        // A subagent runs its own model and permissions, and takes text only.
        for view in [modelChip, traitsChip, attachButton] as [NSView] { view.isHidden = isSubagent }
        let selection = selection
        let status = engine.status(of: selection.provider)
        let model = ModelChoice.model(for: selection, status: status)
        modelChip.configure(
            title: ProviderCatalog.displayName(for: selection, in: status),
            image: ProviderGlyph.image(for: selection.provider, size: 16)
        )
        modelChip.toolTip = ModelChoice.chipTitle(selection, status: status)
        modelChip.setAccessibilityLabel(modelChip.toolTip)

        let effort = ModelChoice.effectiveEffort(selection, model: model)
        let fast = ModelChoice.effectiveFastMode(selection, model: model)
        let fastImage = fast ? NSImage.symbol(Icon.zap, size: 10) : nil
        if let effort {
            traitsChip.configure(title: ProviderCatalog.effortLabel(effort), image: nil, trailing: fastImage)
        } else {
            traitsChip.configure(title: nil, image: NSImage.symbol(Icon.gauge, size: 14), trailing: fastImage)
        }
        let traitParts = [effort.map { "Effort: \(ProviderCatalog.effortLabel($0))" }, fast ? "Fast" : nil].compactMap { $0 }
        traitsChip.toolTip = traitParts.isEmpty ? "Traits" : traitParts.joined(separator: " · ")
        traitsChip.setAccessibilityLabel(traitsChip.toolTip)

        let mode = runtimeMode
        permissionsChip.isHidden = isSubagent || mode == engine.settings.defaultRuntimeMode
        permissionsChip.configure(title: mode.title, image: NSImage.symbol(mode.symbolName, size: 13))
        permissionsChip.toolTip = "Permissions: \(mode.title). \(mode.summary)"
        permissionsChip.setAccessibilityLabel("Permissions: \(mode.title)")
    }

    private func refreshContextStrip() {
        guard let git = draftRepository else {
            contextStrip.isHidden = true
            return
        }
        contextStrip.isHidden = false
        let options = draftOptions
        if options.usesWorktree {
            let base = options.baseBranch ?? git.currentBranch
            let isRemote = git.branches?.first { $0.name == base }?.isRemote ?? false
            contextStrip.configure(usesWorktree: true, branchLabel: BranchLabel.trigger(branch: base, newWorktree: true, isRemote: isRemote))
        } else {
            contextStrip.configure(usesWorktree: false, branchLabel: BranchLabel.trigger(branch: git.currentBranch, newWorktree: false))
        }
        contextStrip.workspaceChip.isOpen = popoverKind == .workspace
        contextStrip.branchChip.isOpen = popoverKind == .branch
    }

    private func updatePrimary() {
        let thread = currentThread
        if let input = pendingInput, questionRequestID == input.id, let draft = answers[input.id] {
            let isLast = draft.index >= input.questions.count - 1
            previousButton.isHidden = draft.index == 0
            answerButton.isHidden = false
            answerButton.title = !isLast ? "Next question" : (draft.index > 0 ? "Submit answers" : "Submit answer")
            answerButton.isEnabled = isLast ? isComplete(draft, input) : !answer(for: draft.index, draft, input).isEmpty
            primaryButton.isHidden = !(thread?.isRunning ?? false)
            primaryButton.update(.stop, tooltip: ComposerPrimaryAction.stop.tooltip(followUp: followUp), stopping: isStopping)
            return
        }
        previousButton.isHidden = true
        answerButton.isHidden = true
        primaryButton.isHidden = false
        if let subagent = currentSubagent {
            let action: ComposerPrimaryAction = subagent.isRunning ? (hasContent ? .steer : .stop) : .sendDisabled
            let tooltip = switch action {
            case .steer: "Send to \(subagent.name)"
            case .stop: "Stop \(subagent.name)"
            default: "\(subagent.name) is not running"
            }
            primaryButton.update(action, tooltip: tooltip, stopping: false)
            return
        }
        let action = ComposerPrimaryAction.resolve(
            isRunning: thread?.isRunning ?? false,
            hasContent: hasContent,
            isAwaitingApproval: pendingApproval != nil,
            followUp: followUp,
            alternate: isAlternateHeld
        )
        primaryButton.update(action, tooltip: action.tooltip(followUp: followUp), stopping: action == .stop && isStopping)
    }

    /// Stop was pressed and the provider has not ended the turn yet.
    private var isStopping: Bool {
        currentThread?.activeTurn?.stopRequestedAt != nil
    }

    private func setAlternateHeld(_ held: Bool) {
        guard held != isAlternateHeld else { return }
        isAlternateHeld = held
        updatePrimary()
    }

    // MARK: Editor delegate

    func textDidChange(_ notification: Notification) {
        editor.updateHeight()
        if let current = history.current, editorText != current {
            history.reset()
        }
        if let requestID = questionRequestID, var draft = answers[requestID], let question = currentQuestion(draft) {
            draft.custom[question.id] = editorText
            answers[requestID] = draft
        }
        updatePrimary()
        syncSlashMenu()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        syncSlashMenu()
    }

    private func recallHistory(up: Bool) -> Bool {
        guard questionRequestID == nil, !state.isDraft else { return false }
        let text = editorText
        if up {
            guard text.isEmpty || text == history.current else { return false }
            guard let entry = history.older() else { return history.position != nil }
            editor.textView.setText(entry)
            return true
        }
        guard history.position != nil, text == history.current, let entry = history.newer() else { return false }
        editor.textView.setText(entry)
        return true
    }

    // MARK: Sending

    private func primaryClicked() {
        if primaryButton.action == .stop {
            stop()
            return
        }
        submit(alternate: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    /// Enter / the send button. `alternate` (⌘) swaps steer and queue while a turn runs.
    func submit(alternate: Bool) {
        if questionRequestID != nil {
            advanceQuestion()
            return
        }
        let text = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !text.isEmpty || !files.isEmpty else { return }
        if state.isDraft {
            launchDraft(text: text, attachments: files)
            return
        }
        guard let thread = currentThread else { return }
        if let subagent = currentSubagent {
            sendToSubagent(subagent, of: thread.id, text: text)
            return
        }
        if let approval = pendingApproval {
            // Decline, then deliver the message: it steers the turn the agent continues.
            let sentFrom = target
            clearComposer()
            Task { [weak self] in
                guard let self else { return }
                await engine.respond(thread.id, approvalID: approval.id, decision: .decline)
                do {
                    try await engine.send(thread.id, text: text, attachments: files)
                } catch {
                    restoreUnsent(text: text, attachments: files, to: sentFrom)
                    await Dialogs.alert(title: "Couldn’t send message", message: error.localizedDescription, in: view.window)
                }
            }
            return
        }
        let action = ComposerPrimaryAction.resolve(
            isRunning: thread.isRunning,
            hasContent: true,
            isAwaitingApproval: false,
            followUp: followUp,
            alternate: alternate
        )
        guard let mode = action.sendMode else { return }
        let sentFrom = target
        clearComposer()
        Task { [weak self] in
            do {
                try await self?.engine.send(thread.id, text: text, attachments: files, mode: mode)
            } catch {
                self?.restoreUnsent(text: text, attachments: files, to: sentFrom)
                await Dialogs.alert(title: "Couldn’t send message", message: error.localizedDescription, in: self?.view.window)
            }
        }
    }

    /// ⌘↩: the opposite of the follow-up setting while a turn runs.
    func sendAlternate() {
        submit(alternate: true)
    }

    /// Delivers text to a subagent (attachments stay in the composer: subagents take text only).
    private func sendToSubagent(_ subagent: Subagent, of threadID: String, text: String) {
        guard !text.isEmpty else { return }
        let sentFrom = target
        editor.textView.setText("")
        history.reset()
        updatePrimary()
        let subagentID = subagent.id
        let name = subagent.name
        Task { [weak self] in
            do {
                try await self?.engine.steerSubagent(threadID, subagentID, text: text)
            } catch {
                self?.restoreUnsent(text: text, attachments: [], to: sentFrom)
                await Dialogs.alert(title: "Couldn’t message \(name)", message: error.localizedDescription, in: self?.view.window)
            }
        }
    }

    private func launchDraft(text: String, attachments files: [Attachment]) {
        let options = draftOptions
        var workspace = WorkspaceChoice.projectRoot
        if let git = draftRepository, options.usesWorktree, let base = options.baseBranch ?? git.currentBranch {
            workspace = .newWorktree(baseBranch: base)
        }
        let draft = ThreadDraft(
            projectID: state.draftProjectID,
            modelSelection: options.modelSelection,
            runtimeMode: options.runtimeMode,
            workspace: workspace
        )
        let sentFrom = target
        clearComposer()
        Task { [weak self] in
            guard let self else { return }
            do {
                let threadID = try await engine.launchThread(draft, text: text, attachments: files)
                onDraftLaunched?(draft, threadID)
                state.select(.thread(threadID), closingStatistics: false)
            } catch {
                restoreUnsent(text: text, attachments: files, to: sentFrom)
                await Dialogs.alert(title: "Couldn’t start a new thread", message: error.localizedDescription, in: view.window)
            }
        }
    }

    private func clearComposer() {
        editor.textView.setText("")
        attachments = []
        shelf.setAttachments([])
        history.reset()
        updatePrimary()
    }

    /// Puts a message that failed to send back where it came from (unless the user typed anew).
    private func restoreUnsent(text: String, attachments files: [Attachment], to origin: Target) {
        if origin == target, questionRequestID == nil, editorText.isEmpty, attachments.isEmpty {
            editor.textView.setText(text)
            attachments = files
            shelf.setAttachments(files)
            updatePrimary()
        } else if stored[origin] == nil {
            stored[origin] = StoredDraft(text: text, attachments: files)
        }
    }

    /// Interrupts the selected thread's running turn, or stops the selected subagent.
    func stop() {
        if let subagent = currentSubagent {
            guard subagent.isRunning, let threadID = state.selectedThreadID else { return }
            SubagentActions.stop(threadID: threadID, subagentID: subagent.id, engine: engine, window: view.window)
            return
        }
        guard let thread = currentThread, thread.isRunning else { return }
        Task { await engine.interrupt(thread.id) }
    }

    var canStop: Bool {
        if let subagent = currentSubagent { return subagent.isRunning }
        return currentThread?.isRunning ?? false
    }

    // MARK: Approvals and questions

    private func respond(_ decision: ApprovalDecision) {
        guard let thread = currentThread, let approval = pendingApproval else { return }
        Task { await engine.respond(thread.id, approvalID: approval.id, decision: decision) }
    }

    private func currentQuestion(_ draft: AnswerDraft, in request: UserInputRequest? = nil) -> UserInputQuestion? {
        guard let request = request ?? pendingInput, request.questions.indices.contains(draft.index) else { return nil }
        return request.questions[draft.index]
    }

    /// Free text wins over selected options.
    private func answer(for index: Int, _ draft: AnswerDraft, _ request: UserInputRequest) -> [String] {
        guard request.questions.indices.contains(index) else { return [] }
        let question = request.questions[index]
        let custom = (draft.custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return [custom] }
        return draft.selections[question.id] ?? []
    }

    private func isComplete(_ draft: AnswerDraft, _ request: UserInputRequest) -> Bool {
        request.questions.indices.allSatisfy { !answer(for: $0, draft, request).isEmpty }
    }

    /// Enters, follows or leaves question mode as the thread's pending questions change.
    private func updateQuestion(_ request: UserInputRequest?) {
        guard let request else {
            questionPanel.isHidden = true
            if questionRequestID != nil {
                questionRequestID = nil
                editor.textView.setText(stashedText ?? "")
                stashedText = nil
            }
            return
        }
        if questionRequestID != request.id {
            if questionRequestID == nil { stashedText = editorText }
            questionRequestID = request.id
            let draft = answers[request.id] ?? AnswerDraft()
            answers[request.id] = draft
            editor.textView.setText(currentQuestion(draft, in: request).flatMap { draft.custom[$0.id] } ?? "")
        }
        guard let draft = answers[request.id], let question = currentQuestion(draft, in: request) else { return }
        questionPanel.isHidden = false
        let custom = (draft.custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        questionPanel.configure(
            question: question,
            index: draft.index,
            total: request.questions.count,
            selected: custom.isEmpty ? Set(draft.selections[question.id] ?? []) : [],
            enabled: true
        )
    }

    private func toggleOption(_ optionIndex: Int) {
        guard let request = pendingInput, var draft = answers[request.id], let question = currentQuestion(draft, in: request),
              question.options.indices.contains(optionIndex) else { return }
        let label = question.options[optionIndex].label
        if question.allowsMultiple {
            var chosen = draft.selections[question.id] ?? []
            if let existing = chosen.firstIndex(of: label) { chosen.remove(at: existing) } else { chosen.append(label) }
            draft.selections[question.id] = chosen
        } else {
            draft.selections[question.id] = [label]
        }
        draft.custom[question.id] = ""
        answers[request.id] = draft
        editor.textView.setText("")
        refresh()
        guard !question.allowsMultiple, draft.index < request.questions.count - 1 else { return }
        autoAdvance?.cancel()
        autoAdvance = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.advanceQuestion()
        }
    }

    private func moveQuestion(by delta: Int) {
        guard let request = pendingInput, var draft = answers[request.id] else { return }
        let next = draft.index + delta
        guard request.questions.indices.contains(next) else { return }
        if let question = currentQuestion(draft, in: request) { draft.custom[question.id] = editorText }
        draft.index = next
        answers[request.id] = draft
        editor.textView.setText(draft.custom[request.questions[next].id] ?? "")
        refresh()
    }

    private func previousQuestion() {
        autoAdvance?.cancel()
        moveQuestion(by: -1)
    }

    /// "Next question", or "Submit answers" on the last one.
    private func advanceQuestion() {
        autoAdvance?.cancel()
        guard let thread = currentThread, let request = pendingInput, let draft = answers[request.id] else { return }
        if draft.index < request.questions.count - 1 {
            guard !answer(for: draft.index, draft, request).isEmpty else { return }
            moveQuestion(by: 1)
            return
        }
        guard isComplete(draft, request) else { return }
        var result: [String: [String]] = [:]
        for (index, question) in request.questions.enumerated() {
            result[question.id] = answer(for: index, draft, request)
        }
        Task { await engine.answer(thread.id, requestID: request.id, answers: result) }
    }

    private func dismissQuestion() {
        guard let thread = currentThread, let request = pendingInput else { return }
        autoAdvance?.cancel()
        Task { await engine.dismissUserInput(thread.id, requestID: request.id) }
    }

    // MARK: Attachments

    private func chooseFiles() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.importFiles(urls) }
        }
    }

    private func importFiles(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            do {
                attachments.append(try engine.importAttachment(from: url))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        shelf.setAttachments(attachments)
        updatePrimary()
        focusEditor()
        guard !failures.isEmpty else { return }
        let window = view.window
        Task { await Dialogs.alert(title: "Couldn’t attach file", message: failures.joined(separator: "\n"), in: window) }
    }

    /// Pasted or dropped image data without a file: written to a temporary PNG, then imported.
    private func importImageData(_ data: Data) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("soprano-agents-paste", isDirectory: true)
        let url = directory.appendingPathComponent("Pasted image \(UUID().uuidString.prefix(8)).png")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
            try png.write(to: url)
        } catch {
            let window = view.window
            Task { await Dialogs.alert(title: "Couldn’t attach image", message: error.localizedDescription, in: window) }
            return
        }
        importFiles([url])
        try? FileManager.default.removeItem(at: url)
    }

    private func removeAttachment(_ id: String) {
        attachments.removeAll { $0.id == id }
        shelf.setAttachments(attachments)
        updatePrimary()
    }

    // MARK: Model, traits, permissions, mode

    private func setModelSelection(_ selection: ModelSelection) {
        if let thread = currentThread {
            engine.setModelSelection(thread.id, selection)
        } else {
            draftOptions.modelSelection = selection
            refresh()
        }
    }

    private func setRuntimeMode(_ mode: RuntimeMode) {
        if let thread = currentThread {
            engine.setRuntimeMode(thread.id, mode)
        } else {
            draftOptions.runtimeMode = mode
            refresh()
        }
    }

    func toggleModelPicker() {
        guard popoverKind != .model else { return closePopover() }
        let content = ModelPickerContent(selection: selection, status: engine.status(of: selection.provider)) { [weak self] selection in
            self?.setModelSelection(selection)
        }
        present(.model, content: content, anchor: modelChip, side: .above, alignment: .leading) { [weak self] open in
            self?.modelChip.isOpen = open
        }
    }

    func toggleTraits() {
        guard popoverKind != .traits else { return closePopover() }
        let selection = selection
        let model = ModelChoice.model(for: selection, status: engine.status(of: selection.provider))
        let content = TraitsMenuContent(
            selection: selection,
            model: model,
            runtimeMode: runtimeMode,
            includesModelOptions: true,
            onSelection: { [weak self] in self?.setModelSelection($0) },
            onRuntimeMode: { [weak self] in self?.setRuntimeMode($0) }
        )
        present(.traits, content: content, anchor: traitsChip, side: .above, alignment: .leading) { [weak self] open in
            self?.traitsChip.isOpen = open
        }
    }

    /// The permissions chip's menu; without the chip (default mode) the traits menu, which has the section too.
    func togglePermissions() {
        guard !permissionsChip.isHidden else { return toggleTraits() }
        guard popoverKind != .permissions else { return closePopover() }
        let content = TraitsMenuContent(
            selection: selection,
            model: nil,
            runtimeMode: runtimeMode,
            includesModelOptions: false,
            onSelection: { _ in },
            onRuntimeMode: { [weak self] in self?.setRuntimeMode($0) }
        )
        present(.permissions, content: content, anchor: permissionsChip, side: .above, alignment: .leading) { [weak self] open in
            self?.permissionsChip.isOpen = open
        }
    }

    // MARK: Draft workspace, branch, project

    /// Workspace and branch apply to drafts of git projects.
    var hasDraftRepository: Bool { draftRepository != nil }

    func toggleWorkspaceMenu() {
        guard draftRepository != nil else { return }
        guard popoverKind != .workspace else { return closePopover() }
        let content = WorkspaceMenuContent(usesWorktree: draftOptions.usesWorktree) { [weak self] usesWorktree in
            self?.draftOptions.usesWorktree = usesWorktree
            self?.refresh()
        }
        present(.workspace, content: content, anchor: contextStrip.workspaceChip, side: .above, alignment: .leading) { [weak self] open in
            self?.contextStrip.workspaceChip.isOpen = open
        }
    }

    /// Picks the new worktree's base ref. The current checkout's branch is read-only (switching
    /// it is not a composer action), so opening the picker selects "New worktree".
    func toggleBranchPicker() {
        guard let git = draftRepository else { return }
        guard popoverKind != .branch else { return closePopover() }
        if !draftOptions.usesWorktree {
            draftOptions.usesWorktree = true
            refresh()
        }
        let content = BranchPickerContent(
            branches: git.branches,
            selected: draftOptions.baseBranch ?? git.currentBranch,
            projectPath: engine.project(state.draftProjectID)?.path
        ) { [weak self] ref in
            self?.draftOptions.baseBranch = ref.name
            self?.refresh()
        }
        branchContent = content
        view.layoutSubtreeIfNeeded()
        present(.branch, content: content, anchor: contextStrip.branchChip, side: .above, alignment: .trailing) { [weak self] open in
            self?.contextStrip.branchChip.isOpen = open
        }
    }

    private func toggleProjectPicker(anchor: NSView) {
        guard popoverKind != .project else { return closePopover() }
        let content = ProjectPickerContent(projects: engine.projects, selectedID: state.draftProjectID) { [weak self] choice in
            guard let self else { return }
            switch choice {
            case let .project(id): state.select(.draft(projectID: id))
            case .addProject: perform("project.open")
            case .noProject: state.select(.draft(projectID: nil))
            }
        }
        present(.project, content: content, anchor: anchor, side: .below, alignment: .center) { [weak self] open in
            self?.hero.projectButton?.isOpen = open
        }
    }

    private func perform(_ commandID: String) {
        (view.window?.windowController as? MainWindowController)?.perform(commandID)
    }

    // MARK: Context meter and compaction

    private var contextReading: ContextMeterReading? {
        guard !state.isDraft else { return nil }
        return ContextMeterReading(currentThread?.contextUsage)
    }

    private func refreshMeter() {
        let isCompacting = currentThread.map { compacting.contains($0.id) } ?? false
        let reading = contextReading
        contextMeter.isCompacting = isCompacting
        contextMeter.update(reading)
        // The meter reads the thread's conversation, not a subagent's.
        if currentSubagent != nil { contextMeter.isHidden = true }
        contextCard?.update(reading, canCompact: canCompact, isCompacting: isCompacting)
    }

    /// The selected thread can compact now (and no compaction this composer started is running).
    var canCompact: Bool {
        guard let thread = currentThread, !compacting.contains(thread.id) else { return false }
        return engine.canCompact(thread.id)
    }

    /// The meter's card: usage, what compacting does, "Compact conversation".
    func toggleContextCard() {
        guard popoverKind != .context else { return closePopover() }
        guard !contextMeter.isHiddenOrHasHiddenAncestor else { return }
        let content = ContextMeterCardContent { [weak self] in self?.compactConversation() }
        content.update(contextReading, canCompact: canCompact, isCompacting: contextMeter.isCompacting)
        contextCard = content
        present(.context, content: content, anchor: contextMeter, side: .above, alignment: .trailing) { [weak self] open in
            self?.contextMeter.isOpen = open
        }
    }

    /// `thread.compact` and the card's button: the provider summarizes the conversation.
    func compactConversation() {
        guard let thread = currentThread, canCompact else { return }
        let threadID = thread.id
        compacting.insert(threadID)
        refreshMeter()
        Task { [weak self] in
            do {
                try await self?.engine.compact(threadID)
            } catch {
                await Dialogs.alert(title: "Couldn’t compact the conversation", message: error.localizedDescription, in: self?.view.window)
            }
            self?.compacting.remove(threadID)
            self?.refreshMeter()
        }
    }

    // MARK: Slash commands

    /// Opens, filters or closes the `/` menu for the token at the caret.
    private func syncSlashMenu() {
        let textView = editor.textView
        let caret = textView.selectedRange()
        let token = questionRequestID == nil && pendingApproval == nil && caret.length == 0
            ? SlashToken.at(textView.string, caret: caret.location)
            : nil
        guard let token else {
            slashDismissed = false
            closeSlashMenu()
            return
        }
        // Text the composer put there (thread switch, history, restore) never opens the menu.
        if textView.isSettingText { slashDismissed = true }
        guard !slashDismissed, view.window?.firstResponder === textView else {
            closeSlashMenu()
            return
        }
        guard token != slashToken || slashMenu == nil else { return }
        slashToken = token
        showSlashMenu()
    }

    /// Shows the menu for `slashToken`, or re-lists it in place when it already shows.
    private func showSlashMenu() {
        guard let token = slashToken else { return }
        let thread = currentThread
        let commands = thread.map { engine.commands(forThread: $0.id) }
            ?? engine.commands(forDraft: selection.provider, projectID: state.draftProjectID)
        let candidates = SlashCommandFilter.candidates(commands, includeCompact: thread.map { engine.canCompact($0.id) } ?? false)
        let matches = SlashCommandFilter.matching(candidates, query: token.query)
        let emptyText = SlashCommandFilter.emptyText(hasCandidates: !candidates.isEmpty, query: token.query)
        if slashMenu != nil, let slashContent {
            slashContent.show(matches, emptyText: emptyText)
            return
        }
        guard let window = surface.window else { return }
        closePopover()
        let content = SlashCommandMenuContent(width: surface.frame.width) { [weak self] command in self?.insertCommand(command) }
        content.show(matches, emptyText: emptyText)
        let menu = ComposerPopover(content: content, passive: true)
        menu.onClose = { [weak self, weak menu] in
            guard let self, let menu, slashMenu === menu else { return }
            slashMenu = nil
            slashToken = nil
            if let slashKeyObserver { NotificationCenter.default.removeObserver(slashKeyObserver) }
            slashKeyObserver = nil
        }
        slashMenu = menu
        slashContent = content
        // Another of the app's windows taking the keyboard (palette, dialog, settings) closes the
        // menu. The main window resigning key alone does not: that also happens when the app is
        // deactivated (or never was, offscreen), and the editor keeps its focus then.
        slashKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self, weak window, weak menu] note in
            nonisolated(unsafe) let keyWindow = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard SlashMenuFocus.closes(whenKey: keyWindow, main: window, menu: menu?.window) else { return }
                self?.closeSlashMenu()
            }
        }
        menu.show(anchoredTo: surface, side: .above, alignment: .leading)
    }

    private func closeSlashMenu() {
        slashToken = nil
        slashMenu?.close()
    }

    /// Escape, or Enter/Tab with nothing to pick: hide the menu until the caret leaves the token.
    private func dismissSlashMenu() {
        slashDismissed = true
        closeSlashMenu()
    }

    /// ↑/↓ move, Enter/Tab insert, Escape closes; anything else (⇧⇥, ⇧↩, typing) goes to the editor.
    private func handleSlashKey(_ event: NSEvent) -> Bool {
        guard slashMenu != nil, let content = slashContent else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        switch event.keyCode {
        case 125:
            content.moveHighlight(by: 1)
        case 126:
            content.moveHighlight(by: -1)
        case 36, 76, 48:
            if !content.chooseHighlighted() { dismissSlashMenu() }
        case 53:
            dismissSlashMenu()
        default:
            return false
        }
        return true
    }

    /// Replaces the typed token with the command's text, keeping what follows it.
    private func insertCommand(_ command: ProviderCommand) {
        guard let token = slashToken else { return }
        let textView = editor.textView
        let edit = token.replacement(inserting: command.insertText, in: textView.string)
        closeSlashMenu()
        textView.insertText(edit.text, replacementRange: edit.range)
        focusEditor()
    }

    // MARK: Popovers

    private func present(
        _ kind: PopoverKind,
        content: ComposerPopoverContent,
        anchor: NSView,
        side: ComposerPopover.Side,
        alignment: ComposerPopover.Alignment,
        marking: @escaping (Bool) -> Void
    ) {
        closePopover()
        closeSlashMenu()
        guard anchor.window != nil, !anchor.isHiddenOrHasHiddenAncestor else { return }
        let popover = ComposerPopover(content: content)
        popover.onClose = { [weak self, weak popover] in
            marking(false)
            guard let self, let popover, self.popover === popover else { return }
            self.popover = nil
            popoverKind = nil
            focusEditor()
        }
        self.popover = popover
        popoverKind = kind
        marking(true)
        popover.show(anchoredTo: anchor, side: side, alignment: alignment)
    }

    private func closePopover() {
        popover?.close()
    }

    /// Escape in the editor closes an open picker.
    @discardableResult
    func closePopoverIfOpen() -> Bool {
        guard popover != nil else { return false }
        closePopover()
        return true
    }
}
