// Thread timeline: turns with their message, activity items and footer; queued messages.

import { parseDiff, renderDiffLines } from './diff.js';
import { h, icon, reconcile, spinner } from './dom.js';
import { renderMarkdown } from './markdown.js';
import { compactDuration, diffStats, turnDuration } from './model.js';

/** Rows the person opened (or closed, for rows open by default); survives re-renders. */
const expanded = new Set();

function fold(key, summaryChildren, buildBody, { cls = '' } = {}) {
  const details = h('details', { class: `fold ${cls}`.trim() },
    h('summary', null, icon('chevronRight', { size: 14, cls: 'disclosure' }), summaryChildren));
  let built = false;
  const build = () => {
    if (built) return;
    built = true;
    details.append(h('div', { class: 'fold-body' }, buildBody()));
  };
  details.addEventListener('toggle', () => {
    if (details.open) {
      expanded.add(key);
      build();
    } else {
      expanded.delete(key);
    }
  });
  if (expanded.has(key)) {
    details.open = true;
    build();
  }
  return details;
}

function pre(text, cls = 'output') {
  return h('pre', { class: cls }, h('code', { text }));
}

function markdown(text, cls) {
  return h('div', { class: `md ${cls}`.trim(), html: renderMarkdown(text) });
}

function userBubble(text, { label = null, cls = '' } = {}) {
  return h('div', { class: `user-message ${cls}`.trim() },
    label ? h('div', { class: 'user-meta' }, label) : null,
    h('div', { class: 'bubble' }, h('div', { class: 'bubble-text', text })));
}

const isActive = (item) => item.status === 'running' || item.status === 'pending';

const FILE_VERBS = {
  add: ['Creating', 'Created'],
  delete: ['Deleting', 'Deleted'],
  update: ['Editing', 'Edited'],
  move: ['Moving', 'Moved'],
};

function pathLabel(path) {
  const index = path.lastIndexOf('/');
  const [dir, base] = index < 0 ? ['', path] : [path.slice(0, index + 1), path.slice(index + 1)];
  return h('span', { class: 'path' }, h('span', { class: 'path-base', text: base }), dir ? h('span', { class: 'path-dir', text: ` ${dir}` }) : null);
}

function fileChangeRow(turnID, item, change, index) {
  const verbs = change.is_full_content ? ['Writing', 'Wrote'] : FILE_VERBS[change.kind] ?? FILE_VERBS.update;
  let stats = null;
  if (change.diff && change.is_full_content) {
    stats = h('span', { class: 'meta', text: `${change.diff.split('\n').length} lines` });
  } else if (change.diff) {
    const { additions, deletions } = diffStats(change.diff);
    stats = h('span', { class: 'stats' }, h('span', { class: 'stat-add', text: `+${additions}` }), h('span', { class: 'stat-del', text: `−${deletions}` }));
  }
  const summary = [
    icon('file', { size: 16, cls: 'row-icon' }),
    h('span', { class: 'row-title' },
      h('span', { class: 'verb', text: `${isActive(item) ? verbs[0] : verbs[1]} ` }),
      pathLabel(change.move_path ? `${change.path} → ${change.move_path}` : change.path)),
    stats,
  ];
  if (!change.diff) return h('div', { class: 'work-row' }, summary);
  return fold(`${turnID}:${item.id}:${index}`, summary, () => {
    if (change.is_full_content) {
      return renderDiffLines(change.diff.split('\n').map((text) => ({ type: 'ctx', text })), { plain: true });
    }
    const files = parseDiff(change.diff, change.path);
    if (files.length === 1) return renderDiffLines(files[0].lines);
    return files.map((f) => [h('div', { class: 'fold-label mono', text: f.path }), renderDiffLines(f.lines)]);
  }, { cls: 'work' });
}

function statusChip(item) {
  if (isActive(item)) return spinner('Running');
  if (item.status === 'failed') return h('span', { class: 'chip chip-error', text: 'Failed' });
  if (item.status === 'declined') return h('span', { class: 'chip', text: 'Declined' });
  if (item.status === 'interrupted') return h('span', { class: 'chip', text: 'Stopped' });
  return null;
}

function commandRow(turnID, item) {
  const failed = (item.exit_code != null && item.exit_code !== 0) || item.status === 'failed';
  const exit = item.exit_code == null ? null
    : h('span', { class: `chip ${failed ? 'chip-error' : 'chip-quiet'}`, text: `exit ${item.exit_code}` });
  return fold(`${turnID}:${item.id}`, [
    icon('terminal', { size: 16, cls: 'row-icon' }),
    h('code', { class: 'row-command', text: item.command }),
    isActive(item) ? spinner('Running') : exit ?? statusChip(item),
  ], () => {
    const output = pre(item.output || (isActive(item) ? '' : 'No output'));
    // The end of the output is what a running command is at.
    requestAnimationFrame(() => { output.scrollTop = output.scrollHeight; });
    return [h('pre', { class: 'command-line' }, h('code', { text: `$ ${item.command}` })), output];
  }, { cls: `work${failed ? ' failed' : ''}` });
}

const TOOL_ICONS = { read: 'file', search: 'search', subagent: 'person', other: 'tool' };

function toolRow(turnID, item) {
  const summary = [
    icon(TOOL_ICONS[item.category] ?? 'tool', { size: 16, cls: 'row-icon' }),
    h('span', { class: 'row-title', text: item.title || item.name }),
    statusChip(item),
  ];
  if (!item.input && !item.output) return h('div', { class: 'work-row' }, summary);
  return fold(`${turnID}:${item.id}`, summary, () => [
    item.input ? h('div', { class: 'fold-label', text: 'Input' }) : null,
    item.input ? pre(item.input) : null,
    item.output ? h('div', { class: 'fold-label', text: 'Output' }) : null,
    item.output ? pre(item.output) : null,
  ], { cls: 'work' });
}

const DECISIONS = {
  accept: 'Approved',
  accept_for_session: 'Allowed for this session',
  decline: 'Declined',
  cancel: 'Cancelled',
};

function approvalRow(item) {
  const accepted = item.decision === 'accept' || item.decision === 'accept_for_session';
  return h('div', { class: 'work-row' }, icon(accepted ? 'check' : 'x', { size: 16, cls: 'row-icon' }),
    h('span', { class: 'row-title' },
      h('span', { class: 'verb', text: `${DECISIONS[item.decision] ?? item.decision} ` }),
      h('code', { class: 'row-command', text: item.detail })));
}

function userInputRow(turnID, item) {
  if (item.dismissed) {
    return h('div', { class: 'work-row' }, icon('question', { size: 16, cls: 'row-icon' }), h('span', { class: 'row-title muted', text: 'Questions dismissed' }));
  }
  const count = item.answers.length;
  return fold(`${turnID}:${item.id}`, [
    icon('question', { size: 16, cls: 'row-icon' }),
    h('span', { class: 'row-title', text: count === 1 ? `Answered: ${item.answers[0].question}` : `Answered ${count} questions` }),
  ], () => h('dl', { class: 'answers' }, item.answers.map((entry) => [
    h('dt', { text: entry.question }),
    h('dd', { text: entry.answer || 'No answer' }),
  ])), { cls: 'work' });
}

function renderItem(turnID, item) {
  switch (item.kind) {
    case 'assistant_message':
      if (!item.text?.trim()) return null;
      return markdown(item.text, item.is_final ? 'assistant' : 'assistant commentary');
    case 'reasoning': {
      const running = isActive(item);
      const title = [icon('bulb', { size: 16, cls: 'row-icon' }), h('span', { class: 'row-title', text: running ? 'Thinking…' : 'Thinking' })];
      if (!item.text?.trim()) return running ? h('div', { class: 'work-row' }, title) : null;
      return fold(`${turnID}:${item.id}`, title, () => markdown(item.text, 'reasoning'), { cls: 'work' });
    }
    case 'command':
      return commandRow(turnID, item);
    case 'file_change':
      return h('div', { class: 'file-changes' }, item.files.map((change, index) => fileChangeRow(turnID, item, change, index)));
    case 'tool_call':
      return toolRow(turnID, item);
    case 'web_search':
      return h('div', { class: 'work-row' }, icon('globe', { size: 16, cls: 'row-icon' }),
        h('span', { class: 'row-title' }, h('span', { class: 'verb', text: isActive(item) ? 'Searching ' : 'Searched ' }), h('span', { text: `“${item.query}”` })),
        statusChip(item));
    case 'approval':
      return approvalRow(item);
    case 'user_input':
      return userInputRow(turnID, item);
    case 'steer':
      return userBubble(item.text, { label: 'Steered', cls: 'steer' });
    case 'error':
      return h('div', { class: 'error-box', role: 'note' }, icon('alert', { size: 16 }), h('span', { text: item.message }));
    case 'notice':
      return h('div', { class: 'notice', role: 'separator' }, h('span', { text: item.text }));
    default:
      return null;
  }
}

/** `waiting`: what the thread waits on from the person while this turn runs, if anything. */
function footer(turn, waiting) {
  if (turn.status === 'running') {
    if (waiting && !turn.stopping) {
      return h('div', { class: 'turn-footer waiting', role: 'status' }, icon('clock', { size: 15 }), h('span', { text: waiting }));
    }
    return h('div', { class: 'turn-footer working', role: 'status' },
      spinner('Working'),
      h('span', { text: turn.stopping ? 'Stopping…' : 'Working' }),
      !turn.stopping && turn.started_at_ms
        ? h('span', { class: 'meta', dataset: { since: turn.started_at_ms }, text: compactDuration(Date.now() - turn.started_at_ms) })
        : null);
  }
  const parts = [];
  if (turn.started_at_ms && turn.completed_at_ms) {
    parts.push(h('span', { class: 'meta', text: `Worked for ${turnDuration(turn.completed_at_ms - turn.started_at_ms)}` }));
  }
  if (turn.status === 'interrupted') parts.push(h('span', { class: 'chip', text: 'Interrupted' }));
  if (!parts.length && !turn.failure_message) return h('div', { hidden: true });
  return h('div', { class: 'turn-end' },
    parts.length ? h('div', { class: 'turn-footer' }, parts) : null,
    turn.failure_message ? h('div', { class: 'error-box', role: 'note' }, icon('alert', { size: 16 }), h('span', { text: turn.failure_message })) : null);
}

function itemEntries(turnID, items) {
  return items.map((item) => ({
    key: `${item.kind}:${item.id}`,
    sig: JSON.stringify(item),
    build: () => renderItem(turnID, item) ?? h('div', { hidden: true }),
  }));
}

function turnEntries(turn, waiting) {
  const entries = [];
  if (turn.user_text) entries.push({ key: 'u', sig: turn.user_text, build: () => userBubble(turn.user_text) });
  entries.push(...itemEntries(turn.id, turn.items));
  entries.push({
    key: 'f',
    sig: JSON.stringify([turn.status, turn.stopping, turn.started_at_ms, turn.completed_at_ms, turn.failure_message, waiting]),
    build: () => footer(turn, waiting),
  });
  return entries;
}

/**
 * Renders `thread` (a thread detail) into `container`, reusing unchanged rows. `actions.showAll`
 * loads the turns the server left out.
 */
export function renderTimeline(container, thread, actions) {
  const entries = [];
  if (thread.earlier_turns > 0) {
    entries.push({
      key: 'earlier',
      sig: String(thread.earlier_turns),
      build: () => {
        const button = h('button', { type: 'button', class: 'button small ghost earlier', text: `Show ${thread.earlier_turns} earlier ${thread.earlier_turns === 1 ? 'turn' : 'turns'}` });
        button.addEventListener('click', () => {
          button.disabled = true;
          button.append(spinner('Loading'));
          actions.showAll();
        });
        return button;
      },
    });
  }
  if (thread.preamble.length) {
    entries.push({ key: 'preamble', sig: 'turn', build: () => h('section', { class: 'turn' }) });
  }
  const last = thread.turns.at(-1);
  for (const turn of thread.turns) {
    entries.push({ key: `t:${turn.id}`, sig: 'turn', build: () => h('section', { class: 'turn' }) });
  }
  if (!thread.turns.length && !thread.preamble.length) {
    entries.push({
      key: 'empty',
      sig: String(thread.loading),
      build: () => (thread.loading
        ? h('div', { class: 'placeholder', role: 'status' }, spinner(), h('span', { text: 'Reading the conversation…' }))
        : h('div', { class: 'placeholder' }, h('p', { text: 'Nothing in this conversation yet.' }))),
    });
  }
  for (const [index, text] of thread.queued_prompts.entries()) {
    entries.push({
      key: `q:${index}`,
      sig: text,
      build: () => userBubble(text, { label: [icon('clock', { size: 13 }), ' Queued'], cls: 'queued' }),
    });
  }
  reconcile(container, entries);

  const waiting = thread.pending_approval ? 'Waiting for your approval' : thread.pending_input ? 'Waiting for your answers' : null;
  for (const section of container.children) {
    if (section._key === 'preamble') {
      reconcile(section, itemEntries('preamble', thread.preamble));
    } else if (section._key?.startsWith('t:')) {
      const turn = thread.turns.find((t) => `t:${t.id}` === section._key);
      if (turn) reconcile(section, turnEntries(turn, turn === last ? waiting : null));
    }
  }
}
