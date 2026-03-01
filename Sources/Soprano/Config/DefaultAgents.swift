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

    static let openClaw = AgentProfile(
        id: "openclaw",
        name: "OpenClaw",
        icon: "paw-print",
        color: "#f97316",
        description: "OpenClaw with SSH tunnel bootstrap",
        command: "bash",
        args: [],
        launchScript: """
            VPS="root@187.77.66.93"
            PORT="41856"
            SOCK="/tmp/soprano-ssh-${PORT}"
            if ! ssh -o ControlPath="${SOCK}" -O check "${VPS}" 2>/dev/null; then
              rm -f "${SOCK}"
              ssh -fN -o ControlMaster=yes -o ControlPath="${SOCK}" -o ControlPersist=600 -L ${PORT}:127.0.0.1:${PORT} "${VPS}"
            fi
            TOKEN="$(ssh -o ControlPath="${SOCK}" "${VPS}" "bash -lc 'openclaw config get gateway.auth.token'")"
            if [ -z "${TOKEN}" ]; then
              echo "❌ Could not fetch gateway token from VPS."
              exit 1
            fi
            exec openclaw tui --url ws://127.0.0.1:${PORT} --token "${TOKEN}" --session main
            """,
        patterns: .init(
            ready: ["Connected", "session"],
            error: ["Could not fetch", "Error", "refused"]
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

    static let all: [AgentProfile] = [codex, claudeCode, openCode, openClaw, terminal]

    static func profile(for id: String) -> AgentProfile? {
        all.first { $0.id == id }
    }

    private static var defaultShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
