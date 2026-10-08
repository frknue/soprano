import type { GitCollapseReason, GitFileStatus } from "./git-types";

/** Attributes queried by `git check-attr` for `parseGitCollapseReasons`. */
export const GIT_REVIEW_ATTRIBUTES = [
  "linguist-generated",
  "linguist-vendored",
  "linguist-documentation",
  "diff",
  "binary",
] as const;

// Linguist overrides are boolean: `attr` / `attr=true` set it, `-attr` / `attr=false` clear it.
const isTrue = (value: string | undefined) => value === "set" || value === "true";

function collapseReasonFromAttributes(attrs: Map<string, string>): GitCollapseReason | undefined {
  // `no-diff` wins so callers can suppress the diff from the reason alone.
  // `binary` also unsets diff; binary changes (images, fonts) stay in the main list.
  if (attrs.get("diff") === "unset" && attrs.get("binary") !== "set") return "no-diff";
  if (isTrue(attrs.get("linguist-generated"))) return "generated";
  if (isTrue(attrs.get("linguist-vendored"))) return "vendored";
  if (isTrue(attrs.get("linguist-documentation"))) return "documentation";
  return undefined;
}

/** Parses `git check-attr -z` output (`path NUL attr NUL value NUL` triples). */
export function parseGitCollapseReasons(output: string): Map<string, GitCollapseReason> {
  const records = output.split("\0");
  const byPath = new Map<string, Map<string, string>>();
  for (let i = 0; i + 2 < records.length; i += 3) {
    const [filePath, attr, value] = [records[i], records[i + 1], records[i + 2]];
    let attrs = byPath.get(filePath);
    if (!attrs) byPath.set(filePath, attrs = new Map());
    attrs.set(attr, value);
  }
  const reasons = new Map<string, GitCollapseReason>();
  for (const [filePath, attrs] of byPath) {
    const reason = collapseReasonFromAttributes(attrs);
    if (reason) reasons.set(filePath, reason);
  }
  return reasons;
}

export interface GitPorcelainEntry {
  path: string;
  originalPath?: string;
  indexStatus: string;
  worktreeStatus: string;
}

function usesRenamePath(indexStatus: string, worktreeStatus: string): boolean {
  return indexStatus === "R" || indexStatus === "C" || worktreeStatus === "R" || worktreeStatus === "C";
}

export function parseGitPorcelainV1(output: string): GitPorcelainEntry[] {
  const records = output.split("\0");
  const entries: GitPorcelainEntry[] = [];

  for (let i = 0; i < records.length; i++) {
    const record = records[i];
    if (!record || record.length < 4 || record[2] !== " ") continue;
    const indexStatus = record[0];
    const worktreeStatus = record[1];
    const entry: GitPorcelainEntry = {
      path: record.slice(3),
      indexStatus,
      worktreeStatus,
    };
    if (usesRenamePath(indexStatus, worktreeStatus)) {
      entry.originalPath = records[++i] || undefined;
    }
    entries.push(entry);
  }

  return entries;
}

const CONFLICT_STATUSES = new Set(["DD", "AU", "UD", "UA", "DU", "AA", "UU"]);

export function classifyGitStatus(entry: GitPorcelainEntry): Pick<GitFileStatus, "status" | "code"> {
  const pair = `${entry.indexStatus}${entry.worktreeStatus}`;
  if (pair === "??") return { status: "untracked", code: "U" };
  if (CONFLICT_STATUSES.has(pair) || pair.includes("U")) return { status: "conflict", code: "C" };
  if (pair.includes("D")) return { status: "deleted", code: "D" };
  if (pair.includes("R") || pair.includes("C")) return { status: "renamed", code: "R" };
  if (pair.includes("A")) return { status: "added", code: "A" };
  return { status: "modified", code: "M" };
}
