import assert from "node:assert/strict";
import test from "node:test";
import { createJiti } from "jiti";

const jiti = createJiti(import.meta.url);
const { summarizeProviderAccounts } = await jiti.import("./provider-accounts.ts");

test("distinct accounts are listed once even when usage is split per model/tier", () => {
  const reports = [
    { provider: "anthropic", accountLabel: "a@x.test", plan: "max" },
    { provider: "anthropic", accountLabel: "a@x.test", modelId: "opus" },
    { provider: "anthropic", accountLabel: "b@x.test" },
    { provider: "openai", accountLabel: "other@x.test" },
  ];
  assert.deepEqual(
    summarizeProviderAccounts(reports, "anthropic").map((a) => [a.label, a.plan]),
    [["a@x.test", "max"], ["b@x.test", undefined]],
  );
});

test("accounts without a label are told apart by their position", () => {
  const reports = [
    { provider: "p", accountIndex: 1 },
    { provider: "p", accountIndex: 2, noLimits: true },
    { provider: "p", accountIndex: 1, modelId: "m" },
  ];
  assert.deepEqual(summarizeProviderAccounts(reports, "p").map((a) => a.index), [1, 2]);
  assert.deepEqual(summarizeProviderAccounts(reports, "none"), []);
});
