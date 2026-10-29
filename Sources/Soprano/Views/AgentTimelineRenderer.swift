import AppKit

/// What an agent is doing right now, in one line, for its dashboard row and
/// the activity line above the detail view's reply field: an optional
/// call-state glyph, a lead (tool name or short phrase), the tool's subject
/// in mono, a plain detail and the time it has been going.
struct AgentTimelineActivity: Equatable {
    enum Tone: Equatable {
        case working
        case waiting
        case idle
        case failed
    }

    /// ▶ ✓ ✗ ⊘ for a tool call.
    var glyph: String? = nil
    /// A tool name or a short phrase: "Thinking", "Asks", "Replied".
    let title: String
    /// The tool's subject: a command, path or pattern.
    var code: String? = nil
    /// The first line of a reply.
    var detail: String? = nil
    /// How long it has been going: `38s`.
    var elapsed: String? = nil
    let tone: Tone

    /// The whole line as plain text: `▶ Bash · swift test · 38s`.
    var text: String {
        var parts = [glyph.map { "\($0) \(title)" } ?? title]
        parts += [code, detail, elapsed].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    static func current(
        in timeline: AgentTimeline?,
        status: AgentStatus,
        now: Date = Date()
    ) -> AgentTimelineActivity? {
        guard let timeline, let last = timeline.items.last else { return nil }
        let lastPrompt = timeline.items.lastIndex(where: \.isPrompt) ?? -1
        let running = timeline.items.indices.last { index in
            index > lastPrompt && timeline.items[index].toolCall?.state == .running
        }.map { timeline.items[$0] }

        switch status {
        case .running, .starting:
            if let running, let call = running.toolCall {
                return AgentTimelineActivity(
                    glyph: AgentTimelineRenderer.glyph(for: .running),
                    title: call.name,
                    code: Self.subject(of: call),
                    elapsed: Self.since(running.timestamp, now: now),
                    tone: .working
                )
            }
            switch last.kind {
            case .prompt, .thinking:
                return AgentTimelineActivity(title: "Thinking", elapsed: Self.since(last.timestamp, now: now), tone: .working)
            case .reply:
                return AgentTimelineActivity(title: "Writing", elapsed: Self.since(last.timestamp, now: now), tone: .working)
            case .tool(let call):
                return AgentTimelineActivity(
                    glyph: AgentTimelineRenderer.glyph(for: call.state),
                    title: call.name,
                    code: Self.subject(of: call),
                    tone: .working
                )
            case .notice(let text, let isError):
                return AgentTimelineActivity(title: AgentTimeline.firstLine(text), tone: isError ? .failed : .working)
            }
        case .waiting:
            if let running, let call = running.toolCall {
                return AgentTimelineActivity(title: "Approve \(call.name)?", code: Self.subject(of: call), tone: .waiting)
            }
            if let reply = Self.lastReply(in: timeline) {
                return AgentTimelineActivity(title: "Asks", detail: AgentTimeline.firstLine(reply), tone: .waiting)
            }
            return AgentTimelineActivity(title: "Waiting for input", tone: .waiting)
        case .error:
            let notice = timeline.items.last { item in
                if case .notice(_, true) = item.kind { return true }
                return false
            }
            if case .notice(let text, _)? = notice?.kind {
                return AgentTimelineActivity(title: AgentTimeline.firstLine(text), tone: .failed)
            }
            return AgentTimelineActivity(title: "Stopped with an error", tone: .failed)
        case .idle, .stopped:
            if let reply = Self.lastReply(in: timeline) {
                return AgentTimelineActivity(title: "Replied", detail: AgentTimeline.firstLine(reply), tone: .idle)
            }
            return nil
        }
    }

    /// The line in chrome type: the lead in `titleFont`, the subject in
    /// `codeFont` and `codeColor`, the elapsed time with tabular digits,
    /// joined by ` · ` and truncated at the tail, never wrapped. `compact`
    /// (agent rows, which show their own status and time) leaves out the
    /// glyph and the elapsed time.
    func attributed(
        font: NSFont,
        titleFont: NSFont,
        codeFont: NSFont,
        color: NSColor,
        codeColor: NSColor,
        compact: Bool = false
    ) -> NSAttributedString {
        let line = NSMutableAttributedString()
        func append(_ string: String, _ font: NSFont, _ color: NSColor) {
            line.append(NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color]))
        }
        if let glyph, !compact {
            append(glyph + " ", font, color)
        }
        append(title, titleFont, color)
        if let code {
            append(" · ", font, color)
            append(code, codeFont, codeColor)
        }
        if let detail {
            append(" · ", font, color)
            append(detail, font, color)
        }
        if let elapsed, !compact {
            append(" · ", font, color)
            append(elapsed, ChromeFont.sans(size: font.pointSize, tabular: true), color)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return line
    }

    private static func subject(of call: AgentToolCall) -> String? {
        call.summary.isEmpty ? nil : call.summary
    }

    private static func lastReply(in timeline: AgentTimeline) -> String? {
        for item in timeline.items.reversed() {
            if item.isPrompt { return nil }
            if case .reply(let text) = item.kind { return text }
        }
        return nil
    }

    private static func since(_ start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        return AgentTimelineRenderer.duration(max(0, now.timeIntervalSince(start)))
    }
}

/// Lays out an agent's timeline as attributed text for the dashboard, as a
/// conversation: prompts as `You` cards, each answer under the agent's name,
/// replies rendered as Markdown, and every run of tool calls in one hairline
/// card with a line per call (state glyph, name, mono subject, muted meta,
/// diffstat) and its diff in a nested box. Notices sit centered between them.
/// The text view showing it must use TextKit 1, which draws the `NSTextBlock`
/// boxes.
@MainActor
final class AgentTimelineRenderer {
    struct Output {
        let text: NSAttributedString
        /// Where each prompt starts, so the dashboard can jump between turns.
        let turnStarts: [Int]
    }

    /// Diff lines a compact timeline shows per tool call.
    static let compactDiffLines = 12
    /// Output lines a compact timeline shows for a failed tool call.
    static let compactFailureLines = 6
    /// Characters of a prompt shown before it is cut.
    static let promptCharacterLimit = 2_000
    /// Tool calls quicker than this show no duration; every read would say 0.0s.
    static let shownDuration: TimeInterval = 1

    /// Glyphs sit centered in a 20 pt column; text starts 6 pt after it.
    private static let glyphColumn: CGFloat = 20
    private static let textInset: CGFloat = 26
    /// Tool names take at least this width before their subject.
    private static let nameMinimumWidth: CGFloat = 56
    private static let gap: CGFloat = 10
    /// Space between timeline items.
    private static let itemSpacing: CGFloat = 12
    /// Space between the lines of one tool card.
    private static let groupSpacing: CGFloat = 6
    private static let lineHeight: CGFloat = 18
    /// Diff rows: 48 pt gutter, 18 pt marker column, then the code.
    private static let diffRowHeight: CGFloat = 18
    private static let diffGutter: CGFloat = 48
    private static let diffCode: CGFloat = 66

    private(set) var colors: ThemeColors
    private var replyCache: [String: (markdown: String, text: NSAttributedString)] = [:]

    init(colors: ThemeColors) {
        self.colors = colors
    }

    func apply(colors: ThemeColors) {
        self.colors = colors
        replyCache.removeAll()
    }

    /// `isAgentActive` tells whether calls without a result are still running;
    /// once the agent is idle or gone they were cut short. `agentName` heads
    /// each answer, so the timeline reads as a conversation.
    func render(
        _ timeline: AgentTimeline,
        detailed: Bool,
        isAgentActive: Bool,
        agentName: String? = nil
    ) -> Output {
        let output = NSMutableAttributedString()
        var turnStarts: [Int] = []
        var shownReplies = Set<String>()
        /// The card the current run of tool calls and thinking shares.
        var group: RoundedTextBlock?
        /// Whether the next agent item starts an answer and gets the name.
        var startsAnswer = true

        func closeGroup() {
            guard group != nil else { return }
            trimTrailingSpacing(of: output)
            group = nil
        }
        func beginAgentItem(_ timestamp: Date?) {
            guard startsAnswer else { return }
            startsAnswer = false
            if let agentName {
                appendAuthor(agentName, timestamp: timestamp, to: output)
            }
        }
        func openGroup() -> RoundedTextBlock {
            if let group { return group }
            let block = groupBlock()
            group = block
            return block
        }

        if timeline.items.isEmpty {
            appendNotice("No messages yet.", isError: false, to: output)
        }
        for item in timeline.items {
            switch item.kind {
            case .prompt(let text):
                closeGroup()
                turnStarts.append(output.length)
                appendPrompt(text, timestamp: item.timestamp, to: output)
                startsAnswer = true
            case .reply(let markdown):
                closeGroup()
                beginAgentItem(item.timestamp)
                shownReplies.insert(item.id)
                appendReply(markdown, id: item.id, to: output)
            case .thinking(let text):
                beginAgentItem(item.timestamp)
                appendThinking(text, detailed: detailed, group: openGroup(), to: output)
            case .tool(var call):
                if call.state == .running, !isAgentActive {
                    call.state = .interrupted
                }
                beginAgentItem(item.timestamp)
                appendTool(call, startedAt: item.timestamp, detailed: detailed, group: openGroup(), to: output)
            case .notice(let text, let isError):
                closeGroup()
                appendNotice(text, isError: isError, to: output)
            }
        }
        closeGroup()
        replyCache = replyCache.filter { shownReplies.contains($0.key) }
        return Output(text: output, turnStarts: turnStarts)
    }

    // MARK: - Items

    /// `You` card: panel fill, radius 8, ink label and muted time over the
    /// prompt in 13/19, set apart from the answer before it. No accent.
    private func appendPrompt(_ text: String, timestamp: Date?, to output: NSMutableAttributedString) {
        let block = RoundedTextBlock(radius: Chrome.Radius.card)
        block.backgroundColor = colors.bgPanel
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(14, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(Self.itemSpacing, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(Self.itemSpacing + 4, type: .absoluteValueType, for: .margin, edge: .maxY)

        let header = speakerLine("You", timestamp: timestamp)
        header.addAttribute(
            .paragraphStyle,
            value: paragraph(blocks: [block], spacing: 4),
            range: NSRange(location: 0, length: header.length)
        )
        output.append(header)

        var shown = text
        if shown.count > Self.promptCharacterLimit {
            shown = String(shown.prefix(Self.promptCharacterLimit)) + " …"
        }
        output.append(NSAttributedString(
            string: shown + "\n",
            attributes: [
                .font: ChromeFont.row,
                .foregroundColor: colors.textPrimary,
                .paragraphStyle: paragraph(blocks: [block], lineHeight: 19),
            ]
        ))
    }

    /// The agent's name and the time over its answer, like the `You` label
    /// over a prompt.
    private func appendAuthor(_ name: String, timestamp: Date?, to output: NSMutableAttributedString) {
        let line = speakerLine(name, timestamp: timestamp)
        line.addAttribute(
            .paragraphStyle,
            value: paragraph(spacing: 6),
            range: NSRange(location: 0, length: line.length)
        )
        output.append(line)
    }

    /// `Name  14:32`: the name in ink, the time muted, then a line break.
    private func speakerLine(_ name: String, timestamp: Date?) -> NSMutableAttributedString {
        let line = NSMutableAttributedString(
            string: name,
            attributes: [.font: ChromeFont.labelStrong, .foregroundColor: colors.textPrimary]
        )
        if let timestamp {
            line.append(gap(8, after: ChromeFont.labelStrong))
            line.append(NSAttributedString(
                string: Self.timeFormatter.string(from: timestamp),
                attributes: [.font: ChromeFont.count, .foregroundColor: colors.textMuted]
            ))
        }
        line.append(NSAttributedString(string: "\n", attributes: [.font: ChromeFont.labelStrong]))
        return line
    }

    private func appendReply(_ markdown: String, id: String, to output: NSMutableAttributedString) {
        let rendered: NSAttributedString
        if let cached = replyCache[id], cached.markdown == markdown {
            rendered = cached.text
        } else {
            rendered = AgentMarkdownRenderer.render(markdown, colors: colors, fontSize: ChromeFont.row.pointSize)
            replyCache[id] = (markdown, rendered)
        }
        output.append(rendered)
        output.append(NSAttributedString(
            string: "\n",
            attributes: [.font: ChromeFont.row, .paragraphStyle: paragraph(spacing: Self.itemSpacing)]
        ))
    }

    /// `▸ Thinking` in muted italic in the tool card; detailed timelines show
    /// the whole text.
    private func appendThinking(
        _ text: String,
        detailed: Bool,
        group: RoundedTextBlock,
        to output: NSMutableAttributedString
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: ChromeFont.row,
            .foregroundColor: colors.textMuted,
            .obliqueness: 0.15,
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = detailed && !trimmed.isEmpty
        let summary = expanded
            ? "Thinking"
            : (trimmed.isEmpty ? "Thinking" : AgentTimeline.firstLine(trimmed, limit: 140))
        let line = NSMutableAttributedString()
        line.append(glyph(expanded ? "▾" : "▸", color: colors.textMuted))
        line.append(NSAttributedString(string: summary + "\n", attributes: attributes))
        line.addAttribute(
            .paragraphStyle,
            value: itemParagraph(
                glyph: expanded ? "▾" : "▸",
                spacing: expanded ? 4 : Self.groupSpacing,
                blocks: [group]
            ),
            range: NSRange(location: 0, length: line.length)
        )
        output.append(line)
        if expanded {
            output.append(NSAttributedString(
                string: trimmed + "\n",
                attributes: attributes.merging([
                    .paragraphStyle: paragraph(blocks: [group], spacing: Self.groupSpacing, indent: Self.textInset),
                ]) { $1 }
            ))
        }
    }

    private func appendTool(
        _ call: AgentToolCall,
        startedAt: Date?,
        detailed: Bool,
        group: RoundedTextBlock,
        to output: NSMutableAttributedString
    ) {
        let nameFont = ChromeFont.sans(size: 13, weight: .medium)
        let line = NSMutableAttributedString()
        let glyphText = Self.glyph(for: call.state)
        line.append(glyph(glyphText, color: color(for: call.state)))
        line.append(NSAttributedString(
            string: call.name,
            attributes: [.font: nameFont, .foregroundColor: colors.textPrimary]
        ))
        let nameWidth = ceil((call.name as NSString).size(withAttributes: [.font: nameFont]).width)
        line.append(gap(max(0, Self.nameMinimumWidth - nameWidth) + Self.gap, after: nameFont))
        if !call.summary.isEmpty {
            line.append(NSAttributedString(
                string: call.summary,
                attributes: [.font: ChromeFont.mono, .foregroundColor: colors.textPrimary]
            ))
        }
        let meta: String?
        if call.state == .running {
            meta = "running…"
        } else if let startedAt, let finishedAt = call.finishedAt,
                  finishedAt.timeIntervalSince(startedAt) >= Self.shownDuration {
            meta = Self.duration(finishedAt.timeIntervalSince(startedAt))
        } else {
            meta = nil
        }
        if let meta {
            line.append(gap(Self.gap, after: ChromeFont.row))
            line.append(NSAttributedString(
                string: meta,
                attributes: [.font: ChromeFont.count, .foregroundColor: colors.textMuted]
            ))
        }
        if let diff = call.diff {
            let (added, removed) = Self.diffStatistics(diff)
            line.append(gap(Self.gap, after: ChromeFont.row))
            line.append(NSAttributedString(string: "+\(added)", attributes: [
                .font: ChromeFont.monoSmall,
                .foregroundColor: added == 0 ? colors.textMuted : colors.success,
            ]))
            line.append(NSAttributedString(string: " ", attributes: [.font: ChromeFont.monoSmall]))
            line.append(NSAttributedString(string: "−\(removed)", attributes: [
                .font: ChromeFont.monoSmall,
                .foregroundColor: removed == 0 ? colors.textMuted : colors.danger,
            ]))
        }
        line.append(NSAttributedString(string: "\n", attributes: [.font: ChromeFont.row]))

        let failureLines: String? = {
            guard !detailed, call.state == .failed, let text = call.output else { return nil }
            let lines = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
            return lines.isEmpty ? nil : lines.suffix(Self.compactFailureLines).joined(separator: "\n")
        }()
        let detail = detailed ? call.detail.flatMap { $0.isEmpty ? nil : $0 } : nil
        let hasBoxes = detail != nil || call.diff != nil || (detailed && call.output != nil) || failureLines != nil
        line.addAttribute(
            .paragraphStyle,
            value: itemParagraph(glyph: glyphText, spacing: hasBoxes ? 0 : Self.groupSpacing, blocks: [group]),
            range: NSRange(location: 0, length: line.length)
        )
        output.append(line)

        if let detail {
            appendBlock(detail, color: colors.textPrimary, in: group, to: output)
        }
        if let diff = call.diff {
            appendDiff(diff, detailed: detailed, in: group, to: output)
        }
        if detailed, let text = call.output {
            appendBlock(text, color: colors.textMuted, in: group, to: output)
        } else if let failureLines {
            appendBlock(failureLines, color: colors.danger, in: group, to: output)
        }
    }

    private func appendNotice(_ text: String, isError: Bool, to output: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = Self.itemSpacing
        output.append(NSAttributedString(
            string: "— \(AgentTimeline.firstLine(text, limit: 200)) —\n",
            attributes: [
                .font: ChromeFont.meta,
                .foregroundColor: isError ? colors.danger : colors.textMuted,
                .paragraphStyle: style,
            ]
        ))
    }

    /// A diff in one hairline box inside the tool card: a muted mono gutter
    /// with line numbers from the hunk headers, a marker column, and
    /// add/delete rows washed full width.
    private func appendDiff(
        _ diff: String,
        detailed: Bool,
        in group: RoundedTextBlock,
        to output: NSMutableAttributedString
    ) {
        var lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var elided = 0
        if !detailed, lines.count > Self.compactDiffLines {
            elided = lines.count - Self.compactDiffLines
            lines = Array(lines.prefix(Self.compactDiffLines))
        }
        let block = boxBlock()
        // The gutter starts inside the box's hairline padding.
        block.gutterWidth = Chrome.hairline + Self.diffGutter
        block.gutterFill = colors.bgPanel
        let blocks = [group, block]
        let text = NSMutableAttributedString()
        var oldLine: Int?
        var newLine: Int?
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("@@") {
                let numbers = Self.hunkStarts(line)
                oldLine = numbers?.old
                newLine = numbers?.new
                // The first hunk's position is in the gutter already.
                if index > 0 {
                    text.append(diffRow(gutter: nil, marker: "", code: line, codeFont: ChromeFont.monoSmall,
                                        codeColor: colors.cyan, wash: colors.diffFiller, blocks: blocks))
                }
                continue
            }
            if line.hasPrefix("diff ") {
                oldLine = nil
                newLine = nil
                text.append(diffRow(gutter: nil, marker: "", code: String(line.dropFirst(5)),
                                    codeFont: ChromeFont.sans(size: 12, weight: .medium),
                                    codeColor: colors.textPrimary, wash: colors.diffFiller, blocks: blocks))
                continue
            }
            let marker = line.first.map(String.init) ?? ""
            let code = line.isEmpty ? "" : String(line.dropFirst())
            switch marker {
            case "+":
                text.append(diffRow(gutter: newLine, marker: "+", code: code, markerColor: colors.success,
                                    wash: colors.diffAdd, blocks: blocks))
                newLine = newLine.map { $0 + 1 }
            case "-":
                text.append(diffRow(gutter: oldLine, marker: "−", code: code, markerColor: colors.danger,
                                    wash: colors.diffDelete, blocks: blocks))
                oldLine = oldLine.map { $0 + 1 }
            default:
                text.append(diffRow(gutter: newLine, marker: "", code: marker == " " ? code : line, blocks: blocks))
                oldLine = oldLine.map { $0 + 1 }
                newLine = newLine.map { $0 + 1 }
            }
        }
        if elided > 0 {
            text.append(diffRow(gutter: nil, marker: "", code: "⋯ \(elided) more lines · O shows all",
                                codeFont: ChromeFont.meta, codeColor: colors.textMuted, blocks: blocks))
        }
        output.append(text)
    }

    private func diffRow(
        gutter: Int?,
        marker: String,
        code: String,
        codeFont: NSFont = ChromeFont.mono,
        codeColor: NSColor? = nil,
        markerColor: NSColor? = nil,
        wash: NSColor? = nil,
        blocks: [NSTextBlock]
    ) -> NSAttributedString {
        let row = NSMutableAttributedString()
        row.append(NSAttributedString(
            string: "\t" + (gutter.map(String.init) ?? "") + "\t",
            attributes: [.font: ChromeFont.monoSmall, .foregroundColor: colors.textMuted]
        ))
        row.append(NSAttributedString(
            string: marker + "\t",
            attributes: [
                .font: ChromeFont.monospaced(size: 12, weight: .semibold),
                .foregroundColor: markerColor ?? colors.textMuted,
            ]
        ))
        row.append(NSAttributedString(
            string: code + "\n",
            attributes: [.font: codeFont, .foregroundColor: codeColor ?? colors.textPrimary]
        ))
        let style = NSMutableParagraphStyle()
        style.textBlocks = blocks
        style.minimumLineHeight = Self.diffRowHeight
        style.maximumLineHeight = Self.diffRowHeight
        style.headIndent = Self.diffCode
        style.lineBreakMode = .byWordWrapping
        style.tabStops = [
            NSTextTab(textAlignment: .right, location: Self.diffGutter - 8),
            NSTextTab(textAlignment: .center, location: Self.diffGutter + 9),
            NSTextTab(textAlignment: .left, location: Self.diffCode),
        ]
        let range = NSRange(location: 0, length: row.length)
        row.addAttribute(.paragraphStyle, value: style, range: range)
        row.addAttribute(.baselineOffset, value: 2, range: range)
        if let wash {
            row.addAttribute(.timelineRowWash, value: wash, range: range)
        }
        return row
    }

    /// Tool details and output: mono text in a hairline box inside the tool
    /// card.
    private func appendBlock(
        _ text: String,
        color: NSColor,
        in group: RoundedTextBlock,
        to output: NSMutableAttributedString
    ) {
        let block = boxBlock()
        block.setWidth(8, type: .absoluteValueType, for: .padding)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        output.append(NSAttributedString(
            string: text + "\n",
            attributes: [
                .font: ChromeFont.mono,
                .foregroundColor: color,
                .paragraphStyle: paragraph(blocks: [group, block]),
            ]
        ))
    }

    /// A box under a tool line, aligned with its name: borderSubtle edge,
    /// radius 6, 6 pt above and the card's line gap below.
    private func boxBlock() -> RoundedTextBlock {
        let block = RoundedTextBlock(radius: Chrome.Radius.control, edge: colors.borderSubtle)
        block.setWidth(Chrome.hairline, type: .absoluteValueType, for: .padding)
        block.setWidth(Self.textInset, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
        block.setWidth(Self.groupSpacing + 2, type: .absoluteValueType, for: .margin, edge: .maxY)
        return block
    }

    /// The card a run of tool calls and thinking shares: borderSubtle edge,
    /// radius 8, its lines inset 8 and the item gap below.
    private func groupBlock() -> RoundedTextBlock {
        let block = RoundedTextBlock(radius: Chrome.Radius.card, edge: colors.borderSubtle)
        block.setWidth(9, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(9, type: .absoluteValueType, for: .padding, edge: .maxY)
        block.setWidth(8, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(Self.itemSpacing + 2, type: .absoluteValueType, for: .margin, edge: .maxY)
        return block
    }

    /// Takes the paragraph spacing off the last paragraph, so a card ends on
    /// its padding rather than on the gap meant for a following line.
    private func trimTrailingSpacing(of output: NSMutableAttributedString) {
        guard output.length > 0 else { return }
        let last = output.length - 1
        guard let style = output.attribute(.paragraphStyle, at: last, effectiveRange: nil) as? NSParagraphStyle,
              style.paragraphSpacing > 0,
              let trimmed = style.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        trimmed.paragraphSpacing = 0
        let range = (output.string as NSString).paragraphRange(for: NSRange(location: last, length: 0))
        output.addAttribute(.paragraphStyle, value: trimmed, range: range)
    }

    // MARK: - Styling

    private func color(for state: AgentToolCall.State) -> NSColor {
        switch state {
        case .running: colors.textPrimary
        case .succeeded: colors.success
        case .failed: colors.danger
        case .interrupted: colors.textMuted
        }
    }

    nonisolated static func glyph(for state: AgentToolCall.State) -> String {
        switch state {
        case .running: "▶"
        case .succeeded: "✓"
        case .failed: "✗"
        case .interrupted: "⊘"
        }
    }

    private static var glyphFont: NSFont { ChromeFont.sans(size: 13, weight: .medium) }

    /// A state glyph followed by the tab to the text column.
    private func glyph(_ glyph: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(
            string: glyph + "\t",
            attributes: [.font: Self.glyphFont, .foregroundColor: color]
        )
    }

    /// One timeline line: the glyph centered in its column, wrapped text
    /// hanging at the text column.
    private func itemParagraph(glyph: String, spacing: CGFloat, blocks: [NSTextBlock] = []) -> NSParagraphStyle {
        let width = (glyph as NSString).size(withAttributes: [.font: Self.glyphFont]).width
        let style = NSMutableParagraphStyle()
        style.textBlocks = blocks
        style.firstLineHeadIndent = max(0, floor((Self.glyphColumn - width) / 2))
        style.headIndent = Self.textInset
        style.tabStops = [NSTextTab(textAlignment: .left, location: Self.textInset)]
        style.minimumLineHeight = Self.lineHeight
        style.paragraphSpacing = spacing
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// A space `width` wide, measured in `font`.
    private func gap(_ width: CGFloat, after font: NSFont) -> NSAttributedString {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        return NSAttributedString(string: " ", attributes: [.font: font, .kern: width - space])
    }

    private func paragraph(
        blocks: [NSTextBlock] = [],
        spacing: CGFloat = 0,
        indent: CGFloat = 0,
        lineHeight: CGFloat? = nil
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textBlocks = blocks
        style.paragraphSpacing = spacing
        style.headIndent = indent
        style.firstLineHeadIndent = indent
        style.lineBreakMode = .byWordWrapping
        if let lineHeight {
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
        }
        return style
    }

    /// The old and new start lines of a `@@ -a,b +c,d @@` header.
    private static func hunkStarts(_ header: String) -> (old: Int, new: Int)? {
        let fields = header.split(separator: " ")
        guard fields.count >= 3,
              let old = fields[1].dropFirst().split(separator: ",").first.flatMap({ Int($0) }),
              let new = fields[2].dropFirst().split(separator: ",").first.flatMap({ Int($0) })
        else { return nil }
        return (old, new)
    }

    static func diffStatistics(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0
        var removed = 0
        for line in diff.split(separator: "\n") {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 }
            if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    /// `2.4s`, `38s`, `3m 05s`, `1h 02m`.
    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        if whole < 60 { return "\(whole)s" }
        if whole < 3_600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
        return String(format: "%dh %02dm", whole / 3_600, (whole % 3_600) / 60)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

extension AgentTimelineActivity.Tone {
    /// The status color of what the agent is doing: working green, waiting
    /// yellow, idle blue, failed red.
    func color(in colors: ThemeColors) -> NSColor {
        switch self {
        case .working: colors.success
        case .waiting: colors.yellow
        case .idle: colors.blue
        case .failed: colors.danger
        }
    }
}

extension NSAttributedString.Key {
    /// An `NSColor` a `RoundedTextBlock` paints across the full width of the
    /// lines carrying it (diff rows).
    static let timelineRowWash = NSAttributedString.Key("SopranoTimelineRowWash")
}

/// A full-width text box that TextKit 1 draws as one rounded rectangle: its
/// `backgroundColor` fill, the `.timelineRowWash` of its lines, then an
/// optional hairline `edge`. Paragraphs sharing one block share one box.
final class RoundedTextBlock: NSTextBlock {
    var radius: CGFloat = 0
    var edge: NSColor?
    /// A leading column (a diff's line numbers) filled with `gutterFill` over
    /// the row washes and closed by an `edge` hairline.
    var gutterWidth: CGFloat = 0
    var gutterFill: NSColor?

    override init() {
        super.init()
        // Without an explicit width TextKit sizes the block to its narrowest
        // content, which stacks a long code line one character per line.
        setValue(100, type: .percentageValueType, for: .width)
    }

    convenience init(radius: CGFloat, edge: NSColor? = nil) {
        self.init()
        self.radius = radius
        self.edge = edge
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let copy = copy as? RoundedTextBlock {
            copy.radius = radius
            copy.edge = edge
            copy.gutterWidth = gutterWidth
            copy.gutterFill = gutterFill
        }
        return copy
    }

    override func drawBackground(
        withFrame frameRect: NSRect,
        in controlView: NSView,
        characterRange charRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        let left = width(for: .margin, edge: .minX)
        let right = width(for: .margin, edge: .maxX)
        let top = width(for: .margin, edge: .minY)
        let bottom = width(for: .margin, edge: .maxY)
        let box = NSRect(
            x: frameRect.minX + left,
            y: frameRect.minY + top,
            width: frameRect.width - left - right,
            height: frameRect.height - top - bottom
        )
        guard box.width > 0, box.height > 0 else { return }
        let shape = NSBezierPath(
            roundedRect: box.insetBy(dx: 0.5, dy: 0.5),
            xRadius: radius,
            yRadius: radius
        )
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        if let backgroundColor {
            backgroundColor.setFill()
            box.fill()
        }
        drawRowWashes(in: box, controlView: controlView, characterRange: charRange, layoutManager: layoutManager)
        if gutterWidth > 0 {
            let gutter = NSRect(x: box.minX, y: box.minY, width: gutterWidth, height: box.height)
            if let gutterFill {
                gutterFill.setFill()
                gutter.fill()
            }
            if let edge {
                edge.setFill()
                NSRect(x: gutter.maxX - Chrome.hairline, y: box.minY, width: Chrome.hairline, height: box.height).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if let edge {
            edge.setStroke()
            shape.lineWidth = Chrome.hairline
            shape.stroke()
        }
    }

    private func drawRowWashes(
        in box: NSRect,
        controlView: NSView,
        characterRange: NSRange,
        layoutManager: NSLayoutManager
    ) {
        guard let storage = layoutManager.textStorage,
              NSMaxRange(characterRange) <= storage.length
        else { return }
        // TextKit 1 draws on the main thread.
        let origin = MainActor.assumeIsolated {
            (controlView as? NSTextView)?.textContainerOrigin ?? .zero
        }
        storage.enumerateAttribute(.timelineRowWash, in: characterRange) { value, range, _ in
            guard let wash = value as? NSColor else { return }
            // A wash belongs to the innermost box (the diff), not to the tool
            // card around it, which would paint it across its whole width.
            let style = storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            guard style?.textBlocks.last === self else { return }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            wash.setFill()
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, _, _ in
                NSRect(x: box.minX, y: line.minY + origin.y, width: box.width, height: line.height).fill()
            }
        }
    }
}
