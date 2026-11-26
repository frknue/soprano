// Small, safe Markdown renderer for assistant messages. All text is HTML-escaped before any markup is
// added; links are kept only for http(s) URLs.

const ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };

export function escapeHTML(text) {
  return String(text).replace(/[&<>"']/g, (c) => ESCAPES[c]);
}

const FENCE = /^(\s{0,3})(`{3,}|~{3,})\s*([^\s`]*)[^`]*$/;
const HEADING = /^\s{0,3}(#{1,6})\s+(.*?)(?:\s+#+)?\s*$/;
const RULE = /^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/;
const QUOTE = /^\s{0,3}>/;
const LIST = /^(\s*)([-*+]|\d{1,9}[.)])\s+(.*)$/;
const BLANK = /^\s*$/;

const indentOf = (line) => line.match(/^\s*/)[0].replace(/\t/g, '    ').length;

function isTableDivider(line) {
  return line.includes('-') && line.includes('|') && /^\s*\|?(\s*:?-+:?\s*\|)*\s*:?-+:?\s*\|?\s*$/.test(line);
}

function startsBlock(lines, index) {
  const line = lines[index];
  return FENCE.test(line) || HEADING.test(line) || RULE.test(line) || QUOTE.test(line) || LIST.test(line)
    || (line.includes('|') && index + 1 < lines.length && isTableDivider(lines[index + 1]));
}

export function renderMarkdown(source) {
  return blocks(String(source ?? '').replace(/\r\n?/g, '\n').split('\n'));
}

function blocks(lines) {
  let out = '';
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (BLANK.test(line)) {
      i++;
      continue;
    }
    let match = line.match(FENCE);
    if (match) {
      const [, indent, fence, lang] = match;
      const close = new RegExp(`^\\s{0,3}${fence[0] === '`' ? '`' : '~'}{${fence.length},}\\s*$`);
      const body = [];
      i++;
      while (i < lines.length && !close.test(lines[i])) {
        body.push(lines[i].slice(Math.min(indent.length, indentOf(lines[i]))));
        i++;
      }
      i++;
      out += codeBlock(body.join('\n'), lang);
      continue;
    }
    match = line.match(HEADING);
    if (match) {
      const level = match[1].length;
      out += `<h${level}>${inline(match[2])}</h${level}>`;
      i++;
      continue;
    }
    if (RULE.test(line)) {
      out += '<hr>';
      i++;
      continue;
    }
    if (QUOTE.test(line)) {
      const body = [];
      while (i < lines.length && (QUOTE.test(lines[i]) || (!BLANK.test(lines[i]) && !startsBlock(lines, i) && body.length))) {
        body.push(lines[i].replace(/^\s{0,3}>\s?/, ''));
        i++;
      }
      out += `<blockquote>${blocks(body)}</blockquote>`;
      continue;
    }
    if (line.includes('|') && i + 1 < lines.length && isTableDivider(lines[i + 1])) {
      const [html, next] = table(lines, i);
      out += html;
      i = next;
      continue;
    }
    if (LIST.test(line)) {
      const [html, next] = list(lines, i);
      out += html;
      i = next;
      continue;
    }
    const paragraph = [line.trim()];
    i++;
    while (i < lines.length && !BLANK.test(lines[i]) && !startsBlock(lines, i)) {
      paragraph.push(lines[i].trim());
      i++;
    }
    out += `<p>${paragraph.map((l) => inline(l)).join('\n')}</p>`;
  }
  return out;
}

function codeBlock(code, lang) {
  const label = lang ? escapeHTML(lang) : 'code';
  return `<div class="code-block"><div class="code-head"><span class="code-lang">${label}</span>`
    + '<button type="button" class="code-copy" aria-label="Copy code">Copy</button></div>'
    + `<pre><code>${escapeHTML(code)}</code></pre></div>`;
}

function splitRow(line) {
  let text = line.trim();
  if (text.startsWith('|')) text = text.slice(1);
  if (text.endsWith('|') && !text.endsWith('\\|')) text = text.slice(0, -1);
  const cells = [];
  let current = '';
  for (let k = 0; k < text.length; k++) {
    if (text[k] === '\\' && text[k + 1] === '|') {
      current += '|';
      k++;
    } else if (text[k] === '|') {
      cells.push(current.trim());
      current = '';
    } else {
      current += text[k];
    }
  }
  cells.push(current.trim());
  return cells;
}

function table(lines, start) {
  const header = splitRow(lines[start]);
  const aligns = splitRow(lines[start + 1]).map((cell) => {
    const left = cell.startsWith(':');
    const right = cell.endsWith(':');
    return left && right ? 'center' : right ? 'right' : left ? 'left' : null;
  });
  const cell = (tag, text, index) => {
    const align = aligns[index];
    return `<${tag}${align ? ` style="text-align:${align}"` : ''}>${inline(text)}</${tag}>`;
  };
  let i = start + 2;
  const rows = [];
  while (i < lines.length && !BLANK.test(lines[i]) && lines[i].includes('|')) {
    rows.push(splitRow(lines[i]));
    i++;
  }
  const head = `<tr>${header.map((text, index) => cell('th', text, index)).join('')}</tr>`;
  const body = rows.map((row) => `<tr>${header.map((_, index) => cell('td', row[index] ?? '', index)).join('')}</tr>`).join('');
  return [`<div class="table-wrap"><table><thead>${head}</thead><tbody>${body}</tbody></table></div>`, i];
}

function list(lines, start) {
  const first = lines[start].match(LIST);
  const baseIndent = indentOf(lines[start]);
  const ordered = /\d/.test(first[2]);
  const startNumber = ordered ? parseInt(first[2], 10) : 1;
  const items = [];
  let i = start;
  while (i < lines.length) {
    const line = lines[i];
    const match = line.match(LIST);
    const indent = indentOf(line);
    if (match && indent === baseIndent) {
      if (/\d/.test(match[2]) !== ordered) break;
      items.push({ text: match[3], rest: [] });
      i++;
      continue;
    }
    if (BLANK.test(line)) {
      let j = i + 1;
      while (j < lines.length && BLANK.test(lines[j])) j++;
      if (j < lines.length && (indentOf(lines[j]) > baseIndent || (LIST.test(lines[j]) && indentOf(lines[j]) === baseIndent))) {
        if (indentOf(lines[j]) > baseIndent) items.at(-1).rest.push('');
        i = j;
        continue;
      }
      break;
    }
    if (indent > baseIndent) {
      items.at(-1).rest.push(line);
      i++;
      continue;
    }
    if (!startsBlock(lines, i)) {
      items.at(-1).text += ` ${line.trim()}`;
      i++;
      continue;
    }
    break;
  }
  const html = items.map(({ text, rest }) => {
    let body = text;
    let className = '';
    const task = text.match(/^\[([ xX])\]\s+(.*)$/);
    let prefix = '';
    if (task) {
      className = ' class="task"';
      prefix = `<input type="checkbox" disabled${task[1] === ' ' ? '' : ' checked'} aria-label="${task[1] === ' ' ? 'Not done' : 'Done'}"> `;
      body = task[2];
    }
    let nested = '';
    if (rest.length) {
      const content = rest.filter((l) => !BLANK.test(l));
      const dedent = content.length ? Math.min(...content.map(indentOf)) : 0;
      nested = blocks(rest.map((l) => l.replace(/\t/g, '    ').slice(Math.min(dedent, indentOf(l)))));
    }
    return `<li${className}>${prefix}${inline(body)}${nested}</li>`;
  }).join('');
  const tag = ordered ? 'ol' : 'ul';
  const startAttr = ordered && startNumber !== 1 ? ` start="${startNumber}"` : '';
  return [`<${tag}${startAttr}>${html}</${tag}>`, i];
}

const SAFE_URL = /^https?:\/\/[^\s]+$/i;

function link(url, label) {
  return `<a href="${url}" target="_blank" rel="noopener noreferrer">${label}</a>`;
}

/** Inline Markdown: code spans, links, autolinks, bold, italic, strikethrough. */
export function inline(raw) {
  const slots = [];
  const keep = (html) => `\u0000${slots.push(html) - 1}\u0000`;
  // NUL delimits the placeholders below; one in the source could make a placeholder name itself
  // and expand forever, so the source never carries any.
  let text = String(raw).replace(/\u0000/g, '\uFFFD').replace(/(`+)([^`]|[^`][\s\S]*?[^`])\1(?!`)/g, (_, ticks, code) => {
    const trimmed = /^ .* $/.test(code) ? code.slice(1, -1) : code;
    return keep(`<code>${escapeHTML(trimmed)}</code>`);
  });
  text = escapeHTML(text);
  // [label](url "title")
  text = text.replace(/\[([^\]\u0000]*(?:\u0000\d+\u0000[^\]\u0000]*)*)\]\(\s*(?:&lt;)?([^\s)]+?)(?:&gt;)?(?:\s+&quot;[^)]*?&quot;)?\s*\)/g, (whole, label, url) => {
    const shown = emphasis(label);
    return SAFE_URL.test(url) ? keep(link(url, shown)) : keep(shown);
  });
  // <https://…>
  text = text.replace(/&lt;(https?:\/\/[^\s&]+)&gt;/gi, (_, url) => keep(link(url, url)));
  // Bare URLs.
  text = text.replace(/(^|[\s(])(https?:\/\/(?:(?!&(?:lt|gt|quot|#39);)[^\s\u0000])+)/gi, (_, lead, url) => {
    let trail = '';
    while (/[.,;:!?)\]'*_]$/.test(url) && !(url.endsWith(')') && url.includes('('))) {
      trail = url.slice(-1) + trail;
      url = url.slice(0, -1);
    }
    return `${lead}${keep(link(url, url))}${trail}`;
  });
  text = emphasis(text);
  let previous;
  do {
    previous = text;
    text = text.replace(/\u0000(\d+)\u0000/g, (_, index) => slots[Number(index)]);
  } while (text !== previous && text.includes('\u0000'));
  return text;
}

function emphasis(text) {
  return text
    .replace(/\*\*(?=\S)([\s\S]*?\S)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^\w])__(?=\S)([\s\S]*?\S)__(?!\w)/g, '$1<strong>$2</strong>')
    .replace(/(^|[^*\w])\*(?=[^\s*])([^*]*?[^\s*])\*(?!\*)/g, '$1<em>$2</em>')
    .replace(/(^|[^\w])_(?=[^\s_])([^_]*?[^\s_])_(?!\w)/g, '$1<em>$2</em>')
    .replace(/~~(?=\S)([\s\S]*?\S)~~/g, '<del>$1</del>');
}
