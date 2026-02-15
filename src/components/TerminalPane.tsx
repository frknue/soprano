import {
  forwardRef,
  memo,
  useEffect,
  useImperativeHandle,
  useRef,
} from "react";
import { platform } from "@tauri-apps/plugin-os";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { WebglAddon } from "@xterm/addon-webgl";
import { IDisposable, ITheme, Terminal } from "@xterm/xterm";
import { IPty, spawn } from "tauri-pty";
import { getAgentById } from "../config/agents";
import { AgentStatus } from "../types/agent";
import "@xterm/xterm/css/xterm.css";

const TERM_FONT_FAMILY = "'MesloLGS NF', monospace";

export interface TerminalRef {
  terminal: Terminal | null;
  fit: () => void;
  focus: () => void;
  restart: () => void;
  stop: () => void;
}

interface TerminalPaneProps {
  paneId: string;
  isActive: boolean;
  profileId?: string;
  terminalTheme?: ITheme;
  onStatusChange?: (status: AgentStatus) => void;
  onTerminalReady?: (terminal: Terminal) => void;
}

const TerminalPaneComponent = forwardRef<TerminalRef, TerminalPaneProps>(
  ({ paneId, isActive, profileId, terminalTheme, onStatusChange, onTerminalReady }, ref) => {
    const hostRef = useRef<HTMLDivElement | null>(null);
    const terminalRef = useRef<Terminal | null>(null);
    const fitAddonRef = useRef<FitAddon | null>(null);
    const ptyRef = useRef<IPty | null>(null);
    const ptyDisposablesRef = useRef<IDisposable[]>([]);
    const activeRef = useRef(isActive);
    const statusChangeRef = useRef(onStatusChange);
    const terminalReadyRef = useRef(onTerminalReady);
    const terminalThemeRef = useRef(terminalTheme);

    const profile = profileId ? getAgentById(profileId) : undefined;

    useEffect(() => {
      activeRef.current = isActive;
    }, [isActive]);

    useEffect(() => {
      statusChangeRef.current = onStatusChange;
    }, [onStatusChange]);

    useEffect(() => {
      terminalReadyRef.current = onTerminalReady;
    }, [onTerminalReady]);

    useEffect(() => {
      terminalThemeRef.current = terminalTheme;
      if (terminalRef.current && terminalTheme) {
        terminalRef.current.options.theme = terminalTheme;
      }
    }, [terminalTheme]);

    const disposePty = (): void => {
      ptyDisposablesRef.current.forEach((disposable) => {
        disposable.dispose();
      });
      ptyDisposablesRef.current = [];

      if (ptyRef.current) {
        ptyRef.current.kill();
        ptyRef.current = null;
      }
    };

    const spawnPty = (): void => {
      const terminal = terminalRef.current;
      if (!terminal) {
        return;
      }

      disposePty();

      const baseEnv = {
        TERM: "xterm-256color",
        COLORTERM: "truecolor",
        LANG: "en_US.UTF-8",
        ...(profile?.env ?? {}),
      };

      const shellPlatform = platform();
      const defaultShell =
        shellPlatform === "macos"
          ? "zsh"
          : shellPlatform === "windows"
            ? "powershell.exe"
            : "bash";

      const pty = profile
        ? profile.launchScript
          ? spawn("bash", ["-c", profile.launchScript], {
              cols: terminal.cols,
              rows: terminal.rows,
              env: baseEnv,
              cwd: profile.cwd,
            })
          : spawn(profile.command, profile.args, {
              cols: terminal.cols,
              rows: terminal.rows,
              env: baseEnv,
              cwd: profile.cwd,
            })
        : spawn(defaultShell, ["--login"], {
            cols: terminal.cols,
            rows: terminal.rows,
            env: baseEnv,
          });

      ptyRef.current = pty;
      statusChangeRef.current?.("running");

      const ptyDataDisposable = pty.onData((data) => {
        terminal.write(data);
      });

      const ptyExitDisposable = pty.onExit(({ exitCode }) => {
        terminal.writeln(`\r\n[process exited with code ${exitCode}]`);
        statusChangeRef.current?.("stopped");
      });

      const termDataDisposable = terminal.onData((data) => {
        pty.write(data);
      });

      const termResizeDisposable = terminal.onResize(({ cols, rows }) => {
        pty.resize(cols, rows);
      });

      ptyDisposablesRef.current = [
        ptyDataDisposable,
        ptyExitDisposable,
        termDataDisposable,
        termResizeDisposable,
      ];

      requestAnimationFrame(() => {
        fitAddonRef.current?.fit();
        pty.resize(terminal.cols, terminal.rows);
        if (activeRef.current) {
          terminal.focus();
        }
      });
    };

    useImperativeHandle(
      ref,
      () => ({
        terminal: terminalRef.current,
        fit: () => {
          fitAddonRef.current?.fit();
        },
        focus: () => {
          terminalRef.current?.focus();
        },
        restart: () => {
          spawnPty();
        },
        stop: () => {
          statusChangeRef.current?.("stopped");
          disposePty();
        },
      }),
      [profileId],
    );

    useEffect(() => {
      if (!hostRef.current) {
        return undefined;
      }

      let disposed = false;
      let terminal: Terminal | null = null;
      let resizeObserver: ResizeObserver | null = null;
      const host = hostRef.current;

      const init = async (): Promise<void> => {
        try {
          await document.fonts.load(`14px ${TERM_FONT_FAMILY}`);
        } catch {
        }
        await document.fonts.ready;

        if (disposed) return;

        terminal = new Terminal({
          cursorBlink: true,
          fontSize: 14,
          allowProposedApi: true,
          fontFamily: TERM_FONT_FAMILY,
          theme: terminalThemeRef.current ?? undefined,
        });

        terminalRef.current = terminal;

        const fitAddon = new FitAddon();
        const linksAddon = new WebLinksAddon();
        fitAddonRef.current = fitAddon;

        terminal.loadAddon(fitAddon);
        terminal.loadAddon(linksAddon);
        terminal.open(host);

        try {
          const webglAddon = new WebglAddon();
          terminal.loadAddon(webglAddon);
        } catch {
        }

        terminalReadyRef.current?.(terminal);

        resizeObserver = new ResizeObserver(() => {
          fitAddon.fit();
          if (ptyRef.current && terminal) {
            ptyRef.current.resize(terminal.cols, terminal.rows);
          }
        });

        resizeObserver.observe(host);
        requestAnimationFrame(() => {
          spawnPty();
        });
      };

      init();

      return () => {
        disposed = true;
        resizeObserver?.disconnect();
        disposePty();
        terminal?.dispose();
        fitAddonRef.current = null;
        terminalRef.current = null;
      };
    }, [paneId, profileId]);

    useEffect(() => {
      const handler = (e: Event): void => {
        const terminal = terminalRef.current;
        if (!terminal) return;
        const detail = (e as CustomEvent).detail;
        if (detail.reset) {
          terminal.options.fontSize = 14;
        } else {
          const current = terminal.options.fontSize ?? 14;
          terminal.options.fontSize = Math.min(32, Math.max(8, current + detail.delta));
        }
        fitAddonRef.current?.fit();
        if (ptyRef.current) {
          ptyRef.current.resize(terminal.cols, terminal.rows);
        }
      };
      window.addEventListener("soprano-zoom", handler);
      return () => window.removeEventListener("soprano-zoom", handler);
    }, []);

    useEffect(() => {
      if (isActive) {
        terminalRef.current?.focus();
      }
    }, [isActive]);

    return (
      <div
        className={`pane terminal-pane ${isActive ? "pane-active" : ""}`}
        onMouseDown={() => terminalRef.current?.focus()}
      >
        <div className="terminal-host" ref={hostRef} />
      </div>
    );
  },
);

TerminalPaneComponent.displayName = "TerminalPane";

export const TerminalPane = memo(TerminalPaneComponent);
