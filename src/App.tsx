import { useCallback, useEffect, useRef, useState } from "react";
import { MosaicNode } from "react-mosaic-component";
import { CommandPalette } from "./components/CommandPalette";
import { SettingsPage } from "./components/SettingsPage";
import { Sidebar, SidebarSection } from "./components/Sidebar";
import { StatusBar } from "./components/StatusBar";
import { TilingLayout } from "./components/TilingLayout";
import {
  AppSettings,
  loadAppSettings,
  loadLastSession,
  saveAppSettings,
  saveLastSession,
  SavedWorkspace,
} from "./config/settings";
import { useKeybindings } from "./hooks/useKeybindings";
import { useAgentManager } from "./hooks/useAgentManager";
import { useMcpManager } from "./hooks/useMcpManager";
import { useNotifications } from "./hooks/useNotifications";
import { useOutputMonitor } from "./hooks/useOutputMonitor";
import { useSessionManager } from "./hooks/useSessionManager";
import { useTheme, applyThemeSync } from "./hooks/useTheme";

function collectLayoutPaneIds(node: MosaicNode<string> | null): Set<string> {
  const ids = new Set<string>();
  if (node === null) return ids;
  if (typeof node === "string") {
    ids.add(node);
    return ids;
  }
  for (const id of collectLayoutPaneIds(node.first)) ids.add(id);
  for (const id of collectLayoutPaneIds(node.second)) ids.add(id);
  return ids;
}

const initialSettings = loadAppSettings();
const initialWorkspace = initialSettings.restoreLastSession ? loadLastSession() : null;

applyThemeSync(initialSettings.themeId);

export default function App() {
  const agentManager = useAgentManager(initialWorkspace);
  const mcpManager = useMcpManager();
  const themeManager = useTheme(initialSettings.themeId);
  const [appSettings, setAppSettings] = useState<AppSettings>(initialSettings);
  const outputMonitor = useOutputMonitor(agentManager);
  const sessionManager = useSessionManager(agentManager);
  const notifications = useNotifications();
  const [sidebarSection, setSidebarSection] = useState<SidebarSection | null>(null);
  const [showSettings, setShowSettings] = useState(false);
  const [maximizedPaneId, setMaximizedPaneId] = useState<string | null>(null);

  const toggleSettings = useCallback(() => {
    setShowSettings((prev) => !prev);
  }, []);

  const appSettingsRef = useRef(appSettings);
  appSettingsRef.current = appSettings;

  const updateAppSettings = useCallback((next: AppSettings) => {
    setAppSettings(next);
    saveAppSettings(next);
    themeManager.setThemeId(next.themeId);
  }, [themeManager.setThemeId]);

  const saveTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (!appSettingsRef.current.restoreLastSession) return;

    if (saveTimerRef.current) clearTimeout(saveTimerRef.current);

    saveTimerRef.current = setTimeout(() => {
      const layoutPaneIds = collectLayoutPaneIds(agentManager.layout);
      const workspace: SavedWorkspace = {
        layout: agentManager.layout,
        activePaneId: agentManager.activePaneId,
        panes: [...agentManager.panes.values()]
          .filter((pane) => layoutPaneIds.has(pane.id))
          .map((pane) => ({
            id: pane.id,
            activeTabIndex: pane.activeTabIndex,
            tabs: pane.tabs.map((tab) => ({
              id: tab.id,
              type: tab.type,
              profileId: tab.agent?.profileId,
            })),
          })),
        runningMcpServers: mcpManager.pool
          .filter((e) => e.instance.status === "running")
          .map((e) => e.config.id),
        savedAt: Date.now(),
      };
      saveLastSession(workspace);
    }, 800);

    return () => {
      if (saveTimerRef.current) clearTimeout(saveTimerRef.current);
    };
  }, [agentManager.layout, agentManager.panes, agentManager.activePaneId, mcpManager.pool]);

  useEffect(() => {
    if (!initialWorkspace?.runningMcpServers?.length) return;
    for (const serverId of initialWorkspace.runningMcpServers) {
      mcpManager.startServer(serverId);
    }
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const { mode, isPaletteOpen, togglePalette, config, updateConfig } = useKeybindings(agentManager, {
    onSaveSession: () => {
      const stamp = new Date().toLocaleString();
      sessionManager.saveSession(`Session ${stamp}`);
      notifications.notify("Session saved", `Workspace saved as Session ${stamp}`, "success");
    },
    onToggleSidebar: () => {
      setSidebarSection((prev) => (prev === null ? "agents" : null));
    },
    onOpenSettings: toggleSettings,
    onToggleMaximize: () => {
      setMaximizedPaneId((prev) => (prev ? null : agentManager.activePaneId));
    },
  });

  useEffect(() => {
    if (maximizedPaneId && agentManager.activePaneId !== maximizedPaneId) {
      setMaximizedPaneId(null);
    }
  }, [agentManager.activePaneId, maximizedPaneId]);

  return (
    <div className="app-shell">
      <div className="app-body">
        <Sidebar
          activeSection={sidebarSection}
          agentManager={agentManager}
          mcpManager={mcpManager}
          isSettingsOpen={showSettings}
          onOpenSettings={toggleSettings}
          onSectionChange={setSidebarSection}
          sessionManager={sessionManager}
        />
        <main className="app-main">
          {showSettings ? (
            <SettingsPage
              appSettings={appSettings}
              config={config}
              mcpManager={mcpManager}
              onAppSettingsChange={updateAppSettings}
              onClose={() => setShowSettings(false)}
              onConfigChange={updateConfig}
            />
          ) : (
            <TilingLayout agentManager={agentManager} maximizedPaneId={maximizedPaneId} notifications={notifications} outputMonitor={outputMonitor} theme={themeManager.theme} />
          )}
        </main>
      </div>
      <StatusBar agentManager={agentManager} mode={mode} notifications={notifications} />
      <CommandPalette
        agentManager={agentManager}
        config={config}
        isOpen={isPaletteOpen}
        onClose={togglePalette}
        sessionManager={sessionManager}
      />
    </div>
  );
}
