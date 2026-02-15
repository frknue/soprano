import { ReactNode, useRef, useState } from "react";
import * as Tooltip from "@radix-ui/react-tooltip";
import {
  ArrowUpRight,
  Bot,
  Globe,
  History,
  LayoutGrid,
  Settings,
  Terminal,
  Trash2,
  X,
  type LucideIcon,
} from "lucide-react";
import { DEFAULT_AGENTS, getAgentById } from "../config/agents";
import { AgentIcon } from "./AgentIcon";
import { AgentManager } from "../hooks/useAgentManager";
import { useSessionManager } from "../hooks/useSessionManager";
import { activeTab } from "../types/agent";

export type SidebarSection = "agents" | "panes" | "sessions" | "settings";

interface SidebarProps {
  agentManager: AgentManager;
  activeSection: SidebarSection | null;
  onSectionChange: (section: SidebarSection | null) => void;
  sessionManager: ReturnType<typeof useSessionManager>;
  isSettingsOpen: boolean;
  onOpenSettings: () => void;
}

const SECTION_META: Array<{
  id: SidebarSection;
  Icon: LucideIcon;
  label: string;
  bottom?: boolean;
}> = [
  { id: "agents", Icon: Bot, label: "Agents" },
  { id: "panes", Icon: LayoutGrid, label: "Panes" },
  { id: "sessions", Icon: History, label: "Sessions" },
  { id: "settings", Icon: Settings, label: "Settings", bottom: true },
];

function ActivityTooltip({ label, children }: { label: string; children: ReactNode }) {
  return (
    <Tooltip.Root>
      <Tooltip.Trigger asChild>{children}</Tooltip.Trigger>
      <Tooltip.Portal>
        <Tooltip.Content className="tooltip-content" side="right" sideOffset={8}>
          {label}
        </Tooltip.Content>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}

function AgentLauncherPanel({ agentManager }: { agentManager: AgentManager }) {
  const launchable = DEFAULT_AGENTS.filter((a) => a.id !== "terminal");

  return (
    <div>
      <div className="sidebar-section-label">AI Agents</div>
      {launchable.map((agent) => (
        <button
          className="sidebar-agent-item"
          key={agent.id}
          onClick={() => agentManager.spawnAgent(agent.id)}
          title={agent.description}
          type="button"
        >
          <span className="sidebar-agent-icon">
            <AgentIcon name={agent.icon} size={18} style={{ color: agent.color }} />
          </span>
          <div className="sidebar-agent-info">
            <div className="sidebar-agent-name">{agent.name}</div>
            <div className="sidebar-agent-desc">{agent.description}</div>
          </div>
        </button>
      ))}

      <div className="sidebar-section-label spaced">Tools</div>
      <button
        className="sidebar-agent-item"
        onClick={() => agentManager.spawnTerminal()}
        type="button"
      >
        <span className="sidebar-agent-icon">
          <Terminal size={18} />
        </span>
        <div className="sidebar-agent-info">
          <div className="sidebar-agent-name">Terminal</div>
          <div className="sidebar-agent-desc">System login shell</div>
        </div>
      </button>
      <button
        className="sidebar-agent-item"
        onClick={() => agentManager.spawnBrowser()}
        type="button"
      >
        <span className="sidebar-agent-icon">
          <Globe size={18} />
        </span>
        <div className="sidebar-agent-info">
          <div className="sidebar-agent-name">Browser</div>
          <div className="sidebar-agent-desc">Embedded web browser</div>
        </div>
      </button>
    </div>
  );
}

function ActivePanesPanel({ agentManager }: { agentManager: AgentManager }) {
   const panes = [...agentManager.panes.values()];

   return (
     <div>
       <div className="sidebar-section-label">
         {`Open Panes (${agentManager.paneCount})`}
       </div>
       {panes.map((pane) => {
         const tab = activeTab(pane);
         const profile = tab.agent ? getAgentById(tab.agent.profileId) : undefined;
         const isActive = pane.id === agentManager.activePaneId;
         const iconName =
           tab.type === "browser"
             ? "globe"
             : tab.type === "terminal"
               ? "terminal"
               : (profile?.icon ?? "bot");

         return (
           <div
             className={`sidebar-pane-item ${isActive ? "active" : ""}`}
             key={pane.id}
             onClick={() => agentManager.focusPane(pane.id)}
             role="button"
             tabIndex={0}
           >
             <span className="sidebar-pane-icon">
               <AgentIcon name={iconName} size={14} />
             </span>
             <span className="sidebar-pane-title">{tab.title}</span>
             {pane.tabs.length > 1 && <span className="sidebar-pane-tab-count">{pane.tabs.length}</span>}
             {tab.agent ? (
               <span className={`agent-status-dot ${tab.agent.status}`} />
             ) : null}
             <button
               className="sidebar-pane-close"
               onClick={(e) => {
                 e.stopPropagation();
                 agentManager.closePane(pane.id);
               }}
               title="Close pane"
               type="button"
             >
               <X size={12} />
             </button>
           </div>
         );
       })}
       {panes.length === 0 ? (
         <div className="sidebar-empty">No panes open</div>
       ) : null}
     </div>
   );
 }

function SessionsPanel({
  sessionManager,
}: {
  sessionManager: ReturnType<typeof useSessionManager>;
}) {
  const [sessionName, setSessionName] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);

  const handleSave = (): void => {
    const name = sessionName.trim();
    if (!name) {
      return;
    }

    sessionManager.saveSession(name);
    setSessionName("");
  };

  return (
    <div>
      <div className="sidebar-section-label">Save Current</div>
      <div className="sidebar-save-row">
        <input
          className="sidebar-input"
          onChange={(e) => setSessionName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              handleSave();
            }
          }}
          placeholder="Session name…"
          ref={inputRef}
          value={sessionName}
        />
        <button
          className="sidebar-save-btn"
          disabled={!sessionName.trim()}
          onClick={handleSave}
          type="button"
        >
          Save
        </button>
      </div>

      <div className="sidebar-section-label spaced">
        {`Saved (${sessionManager.sessions.length})`}
      </div>
      {sessionManager.sessions.map((session) => (
        <div className="sidebar-session-item" key={session.id}>
          <div className="sidebar-session-info">
            <div className="sidebar-session-name">{session.name}</div>
            <div className="sidebar-session-date">
              {new Date(session.savedAt).toLocaleDateString()}
            </div>
          </div>
          <div className="sidebar-session-actions">
            <button
              className="sidebar-action-btn"
              onClick={() => sessionManager.loadSession(session.id)}
              title="Load session"
              type="button"
            >
              <ArrowUpRight size={14} />
            </button>
            <button
              className="sidebar-action-btn danger"
              onClick={() => sessionManager.deleteSession(session.id)}
              title="Delete session"
              type="button"
            >
              <Trash2 size={14} />
            </button>
          </div>
        </div>
      ))}
      {sessionManager.sessions.length === 0 ? (
        <div className="sidebar-empty">No saved sessions</div>
      ) : null}
    </div>
  );
}

export function Sidebar({
  agentManager,
  activeSection,
  onSectionChange,
  sessionManager,
  isSettingsOpen,
  onOpenSettings,
}: SidebarProps) {
  const isOpen = activeSection !== null;

  const handleSectionClick = (section: SidebarSection): void => {
    if (section === "settings") {
      onSectionChange(null);
      onOpenSettings();
      return;
    }
    onSectionChange(activeSection === section ? null : section);
  };

  const topSections = SECTION_META.filter((s) => !s.bottom);
  const bottomSections = SECTION_META.filter((s) => s.bottom);
  const sectionLabel = SECTION_META.find((s) => s.id === activeSection)?.label.toUpperCase() ?? "";

  return (
    <>
      <Tooltip.Provider delayDuration={400} skipDelayDuration={100}>
        <nav className="activity-bar" aria-label="Sidebar navigation">
          <div className="activity-top">
            {topSections.map((section) => (
              <ActivityTooltip key={section.id} label={section.label}>
                <button
                  aria-pressed={activeSection === section.id}
                  className={`activity-button ${activeSection === section.id ? "active" : ""}`}
                  onClick={() => handleSectionClick(section.id)}
                  type="button"
                >
                  <section.Icon size={20} />
                </button>
              </ActivityTooltip>
            ))}
          </div>
          <div className="activity-bottom">
            {bottomSections.map((section) => {
              const isActive = section.id === "settings" ? isSettingsOpen : activeSection === section.id;
              return (
                <ActivityTooltip key={section.id} label={section.label}>
                  <button
                    aria-pressed={isActive}
                    className={`activity-button ${isActive ? "active" : ""}`}
                    onClick={() => handleSectionClick(section.id)}
                    type="button"
                  >
                    <section.Icon size={20} />
                  </button>
                </ActivityTooltip>
              );
            })}
          </div>
        </nav>
      </Tooltip.Provider>

      {isOpen ? (
        <aside className="sidebar-panel">
          <div className="sidebar-header">
            <span className="sidebar-title">{sectionLabel}</span>
          </div>
          <div className="sidebar-content">
            {activeSection === "agents" ? (
              <AgentLauncherPanel agentManager={agentManager} />
            ) : null}
            {activeSection === "panes" ? (
              <ActivePanesPanel agentManager={agentManager} />
            ) : null}
            {activeSection === "sessions" ? (
              <SessionsPanel sessionManager={sessionManager} />
            ) : null}

          </div>
        </aside>
      ) : null}
    </>
  );
}
