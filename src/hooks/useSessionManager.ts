import { useCallback, useEffect, useState } from "react";
import { MosaicNode } from "react-mosaic-component";
import { PaneType } from "../types/agent";
import { AgentManager } from "./useAgentManager";

interface WorkspaceSession {
  id: string;
  name: string;
  savedAt: number;
  layout: MosaicNode<string> | null;
  panes: Array<{ id: string; tabs: Array<{ id: string; type: PaneType; profileId?: string }> }>;
}

const SESSION_STORAGE_KEY = "soprano-sessions";

function parseSessions(raw: string | null): WorkspaceSession[] {
  if (!raw) {
    return [];
  }

  try {
    const value = JSON.parse(raw) as WorkspaceSession[];
    if (!Array.isArray(value)) {
      return [];
    }
    return value;
  } catch {
    return [];
  }
}

export function useSessionManager(agentManager: AgentManager): {
  sessions: WorkspaceSession[];
  saveSession: (name: string) => void;
  loadSession: (sessionId: string) => void;
  deleteSession: (sessionId: string) => void;
} {
  const [sessions, setSessions] = useState<WorkspaceSession[]>([]);

  useEffect(() => {
    setSessions(parseSessions(window.localStorage.getItem(SESSION_STORAGE_KEY)));
  }, []);

  const saveSession = useCallback(
    (name: string): void => {
      const trimmed = name.trim();
      if (!trimmed) {
        return;
      }

      const session: WorkspaceSession = {
        id: `session-${Date.now()}`,
        name: trimmed,
        savedAt: Date.now(),
        layout: agentManager.layout,
        panes: [...agentManager.panes.values()].map((pane) => ({
          id: pane.id,
          tabs: pane.tabs.map((tab) => ({
            id: tab.id,
            type: tab.type,
            profileId: tab.agent?.profileId,
          })),
        })),
      };

      setSessions((prev) => {
        const next = [session, ...prev];
        window.localStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify(next));
        return next;
      });
    },
    [agentManager.layout, agentManager.panes],
  );

  const loadSession = useCallback(
    (sessionId: string): void => {
      const session = sessions.find((item) => item.id === sessionId);
      if (!session || session.panes.length === 0) {
        return;
      }

      agentManager.restoreWorkspace(session.panes, session.layout);
    },
    [agentManager, sessions],
  );

  const deleteSession = useCallback((sessionId: string): void => {
    setSessions((prev) => {
      const next = prev.filter((item) => item.id !== sessionId);
      window.localStorage.setItem(SESSION_STORAGE_KEY, JSON.stringify(next));
      return next;
    });
  }, []);

  return {
    sessions,
    saveSession,
    loadSession,
    deleteSession,
  };
}

export type { WorkspaceSession };
