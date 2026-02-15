import { useCallback, useEffect, useState } from "react";
import { CommandPalette } from "./components/CommandPalette";
import { SettingsPage } from "./components/SettingsPage";
import { Sidebar, SidebarSection } from "./components/Sidebar";
import { StatusBar } from "./components/StatusBar";
import { TilingLayout } from "./components/TilingLayout";
import { useKeybindings } from "./hooks/useKeybindings";
import { useAgentManager } from "./hooks/useAgentManager";
import { useMcpManager } from "./hooks/useMcpManager";
import { useNotifications } from "./hooks/useNotifications";
import { useOutputMonitor } from "./hooks/useOutputMonitor";
import { useSessionManager } from "./hooks/useSessionManager";

export default function App() {
  const agentManager = useAgentManager();
  const mcpManager = useMcpManager();
  const outputMonitor = useOutputMonitor(agentManager);
  const sessionManager = useSessionManager(agentManager);
  const notifications = useNotifications();
  const [sidebarSection, setSidebarSection] = useState<SidebarSection | null>(null);
  const [showSettings, setShowSettings] = useState(false);
  const [maximizedPaneId, setMaximizedPaneId] = useState<string | null>(null);

  const toggleSettings = useCallback(() => {
    setShowSettings((prev) => !prev);
  }, []);

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
              config={config}
              mcpManager={mcpManager}
              onClose={() => setShowSettings(false)}
              onConfigChange={updateConfig}
            />
          ) : (
            <TilingLayout agentManager={agentManager} maximizedPaneId={maximizedPaneId} notifications={notifications} outputMonitor={outputMonitor} />
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
