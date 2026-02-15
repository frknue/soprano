import { KeyBinding, KeyBindingConfig } from "../types/keybinding";

const STORAGE_KEY = "soprano-keybindings";

export const DEFAULT_KEYBINDING_CONFIG: KeyBindingConfig = {
  prefixKey: "a",
  prefixTimeoutMs: 1500,
  resizeTickPercent: 5,
  bindings: [
    { id: "nav-left", label: "Focus Left", description: "Move focus to the left pane", category: "navigation", defaultKeys: "Ctrl+H", mode: "direct", key: "h", ctrl: true },
    { id: "nav-down", label: "Focus Down", description: "Move focus to the pane below", category: "navigation", defaultKeys: "Ctrl+J", mode: "direct", key: "j", ctrl: true },
    { id: "nav-up", label: "Focus Up", description: "Move focus to the pane above", category: "navigation", defaultKeys: "Ctrl+K", mode: "direct", key: "k", ctrl: true },
    { id: "nav-right", label: "Focus Right", description: "Move focus to the right pane", category: "navigation", defaultKeys: "Ctrl+L", mode: "direct", key: "l", ctrl: true },
    { id: "resize-left", label: "Resize Left", description: "Shrink pane from the left", category: "layout", defaultKeys: "Ctrl+A → H", mode: "prefix", key: "h" },
    { id: "resize-down", label: "Resize Down", description: "Shrink pane from below", category: "layout", defaultKeys: "Ctrl+A → J", mode: "prefix", key: "j" },
    { id: "resize-up", label: "Resize Up", description: "Shrink pane from above", category: "layout", defaultKeys: "Ctrl+A → K", mode: "prefix", key: "k" },
    { id: "resize-right", label: "Resize Right", description: "Grow pane to the right", category: "layout", defaultKeys: "Ctrl+A → L", mode: "prefix", key: "l" },
    { id: "split-horizontal", label: "Split Horizontal", description: "Split active pane horizontally", category: "layout", defaultKeys: "Ctrl+A → S", mode: "prefix", key: "s" },
     { id: "split-vertical", label: "Split Vertical", description: "Split active pane vertically", category: "layout", defaultKeys: "Ctrl+A → V", mode: "prefix", key: "v" },
     { id: "close-pane", label: "Close Pane", description: "Close the active pane", category: "layout", defaultKeys: "Ctrl+A → Q", mode: "prefix", key: "q" },
     { id: "kill-pane", label: "Kill Pane", description: "Kill the active pane (tmux-style)", category: "layout", defaultKeys: "Ctrl+A → X", mode: "prefix", key: "x" },
     { id: "new-pane-tab", label: "New Tab in Pane", description: "Open a new terminal tab in the active pane", category: "layout", defaultKeys: "Ctrl+A → T", mode: "prefix", key: "t" },
     { id: "next-pane-tab", label: "Next Tab", description: "Switch to next tab in the active pane", category: "layout", defaultKeys: "Ctrl+A → N", mode: "prefix", key: "n" },
     { id: "prev-pane-tab", label: "Previous Tab", description: "Switch to previous tab in the active pane", category: "layout", defaultKeys: "Ctrl+A → P", mode: "prefix", key: "p" },
     { id: "close-pane-tab", label: "Close Tab", description: "Close the active tab in the active pane", category: "layout", defaultKeys: "Ctrl+A → W", mode: "prefix", key: "w" },
    { id: "launch-codex", label: "Launch Codex", description: "Start Codex agent", category: "agents", defaultKeys: "⌘1", mode: "direct", key: "1", meta: true },
    { id: "launch-claude-code", label: "Launch Claude Code", description: "Start Claude Code agent", category: "agents", defaultKeys: "⌘2", mode: "direct", key: "2", meta: true },
    { id: "launch-opencode", label: "Launch OpenCode", description: "Start OpenCode agent", category: "agents", defaultKeys: "⌘3", mode: "direct", key: "3", meta: true },
    { id: "launch-openclaw", label: "Launch OpenClaw", description: "Start OpenClaw agent", category: "agents", defaultKeys: "⌘4", mode: "direct", key: "4", meta: true },
    { id: "command-palette", label: "Command Palette", description: "Open the command palette", category: "general", defaultKeys: "⌘P", mode: "direct", key: "p", meta: true },
    { id: "new-terminal", label: "New Terminal", description: "Open a plain terminal", category: "general", defaultKeys: "⌘T", mode: "direct", key: "t", meta: true },
    { id: "new-browser", label: "New Browser", description: "Open a browser pane", category: "general", defaultKeys: "⌘B", mode: "direct", key: "b", meta: true },
    { id: "close-active", label: "Close Active", description: "Close the active pane", category: "general", defaultKeys: "⌘W", mode: "direct", key: "w", meta: true },
    { id: "save-session", label: "Save Session", description: "Save current workspace session", category: "general", defaultKeys: "⌘⇧S", mode: "direct", key: "s", meta: true, shift: true },
    { id: "toggle-sidebar", label: "Toggle Sidebar", description: "Show or hide the sidebar panel", category: "general", defaultKeys: "⌘E", mode: "direct", key: "e", meta: true },
    { id: "open-settings", label: "Open Settings", description: "Open the settings page", category: "general", defaultKeys: "⌘,", mode: "direct", key: ",", meta: true },
  ],
};

function cloneDefaultConfig(): KeyBindingConfig {
  return {
    ...DEFAULT_KEYBINDING_CONFIG,
    bindings: DEFAULT_KEYBINDING_CONFIG.bindings.map((binding) => ({ ...binding })),
  };
}

export function loadKeybindingConfig(): KeyBindingConfig {
  if (typeof window === "undefined") {
    return cloneDefaultConfig();
  }

  const rawConfig = window.localStorage.getItem(STORAGE_KEY);
  if (!rawConfig) {
    return cloneDefaultConfig();
  }

  try {
    const parsed = JSON.parse(rawConfig) as KeyBindingConfig;
    if (
      typeof parsed.prefixKey !== "string" ||
      typeof parsed.prefixTimeoutMs !== "number" ||
      typeof parsed.resizeTickPercent !== "number" ||
      !Array.isArray(parsed.bindings)
    ) {
      return cloneDefaultConfig();
    }

    const sanitizedBindings: KeyBinding[] = parsed.bindings
      .filter((binding) => {
        return (
          typeof binding?.id === "string" &&
          typeof binding?.label === "string" &&
          typeof binding?.description === "string" &&
          (binding?.category === "navigation" ||
            binding?.category === "layout" ||
            binding?.category === "agents" ||
            binding?.category === "general") &&
          typeof binding?.defaultKeys === "string" &&
          (binding?.mode === "direct" || binding?.mode === "prefix") &&
          typeof binding?.key === "string"
        );
      })
      .map((binding) => ({ ...binding }));

    return {
      prefixKey: parsed.prefixKey.toLowerCase(),
      prefixTimeoutMs: parsed.prefixTimeoutMs,
      resizeTickPercent: parsed.resizeTickPercent,
      bindings: sanitizedBindings,
    };
  } catch {
    return cloneDefaultConfig();
  }
}

export function saveKeybindingConfig(config: KeyBindingConfig): void {
  if (typeof window === "undefined") {
    return;
  }

  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(config));
}

export function getBindingById(config: KeyBindingConfig, id: string): KeyBinding | undefined {
  return config.bindings.find((binding) => binding.id === id);
}
