import AppKit

/// What the composer's round primary button does.
enum ComposerPrimaryAction: Equatable {
    /// Idle with text: start a turn (or decline a pending approval and redirect the agent).
    case send
    /// Idle and empty: the send button is shown disabled.
    case sendDisabled
    /// Running with text and ⌘ held: deliver into the running turn.
    case steer
    /// Running with text: wait until the running turn ends.
    case queue
    /// Running and empty: interrupt.
    case stop
    /// The agent stopped: start it again.
    case restart

    /// - Parameters:
    ///   - isAwaitingApproval: the running turn waits on an approval; sending declines it and
    ///     delivers the message, so it is a plain send rather than a steer or queue.
    ///   - alternate: ⌘ is held (⌘-click, ⌘↩): steer instead of queue, where the agent can be steered.
    static func resolve(
        isStopped: Bool,
        isRunning: Bool,
        hasContent: Bool,
        isAwaitingApproval: Bool,
        canSteer: Bool,
        alternate: Bool
    ) -> ComposerPrimaryAction {
        if isStopped { return .restart }
        guard isRunning else { return hasContent ? .send : .sendDisabled }
        guard hasContent else { return .stop }
        if isAwaitingApproval { return .send }
        return alternate && canSteer ? .steer : .queue
    }

    /// Tooltip and accessibility label.
    func tooltip(agentName: String, canSteer: Bool) -> String {
        switch self {
        case .send, .sendDisabled: "Submit message"
        case .stop: "Interrupt"
        case .restart: "Restart \(agentName)"
        case .steer, .queue:
            canSteer ? "Click to queue, ⌘-click or ⌘↩ to steer" : "Queue until \(agentName) is done"
        }
    }
}

/// Up/Down recall of the chat's earlier messages in an empty editor.
struct ComposerHistory: Equatable {
    /// Oldest first.
    let entries: [String]
    /// Index into `entries` while browsing; nil = not browsing.
    private(set) var position: Int?

    init(entries: [String]) {
        self.entries = entries
    }

    /// The person's messages (first messages and steers), oldest first.
    static func entries(of thread: ChatThread) -> [String] {
        thread.turns
            .flatMap { [$0.userMessage] + $0.steers }
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// The entry shown right now, while browsing.
    var current: String? {
        position.map { entries[$0] }
    }

    /// One step back in time; nil when there is nothing older.
    mutating func older() -> String? {
        let next = (position ?? entries.count) - 1
        guard next >= 0, next < entries.count else { return nil }
        position = next
        return entries[next]
    }

    /// One step forward; leaving the newest entry ends browsing and returns "".
    mutating func newer() -> String? {
        guard let position else { return nil }
        if position + 1 < entries.count {
            self.position = position + 1
            return entries[position + 1]
        }
        self.position = nil
        return ""
    }

    mutating func reset() {
        position = nil
    }
}

/// The chat's floating composer, ported from Soprano Agents' `ComposerViewController`: the
/// plan, the approval or question the agent waits on, the editor, the model / thinking /
/// permissions chips, the context meter and the round send / stop button; the `/` command menu
/// floats above it.
///
/// ```
/// ┌ surface r16 glass ──────────────────────────────────────────────────────┐
/// │ [plan: Plan 2 of 5 done · current step                              ⌄]  │
/// │ [approval: Command approval · detail        Decline  Approve  …]         │
/// │ [question: header chip · question · options]                             │
/// │ Ask anything                                                             │
/// │                     π Claude Opus 5.5 · anthropic  High  🔒 Default ◔ (↑)│
/// └──────────────────────────────────────────────────────────────────────────┘
/// ```
@MainActor
final class ChatComposerView: NSView, NSTextViewDelegate {
    let session: AgentChatSession
    private let agentName: String

    /// The composer's height changed; the timeline pads its end by it.
    var onHeightChange: ((CGFloat) -> Void)?
    /// The editor took (true) or lost (false) the keyboard.
    var onFocusChange: ((Bool) -> Void)?
    /// The person asked to start the stopped agent again.
    var onRestartRequested: (() -> Void)?
    /// A message went out (or was queued): the timeline follows its end again.
    var onSubmitted: (() -> Void)?

    private let surface = ComposerSurfaceView()
    private let planPanel = ComposerPlanPanel()
    private let approvalPanel = ComposerApprovalPanel()
    private let questionPanel = ComposerQuestionPanel()
    private let editor = ComposerEditorView()
    private var bodyTop: NSLayoutConstraint?
    private let modelChip = ComposerChip()
    private let traitsChip = ComposerChip()
    private let permissionsChip = ComposerChip()
    private let previousButton = TextButton("Previous", variant: .outline, size: .sm)
    private let answerButton = ComposerPillButton("Submit answer")
    private let primaryButton = ComposerPrimaryButton()
    private let contextMeter = ContextMeterView()

    /// Answers being drafted for the question on screen.
    private struct AnswerDraft {
        var index = 0
        var selections: [String: [String]] = [:]
        /// Typed text per question (the editor holds the current question's).
        var custom: [String: String] = [:]
    }

    private enum PopoverKind {
        case model, traits, permissions, context
    }

    private var history = ComposerHistory(entries: [])
    private var popover: ComposerPopover?
    private var popoverKind: PopoverKind?
    private var isAlternateHeld = false
    private nonisolated(unsafe) var flagsMonitor: Any?
    private var answers: [String: AnswerDraft] = [:]
    /// The question set the editor is answering, if any.
    private var questionRequestID: String?
    /// The composer's own text while the editor answers a question.
    private var stashedText: String?
    private var lastHeight: CGFloat = 0
    private var autoAdvance: Task<Void, Never>?
    private weak var contextCard: ContextMeterCardContent?
    /// The `/` command menu, while it shows.
    private var slashMenu: ComposerPopover?
    private weak var slashContent: SlashCommandMenuContent?
    private var slashToken: SlashToken?
    /// Escape (or a programmatic text change) hid the menu until the caret leaves the token.
    private var slashDismissed = false
    private var slashKeyObserver: NSObjectProtocol?
    /// Each question set gets its own draft id, so a new one starts over.
    private var questionCount = 0
    private var shownQuestion: AgentChatQuestion?

    init(session: AgentChatSession, agentName: String) {
        self.session = session
        self.agentName = agentName
        super.init(frame: NSRect(x: 0, y: 0, width: Metrics.chatMaxWidth, height: 140))
        build()
        wireActions()
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            nonisolated(unsafe) let incoming = event
            MainActor.assumeIsolated {
                self?.setAlternateHeld(incoming.modifierFlags.contains(.command))
            }
            return incoming
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
    }

    override var isFlipped: Bool { true }

    /// The editor, which takes the keyboard when the chat does.
    var textView: ComposerTextView { editor.textView }

    func focusEditor() {
        window?.makeFirstResponder(editor.textView)
    }

    /// Ends what floats above the composer (the tab is closing).
    func close() {
        closePopover()
        closeSlashMenu()
        autoAdvance?.cancel()
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
    }

    // MARK: Building

    private func build() {
        let body = NSView()
        let bodyStack = ComposerColumn([editor])
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
        let footerRow = NSStackView(views: [spacer, chips, actions])
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
        for view in [planPanel, approvalPanel, questionPanel, body, footer] {
            surface.content.add(view)
        }

        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        modelChip.toolTip = "Model"
        traitsChip.toolTip = "Thinking"
        permissionsChip.toolTip = "Permissions"
    }

    override func layout() {
        super.layout()
        if let slashMenu, let slashContent {
            slashContent.setWidth(surface.frame.width)
            slashMenu.reposition()
        }
        let compaction = Self.chipCompaction(forWidth: bounds.width)
        if compaction != chipCompaction {
            chipCompaction = compaction
            refreshChips()
        }
        let height = frame.height
        guard abs(height - lastHeight) > 0.5 else { return }
        lastHeight = height
        onHeightChange?(height)
    }

    private func wireActions() {
        let textView = editor.textView
        textView.delegate = self
        textView.setAccessibilityLabel("Message \(agentName)")
        textView.onSubmit = { [weak self] alternate in self?.submit(alternate: alternate) }
        textView.onHistory = { [weak self] up in self?.recallHistory(up: up) ?? false }
        textView.onEscape = { [weak self] in self?.escape() ?? false }
        textView.menuKeyHandler = { [weak self] event in self?.handleMenuKey(event) ?? false }
        textView.onFocusChange = { [weak self] focused in
            if !focused { self?.closeSlashMenu() }
            self?.onFocusChange?(focused)
        }
        contextMeter.onClick = { [weak self] in self?.toggleContextCard() }
        editor.onHeightChange = { [weak self] in self?.needsLayout = true }
        planPanel.onResize = { [weak self] in self?.needsLayout = true }
        modelChip.onClick = { [weak self] in self?.toggleOptionMenu(.model) }
        traitsChip.onClick = { [weak self] in self?.toggleOptionMenu(.traits) }
        permissionsChip.onClick = { [weak self] in self?.toggleOptionMenu(.permissions) }
        primaryButton.onClick = { [weak self] in self?.primaryClicked() }
        previousButton.onClick = { [weak self] in self?.previousQuestion() }
        answerButton.onClick = { [weak self] in self?.advanceQuestion() }
        approvalPanel.onOption = { [weak self] option in self?.session.choosePermissionOption(option.id) }
        questionPanel.onToggleOption = { [weak self] index in self?.toggleOption(index) }
        questionPanel.onDismiss = { [weak self] in self?.session.declineQuestion() }
    }

    // MARK: Reading

    private var permission: AgentChatPermission? {
        if case let .permission(permission) = session.interaction { return permission }
        return nil
    }

    private var question: AgentChatQuestion? {
        if case let .question(question) = session.interaction { return question }
        return nil
    }

    /// The question set as the composer asks it.
    private var pendingInput: UserInputRequest? {
        guard let question else { return nil }
        return question.userInputRequest(id: "question-\(questionCount)")
    }

    private var editorText: String { editor.textView.string }

    private var hasContent: Bool {
        !editorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isStopped: Bool {
        if case .stopped = session.phase { return true }
        return false
    }

    private func option(_ category: String) -> AgentChatConfigOption? {
        session.configOptions.first { $0.category == category && $0.values.count > 1 }
    }

    // MARK: Rendering

    /// Re-reads the session.
    func refresh() {
        let thread = session.thread
        if history.position == nil {
            history = ComposerHistory(entries: ComposerHistory.entries(of: thread))
        }
        let plan = session.plan
        planPanel.isHidden = plan.isEmpty || !(plan.contains { $0.status != .completed } || session.phase == .working)
        planPanel.configure(plan)
        if let permission {
            approvalPanel.isHidden = false
            approvalPanel.configure(ApprovalRequest(
                id: permission.subject, kind: permission.kind, detail: permission.subject,
                reason: permission.reason, options: permission.options
            ))
        } else {
            approvalPanel.isHidden = true
        }
        updateQuestion()
        bodyTop?.constant = permission != nil || questionRequestID != nil ? 10 : 16
        refreshChips()
        editor.textView.placeholder = placeholder
        editor.textView.isEditable = true
        updatePrimary()
        refreshMeter()
        if slashMenu != nil { showSlashMenu(keepingHighlight: true) }
    }

    private var placeholder: String {
        if let input = questionRequestID.flatMap({ answers[$0] }), let request = pendingInput, let question = currentQuestion(input, in: request) {
            return question.allowsOther ? "Type your own answer, or leave this blank to use the selected option" : "Choose an option above"
        }
        if isStopped { return "\(agentName) stopped. Press Return to restart it." }
        if permission != nil { return "Send a message to decline and redirect the agent" }
        return "Ask anything"
    }

    /// How far the footer's chips give way in a narrow composer: 0 all of them, 1 without the
    /// thinking chip, 2 without the permissions chip too, 3 the model as its glyph alone.
    private var chipCompaction = 0

    static func chipCompaction(forWidth width: CGFloat) -> Int {
        switch width {
        case 460...: 0
        case 380..<460: 1
        case 320..<380: 2
        default: 3
        }
    }

    private func refreshChips() {
        if let model = option(AgentChatConfigOption.modelCategory) {
            let value = model.currentValueEntry
            modelChip.isHidden = false
            modelChip.configure(
                title: chipCompaction >= 3 ? nil : value.map(AgentChatConfigOption.modelTitle) ?? model.currentValue,
                image: ChatAgentGlyph.image(size: 16)
            )
            modelChip.toolTip = "Model: \(value?.name ?? model.currentValue)"
            modelChip.setAccessibilityLabel(modelChip.toolTip)
        } else {
            modelChip.isHidden = true
        }
        if let thinking = option(AgentChatConfigOption.thinkingCategory) {
            traitsChip.isHidden = chipCompaction >= 1
            let title = ConfigOptionMenuContent.title(thinking.currentName)
            traitsChip.configure(title: title, image: nil)
            traitsChip.toolTip = "\(thinking.name): \(title)"
            traitsChip.setAccessibilityLabel(traitsChip.toolTip)
        } else {
            traitsChip.isHidden = true
        }
        if let mode = option(AgentChatConfigOption.modeCategory) {
            permissionsChip.isHidden = chipCompaction >= 2
            permissionsChip.configure(title: mode.currentName, image: NSImage.symbol(ComposerIcon.lock, size: 13))
            permissionsChip.toolTip = "\(mode.name): \(mode.currentName)" + (mode.currentValueEntry?.detail.map { ". \($0)" } ?? "")
            permissionsChip.setAccessibilityLabel("\(mode.name): \(mode.currentName)")
        } else {
            permissionsChip.isHidden = true
        }
        // Settings change only while the agent runs.
        for chip in [modelChip, traitsChip, permissionsChip] { chip.isEnabled = session.isRunning }
        modelChip.isOpen = popoverKind == .model
        traitsChip.isOpen = popoverKind == .traits
        permissionsChip.isOpen = popoverKind == .permissions
    }

    private func updatePrimary() {
        let canSteer = session.supportsSteering
        if let request = pendingInput, questionRequestID == request.id, let draft = answers[request.id] {
            let isLast = draft.index >= request.questions.count - 1
            previousButton.isHidden = draft.index == 0
            answerButton.isHidden = false
            answerButton.title = !isLast ? "Next question" : (draft.index > 0 ? "Submit answers" : "Submit answer")
            answerButton.isEnabled = isLast ? isComplete(draft, request) : !answer(for: draft.index, draft, request).isEmpty
            primaryButton.isHidden = session.phase != .working
            primaryButton.update(.stop, tooltip: ComposerPrimaryAction.stop.tooltip(agentName: agentName, canSteer: canSteer), stopping: isStopping)
            return
        }
        previousButton.isHidden = true
        answerButton.isHidden = true
        primaryButton.isHidden = false
        let action = ComposerPrimaryAction.resolve(
            isStopped: isStopped,
            isRunning: session.phase == .working,
            hasContent: hasContent,
            isAwaitingApproval: permission != nil,
            canSteer: canSteer,
            alternate: isAlternateHeld
        )
        primaryButton.update(action, tooltip: action.tooltip(agentName: agentName, canSteer: canSteer), stopping: action == .stop && isStopping)
    }

    /// Stop was pressed and the agent has not ended the turn yet.
    private var isStopping: Bool {
        session.thread.activeTurn?.stopRequestedAt != nil
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
        if let requestID = questionRequestID, var draft = answers[requestID], let request = pendingInput,
           let question = currentQuestion(draft, in: request) {
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
        guard questionRequestID == nil else { return false }
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
            session.cancel()
            return
        }
        submit(alternate: NSApp.currentEvent?.modifierFlags.contains(.command) == true)
    }

    /// Return / the send button. `alternate` (⌘) steers instead of queueing while a turn runs.
    func submit(alternate: Bool) {
        if isStopped {
            onRestartRequested?()
            return
        }
        if questionRequestID != nil {
            advanceQuestion()
            return
        }
        let text = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let permission, let decline = permission.options.declineOption {
            // Decline, then deliver the message: it redirects the turn the agent continues.
            session.choosePermissionOption(decline.id)
            guard session.steer(text) else { return }
        } else if alternate, session.phase == .working {
            guard session.steer(text) else { return }
        } else {
            guard session.send(text) else { return }
        }
        editor.textView.setText("")
        history.reset()
        updatePrimary()
        onSubmitted?()
    }

    /// Escape: closes the `/` menu or a popover, else stops the running turn.
    private func escape() -> Bool {
        if slashMenu != nil {
            dismissSlashMenu()
            return true
        }
        if popover != nil {
            closePopover()
            return true
        }
        guard session.phase == .working else { return false }
        session.cancel()
        return true
    }

    // MARK: Questions

    private func currentQuestion(_ draft: AnswerDraft, in request: UserInputRequest) -> UserInputQuestion? {
        request.questions.indices.contains(draft.index) ? request.questions[draft.index] : nil
    }

    /// Typed text wins over selected options.
    private func answer(for index: Int, _ draft: AnswerDraft, _ request: UserInputRequest) -> [String] {
        guard request.questions.indices.contains(index) else { return [] }
        let question = request.questions[index]
        let custom = (draft.custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty, question.allowsOther { return [custom] }
        return draft.selections[question.id] ?? []
    }

    private func isComplete(_ draft: AnswerDraft, _ request: UserInputRequest) -> Bool {
        request.questions.indices.allSatisfy { !answer(for: $0, draft, request).isEmpty }
    }

    /// Enters, follows or leaves question mode as the agent's questions come and go.
    private func updateQuestion() {
        guard let question else {
            questionPanel.isHidden = true
            shownQuestion = nil
            if questionRequestID != nil {
                questionRequestID = nil
                editor.textView.setText(stashedText ?? "")
                stashedText = nil
            }
            return
        }
        if question != shownQuestion {
            shownQuestion = question
            questionCount += 1
        }
        guard let request = pendingInput else { return }
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
            selected: custom.isEmpty || !question.allowsOther ? Set(draft.selections[question.id] ?? []) : [],
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
        let requestID = request.id
        autoAdvance = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            // A later question set keeps its own question.
            guard !Task.isCancelled, let self, pendingInput?.id == requestID else { return }
            advanceQuestion()
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
        guard let question, let request = pendingInput, let draft = answers[request.id] else { return }
        if draft.index < request.questions.count - 1 {
            guard !answer(for: draft.index, draft, request).isEmpty else { return }
            moveQuestion(by: 1)
            return
        }
        guard isComplete(draft, request) else { return }
        var result: [String: [String]] = [:]
        for (index, item) in request.questions.enumerated() {
            result[item.id] = answer(for: index, draft, request)
        }
        session.answerQuestion(question.content(for: result))
    }

    // MARK: Keys

    /// The `/` menu's keys first; digits 1–9 pick a question's option while the editor is empty.
    private func handleMenuKey(_ event: NSEvent) -> Bool {
        if handleSlashKey(event) { return true }
        guard questionRequestID != nil, editorText.isEmpty,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let digit = event.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit)
        else { return false }
        toggleOption(digit - 1)
        return true
    }

    // MARK: Settings menus

    private func toggleOptionMenu(_ kind: PopoverKind) {
        guard popoverKind != kind else { return closePopover() }
        let anchor: ComposerChip
        let content: ComposerPopoverContent
        let setValue: (String) -> Void
        switch kind {
        case .model:
            guard let option = option(AgentChatConfigOption.modelCategory) else { return }
            setValue = { [weak self] in self?.session.setConfigOption(option.id, to: $0) }
            content = ModelPickerContent(option: option, agentName: agentName, onSelect: setValue)
            anchor = modelChip
        case .traits:
            guard let option = option(AgentChatConfigOption.thinkingCategory) else { return }
            setValue = { [weak self] in self?.session.setConfigOption(option.id, to: $0) }
            content = ConfigOptionMenuContent(option: option, onSelect: setValue)
            anchor = traitsChip
        case .permissions:
            guard let option = option(AgentChatConfigOption.modeCategory) else { return }
            setValue = { [weak self] in self?.session.setConfigOption(option.id, to: $0) }
            content = ConfigOptionMenuContent(option: option, onSelect: setValue)
            anchor = permissionsChip
        case .context:
            return
        }
        present(kind, content: content, anchor: anchor, alignment: .leading) { [weak anchor] open in
            anchor?.isOpen = open
        }
    }

    // MARK: Context meter

    private var contextReading: ContextMeterReading? {
        ContextMeterReading(used: session.contextUsage?.used, size: session.contextUsage?.size)
    }

    private func refreshMeter() {
        let reading = contextReading
        contextMeter.update(reading)
        contextCard?.update(reading, canCompact: session.canCompact, isCompacting: false)
    }

    /// The meter's card: usage, what compacting does, "Compact conversation".
    private func toggleContextCard() {
        guard popoverKind != .context else { return closePopover() }
        let content = ContextMeterCardContent { [weak self] in
            self?.session.compact()
            self?.closePopover()
        }
        content.update(contextReading, canCompact: session.canCompact, isCompacting: false)
        contextCard = content
        present(.context, content: content, anchor: contextMeter, alignment: .trailing) { [weak self] open in
            self?.contextMeter.isOpen = open
        }
    }

    // MARK: Slash commands

    /// Opens, filters or closes the `/` menu for the token at the caret.
    private func syncSlashMenu() {
        let textView = editor.textView
        let caret = textView.selectedRange()
        let token = questionRequestID == nil && permission == nil && caret.length == 0
            ? SlashToken.at(textView.string, caret: caret.location)
            : nil
        guard let token else {
            slashDismissed = false
            closeSlashMenu()
            return
        }
        // Text the composer put there (history) never opens the menu.
        if textView.isSettingText { slashDismissed = true }
        guard !slashDismissed, window?.firstResponder === textView else {
            closeSlashMenu()
            return
        }
        guard token != slashToken || slashMenu == nil else { return }
        slashToken = token
        showSlashMenu()
    }

    /// Shows the menu for `slashToken`, or re-lists it in place when it already shows;
    /// `keepingHighlight` (an update, the query unchanged) keeps the highlighted command.
    private func showSlashMenu(keepingHighlight: Bool = false) {
        guard let token = slashToken else { return }
        let commands = session.commands
        let matches = SlashCommandFilter.matching(commands, query: token.query)
        let emptyText = SlashCommandFilter.emptyText(agentName: agentName, hasCandidates: !commands.isEmpty, query: token.query)
        if slashMenu != nil, let slashContent {
            slashContent.show(matches, emptyText: emptyText, keepingHighlight: keepingHighlight)
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
        // Another of the app's windows taking the keyboard (palette, dialog, settings) closes the menu.
        slashKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self, weak window, weak menu] note in
            let keyWindow = note.object as? NSWindow
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

    /// Escape, or Return/Tab with nothing to pick: hide the menu until the caret leaves the token.
    private func dismissSlashMenu() {
        slashDismissed = true
        closeSlashMenu()
    }

    /// ↑/↓ move, Return/Tab insert, Escape closes; anything else goes to the editor.
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
    private func insertCommand(_ command: AgentChatCommand) {
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
        popover.show(anchoredTo: anchor, side: .above, alignment: alignment)
    }

    private func closePopover() {
        popover?.close()
    }
}
