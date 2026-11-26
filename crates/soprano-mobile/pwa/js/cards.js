// Pending approval and question cards shown above the composer.

import { enc, post } from './api.js';
import { h, icon, spinner, toastError } from './dom.js';

/** Approval card with the answers the agent offers; the first allowing one is the primary button. */
export function approvalCard(threadID, approval) {
  const buttons = [];
  const answer = async (option, button) => {
    buttons.forEach((b) => { b.disabled = true; });
    button.append(spinner('Sending'));
    try {
      await post(`/api/threads/${enc(threadID)}/approve`, { option_id: option.id });
    } catch (error) {
      toastError(error, 'Could not answer');
      buttons.forEach((b) => { b.disabled = false; });
      button.querySelector('.spinner')?.remove();
    }
  };
  const primary = approval.options.find((option) => option.kind === 'allow_once') ?? approval.options.find((option) => option.kind.startsWith('allow'));
  for (const option of approval.options) {
    const cls = option === primary ? 'primary' : option.kind.startsWith('allow') ? '' : 'ghost';
    const button = h('button', { type: 'button', class: `button ${cls}`.trim(), text: option.label });
    button.addEventListener('click', () => answer(option, button));
    buttons.push(button);
  }
  return h('section', { class: 'pending-card approval', 'aria-label': approval.title },
    h('div', { class: 'pending-head' }, icon('alert', { size: 18 }), h('h3', { text: approval.title })),
    approval.reason ? h('p', { class: 'pending-reason', text: approval.reason }) : null,
    approval.is_command
      ? h('pre', { class: 'pending-detail mono' }, h('code', { text: approval.detail }))
      : h('p', { class: 'pending-detail', text: approval.detail }),
    h('div', { class: 'pending-actions' }, buttons));
}

/** Answer drafts per set of questions, so a re-render keeps what the person picked. */
const drafts = new Map();

function draftFor(key, request) {
  let draft = drafts.get(key);
  if (!draft) {
    draft = { index: 0, selected: {}, text: {} };
    for (const q of request.questions) {
      draft.selected[q.id] = new Set();
      draft.text[q.id] = '';
    }
    drafts.set(key, draft);
  }
  return draft;
}

/** The answer values for one question, or null when it is not answerable yet. */
function answerFor(question, draft) {
  const selected = [...draft.selected[question.id]];
  const text = question.allows_other || !question.options.length ? draft.text[question.id].trim() : '';
  if (question.allows_multiple) {
    const values = text ? [...selected, text] : selected;
    return values.length ? values : null;
  }
  if (text) return [text];
  return selected.length ? selected : null;
}

/** Question card: one question at a time, Next/Submit, Dismiss. `rerender` redraws the card. */
export function questionCard(threadID, request, rerender) {
  const key = `${threadID}:${JSON.stringify(request.questions.map((q) => [q.id, q.prompt]))}`;
  const draft = draftFor(key, request);
  const questions = request.questions;
  const index = Math.min(draft.index, questions.length - 1);
  const question = questions[index];
  const last = index === questions.length - 1;
  const name = `q-${index}`;
  const typed = question.allows_other || !question.options.length;
  let busy = false;

  const primary = h('button', { type: 'button', class: 'button primary', text: last ? 'Submit' : 'Next' });
  const back = index > 0 ? h('button', { type: 'button', class: 'button ghost', text: 'Back' }) : null;
  const dismiss = h('button', { type: 'button', class: 'button ghost', text: 'Dismiss' });
  const refresh = () => { primary.disabled = busy || answerFor(question, draft) == null; };

  let textField = null;
  const inputs = [];
  const optionRows = question.options.map((option, optionIndex) => {
    const id = `${name}-${optionIndex}`;
    const input = h('input', {
      type: question.allows_multiple ? 'checkbox' : 'radio',
      name,
      id,
      value: option.label,
      checked: draft.selected[question.id].has(option.label),
    });
    inputs.push(input);
    input.addEventListener('change', () => {
      const set = draft.selected[question.id];
      if (question.allows_multiple) {
        if (input.checked) set.add(option.label);
        else set.delete(option.label);
      } else {
        set.clear();
        if (input.checked) set.add(option.label);
        // A picked option replaces typed text for a single-choice question.
        if (textField) {
          textField.value = '';
          draft.text[question.id] = '';
        }
      }
      refresh();
    });
    return h('label', { class: 'option', for: id },
      input,
      h('span', { class: 'option-text' },
        h('span', { class: 'option-label', text: option.label }),
        option.description ? h('span', { class: 'option-description', text: option.description }) : null));
  });

  if (typed) {
    textField = h('textarea', {
      class: 'field other-field',
      rows: 1,
      'aria-label': question.allows_multiple ? 'Other answer' : 'Your answer',
      placeholder: question.options.length ? (question.allows_multiple ? 'Something else…' : 'Or type an answer…') : 'Type your answer…',
      value: draft.text[question.id],
    });
    textField.addEventListener('input', () => {
      draft.text[question.id] = textField.value;
      if (!question.allows_multiple && textField.value.trim()) {
        // Typed text replaces the selection of a single-choice question.
        draft.selected[question.id].clear();
        inputs.forEach((input) => { input.checked = false; });
      }
      refresh();
    });
  }

  const setBusy = (value) => {
    busy = value;
    dismiss.disabled = value;
    if (back) back.disabled = value;
    refresh();
  };

  primary.addEventListener('click', async () => {
    if (answerFor(question, draft) == null) return;
    if (!last) {
      draft.index = index + 1;
      rerender();
      return;
    }
    const answers = {};
    for (const q of questions) answers[q.id] = answerFor(q, draft) ?? [];
    setBusy(true);
    primary.append(spinner('Sending'));
    try {
      await post(`/api/threads/${enc(threadID)}/input`, { answers });
      drafts.delete(key);
    } catch (error) {
      toastError(error, 'Could not send the answers');
      primary.querySelector('.spinner')?.remove();
      setBusy(false);
    }
  });
  back?.addEventListener('click', () => {
    draft.index = index - 1;
    rerender();
  });
  dismiss.addEventListener('click', async () => {
    setBusy(true);
    try {
      await post(`/api/threads/${enc(threadID)}/decline-input`);
      drafts.delete(key);
    } catch (error) {
      toastError(error, 'Could not dismiss');
      setBusy(false);
    }
  });
  refresh();

  const groupLabel = `${name}-label`;
  return h('section', { class: 'pending-card question', 'aria-label': 'Question from the agent' },
    h('div', { class: 'pending-head' },
      icon('question', { size: 18 }),
      question.header ? h('span', { class: 'chip chip-accent', text: question.header }) : h('h3', { text: 'Question' }),
      questions.length > 1 ? h('span', { class: 'meta push', text: `${index + 1}/${questions.length}` }) : null),
    h('p', { class: 'question-text', id: groupLabel, text: question.prompt }),
    optionRows.length ? h('div', { class: 'options', role: question.allows_multiple ? 'group' : 'radiogroup', 'aria-labelledby': groupLabel }, optionRows) : null,
    textField,
    h('div', { class: 'pending-actions row' }, dismiss, h('span', { class: 'spacer' }), back, primary));
}
