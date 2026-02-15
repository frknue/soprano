import { CSSProperties } from "react";
import { Globe, MoreHorizontal, RotateCcw, Square, Terminal } from "lucide-react";
import { getAgentById } from "../config/agents";
import { AgentIcon } from "./AgentIcon";
import { PaneState, activeTab, AgentStatus } from "../types/agent";

interface AgentHeaderProps {
  pane: PaneState;
  onRestart: () => void;
  onStop: () => void;
}

const statusLabels: Record<AgentStatus, string> = {
   starting: "starting",
   running: "running",
   idle: "idle",
   error: "error",
   stopped: "stopped",
 };

export function AgentHeader({ pane, onRestart, onStop }: AgentHeaderProps) {
   const tab = activeTab(pane);
   if (tab.type === "browser") {
     return (
       <div className="agent-header">
         <div className="agent-header-left">
           <span className="agent-header-icon"><Globe size={14} /></span>
           <span className="agent-header-name">Browser</span>
         </div>
       </div>
     );
   }

   if (tab.type === "terminal") {
     return (
       <div className="agent-header">
         <div className="agent-header-left">
           <span className="agent-header-icon"><Terminal size={14} /></span>
           <span className="agent-header-name">Terminal</span>
         </div>
       </div>
     );
   }

   const profile = tab.agent ? getAgentById(tab.agent.profileId) : undefined;
   const status = tab.agent?.status ?? "stopped";
   const style: CSSProperties & Record<"--agent-accent", string> = {
     "--agent-accent": profile?.color ?? "var(--accent)",
   };

   return (
     <div className="agent-header" style={style}>
       <div className="agent-header-left">
         <span className="agent-header-icon">
           <AgentIcon name={profile?.icon ?? "bot"} size={14} />
         </span>
         <span className="agent-header-name">{profile?.name ?? tab.title}</span>
         <span className="agent-status-badge">
           <span className={`agent-status-dot ${status}`} />
           <span>{statusLabels[status]}</span>
         </span>
       </div>
       <div className="agent-header-controls">
         <button className="pane-toolbar-button" onClick={onRestart} title="Restart agent" type="button">
           <RotateCcw size={12} />
         </button>
         <button className="pane-toolbar-button danger" onClick={onStop} title="Stop agent" type="button">
           <Square size={12} />
         </button>
         <button className="pane-toolbar-button" title="More actions" type="button">
           <MoreHorizontal size={12} />
         </button>
       </div>
     </div>
   );
 }
