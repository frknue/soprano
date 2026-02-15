import { useCallback, useRef } from "react";
import { IDisposable, Terminal } from "@xterm/xterm";
import { getAgentById } from "../config/agents";
import { AgentManager } from "./useAgentManager";

function matchesAny(source: string, patterns?: string[]): boolean {
  if (!patterns || patterns.length === 0) {
    return false;
  }

  return patterns.some((pattern) => source.includes(pattern));
}

export function useOutputMonitor(agentManager: AgentManager): {
  attachTerminal: (id: string, terminal: Terminal, paneId: string, profileId?: string) => void;
  detachTerminal: (id: string) => void;
} {
  const subscriptionsRef = useRef<Map<string, IDisposable>>(new Map());
  const buffersRef = useRef<Map<string, string>>(new Map());

  const detachTerminal = useCallback((id: string): void => {
    const subscription = subscriptionsRef.current.get(id);
    subscription?.dispose();
    subscriptionsRef.current.delete(id);
    buffersRef.current.delete(id);
  }, []);

  const attachTerminal = useCallback(
    (id: string, terminal: Terminal, paneId: string, profileId?: string): void => {
      detachTerminal(id);

      const profile = profileId ? getAgentById(profileId) : undefined;
      if (!profile) {
        return;
      }

      const disposable = terminal.onData((chunk) => {
        const previous = buffersRef.current.get(id) ?? "";
        const next = `${previous}${chunk}`.slice(-500);
        buffersRef.current.set(id, next);

        const patterns = profile.patterns;
        if (matchesAny(next, patterns?.error)) {
          agentManager.updateAgentStatus(paneId, "error");
          return;
        }

        if (matchesAny(next, patterns?.completion)) {
          try {
            void new Notification(`${profile.name} finished`, {
              body: `${profile.name} completed a task`,
            });
          } catch {
          }
          agentManager.updateAgentStatus(paneId, "idle");
          return;
        }

        if (matchesAny(next, patterns?.ready)) {
          agentManager.updateAgentStatus(paneId, "running");
          return;
        }

        if (matchesAny(next, patterns?.idle)) {
          agentManager.updateAgentStatus(paneId, "idle");
        }
      });

      subscriptionsRef.current.set(id, disposable);
    },
    [agentManager, detachTerminal],
  );

  return {
    attachTerminal,
    detachTerminal,
  };
}
