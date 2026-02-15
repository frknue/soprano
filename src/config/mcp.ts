import { McpServerConfig } from "../types/mcp";

export const DEFAULT_MCP_SERVERS: McpServerConfig[] = [
  {
    id: "playwright",
    name: "Playwright",
    icon: "monitor",
    color: "#2ead33",
    command: "npx",
    args: ["@playwright/mcp@latest"],
    transport: "sse",
    port: 3100,
    autoStart: false,
  },
  {
    id: "filesystem",
    name: "Filesystem",
    icon: "folder-open",
    color: "#fabd2f",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-filesystem", "/"],
    transport: "stdio",
    port: 3101,
    autoStart: false,
  },
  {
    id: "github",
    name: "GitHub",
    icon: "github",
    color: "#ebdbb2",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-github"],
    env: { GITHUB_PERSONAL_ACCESS_TOKEN: "" },
    transport: "stdio",
    port: 3102,
    autoStart: false,
  },
  {
    id: "memory",
    name: "Memory",
    icon: "brain",
    color: "#d3869b",
    command: "npx",
    args: ["-y", "@modelcontextprotocol/server-memory"],
    transport: "stdio",
    port: 3103,
    autoStart: false,
  },
];

const STORAGE_KEY = "soprano-mcp-servers";

export function loadMcpConfigs(): McpServerConfig[] {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored) {
      return JSON.parse(stored) as McpServerConfig[];
    }
  } catch { }
  return DEFAULT_MCP_SERVERS;
}

export function saveMcpConfigs(configs: McpServerConfig[]): void {
  localStorage.setItem(STORAGE_KEY, JSON.stringify(configs));
}
