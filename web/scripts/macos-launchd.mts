#!/usr/bin/env node
// Install ompweb as a macOS launchd user agent (starts at login, restarts on crash).
//
// Uses the local Soprano launcher; no runtime package downloads.
// Usage: node scripts/macos-launchd.mts [install|uninstall|status]
//
// Configuration (read at install time, baked into the plist):
//   PORT                 Server port                                default 30177
//   OMP_WEB_HOSTNAME     Server bind host                           default 127.0.0.1
//   OMP_WEB_PASSWORD     Optional password for web login            default none (auth disabled)
//   OMP_WEB_NO_OPEN      Set to 0 to auto-open the browser          default 1 (no auto-open)
//   OMP_WEB_OMP_BIN      Path to omp binary if not on PATH          default auto-detected
//   PI_CODING_AGENT_DIR  Custom omp agent directory                 default ~/.omp/agent
//
// Example (loopback-only; require auth + trusted HTTPS proxy/VPN for remote access):
//   OMP_WEB_PASSWORD=secret ompweb-launchd install

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const LABEL = "com.soprano.ompweb";
const HOME = os.homedir();
const PLIST = path.join(HOME, "Library", "LaunchAgents", `${LABEL}.plist`);
const LOG_DIR = path.join(HOME, "Library", "Logs", "ompweb");
const DOMAIN = `gui/${process.getuid?.() ?? 0}`;

// Print an error and exit non-zero.
function fail(message: string): never {
  console.error(`error: ${message}`);
  process.exit(1);
}

// True when the path is an executable regular file.
function isExecutableFile(candidate: string): boolean {
  try {
    fs.accessSync(candidate, fs.constants.X_OK);
    return fs.statSync(candidate).isFile();
  } catch {
    return false;
  }
}

// Locate an executable on the caller's PATH.
function which(name: string): string | null {
  for (const dir of (process.env.PATH ?? "").split(path.delimiter)) {
    if (dir && isExecutableFile(path.join(dir, name))) return path.join(dir, name);
  }
  return null;
}

// Escape a value for embedding in plist XML.
function xmlEscape(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// Run launchctl; by default a failure is fatal.
function launchctl(args: string[], { ignoreFailure = false } = {}): string {
  const result = spawnSync("launchctl", args, { encoding: "utf8" });
  if (result.error) fail(`launchctl not runnable: ${result.error.message}`);
  if (result.status !== 0 && !ignoreFailure) {
    fail(`launchctl ${args.join(" ")} failed: ${(result.stderr ?? "").trim()}`);
  }
  return result.stdout ?? "";
}

function install(pkgArg?: string): void {
  if (pkgArg || process.env.OMP_WEB_PKG) fail("Package specs are not supported; this service runs the local Soprano web app");
  const nodeBin = process.execPath;
  const launcherPath = fileURLToPath(new URL("../bin/omp-web.js", import.meta.url));

  // omp binary: explicit env var wins, otherwise auto-detect from the current PATH.
  const ompBin = process.env.OMP_WEB_OMP_BIN ?? which("omp");
  if (process.env.OMP_WEB_OMP_BIN) {
    try {
      fs.accessSync(process.env.OMP_WEB_OMP_BIN, fs.constants.X_OK);
    } catch {
      fail(`OMP_WEB_OMP_BIN=${process.env.OMP_WEB_OMP_BIN} is not executable`);
    }
  } else if (!ompBin) {
    console.warn("warning: omp binary not found; live-agent features will be unavailable (set OMP_WEB_OMP_BIN)");
  }

  // Service parameters are frozen at install time.
  const port = process.env.PORT ?? "30177";
  const hostname = process.env.OMP_WEB_HOSTNAME ?? "127.0.0.1";
  const noOpen = process.env.OMP_WEB_NO_OPEN ?? "1";
  const password = process.env.OMP_WEB_PASSWORD;
  // launchd does not expand `~` in environment values — resolve it now.
  const agentDir = process.env.PI_CODING_AGENT_DIR?.replace(/^~(?=\/|$)/, HOME);

  // Give the service a PATH covering node, omp, and system tools.
  const asdfBin = which("asdf");
  const svcPath = [
    ...(ompBin ? [path.dirname(ompBin)] : []),
    ...(asdfBin ? [path.dirname(asdfBin)] : []),
    path.dirname(nodeBin),
    "/usr/bin",
    "/bin",
    "/usr/sbin",
    "/sbin",
  ].filter((dir, i, all) => all.indexOf(dir) === i).join(path.delimiter);

  // Environment baked into the service; optional entries only when set.
  const env: Record<string, string> = {
    PATH: svcPath,
    PORT: port,
    OMP_WEB_HOSTNAME: hostname,
    OMP_WEB_NO_OPEN: noOpen,
    ...(password ? { OMP_WEB_PASSWORD: password } : {}),
    ...(ompBin ? { OMP_WEB_OMP_BIN: ompBin } : {}),
    ...(agentDir ? { PI_CODING_AGENT_DIR: agentDir } : {}),
  };
  const envXml = Object.entries(env)
    .map(([key, value]) => `    <key>${xmlEscape(key)}</key><string>${xmlEscape(value)}</string>`)
    .join("\n");

  const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${xmlEscape(nodeBin)}</string>
    <string>${xmlEscape(launcherPath)}</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
${envXml}
  </dict>
  <key>WorkingDirectory</key><string>${xmlEscape(HOME)}</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>${xmlEscape(path.join(LOG_DIR, "ompweb.log"))}</string>
  <key>StandardErrorPath</key><string>${xmlEscape(path.join(LOG_DIR, "ompweb.err.log"))}</string>
</dict>
</plist>
`;

  fs.mkdirSync(LOG_DIR, { recursive: true });
  fs.mkdirSync(path.dirname(PLIST), { recursive: true });
  // Password lives in the plist as plain text; keep it user-readable only.
  fs.writeFileSync(PLIST, plist, { mode: 0o600 });
  fs.chmodSync(PLIST, 0o600);

  // Reload: bootout fails harmlessly when the agent isn't currently loaded.
  launchctl(["bootout", `${DOMAIN}/${LABEL}`], { ignoreFailure: true });
  launchctl(["bootstrap", DOMAIN, PLIST]);

  console.log(`installed: ${PLIST}`);
  console.log(`launcher:  ${launcherPath}`);
  console.log(`url:       http://${hostname}:${port}`);
  console.log(`logs:      ${path.join(LOG_DIR, "ompweb.log")}`);
  if (password) console.log("note:      password is stored in plain text in the plist (mode 600)");
}

function uninstall(): void {
  launchctl(["bootout", `${DOMAIN}/${LABEL}`], { ignoreFailure: true });
  fs.rmSync(PLIST, { force: true });
  console.log(`uninstalled: ${LABEL}`);
}

function status(): void {
  const result = spawnSync("launchctl", ["print", `${DOMAIN}/${LABEL}`], { encoding: "utf8" });
  if (result.status === 0) {
    const lines = (result.stdout ?? "").split("\n").filter((line) => /\b(state|pid|last exit)\b/.test(line));
    console.log(lines.join("\n") || (result.stdout ?? "").trim());
    return;
  }
  console.log(`not loaded: ${LABEL}`);
  process.exit(1);
}

if (process.platform !== "darwin") fail("launchd services are macOS-only");

const command = process.argv[2] ?? "install";
if (command === "install") install(process.argv[3]);
else if (command === "uninstall") uninstall();
else if (command === "status") status();
else {
  console.error("usage: ompweb-launchd [install|uninstall|status]");
  process.exit(2);
}
