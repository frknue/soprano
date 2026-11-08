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
                    glyph: glyph(for: .running),
                    title: call.name,
                    code: subject(of: call),
                    elapsed: since(running.timestamp, now: now),
                    tone: .working
                )
            }
            switch last.kind {
            case .prompt, .thinking:
                return AgentTimelineActivity(title: "Thinking", elapsed: since(last.timestamp, now: now), tone: .working)
            case .reply:
                return AgentTimelineActivity(title: "Writing", elapsed: since(last.timestamp, now: now), tone: .working)
            case .tool(let call):
                return AgentTimelineActivity(
                    glyph: glyph(for: call.state),
                    title: call.name,
                    code: subject(of: call),
                    tone: .working
                )
            case .notice(let text, let isError):
                return AgentTimelineActivity(title: AgentTimeline.firstLine(text), tone: isError ? .failed : .working)
            }
        case .waiting:
            if let running, let call = running.toolCall {
                return AgentTimelineActivity(title: "Approve \(call.name)?", code: subject(of: call), tone: .waiting)
            }
            if let reply = lastReply(in: timeline) {
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
            if let reply = lastReply(in: timeline) {
                return AgentTimelineActivity(title: "Replied", detail: AgentTimeline.firstLine(reply), tone: .idle)
            }
            return nil
        }
    }

    /// The line in UI type: the lead in `titleFont`, the subject in
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
            append(elapsed, Typography.tabular(font.pointSize), color)
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return line
    }

    static func glyph(for state: AgentToolCall.State) -> String {
        switch state {
        case .running: "▶"
        case .succeeded: "✓"
        case .failed: "✗"
        case .interrupted: "⊘"
        }
    }

    /// `2.4s`, `38s`, `3m 05s`, `1h 02m`.
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        let whole = Int(seconds)
        if whole < 60 { return "\(whole)s" }
        if whole < 3_600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
        return String(format: "%dh %02dm", whole / 3_600, (whole % 3_600) / 60)
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
        return duration(max(0, now.timeIntervalSince(start)))
    }
}
