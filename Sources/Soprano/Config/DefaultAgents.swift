import Foundation

/// Built-in agent profile definitions.
enum DefaultAgents {
    static let codex = AgentProfile(
        id: "codex",
        name: "Codex",
        icon: "bot",
        color: "#10a37f",
        description: "OpenAI Codex coding agent",
        command: "codex",
        args: [],
        patterns: .init(
            ready: ["Codex is ready", ">"],
            error: ["Error", "error:", "FAILED"]
        )
    )

    static let claudeCode = AgentProfile(
        id: "claude-code",
        name: "Claude Code",
        icon: "sparkles",
        color: "#da7756",
        description: "Anthropic Claude Code CLI agent",
        command: "claude",
        args: [],
        patterns: .init(
            ready: ["Claude", ">", "❯"],
            error: ["Error", "error:", "FAILED"]
        )
    )

    static let openCode = AgentProfile(
        id: "opencode",
        name: "Open Code",
        icon: "zap",
        color: "#58a6ff",
        description: "OpenCode terminal agent",
        command: "opencode",
        args: [],
        patterns: .init(
            ready: [">", "Ready"],
            error: ["Error", "error:", "FAILED"]
        )
    )

    static let terminal = AgentProfile(
        id: "terminal",
        name: "Terminal",
        icon: "terminal",
        color: "#fe8019",
        description: "Plain system login shell",
        command: defaultShell,
        args: ["--login"]
    )

    static let all: [AgentProfile] = [codex, claudeCode, openCode, terminal]

    static func profile(for id: String) -> AgentProfile? {
        all.first { $0.id == id }
    }

    private static var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
