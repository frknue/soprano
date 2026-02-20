import { useCallback, useEffect, useRef, useState } from "react";
import { loadKeybindingConfig } from "../config/keybindings";
import { KeyBinding, KeyBindingConfig } from "../types/keybinding";
import { AgentManager } from "./useAgentManager";

export type KeybindingMode = "NORMAL" | "PREFIX";

function stopEvent(event: KeyboardEvent): void {
  event.preventDefault();
  event.stopPropagation();
}

interface KeybindingOptions {
  onSaveSession?: () => void;
  onToggleSidebar?: () => void;
  onOpenSettings?: () => void;
  onToggleMaximize?: () => void;
  getActiveCwd?: () => Promise<string | undefined>;
}

function matchDirectBinding(event: KeyboardEvent, binding: KeyBinding): boolean {
  return (
    event.key.toLowerCase() === binding.key &&
    event.ctrlKey === !!binding.ctrl &&
    event.metaKey === !!binding.meta &&
    event.shiftKey === !!binding.shift
  );
}

export type PaletteMode = "commands" | "projects";

export function useKeybindings(
  agentManager: AgentManager,
  callbacks: KeybindingOptions = {},
): {
  mode: KeybindingMode;
  isPaletteOpen: boolean;
  paletteMode: PaletteMode;
  pendingAgentId: string | null;
  togglePalette: () => void;
  requestAgentLaunch: (profileId: string) => void;
  config: KeyBindingConfig;
  updateConfig: (config: KeyBindingConfig) => void;
} {
  const [config, setConfig] = useState<KeyBindingConfig>(() => loadKeybindingConfig());
  const [mode, setMode] = useState<KeybindingMode>("NORMAL");
  const [isPaletteOpen, setPaletteOpen] = useState(false);
  const [paletteMode, setPaletteMode] = useState<PaletteMode>("commands");
  const [pendingAgentId, setPendingAgentId] = useState<string | null>(null);
  const prefixTimerRef = useRef<number | null>(null);
  const modeRef = useRef<KeybindingMode>("NORMAL");

  const agentManagerRef = useRef(agentManager);
  agentManagerRef.current = agentManager;

  const callbacksRef = useRef(callbacks);
  callbacksRef.current = callbacks;

  const togglePalette = useCallback((): void => {
    setPaletteOpen((prev) => {
      if (prev) {
        setPaletteMode("commands");
        setPendingAgentId(null);
      }
      return !prev;
    });
  }, []);

  const requestAgentLaunch = useCallback((profileId: string): void => {
    setPendingAgentId(profileId);
    setPaletteMode("projects");
    setPaletteOpen(true);
  }, []);

  const togglePaletteRef = useRef(togglePalette);
  togglePaletteRef.current = togglePalette;

  const requestAgentLaunchRef = useRef(requestAgentLaunch);
  requestAgentLaunchRef.current = requestAgentLaunch;

  const openProjectSearchRef = useRef((): void => {
    setPendingAgentId(null);
    setPaletteMode("projects");
    setPaletteOpen(true);
  });
  openProjectSearchRef.current = (): void => {
    setPendingAgentId(null);
    setPaletteMode("projects");
    setPaletteOpen(true);
  };

  useEffect(() => {
    const clearPrefixMode = (): void => {
      modeRef.current = "NORMAL";
      setMode("NORMAL");
      if (prefixTimerRef.current !== null) {
        window.clearTimeout(prefixTimerRef.current);
        prefixTimerRef.current = null;
      }
    };

    const startPrefixMode = (): void => {
      modeRef.current = "PREFIX";
      setMode("PREFIX");
      if (prefixTimerRef.current !== null) {
        window.clearTimeout(prefixTimerRef.current);
      }

      prefixTimerRef.current = window.setTimeout(() => {
        modeRef.current = "NORMAL";
        setMode("NORMAL");
        prefixTimerRef.current = null;
      }, config.prefixTimeoutMs);
    };

    const spawnTerminalWithCwd = (): void => {
      const mgr = agentManagerRef.current;
      const cbs = callbacksRef.current;
      if (cbs.getActiveCwd) {
        cbs.getActiveCwd().then((cwd) => mgr.spawnTerminal(cwd));
      } else {
        mgr.spawnTerminal();
      }
    };

    const executeBinding = (binding: KeyBinding): void => {
      const mgr = agentManagerRef.current;
      const cbs = callbacksRef.current;

      const actions: Record<string, () => void> = {
         "nav-left": () => mgr.navigateToPane("left"),
         "nav-right": () => mgr.navigateToPane("right"),
         "nav-up": () => mgr.navigateToPane("up"),
         "nav-down": () => mgr.navigateToPane("down"),
         "resize-left": () => mgr.resizePane("left", config.resizeTickPercent),
         "resize-right": () => mgr.resizePane("right", config.resizeTickPercent),
         "resize-up": () => mgr.resizePane("up", config.resizeTickPercent),
         "resize-down": () => mgr.resizePane("down", config.resizeTickPercent),
         "split-horizontal": () => mgr.splitPane("column", mgr.activePaneId),
         "split-vertical": () => mgr.splitPane("row", mgr.activePaneId),
         "close-pane": () => mgr.closePane(mgr.activePaneId),
         "kill-pane": () => mgr.closePane(mgr.activePaneId),
         "new-pane-tab": () => mgr.addTabToPane(mgr.activePaneId, "terminal"),
         "next-pane-tab": () => mgr.nextTab(mgr.activePaneId),
         "prev-pane-tab": () => mgr.prevTab(mgr.activePaneId),
         "close-pane-tab": () => {
           const pane = mgr.panes.get(mgr.activePaneId);
           if (pane && pane.tabs.length > 0) {
             const tab = pane.tabs[pane.activeTabIndex];
             if (tab) mgr.removeTabFromPane(mgr.activePaneId, tab.id);
           }
         },
         "launch-codex": () => requestAgentLaunchRef.current("codex"),
         "launch-claude-code": () => requestAgentLaunchRef.current("claude-code"),
         "launch-opencode": () => requestAgentLaunchRef.current("opencode"),
         "launch-openclaw": () => requestAgentLaunchRef.current("openclaw"),
         "command-palette": () => togglePaletteRef.current(),
         "open-project": () => openProjectSearchRef.current(),
         "new-terminal": spawnTerminalWithCwd,
         "new-browser": () => mgr.spawnBrowser(),
         "close-active": () => mgr.closePane(mgr.activePaneId),
         "save-session": () => cbs.onSaveSession?.(),
         "toggle-sidebar": () => cbs.onToggleSidebar?.(),
          "open-settings": () => cbs.onOpenSettings?.(),
           "maximize-pane": () => cbs.onToggleMaximize?.(),
           "zoom-in": () => window.dispatchEvent(new CustomEvent("soprano-zoom", { detail: { delta: 1 } })),
          "zoom-out": () => window.dispatchEvent(new CustomEvent("soprano-zoom", { detail: { delta: -1 } })),
          "zoom-reset": () => window.dispatchEvent(new CustomEvent("soprano-zoom", { detail: { reset: true } } )),
       };

      const action = actions[binding.id];
      if (action) {
        action();
      }
    };

    const isTextInput = (): boolean => {
      return document.activeElement instanceof HTMLInputElement;
    };

    const handleKeyDown = (event: KeyboardEvent): void => {
      const normalizedKey = event.key.toLowerCase();
      const inputFocused = isTextInput();

      if (inputFocused && !event.metaKey) {
        return;
      }

      const isPrefixActivation =
        event.ctrlKey && normalizedKey === config.prefixKey && !event.metaKey && !event.shiftKey;

      if (isPrefixActivation) {
        stopEvent(event);
        startPrefixMode();
        return;
      }

      if (modeRef.current === "PREFIX") {
        stopEvent(event);
        const prefixBinding = config.bindings.find(
          (binding) => binding.mode === "prefix" && binding.key === normalizedKey,
        );
        if (prefixBinding) {
          executeBinding(prefixBinding);
        }
        clearPrefixMode();
        return;
      }

      const directBinding = config.bindings.find(
        (binding) => binding.mode === "direct" && matchDirectBinding(event, binding),
      );
      if (!directBinding) {
        return;
      }

      stopEvent(event);
      executeBinding(directBinding);
    };

    window.addEventListener("keydown", handleKeyDown, { capture: true });

    return () => {
      window.removeEventListener("keydown", handleKeyDown, { capture: true });
      if (prefixTimerRef.current !== null) {
        window.clearTimeout(prefixTimerRef.current);
        prefixTimerRef.current = null;
      }
    };
  }, [config]);

  return { mode, isPaletteOpen, paletteMode, pendingAgentId, togglePalette, requestAgentLaunch, config, updateConfig: setConfig };
}
