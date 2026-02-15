import type { ITheme } from "@xterm/xterm";

export interface AppTheme {
  id: string;
  name: string;
  colors: Record<string, string>;
  terminal: ITheme;
}

const GRUVBOX_DARK: AppTheme = {
  id: "gruvbox-dark",
  name: "Gruvbox Dark",
  colors: {
    "--bg-base": "#282828",
    "--bg-panel": "#1d2021",
    "--bg-raised": "#1d2021",
    "--bg-overlay": "#3c3836",
    "--text-primary": "#ebdbb2",
    "--text-muted": "#a89984",
    "--accent": "#fe8019",
    "--accent-strong": "#fabd2f",
    "--border-subtle": "#3c3836",
    "--border-strong": "#504945",
    "--success": "#b8bb26",
    "--danger": "#fb4934",
    "--blue": "#83a598",
    "--cyan": "#8ec07c",
    "--yellow": "#fabd2f",
    "--gray": "#665c54",
    "--bg-base-rgb": "40 40 40",
    "--bg-panel-rgb": "29 32 33",
    "--bg-raised-rgb": "29 32 33",
    "--bg-overlay-rgb": "60 56 54",
    "--text-primary-rgb": "235 219 178",
    "--text-muted-rgb": "168 153 132",
    "--accent-rgb": "254 128 25",
    "--accent-strong-rgb": "250 189 47",
    "--border-subtle-rgb": "60 56 54",
    "--border-strong-rgb": "80 73 69",
    "--success-rgb": "184 187 38",
    "--danger-rgb": "251 73 52",
    "--blue-rgb": "131 165 152",
    "--cyan-rgb": "142 192 124",
    "--yellow-rgb": "250 189 47",
    "--gray-rgb": "102 92 84",
  },
  terminal: {
    background: "#282828",
    foreground: "#ebdbb2",
    cursor: "#ebdbb2",
    cursorAccent: "#282828",
    selectionBackground: "#50494599",
    black: "#282828",
    red: "#cc241d",
    green: "#98971a",
    yellow: "#d79921",
    blue: "#458588",
    magenta: "#b16286",
    cyan: "#689d6a",
    white: "#a89984",
    brightBlack: "#928374",
    brightRed: "#fb4934",
    brightGreen: "#b8bb26",
    brightYellow: "#fabd2f",
    brightBlue: "#83a598",
    brightMagenta: "#d3869b",
    brightCyan: "#8ec07c",
    brightWhite: "#ebdbb2",
  },
};

const CATPPUCCIN_MOCHA: AppTheme = {
  id: "catppuccin-mocha",
  name: "Catppuccin Mocha",
  colors: {
    "--bg-base": "#1e1e2e",
    "--bg-panel": "#181825",
    "--bg-raised": "#11111b",
    "--bg-overlay": "#313244",
    "--text-primary": "#cdd6f4",
    "--text-muted": "#a6adc8",
    "--accent": "#cba6f7",
    "--accent-strong": "#f5c2e7",
    "--border-subtle": "#313244",
    "--border-strong": "#45475a",
    "--success": "#a6e3a1",
    "--danger": "#f38ba8",
    "--blue": "#89b4fa",
    "--cyan": "#94e2d5",
    "--yellow": "#f9e2af",
    "--gray": "#45475a",
    "--bg-base-rgb": "30 30 46",
    "--bg-panel-rgb": "24 24 37",
    "--bg-raised-rgb": "17 17 27",
    "--bg-overlay-rgb": "49 50 68",
    "--text-primary-rgb": "205 214 244",
    "--text-muted-rgb": "166 173 200",
    "--accent-rgb": "203 166 247",
    "--accent-strong-rgb": "245 194 231",
    "--border-subtle-rgb": "49 50 68",
    "--border-strong-rgb": "69 71 90",
    "--success-rgb": "166 227 161",
    "--danger-rgb": "243 139 168",
    "--blue-rgb": "137 180 250",
    "--cyan-rgb": "148 226 213",
    "--yellow-rgb": "249 226 175",
    "--gray-rgb": "69 71 90",
  },
  terminal: {
    background: "#1e1e2e",
    foreground: "#cdd6f4",
    cursor: "#f5e0dc",
    cursorAccent: "#1e1e2e",
    selectionBackground: "#45475a99",
    black: "#45475a",
    red: "#f38ba8",
    green: "#a6e3a1",
    yellow: "#f9e2af",
    blue: "#89b4fa",
    magenta: "#cba6f7",
    cyan: "#94e2d5",
    white: "#bac2de",
    brightBlack: "#585b70",
    brightRed: "#f38ba8",
    brightGreen: "#a6e3a1",
    brightYellow: "#f9e2af",
    brightBlue: "#89b4fa",
    brightMagenta: "#cba6f7",
    brightCyan: "#94e2d5",
    brightWhite: "#a6adc8",
  },
};

export const THEMES: AppTheme[] = [GRUVBOX_DARK, CATPPUCCIN_MOCHA];

export const DEFAULT_THEME_ID = "gruvbox-dark";

export function getThemeById(id: string): AppTheme {
  return THEMES.find((t) => t.id === id) ?? GRUVBOX_DARK;
}

export function applyTheme(theme: AppTheme): void {
  const root = document.documentElement;
  for (const [key, value] of Object.entries(theme.colors)) {
    root.style.setProperty(key, value);
  }
}
