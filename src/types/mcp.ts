export type McpTransport = "stdio" | "sse";

export type McpServerStatus = "stopped" | "starting" | "running" | "error";

export interface McpServerConfig {
  id: string;
  name: string;
  icon: string;
  color: string;
  command: string;
  args: string[];
  env?: Record<string, string>;
  transport: McpTransport;
  port: number;
  autoStart: boolean;
}

export interface McpServerInstance {
  id: string;
  status: McpServerStatus;
  pid: number | null;
  url: string | null;
  startedAt: number | null;
  error: string | null;
}

export interface McpPoolEntry {
  config: McpServerConfig;
  instance: McpServerInstance;
}
