import AppKit

/// What an agent is doing right now, in one line, for its dashboard row and
/// the detail view's NOW strip.
struct AgentTimelineActivity: Equatable {
    enum Tone: Equatable {
        case working
        case waiting
        case idle
        case failed
    }

    let text: String
    let tone: Tone

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
                    text: "▶ \(Self.label(for: call))\(Self.since(running.timestamp, now: now))",
                    tone: .working
                )
            }
            switch last.kind {
            case .prompt, .thinking:
                return AgentTimelineActivity(text: "Thinking\(Self.since(last.timestamp, now: now))", tone: .working)
            case .reply:
                return AgentTimelineActivity(text: "Writing\(Self.since(last.timestamp, now: now))", tone: .working)
            case .tool(let call):
                return AgentTimelineActivity(
                    text: "\(AgentTimelineRenderer.glyph(for: call.state)) \(Self.label(for: call))",
                    tone: .working
                )
            case .notice(let text, let isError):
                return AgentTimelineActivity(text: text, tone: isError ? .failed : .working)
            }
        case .waiting:
            if let running, let call = running.toolCall {
                return AgentTimelineActivity(text: "Approve? \(Self.label(for: call))", tone: .waiting)
            }
            if let reply = Self.lastReply(in: timeline) {
                return AgentTimelineActivity(text: "Asks · \(AgentTimeline.firstLine(reply))", tone: .waiting)
            }
            return AgentTimelineActivity(text: "Waiting for input", tone: .waiting)
        case .error:
            let notice = timeline.items.last { item in
                if case .notice(_, true) = item.kind { return true }
                return false
            }
            if case .notice(let text, _)? = notice?.kind {
                return AgentTimelineActivity(text: AgentTimeline.firstLine(text), tone: .failed)
            }
            return AgentTimelineActivity(text: "Stopped with an error", tone: .failed)
        case .idle, .stopped:
            if let reply = Self.lastReply(in: timeline) {
                return AgentTimelineActivity(text: "Replied · \(AgentTimeline.firstLine(reply))", tone: .idle)
            }
            return nil
        }
    }

    private static func label(for call: AgentToolCall) -> String {
        call.summary.isEmpty ? call.name : "\(call.name) \(call.summary)"
    }

    private static func lastReply(in timeline: AgentTimeline) -> String? {
        for item in timeline.items.reversed() {
            if item.isPrompt { return nil }
            if case .reply(let text) = item.kind { return text }
        }
        return nil
    }

    private static func since(_ start: Date?, now: Date) -> String {
        guard let start else { return "" }
        return " · " + AgentTimelineRenderer.duration(max(0, now.timeIntervalSince(start)))
    }
}

/// Lays out an agent's timeline as attributed text for the dashboard: prompts
/// as tinted cards, replies as rendered Markdown, one line per tool call with
/// its diff, and notices centered between them. The text view showing it must
/// use TextKit 1, which draws the `NSTextBlock` backgrounds.
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

    private(set) var colors: ThemeColors
    let fontSize: CGFloat
    private var replyCache: [String: (markdown: String, text: NSAttributedString)] = [:]

    init(colors: ThemeColors, fontSize: CGFloat = 11) {
        self.colors = colors
        self.fontSize = fontSize
    }

    func apply(colors: ThemeColors) {
        self.colors = colors
        replyCache.removeAll()
    }

    /// `isAgentActive` tells whether calls without a result are still running;
    /// once the agent is idle or gone they were cut short.
    func render(_ timeline: AgentTimeline, detailed: Bool, isAgentActive: Bool) -> Output {
        let output = NSMutableAttributedString()
        var turnStarts: [Int] = []
        var shownReplies = Set<String>()

        if timeline.items.isEmpty {
            append("No messages yet.", color: colors.textMuted, to: output)
        }
        for item in timeline.items {
            switch item.kind {
            case .prompt(let text):
                turnStarts.append(output.length)
                appendPrompt(text, timestamp: item.timestamp, to: output)
            case .reply(let markdown):
                shownReplies.insert(item.id)
                appendReply(markdown, id: item.id, to: output)
            case .thinking(let text):
                appendThinking(text, detailed: detailed, to: output)
            case .tool(var call):
                if call.state == .running, !isAgentActive {
                    call.state = .interrupted
                }
                appendTool(call, startedAt: item.timestamp, detailed: detailed, to: output)
            case .notice(let text, let isError):
                appendNotice(text, isError: isError, to: output)
            }
        }
        replyCache = replyCache.filter { shownReplies.contains($0.key) }
        return Output(text: output, turnStarts: turnStarts)
    }

    // MARK: - Items

    private func appendPrompt(_ text: String, timestamp: Date?, to output: NSMutableAttributedString) {
        let block = textBlock(background: colors.bgSelected, border: colors.accent, topMargin: 14)
        let header = NSMutableAttributedString(
            string: "You",
            attributes: [.font: RetroFont.display(11), .foregroundColor: colors.accent]
        )
        if let timestamp {
            header.append(NSAttributedString(
                string: "  " + Self.timeFormatter.string(from: timestamp),
                attributes: [.font: font(), .foregroundColor: colors.textMuted]
            ))
        }
        header.append(NSAttributedString(string: "\n"))
        header.addAttribute(.paragraphStyle, value: paragraph(blocks: [block], spacing: 3), range: NSRange(location: 0, length: header.length))
        output.append(header)

        var shown = text
        if shown.count > Self.promptCharacterLimit {
            shown = String(shown.prefix(Self.promptCharacterLimit)) + " …"
        }
        output.append(NSAttributedString(
            string: shown + "\n",
            attributes: [
                .font: font(),
                .foregroundColor: colors.textPrimary,
                .paragraphStyle: paragraph(blocks: [block], spacing: 2),
            ]
        ))
        output.append(spacer(height: 4))
    }

    private func appendReply(_ markdown: String, id: String, to output: NSMutableAttributedString) {
        let rendered: NSAttributedString
        if let cached = replyCache[id], cached.markdown == markdown {
            rendered = cached.text
        } else {
            rendered = AgentMarkdownRenderer.render(markdown, colors: colors, fontSize: fontSize)
            replyCache[id] = (markdown, rendered)
        }
        output.append(rendered)
        output.append(NSAttributedString(
            string: "\n",
            attributes: [.font: font(), .paragraphStyle: paragraph(spacing: 8)]
        ))
    }

    private func appendThinking(_ text: String, detailed: Bool, to output: NSMutableAttributedString) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(),
            .foregroundColor: colors.textMuted,
            .obliqueness: 0.15,
            .paragraphStyle: paragraph(spacing: 6),
        ]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if detailed, !trimmed.isEmpty {
            output.append(NSAttributedString(string: "▾ Thinking\n", attributes: attributes))
            output.append(NSAttributedString(
                string: trimmed + "\n",
                attributes: attributes.merging([.paragraphStyle: paragraph(spacing: 6, indent: characterWidth * 2)]) { $1 }
            ))
        } else {
            let summary = trimmed.isEmpty ? "Thinking" : AgentTimeline.firstLine(trimmed, limit: 140)
            output.append(NSAttributedString(string: "▸ \(summary)\n", attributes: attributes))
        }
    }

    private func appendTool(
        _ call: AgentToolCall,
        startedAt: Date?,
        detailed: Bool,
        to output: NSMutableAttributedString
    ) {
        let nameWidth = max(8, call.name.count + 1)
        let indent = characterWidth * CGFloat(2 + nameWidth)
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(
            string: Self.glyph(for: call.state) + " ",
            attributes: [.font: font(weight: .bold), .foregroundColor: color(for: call.state)]
        ))
        line.append(NSAttributedString(
            string: call.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0),
            attributes: [.font: font(weight: .semibold), .foregroundColor: colors.textMuted]
        ))
        line.append(NSAttributedString(
            string: call.summary,
            attributes: [.font: font(), .foregroundColor: colors.textPrimary]
        ))
        if call.state == .running {
            line.append(NSAttributedString(
                string: "  running…",
                attributes: [.font: font(), .foregroundColor: colors.accent]
            ))
        } else if let startedAt, let finishedAt = call.finishedAt,
                  finishedAt.timeIntervalSince(startedAt) >= Self.shownDuration {
            line.append(NSAttributedString(
                string: " · " + Self.duration(finishedAt.timeIntervalSince(startedAt)),
                attributes: [.font: font(), .foregroundColor: colors.textMuted]
            ))
        }
        if let diff = call.diff {
            let (added, removed) = Self.diffStatistics(diff)
            line.append(NSAttributedString(string: "  +\(added)", attributes: [.font: font(), .foregroundColor: colors.success]))
            line.append(NSAttributedString(string: " −\(removed)", attributes: [.font: font(), .foregroundColor: colors.danger]))
        }
        line.append(NSAttributedString(string: "\n"))
        line.addAttribute(
            .paragraphStyle,
            value: paragraph(spacing: 4, indent: indent, firstLineIndent: 0),
            range: NSRange(location: 0, length: line.length)
        )
        output.append(line)

        if detailed, let detail = call.detail, !detail.isEmpty {
            appendBlock(detail, indent: indent, color: colors.textPrimary, to: output)
        }
        if let diff = call.diff {
            appendDiff(diff, indent: indent, detailed: detailed, to: output)
        }
        if let text = call.output {
            if detailed {
                appendBlock(text, indent: indent, color: colors.textMuted, to: output)
            } else if call.state == .failed {
                let lines = text.split(separator: "\n").filter {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty
                }
                appendBlock(
                    lines.suffix(Self.compactFailureLines).joined(separator: "\n"),
                    indent: indent,
                    color: colors.danger,
                    to: output
                )
            }
        }
    }

    private func appendNotice(_ text: String, isError: Bool, to output: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.paragraphSpacing = 8
        style.paragraphSpacingBefore = 6
        output.append(NSAttributedString(
            string: "— \(AgentTimeline.firstLine(text, limit: 200)) —\n",
            attributes: [
                .font: font(),
                .foregroundColor: isError ? colors.danger : colors.textMuted,
                .paragraphStyle: style,
            ]
        ))
    }

    private func appendDiff(_ diff: String, indent: CGFloat, detailed: Bool, to output: NSMutableAttributedString) {
        var lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var elided = 0
        if !detailed, lines.count > Self.compactDiffLines {
            elided = lines.count - Self.compactDiffLines
            lines = Array(lines.prefix(Self.compactDiffLines))
        }
        let block = textBlock(background: colors.bgRaised, leftMargin: indent)
        let style = paragraph(blocks: [block])
        let text = NSMutableAttributedString()
        for line in lines {
            text.append(NSAttributedString(
                string: line + "\n",
                attributes: [.font: font(), .foregroundColor: diffColor(for: line), .paragraphStyle: style]
            ))
        }
        if elided > 0 {
            text.append(NSAttributedString(
                string: "⋯ \(elided) more lines · O shows all\n",
                attributes: [.font: font(), .foregroundColor: colors.textMuted, .paragraphStyle: style]
            ))
        }
        output.append(text)
        output.append(spacer(height: 4))
    }

    private func appendBlock(_ text: String, indent: CGFloat, color: NSColor, to output: NSMutableAttributedString) {
        let block = textBlock(background: colors.bgRaised, leftMargin: indent)
        output.append(NSAttributedString(
            string: text + "\n",
            attributes: [.font: font(), .foregroundColor: color, .paragraphStyle: paragraph(blocks: [block])]
        ))
        output.append(spacer(height: 4))
    }

    private func append(_ text: String, color: NSColor, to output: NSMutableAttributedString) {
        output.append(NSAttributedString(
            string: text + "\n",
            attributes: [.font: font(), .foregroundColor: color, .paragraphStyle: paragraph(spacing: 6)]
        ))
    }

    // MARK: - Styling

    private func diffColor(for line: String) -> NSColor {
        if line.hasPrefix("@@") { return colors.cyan }
        if line.hasPrefix("diff ") || line.hasPrefix("+++") || line.hasPrefix("---") { return colors.accent }
        if line.hasPrefix("+") { return colors.success }
        if line.hasPrefix("-") { return colors.danger }
        return colors.textMuted
    }

    private func color(for state: AgentToolCall.State) -> NSColor {
        switch state {
        case .running: colors.accent
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

    private func font(weight: NSFont.Weight = .regular) -> NSFont {
        RetroFont.body(fontSize, weight: weight)
    }

    private var characterWidth: CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font()]).width
    }

    private func paragraph(
        blocks: [NSTextBlock] = [],
        spacing: CGFloat = 0,
        indent: CGFloat = 0,
        firstLineIndent: CGFloat? = nil
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textBlocks = blocks
        style.paragraphSpacing = spacing
        style.headIndent = indent
        style.firstLineHeadIndent = firstLineIndent ?? indent
        style.lineBreakMode = .byWordWrapping
        return style
    }

    /// A full-width tinted box. Paragraphs that share one block draw as one box.
    private func textBlock(
        background: NSColor,
        border: NSColor? = nil,
        leftMargin: CGFloat = 0,
        topMargin: CGFloat = 2
    ) -> NSTextBlock {
        let block = NSTextBlock()
        block.backgroundColor = background
        block.setValue(100, type: .percentageValueType, for: .width)
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        block.setWidth(10, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(leftMargin, type: .absoluteValueType, for: .margin, edge: .minX)
        block.setWidth(topMargin, type: .absoluteValueType, for: .margin, edge: .minY)
        if let border {
            block.setWidth(2, type: .absoluteValueType, for: .border, edge: .minX)
            block.setBorderColor(border, for: .minX)
        }
        return block
    }

    private func spacer(height: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return NSAttributedString(
            string: "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: style]
        )
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
    /// The dashboard's status colors: working green, waiting yellow, idle blue.
    func color(in colors: ThemeColors) -> NSColor {
        switch self {
        case .working: colors.success
        case .waiting: colors.yellow
        case .idle: colors.blue
        case .failed: colors.danger
        }
    }
}
