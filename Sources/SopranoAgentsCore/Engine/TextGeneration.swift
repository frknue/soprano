import Foundation

/// Text-generation prompts (titles, branch names, commit messages, PR text) and the
/// sanitizers applied to what the model returns.
enum TextGeneration {
    // MARK: Shared helpers

    /// `limitSection`: truncates to `maxChars` and marks the cut.
    static func limitSection(_ value: String, _ maxChars: Int) -> String {
        guard value.count > maxChars else { return value }
        return "\(value.prefix(maxChars))\n\n[truncated]"
    }

    /// `limitTitleMessage`: keeps the head and tail of an over-long message.
    static func limitTitleMessage(_ text: String, _ budget: Int) -> String {
        guard text.count > budget else { return text }
        let marker = "\n[Content truncated]\n"
        guard budget > marker.count else { return "" }
        let available = budget - marker.count
        let head = (available + 1) / 2
        let tail = available - head
        return "\(text.prefix(head))\(marker)\(tail > 0 ? String(text.suffix(tail)) : "")"
    }

    static func policyInstruction(_ instruction: String?) -> [String] {
        guard let trimmed = instruction?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return [] }
        return ["", "Additional instructions:", limitSection(trimmed, 20_000)]
    }

    static func attachmentLines(_ attachments: [Attachment]) -> [String] {
        attachments.map { "- \($0.name) (\($0.mimeType), \($0.byteSize) bytes)" }
    }

    static func objectSchema(_ properties: [String: JSONValue]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(properties.keys.sorted().map(JSONValue.string)),
            "additionalProperties": .bool(false),
        ])
    }

    static let stringSchema: JSONValue = .object(["type": .string("string")])
    static let booleanSchema: JSONValue = .object(["type": .string("boolean")])

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Title seed

    /// `truncate`: first 50 characters + "..." when longer.
    static func truncate(_ text: String, _ maxLength: Int = 50) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength else { return trimmed }
        return "\(trimmed.prefix(maxLength))..."
    }

    /// The title a thread shows right after its first message, before generation finishes.
    static func titleSeed(text: String, attachments: [Attachment]) -> String {
        let prose = collapseWhitespace(text)
        if !prose.isEmpty { return truncate(prose) }
        let images = attachments.filter { $0.kind == .image }
        if !images.isEmpty { return images.count == 1 ? "Attached image" : "Attached images" }
        if let name = attachments.first.map({ collapseWhitespace($0.name) }), !name.isEmpty {
            return truncate("File: \(name)")
        }
        return "New thread"
    }

    // MARK: Thread titles

    static let defaultTitle = "New thread"

    static let titleSchema = objectSchema(["title": stringSchema, "needsRefinement": booleanSchema])

    static let initialTitlePrompt = """
    Generate a title that will help the user recognize this Soprano Agents thread weeks later.
    Return JSON with keys title and needsRefinement.
    Set needsRefinement to true only if the subject is still unknown, such as an unresolved link, "fix this", or an unexplained attachment. Otherwise set it to false.

    Before answering, silently reduce the request to:
    - Subject: What system, feature, or problem is this really about?
    - Outcome: What does the user ultimately want to understand or change?
    - Incidental instructions: What only describes how the agent should do the work?

    Title the subject and outcome. Discard incidental instructions.

    Editorial rules:
    - 3-8 words, fewer than 40 characters.
    - Use a compact noun phrase or clear action phrase.
    - Capture the umbrella goal when the request lists several symptoms or steps.
    - Name the product change, not the mock, plan, report, branch, or PR used to produce it.
    - Models, subagents, tools, output formats, and monitoring instructions do not belong in the title unless they are themselves the topic.
    - For reviews, name what is being reviewed and the relevant concern. Avoid generic titles such as "Review PR 123" when linked or attached context reveals the subject.
    - For research, name the question domain rather than the requested research process.
    - Do not claim the work is complete.
    - Do not copy and truncate the user's message.
    - Avoid project names already visible in the UI, quotes, labels, filler, and trailing punctuation.
    - Use attached images as primary context for UI issues.
    - When a URL or attachment is the only source of the subject, use available tools to inspect it directly.
    - Local git history is not evidence of what a linked PR or issue is about. Never title the thread after branch names, commit messages, or merged commits found in the checkout.
    - If a linked PR or issue cannot be read, fall back to the user's stated action plus its number, such as "Take Over PR 8588". This is the one case where a PR or issue number belongs in the title.
    """

    static func regenerateTitlePrompt(previousTitle: String) -> String {
        """
        Regenerate the title for an existing Soprano Agents thread so the user can recognize it weeks later.
        The previous title was \(jsonString(previousTitle)).
        Return JSON with keys title and needsRefinement. Set needsRefinement to false.

        Determine the title in this order:
        1. Read the USER messages first. Identify the latest explicit durable goal. The original subject remains the subject until the user clearly changes what the thread is about.
        2. Use ASSISTANT messages to resolve vague links, unnamed code, and discovered product nouns. Do not promote one assistant finding into the thread subject unless the user adopts it as a new goal.
        3. Compare that subject with the previous title. Preserve accurate scope words, especially when earlier content is truncated. Replace the previous title when it is generic, artifact-based, a completion update, or contradicted by the thread.
        4. Title the durable subject and desired outcome, not the current workflow state.

        Editorial rules:
        - 3-8 words, fewer than 40 characters.
        - Use a compact noun phrase or clear action phrase.
        - Preserve the umbrella subject when later messages focus on one finding, provider, platform, or implementation detail.
        - A thread progressing through research, planning, implementation, review, CI, merge, and monitoring has usually not changed subjects.
        - Ignore deliverables and operations such as mocks, plans, HTML, branches, PRs, tests, CI, commits, merging, and monitoring unless they are the actual topic.
        - Models, subagents, tools, output formats, and monitoring instructions do not belong in the title unless they are themselves the topic.
        - Treat final operational follow-ups and assistant completion summaries as weak evidence of subject.
        - For reviews, name the reviewed feature or system and its durable concern, not one finding from the review.
        - For research, name the question domain rather than the research process.
        - Do not claim the work is complete.
        - Do not copy and truncate a thread message.
        - Avoid project names already visible in the UI, PR numbers, quotes, labels, filler, and trailing punctuation.
        - Use attached images as primary context for UI issues.
        - When a URL or attachment is the only source of the subject, use available tools to inspect it directly.
        - Local git history is not evidence of what a linked PR or issue is about. Never title the thread after branch names, commit messages, or merged commits found in the checkout.
        - If a linked PR or issue cannot be read, fall back to the user's stated action plus its number, such as "Take Over PR 8588". This is the one case where a PR or issue number belongs in the title.
        - Keep the previous title unchanged if it is already accurate. Otherwise return a meaningfully improved title, not a cosmetic paraphrase.

        Examples of the distinction:
        - A subagent-monitoring review that finds a Codex roster bug remains "Review Subagent Monitoring Risks," not "Codex Roster Bug Review."
        - A vague failing-test request later identified as a lazy thread-feed mismatch becomes "Fix Lazy Thread Feed Test," not "Prevent Mobile Feed Regressions."
        - A QR-sharing overhaul that ends with CI and merge work remains about QR sharing, not the PR lifecycle.
        """
    }

    private static func titleSuffix(_ attachments: [Attachment]) -> String {
        let lines = attachmentLines(attachments)
        guard !lines.isEmpty else { return "" }
        return "\n\nAttachment metadata:\n\(limitSection(lines.joined(separator: "\n"), 4_000))"
    }

    static func initialTitlePrompt(message: String, attachments: [Attachment]) -> String {
        "\(initialTitlePrompt)\n\nUser message:\n\(limitTitleMessage(message, 8_000))\(titleSuffix(attachments))"
    }

    static func regenerateTitlePrompt(previousTitle: String, transcript: String) -> String {
        "\(regenerateTitlePrompt(previousTitle: previousTitle))\n\nThread contents:\n\(preserveMessageEnd(transcript))"
    }

    private static let earlierContentMarker = "[Earlier content truncated]\n\n"

    static func preserveMessageEnd(_ message: String) -> String {
        guard message.count > 8_000 else { return message }
        return "\(earlierContentMarker)\(message.suffix(8_000))"
    }

    /// USER/ASSISTANT transcript of a thread for title regeneration (reasoning and tools dropped).
    static func titleTranscript(_ thread: AgentThread) -> String {
        var sections: [String] = []
        func add(_ role: String, _ text: String, _ attachments: [Attachment] = []) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let names = attachments.map(\.name).joined(separator: ", ")
            let contents = [trimmed, names.isEmpty ? "" : "[Attachments: \(names)]"].filter { !$0.isEmpty }.joined(separator: "\n")
            guard !contents.isEmpty else { return }
            sections.append("\(role):\n\(limitTitleMessage(contents, 2_000))")
        }
        for turn in thread.turns {
            add("USER", turn.userMessage.text, turn.userMessage.attachments)
            for steer in turn.steers {
                add("USER", steer.text, steer.attachments)
            }
            let assistant = turn.items.compactMap { item -> String? in
                if case let .assistantMessage(text, _) = item.kind { return text }
                return nil
            }
            add("ASSISTANT", assistant.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    /// `sanitizeThreadTitle`: first line, no wrapping quotes, collapsed spaces, ≤ 120 characters.
    static func sanitizeTitle(_ raw: String) -> String {
        let firstLine = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        let quotes = CharacterSet(charactersIn: "'\"`")
        let normalized = collapseWhitespace(firstLine.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: quotes))
        guard !normalized.isEmpty else { return defaultTitle }
        guard normalized.count > 120 else { return normalized }
        let cut = String(normalized.prefix(117)).trimmingCharacters(in: .whitespaces)
        return "\(cut)..."
    }

    // MARK: Branch names

    static let branchSchema = objectSchema(["branch": stringSchema])

    static func branchNamePrompt(message: String, attachments: [Attachment]) -> String {
        var sections = [
            "You generate concise git branch names.",
            "Return a JSON object with key: branch.",
            "Rules:",
            "- Branch should describe the requested work from the user message.",
            "- Return a valid Git branch name without spaces.",
            "- Keep it short and specific (2-6 words), in lowercase with hyphen-separated words.",
            "- Return only the descriptive branch fragment, without a prefix or namespace. The application adds the configured prefix.",
            "- If images are attached, use them as primary context for visual/UI issues.",
            "",
            "User message:",
            limitSection(message, 8_000),
        ]
        let lines = attachmentLines(attachments)
        if !lines.isEmpty {
            sections += ["", "Attachment metadata:", limitSection(lines.joined(separator: "\n"), 4_000)]
        }
        return sections.joined(separator: "\n")
    }

    /// `sanitizeBranchFragment`: lowercase, `[^a-z0-9/_-]` → `-`, ≤ 64 characters, fallback `update`.
    static func sanitizeBranchFragment(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        value.removeAll { "'\"`".contains($0) }
        value = trimEdges(value, "./ \t\n_-")
        value = replace(value, "[^a-z0-9/_-]+", "-")
        value = replace(value, "/+", "/")
        value = replace(value, "-+", "-")
        value = trimEdges(value, "./_-")
        value = String(value.prefix(64))
        value = replace(value, "[./_-]+$", "")
        return value.isEmpty ? "update" : value
    }

    /// Static naming mode: `<prefix>/<fragment>`.
    static func formatGeneratedBranchName(_ raw: String, prefix: String) -> String {
        let fragment = sanitizeBranchFragment(raw)
        let namespace = branchPrefix(prefix)
        return namespace.isEmpty ? fragment : "\(namespace)/\(fragment)"
    }

    /// The configured prefix as a valid ref namespace ("soprano", "team/agents").
    static func branchPrefix(_ prefix: String) -> String {
        prefix.split(separator: "/").map { part in
            trimEdges(replace(replace(String(part), "[^a-zA-Z0-9_-]+", "-"), "-+", "-"), "-")
        }.filter { !$0.isEmpty }.joined(separator: "/")
    }

    /// `sanitizeFeatureBranchName`: a fragment with a namespace, `feature/` when it has none.
    static func sanitizeFeatureBranchName(_ raw: String) -> String {
        let fragment = sanitizeBranchFragment(raw)
        return fragment.contains("/") ? fragment : "feature/\(fragment)"
    }

    /// Temporary worktree branch: `<prefix>/<8 hex>`.
    static func temporaryBranchName(prefix: String) -> String {
        let hex = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8)
        let namespace = branchPrefix(prefix)
        return namespace.isEmpty ? "tmp-\(hex)" : "\(namespace)/\(hex)"
    }

    // MARK: Commit messages and PR text

    static let commitInstructions = "Follow the repository's established commit message style when examples are available."
    static let changeRequestInstructions = "Follow the repository's established change request title and body style when examples are available."

    static func commitSchema(includeBranch: Bool) -> JSONValue {
        var properties: [String: JSONValue] = ["subject": stringSchema, "body": stringSchema]
        if includeBranch { properties["branch"] = stringSchema }
        return objectSchema(properties)
    }

    static func commitMessagePrompt(branch: String?, stagedSummary: String, stagedPatch: String, includeBranch: Bool) -> String {
        var lines = [
            "You write concise git commit messages.",
            includeBranch ? "Return a JSON object with keys: subject, body, branch." : "Return a JSON object with keys: subject, body.",
            "Rules:",
            "- subject must be imperative, <= 72 chars, and no trailing period",
            "- body can be empty string or short bullet points",
        ]
        if includeBranch { lines.append("- branch must be a short semantic git branch fragment for this change") }
        lines.append("- capture the primary user-visible or developer-visible change")
        lines += policyInstruction(commitInstructions)
        lines += [
            "",
            "Branch: \(branch ?? "(detached)")",
            "",
            "Staged files:",
            limitSection(stagedSummary, 6_000),
            "",
            "Staged patch:",
            limitSection(stagedPatch, 40_000),
        ]
        return lines.joined(separator: "\n")
    }

    static let pullRequestSchema = objectSchema(["title": stringSchema, "body": stringSchema])

    static func pullRequestPrompt(baseBranch: String, headBranch: String, commits: String, diffStat: String, diffPatch: String) -> String {
        var lines = [
            "You write source control change request content.",
            "Return a JSON object with keys: title, body.",
            "Rules:",
            "- title should be concise and specific",
            "- body must be markdown and include headings '## Summary' and '## Testing'",
            "- under Summary, provide short bullet points",
            "- under Testing, include bullet points with concrete checks or 'Not run' where appropriate",
        ]
        lines += policyInstruction(changeRequestInstructions)
        lines += [
            "",
            "Base branch: \(baseBranch)",
            "Head branch: \(headBranch)",
            "",
            "Commits:",
            limitSection(commits, 12_000),
            "",
            "Diff stat:",
            limitSection(diffStat, 12_000),
            "",
            "Diff patch:",
            limitSection(diffPatch, 40_000),
        ]
        return lines.joined(separator: "\n")
    }

    /// `sanitizeCommitSubject`: first line, no trailing period, ≤ 72 characters.
    static func sanitizeCommitSubject(_ raw: String) -> String {
        let firstLine = (raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        var subject = firstLine
        while subject.hasSuffix(".") { subject.removeLast() }
        subject = subject.trimmingCharacters(in: .whitespaces)
        if subject.count > 72 { subject = String(subject.prefix(72)).trimmingCharacters(in: .whitespaces) }
        return subject.isEmpty ? "Update project files" : subject
    }

    /// `sanitizePrTitle`: first line, fallback "Update project changes".
    static func sanitizePullRequestTitle(_ raw: String) -> String {
        let firstLine = (raw.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? "")
            .trimmingCharacters(in: .whitespaces)
        return firstLine.isEmpty ? "Update project changes" : firstLine
    }

    // MARK: Private

    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return "\"\(value)\"" }
        return text
    }

    private static func replace(_ value: String, _ pattern: String, _ replacement: String) -> String {
        value.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    private static func trimEdges(_ value: String, _ characters: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: characters))
    }
}

/// Commit messages and PR text from the text-generation model (`ProviderDriver.generateJSON`).
struct ProviderSourceControlWriter: SourceControlWriter {
    let driver: (any ProviderDriver)?
    let selection: ModelSelection
    let cwd: String

    func commitMessage(branch: String?, stagedSummary: String, stagedPatch: String, includeBranch: Bool) async throws -> (subject: String, body: String, branch: String?) {
        let prompt = TextGeneration.commitMessagePrompt(branch: branch, stagedSummary: stagedSummary, stagedPatch: stagedPatch, includeBranch: includeBranch)
        let result = try await generate(prompt, schema: TextGeneration.commitSchema(includeBranch: includeBranch))
        let subject = TextGeneration.sanitizeCommitSubject(result["subject"]?.stringValue ?? "")
        let body = (result["body"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedBranch = includeBranch ? result["branch"]?.stringValue.map(TextGeneration.sanitizeFeatureBranchName) : nil
        return (subject, body, generatedBranch)
    }

    func pullRequest(baseBranch: String, headBranch: String, commits: String, diffStat: String, diffPatch: String) async throws -> (title: String, body: String) {
        let prompt = TextGeneration.pullRequestPrompt(baseBranch: baseBranch, headBranch: headBranch, commits: commits, diffStat: diffStat, diffPatch: diffPatch)
        let result = try await generate(prompt, schema: TextGeneration.pullRequestSchema)
        let title = TextGeneration.sanitizePullRequestTitle(result["title"]?.stringValue ?? "")
        let body = (result["body"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body)
    }

    private func generate(_ prompt: String, schema: JSONValue) async throws -> JSONValue {
        guard let driver else {
            throw EngineError.providerUnavailable(selection.provider, "No driver is configured.")
        }
        return try await driver.generateJSON(prompt: prompt, schema: schema, model: selection.model, cwd: cwd)
    }
}
