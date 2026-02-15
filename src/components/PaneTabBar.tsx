import { Globe, Terminal, X } from "lucide-react";
import { getAgentById } from "../config/agents";
import { PaneTab } from "../types/agent";
import { AgentIcon } from "./AgentIcon";

interface PaneTabBarProps {
  tabs: PaneTab[];
  activeIndex: number;
  onSwitch: (index: number) => void;
  onClose: (tabId: string) => void;
}

function renderTabIcon(tab: PaneTab) {
  if (tab.type === "browser") {
    return <Globe size={12} />;
  }

  if (tab.type === "terminal") {
    return <Terminal size={12} />;
  }

  const profile = tab.agent ? getAgentById(tab.agent.profileId) : undefined;
  return <AgentIcon name={profile?.icon ?? "bot"} size={12} />;
}

export function PaneTabBar({ tabs, activeIndex, onSwitch, onClose }: PaneTabBarProps) {
  return (
    <div className="pane-tab-bar">
      {tabs.map((tab, index) => (
        <div
          className={`pane-tab ${index === activeIndex ? "active" : ""}`}
          key={tab.id}
          onClick={() => onSwitch(index)}
          onKeyDown={(event) => {
            if (event.key === "Enter" || event.key === " ") {
              event.preventDefault();
              onSwitch(index);
            }
          }}
          role="button"
          tabIndex={0}
        >
          {renderTabIcon(tab)}
          <span className="pane-tab-title">{tab.title}</span>
          <button
            className="pane-tab-close"
            onClick={(event) => {
              event.stopPropagation();
              onClose(tab.id);
            }}
            type="button"
          >
            <X size={10} />
          </button>
        </div>
      ))}
    </div>
  );
}
