"use client";

import { useMemo } from "react";
import { useI18n } from "@/lib/i18n";
import { summarizeProviderAccounts } from "@/lib/provider-accounts";
import { useProviderUsage } from "./AppShell-provider-usage";

/**
 * Accounts omp manages for one provider (read-only). omp stays responsible for
 * credentials, account selection and rotation; this only surfaces what it
 * reports, so multi-account setups are discoverable.
 */
export function ProviderAccounts({ providerId, enabled }: { providerId: string; enabled: boolean }) {
  const { t } = useI18n();
  const { snapshot, loading } = useProviderUsage(enabled ? `provider=${encodeURIComponent(providerId)}` : null);
  const accounts = useMemo(
    () => (snapshot ? summarizeProviderAccounts(snapshot.reports, providerId) : []),
    [snapshot, providerId],
  );

  if (!enabled || (!loading && accounts.length === 0)) return null;

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 6 }} data-testid="provider-accounts">
      <div style={{ fontSize: 11, fontWeight: 600, color: "var(--text-muted)" }}>
        {accounts.length > 1 ? t("modelsConfig.accountsCount", { count: accounts.length }) : t("modelsConfig.accounts")}
      </div>
      {loading ? (
        <div style={{ fontSize: 12, color: "var(--text-dim)" }}>{t("modelsConfig.accountsLoading")}</div>
      ) : (
        <ul style={{ listStyle: "none", margin: 0, padding: 0, display: "flex", flexDirection: "column", gap: 4 }}>
          {accounts.map((account) => (
            <li
              key={account.key}
              style={{ display: "flex", gap: 8, alignItems: "baseline", fontSize: 12, color: "var(--text)", padding: "4px 8px", background: "var(--bg-subtle)", borderRadius: "var(--radius-control)" }}
            >
              <span title={account.label} style={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{account.label ?? t("modelsConfig.accountNumber", { index: account.index ?? 1 })}</span>
              {account.plan && <span style={{ color: "var(--text-dim)" }}>{account.plan}</span>}
            </li>
          ))}
        </ul>
      )}
      {accounts.length > 1 && (
        <p style={{ margin: 0, fontSize: 11, color: "var(--text-dim)", lineHeight: 1.5 }}>{t("modelsConfig.accountsRotationHint")}</p>
      )}
    </div>
  );
}
