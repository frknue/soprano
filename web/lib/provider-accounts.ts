import type { ProviderUsageReport } from "./provider-usage-types";

export interface ProviderAccountSummary {
  /** Stable key: the account label, else its 1-based position in omp's list. */
  key: string;
  label?: string;
  index?: number;
  plan?: string;
}

/**
 * The distinct accounts omp reports usage for under one provider. omp's login
 * RPC only says whether a provider is authenticated, so `omp usage` (one report
 * per credential, split here by model/tier) is the supported place accounts
 * show up. Accounts without usage windows still appear (`noLimits`).
 */
export function summarizeProviderAccounts(reports: readonly ProviderUsageReport[], provider: string): ProviderAccountSummary[] {
  const accounts = new Map<string, ProviderAccountSummary>();
  for (const report of reports) {
    if (report.provider !== provider) continue;
    const key = report.accountLabel ?? `#${report.accountIndex ?? accounts.size + 1}`;
    const existing = accounts.get(key);
    if (existing) {
      if (!existing.plan && report.plan) existing.plan = report.plan;
      continue;
    }
    accounts.set(key, {
      key,
      ...(report.accountLabel ? { label: report.accountLabel } : {}),
      ...(report.accountIndex !== undefined ? { index: report.accountIndex } : {}),
      ...(report.plan ? { plan: report.plan } : {}),
    });
  }
  return [...accounts.values()];
}
