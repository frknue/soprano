import { useState } from "react";
import {
  Bot,
  CirclePlay,
  CircleStop,
  Info,
  Keyboard,
  Plug,
  Plus,
  RefreshCw,
  Settings as SettingsIcon,
  Trash2,
  X,
} from "lucide-react";
import { DEFAULT_AGENTS } from "../config/agents";
import { AgentIcon } from "./AgentIcon";
import { KeyBindingConfig } from "../types/keybinding";
import { saveKeybindingConfig } from "../config/keybindings";
import { McpManager } from "../hooks/useMcpManager";
import { McpServerConfig, McpTransport } from "../types/mcp";

type SettingsTab = "general" | "shortcuts" | "agents" | "mcp" | "about";

interface SettingsPageProps {
  config: KeyBindingConfig;
  mcpManager: McpManager;
  onClose: () => void;
  onConfigChange: (config: KeyBindingConfig) => void;
}

const TABS: Array<{ id: SettingsTab; label: string; Icon: typeof SettingsIcon }> = [
  { id: "general", Icon: SettingsIcon, label: "General" },
  { id: "shortcuts", Icon: Keyboard, label: "Keyboard Shortcuts" },
  { id: "agents", Icon: Bot, label: "Agent Profiles" },
  { id: "mcp", Icon: Plug, label: "MCP Servers" },
  { id: "about", Icon: Info, label: "About" },
];

function GeneralTab({
  config,
  onConfigChange,
}: {
  config: KeyBindingConfig;
  onConfigChange: (config: KeyBindingConfig) => void;
}) {
  const updateField = <K extends keyof KeyBindingConfig>(
    key: K,
    value: KeyBindingConfig[K],
  ): void => {
    const next = { ...config, [key]: value };
    onConfigChange(next);
    saveKeybindingConfig(next);
  };

  return (
    <div className="settings-section">
      <h3 className="settings-section-title">Keybinding Behavior</h3>

      <div className="settings-field">
        <div className="settings-field-header">
          <label className="settings-label" htmlFor="prefix-key">Prefix Key</label>
          <span className="settings-hint">
            The key used with Ctrl to enter prefix mode (tmux-style)
          </span>
        </div>
        <input
          className="settings-input settings-input-sm"
          id="prefix-key"
          maxLength={1}
          onChange={(e) => {
            const key = e.target.value.toLowerCase();
            if (key.length === 1) {
              updateField("prefixKey", key);
            }
          }}
          value={config.prefixKey}
        />
      </div>

      <div className="settings-field">
        <div className="settings-field-header">
          <label className="settings-label" htmlFor="prefix-timeout">Prefix Timeout</label>
          <span className="settings-hint">
            Milliseconds before prefix mode auto-cancels
          </span>
        </div>
        <div className="settings-input-row">
          <input
            className="settings-input settings-input-sm"
            id="prefix-timeout"
            max={5000}
            min={300}
            onChange={(e) => {
              const value = Number.parseInt(e.target.value, 10);
              if (!Number.isNaN(value)) {
                updateField("prefixTimeoutMs", value);
              }
            }}
            step={100}
            type="number"
            value={config.prefixTimeoutMs}
          />
          <span className="settings-unit">ms</span>
        </div>
      </div>

      <div className="settings-field">
        <div className="settings-field-header">
          <label className="settings-label" htmlFor="resize-tick">Resize Step</label>
          <span className="settings-hint">
            Percentage each resize action moves a split boundary
          </span>
        </div>
        <div className="settings-input-row">
          <input
            className="settings-input settings-input-sm"
            id="resize-tick"
            max={25}
            min={1}
            onChange={(e) => {
              const value = Number.parseInt(e.target.value, 10);
              if (!Number.isNaN(value)) {
                updateField("resizeTickPercent", value);
              }
            }}
            type="number"
            value={config.resizeTickPercent}
          />
          <span className="settings-unit">%</span>
        </div>
      </div>
    </div>
  );
}

function ShortcutsTab({ config }: { config: KeyBindingConfig }) {
  const categoryOrder = ["navigation", "layout", "agents", "general"];
  const categoryLabels: Record<string, string> = {
    navigation: "Navigation",
    layout: "Layout & Splits",
    agents: "Agent Launchers",
    general: "General",
  };

  const grouped = config.bindings.reduce<Record<string, typeof config.bindings>>(
    (acc, binding) => {
      if (!acc[binding.category]) {
        acc[binding.category] = [];
      }
      acc[binding.category].push(binding);
      return acc;
    },
    {},
  );

  return (
    <div className="settings-section">
      {categoryOrder.map((category) => {
        const bindings = grouped[category];
        if (!bindings || bindings.length === 0) {
          return null;
        }

        return (
          <div key={category} className="settings-keybinding-group">
            <h3 className="settings-section-title">
              {categoryLabels[category] ?? category}
            </h3>
            <div className="settings-keybinding-table">
              <div className="settings-keybinding-header-row">
                <span>Action</span>
                <span>Description</span>
                <span>Mode</span>
                <span>Binding</span>
              </div>
              {bindings.map((binding) => (
                <div className="settings-keybinding-row" key={binding.id}>
                  <span className="settings-keybinding-action">{binding.label}</span>
                  <span className="settings-keybinding-desc">{binding.description}</span>
                  <span className="settings-keybinding-mode">{binding.mode}</span>
                  <kbd className="settings-keybinding-key">{binding.defaultKeys}</kbd>
                </div>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}

function AgentsTab() {
  return (
    <div className="settings-section">
      <h3 className="settings-section-title">Configured Agents</h3>
      <div className="settings-agents-grid">
        {DEFAULT_AGENTS.map((agent) => (
          <div className="settings-agent-card" key={agent.id}>
            <div className="settings-agent-card-header">
              <AgentIcon name={agent.icon} size={20} style={{ color: agent.color }} />
              <span className="settings-agent-card-name">{agent.name}</span>
              <span
                className="settings-agent-card-dot"
                style={{ background: agent.color }}
              />
            </div>
            <p className="settings-agent-card-desc">{agent.description}</p>

            <div className="settings-agent-card-fields">
              <div className="settings-agent-card-field">
                <span className="settings-agent-card-label">Command</span>
                <code className="settings-agent-card-value">
                  {agent.launchScript
                    ? "bash -c [launch script]"
                    : `${agent.command} ${agent.args.join(" ")}`.trim()}
                </code>
              </div>
              {agent.cwd ? (
                <div className="settings-agent-card-field">
                  <span className="settings-agent-card-label">Working Directory</span>
                  <code className="settings-agent-card-value">{agent.cwd}</code>
                </div>
              ) : null}
              {agent.patterns?.ready ? (
                <div className="settings-agent-card-field">
                  <span className="settings-agent-card-label">Ready Patterns</span>
                  <code className="settings-agent-card-value">
                    {agent.patterns.ready.join(", ")}
                  </code>
                </div>
              ) : null}
              {agent.patterns?.error ? (
                <div className="settings-agent-card-field">
                  <span className="settings-agent-card-label">Error Patterns</span>
                  <code className="settings-agent-card-value">
                    {agent.patterns.error.join(", ")}
                  </code>
                </div>
              ) : null}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function McpServersTab({ mcpManager }: { mcpManager: McpManager }) {
  const [showAddForm, setShowAddForm] = useState(false);
  const [newName, setNewName] = useState("");
  const [newCommand, setNewCommand] = useState("");
  const [newArgs, setNewArgs] = useState("");
  const [newTransport, setNewTransport] = useState<McpTransport>("stdio");
  const [newPort, setNewPort] = useState("3200");

  const handleAdd = (): void => {
    const name = newName.trim();
    const command = newCommand.trim();
    if (!name || !command) return;

    const config: McpServerConfig = {
      id: name.toLowerCase().replace(/\s+/g, "-"),
      name,
      icon: "plug",
      color: "#94e2d5",
      command,
      args: newArgs.trim() ? newArgs.trim().split(/\s+/) : [],
      transport: newTransport,
      port: Number.parseInt(newPort, 10) || 3200,
      autoStart: false,
    };

    mcpManager.addServer(config);
    setNewName("");
    setNewCommand("");
    setNewArgs("");
    setNewTransport("stdio");
    setNewPort("3200");
    setShowAddForm(false);
  };

  const statusLabel = (status: string): string => {
    switch (status) {
      case "running": return "Running";
      case "starting": return "Starting…";
      case "error": return "Error";
      default: return "Stopped";
    }
  };

  return (
    <div className="settings-section">
      <div className="mcp-section-header">
        <h3 className="settings-section-title" style={{ marginBottom: 0, borderBottom: "none", paddingBottom: 0 }}>
          MCP Server Pool
        </h3>
        <button
          className="mcp-add-btn"
          onClick={() => setShowAddForm((prev) => !prev)}
          type="button"
        >
          <Plus size={14} />
          <span>Add Server</span>
        </button>
      </div>

      <p className="mcp-description">
        Shared MCP servers are spawned once and accessible by all agents.
        Stdio servers are automatically proxied via supergateway for multi-client SSE access.
      </p>

      {showAddForm && (
        <div className="mcp-add-form">
          <div className="mcp-form-row">
            <div className="mcp-form-field">
              <label className="settings-label" htmlFor="mcp-name">Name</label>
              <input
                className="settings-input"
                id="mcp-name"
                onChange={(e) => setNewName(e.target.value)}
                placeholder="My Server"
                value={newName}
              />
            </div>
            <div className="mcp-form-field">
              <label className="settings-label" htmlFor="mcp-port">Port</label>
              <input
                className="settings-input settings-input-sm"
                id="mcp-port"
                onChange={(e) => setNewPort(e.target.value)}
                type="number"
                value={newPort}
              />
            </div>
          </div>
          <div className="mcp-form-row">
            <div className="mcp-form-field" style={{ flex: 1 }}>
              <label className="settings-label" htmlFor="mcp-command">Command</label>
              <input
                className="settings-input"
                id="mcp-command"
                onChange={(e) => setNewCommand(e.target.value)}
                placeholder="npx"
                style={{ width: "100%" }}
                value={newCommand}
              />
            </div>
          </div>
          <div className="mcp-form-row">
            <div className="mcp-form-field" style={{ flex: 1 }}>
              <label className="settings-label" htmlFor="mcp-args">Arguments</label>
              <input
                className="settings-input"
                id="mcp-args"
                onChange={(e) => setNewArgs(e.target.value)}
                placeholder="-y @modelcontextprotocol/server-example"
                style={{ width: "100%" }}
                value={newArgs}
              />
            </div>
          </div>
          <div className="mcp-form-row">
            <div className="mcp-form-field">
              <label className="settings-label" htmlFor="mcp-transport">Transport</label>
              <select
                className="settings-input mcp-select"
                id="mcp-transport"
                onChange={(e) => setNewTransport(e.target.value as McpTransport)}
                value={newTransport}
              >
                <option value="stdio">stdio (proxied via supergateway)</option>
                <option value="sse">SSE (native)</option>
              </select>
            </div>
          </div>
          <div className="mcp-form-actions">
            <button className="mcp-form-cancel" onClick={() => setShowAddForm(false)} type="button">Cancel</button>
            <button
              className="mcp-form-submit"
              disabled={!newName.trim() || !newCommand.trim()}
              onClick={handleAdd}
              type="button"
            >
              Add Server
            </button>
          </div>
        </div>
      )}

      <div className="mcp-server-list">
        {mcpManager.pool.map(({ config, instance }) => (
          <div className="mcp-server-card" key={config.id}>
            <div className="mcp-server-card-header">
              <AgentIcon name={config.icon} size={20} style={{ color: config.color }} />
              <span className="mcp-server-card-name">{config.name}</span>
              <span className={`mcp-status-badge ${instance.status}`}>
                {statusLabel(instance.status)}
              </span>
            </div>

            <div className="mcp-server-card-details">
              <div className="mcp-server-detail">
                <span className="mcp-detail-label">Command</span>
                <code className="mcp-detail-value">
                  {`${config.command} ${config.args.join(" ")}`.trim()}
                </code>
              </div>
              <div className="mcp-server-detail">
                <span className="mcp-detail-label">Transport</span>
                <span className="mcp-detail-value">{config.transport === "stdio" ? "stdio → SSE proxy" : "SSE native"}</span>
              </div>
              <div className="mcp-server-detail">
                <span className="mcp-detail-label">Port</span>
                <span className="mcp-detail-value">{config.port}</span>
              </div>
              {instance.url && (
                <div className="mcp-server-detail">
                  <span className="mcp-detail-label">URL</span>
                  <code className="mcp-detail-value mcp-url">{instance.url}</code>
                </div>
              )}
              {instance.error && (
                <div className="mcp-server-detail">
                  <span className="mcp-detail-label">Error</span>
                  <span className="mcp-detail-value mcp-error-text">{instance.error}</span>
                </div>
              )}
            </div>

            <div className="mcp-server-card-actions">
              {instance.status === "running" ? (
                <>
                  <button
                    className="mcp-action-btn"
                    onClick={() => mcpManager.restartServer(config.id)}
                    title="Restart"
                    type="button"
                  >
                    <RefreshCw size={14} />
                  </button>
                  <button
                    className="mcp-action-btn danger"
                    onClick={() => mcpManager.stopServer(config.id)}
                    title="Stop"
                    type="button"
                  >
                    <CircleStop size={14} />
                  </button>
                </>
              ) : (
                <button
                  className="mcp-action-btn success"
                  disabled={instance.status === "starting"}
                  onClick={() => mcpManager.startServer(config.id)}
                  title="Start"
                  type="button"
                >
                  <CirclePlay size={14} />
                </button>
              )}
              <button
                className="mcp-action-btn danger"
                onClick={() => mcpManager.removeServer(config.id)}
                title="Remove"
                type="button"
              >
                <Trash2 size={14} />
              </button>
            </div>
          </div>
        ))}

        {mcpManager.pool.length === 0 && (
          <div className="mcp-empty">
            No MCP servers configured. Click "Add Server" to get started.
          </div>
        )}
      </div>
    </div>
  );
}

function AboutTab() {
  return (
    <div className="settings-section">
      <div className="settings-about">
        <h2 className="settings-about-title">Soprano</h2>
        <p className="settings-about-tagline">
          AI Agent Orchestration Platform
        </p>

        <div className="settings-about-details">
          <div className="settings-about-row">
            <span className="settings-about-label">Version</span>
            <span className="settings-about-value">0.1.0</span>
          </div>
          <div className="settings-about-row">
            <span className="settings-about-label">Runtime</span>
            <span className="settings-about-value">Tauri v2 + React 18</span>
          </div>
          <div className="settings-about-row">
            <span className="settings-about-label">Terminal</span>
            <span className="settings-about-value">xterm.js + tauri-plugin-pty</span>
          </div>
          <div className="settings-about-row">
            <span className="settings-about-label">Tiling</span>
            <span className="settings-about-value">react-mosaic with drag &amp; drop</span>
          </div>
          <div className="settings-about-row">
            <span className="settings-about-label">Icons</span>
            <span className="settings-about-value">Lucide React</span>
          </div>
          <div className="settings-about-row">
            <span className="settings-about-label">Theme</span>
            <span className="settings-about-value">Catppuccin Mocha</span>
          </div>
        </div>

        <div className="settings-about-shortcuts">
          <h3 className="settings-section-title">Quick Reference</h3>
          <div className="settings-about-shortcut-grid">
            <kbd>Ctrl+H/J/K/L</kbd><span>Navigate panes</span>
            <kbd>Ctrl+A → H/J/K/L</kbd><span>Resize panes</span>
            <kbd>Ctrl+A → S/V</kbd><span>Split horizontal / vertical</span>
            <kbd>Ctrl+A → Q/X</kbd><span>Close / kill pane</span>
            <kbd>⌘P</kbd><span>Command palette</span>
            <kbd>⌘,</kbd><span>Settings</span>
            <kbd>⌘E</kbd><span>Toggle sidebar</span>
          </div>
        </div>
      </div>
    </div>
  );
}

export function SettingsPage({ config, mcpManager, onClose, onConfigChange }: SettingsPageProps) {
  const [activeTab, setActiveTab] = useState<SettingsTab>("general");

  return (
    <div className="settings-page">
      <header className="settings-page-header">
        <div className="settings-page-title-row">
          <SettingsIcon size={20} />
          <h1 className="settings-page-title">Settings</h1>
        </div>
        <button
          className="settings-close-btn"
          onClick={onClose}
          title="Close settings (Esc)"
          type="button"
        >
          <X size={18} />
        </button>
      </header>

      <nav className="settings-tab-bar">
        {TABS.map((tab) => (
          <button
            className={`settings-tab-btn ${activeTab === tab.id ? "active" : ""}`}
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
            type="button"
          >
            <tab.Icon size={15} />
            <span>{tab.label}</span>
          </button>
        ))}
      </nav>

      <div className="settings-page-content">
        {activeTab === "general" ? (
          <GeneralTab config={config} onConfigChange={onConfigChange} />
        ) : null}
        {activeTab === "shortcuts" ? <ShortcutsTab config={config} /> : null}
        {activeTab === "agents" ? <AgentsTab /> : null}
        {activeTab === "mcp" ? <McpServersTab mcpManager={mcpManager} /> : null}
        {activeTab === "about" ? <AboutTab /> : null}
      </div>
    </div>
  );
}
