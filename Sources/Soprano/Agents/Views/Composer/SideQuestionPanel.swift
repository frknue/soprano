import AppKit
import SopranoAgentsCore

/// Composer text that is a side question: `/btw <question>` asks it, `/btw` alone opens the panel.
enum SideQuestionCommand: Equatable {
    case open
    case ask(String)

    static let prefix = "/btw"

    /// nil for anything else (`/btwx`, text before the command).
    static func parse(_ text: String) -> SideQuestionCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix) else { return nil }
        let rest = trimmed.dropFirst(prefix.count)
        if let first = rest.first, !first.isWhitespace { return nil }
        let question = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return question.isEmpty ? .open : .ask(question)
    }
}

/// The side-question panel above the composer (`thread.sideQuestion`, `/btw`): a key-taking
/// composer popover at the composer's width.
///
/// ```
/// ┌ ‹  Side question · Not added to the thread                         × ┐
/// │ list of topics (newest first)  ─or─  the selected topic's exchanges   │
/// │ error line                                                            │
/// │ Ask a side question… / Ask a follow-up…                  Stop  Copy   │
/// └───────────────────────────────────────────────────────────────────────┘
/// ```
/// Without a selected topic it lists the thread's side questions (or a hint when there are
/// none) and the field asks a new one; a selected topic shows its questions and streamed answers
/// and the field asks a follow-up. Escape stops a running answer, else closes the panel.
final class SideQuestionPanelContent: ComposerPopoverContent, NSTextFieldDelegate {
    static let transcriptMaxHeight: CGFloat = 360
    private static let padding: CGFloat = 14

    private let backButton = GhostIconButton(symbol: "chevron.left", size: 24, symbolSize: 12, toolTip: "All side questions")
    private let titleLabel = NSTextField.label("Side question", size: Typography.rowSize, weight: .medium)
    private let subtitleLabel = NSTextField.label("Not added to the thread", size: Typography.smallSize)
    private let closeButton = GhostIconButton(symbol: Icon.close, size: 24, symbolSize: 12, toolTip: "Close side questions")
    private let topDivider = ComposerDivider()
    private let hintLabel = ComposerWrappingLabel.make(size: Typography.rowSize)
    private let historyList = ComposerListView(maxHeight: 288)
    private let transcriptScroll = NSScrollView()
    private let transcript = SideQuestionTranscriptView()
    private var transcriptHeight: NSLayoutConstraint?
    private let errorLabel = ComposerWrappingLabel.make(size: Typography.smallSize)
    private let hintBox = NSView()
    private let transcriptBox = NSView()
    private let errorBox = NSView()
    private let bottomDivider = ComposerDivider()
    private let field = NSTextField()
    private let stopButton = TextButton("Stop", symbol: Icon.stop, variant: .outline, size: .xs)
    private let copyButton = TextButton("Copy", symbol: Icon.copy, variant: .ghost, size: .xs)
    private var widthConstraint: NSLayoutConstraint?
    private var wrappingLabels: [ComposerWrappingLabel] { [hintLabel, errorLabel] }

    private(set) var topics: [SideQuestion] = []
    private(set) var selectedTopicID: String?
    /// A question sent and not reported by the provider yet (shown answering), and how many
    /// exchanges the selected topic has once it is reported.
    private var pendingQuestion: String?
    private var pendingExchanges = 1
    private var isLoading = false
    /// The thread has a question starting (maybe asked from an earlier panel).
    private var isStarting = false

    /// Enter in the field: the question and the topic it follows up (nil = a new topic).
    var onAsk: ((String, _ topicID: String?) -> Void)?
    /// Stop / Escape while an answer runs.
    var onCancel: (() -> Void)?

    override var initialFocus: NSView? { field }

    init(width: CGFloat) {
        super.init(frame: .zero)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Typography.ui(Typography.bodySize)
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.target = self
        field.action = #selector(submit)
        field.setAccessibilityLabel("Side question")

        transcriptScroll.documentView = transcript
        transcriptScroll.drawsBackground = false
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.scrollerStyle = .overlay
        transcriptScroll.automaticallyAdjustsContentInsets = false

        let header = NSStackView(views: [backButton, titleLabel, subtitleLabel, NSView(), closeButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.setCustomSpacing(8, after: titleLabel)
        header.fillsWidth()
        subtitleLabel.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let footer = NSStackView(views: [field, stopButton, copyButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 6
        footer.fillsWidth()
        field.setContentHuggingPriority(.init(1), for: .horizontal)

        let padded = NSEdgeInsets(top: 0, left: Self.padding, bottom: 0, right: Self.padding)
        Self.pad(hintLabel, in: hintBox, NSEdgeInsets(top: 14, left: Self.padding, bottom: 14, right: Self.padding))
        Self.pad(transcriptScroll, in: transcriptBox, NSEdgeInsets(top: 0, left: Self.padding, bottom: 0, right: 6))
        Self.pad(errorLabel, in: errorBox, NSEdgeInsets(top: 0, left: Self.padding, bottom: 8, right: Self.padding))
        let headerBox = NSView()
        let footerBox = NSView()
        Self.pad(header, in: headerBox, NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8))
        Self.pad(footer, in: footerBox, NSEdgeInsets(top: 8, left: padded.left, bottom: 8, right: 10))
        errorBox.isHidden = true
        let column = ComposerColumn([headerBox, topDivider, hintBox, historyList, transcriptBox, errorBox, bottomDivider, footerBox])
        addSubview(column)
        let width = widthAnchor.constraint(equalToConstant: width)
        widthConstraint = width
        let height = transcriptScroll.heightAnchor.constraint(equalToConstant: 0)
        transcriptHeight = height
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,
            height,
            field.heightAnchor.constraint(equalToConstant: 24),
        ])
        backButton.onClick = { [weak self] in self?.showList() }
        closeButton.onClick = { [weak self] in self?.requestClose?() }
        stopButton.onClick = { [weak self] in self?.onCancel?() }
        copyButton.onClick = { [weak self] in self?.copyAnswer() }
        setAccessibilityLabel("Side questions")
        updateWidths(width.constant)
        render()
    }

    /// Pins `view` inside `box` with `insets`; the column stretches the box to its width and
    /// hides it with its padding.
    private static func pad(_ view: NSView, in box: NSView, _ insets: NSEdgeInsets) {
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -insets.right),
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: insets.top),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -insets.bottom),
        ])
    }

    func setWidth(_ width: CGFloat) {
        guard let widthConstraint, abs(widthConstraint.constant - width) > 0.5 else { return }
        widthConstraint.constant = width
        updateWidths(width)
        render()
    }

    private func updateWidths(_ width: CGFloat) {
        for label in wrappingLabels { label.preferredMaxLayoutWidth = width - Self.padding * 2 }
    }

    // MARK: State

    /// The thread's topics (newest first) and whether its history is still being read.
    func update(_ topics: [SideQuestion], isLoading: Bool, isStarting: Bool) {
        self.topics = topics
        self.isLoading = isLoading
        self.isStarting = isStarting
        clearReportedPending()
        render()
    }

    /// Shows topic `id` (a question just asked, or one picked from the list); nil = the list.
    func select(_ id: String?) {
        selectedTopicID = id
        clearReportedPending()
        render(scrollToEnd: true)
    }

    /// The pending question is reported: the selected topic reached its exchange count.
    private func clearReportedPending() {
        if pendingQuestion != nil, let topic = selectedTopic, topic.exchanges.count >= pendingExchanges { pendingQuestion = nil }
    }

    /// The question went out (a follow-up of the selected topic, else a new topic); it shows as
    /// answering until the provider reports it.
    func setPending(_ question: String?) {
        pendingQuestion = question
        pendingExchanges = (selectedTopic?.exchanges.count ?? 0) + 1
        if question != nil { showError(nil) }
        render(scrollToEnd: true)
    }

    func showError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorBox.isHidden = message == nil
        requestResize?()
    }

    private func topic(_ id: String?) -> SideQuestion? {
        id.flatMap { id in topics.first { $0.id == id } }
    }

    private var selectedTopic: SideQuestion? { topic(selectedTopicID) }

    var isAnswering: Bool { pendingQuestion != nil || isStarting || topics.contains(where: \.isRunning) }

    // MARK: Rendering

    private func render(scrollToEnd: Bool = false) {
        let topic = selectedTopic
        let showsTopic = selectedTopicID != nil || pendingQuestion != nil
        backButton.isHidden = !showsTopic
        hintBox.isHidden = showsTopic || !topics.isEmpty
        hintLabel.stringValue = isLoading
            ? "Reading this thread’s side questions…"
            : "Ask about this thread without steering it. The agent keeps working, and neither the question nor the answer joins the conversation."
        historyList.isHidden = showsTopic || topics.isEmpty
        transcriptBox.isHidden = !showsTopic
        if showsTopic {
            renderTranscript(topic, scrollToEnd: scrollToEnd)
        } else if !topics.isEmpty {
            renderList()
        }
        field.placeholderString = topic == nil ? "Ask a side question…" : "Ask a follow-up…"
        stopButton.isHidden = !isAnswering
        let answer = topic?.exchanges.last(where: { !$0.answer.isEmpty })?.answer
        copyButton.isHidden = answer == nil
        applyPalette(palette)
        requestResize?()
    }

    private func renderList() {
        let now = Date()
        let rows = topics.map { topic in
            let latest = topic.latest
            let count = topic.followUps.isEmpty ? nil : "\(topic.exchanges.count) questions"
            let state: String? = switch latest.status {
            case .running: "Answering…"
            case .complete: nil
            case .cancelled: "Cancelled"
            case .failed: "Failed"
            case .interrupted: "Interrupted"
            }
            // The answer's first line, without inline-code backticks.
            let preview = latest.answer.split(whereSeparator: \.isNewline).first.map { $0.replacingOccurrences(of: "`", with: "") }
            return ComposerListRow.Model(
                title: topic.first.question,
                subtitle: [state, preview].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                trailingNote: [count, DurationText.relative(latest.updatedAt, now: now)].compactMap { $0 }.joined(separator: " · "),
                toolTip: topic.first.question,
                subtitleLines: 1
            )
        }
        let actions: [() -> Void] = topics.map { topic in { [weak self] in self?.select(topic.id) } }
        historyList.setRows(rows, actions: actions, highlight: historyList.highlightedIndex ?? 0)
    }

    private func renderTranscript(_ topic: SideQuestion?, scrollToEnd: Bool) {
        let clip = transcriptScroll.contentView
        let wasAtEnd = clip.bounds.maxY >= transcript.frame.height - 4
        var exchanges = topic?.exchanges ?? []
        if let pendingQuestion, exchanges.count < pendingExchanges {
            exchanges.append(SideQuestionExchange(question: pendingQuestion, status: .running, createdAt: Date()))
        }
        let width = max(0, (widthConstraint?.constant ?? 0) - Self.padding - 6)
        let height = transcript.show(exchanges, width: width - 8)
        transcriptHeight?.constant = min(height, Self.transcriptMaxHeight)
        if scrollToEnd || wasAtEnd {
            layoutSubtreeIfNeeded()
            transcript.scroll(NSPoint(x: 0, y: max(0, transcript.frame.height - clip.bounds.height)))
        }
    }

    // MARK: Actions

    private func showList() {
        selectedTopicID = nil
        pendingQuestion = nil
        render()
        window?.makeFirstResponder(field)
    }

    @objc private func submit() {
        let question = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            if selectedTopicID == nil, !historyList.isHidden { _ = historyList.chooseHighlighted() }
            return
        }
        field.stringValue = ""
        onAsk?(question, selectedTopicID)
    }

    /// Puts a question the provider refused back into the field (unless something new was typed).
    func restore(_ question: String) {
        if field.stringValue.isEmpty { field.stringValue = question }
    }

    private func copyAnswer() {
        guard let answer = selectedTopic?.exchanges.last(where: { !$0.answer.isEmpty })?.answer else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(answer, forType: .string)
    }

    override func handleKey(_ event: NSEvent) -> Bool {
        let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
        switch event.keyCode {
        case 53:
            if isAnswering {
                onCancel?()
                return true
            }
            return super.handleKey(event)
        case 125 where plain && !historyList.isHidden:
            historyList.moveHighlight(by: 1)
            return true
        case 126 where plain && !historyList.isHidden:
            historyList.moveHighlight(by: -1)
            return true
        default:
            return false
        }
    }

    override func applyPalette(_ palette: Palette) {
        titleLabel.textColor = palette.foreground
        subtitleLabel.textColor = palette.mutedForeground
        hintLabel.textColor = palette.mutedForeground
        errorLabel.textColor = palette.errorForeground
        field.textColor = palette.foreground
        transcript.applyPalette(palette)
    }
}

/// The selected topic's exchanges: each question (medium, foreground), then its answer as
/// Markdown, "Thinking…" while nothing streamed yet, and a muted status line when it did not
/// complete. Laid out in frames at the given width.
final class SideQuestionTranscriptView: PaletteView {
    private struct Block {
        let question: NSTextField
        let answer: MarkdownView?
        let note: NSTextField?
        let isError: Bool
    }

    private var blocks: [Block] = []

    /// Rebuilds for `exchanges` at `width`; returns the height.
    func show(_ exchanges: [SideQuestionExchange], width: CGFloat) -> CGFloat {
        subviews.forEach { $0.removeFromSuperview() }
        blocks = exchanges.map { exchange in
            let question = ComposerWrappingLabel.make(size: Typography.bodySize, weight: .medium)
            question.stringValue = exchange.question
            question.isSelectable = true
            var answer: MarkdownView?
            if !exchange.answer.isEmpty {
                let view = MarkdownView()
                view.apply(MarkdownRenderer.render(exchange.answer, style: .assistant))
                answer = view
            }
            let noteText: String? = switch exchange.status {
            case .running: exchange.answer.isEmpty ? "Thinking…" : nil
            case .complete: exchange.answer.isEmpty ? "No answer." : nil
            case .cancelled: "Cancelled"
            case .interrupted: "Interrupted"
            case .failed: exchange.error.map { "Failed: \($0)" } ?? "Failed"
            }
            let note = noteText.map { NSTextField.label($0, size: Typography.smallSize) }
            return Block(question: question, answer: answer, note: note, isError: exchange.status == .failed)
        }
        var y: CGFloat = 12
        for (index, block) in blocks.enumerated() {
            if index > 0 { y += 18 }
            addSubview(block.question)
            block.question.preferredMaxLayoutWidth = width
            let questionHeight = ceil(block.question.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)).height ?? 18)
            block.question.frame = NSRect(x: 0, y: y, width: width, height: questionHeight)
            y += questionHeight
            if let answer = block.answer {
                y += 6
                addSubview(answer)
                let height = answer.layoutMarkdown(width: width)
                answer.frame.origin = NSPoint(x: 0, y: y)
                y += height
            }
            if let note = block.note {
                y += 6
                addSubview(note)
                note.frame = NSRect(x: 0, y: y, width: width, height: 16)
                y += 16
            }
        }
        y += 12
        frame.size = NSSize(width: width, height: ceil(y))
        applyPalette(palette)
        return ceil(y)
    }

    override func applyPalette(_ palette: Palette) {
        for block in blocks {
            block.question.textColor = palette.foreground
            block.note?.textColor = block.isError ? palette.errorForeground : palette.mutedForeground
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
