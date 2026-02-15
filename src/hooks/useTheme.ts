import { useCallback, useEffect, useState } from "react";
import { AppTheme, applyTheme, DEFAULT_THEME_ID, getThemeById } from "../config/themes";

export interface ThemeManager {
  theme: AppTheme;
  setThemeId: (id: string) => void;
}

export function useTheme(initialThemeId: string): ThemeManager {
  const [theme, setTheme] = useState<AppTheme>(() => getThemeById(initialThemeId));

  useEffect(() => {
    applyTheme(theme);
  }, [theme]);

  const setThemeId = useCallback((id: string) => {
    setTheme(getThemeById(id));
  }, []);

  return { theme, setThemeId };
}

export function applyThemeSync(themeId: string): void {
  applyTheme(getThemeById(themeId ?? DEFAULT_THEME_ID));
}
