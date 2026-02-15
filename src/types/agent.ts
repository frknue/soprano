export type AgentStatus = "idle" | "starting" | "running" | "error" | "stopped";

export interface AgentProfile {
  id: string;
  name: string;
  icon: string;
  color: string;
  description: string;
  command: string;
  args: string[];
  env?: Record<string, string>;
  cwd?: string;
  launchScript?: string;
  autoRestart?: boolean;
  restartDelayMs?: number;
  patterns?: {
    ready?: string[];
    error?: string[];
    idle?: string[];
    completion?: string[];
  };
}

export interface AgentInstance {
  id: string;
  profileId: string;
  status: AgentStatus;
  startedAt: number | null;
  exitCode: number | null;
  restartCount: number;
}

export type PaneType = "agent" | "browser" | "terminal";

export interface PaneTab {
  id: string;
  type: PaneType;
  title: string;
  agent?: AgentInstance;
}

export interface PaneState {
  id: string;
  tabs: PaneTab[];
  activeTabIndex: number;
}

export function activeTab(pane: PaneState): PaneTab {
  return pane.tabs[pane.activeTabIndex];
}
