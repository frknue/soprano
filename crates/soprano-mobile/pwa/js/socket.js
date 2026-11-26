// The live connection to Soprano: a reconnecting WebSocket that carries the inbox, announces
// changed threads, and tells Soprano which thread this phone shows.

/** Soprano pings a quiet connection every 20 s; after this long without anything it is dead. */
const IDLE_TIMEOUT = 45000;
const MIN_DELAY = 1000;
const MAX_DELAY = 15000;

/**
 * Handlers: onEvent(message), onStatus('connecting' | 'open' | 'closed'), and
 * beforeReconnect(): awaited before each new attempt after a drop (a 401 there ends the session,
 * which a failed WebSocket upgrade cannot report).
 */
export class Socket {
  constructor({ onEvent, onStatus, beforeReconnect }) {
    Object.assign(this, { onEvent, onStatus, beforeReconnect });
    this.ws = null;
    this.running = false;
    this.delay = MIN_DELAY;
    this.watched = null;
    this.retryTimer = null;
    this.idleTimer = null;
  }

  start() {
    if (this.running) return;
    this.running = true;
    this.connect();
  }

  stop() {
    this.running = false;
    clearTimeout(this.retryTimer);
    clearTimeout(this.idleTimer);
    this.drop();
    this.onStatus('closed');
  }

  /** The thread on screen (null: none); Soprano announces its changes. */
  watch(threadID) {
    this.watched = threadID;
    this.sendWatch();
  }

  /** Reconnects now when the connection is down or went quiet: the app came back to the foreground. */
  kick() {
    if (!this.running) return;
    if (this.ws?.readyState === WebSocket.OPEN && Date.now() - this.lastActivity < IDLE_TIMEOUT) return;
    clearTimeout(this.retryTimer);
    this.delay = MIN_DELAY;
    this.drop();
    this.connect();
  }

  sendWatch() {
    if (this.ws?.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify({ type: 'watch', thread_id: this.watched }));
    }
  }

  drop() {
    const ws = this.ws;
    this.ws = null;
    if (!ws) return;
    ws.onopen = ws.onmessage = ws.onclose = ws.onerror = null;
    ws.close();
  }

  touch() {
    this.lastActivity = Date.now();
    clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => this.lost(), IDLE_TIMEOUT);
  }

  lost() {
    if (!this.running) return;
    clearTimeout(this.idleTimer);
    this.drop();
    this.onStatus('closed');
    this.retryTimer = setTimeout(async () => {
      this.delay = Math.min(this.delay * 1.7, MAX_DELAY);
      try {
        await this.beforeReconnect?.();
      } catch {
        // Not reachable yet; the attempt below fails the same way and schedules the next.
      }
      if (this.running && !this.ws) this.connect();
    }, this.delay);
  }

  connect() {
    this.onStatus('connecting');
    const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${scheme}//${location.host}/api/ws`);
    this.ws = ws;
    // A connection attempt that hangs counts as lost after the idle timeout too.
    this.touch();
    ws.onopen = () => {
      this.delay = MIN_DELAY;
      this.touch();
      this.onStatus('open');
      this.sendWatch();
    };
    ws.onmessage = (event) => {
      this.touch();
      let message;
      try {
        message = JSON.parse(event.data);
      } catch {
        return;
      }
      this.onEvent(message);
    };
    ws.onclose = () => this.lost();
  }
}
