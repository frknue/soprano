/**
 * Client-side composer preferences (localStorage). These live outside the
 * native OMP config because they are ompweb UI behaviors.
 */

export type SubmitDuringRunBehavior = "steer" | "queue";

const SUBMIT_DURING_RUN_KEY = "omp-web:submit-during-run";

/** Default behavior when a message is submitted while the agent is running. */
export function getSubmitDuringRunBehavior(): SubmitDuringRunBehavior {
  if (typeof window === "undefined") return "steer";
  try {
    const value = window.localStorage.getItem(SUBMIT_DURING_RUN_KEY);
    if (value === "steer" || value === "queue") return value;
  } catch {
    // storage unavailable — fall through to the default
  }
  return "steer";
}

export function setSubmitDuringRunBehavior(behavior: SubmitDuringRunBehavior): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(SUBMIT_DURING_RUN_KEY, behavior);
  } catch {
    // storage unavailable — the preference simply won't persist
  }
}

/** Ghost-text word completion: `auto` enables it only with a physical keyboard. */
export type WordCompletionMode = "auto" | "on" | "off";

const WORD_COMPLETION_KEY = "omp-web:word-completion";

export function getWordCompletionMode(): WordCompletionMode {
  if (typeof window === "undefined") return "auto";
  try {
    const value = window.localStorage.getItem(WORD_COMPLETION_KEY);
    if (value === "auto" || value === "on" || value === "off") return value;
  } catch {
    // storage unavailable — fall through to the default
  }
  return "auto";
}

export function setWordCompletionMode(mode: WordCompletionMode): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(WORD_COMPLETION_KEY, mode);
  } catch {
    // storage unavailable — the preference simply won't persist
  }
}

/**
 * Whether ghost text is on. Browsers cannot see an on-screen keyboard, so
 * `auto` goes by the primary pointer: a mouse/trackpad (`pointer: fine`)
 * means a physical keyboard is likely; touch devices bring their own
 * keyboard suggestions and have no Tab key.
 */
export function isWordCompletionEnabled(mode: WordCompletionMode = getWordCompletionMode()): boolean {
  if (mode !== "auto") return mode === "on";
  return typeof window !== "undefined" && window.matchMedia("(pointer: fine)").matches;
}
