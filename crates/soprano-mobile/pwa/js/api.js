// HTTP API client: JSON requests under the pairing cookie, and pairing itself.

let unauthorizedHandler = () => {};

/** Called whenever a request is answered 401: the device is not paired (any more). */
export function onUnauthorized(handler) {
  unauthorizedHandler = handler;
}

export class ApiError extends Error {
  constructor(message, status) {
    super(message);
    this.status = status;
  }
}

export const enc = encodeURIComponent;

const UNREACHABLE = 'Soprano is not reachable. Check that the computer is awake and Tailscale is connected.';

/** What went wrong, in the server's words when it sent any. */
async function errorMessage(response) {
  let text = '';
  try {
    text = await response.text();
    const body = JSON.parse(text);
    if (body?.error) return body.error;
  } catch {
    // Not JSON: a proxy's or the framework's plain-text answer.
  }
  const plain = text.trim();
  if (plain && plain.length < 200 && !plain.startsWith('<')) return plain;
  if (response.status === 502 || response.status === 503) return UNREACHABLE;
  return `The request failed (${response.status}).`;
}

/** JSON request; resolves to the parsed body, throws ApiError. */
export async function api(path, { method = 'GET', body } = {}) {
  let response;
  try {
    response = await fetch(path, {
      method,
      credentials: 'same-origin',
      cache: 'no-store',
      headers: body === undefined ? { Accept: 'application/json' } : { Accept: 'application/json', 'Content-Type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError(UNREACHABLE, 0);
  }
  if (response.status === 401) {
    unauthorizedHandler();
    throw new ApiError('This device is not paired.', 401);
  }
  if (!response.ok) throw new ApiError(await errorMessage(response), response.status);
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

export const get = (path) => api(path);
export const post = (path, body = {}) => api(path, { method: 'POST', body });

/** The pairing code in a pairing link (`…/pair#t=<code>`), or a bare code; null when none. */
export function parsePairCode(input) {
  const text = String(input ?? '').trim();
  const match = text.match(/[#&?]t=([A-Za-z0-9_\-%=]+)/);
  if (match) return decodeURIComponent(match[1]);
  return /^[A-Za-z0-9_-]{16,}={0,2}$/.test(text) ? text : null;
}

/** A readable name for this device, shown in Settings ▸ Mobile on the computer. */
export function deviceName() {
  const ua = navigator.userAgent;
  const device = /iPhone/.test(ua) ? 'iPhone'
    : /iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ? 'iPad'
      : /Android/.test(ua) ? 'Android'
        : /Macintosh/.test(ua) ? 'Mac'
          : /Windows/.test(ua) ? 'Windows PC'
            : /Linux/.test(ua) ? 'Linux'
              : 'Browser';
  const browser = /CriOS|Chrome\//.test(ua) && !/Edg/.test(ua) ? 'Chrome'
    : /FxiOS|Firefox\//.test(ua) ? 'Firefox'
      : /Edg/.test(ua) ? 'Edge'
        : /Safari\//.test(ua) ? 'Safari'
          : null;
  if (isStandalone()) return `${device} (home screen app)`;
  return browser ? `${device} (${browser})` : device;
}

export function isStandalone() {
  return navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
}

/** Redeems a pairing code; the server answers with this device's session cookie. */
export async function pair(code) {
  let response;
  try {
    response = await fetch('/api/pair', {
      method: 'POST',
      credentials: 'same-origin',
      cache: 'no-store',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ token: code, device_name: deviceName() }),
    });
  } catch {
    throw new ApiError(UNREACHABLE, 0);
  }
  if (!response.ok) throw new ApiError(await errorMessage(response), response.status);
}
