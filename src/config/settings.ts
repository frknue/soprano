import { MosaicNode } from "react-mosaic-component";
import { PaneType } from "../types/agent";

export interface AppSettings {
  restoreLastSession: boolean;
  themeId: string;
  projectDirectories: string[];
}

export interface SavedWorkspace {
  layout: MosaicNode<string> | null;
  panes: Array<{
    id: string;
    activeTabIndex: number;
    tabs: Array<{ id: string; type: PaneType; profileId?: string }>;
  }>;
  activePaneId: string;
  runningMcpServers?: string[];
  savedAt: number;
}

const SETTINGS_KEY = "soprano-app-settings";
const LAST_SESSION_KEY = "soprano-last-session";

const DEFAULT_SETTINGS: AppSettings = {
  restoreLastSession: true,
  themeId: "gruvbox-dark",
  projectDirectories: [],
};

export function loadAppSettings(): AppSettings {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY);
    if (!raw) return { ...DEFAULT_SETTINGS };
    const parsed = JSON.parse(raw) as Partial<AppSettings>;
    return { ...DEFAULT_SETTINGS, ...parsed };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

export function saveAppSettings(settings: AppSettings): void {
  localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings));
}

export function loadLastSession(): SavedWorkspace | null {
  try {
    const raw = localStorage.getItem(LAST_SESSION_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as SavedWorkspace;
    if (!parsed.panes || parsed.panes.length === 0) return null;
    return parsed;
  } catch {
    return null;
  }
}

export function saveLastSession(workspace: SavedWorkspace): void {
  localStorage.setItem(LAST_SESSION_KEY, JSON.stringify(workspace));
}

export function clearLastSession(): void {
  localStorage.removeItem(LAST_SESSION_KEY);
}
