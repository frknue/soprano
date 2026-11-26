// Helpers over the wire models: status pills, turn state, durations.

/** Live working duration: `Ns`, `Nm`, `Hh Mm`. */
export function compactDuration(ms) {
  const seconds = Math.max(0, Math.floor(ms / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

/** Turn duration ("Worked for 1m 12s"). */
export function turnDuration(ms) {
  const interval = ms / 1000;
  if (interval < 1) return `${Math.max(0, Math.floor(ms))}ms`;
  if (interval < 10) return `${interval.toFixed(1)}s`;
  const seconds = Math.floor(interval);
  if (seconds < 60) return `${seconds}s`;
  const parts = [];
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  const rest = seconds % 60;
  if (hours) parts.push(`${hours}h`);
  if (minutes) parts.push(`${minutes}m`);
  if (rest) parts.push(`${rest}s`);
  return parts.join(' ');
}

/** Inbox relative time: "now", "Nm", "Nh", "Nd". */
export function relativeTime(ms, now = Date.now()) {
  if (!ms) return '';
  const seconds = Math.floor((now - ms) / 1000);
  if (seconds < 60) return 'now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86400)}d`;
}

/**
 * The status pill of a thread summary, as the desktop shows it: {tone, label, since} or null for
 * an idle agent (callers show a relative time instead).
 */
export function pillFor(summary) {
  switch (summary?.status) {
    case 'running':
      return { tone: 'working', label: 'Working', since: summary.since_ms };
    case 'starting':
      return { tone: 'working', label: 'Starting' };
    case 'waiting':
      if (summary.waiting_reason === 'approval') return { tone: 'approval', label: 'Approval' };
      if (summary.waiting_reason === 'turn') return { tone: 'done', label: 'Done' };
      return { tone: 'input', label: 'Input' };
    case 'error':
      return { tone: 'failed', label: 'Failed' };
    case 'stopped':
      return { tone: 'muted', label: 'Stopped' };
    default:
      return summary?.needs_attention ? { tone: 'done', label: 'Done' } : null;
  }
}

/** The turn the agent works on: the last one while it runs. */
export function activeTurn(thread) {
  const last = thread?.turns?.at(-1);
  return last && last.status === 'running' ? last : null;
}

/** Lines added and removed in a unified diff text. */
export function diffStats(diff) {
  let additions = 0;
  let deletions = 0;
  for (const line of String(diff ?? '').split('\n')) {
    if (line.startsWith('+++') || line.startsWith('---')) continue;
    if (line[0] === '+') additions++;
    else if (line[0] === '-') deletions++;
  }
  return { additions, deletions };
}
