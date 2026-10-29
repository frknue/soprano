import Foundation

/// A prompt Soprano gives an agent on a schedule, as `settings.json` declares
/// it under `automations.<id>`.
struct Automation: Equatable, Sendable, Identifiable {
    /// Where each run's agent works.
    enum Workspace: Equatable, Sendable {
        /// In `folder` itself, beside whatever else works there.
        case folder
        /// In a fresh git worktree of `folder`'s repository, branched from
        /// `baseBranch` (the remote's default branch when nil).
        case worktree(baseBranch: String?)
    }

    enum Session: String, Equatable, Sendable, CaseIterable {
        /// Every run starts a new agent.
        case fresh
        /// A run hands its prompt to the previous run's agent while that one
        /// is still open and done with its turn, and starts one otherwise.
        case reuse
    }

    /// The CLIs that take a first prompt on their command line and report
    /// their turns back to Soprano, so a run can start and finish unattended.
    static let agentIds = ["omp", "claude-code", "codex", "opencode"]

    static let defaultGraceMinutes = 720
    static let graceMinutesRange = 0...2_880
    static let defaultPrecheckTimeoutSeconds = 60
    static let precheckTimeoutRange = 5...600

    let id: String
    var name: String
    var agentId: String
    /// Absolute, `~` expanded.
    var folder: String
    var prompt: String
    var schedule: CronSchedule
    var enabled: Bool
    var workspace: Workspace
    var session: Session
    /// How late a run due while the Mac slept, or Soprano was closed, may
    /// still start.
    var graceMinutes: Int
    /// A shell command run in `folder` before a scheduled run; the run is
    /// skipped unless it exits 0.
    var precheck: String?
    var precheckTimeoutSeconds: Int
    /// Passed as the CLI's model option; nil keeps the CLI's default.
    var model: String?

    var cadence: AutomationCadence { AutomationCadence(schedule) }

    /// `abc`, `weekday-audit`: what may name an automation in settings.json.
    static func isValidId(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    /// A new id from `name`, unique among `existing`.
    static func makeId(from name: String, existing: Set<String>) -> String {
        var slug = ""
        var lastWasDash = false
        for scalar in name.lowercased().unicodeScalars {
            if (97...122).contains(scalar.value) || (48...57).contains(scalar.value) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug += "-"
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        slug = String(slug.prefix(48))
        if slug.isEmpty { slug = "automation" }
        var candidate = slug
        var suffix = 2
        while existing.contains(candidate) {
            candidate = "\(slug)-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    /// The `automations.<id>` object Soprano writes for this automation:
    /// defaults are left out so the file stays as short as a hand-written one.
    var configObject: [String: Any] {
        var object: [String: Any] = [
            "name": name,
            "agent": agentId,
            "folder": ConfigFile.abbreviatingHome(folder),
            "prompt": prompt,
            "schedule": schedule.expression,
        ]
        if !enabled { object["enabled"] = false }
        if case .worktree(let baseBranch) = workspace {
            object["worktree"] = true
            if let baseBranch { object["baseBranch"] = baseBranch }
        }
        if session != .fresh { object["session"] = session.rawValue }
        if graceMinutes != Self.defaultGraceMinutes { object["graceMinutes"] = graceMinutes }
        if let precheck { object["precheck"] = precheck }
        if precheckTimeoutSeconds != Self.defaultPrecheckTimeoutSeconds {
            object["precheckTimeoutSeconds"] = precheckTimeoutSeconds
        }
        if let model { object["model"] = model }
        return object
    }
}

extension SopranoConfig {
    /// One `automations.<id>` entry. Every field is optional so a partial or
    /// mistyped entry is reported in Settings instead of failing the file.
    struct AutomationEntry: Codable, Equatable {
        var name: String?
        var agent: String?
        var folder: String?
        var prompt: String?
        var schedule: String?
        var enabled: Bool?
        var worktree: Bool?
        var baseBranch: String?
        var session: String?
        var graceMinutes: Int?
        var precheck: String?
        var precheckTimeoutSeconds: Int?
        var model: String?
    }

    /// The valid automations, sorted by name; every rejected entry becomes
    /// an issue and is left out.
    static func resolveAutomations(
        _ entries: [String: AutomationEntry],
        agentIds: Set<String>,
        issues: inout [ConfigIssue]
    ) -> [Automation] {
        var automations: [Automation] = []
        for (id, entry) in entries.sorted(by: { $0.key < $1.key }) {
            func reject(_ reason: String) {
                issues.append(.init(severity: .warning, message: "automations.\(id): \(reason)"))
            }
            guard Automation.isValidId(id) else {
                reject("ids use only letters, digits, - and _; the entry was ignored.")
                continue
            }
            guard let prompt = entry.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty else {
                reject("\"prompt\" is missing; the automation was ignored.")
                continue
            }
            let folder = expandPath(entry.folder ?? "")
            guard !folder.isEmpty else {
                reject("\"folder\" is missing; the automation was ignored.")
                continue
            }
            guard let agentId = entry.agent?.trimmingCharacters(in: .whitespacesAndNewlines), !agentId.isEmpty else {
                reject("\"agent\" is missing; use one of \(Automation.agentIds.joined(separator: ", ")).")
                continue
            }
            guard Automation.agentIds.contains(agentId), agentIds.contains(agentId) else {
                reject("\"\(agentId)\" can't run automations; use one of \(Automation.agentIds.joined(separator: ", ")).")
                continue
            }
            let schedule: CronSchedule
            do {
                schedule = try CronSchedule(parsing: entry.schedule ?? "")
            } catch {
                reject("\"schedule\" \(entry.schedule.map { "\"\($0)\"" } ?? "is missing"): \(error.localizedDescription)")
                continue
            }

            var graceMinutes = entry.graceMinutes ?? Automation.defaultGraceMinutes
            if !Automation.graceMinutesRange.contains(graceMinutes) {
                reject("\"graceMinutes\" must be 0–\(Automation.graceMinutesRange.upperBound); using the default.")
                graceMinutes = Automation.defaultGraceMinutes
            }
            var timeout = entry.precheckTimeoutSeconds ?? Automation.defaultPrecheckTimeoutSeconds
            if !Automation.precheckTimeoutRange.contains(timeout) {
                reject(
                    "\"precheckTimeoutSeconds\" must be \(Automation.precheckTimeoutRange.lowerBound)–"
                        + "\(Automation.precheckTimeoutRange.upperBound); using the default."
                )
                timeout = Automation.defaultPrecheckTimeoutSeconds
            }
            let workspace: Automation.Workspace = entry.worktree == true
                ? .worktree(baseBranch: entry.baseBranch.flatMap(nonEmpty))
                : .folder
            var session = Automation.Session.fresh
            if let raw = entry.session {
                if let value = Automation.Session(rawValue: raw) {
                    session = value
                } else {
                    reject("\"session\" must be \"fresh\" or \"reuse\"; using fresh.")
                }
            }
            if session == .reuse, workspace != .folder {
                reject("\"session\": \"reuse\" needs the run to work in its folder, not a worktree; using fresh.")
                session = .fresh
            }
            let name = entry.name.flatMap(nonEmpty) ?? id
            automations.append(Automation(
                id: id,
                name: name,
                agentId: agentId,
                folder: folder,
                prompt: prompt,
                schedule: schedule,
                enabled: entry.enabled ?? true,
                workspace: workspace,
                session: session,
                graceMinutes: graceMinutes,
                precheck: entry.precheck.flatMap(nonEmpty),
                precheckTimeoutSeconds: timeout,
                model: entry.model.flatMap(nonEmpty)
            ))
        }
        return automations.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
