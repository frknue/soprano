// Thread: header with menu, timeline, pending approval/question cards, composer.

import { enc, post } from '../api.js';
import { approvalCard, questionCard } from '../cards.js';
import { actionSheet, copyText, h, icon, iconButton, toastError } from '../dom.js';
import { activeTurn } from '../model.js';
import { openThread, refreshThread, showAllTurns, store, summaryFor } from '../store.js';
import { renderTimeline } from '../timeline.js';
import { failure, loading, statusPill, topbar } from './common.js';

const DRAFT_PREFIX = 'soprano.draft.';

/** `onSent`: called after a message went out. */
function composer(threadID, onSent) {
  const field = h('textarea', {
    class: 'composer-field',
    rows: 1,
    'aria-label': 'Message',
    enterkeyhint: 'send',
    value: sessionStorage.getItem(DRAFT_PREFIX + threadID) ?? '',
  });
  const send = h('button', { type: 'button', class: 'composer-send', 'aria-label': 'Send' }, icon('send', { size: 20 }));
  const stop = h('button', { type: 'button', class: 'composer-stop', 'aria-label': 'Stop' }, icon('stop', { size: 18 }));
  const options = h('div', { class: 'composer-options' });
  const root = h('form', { class: 'composer', 'aria-label': 'Composer' },
    field,
    h('div', { class: 'composer-bar' }, options, h('span', { class: 'spacer' }), stop, send));

  let enabled = false;
  let stoppable = false;
  let stopping = false;
  let sending = false;
  let optionsSig = null;

  const grow = () => {
    field.style.height = 'auto';
    const line = parseFloat(getComputedStyle(field).lineHeight) || 22;
    field.style.height = `${Math.min(field.scrollHeight, line * 6 + 16)}px`;
  };
  const sync = () => {
    const hasText = field.value.trim().length > 0;
    field.disabled = !enabled;
    field.placeholder = enabled ? 'Message' : 'This agent takes no message right now';
    send.disabled = !enabled || !hasText || sending;
    send.hidden = stoppable && !hasText;
    stop.hidden = !stoppable;
    stop.disabled = stopping;
    stop.setAttribute('aria-label', stopping ? 'Stopping' : 'Stop');
  };

  const submit = async () => {
    const text = field.value.trim();
    if (!text || sending || !enabled) return;
    sending = true;
    sync();
    try {
      await post(`/api/threads/${enc(threadID)}/reply`, { text });
      field.value = '';
      sessionStorage.removeItem(DRAFT_PREFIX + threadID);
      grow();
      onSent();
    } catch (error) {
      toastError(error, 'Could not send');
    } finally {
      sending = false;
      sync();
    }
  };

  field.addEventListener('input', () => {
    sessionStorage.setItem(DRAFT_PREFIX + threadID, field.value);
    grow();
    sync();
  });
  field.addEventListener('keydown', (event) => {
    // Hardware keyboards: ⌘↩ / Ctrl↩ sends; plain Return makes a new line like the iOS keyboard.
    if (event.key === 'Enter' && (event.metaKey || event.ctrlKey)) {
      event.preventDefault();
      submit();
    }
  });
  root.addEventListener('submit', (event) => {
    event.preventDefault();
    submit();
  });
  send.addEventListener('click', submit);
  stop.addEventListener('click', async () => {
    stopping = true;
    sync();
    try {
      await post(`/api/threads/${enc(threadID)}/cancel`);
    } catch (error) {
      stopping = false;
      sync();
      toastError(error, 'Could not stop');
    }
  });

  const pickOption = (option) => {
    actionSheet(option.name, option.values.map((value) => ({
      label: value.name,
      checked: value.value === option.current_value,
      onSelect: () => post(`/api/threads/${enc(threadID)}/option`, { id: option.id, value: value.value })
        .catch((error) => toastError(error, option.name)),
    })));
  };

  requestAnimationFrame(grow);
  sync();
  return {
    el: root,
    /** `summary`: the thread's; `thread`: its conversation once loaded. */
    update(summary, thread) {
      enabled = Boolean(summary?.accepts_replies);
      const turn = activeTurn(thread);
      // Only a chat's turn can be interrupted; a terminal agent's Stop ends its tab (the menu's).
      stoppable = Boolean(summary?.is_chat && turn);
      stopping = Boolean(turn?.stopping);
      const sig = JSON.stringify(thread?.options ?? []);
      if (sig !== optionsSig) {
        optionsSig = sig;
        options.replaceChildren(...(thread?.options ?? []).map((option) => {
          const current = option.values.find((value) => value.value === option.current_value);
          return h('button', { type: 'button', class: 'option-chip', 'aria-label': option.name, onclick: () => pickOption(option) },
            h('span', { text: current?.name ?? option.name }), icon('chevronDown', { size: 12 }));
        }));
      }
      sync();
    },
  };
}

export function mountThread(root, { id }) {
  const timeline = h('div', { class: 'timeline' });
  const scroller = h('main', { class: 'scroll thread-scroll' }, h('div', { class: 'lane' }, timeline));
  const pending = h('div', { class: 'pending' });
  // A sent message is followed to where it shows up.
  const compose = composer(id, () => {
    atBottom = true;
    scroller.scrollTop = scroller.scrollHeight;
  });
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const toBottom = h('button', {
    type: 'button',
    class: 'scroll-bottom',
    'aria-label': 'Scroll to the latest message',
    hidden: true,
    onclick: () => scroller.scrollTo({ top: scroller.scrollHeight, behavior: reduceMotion.matches ? 'auto' : 'smooth' }),
  }, icon('arrowDown', { size: 20 }));
  const dock = h('div', { class: 'dock' }, toBottom, pending, compose.el);
  const headerHost = h('div');
  root.replaceChildren(h('div', { class: 'screen thread' }, headerHost, scroller, dock));

  let atBottom = true;
  let firstRender = true;
  let pendingKey = null;
  let headerSig = null;
  let earlierTurns = 0;

  // Follows the newest message while it is in view; otherwise a button leads back to it.
  scroller.addEventListener('scroll', () => {
    atBottom = scroller.scrollHeight - scroller.scrollTop - scroller.clientHeight < 48;
    toBottom.hidden = atBottom;
  }, { passive: true });
  const keepBottom = () => {
    if (atBottom) scroller.scrollTop = scroller.scrollHeight;
    else toBottom.hidden = false;
  };
  const resizeObserver = new ResizeObserver(keepBottom);
  resizeObserver.observe(scroller);
  resizeObserver.observe(timeline);

  timeline.addEventListener('click', (event) => {
    const copy = event.target.closest('.code-copy');
    if (copy) copyText(copy.closest('.code-block').querySelector('code').textContent);
  });

  const act = (action, failed) => post(`/api/threads/${enc(id)}/${action}`).catch((error) => toastError(error, failed));

  const runMenu = () => {
    const summary = summaryFor(id);
    actionSheet(summary?.title ?? 'Thread', [
      { label: 'Restart agent', icon: 'refresh', disabled: !summary?.can_restart, onSelect: () => act('restart', 'Could not restart') },
      { label: 'Stop agent', icon: 'stop', destructive: true, disabled: !summary?.can_stop, onSelect: () => act('stop', 'Could not stop') },
    ]);
  };

  const renderHeader = () => {
    const summary = summaryFor(id);
    const sig = JSON.stringify(summary ?? null);
    if (sig === headerSig) return;
    headerSig = sig;
    headerHost.replaceChildren(topbar({
      title: summary?.title ?? 'Thread',
      subtitle: summary ? [
        h('span', { class: 'subtitle-item', text: summary.project }),
        h('span', { class: 'model-chip', text: summary.profile_name }),
        statusPill(summary),
      ] : null,
      backTo: '#/',
      actions: summary?.can_stop || summary?.can_restart ? [iconButton('more', 'Thread actions', runMenu)] : [],
    }));
  };

  const renderPending = (thread) => {
    const key = JSON.stringify([thread.pending_approval ?? null, thread.pending_input ?? null]);
    if (key === pendingKey) return;
    pendingKey = key;
    const cards = [];
    if (thread.pending_approval) cards.push(approvalCard(id, thread.pending_approval));
    if (thread.pending_input) {
      const holder = h('div');
      const draw = () => holder.replaceChildren(questionCard(id, thread.pending_input, draw));
      draw();
      cards.push(holder);
    }
    pending.replaceChildren(...cards);
  };

  const render = () => {
    renderHeader();
    const thread = store.threadID === id ? store.thread : null;
    compose.update(summaryFor(id), thread);
    if (!thread) {
      // Cards of a conversation that is gone must not stay.
      pending.replaceChildren();
      pendingKey = null;
      if (store.threadError) {
        timeline.replaceChildren(failure(store.threadError.status === 404 ? 'This thread is no longer open in Soprano.' : store.threadError.message, () => {
          timeline.replaceChildren(loading());
          refreshThread();
        }));
      } else if (!timeline.querySelector(':scope > [role="status"]')) {
        timeline.replaceChildren(loading());
      }
      return;
    }
    // The loading and failure placeholders are not the timeline's rows.
    for (const el of [...timeline.children]) {
      if (el._key === undefined) el.remove();
    }
    const wasAtBottom = atBottom;
    const fromBottom = scroller.scrollHeight - scroller.scrollTop;
    renderTimeline(timeline, thread, { showAll: showAllTurns });
    renderPending(thread);
    // Earlier turns arrive above the ones on screen, which stay where they are.
    if (thread.earlier_turns < earlierTurns && !wasAtBottom) scroller.scrollTop = scroller.scrollHeight - fromBottom;
    earlierTurns = thread.earlier_turns;
    if (firstRender || wasAtBottom) {
      scroller.scrollTop = scroller.scrollHeight;
      atBottom = true;
    }
    toBottom.hidden = atBottom;
    firstRender = false;
  };

  openThread(id);
  render();

  return {
    update(topic) {
      if (topic === 'thread' || topic === 'state') render();
    },
    destroy() {
      resizeObserver.disconnect();
    },
  };
}
