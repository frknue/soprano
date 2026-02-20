import { ReactNode, useCallback, useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
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
import { getAgentById } from "../config/agents";
import { getBindingById } from "../config/keybindings";
import { AppSettings } from "../config/settings";
import { useSessionManager } from "../hooks/useSessionManager";
import { AgentManager } from "../hooks/useAgentManager";
import { PaletteMode } from "../hooks/useKeybindings";
import { KeyBindingConfig } from "../types/keybinding";

interface ProjectEntry {
  name: string;
  path: string;
}

interface CommandPaletteProps {
  isOpen: boolean;
  initialMode: PaletteMode;
  pendingAgentId: string | null;
  onClose: () => void;
  onRequestAgentLaunch: (profileId: string) => void;
  agentManager: AgentManager;
  sessionManager: ReturnType<typeof useSessionManager>;
  config: KeyBindingConfig;
  appSettings: AppSettings;
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

export function CommandPalette({ isOpen, initialMode, pendingAgentId, onClose, onRequestAgentLaunch, agentManager, sessionManager, config, appSettings }: CommandPaletteProps) {
  const inputRef = useRef<HTMLInputElement | null>(null);
  const saveInputRef = useRef<HTMLInputElement | null>(null);
  const [query, setQuery] = useState("");
  const [selectedIndex, setSelectedIndex] = useState(0);
  const [isSaveMode, setIsSaveMode] = useState(false);
  const [sessionName, setSessionName] = useState("");
  const [isProjectMode, setIsProjectMode] = useState(false);
  const [projects, setProjects] = useState<ProjectEntry[]>([]);

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
        execute: () => onRequestAgentLaunch("codex"),
      },
      {
        id: "launch-claude-code",
        icon: <Sparkles size={18} />,
        label: "Launch Claude Code",
        description: "Start Claude Code agent",
        shortcut: getShortcut("launch-claude-code"),
        execute: () => onRequestAgentLaunch("claude-code"),
      },
      {
        id: "launch-opencode",
        icon: <Zap size={18} />,
        label: "Launch OpenCode",
        description: "Start OpenCode agent",
        shortcut: getShortcut("launch-opencode"),
        execute: () => onRequestAgentLaunch("opencode"),
      },
      {
        id: "launch-openclaw",
        icon: <PawPrint size={18} />,
        label: "Launch OpenClaw",
        description: "Start OpenClaw agent (with tunnel)",
        shortcut: getShortcut("launch-openclaw"),
        execute: () => onRequestAgentLaunch("openclaw"),
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

    const projectCommands: CommandItem[] = appSettings.projectDirectories.length > 0
      ? [{
          id: "open-project",
          icon: <FolderOpen size={18} />,
          label: "Open Project...",
          description: "Browse project directories and open a terminal",
          execute: () => {
            setIsProjectMode(true);
            setQuery("");
            setSelectedIndex(0);
            invoke<ProjectEntry[]>("list_projects", { roots: appSettings.projectDirectories })
              .then(setProjects)
              .catch(() => setProjects([]));
          },
        }]
      : [];

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

    return [...agentCommands, ...projectCommands, ...actionCommands, ...sessionCommands];
  }, [agentManager, config, sessionManager, appSettings.projectDirectories, onRequestAgentLaunch]);

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
      setIsProjectMode(false);
      setProjects([]);
      return;
    }

    if (initialMode === "projects" && appSettings.projectDirectories.length > 0) {
      setIsProjectMode(true);
      setQuery("");
      setSelectedIndex(0);
      invoke<ProjectEntry[]>("list_projects", { roots: appSettings.projectDirectories })
        .then(setProjects)
        .catch(() => setProjects([]));
    }

    requestAnimationFrame(() => {
      if (isSaveMode) {
        saveInputRef.current?.focus();
      } else {
        inputRef.current?.focus();
      }
    });
  }, [isOpen, isSaveMode, initialMode, appSettings.projectDirectories]);

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

  const filteredProjects = useMemo(() => {
    if (!isProjectMode) return [];
    const term = query.trim().toLowerCase();
    if (!term) return projects;
    return projects.filter((p) => p.name.toLowerCase().includes(term));
  }, [isProjectMode, projects, query]);

  const openProject = useCallback((project: ProjectEntry): void => {
    if (pendingAgentId) {
      agentManager.spawnAgent(pendingAgentId, project.path);
    } else {
      agentManager.spawnTerminal(project.path);
    }
    onClose();
  }, [agentManager, pendingAgentId, onClose]);

  if (!isOpen) {
    return null;
  }

  const executeCommand = (command: CommandItem): void => {
    command.execute();
    const keepOpen = command.id === "save-session"
      || command.id === "open-project"
      || command.id.startsWith("launch-");
    if (!keepOpen) {
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
            onChange={(event) => {
              setQuery(event.target.value);
              setSelectedIndex(0);
            }}
            onKeyDown={(event) => {
              const listLength = isProjectMode ? filteredProjects.length : filtered.length;

              if (event.key === "ArrowDown") {
                event.preventDefault();
                setSelectedIndex((prev) => Math.min(prev + 1, Math.max(0, listLength - 1)));
              }

              if (event.key === "ArrowUp") {
                event.preventDefault();
                setSelectedIndex((prev) => Math.max(prev - 1, 0));
              }

              if (event.key === "Enter") {
                event.preventDefault();
                if (isProjectMode) {
                  const project = filteredProjects[selectedIndex];
                  if (project) openProject(project);
                } else {
                  const selected = filtered[selectedIndex];
                  if (selected) executeCommand(selected);
                }
              }

              if (event.key === "Escape") {
                event.preventDefault();
                if (isProjectMode) {
                  setIsProjectMode(false);
                  setProjects([]);
                  setQuery("");
                  setSelectedIndex(0);
                } else {
                  onClose();
                }
              }
            }}
            placeholder={isProjectMode
              ? pendingAgentId
                ? `Select project for ${getAgentById(pendingAgentId)?.name ?? "agent"}...`
                : "Search projects..."
              : "Type a command..."
            }
            ref={inputRef}
            value={query}
          />
        )}

        <div className="command-palette-results">
          {isProjectMode ? (
            filteredProjects.map((project, index) => (
              <div
                className={`command-palette-item ${index === selectedIndex ? "selected" : ""}`}
                key={project.path}
                onClick={() => openProject(project)}
                ref={index === selectedIndex ? selectedRef : undefined}
                role="button"
                tabIndex={0}
              >
                <span className="command-palette-item-icon"><FolderOpen size={18} /></span>
                <div>
                  <div className="command-palette-item-label">{project.name}</div>
                  <div className="command-palette-item-desc">{project.path}</div>
                </div>
              </div>
            ))
          ) : (
            filtered.map((command, index) => (
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
            ))
          )}
        </div>
      </div>
    </div>
  );
}
