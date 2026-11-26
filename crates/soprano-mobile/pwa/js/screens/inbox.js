// Inbox: the agents in the desktop's sections, a filter, and a floating New thread button.

import { isStandalone } from '../api.js';
import { h, icon, iconButton, reconcile } from '../dom.js';
import { relativeTime } from '../model.js';
import { go, threadHash } from '../nav.js';
import { store } from '../store.js';
import { connectionDot, loading, statusPill, updateConnectionDot } from './common.js';

const SECTIONS = [
  ['needs_you', 'Needs you'],
  ['working', 'Working'],
  ['ready', 'Ready'],
  ['stopped', 'Stopped'],
];

const COLLAPSED_KEY = 'soprano.collapsedSections';
const INSTALL_HINT_KEY = 'soprano.installHintDismissed';

function collapsedSections() {
  try {
    const stored = JSON.parse(localStorage.getItem(COLLAPSED_KEY));
    if (Array.isArray(stored)) return new Set(stored);
  } catch {
    // Default below.
  }
  return new Set(['stopped']);
}

function row(summary) {
  const pill = statusPill(summary);
  const meta = [h('span', { class: 'meta-item' }, icon('folder', { size: 13 }), h('span', { text: summary.project }))];
  if (summary.branch) meta.push(h('span', { class: 'meta-item' }, icon('branch', { size: 13 }), h('span', { text: summary.branch })));
  meta.push(h('span', { class: 'meta-item' }, icon('agent', { size: 13 }), h('span', { text: summary.profile_name })));
  return h('a', { class: 'thread-row', href: threadHash(summary.id) },
    h('div', { class: 'thread-row-top' },
      h('span', { class: 'thread-title', text: summary.title || 'New thread' }),
      pill ?? h('span', { class: 'rel-time', dataset: { rel: summary.since_ms }, text: relativeTime(summary.since_ms) })),
    h('div', { class: 'thread-meta' }, meta));
}

function matches(summary, query) {
  return [summary.title, summary.project, summary.profile_name, summary.branch]
    .some((text) => text && text.toLowerCase().includes(query));
}

export function mountInbox(root) {
  const collapsed = collapsedSections();
  let query = '';
  const dot = connectionDot();
  const host = h('div', { class: 'topbar-subtitle' });
  const list = h('div', { class: 'inbox-list' });
  const search = h('input', {
    type: 'search',
    class: 'field search-field',
    placeholder: 'Filter agents, projects, branches',
    'aria-label': 'Filter agents',
    autocomplete: 'off',
    autocapitalize: 'none',
    spellcheck: 'false',
    enterkeyhint: 'search',
  });
  const hint = h('div', { class: 'install-hint', hidden: true },
    icon('share', { size: 18 }),
    h('span', { text: 'For a full-screen app, tap Share, then “Add to Home Screen”.' }),
    iconButton('x', 'Dismiss', () => {
      localStorage.setItem(INSTALL_HINT_KEY, '1');
      hint.hidden = true;
    }));
  hint.hidden = isStandalone() || localStorage.getItem(INSTALL_HINT_KEY) === '1' || !/iPhone|iPad/.test(navigator.userAgent);
  const header = h('header', { class: 'topbar large' },
    h('div', { class: 'topbar-row' },
      h('div', { class: 'topbar-title' }, h('h1', null, 'Agents', dot), host)));
  const main = h('main', { class: 'scroll inbox-scroll' }, hint, h('div', { class: 'search-wrap' }, search), list);
  const fab = h('button', { type: 'button', class: 'fab', onclick: () => go('#/new') }, icon('compose', { size: 20 }), h('span', { text: 'New thread' }));
  root.replaceChildren(h('div', { class: 'screen inbox' }, header, main, fab));

  const render = () => {
    const state = store.state;
    host.textContent = state?.host_name ?? '';
    if (!state) {
      list.replaceChildren(loading('Connecting to Soprano…'));
      return;
    }
    list.querySelector(':scope > [role="status"]')?.remove();
    const threads = query ? state.threads.filter((t) => matches(t, query)) : state.threads;
    const entries = [];
    for (const [id, title] of SECTIONS) {
      const members = threads.filter((t) => t.section === id);
      if (!members.length) continue;
      // A filter shows its hits wherever they are.
      const isCollapsed = !query && collapsed.has(id);
      entries.push({
        key: id,
        sig: JSON.stringify([isCollapsed, members]),
        build: () => {
          const bodyID = `section-${id}`;
          const toggle = h('button', {
            type: 'button',
            class: 'section-head',
            'aria-expanded': String(!isCollapsed),
            'aria-controls': bodyID,
            onclick: () => {
              if (collapsed.has(id)) collapsed.delete(id);
              else collapsed.add(id);
              localStorage.setItem(COLLAPSED_KEY, JSON.stringify([...collapsed]));
              render();
            },
          }, h('span', { class: 'section-title', text: title }), h('span', { class: 'section-count', text: String(members.length) }),
          icon('chevronDown', { size: 14, cls: `section-chevron${isCollapsed ? ' collapsed' : ''}` }));
          return h('section', { class: 'inbox-section', 'aria-label': title },
            toggle,
            isCollapsed ? null : h('div', { class: 'section-body', id: bodyID }, members.map(row)));
        },
      });
    }
    if (!entries.length) {
      entries.push({
        key: 'empty',
        sig: query ? 'no-match' : 'empty',
        build: () => (query
          ? h('div', { class: 'placeholder' }, icon('search', { size: 24 }), h('p', { text: 'No agent matches the filter.' }))
          : h('div', { class: 'placeholder' },
            icon('compose', { size: 24 }),
            h('p', { text: 'No agents are open in Soprano.' }),
            h('button', { type: 'button', class: 'button primary', onclick: () => go('#/new') }, 'Start a thread'))),
      });
    }
    reconcile(list, entries);
  };

  search.addEventListener('input', () => {
    query = search.value.trim().toLowerCase();
    render();
  });

  render();
  return {
    update(topic) {
      if (topic === 'state') render();
      if (topic === 'connection') updateConnectionDot(dot);
    },
    destroy() {},
  };
}
