// Pieces shared by screens: top bar, status pill, connection dot, placeholders.

import { h, icon, iconButton } from '../dom.js';
import { compactDuration, pillFor } from '../model.js';
import { back } from '../nav.js';
import { store } from '../store.js';

/** Screen top bar. `backTo`: the parent screen's hash for the back button. */
export function topbar({ title, subtitle = null, backTo = null, actions = [] }) {
  return h('header', { class: 'topbar' },
    h('div', { class: 'topbar-row' },
      backTo != null ? iconButton('back', 'Back', () => back(backTo), 'back-button') : null,
      h('div', { class: 'topbar-title' },
        h('h1', { text: title }),
        subtitle ? h('div', { class: 'topbar-subtitle' }, subtitle) : null),
      h('div', { class: 'topbar-actions' }, actions)));
}

export function connectionDot() {
  const dot = h('span', { class: 'conn-dot', role: 'img' });
  updateConnectionDot(dot);
  return dot;
}

export function updateConnectionDot(dot) {
  const status = store.connection;
  dot.dataset.status = status;
  const label = status === 'open' ? 'Connected' : status === 'connecting' ? 'Connecting' : 'Disconnected';
  dot.setAttribute('aria-label', label);
  dot.title = label;
}

/** Status pill for a thread summary; null for an idle agent (callers show a relative time). */
export function statusPill(summary) {
  const spec = pillFor(summary);
  if (!spec) return null;
  const pill = h('span', { class: `pill pill-${spec.tone}` });
  if (spec.tone === 'working') pill.append(icon('circleDashed', { size: 13, cls: 'spin' }));
  pill.append(h('span', { text: spec.label }));
  if (spec.since) {
    pill.append(h('span', { class: 'pill-time', dataset: { since: spec.since }, text: compactDuration(Date.now() - spec.since) }));
  }
  return pill;
}

export function loading(label = 'Loading…') {
  return h('div', { class: 'placeholder', role: 'status' }, h('span', { class: 'spinner' }), h('span', { text: label }));
}

export function failure(message, retry) {
  return h('div', { class: 'placeholder' },
    icon('alert', { size: 22 }),
    h('p', { text: message }),
    retry ? h('button', { type: 'button', class: 'button', onclick: retry }, 'Try again') : null);
}
