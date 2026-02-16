import { CSSProperties, ReactNode, useEffect, useRef, useState } from "react";
import { Copy, Globe, MoreHorizontal, RotateCcw, Square, Terminal, X, FolderOpen } from "lucide-react";
import { getAgentById } from "../config/agents";
import { AgentIcon } from "./AgentIcon";
import { PaneState, activeTab, AgentStatus } from "../types/agent";

interface AgentHeaderProps {
  pane: PaneState;
  onRestart: () => void;
  onStop: () => void;
  onDuplicate: () => void;
  onClose: () => void;
  onAddBrowser: () => void;
  onAddTerminal: () => void;
  onChangeCwd: () => void;
  onMenuOpenChange?: (isOpen: boolean) => void;
}

const statusLabels: Record<AgentStatus, string> = {
  starting: "starting",
  running: "running",
  idle: "idle",
  error: "error",
  stopped: "stopped",
};

export function AgentHeader({
  pane,
  onRestart,
  onStop,
  onDuplicate,
  onClose,
  onAddBrowser,
  onAddTerminal,
  onChangeCwd,
  onMenuOpenChange,
}: AgentHeaderProps) {
  const [isOpen, setIsOpen] = useState(false);

  useEffect(() => {
    onMenuOpenChange?.(isOpen);
  }, [isOpen, onMenuOpenChange]);
  const dropdownRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    function handleClickOutside(event: MouseEvent) {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target as Node)) {
        setIsOpen(false);
      }
    }

    if (isOpen) {
      document.addEventListener("mousedown", handleClickOutside);
    }

    return () => {
      document.removeEventListener("mousedown", handleClickOutside);
    };
  }, [isOpen]);

  const handleAction = (action: () => void) => {
    action();
    setIsOpen(false);
  };

  const tab = activeTab(pane);

  let icon: ReactNode;
  let name: string;

  if (tab.type === "browser") {
    icon = <Globe size={14} />;
    name = "Browser";
  } else if (tab.type === "terminal") {
    icon = <Terminal size={14} />;
    name = "Terminal";
  } else {
    const profile = tab.agent ? getAgentById(tab.agent.profileId) : undefined;
    icon = <AgentIcon name={profile?.icon ?? "bot"} size={14} />;
    name = profile?.name ?? tab.title;
  }

  const profile = tab.agent ? getAgentById(tab.agent.profileId) : undefined;
  const status = tab.agent?.status ?? "stopped";
  
  const style: CSSProperties & Record<"--agent-accent", string> = {
    "--agent-accent": profile?.color ?? "var(--accent)",
  };

  return (
    <div className="agent-header" style={style}>
      <div className="agent-header-left">
        <span className="agent-header-icon">{icon}</span>
        <span className="agent-header-name">{name}</span>
        {tab.type === "agent" && (
          <span className="agent-status-badge">
            <span className={`agent-status-dot ${status}`} />
            <span>{statusLabels[status]}</span>
          </span>
        )}
      </div>
      <div className="agent-header-controls">
        {tab.type === "agent" && (
          <>
            <button
              className="pane-toolbar-button"
              onClick={onRestart}
              title="Restart agent"
              type="button"
            >
              <RotateCcw size={12} />
            </button>
            <button
              className="pane-toolbar-button danger"
              onClick={onStop}
              title="Stop agent"
              type="button"
            >
              <Square size={12} />
            </button>
          </>
        )}

        <div className="pane-dropdown-wrapper" ref={dropdownRef}>
          <button
            className="pane-toolbar-button"
            title="More actions"
            type="button"
            onClick={() => setIsOpen(!isOpen)}
          >
            <MoreHorizontal size={12} />
          </button>

          {isOpen && (
            <div className="pane-dropdown-menu">
              <button
                className="pane-dropdown-item"
                onClick={() => handleAction(onDuplicate)}
                type="button"
              >
                <Copy size={12} />
                <span>Duplicate pane</span>
              </button>

              <div className="pane-dropdown-separator" />

              <button
                className="pane-dropdown-item"
                onClick={() => handleAction(onAddBrowser)}
                type="button"
              >
                <Globe size={12} />
                <span>Open browser tab</span>
              </button>

              <button
                className="pane-dropdown-item"
                onClick={() => handleAction(onAddTerminal)}
                type="button"
              >
                <Terminal size={12} />
                <span>Open terminal tab</span>
              </button>

              {(tab.type === "terminal" || tab.type === "agent") && (
                <button
                  className="pane-dropdown-item"
                  onClick={() => handleAction(onChangeCwd)}
                  type="button"
                  title="Change directory"
                >
                  <FolderOpen size={12} />
                  <span>Change directory...</span>
                </button>
              )}

              <div className="pane-dropdown-separator" />

              <button
                className="pane-dropdown-item danger"
                onClick={() => handleAction(onClose)}
                type="button"
              >
                <X size={12} />
                <span>Close pane</span>
              </button>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
