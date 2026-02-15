export interface KeyBinding {
  id: string;
  label: string;
  description: string;
  category: "navigation" | "layout" | "agents" | "general";
  defaultKeys: string;
  mode: "direct" | "prefix";
  key: string;
  ctrl?: boolean;
  meta?: boolean;
  shift?: boolean;
}

export interface KeyBindingConfig {
  prefixKey: string;
  prefixTimeoutMs: number;
  resizeTickPercent: number;
  bindings: KeyBinding[];
}
