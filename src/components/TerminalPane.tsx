import {
  forwardRef,
  memo,
  useEffect,
  useImperativeHandle,
  useRef,
} from "react";
import { invoke } from "@tauri-apps/api/core";
import { platform } from "@tauri-apps/plugin-os";
import { CanvasAddon } from "@xterm/addon-canvas";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { IDisposable, ITheme, Terminal } from "@xterm/xterm";
import { IPty, spawn } from "tauri-pty";
import { getAgentById } from "../config/agents";
import { AgentStatus } from "../types/agent";
import "@xterm/xterm/css/xterm.css";

const TERM_FONT_FAMILY = "'MesloLGS NF', monospace";
const PTY_SPAWN_MAX_RETRIES = 2;

let fontsReady = false;
const fontReadyPromise = document.fonts
  .load(`14px ${TERM_FONT_FAMILY}`)
  .catch(() => {})
  .then(() => document.fonts.ready)
  .then(() => {
    fontsReady = true;
  });

let parentEnv: Record<string, string> | null = null;
const parentEnvPromise = invoke<Record<string, string>>("get_process_env")
  .then((env) => { parentEnv = env; })
  .catch(() => {});

export interface TerminalRef {
  terminal: Terminal | null;
  fit: () => void;
  focus: () => void;
  restart: () => void;
  stop: () => void;
  sendText: (text: string) => void;
  getPid: () => number | null;
}

interface TerminalPaneProps {
  paneId: string;
  isActive: boolean;
  profileId?: string;
  cwd?: string;
  terminalTheme?: ITheme;
  onStatusChange?: (status: AgentStatus) => void;
  onTerminalReady?: (terminal: Terminal) => void;
}

const TerminalPaneComponent = forwardRef<TerminalRef, TerminalPaneProps>(
  ({ paneId, isActive, profileId, cwd, terminalTheme, onStatusChange, onTerminalReady }, ref) => {
    const hostRef = useRef<HTMLDivElement | null>(null);
    const terminalRef = useRef<Terminal | null>(null);
    const fitAddonRef = useRef<FitAddon | null>(null);
    const ptyRef = useRef<IPty | null>(null);
    const ptyDisposablesRef = useRef<IDisposable[]>([]);
    const retryCountRef = useRef(0);
    const disposedRef = useRef(false);
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
      if (!terminal || disposedRef.current) {
        return;
      }

      disposePty();
      fitAddonRef.current?.fit();

      const cols = Math.max(1, terminal.cols);
      const rows = Math.max(1, terminal.rows);

      const baseEnv = {
        ...(parentEnv ?? {}),
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

      let pty: IPty;
      try {
        pty = profile
          ? profile.launchScript
            ? spawn("bash", ["-c", profile.launchScript], {
                cols,
                rows,
                env: baseEnv,
                cwd: profile.cwd,
              })
            : spawn(profile.command, profile.args, {
                cols,
                rows,
                env: baseEnv,
                cwd: profile.cwd,
              })
          : spawn(defaultShell, ["--login"], {
              cols,
              rows,
              env: baseEnv,
              cwd: cwd || undefined,
            });
      } catch (err) {
        terminal.writeln(`\r\n\x1b[31m[failed to spawn shell: ${err}]\x1b[0m`);
        statusChangeRef.current?.("error");
        return;
      }

      ptyRef.current = pty;
      statusChangeRef.current?.("running");

      const initPromise = (pty as unknown as { _init?: Promise<unknown> })._init;
      if (initPromise && typeof initPromise.then === "function") {
        initPromise.then(() => {
          retryCountRef.current = 0;
        }).catch((err: unknown) => {
          if (disposedRef.current || ptyRef.current !== pty) return;
          terminal.writeln(`\r\n\x1b[31m[PTY spawn failed: ${err}]\x1b[0m`);
          statusChangeRef.current?.("error");
          ptyRef.current = null;

          if (retryCountRef.current < PTY_SPAWN_MAX_RETRIES) {
            retryCountRef.current += 1;
            terminal.writeln(`\x1b[33m[retrying... (${retryCountRef.current}/${PTY_SPAWN_MAX_RETRIES})]\x1b[0m`);
            window.setTimeout(() => {
              if (!disposedRef.current) spawnPty();
            }, 500);
          }
        });
      }

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

      const termResizeDisposable = terminal.onResize(({ cols: c, rows: r }) => {
        pty.resize(c, r);
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
          focusTerminal();
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
          retryCountRef.current = 0;
          terminalRef.current?.clear();
          spawnPty();
        },
        stop: () => {
          statusChangeRef.current?.("stopped");
          disposePty();
        },
        sendText: (text: string) => {
          ptyRef.current?.write(text);
        },
        getPid: () => {
          return ptyRef.current?.pid ?? null;
        },
      }),
      [profileId],
    );

    useEffect(() => {
      if (!hostRef.current) {
        return undefined;
      }

      disposedRef.current = false;
      retryCountRef.current = 0;
      let cancelled = false;
      let terminal: Terminal | null = null;
      let resizeObserver: ResizeObserver | null = null;
      const host = hostRef.current;

      const init = async (): Promise<void> => {
        if (!fontsReady) {
          await fontReadyPromise;
        }
        if (!parentEnv) {
          await parentEnvPromise;
        }

        if (cancelled) return;

        terminal = new Terminal({
          cursorBlink: true,
          fontSize: 14,
          allowProposedApi: true,
          fontFamily: TERM_FONT_FAMILY,
          scrollback: 5000,
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
          terminal.loadAddon(new CanvasAddon());
        } catch {
          // Canvas renderer unavailable — fall back to DOM renderer
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
          if (!cancelled && !disposedRef.current) {
            spawnPty();
            if (activeRef.current) focusTerminal();
          }
        });
      };

      init();

      return () => {
        cancelled = true;
        disposedRef.current = true;
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

    const focusTerminal = (): void => {
      const term = terminalRef.current;
      if (!term) return;
      const ta = term.textarea;
      if (ta) {
        ta.focus();
      } else {
        term.focus();
      }
    };

    useEffect(() => {
      if (!isActive) return undefined;

      fitAddonRef.current?.fit();
      focusTerminal();
      const rafId = requestAnimationFrame(() => {
        fitAddonRef.current?.fit();
        focusTerminal();
      });

      const timerId = window.setTimeout(focusTerminal, 150);

      return () => {
        cancelAnimationFrame(rafId);
        window.clearTimeout(timerId);
      };
    }, [isActive]);

    return (
      <div
        className={`pane terminal-pane ${isActive ? "pane-active" : ""}`}
        tabIndex={-1}
        onMouseDown={focusTerminal}
        onFocus={(e) => {
          const ta = terminalRef.current?.textarea;
          if (ta && (e.target as HTMLElement) !== ta) {
            ta.focus();
          }
        }}
      >
        <div className="terminal-host" ref={hostRef} />
      </div>
    );
  },
);

TerminalPaneComponent.displayName = "TerminalPane";

export const TerminalPane = memo(TerminalPaneComponent);
