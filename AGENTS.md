# AGENTS.md — Soprano

Soprano is a Tauri v2 desktop app for orchestrating AI coding agents (Claude Code, Codex, OpenCode, OpenClaw) in a tiling terminal layout. React + TypeScript frontend, Rust backend.

## Build & Run Commands

```bash
# Frontend only
npm run dev              # Vite dev server on :1420
npm run build            # tsc && vite build

# Full Tauri app (frontend + Rust backend)
npm run tauri dev        # Dev mode with hot-reload
npm run tauri build      # Production build

# Rust backend only (from src-tauri/)
cargo build              # Debug build
cargo build --release    # Release build
cargo check              # Type-check without building
cargo clippy             # Lint Rust code

# TypeScript type-check only
npx tsc --noEmit
```

### Testing

No test framework is currently configured. There are no test files. If adding tests:
- Frontend: add vitest (`npm i -D vitest`) — matches the Vite toolchain
- Rust: use built-in `cargo test` with `#[cfg(test)]` modules in `src-tauri/src/`

### Linting & Formatting

No ESLint, Prettier, or Biome is configured. No `.editorconfig`. TypeScript strict mode enforces type safety. If adding linting, prefer Biome (fast, zero-config).

## Project Structure

```
soprano/
├── src/                    # React frontend (TypeScript)
│   ├── main.tsx            # Entry point, CSS imports
│   ├── App.tsx             # Root component, wires managers together
│   ├── components/         # React components (one per file)
│   ├── hooks/              # Custom React hooks (useXxxManager pattern)
│   ├── config/             # Static config & localStorage persistence
│   ├── types/              # TypeScript type definitions
│   └── styles/             # Plain CSS files (no CSS modules)
├── src-tauri/              # Rust backend (Tauri v2)
│   ├── src/lib.rs          # All Tauri commands (IPC handlers)
│   ├── src/main.rs         # Entry point (calls lib::run)
│   ├── Cargo.toml          # Rust dependencies
│   └── tauri.conf.json     # Tauri app config
├── package.json            # Node dependencies & scripts
├── tsconfig.json           # TypeScript config (strict)
└── vite.config.ts          # Vite bundler config
```

## TypeScript Configuration

Strict mode is enabled with these enforced rules:
- `strict: true` — all strict checks
- `noUnusedLocals: true` — no dead variables
- `noUnusedParameters: true` — no unused function params
- `noFallthroughCasesInSwitch: true`
- `forceConsistentCasingInFileNames: true`
- Target: ES2021, module: ESNext, JSX: react-jsx

## Code Style — TypeScript / React

### Formatting
- **Indentation**: 2 spaces
- **Quotes**: double quotes everywhere (strings, imports, JSX attributes)
- **Semicolons**: always
- **Trailing commas**: yes, in multi-line structures
- **Line length**: no enforced limit, but lines are kept reasonable (~120)

### Naming Conventions
- `PascalCase`: components, interfaces, types, type aliases
- `camelCase`: functions, variables, hooks, config objects
- `UPPER_SNAKE_CASE`: module-level constants (e.g., `STORAGE_KEY`, `PTY_MAX_RETRIES`)
- `kebab-case`: CSS class names (BEM-like: `.sidebar-agent-item`, `.agent-status-dot`)
- Hook files: `useXxx.ts` → exports `useXxx()` function
- Component files: `PascalCase.tsx` → exports named `PascalCase` component

### Imports
Order (no blank lines between groups):
1. React hooks/utilities (`import { useState, useCallback } from "react"`)
2. Third-party libraries (`@tauri-apps/api`, `react-mosaic-component`, `lucide-react`)
3. Internal modules — relative paths only, no path aliases
   - Config: `../config/agents`
   - Hooks: `../hooks/useAgentManager`
   - Types: `../types/agent`
   - Components: `./ComponentName`

No barrel files (`index.ts`) exist. Import directly from the source file.

### Components
- **Named exports** for all components: `export function Sidebar(...)` — NOT default exports
- Exception: `App.tsx` uses `export default function App()`
- Functional components only, no class components
- `forwardRef` + `memo` pattern for performance-critical components (see `TerminalPane.tsx`)
- Set `.displayName` when using `forwardRef`
- Props interfaces defined inline above the component or in the same file
- Use `type="button"` on all `<button>` elements

### Hooks
- Custom hooks follow the `useXxxManager` pattern returning an interface
- Define the return interface above the hook: `export interface AgentManager { ... }`
- Use `useCallback` for all handler functions returned from hooks
- Use `useRef` for values that shouldn't trigger re-renders (e.g., `configsRef`, `statusChangeRef`)
- Prefer `useState` with functional updater: `setState((prev) => ...)` for state derived from previous state

### Types
- **Interfaces** for object shapes: `export interface McpServerConfig { ... }`
- **Type aliases** for unions/literals: `export type AgentStatus = "idle" | "starting" | "running" | "error" | "stopped"`
- Types live in `src/types/` — one file per domain (`agent.ts`, `mcp.ts`, `keybinding.ts`)
- Config types can be co-located in `src/config/` files
- Optional fields use `?`: `env?: Record<string, string>`

### Error Handling
- `try/catch` with empty `catch` blocks are used in non-critical paths (localStorage reads)
- For Tauri IPC: `.catch(() => {})` on fire-and-forget invocations
- Critical errors: write to terminal with ANSI escape codes (`\x1b[31m[error message]\x1b[0m`)

### State Persistence
- Uses `localStorage` with `soprano-` prefixed keys
- Pattern: `loadXxx()` / `saveXxx()` function pairs in `src/config/`
- Always handle parse failures gracefully (return defaults)

## Code Style — Rust

### Formatting
- Standard `rustfmt` defaults (4-space indent)
- No `rustfmt.toml` or `clippy.toml` configured

### Patterns
- `#[tauri::command]` attribute on all IPC handler functions
- Error type is `String` (`Result<T, String>`) — use `.map_err(|e| e.to_string())?`
- `serde::Serialize` / `serde::Deserialize` for IPC data structures
- State management: `Mutex<T>` wrapped in Tauri `State<'_>`
- snake_case for functions and variables

## CSS / Styling

- **Plain CSS** files in `src/styles/` — no CSS modules, no CSS-in-JS
- CSS custom properties for theming (defined in `theme.css`, applied via `var(--name)`)
- RGB components pattern: `--accent-rgb` + `rgb(var(--accent-rgb) / 0.5)` for alpha
- BEM-like class naming: `.component-element.modifier`
- Global styles imported in `main.tsx`
- Responsive breakpoint: `@media (width <= 900px)`

## Key Architecture Decisions

- **Manager pattern**: Core state lives in custom hooks (`useAgentManager`, `useMcpManager`, `useSessionManager`) that return interface objects passed as props
- **No state library**: Pure React state with `useState`/`useCallback`/`useRef`
- **Tiling layout**: Uses `react-mosaic-component` — layout is a binary tree of pane IDs
- **Terminal**: `@xterm/xterm` + `tauri-pty` for native PTY support
- **IPC**: Tauri `invoke()` for frontend→backend calls, all commands in `lib.rs`
- **MCP servers**: Managed as child processes in Rust, exposed via SSE gateway

## Common Pitfalls

- The `eslint-disable-line react-hooks/exhaustive-deps` comment appears on intentional mount-only effects — these are deliberate
- `platform()` from `@tauri-apps/plugin-os` is called at module level in `config/agents.ts` — it's synchronous in Tauri v2
- Browser panes use Tauri's `WebviewBuilder` child webviews, not iframes
- Terminal font (`MesloLGS NF`) must be loaded before xterm init — see `fontReadyPromise` guard
