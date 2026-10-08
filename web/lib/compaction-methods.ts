/** omp's `compaction.methodOrder` choices, in its settings-menu order
 * (coding-agent session/compaction-methods.ts COMPACTION_METHOD_CHOICES). */
export const COMPACTION_METHODS = ["remote", "snapcompact", "handoff", "soft", "shake"] as const;
export type CompactionMethod = (typeof COMPACTION_METHODS)[number];

/** omp's DEFAULT_COMPACTION_METHOD_ORDER, in effect while config.yml leaves the key unset. */
export const DEFAULT_COMPACTION_METHOD_ORDER: readonly CompactionMethod[] = ["remote", "snapcompact", "handoff", "shake", "soft"];

function isCompactionMethod(value: unknown): value is CompactionMethod {
  return (COMPACTION_METHODS as readonly unknown[]).includes(value);
}

/** Known methods, no duplicates. Empty is valid: omp then runs no automatic compaction. */
export function isCompactionMethodOrder(value: unknown): value is CompactionMethod[] {
  return Array.isArray(value) && value.every(isCompactionMethod) && new Set(value).size === value.length;
}

/**
 * The order omp will actually run for a persisted `compaction` section:
 * omp's resolveCompactionMethodOrder (drop unknown ids, keep first
 * occurrences) when `methodOrder` is a list, else omp's load-time migration of
 * the legacy `strategy`/`remoteEnabled` keys (config/settings.ts). `undefined`
 * means omp's default applies.
 */
export function effectiveCompactionMethodOrder(compaction: Record<string, unknown>): CompactionMethod[] | undefined {
  const { methodOrder, strategy, remoteEnabled } = compaction;
  if (Array.isArray(methodOrder)) return [...new Set(methodOrder.filter(isCompactionMethod))];
  const remote: CompactionMethod[] = remoteEnabled === false ? [] : ["remote"];
  switch (strategy === "shake-summary" ? "shake" : strategy) {
    case "context-full": return [...remote, "soft"];
    case "handoff": return ["handoff", ...remote, "soft"];
    case "shake": return ["shake", ...remote, "soft"];
    case "snapcompact": return ["snapcompact", ...remote, "soft"];
    case "off": return [];
  }
  return remoteEnabled === false ? DEFAULT_COMPACTION_METHOD_ORDER.filter((method) => method !== "remote") : undefined;
}
