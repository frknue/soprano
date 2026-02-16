import { useCallback, useEffect, useRef, useState } from "react";
import { Mosaic, MosaicPath, MosaicWindow } from "react-mosaic-component";
import { AgentHeader } from "./AgentHeader";
import { BrowserPane } from "./BrowserPane";
import { PaneTabBar } from "./PaneTabBar";
import { TerminalPane, TerminalRef } from "./TerminalPane";
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

type TerminalHandle = TerminalRef;

export function TilingLayout({ agentManager, maximizedPaneId, theme, outputMonitor, notifications }: TilingLayoutProps) {
  const [menuOpenPaneId, setMenuOpenPaneId] = useState<string | null>(null);
  const terminalRefs = useRef<Map<string, TerminalHandle>>(new Map());
  const agentManagerRef = useRef(agentManager);
  const outputMonitorRef = useRef(outputMonitor);
  const notificationsRef = useRef(notifications);
  const themeRef = useRef(theme);

  agentManagerRef.current = agentManager;
  outputMonitorRef.current = outputMonitor;
  notificationsRef.current = notifications;
  themeRef.current = theme;

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

  const handleStatusChange = useCallback((paneId: string, status: AgentStatus): void => {
    const am = agentManagerRef.current;
    am.updateAgentStatus(paneId, status);
    const pane = am.panes.get(paneId);
    if (!pane) {
      return;
    }
    const tab = activeTab(pane);
    const profile = tab.agent ? getAgentById(tab.agent.profileId) : undefined;

    if (!profile) {
      return;
    }

    const n = notificationsRef.current;
    if (status === "error") {
      n.notify(`${profile.name} error`, `${profile.name} reported an error`, "error", paneId);
    }

    if (status === "idle") {
      n.notify(`${profile.name} idle`, `${profile.name} is waiting for input`, "info", paneId);
    }

    if (status === "stopped") {
      n.notify(`${profile.name} stopped`, `${profile.name} process exited`, "warning", paneId);
    }
  }, []);

  const handleTerminalReady = useCallback((tabId: string, paneId: string, profileId: string | undefined, terminal: import("@xterm/xterm").Terminal): void => {
    outputMonitorRef.current.attachTerminal(tabId, terminal, paneId, profileId);
  }, []);

  const handleTerminalRef = useCallback((tabId: string, handle: TerminalRef | null): void => {
    if (!handle) {
      terminalRefs.current.delete(tabId);
      return;
    }
    terminalRefs.current.set(tabId, handle);
  }, []);

  const maximizedPane = maximizedPaneId ? agentManager.panes.get(maximizedPaneId) : undefined;

  const renderPaneBody = (paneId: string, pane: ReturnType<typeof agentManager.panes.get> & object): JSX.Element => {
    const tab = pane.tabs[pane.activeTabIndex];
    if (!tab) {
      return <div className="pane-tab-panels" />;
    }

    const isPaneActive = agentManager.activePaneId === paneId;
    const isBrowserVisible = (!maximizedPaneId || maximizedPaneId === paneId) && menuOpenPaneId !== paneId;

    return (
      <div className="pane-tab-panels">
        <div className="pane-tab-panel" key={tab.id}>
          {tab.type === "browser" ? (
            <BrowserPane
              isActive={isPaneActive}
              isVisible={isBrowserVisible}
              paneId={tab.id}
            />
          ) : (
            <TerminalPane
              isActive={isPaneActive}
              onStatusChange={(status) => handleStatusChange(paneId, status)}
              onTerminalReady={(terminal) =>
                handleTerminalReady(tab.id, paneId, tab.agent?.profileId, terminal)
              }
              paneId={tab.id}
              profileId={tab.agent?.profileId}
              terminalTheme={theme.terminal}
              ref={(handle) => handleTerminalRef(tab.id, handle)}
            />
          )}
        </div>
      </div>
    );
  };

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
                  onDuplicate={() => {
                    const tab = activeTab(pane);
                    if (tab.type === "agent" && tab.agent) {
                      agentManager.spawnAgent(tab.agent.profileId);
                    } else if (tab.type === "browser") {
                      agentManager.spawnBrowser();
                    } else {
                      agentManager.spawnTerminal();
                    }
                  }}
                  onClose={() => agentManager.closePane(paneId)}
                  onAddBrowser={() => agentManager.addTabToPane(paneId, "browser")}
                  onAddTerminal={() => agentManager.addTabToPane(paneId, "terminal")}
                  onChangeCwd={() => {
                    const newCwd = window.prompt("Enter new working directory:");
                    if (newCwd) {
                      const term = terminalRefs.current.get(currentTab.id);
                      if (term) {
                        term.sendText(`cd "${newCwd}"\n`);
                        term.focus();
                      }
                    }
                  }}
                  onMenuOpenChange={(open) => setMenuOpenPaneId(open ? paneId : null)}
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
