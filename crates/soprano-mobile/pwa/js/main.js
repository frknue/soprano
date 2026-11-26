// Entry: pairing, the live connection, the hash router, viewport, theme and service worker.

import { get, onUnauthorized, pair, parsePairCode } from './api.js';
import { h, toast } from './dom.js';
import { compactDuration, relativeTime } from './model.js';
import { noteHashChange, parseHash } from './nav.js';
import { mountInbox } from './screens/inbox.js';
import { mountNewThread } from './screens/new-thread.js';
import { mountPair } from './screens/pair.js';
import { mountThread } from './screens/thread.js';
import { Socket } from './socket.js';
import { applyEvent, closeThread, refreshThread, resetStore, setConnection, setState, store, subscribe } from './store.js';

const app = document.getElementById('app');
let screen = null;
let paired = false;

// Viewport: follow the visual viewport so the composer sits above the keyboard.
function syncViewport() {
  const viewport = window.visualViewport;
  const height = viewport ? viewport.height : window.innerHeight;
  const root = document.documentElement;
  root.style.setProperty('--app-height', `${Math.round(height)}px`);
  root.style.setProperty('--app-top', `${Math.round(viewport?.offsetTop ?? 0)}px`);
  root.classList.toggle('keyboard-open', viewport ? window.innerHeight - viewport.height > 120 : false);
}
window.visualViewport?.addEventListener('resize', syncViewport);
window.visualViewport?.addEventListener('scroll', syncViewport);
window.addEventListener('resize', syncViewport);
syncViewport();

// Theme: the desktop's tokens as CSS variables (/theme.css has them for the first paint), and
// the browser chrome tinted with the background.
let themeSig = null;
function applyTheme(theme) {
  const sig = JSON.stringify(theme ?? null);
  if (!theme?.background || sig === themeSig) return;
  themeSig = sig;
  const style = document.documentElement.style;
  style.setProperty('color-scheme', theme.dark ? 'dark' : 'light');
  for (const [name, value] of Object.entries(theme)) {
    if (typeof value === 'string' && value) style.setProperty(`--${name.replaceAll('_', '-')}`, value);
  }
  syncThemeColor();
}
function syncThemeColor() {
  const value = getComputedStyle(document.documentElement).getPropertyValue('--background').trim();
  if (value) document.querySelector('meta[name="theme-color"]')?.setAttribute('content', value);
}

const socket = new Socket({
  onEvent: applyEvent,
  onStatus: (status) => {
    setConnection(status);
    // Whatever changed while the connection was down is not announced again.
    if (status === 'open') refreshThread();
  },
  // A dropped connection may mean the device was revoked: a 401 here shows the pair screen.
  beforeReconnect: async () => setState(await get('/api/snapshot')),
});

function mount() {
  screen?.destroy();
  window.scrollTo(0, 0);
  const [section, id] = parseHash();
  if (section === 'thread' && id) {
    socket.watch(id);
    screen = mountThread(app, { id });
    return;
  }
  socket.watch(null);
  closeThread();
  screen = section === 'new' ? mountNewThread(app) : mountInbox(app);
}

function showPair(message = null) {
  paired = false;
  socket.stop();
  resetStore();
  screen?.destroy();
  screen = mountPair(app, { message, onPaired: start });
}

/** Paired: load the inbox, open the live connection, show the route. */
async function start() {
  app.replaceChildren(h('div', { class: 'placeholder full', role: 'status' }, h('span', { class: 'spinner' }), h('span', { text: 'Connecting to Soprano…' })));
  try {
    setState(await get('/api/snapshot'));
  } catch (error) {
    // Not paired: the pair screen is up. Not reachable: the cached shell opens anyway and the
    // connection keeps trying.
    if (error.status === 401) return;
  }
  paired = true;
  socket.start();
  if (location.pathname !== '/') history.replaceState(null, '', `/${location.hash}`);
  mount();
}

onUnauthorized(() => {
  if (paired) showPair('This device is no longer paired. Scan a new code in Settings ▸ Mobile.');
  else if (!screen) showPair();
});

subscribe((topic) => {
  if (topic === 'state') applyTheme(store.state?.theme);
  if (topic === 'connection') updateConnectionBanner();
  screen?.update?.(topic);
});

// Connection banner: shown only after a short grace period, so quick reconnects stay invisible.
const banner = h('div', { class: 'connection-banner', role: 'status', hidden: true }, h('span', { class: 'spinner small' }), h('span', { text: 'Reconnecting…' }));
document.body.append(banner);
let bannerTimer = null;
function updateConnectionBanner() {
  clearTimeout(bannerTimer);
  if (store.connection === 'open' || !paired) {
    banner.hidden = true;
    return;
  }
  bannerTimer = setTimeout(() => {
    banner.hidden = store.connection === 'open' || !paired;
  }, 1500);
}

// Live durations and relative times.
setInterval(() => {
  const now = Date.now();
  for (const el of document.querySelectorAll('[data-since]')) el.textContent = compactDuration(now - Number(el.dataset.since));
  for (const el of document.querySelectorAll('[data-rel]')) el.textContent = relativeTime(Number(el.dataset.rel), now);
}, 1000);

document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') socket.kick();
});
window.addEventListener('online', () => socket.kick());
window.addEventListener('hashchange', () => {
  noteHashChange();
  if (paired) mount();
});

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch((error) => console.warn('Service worker registration failed', error));
}

async function boot() {
  syncThemeColor();
  window.addEventListener('load', syncThemeColor);
  const code = parsePairCode(location.hash);
  if (code) {
    // The code is single-use: out of the address bar and the history before anything else.
    history.replaceState(null, '', '/#/');
    app.replaceChildren(h('div', { class: 'placeholder full', role: 'status' }, h('span', { class: 'spinner' }), h('span', { text: 'Pairing with Soprano…' })));
    try {
      await pair(code);
      toast('Paired with Soprano');
    } catch (error) {
      // An already paired device that opened an old link keeps working.
      try {
        await get('/api/snapshot');
      } catch {
        showPair(error.message);
        return;
      }
    }
  }
  await start();
}

boot();
