import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { loadMcpConfigs, saveMcpConfigs } from "../config/mcp";
import {
  McpPoolEntry,
  McpServerConfig,
  McpServerInstance,
} from "../types/mcp";

interface RustMcpServerInfo {
  id: string;
  pid: number;
  port: number;
  running: boolean;
}

function createInstance(id: string): McpServerInstance {
  return {
    id,
    status: "stopped",
    pid: null,
    url: null,
    startedAt: null,
    error: null,
  };
}

function sseUrl(port: number): string {
  return `http://localhost:${port}/sse`;
}

export interface McpManager {
  pool: McpPoolEntry[];
  runningCount: number;
  startServer: (id: string) => Promise<void>;
  stopServer: (id: string) => Promise<void>;
  restartServer: (id: string) => Promise<void>;
  addServer: (config: McpServerConfig) => void;
  removeServer: (id: string) => Promise<void>;
  updateServer: (id: string, patch: Partial<McpServerConfig>) => void;
  getServerUrl: (id: string) => string | null;
}

export function useMcpManager(): McpManager {
  const [configs, setConfigs] = useState<McpServerConfig[]>(loadMcpConfigs);
  const [instances, setInstances] = useState<Map<string, McpServerInstance>>(() => {
    const map = new Map<string, McpServerInstance>();
    for (const config of loadMcpConfigs()) {
      map.set(config.id, createInstance(config.id));
    }
    return map;
  });

  const configsRef = useRef(configs);
  configsRef.current = configs;

  const persistConfigs = useCallback((next: McpServerConfig[]) => {
    setConfigs(next);
    saveMcpConfigs(next);
  }, []);

  const syncInstances = useCallback((nextConfigs: McpServerConfig[]) => {
    setInstances((prev) => {
      const next = new Map(prev);
      for (const config of nextConfigs) {
        if (!next.has(config.id)) {
          next.set(config.id, createInstance(config.id));
        }
      }
      return next;
    });
  }, []);

  const updateInstance = useCallback(
    (id: string, patch: Partial<McpServerInstance>) => {
      setInstances((prev) => {
        const existing = prev.get(id);
        if (!existing) return prev;
        const next = new Map(prev);
        next.set(id, { ...existing, ...patch });
        return next;
      });
    },
    [],
  );

  const syncAgentConfigs = useCallback(
    (runningOverrides?: Array<{ id: string; port: number; command: string; args: string[]; env: Record<string, string> }>) => {
      const servers = runningOverrides ??
        configsRef.current
          .filter((c) => {
            const inst = instances.get(c.id);
            return inst?.status === "running";
          })
          .map((c) => ({ id: c.id, port: c.port, command: c.command, args: c.args, env: c.env ?? {} }));

      invoke("sync_agent_mcp_configs", { servers }).catch(() => { });
    },
    [instances],
  );

  const startServer = useCallback(
    async (id: string) => {
      const config = configsRef.current.find((c) => c.id === id);
      if (!config) return;

      updateInstance(id, { status: "starting", error: null });

      try {
        const pid = await invoke<number>("spawn_mcp_server", {
          id: config.id,
          command: config.command,
          args: config.args,
          env: config.env ?? {},
          transport: config.transport,
          port: config.port,
        });

        updateInstance(id, {
          status: "running",
          pid,
          url: sseUrl(config.port),
          startedAt: Date.now(),
          error: null,
        });

        const currentRunning = configsRef.current
          .filter((c) => {
            if (c.id === id) return true;
            const inst = instances.get(c.id);
            return inst?.status === "running";
          })
          .map((c) => ({ id: c.id, port: c.port, command: c.command, args: c.args, env: c.env ?? {} }));
        syncAgentConfigs(currentRunning);
      } catch (err) {
        updateInstance(id, {
          status: "error",
          error: String(err),
          pid: null,
          url: null,
        });
      }
    },
    [updateInstance, instances, syncAgentConfigs],
  );

  const stopServer = useCallback(
    async (id: string) => {
      try {
        await invoke("stop_mcp_server", { id });
      } catch { }
      updateInstance(id, {
        status: "stopped",
        pid: null,
        url: null,
        startedAt: null,
        error: null,
      });

      const stillRunning = configsRef.current
        .filter((c) => {
          if (c.id === id) return false;
          const inst = instances.get(c.id);
          return inst?.status === "running";
        })
        .map((c) => ({ id: c.id, port: c.port, command: c.command, args: c.args, env: c.env ?? {} }));
      syncAgentConfigs(stillRunning);
    },
    [updateInstance, instances, syncAgentConfigs],
  );

  const restartServer = useCallback(
    async (id: string) => {
      await stopServer(id);
      await startServer(id);
    },
    [startServer, stopServer],
  );

  const addServer = useCallback(
    (config: McpServerConfig) => {
      const next = [...configsRef.current, config];
      persistConfigs(next);
      syncInstances(next);
    },
    [persistConfigs, syncInstances],
  );

  const removeServer = useCallback(
    async (id: string) => {
      const instance = instances.get(id);
      if (instance?.status === "running") {
        await stopServer(id);
      }
      const next = configsRef.current.filter((c) => c.id !== id);
      persistConfigs(next);
      setInstances((prev) => {
        const m = new Map(prev);
        m.delete(id);
        return m;
      });
      syncAgentConfigs();
    },
    [instances, persistConfigs, stopServer, syncAgentConfigs],
  );

  const updateServer = useCallback(
    (id: string, patch: Partial<McpServerConfig>) => {
      const next = configsRef.current.map((c) =>
        c.id === id ? { ...c, ...patch } : c,
      );
      persistConfigs(next);
    },
    [persistConfigs],
  );

  const getServerUrl = useCallback(
    (id: string): string | null => {
      return instances.get(id)?.url ?? null;
    },
    [instances],
  );

  useEffect(() => {
    const interval = setInterval(async () => {
      try {
        const serverInfos = await invoke<RustMcpServerInfo[]>("get_mcp_servers");
        const runningIds = new Set(serverInfos.map((s) => s.id));

        setInstances((prev) => {
          let changed = false;
          const next = new Map(prev);

          for (const [id, instance] of prev) {
            if (instance.status === "running" && !runningIds.has(id)) {
              next.set(id, {
                ...instance,
                status: "error",
                error: "Process exited unexpectedly",
                pid: null,
                url: null,
              });
              changed = true;
            }
          }

          return changed ? next : prev;
        });
      } catch { }
    }, 5000);

    return () => clearInterval(interval);
  }, []);

  useEffect(() => {
    for (const config of configs) {
      if (config.autoStart) {
        const instance = instances.get(config.id);
        if (instance?.status === "stopped") {
          startServer(config.id);
        }
      }
    }
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const pool = useMemo<McpPoolEntry[]>(
    () => configs.map((config) => ({
      config,
      instance: instances.get(config.id) ?? createInstance(config.id),
    })),
    [configs, instances],
  );

  const runningCount = useMemo(
    () => pool.filter((e) => e.instance.status === "running").length,
    [pool],
  );

  return {
    pool,
    runningCount,
    startServer,
    stopServer,
    restartServer,
    addServer,
    removeServer,
    updateServer,
    getServerUrl,
  };
}
