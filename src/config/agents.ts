import { platform } from "@tauri-apps/plugin-os";
import { AgentProfile } from "../types/agent";

const codex: AgentProfile = {
  id: "codex",
  name: "Codex",
  icon: "bot",
  color: "#10a37f",
  description: "OpenAI Codex coding agent",
  command: "codex",
  args: [],
  patterns: {
    ready: ["Codex is ready", ">"],
    error: ["Error", "error:", "FAILED"],
  },
};

const claudeCode: AgentProfile = {
  id: "claude-code",
  name: "Claude Code",
  icon: "sparkles",
  color: "#da7756",
  description: "Anthropic Claude Code CLI agent",
  command: "claude",
  args: [],
  patterns: {
    ready: ["Claude", ">", "❯"],
    error: ["Error", "error:", "FAILED"],
  },
};

const openCode: AgentProfile = {
  id: "opencode",
  name: "Open Code",
  icon: "zap",
  color: "#58a6ff",
  description: "OpenCode terminal agent",
  command: "opencode",
  args: [],
  patterns: {
    ready: [">", "Ready"],
    error: ["Error", "error:", "FAILED"],
  },
};

const openClaw: AgentProfile = {
  id: "openclaw",
  name: "OpenClaw",
  icon: "paw-print",
  color: "#f97316",
  description: "OpenClaw with SSH tunnel bootstrap",
  command: "bash",
  args: [],
  launchScript: `VPS="root@187.77.66.93"
PORT="41856"
ssh -fN -o ExitOnForwardFailure=yes -L \${PORT}:127.0.0.1:\${PORT} "\${VPS}" 2>/dev/null || true
TOKEN="$(ssh "\${VPS}" "bash -lc 'openclaw config get gateway.auth.token'" 2>/dev/null)"
if [ -z "\${TOKEN}" ]; then
  echo "❌ Could not fetch gateway token from VPS."
  exit 1
fi
exec openclaw tui --url ws://127.0.0.1:\${PORT} --token "\${TOKEN}" --session main`,
  patterns: {
    ready: ["Connected", "session"],
    error: ["Could not fetch", "Error", "refused"],
  },
};

const shellByPlatform: Record<string, string> = {
  macos: "zsh",
  windows: "powershell.exe",
  linux: "bash",
};

const plainTerminal: AgentProfile = {
  id: "terminal",
  name: "Terminal",
  icon: "terminal",
  color: "#cba6f7",
  description: "Plain system login shell",
  command: shellByPlatform[platform()] ?? "bash",
  args: ["--login"],
};

export const DEFAULT_AGENTS: AgentProfile[] = [
  codex,
  claudeCode,
  openCode,
  openClaw,
  plainTerminal,
];

export function getAgentById(id: string): AgentProfile | undefined {
  return DEFAULT_AGENTS.find((agent) => agent.id === id);
}
