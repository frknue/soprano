import { ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Bot,
  Columns2,
  FolderOpen,
  Globe,
  Keyboard,
  RotateCcw,
  Rows2,
  Save,
  Sparkles,
  Square,
  Terminal,
  X,
  Zap,
  PawPrint,
} from "lucide-react";
import { getBindingById } from "../config/keybindings";
import { useSessionManager } from "../hooks/useSessionManager";
import { AgentManager } from "../hooks/useAgentManager";
import { KeyBindingConfig } from "../types/keybinding";

interface CommandPaletteProps {
  isOpen: boolean;
  onClose: () => void;
  agentManager: AgentManager;
  sessionManager: ReturnType<typeof useSessionManager>;
  config: KeyBindingConfig;
}

interface CommandItem {
  id: string;
  icon: ReactNode;
  label: string;
  description: string;
  shortcut?: string;
  execute: () => void;
}

function formatDate(timestamp: number): string {
  return new Date(timestamp).toLocaleString();
}

export function CommandPalette({ isOpen, onClose, agentManager, sessionManager, config }: CommandPaletteProps) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const saveInputRef = useRef<HTMLInputElement | null>(null);
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [isSaveMode, setIsSaveMode] = useState(false);
  const [sessionName, setSessionName] = useState("");

  const commands = useMemo<CommandItem[]>(() => {
    const activePaneId = agentManager.activePaneId;
    const getShortcut = (id: string): string | undefined => getBindingById(config, id)?.defaultKeys;

    const agentCommands: CommandItem[] = [
      {
        id: "launch-codex",
        icon: <Bot size={18} />,
        label: "Launch Codex",
        description: "Start Codex AI agent",
        shortcut: getShortcut("launch-codex"),
        execute: () => agentManager.spawnAgent("codex"),
      },
      {
        id: "launch-claude-code",
        icon: <Sparkles size={18} />,
        label: "Launch Claude Code",
        description: "Start Claude Code agent",
        shortcut: getShortcut("launch-claude-code"),
        execute: () => agentManager.spawnAgent("claude-code"),
      },
      {
        id: "launch-opencode",
        icon: <Zap size={18} />,
        label: "Launch OpenCode",
        description: "Start OpenCode agent",
        shortcut: getShortcut("launch-opencode"),
        execute: () => agentManager.spawnAgent("opencode"),
      },
      {
        id: "launch-openclaw",
        icon: <PawPrint size={18} />,
        label: "Launch OpenClaw",
        description: "Start OpenClaw agent (with tunnel)",
        shortcut: getShortcut("launch-openclaw"),
        execute: () => agentManager.spawnAgent("openclaw"),
      },
      {
        id: "new-terminal",
        icon: <Terminal size={18} />,
        label: "Open Terminal",
        description: "Open a plain terminal",
        shortcut: getShortcut("new-terminal"),
        execute: () => agentManager.spawnTerminal(),
      },
      {
        id: "new-browser",
        icon: <Globe size={18} />,
        label: "Open Browser",
        description: "Open an embedded browser",
        shortcut: getShortcut("new-browser"),
        execute: () => agentManager.spawnBrowser(),
      },
    ];

    const actionCommands: CommandItem[] = [
      {
        id: "split-horizontal",
        icon: <Rows2 size={18} />,
        label: "Split Horizontal",
        description: "Split active pane horizontally",
        shortcut: getShortcut("split-horizontal"),
        execute: () => {
          agentManager.splitPane("column", activePaneId);
        },
      },
      {
        id: "split-vertical",
        icon: <Columns2 size={18} />,
        label: "Split Vertical",
        description: "Split active pane vertically",
        shortcut: getShortcut("split-vertical"),
        execute: () => {
          agentManager.splitPane("row", activePaneId);
        },
      },
      {
        id: "close-pane",
        icon: <X size={18} />,
        label: "Close Pane",
        description: "Close active pane",
        shortcut: getShortcut("close-pane"),
        execute: () => {
          agentManager.closePane(activePaneId);
        },
      },
      {
        id: "restart-agent",
        icon: <RotateCcw size={18} />,
        label: "Restart Agent",
        description: "Restart agent in active pane",
        execute: () => {
          agentManager.restartAgent(activePaneId);
        },
      },
      {
        id: "stop-agent",
        icon: <Square size={18} />,
        label: "Stop Agent",
        description: "Stop agent in active pane",
        execute: () => {
          agentManager.stopAgent(activePaneId);
        },
      },
    ];

    const sessionCommands: CommandItem[] = [
      {
        id: "save-session",
        icon: <Save size={18} />,
        label: "Save Session...",
        description: "Save current workspace layout",
        shortcut: getShortcut("save-session"),
        execute: () => {
          setIsSaveMode(true);
          setSessionName("");
        },
      },
      ...sessionManager.sessions.map((session) => ({
        id: `load-session-${session.id}`,
        icon: <FolderOpen size={18} />,
        label: `Load: ${session.name}`,
        description: `Restore workspace from ${formatDate(session.savedAt)}`,
        execute: () => sessionManager.loadSession(session.id),
      })),
      {
        id: "show-keybindings",
        icon: <Keyboard size={18} />,
        label: "Keyboard Shortcuts",
        description: "View all keyboard shortcuts",
        execute: () => {
          console.log("Soprano keybindings", config.bindings);
        },
      },
    ];

    return [...agentCommands, ...actionCommands, ...sessionCommands];
  }, [agentManager, config, sessionManager]);

  const filtered = useMemo(() => {
    const term = query.trim().toLowerCase();
    if (!term) {
      return commands;
    }

    return commands.filter((command) => {
      const haystack = `${command.label} ${command.description}`.toLowerCase();
      return haystack.includes(term);
    });
  }, [commands, query]);

  useEffect(() => {
    if (!isOpen) {
      setQuery("");
      setSelectedIndex(0);
      setIsSaveMode(false);
      return;
    }

    requestAnimationFrame(() => {
      if (isSaveMode) {
        saveInputRef.current?.focus();
      } else {
        inputRef.current?.focus();
      }
    });
  }, [isOpen, isSaveMode]);

  useEffect(() => {
    setSelectedIndex((prev) => {
      if (filtered.length === 0) {
        return 0;
      }
      return Math.min(prev, filtered.length - 1);
    });
  }, [filtered.length]);

  const selectedRef = useCallback((node: HTMLDivElement | null) => {
    node?.scrollIntoView({ block: "nearest" });
  }, [selectedIndex]);

  if (!isOpen) {
    return null;
  }

  const executeCommand = (command: CommandItem): void => {
    command.execute();
    if (command.id !== "save-session") {
      onClose();
    }
  };

  return (
    <div
      className="command-palette-overlay"
      onClick={(event) => {
        if (event.target === event.currentTarget) {
          onClose();
        }
      }}
      role="presentation"
    >
      <div className="command-palette">
        {isSaveMode ? (
          <input
            className="command-palette-input"
            onChange={(event) => setSessionName(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter") {
                const value = sessionName.trim();
                if (value) {
                  sessionManager.saveSession(value);
                  setIsSaveMode(false);
                  onClose();
                }
              }

              if (event.key === "Escape") {
                setIsSaveMode(false);
              }
            }}
            placeholder="Session name"
            ref={saveInputRef}
            value={sessionName}
          />
        ) : (
          <input
            className="command-palette-input"
            onChange={(event) => setQuery(event.target.value)}
            onKeyDown={(event) => {
              if (event.key === "ArrowDown") {
                event.preventDefault();
                setSelectedIndex((prev) => Math.min(prev + 1, Math.max(0, filtered.length - 1)));
              }

              if (event.key === "ArrowUp") {
                event.preventDefault();
                setSelectedIndex((prev) => Math.max(prev - 1, 0));
              }

              if (event.key === "Enter") {
                event.preventDefault();
                const selected = filtered[selectedIndex];
                if (selected) {
                  executeCommand(selected);
                }
              }

              if (event.key === "Escape") {
                event.preventDefault();
                onClose();
              }
            }}
            placeholder="Type a command..."
            ref={inputRef}
            value={query}
          />
        )}

        <div className="command-palette-results">
          {filtered.map((command, index) => (
            <div
              className={`command-palette-item ${index === selectedIndex ? "selected" : ""}`}
              key={command.id}
              onClick={() => executeCommand(command)}
              ref={index === selectedIndex ? selectedRef : undefined}
              role="button"
              tabIndex={0}
            >
              <span className="command-palette-item-icon">{command.icon}</span>
              <div>
                <div className="command-palette-item-label">{command.label}</div>
                <div className="command-palette-item-desc">{command.description}</div>
              </div>
              {command.shortcut ? <span className="command-palette-item-shortcut">{command.shortcut}</span> : null}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
