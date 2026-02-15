import { useEffect, useRef } from "react";
import { Mosaic, MosaicPath, MosaicWindow } from "react-mosaic-component";
import { AgentHeader } from "./AgentHeader";
import { BrowserPane } from "./BrowserPane";
import { PaneTabBar } from "./PaneTabBar";
import { TerminalPane } from "./TerminalPane";
import { useNotifications } from "../hooks/useNotifications";
import { useOutputMonitor } from "../hooks/useOutputMonitor";
import { AgentManager } from "../hooks/useAgentManager";
import { getAgentById } from "../config/agents";
import { AppTheme } from "../config/themes";
import { activeTab, AgentStatus, PaneTab } from "../types/agent";
import "react-mosaic-component/react-mosaic-component.css";

interface TilingLayoutProps {
  agentManager: AgentManager;
  maximizedPaneId: string | null;
  theme: AppTheme;
  outputMonitor: ReturnType<typeof useOutputMonitor>;
  notifications: ReturnType<typeof useNotifications>;
}

interface TerminalHandle {
  restart: () => void;
  stop: () => void;
}

export function TilingLayout({ agentManager, maximizedPaneId, theme, outputMonitor, notifications }: TilingLayoutProps) {
  const terminalRefs = useRef<Map<string, TerminalHandle>>(new Map());

  useEffect(() => {
    const known = terminalRefs.current;
    const liveTabIds = new Set<string>();
    agentManager.panes.forEach((pane) => {
      pane.tabs.forEach((tab) => liveTabIds.add(tab.id));
    });
    [...known.keys()].forEach((tabId) => {
      if (!liveTabIds.has(tabId)) {
        known.delete(tabId);
        outputMonitor.detachTerminal(tabId);
      }
    });
  }, [agentManager.panes, outputMonitor]);

  const handleStatusChange = (paneId: string, status: AgentStatus): void => {
    agentManager.updateAgentStatus(paneId, status);
    const pane = agentManager.panes.get(paneId);
    if (!pane) {
      return;
    }
    const tab = activeTab(pane);
    const profile = tab.agent ? getAgentById(tab.agent.profileId) : undefined;

    if (!profile) {
      return;
    }

    if (status === "error") {
      notifications.notify(`${profile.name} error`, `${profile.name} reported an error`, "error", paneId);
    }

    if (status === "idle") {
      notifications.notify(`${profile.name} idle`, `${profile.name} is waiting for input`, "info", paneId);
    }

    if (status === "stopped") {
      notifications.notify(`${profile.name} stopped`, `${profile.name} process exited`, "warning", paneId);
    }
  };

  const maximizedPane = maximizedPaneId ? agentManager.panes.get(maximizedPaneId) : undefined;

  const renderPaneBody = (paneId: string, pane: ReturnType<typeof agentManager.panes.get> & object): JSX.Element => (
    <div className="pane-tab-panels">
      {pane.tabs.map((tab, index) => (
        <div
          className={`pane-tab-panel ${index === pane.activeTabIndex ? "" : "hidden"}`}
          key={tab.id}
        >
          {tab.type === "browser" ? (
            <BrowserPane
              isActive={agentManager.activePaneId === paneId && index === pane.activeTabIndex}
              isVisible={index === pane.activeTabIndex}
              paneId={tab.id}
            />
          ) : (
            <TerminalPane
              isActive={agentManager.activePaneId === paneId && index === pane.activeTabIndex}
              onStatusChange={(status) => handleStatusChange(paneId, status)}
              onTerminalReady={(terminal) =>
                outputMonitor.attachTerminal(tab.id, terminal, paneId, tab.agent?.profileId)
              }
              paneId={tab.id}
              profileId={tab.agent?.profileId}
              terminalTheme={theme.terminal}
              ref={(handle) => {
                if (!handle) {
                  terminalRefs.current.delete(tab.id);
                  outputMonitor.detachTerminal(tab.id);
                  return;
                }

                terminalRefs.current.set(tab.id, {
                  restart: handle.restart,
                  stop: handle.stop,
                });
              }}
            />
          )}
        </div>
      ))}
    </div>
  );

  return (
    <div className="tiling-layout">
      <Mosaic<string>
        className="soprano-mosaic"
        onChange={(nextLayout) => {
          agentManager.setLayout(nextLayout);
        }}
        renderTile={(paneId: string, path: MosaicPath) => {
          const pane = agentManager.panes.get(paneId);

          if (!pane) {
            return <div className="pane pane-missing">Pane not found</div>;
          }

          const currentTab: PaneTab = activeTab(pane);
          const title = currentTab.title;

          return (
            <MosaicWindow<string>
              createNode={() => agentManager.createMosaicNode()}
              path={path}
              title={title}
              toolbarControls={
                <AgentHeader
                  onRestart={() => {
                    agentManager.restartAgent(paneId);
                    terminalRefs.current.get(currentTab.id)?.restart();
                  }}
                  onStop={() => {
                    terminalRefs.current.get(currentTab.id)?.stop();
                    agentManager.stopAgent(paneId);
                  }}
                  pane={pane}
                />
              }
            >
              <div
                className="pane-body"
                onMouseDown={() => agentManager.focusPane(paneId)}
                onFocus={() => agentManager.focusPane(paneId)}
                role="presentation"
              >
                {renderPaneBody(paneId, pane)}
                {pane.tabs.length > 1 && (
                  <PaneTabBar
                    activeIndex={pane.activeTabIndex}
                    onClose={(tabId) => agentManager.removeTabFromPane(paneId, tabId)}
                    onSwitch={(index) => agentManager.switchTab(paneId, index)}
                    tabs={pane.tabs}
                  />
                )}
              </div>
            </MosaicWindow>
          );
        }}
        value={agentManager.layout}
      />

      {maximizedPane && maximizedPaneId && (
        <div
          className="pane-body pane-maximized"
          onMouseDown={() => agentManager.focusPane(maximizedPaneId)}
          onFocus={() => agentManager.focusPane(maximizedPaneId)}
          role="presentation"
        >
          {renderPaneBody(maximizedPaneId, maximizedPane)}
          {maximizedPane.tabs.length > 1 && (
            <PaneTabBar
              activeIndex={maximizedPane.activeTabIndex}
              onClose={(tabId) => agentManager.removeTabFromPane(maximizedPaneId, tabId)}
              onSwitch={(index) => agentManager.switchTab(maximizedPaneId, index)}
              tabs={maximizedPane.tabs}
            />
          )}
        </div>
      )}
    </div>
  );
}
