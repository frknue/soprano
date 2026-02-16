import { memo } from "react";
import { KeybindingMode } from "../hooks/useKeybindings";
import { useNotifications } from "../hooks/useNotifications";
import { AgentManager } from "../hooks/useAgentManager";
import { AgentIcon } from "./AgentIcon";
import { getAgentById } from "../config/agents";
import { activeTab } from "../types/agent";

interface StatusBarProps {
  agentManager: AgentManager;
  mode: KeybindingMode;
  notifications: ReturnType<typeof useNotifications>;
}

export const StatusBar = memo(function StatusBar({ agentManager, mode, notifications }: StatusBarProps) {
  const panes = [...agentManager.panes.values()];
  const activePane = agentManager.panes.get(agentManager.activePaneId);
  const activeTypeLabel = activePane ? activeTab(activePane).type.toUpperCase() : "NONE";
  const undismissedCount = notifications.notifications.filter((item) => !item.dismissed).length;

  return (
    <footer className="status-bar">
      <div className="status-left">
        <span className="status-brand">SOPRANO</span>
        <span className={`status-mode ${mode === "PREFIX" ? "prefix" : "normal"}`}>{mode}</span>
        {undismissedCount > 0 ? <span className="notification-badge">{undismissedCount}</span> : null}
      </div>

      <div className="status-center" role="tablist" aria-label="Open panes">
         {panes.map((pane) => {
           const tab = activeTab(pane);
           const iconName =
             tab.type === "browser"
               ? "globe"
               : tab.type === "terminal"
                 ? "terminal"
                 : (getAgentById(tab.agent?.profileId ?? "")?.icon ?? "bot");

           return (
             <button
               aria-selected={pane.id === agentManager.activePaneId}
               className={`status-tab ${pane.id === agentManager.activePaneId ? "active" : ""}`}
               key={pane.id}
               onClick={() => agentManager.focusPane(pane.id)}
               role="tab"
               type="button"
             >
               <AgentIcon name={iconName} size={12} />
               <span>{tab.title}</span>
               {tab.type === "agent" && tab.agent ? (
                 <span className={`agent-status-dot ${tab.agent.status}`} aria-hidden="true" />
               ) : null}
             </button>
           );
         })}
       </div>

      <div className="status-right">
        <span>{`PANES ${agentManager.paneCount}`}</span>
        {undismissedCount > 0 ? <span>{`NOTIFY ${undismissedCount}`}</span> : null}
        <span>{`TYPE ${activeTypeLabel}`}</span>
      </div>
    </footer>
  );
});
