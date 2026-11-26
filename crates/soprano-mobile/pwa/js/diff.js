// Unified diff parsing and rendering (line tints from the theme's diff colors, word highlights).

import { h } from './dom.js';

const stripPrefix = (path) => (path === '/dev/null' ? null : path.replace(/^[ab]\//, ''));

function newFile(path = null) {
  return { oldPath: path, newPath: path, lines: [], additions: 0, deletions: 0, status: null, binary: false, inHunk: false };
}

/** Splits a unified diff into files: {path, oldPath, newPath, status, binary, additions, deletions, lines}. */
export function parseDiff(text, fallbackPath = null) {
  const files = [];
  let file = null;
  let oldNo = 0;
  let newNo = 0;
  const start = (path = null) => {
    file = newFile(path);
    files.push(file);
  };
  const lines = String(text ?? '').replace(/\r\n/g, '\n').split('\n');
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const git = line.match(/^diff --git a\/(.*) b\/(.*)$/);
    if (git) {
      start();
      file.oldPath = git[1];
      file.newPath = git[2];
      continue;
    }
    // A "--- " line is a file header only when "+++ " and a hunk follow; otherwise it is a
    // removed line that starts with "--".
    const header = line.startsWith('--- ') && lines[i + 1]?.startsWith('+++ ') && lines[i + 2]?.startsWith('@@ ');
    if (header && (!file || file.inHunk || file.lines.length)) {
      start(fallbackPath);
      file.oldPath = stripPrefix(line.slice(4).split('\t')[0]);
      continue;
    }
    if (!file) start(fallbackPath);
    if (!file.inHunk) {
      if (line.startsWith('--- ')) { file.oldPath = stripPrefix(line.slice(4).split('\t')[0]); continue; }
      if (line.startsWith('+++ ')) { file.newPath = stripPrefix(line.slice(4).split('\t')[0]); continue; }
      if (line.startsWith('new file mode')) { file.status = 'added'; continue; }
      if (line.startsWith('deleted file mode')) { file.status = 'deleted'; continue; }
      if (line.startsWith('rename from ')) { file.oldPath = line.slice(12); file.status = 'renamed'; continue; }
      if (line.startsWith('rename to ')) { file.newPath = line.slice(10); file.status = 'renamed'; continue; }
      if (/^(index |similarity index|old mode|new mode|copy from|copy to|dissimilarity index)/.test(line)) continue;
      if (/^Binary files .* differ$/.test(line)) { file.binary = true; continue; }
    }
    const hunk = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/);
    if (hunk) {
      file.inHunk = true;
      oldNo = Number(hunk[1]);
      newNo = Number(hunk[2]);
      file.lines.push({ type: 'hunk', text: line });
      continue;
    }
    if (line === '' && !file.inHunk) continue;
    const first = line[0];
    if (first === '+') {
      file.lines.push({ type: 'add', text: line.slice(1), newNo: file.inHunk ? newNo++ : null });
      file.additions++;
    } else if (first === '-') {
      file.lines.push({ type: 'del', text: line.slice(1), oldNo: file.inHunk ? oldNo++ : null });
      file.deletions++;
    } else if (first === ' ') {
      file.lines.push({ type: 'ctx', text: line.slice(1), oldNo: file.inHunk ? oldNo++ : null, newNo: file.inHunk ? newNo++ : null });
    } else if (first === '\\') {
      file.lines.push({ type: 'meta', text: line });
    } else if (line !== '') {
      // Not a diff line (e.g. a preview hunk's "PUT 12.=14:"): show it like a hunk header.
      file.lines.push({ type: 'hunk', text: line });
    }
  }
  // Drop a trailing empty line artifact.
  for (const f of files) {
    while (f.lines.length && f.lines.at(-1).type === 'ctx' && f.lines.at(-1).text === '' && f.lines.at(-1).oldNo == null) f.lines.pop();
    f.path = f.newPath ?? f.oldPath ?? fallbackPath ?? 'file';
    if (!f.status) f.status = f.oldPath == null && f.newPath ? 'added' : f.newPath == null && f.oldPath ? 'deleted' : 'modified';
  }
  return files.filter((f) => f.lines.length || f.binary || f.oldPath || f.newPath);
}

function commonAffixes(a, b) {
  let prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] === b[prefix]) prefix++;
  let suffix = 0;
  while (suffix < a.length - prefix && suffix < b.length - prefix && a[a.length - 1 - suffix] === b[b.length - 1 - suffix]) suffix++;
  return [prefix, suffix];
}

function codeCell(text, range) {
  const cell = h('span', { class: 'dl-code' });
  if (!range) {
    cell.textContent = text || ' ';
    return cell;
  }
  const [prefix, suffix] = range;
  cell.append(text.slice(0, prefix), h('mark', { class: 'dl-word', text: text.slice(prefix, text.length - suffix) }), text.slice(text.length - suffix));
  return cell;
}

/** Word highlights: pairs of removed/added lines of equal-length runs get their changed middle marked. */
function wordRanges(lines) {
  const ranges = new Map();
  let i = 0;
  while (i < lines.length) {
    if (lines[i].type !== 'del') {
      i++;
      continue;
    }
    const dels = [];
    while (i < lines.length && lines[i].type === 'del') dels.push(i++);
    const adds = [];
    while (i < lines.length && lines[i].type === 'add') adds.push(i++);
    if (dels.length !== adds.length) continue;
    dels.forEach((d, k) => {
      const a = adds[k];
      const before = lines[d].text;
      const after = lines[a].text;
      const [prefix, suffix] = commonAffixes(before, after);
      const changedBefore = before.length - prefix - suffix;
      const changedAfter = after.length - prefix - suffix;
      // Only worth marking when most of the line stayed.
      if (prefix + suffix < 3 || (changedBefore === 0 && changedAfter === 0)) return;
      if (changedBefore > 0) ranges.set(d, [prefix, suffix]);
      if (changedAfter > 0) ranges.set(a, [prefix, suffix]);
    });
  }
  return ranges;
}

/** Renders diff lines. `plain` draws a write's whole content as numbered lines. */
export function renderDiffLines(lines, { plain = false } = {}) {
  const inner = h('div', { class: 'diff-inner' });
  const ranges = plain ? new Map() : wordRanges(lines);
  lines.forEach((line, index) => {
    if (line.type === 'hunk' || line.type === 'meta') {
      inner.append(h('div', { class: `dl dl-${line.type}` }, h('span', { class: 'dl-no', 'aria-hidden': 'true' }), h('span', { class: 'dl-code', text: line.text })));
      return;
    }
    const number = plain ? index + 1 : line.type === 'del' ? line.oldNo : line.newNo;
    const sign = plain ? ' ' : line.type === 'add' ? '+' : line.type === 'del' ? '-' : ' ';
    inner.append(h('div', { class: `dl dl-${plain ? 'ctx' : line.type}` },
      h('span', { class: 'dl-no', 'aria-hidden': 'true', text: number ?? '' }),
      h('span', { class: 'dl-sign', 'aria-hidden': 'true', text: sign }),
      codeCell(line.text, ranges.get(index))));
  });
  return h('div', { class: 'diff' }, inner);
}
