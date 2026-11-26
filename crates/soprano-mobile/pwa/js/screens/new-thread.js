// New thread: project, agent, first message.

import { post } from '../api.js';
import { h, spinner } from '../dom.js';
import { go, threadHash } from '../nav.js';
import { store } from '../store.js';
import { loading, topbar } from './common.js';

const LAST_PROJECT_KEY = 'soprano.lastProject';
const LAST_AGENT_KEY = 'soprano.lastAgent';

function field(label, control, hint = null) {
  const id = `f-${Math.random().toString(36).slice(2)}`;
  control.id = id;
  return h('div', { class: 'form-field' }, h('label', { for: id, class: 'form-label', text: label }), control, hint);
}

export function mountNewThread(root) {
  const body = h('main', { class: 'scroll form-scroll' });
  root.replaceChildren(h('div', { class: 'screen new-thread' }, topbar({ title: 'New thread', backTo: '#/' }), body));

  let built = false;

  const build = () => {
    const state = store.state;
    if (!state) {
      body.replaceChildren(loading('Connecting to Soprano…'));
      return;
    }
    built = true;
    const { projects, agents } = state;
    if (!projects.length || !agents.length) {
      body.replaceChildren(h('div', { class: 'placeholder' },
        h('p', { text: projects.length ? 'No agent is set up in Soprano.' : 'Soprano knows no project yet. Open one on the computer, or add a project folder in its Settings.' })));
      return;
    }
    const lastProject = localStorage.getItem(LAST_PROJECT_KEY);
    const lastAgent = localStorage.getItem(LAST_AGENT_KEY);
    const initialProject = projects.find((p) => p.path === lastProject) ?? projects[0];
    const initialAgent = agents.find((a) => a.id === lastAgent) ?? agents[0];

    const project = h('select', { class: 'field' },
      projects.map((p) => h('option', { value: p.path, text: p.name, selected: p === initialProject })));
    const path = h('p', { class: 'form-hint mono' });
    const showPath = () => { path.textContent = projects.find((p) => p.path === project.value)?.display_path ?? ''; };
    project.addEventListener('change', showPath);
    showPath();
    const agent = h('select', { class: 'field' },
      agents.map((a) => h('option', { value: a.id, text: a.name, selected: a === initialAgent })));
    const message = h('textarea', {
      class: 'field message-field',
      rows: 5,
      placeholder: 'What should the agent work on?',
      enterkeyhint: 'enter',
    });
    const error = h('p', { class: 'form-hint error-text', role: 'alert', hidden: true });
    const submit = h('button', { type: 'submit', class: 'button primary wide', text: 'Start thread', disabled: true });
    message.addEventListener('input', () => { submit.disabled = !message.value.trim(); });

    const form = h('form', { class: 'form' },
      field('Project', project, path),
      field('Agent', agent),
      field('Message', message),
      error,
      submit);
    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      const prompt = message.value.trim();
      if (!prompt || submit.disabled) return;
      error.hidden = true;
      submit.disabled = true;
      submit.append(spinner('Starting'));
      try {
        const created = await post('/api/threads', { profile_id: agent.value, cwd: project.value, prompt, options: [] });
        localStorage.setItem(LAST_PROJECT_KEY, project.value);
        localStorage.setItem(LAST_AGENT_KEY, agent.value);
        go(created?.thread_id ? threadHash(created.thread_id) : '#/', { replace: true });
      } catch (failure) {
        error.textContent = failure.message;
        error.hidden = false;
        submit.disabled = false;
        submit.querySelector('.spinner')?.remove();
      }
    });
    body.replaceChildren(h('div', { class: 'lane' }, form));
  };

  build();
  return {
    update(topic) {
      // The form is built once: a later snapshot must not reset what is being typed.
      if (topic === 'state' && !built) build();
    },
    destroy() {},
  };
}
