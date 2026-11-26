// App state fed by the socket and thread fetches; screens subscribe to topics.

import { enc, get } from './api.js';

export const store = {
  /** The inbox snapshot: {host_name, theme, threads, projects, agents}. */
  state: null,
  /** The open thread: its id, conversation (once fetched), revision and requested turn count. */
  threadID: null,
  thread: null,
  threadRev: null,
  threadTurns: null,
  threadError: null,
  /** 'connecting' | 'open' | 'closed' */
  connection: 'connecting',
};

const listeners = new Set();

/** fn(topic): 'state' | 'thread' | 'connection'. Returns an unsubscribe function. */
export function subscribe(fn) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

export function emit(topic) {
  for (const fn of [...listeners]) {
    try {
      fn(topic);
    } catch (error) {
      console.warn('Listener failed', topic, error);
    }
  }
}

/** The freshest summary of a thread: the inbox's, else the fetched conversation's. */
export function summaryFor(id) {
  return store.state?.threads?.find((t) => t.id === id) ?? (store.thread?.summary?.id === id ? store.thread.summary : null);
}

/** A streaming agent changes several times a second; the conversation is fetched this often at most. */
const MIN_FETCH_INTERVAL = 500;

let inflight = null;
let again = false;
let lastFetch = 0;
let loadingTimer = null;

async function fetchThread(id) {
  const wait = lastFetch + MIN_FETCH_INTERVAL - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  if (store.threadID !== id) return;
  lastFetch = Date.now();
  const query = new URLSearchParams();
  if (store.threadRev) query.set('rev', store.threadRev);
  if (store.threadTurns != null) query.set('turns', store.threadTurns);
  const suffix = query.toString() ? `?${query}` : '';
  try {
    const body = await get(`/api/threads/${enc(id)}${suffix}`);
    if (store.threadID !== id) return;
    const hadError = store.threadError != null;
    store.threadError = null;
    if (!body.unchanged) {
      store.thread = body.thread;
      store.threadRev = body.rev;
    }
    if (!body.unchanged || hadError) emit('thread');
    // A transcript still being read is announced when it arrives; ask again in case that
    // announcement was missed.
    clearTimeout(loadingTimer);
    if (store.thread?.loading) loadingTimer = setTimeout(refreshThread, 1500);
  } catch (error) {
    if (store.threadID === id && error?.status !== 401) {
      // A thread that is gone has nothing left to show; any other failure keeps what is on screen.
      if (error?.status === 404) {
        store.thread = null;
        store.threadRev = null;
      }
      store.threadError = error;
      emit('thread');
    }
  }
}

/** Refetches the open thread; overlapping calls coalesce into one follow-up fetch. */
export function refreshThread() {
  const id = store.threadID;
  if (!id) return Promise.resolve();
  if (inflight) {
    again = true;
    return inflight;
  }
  inflight = fetchThread(id).finally(() => {
    inflight = null;
    if (again) {
      again = false;
      refreshThread();
    }
  });
  return inflight;
}

export function openThread(id) {
  if (store.threadID !== id) {
    store.threadID = id;
    store.thread = null;
    store.threadRev = null;
    store.threadTurns = null;
    store.threadError = null;
  }
  return refreshThread();
}

export function closeThread() {
  clearTimeout(loadingTimer);
  store.threadID = null;
  store.thread = null;
  store.threadRev = null;
  store.threadTurns = null;
  store.threadError = null;
}

/** Loads the whole conversation instead of its newest turns. */
export function showAllTurns() {
  store.threadTurns = 0;
  return refreshThread();
}

/** Applies one socket message. */
export function applyEvent(message) {
  switch (message.type) {
    case 'snapshot':
      store.state = message.snapshot;
      emit('state');
      break;
    case 'thread_updated':
      if (message.thread_id === store.threadID) refreshThread();
      break;
    default:
      break;
  }
}

export function setState(snapshot) {
  store.state = snapshot;
  emit('state');
}

export function setConnection(status) {
  if (store.connection === status) return;
  store.connection = status;
  emit('connection');
}

export function resetStore() {
  closeThread();
  store.state = null;
}
