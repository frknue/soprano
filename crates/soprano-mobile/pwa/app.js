const state = {
  authenticated: null, // null = checking, false = needs pairing, true = ready
  pairingError: null,
  connected: false,
  offlineError: null,
  snapshot: null,
  selectedThreadId: null,
  threadDetail: null,
  threadLoading: false,
  searchQuery: '',
  foldedSections: new Set(['stopped']),
  composerText: '',
  sending: false,
  newThreadOpen: false,
  draftProject: '',
  draftAgent: '',
  draftPrompt: '',
  draftError: null,
  inputAnswers: {},
  installHintDismissed: localStorage.getItem('soprano-install-hint-dismissed') === '1',
};

let ws = null;
let wsReconnectTimer = null;
let wsRetryMs = 1000;
let tickTimer = null;

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch(() => {});
}

function escapeHtml(text) {
  return String(text ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function renderMarkdown(md) {
  const src = String(md ?? '');
  const codeBlocks = [];
  let text = src.replace(/```([\w-]*)\n([\s\S]*?)```/g, (_, _lang, code) => {
    const idx = codeBlocks.length;
    codeBlocks.push(`<pre><code>${escapeHtml(code.replace(/\n$/, ''))}</code></pre>`);
    return `@@CODEBLOCK_${idx}@@`;
  });

  const blocks = text.split(/\n{2,}/);
  const htmlBlocks = blocks.map((block) => {
    const trimmed = block.trim();
    if (!trimmed) return '';
    if (/^@@CODEBLOCK_\d+@@$/.test(trimmed)) return trimmed;

    const lines = trimmed.split('\n');
    if (lines.every((l) => /^[-*]\s+/.test(l.trim()))) {
      const items = lines.map((l) => `<li>${renderInline(l.trim().replace(/^[-*]\s+/, ''))}</li>`).join('');
      return `<ul>${items}</ul>`;
    }
    if (lines.every((l) => /^\d+\.\s+/.test(l.trim()))) {
      const items = lines.map((l) => `<li>${renderInline(l.trim().replace(/^\d+\.\s+/, ''))}</li>`).join('');
      return `<ol>${items}</ol>`;
    }
    const heading = trimmed.match(/^(#{1,3})\s+(.+)$/);
    if (heading && lines.length === 1) {
      const level = heading[1].length + 2;
      return `<h${level} style="margin:6px 0">${renderInline(heading[2])}</h${level}>`;
    }
    return `<p>${lines.map(renderInline).join('<br>')}</p>`;
  });

  return htmlBlocks.join('').replace(/@@CODEBLOCK_(\d+)@@/g, (_, idx) => codeBlocks[Number(idx)] || '');
}

function renderInline(line) {
  let out = escapeHtml(line);
  out = out.replace(/`([^`]+)`/g, '<code>$1</code>');
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  out = out.replace(/\*([^*]+)\*/g, '<em>$1</em>');
  return out;
}

function applyTheme(theme) {
  if (!theme) return;
  const root = document.documentElement.style;
  if (theme.canvas) root.setProperty('--bg-canvas', theme.canvas);
  if (theme.surface) root.setProperty('--bg-surface', theme.surface);
  if (theme.raised) root.setProperty('--bg-raised', theme.raised);
  if (theme.hover) root.setProperty('--bg-hover', theme.hover);
  if (theme.border) root.setProperty('--border', theme.border);
  if (theme.foreground) root.setProperty('--fg', theme.foreground);
  if (theme.muted) root.setProperty('--muted', theme.muted);
  if (theme.dim) root.setProperty('--dim', theme.dim);
  if (theme.accent) root.setProperty('--accent', theme.accent);
  if (theme.working) root.setProperty('--working', theme.working);
  if (theme.approval) root.setProperty('--approval', theme.approval);
  if (theme.input) root.setProperty('--input', theme.input);
  if (theme.failed) root.setProperty('--failed', theme.failed);
  if (theme.done) root.setProperty('--done', theme.done);
  const meta = document.getElementById('theme-color-meta');
  if (meta && theme.surface) meta.setAttribute('content', theme.surface);
}

function formatDuration(sinceMs) {
  const secs = Math.max(0, Math.floor((Date.now() - sinceMs) / 1000));
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h ${mins % 60}m`;
  return `${Math.floor(hrs / 24)}d`;
}

function formatRelative(sinceMs) {
  const secs = Math.max(0, Math.floor((Date.now() - sinceMs) / 1000));
  if (secs < 45) return 'now';
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m`;
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return `${hrs}h`;
  return `${Math.floor(hrs / 24)}d`;
}

function statusPill(thread) {
  if (thread.waiting_reason === 'permission' || thread.waiting_reason === 'approval') {
    return { cls: 'approval', label: 'Approval' };
  }
  if (thread.waiting_reason === 'input' || thread.waiting_reason === 'question') {
    return { cls: 'input', label: 'Input' };
  }
  switch (thread.status) {
    case 'running':
      return { cls: 'working', label: `Working ${formatDuration(thread.since_ms)}` };
    case 'starting':
      return { cls: 'working', label: 'Starting' };
    case 'waiting':
      return { cls: 'approval', label: 'Waiting' };
    case 'error':
      return { cls: 'failed', label: 'Failed' };
    case 'stopped':
      return { cls: 'stopped', label: 'Stopped' };
    case 'idle':
      return thread.needs_attention
        ? { cls: 'done', label: 'Done' }
        : { cls: 'idle', label: formatRelative(thread.since_ms) };
    default:
      return { cls: 'idle', label: thread.status };
  }
}

function detectDeviceName() {
  const ua = navigator.userAgent || '';
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/iPad/.test(ua)) return 'iPad';
  if (/Android/.test(ua)) return 'Android';
  if (/Macintosh/.test(ua)) return 'Mac Browser';
  return 'Mobile Browser';
}

function isStandalone() {
  return window.matchMedia('(display-mode: standalone)').matches || window.navigator.standalone === true;
}

async function apiFetch(path, options = {}) {
  const res = await fetch(path, {
    credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options,
  });
  if (res.status === 401) {
    state.authenticated = false;
    closeWebSocket();
    render();
    throw new Error('Unauthorized');
  }
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(body.error || `Request failed (${res.status})`);
  }
  return body;
}

async function attemptHashPairing() {
  const hash = window.location.hash || '';
  const match = hash.match(/(?:^|[#&])t=([^&]+)/);
  if (!match) return false;
  const token = decodeURIComponent(match[1]);
  history.replaceState(null, '', '/');
  try {
    const res = await fetch('/api/pair', {
      method: 'POST',
      credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ token, device_name: detectDeviceName() }),
    });
    const body = await res.json().catch(() => ({}));
    if (!res.ok) {
      state.authenticated = false;
      state.pairingError = body.error || 'Pairing code expired or invalid. Scan a fresh QR code in Soprano Settings.';
      return true;
    }
    state.authenticated = true;
    state.pairingError = null;
    return true;
  } catch {
    state.authenticated = false;
    state.pairingError = 'Could not reach Soprano to complete pairing. Check your Tailscale connection.';
    return true;
  }
}

async function loadSnapshot() {
  try {
    const snap = await apiFetch('/api/snapshot');
    state.snapshot = snap;
    state.authenticated = true;
    state.offlineError = null;
    applyTheme(snap.theme);
    if (!state.draftProject && snap.projects?.length) {
      state.draftProject = snap.projects[0].path;
    }
    if (!state.draftAgent && snap.agents?.length) {
      state.draftAgent = snap.agents[0].id;
    }
    render();
  } catch (err) {
    if (err.message !== 'Unauthorized') {
      state.offlineError = 'Cannot reach Soprano right now. Make sure your Mac is awake and Tailscale is connected.';
      render();
    }
  }
}

async function loadThread(threadId, silent = false) {
  if (!silent) {
    state.threadLoading = true;
    render();
  }
  try {
    const detail = await apiFetch(`/api/threads/${encodeURIComponent(threadId)}`);
    if (state.selectedThreadId === threadId) {
      state.threadDetail = detail;
      state.threadLoading = false;
      render();
      if (!silent) scrollChatToBottom();
    }
  } catch (err) {
    if (state.selectedThreadId === threadId) {
      state.threadLoading = false;
      if (err.message !== 'Unauthorized') {
        state.offlineError = err.message;
      }
      render();
    }
  }
}

function scrollChatToBottom() {
  requestAnimationFrame(() => {
    const el = document.getElementById('chat-stream');
    if (el) el.scrollTop = el.scrollHeight;
  });
}

function closeWebSocket() {
  if (wsReconnectTimer) {
    clearTimeout(wsReconnectTimer);
    wsReconnectTimer = null;
  }
  if (ws) {
    ws.onclose = null;
    ws.close();
    ws = null;
  }
  state.connected = false;
}

function connectWebSocket() {
  if (!state.authenticated) return;
  closeWebSocket();
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${proto}//${location.host}/api/ws`);
  ws.onopen = () => {
    state.connected = true;
    state.offlineError = null;
    wsRetryMs = 1000;
    render();
  };
  ws.onmessage = (event) => {
    try {
      const msg = JSON.parse(event.data);
      if (msg.type === 'snapshot' && msg.snapshot) {
        state.snapshot = msg.snapshot;
        applyTheme(msg.snapshot.theme);
        if (state.selectedThreadId) {
          loadThread(state.selectedThreadId, true);
        } else {
          render();
        }
      } else if (msg.type === 'thread_updated' && msg.thread_id === state.selectedThreadId) {
        loadThread(state.selectedThreadId, true);
      }
    } catch {}
  };
  ws.onclose = () => {
    state.connected = false;
    render();
    if (state.authenticated) {
      wsReconnectTimer = setTimeout(() => {
        wsRetryMs = Math.min(wsRetryMs * 1.6, 10000);
        loadSnapshot().then(() => connectWebSocket());
      }, wsRetryMs);
    }
  };
}

function openThread(threadId) {
  state.selectedThreadId = threadId;
  state.threadDetail = null;
  state.composerText = '';
  state.inputAnswers = {};
  loadThread(threadId, false);
}

function closeThread() {
  state.selectedThreadId = null;
  state.threadDetail = null;
  render();
}

async function sendReply() {
  const text = state.composerText.trim();
  if (!text || !state.selectedThreadId || state.sending) return;
  state.sending = true;
  render();
  try {
    await apiFetch(`/api/threads/${encodeURIComponent(state.selectedThreadId)}/reply`, {
      method: 'POST',
      body: JSON.stringify({ text }),
    });
    state.composerText = '';
    await loadThread(state.selectedThreadId, true);
    scrollChatToBottom();
  } catch (err) {
    state.offlineError = err.message;
  } finally {
    state.sending = false;
    render();
  }
}

async function approveOption(optionId) {
  if (!state.selectedThreadId) return;
  try {
    await apiFetch(`/api/threads/${encodeURIComponent(state.selectedThreadId)}/approve`, {
      method: 'POST',
      body: JSON.stringify({ option_id: optionId }),
    });
    await loadThread(state.selectedThreadId, true);
  } catch (err) {
    state.offlineError = err.message;
    render();
  }
}

async function submitUserInput(pendingInput) {
  if (!state.selectedThreadId) return;
  const answers = {};
  for (const q of pendingInput.questions) {
    const val = (state.inputAnswers[q.id] || '').trim();
    if (val) answers[q.id] = [val];
  }
  try {
    await apiFetch(`/api/threads/${encodeURIComponent(state.selectedThreadId)}/input`, {
      method: 'POST',
      body: JSON.stringify({ answers }),
    });
    state.inputAnswers = {};
    await loadThread(state.selectedThreadId, true);
  } catch (err) {
    state.offlineError = err.message;
    render();
  }
}

async function declineUserInput() {
  if (!state.selectedThreadId) return;
  try {
    await apiFetch(`/api/threads/${encodeURIComponent(state.selectedThreadId)}/decline-input`, {
      method: 'POST',
      body: '{}',
    });
    await loadThread(state.selectedThreadId, true);
  } catch (err) {
    state.offlineError = err.message;
    render();
  }
}

async function threadAction(action) {
  if (!state.selectedThreadId) return;
  try {
    await apiFetch(`/api/threads/${encodeURIComponent(state.selectedThreadId)}/${action}`, {
      method: 'POST',
      body: '{}',
    });
    await loadSnapshot();
    await loadThread(state.selectedThreadId, true);
  } catch (err) {
    state.offlineError = err.message;
    render();
  }
}

async function changeOption(id, value) {
  if (!state.selectedThreadId) return;
  try {
    await apiFetch(`/api/threads/${encodeURIComponent(state.selectedThreadId)}/option`, {
      method: 'POST',
      body: JSON.stringify({ id, value }),
    });
    await loadThread(state.selectedThreadId, true);
  } catch (err) {
    state.offlineError = err.message;
    render();
  }
}

async function submitNewThread() {
  const prompt = state.draftPrompt.trim();
  if (!prompt || !state.draftProject || !state.draftAgent) {
    state.draftError = 'Choose a project, agent, and message.';
    render();
    return;
  }
  state.sending = true;
  state.draftError = null;
  render();
  try {
    const res = await apiFetch('/api/threads', {
      method: 'POST',
      body: JSON.stringify({
        profile_id: state.draftAgent,
        cwd: state.draftProject,
        prompt,
        options: [],
      }),
    });
    state.newThreadOpen = false;
    state.draftPrompt = '';
    await loadSnapshot();
    if (res.thread_id) {
      openThread(res.thread_id);
    }
  } catch (err) {
    state.draftError = err.message;
  } finally {
    state.sending = false;
    render();
  }
}

function renderTurnItem(item) {
  switch (item.kind) {
    case 'assistant_message':
      return `<div class="assistant-prose">${renderMarkdown(item.text)}</div>`;
    case 'reasoning':
      return `<details class="work-card"><summary><span>Thinking</span><span>${escapeHtml(item.status)}</span></summary><div class="work-card-body">${escapeHtml(item.text)}</div></details>`;
    case 'command': {
      const exitText = item.exit_code != null ? `exit ${item.exit_code}` : item.status;
      return `<details class="work-card"><summary><span class="mono">$ ${escapeHtml(item.command)}</span><span>${escapeHtml(exitText)}</span></summary>${item.output ? `<div class="work-card-body">${escapeHtml(item.output)}</div>` : ''}</details>`;
    }
    case 'file_change': {
      const files = item.files || [];
      const summary = files.length === 1 ? files[0].path : `${files.length} changed files`;
      const body = files.map((f) => `${f.kind.toUpperCase()} ${f.path}${f.diff ? '\n' + f.diff : ''}`).join('\n\n');
      return `<details class="work-card"><summary><span class="mono">${escapeHtml(summary)}</span><span>${escapeHtml(item.status)}</span></summary>${body ? `<div class="work-card-body">${escapeHtml(body)}</div>` : ''}</details>`;
    }
    case 'tool_call':
      return `<details class="work-card"><summary><span>${escapeHtml(item.title || item.name)}</span><span>${escapeHtml(item.status)}</span></summary>${item.detail ? `<div class="work-card-body">${escapeHtml(item.detail)}</div>` : ''}</details>`;
    case 'web_search':
      return `<div class="notice-line">Searched: ${escapeHtml(item.query)}</div>`;
    case 'error':
      return `<div class="error-box">${escapeHtml(item.message)}</div>`;
    case 'notice':
      return `<div class="notice-line">${escapeHtml(item.text)}</div>`;
    default:
      return '';
  }
}

function renderPairingScreen() {
  return `
    <div class="centered-state">
      <div class="pair-card">
        <h2>Pair with Soprano</h2>
        ${state.pairingError ? `<div class="error-box">${escapeHtml(state.pairingError)}</div>` : ''}
        <p class="muted">Open <strong>Settings ▸ Mobile</strong> on your computer and scan the pairing QR code with your phone camera.</p>
        <p class="muted">Make sure Tailscale is connected on both devices.</p>
        <div>
          <label class="field-label" for="manual-token">Or paste a pairing code</label>
          <input id="manual-token" class="field-input mono" placeholder="Pairing token" autocomplete="off" />
        </div>
        <button id="manual-pair-btn" class="btn primary">Pair this device</button>
      </div>
    </div>
  `;
}

function renderInbox() {
  const snap = state.snapshot;
  const threads = snap?.threads || [];
  const q = state.searchQuery.trim().toLowerCase();
  const filtered = q
    ? threads.filter((t) =>
        [t.title, t.project, t.profile_name, t.branch].filter(Boolean).some((s) => s.toLowerCase().includes(q))
      )
    : threads;

  const sections = [
    { id: 'needs_you', title: 'Needs you' },
    { id: 'working', title: 'Working' },
    { id: 'ready', title: 'Ready' },
    { id: 'stopped', title: 'Stopped' },
  ];

  const sectionHtml = sections
    .map((sec) => {
      const items = filtered.filter((t) => t.section === sec.id);
      if (!items.length) return '';
      const folded = state.foldedSections.has(sec.id) && !q;
      const cards = folded
        ? ''
        : `<div class="thread-list">${items
            .map((t) => {
              const pill = statusPill(t);
              const metaParts = [t.profile_name, t.branch ? `⎇ ${t.branch}` : null].filter(Boolean);
              return `
                <button class="thread-card ${t.section === 'needs_you' ? 'attention' : ''}" data-thread-id="${escapeHtml(t.id)}">
                  <div class="thread-card-top">
                    <span class="project-name">${escapeHtml(t.project)}</span>
                    <span class="pill ${pill.cls}"><span class="pill-dot"></span>${escapeHtml(pill.label)}</span>
                  </div>
                  <div class="thread-title">${escapeHtml(t.title)}</div>
                  <div class="thread-meta">${metaParts.map((m) => `<span>${escapeHtml(m)}</span>`).join('<span>·</span>')}</div>
                </button>
              `;
            })
            .join('')}</div>`;
      return `
        <div class="section-block">
          <button class="section-header" data-toggle-section="${sec.id}">
            <span>${sec.title}</span>
            <span class="section-count">${items.length}</span>
            <span>${folded ? '›' : '⌄'}</span>
          </button>
          ${cards}
        </div>
      `;
    })
    .join('');

  const installBanner =
    !isStandalone() && !state.installHintDismissed
      ? `<div class="banner info">
          <span>Add to Home Screen for full-screen app mode.</span>
          <button class="icon-btn" id="dismiss-install-hint" aria-label="Dismiss">×</button>
        </div>`
      : '';

  return `
    <header class="topbar">
      <div class="topbar-title">
        <h1>Soprano</h1>
        <div class="topbar-subtitle">${escapeHtml(snap?.host_name || 'Connected')}${state.connected ? '' : ' · Reconnecting…'}</div>
      </div>
      <button class="btn primary" id="open-new-thread">New</button>
    </header>
    ${installBanner}
    ${state.offlineError ? `<div class="banner error"><span>${escapeHtml(state.offlineError)}</span><button class="btn" id="retry-btn">Retry</button></div>` : ''}
    <main class="scroll-body">
      <div class="search-wrap">
        <input id="inbox-search" class="search-input" type="search" placeholder="Filter agents, projects, branches…" value="${escapeHtml(state.searchQuery)}" />
      </div>
      ${sectionHtml || `<div class="centered-state"><p class="muted">${threads.length ? 'No matching agents.' : 'No active agents in Soprano yet.'}</p></div>`}
    </main>
    ${state.newThreadOpen ? renderNewThreadModal() : ''}
  `;
}

function renderNewThreadModal() {
  const projects = state.snapshot?.projects || [];
  const agents = state.snapshot?.agents || [];
  return `
    <div class="modal-backdrop" id="modal-backdrop">
      <div class="modal-sheet">
        <div class="modal-header">
          <h2>New Thread</h2>
          <button class="icon-btn" id="close-new-thread">×</button>
        </div>
        ${state.draftError ? `<div class="error-box">${escapeHtml(state.draftError)}</div>` : ''}
        <div>
          <label class="field-label" for="draft-project">Project</label>
          <select id="draft-project" class="field-select">
            ${projects.map((p) => `<option value="${escapeHtml(p.path)}" ${p.path === state.draftProject ? 'selected' : ''}>${escapeHtml(p.name)} — ${escapeHtml(p.display_path)}</option>`).join('')}
          </select>
        </div>
        <div>
          <label class="field-label" for="draft-agent">Agent</label>
          <select id="draft-agent" class="field-select">
            ${agents.map((a) => `<option value="${escapeHtml(a.id)}" ${a.id === state.draftAgent ? 'selected' : ''}>${escapeHtml(a.name)}</option>`).join('')}
          </select>
        </div>
        <div>
          <label class="field-label" for="draft-prompt">Prompt</label>
          <textarea id="draft-prompt" class="field-textarea" rows="4" placeholder="What should the agent work on?">${escapeHtml(state.draftPrompt)}</textarea>
        </div>
        <button id="submit-new-thread" class="btn primary" ${state.sending ? 'disabled' : ''}>${state.sending ? 'Starting…' : 'Start Thread'}</button>
      </div>
    </div>
  `;
}

function renderThreadView() {
  const summary =
    state.threadDetail?.summary || state.snapshot?.threads?.find((t) => t.id === state.selectedThreadId);
  const detail = state.threadDetail;
  const pill = summary ? statusPill(summary) : null;

  const turnsHtml = (detail?.turns || [])
    .map(
      (turn) => `
      <div class="turn-group">
        ${turn.user_text ? `<div class="user-bubble">${escapeHtml(turn.user_text)}</div>` : ''}
        ${(turn.items || []).map(renderTurnItem).join('')}
      </div>
    `
    )
    .join('');

  const approval = detail?.pending_approval;
  const approvalHtml = approval
    ? `
      <div class="action-card">
        <div class="action-card-title">Approval required · ${escapeHtml(approval.title)}</div>
        ${approval.detail ? `<div class="action-card-detail">${escapeHtml(approval.detail)}</div>` : ''}
        <div class="action-buttons">
          ${approval.options
            .map(
              (opt, idx) =>
                `<button class="btn ${idx === 0 ? 'primary' : ''}" data-approve-option="${escapeHtml(opt.id)}">${escapeHtml(opt.label)}</button>`
            )
            .join('')}
        </div>
      </div>
    `
    : '';

  const pendingInput = detail?.pending_input;
  const inputHtml = pendingInput
    ? `
      <div class="action-card input-card">
        <div class="action-card-title">Agent needs your input</div>
        ${pendingInput.questions
          .map(
            (q) => `
          <div class="question-block">
            <label class="field-label">${escapeHtml(q.prompt)}</label>
            ${
              q.options?.length
                ? `<div class="action-buttons">${q.options
                    .map(
                      (o) =>
                        `<button class="btn ${state.inputAnswers[q.id] === o.label ? 'primary' : ''}" data-pick-answer="${escapeHtml(q.id)}" data-pick-value="${escapeHtml(o.label)}">${escapeHtml(o.label)}</button>`
                    )
                    .join('')}</div>`
                : ''
            }
            <input class="field-input" data-input-question="${escapeHtml(q.id)}" placeholder="Type an answer…" value="${escapeHtml(state.inputAnswers[q.id] || '')}" />
          </div>
        `
          )
          .join('')}
        <div class="action-buttons">
          <button class="btn primary" id="submit-user-input">Send answer</button>
          <button class="btn danger" id="decline-user-input">Decline</button>
        </div>
      </div>
    `
    : '';

  const optionsHtml = (detail?.options || []).length
    ? `<div class="composer-options">
        ${detail.options
          .map(
            (opt) => `
          <select class="option-chip" data-option-id="${escapeHtml(opt.id)}" aria-label="${escapeHtml(opt.name)}">
            ${opt.values
              .map(
                (v) =>
                  `<option value="${escapeHtml(v.value)}" ${v.value === opt.current_value ? 'selected' : ''}>${escapeHtml(v.name)}</option>`
              )
              .join('')}
          </select>
        `
          )
          .join('')}
      </div>`
    : '';

  const isRunning = summary?.status === 'running' || summary?.status === 'starting';
  const isStopped = summary?.status === 'stopped';

  return `
    <header class="topbar">
      <button class="icon-btn" id="back-btn" aria-label="Back">←</button>
      <div class="topbar-title">
        <h1>${escapeHtml(summary?.title || 'Thread')}</h1>
        <div class="topbar-subtitle">${escapeHtml(summary?.project || '')}${summary?.profile_name ? ` · ${escapeHtml(summary.profile_name)}` : ''}</div>
      </div>
      ${pill ? `<span class="pill ${pill.cls}"><span class="pill-dot"></span>${escapeHtml(pill.label)}</span>` : ''}
      ${isStopped ? `<button class="btn" id="restart-thread">Restart</button>` : isRunning ? `<button class="btn danger" id="cancel-thread">Stop</button>` : `<button class="btn" id="stop-thread">Stop</button>`}
    </header>
    ${state.offlineError ? `<div class="banner error"><span>${escapeHtml(state.offlineError)}</span><button class="btn" id="retry-thread-btn">Retry</button></div>` : ''}
    <main class="chat-stream" id="chat-stream">
      ${state.threadLoading && !detail ? `<div class="centered-state"><div class="spinner"></div></div>` : ''}
      ${turnsHtml || (!state.threadLoading ? `<div class="centered-state"><p class="muted">No messages recorded in this thread yet.</p></div>` : '')}
      ${approvalHtml}
      ${inputHtml}
      ${detail?.queued_prompts?.length ? `<div class="notice-line">${detail.queued_prompts.length} queued message(s)</div>` : ''}
    </main>
    <footer class="composer-dock">
      ${optionsHtml}
      <div class="composer-row">
        <textarea id="composer-input" class="composer-textarea" rows="1" placeholder="${summary?.accepts_replies ? 'Reply to agent…' : 'Agent cannot receive replies right now'}" ${summary?.accepts_replies ? '' : 'disabled'}>${escapeHtml(state.composerText)}</textarea>
        <button id="send-reply-btn" class="btn primary" ${!summary?.accepts_replies || state.sending ? 'disabled' : ''}>Send</button>
      </div>
    </footer>
  `;
}

function render() {
  const app = document.getElementById('app');
  if (!app) return;

  if (state.authenticated === null) {
    app.innerHTML = `<div class="centered-state"><div class="spinner"></div><p class="muted">Connecting to Soprano…</p></div>`;
    return;
  }

  if (state.authenticated === false) {
    app.innerHTML = renderPairingScreen();
    bindPairingEvents();
    return;
  }

  if (state.selectedThreadId) {
    const activeId = document.activeElement?.id;
    app.innerHTML = renderThreadView();
    bindThreadEvents();
    if (activeId === 'composer-input') {
      const el = document.getElementById('composer-input');
      if (el) {
        el.focus();
        el.selectionStart = el.selectionEnd = el.value.length;
      }
    }
  } else {
    const activeId = document.activeElement?.id;
    app.innerHTML = renderInbox();
    bindInboxEvents();
    if (activeId === 'inbox-search') {
      const el = document.getElementById('inbox-search');
      if (el) {
        el.focus();
        el.selectionStart = el.selectionEnd = el.value.length;
      }
    }
  }
}

function bindPairingEvents() {
  const btn = document.getElementById('manual-pair-btn');
  const input = document.getElementById('manual-token');
  btn?.addEventListener('click', async () => {
    const token = input?.value?.trim();
    if (!token) return;
    window.location.hash = `#t=${encodeURIComponent(token)}`;
    await attemptHashPairing();
    if (state.authenticated) {
      await loadSnapshot();
      connectWebSocket();
    } else {
      render();
    }
  });
}

function bindInboxEvents() {
  document.getElementById('inbox-search')?.addEventListener('input', (e) => {
    state.searchQuery = e.target.value;
    render();
  });
  document.querySelectorAll('[data-toggle-section]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const id = btn.getAttribute('data-toggle-section');
      if (state.foldedSections.has(id)) state.foldedSections.delete(id);
      else state.foldedSections.add(id);
      render();
    });
  });
  document.querySelectorAll('[data-thread-id]').forEach((card) => {
    card.addEventListener('click', () => openThread(card.getAttribute('data-thread-id')));
  });
  document.getElementById('open-new-thread')?.addEventListener('click', () => {
    state.newThreadOpen = true;
    state.draftError = null;
    render();
  });
  document.getElementById('close-new-thread')?.addEventListener('click', () => {
    state.newThreadOpen = false;
    render();
  });
  document.getElementById('modal-backdrop')?.addEventListener('click', (e) => {
    if (e.target.id === 'modal-backdrop') {
      state.newThreadOpen = false;
      render();
    }
  });
  document.getElementById('draft-project')?.addEventListener('change', (e) => {
    state.draftProject = e.target.value;
  });
  document.getElementById('draft-agent')?.addEventListener('change', (e) => {
    state.draftAgent = e.target.value;
  });
  document.getElementById('draft-prompt')?.addEventListener('input', (e) => {
    state.draftPrompt = e.target.value;
  });
  document.getElementById('submit-new-thread')?.addEventListener('click', submitNewThread);
  document.getElementById('retry-btn')?.addEventListener('click', loadSnapshot);
  document.getElementById('dismiss-install-hint')?.addEventListener('click', () => {
    state.installHintDismissed = true;
    localStorage.setItem('soprano-install-hint-dismissed', '1');
    render();
  });
}

function bindThreadEvents() {
  document.getElementById('back-btn')?.addEventListener('click', closeThread);
  document.getElementById('retry-thread-btn')?.addEventListener('click', () => {
    state.offlineError = null;
    loadThread(state.selectedThreadId, false);
  });
  const composer = document.getElementById('composer-input');
  composer?.addEventListener('input', (e) => {
    state.composerText = e.target.value;
  });
  composer?.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      sendReply();
    }
  });
  document.getElementById('send-reply-btn')?.addEventListener('click', sendReply);
  document.getElementById('stop-thread')?.addEventListener('click', () => threadAction('stop'));
  document.getElementById('cancel-thread')?.addEventListener('click', () => threadAction('cancel'));
  document.getElementById('restart-thread')?.addEventListener('click', () => threadAction('restart'));
  document.querySelectorAll('[data-approve-option]').forEach((btn) => {
    btn.addEventListener('click', () => approveOption(btn.getAttribute('data-approve-option')));
  });
  document.querySelectorAll('[data-pick-answer]').forEach((btn) => {
    btn.addEventListener('click', () => {
      state.inputAnswers[btn.getAttribute('data-pick-answer')] = btn.getAttribute('data-pick-value');
      render();
    });
  });
  document.querySelectorAll('[data-input-question]').forEach((input) => {
    input.addEventListener('input', (e) => {
      state.inputAnswers[input.getAttribute('data-input-question')] = e.target.value;
    });
  });
  document.getElementById('submit-user-input')?.addEventListener('click', () => {
    if (state.threadDetail?.pending_input) submitUserInput(state.threadDetail.pending_input);
  });
  document.getElementById('decline-user-input')?.addEventListener('click', declineUserInput);
  document.querySelectorAll('[data-option-id]').forEach((sel) => {
    sel.addEventListener('change', (e) => changeOption(sel.getAttribute('data-option-id'), e.target.value));
  });
}

async function boot() {
  const pairedFromHash = await attemptHashPairing();
  if (pairedFromHash && !state.authenticated) {
    render();
    return;
  }
  await loadSnapshot();
  if (state.authenticated) {
    connectWebSocket();
  }
  tickTimer = setInterval(() => {
    if (state.authenticated && !state.selectedThreadId && !state.newThreadOpen) {
      const hasWorking = state.snapshot?.threads?.some((t) => t.status === 'running');
      if (hasWorking) render();
    }
  }, 15000);
}

boot();
