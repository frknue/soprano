/*
 * shared/frame.js — bootstrap included by every calm-family screen, right after
 * shared/icons.js:
 *
 *   <script src="../shared/icons.js"></script>
 *   <script src="../shared/frame.js"></script>
 *
 * - Mode: ?mode=dark|light wins over <html data-mode>; result is written back to
 *   html[data-mode] before first paint.
 * - Live switch: window.postMessage({ type: 'soprano-design:mode', mode }, '*').
 * - Icons: every [data-icon] element becomes
 *   <svg class="icon icon-<name>" viewBox="0 0 24 24" fill="none" stroke="currentColor"
 *        stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">…</svg>
 *   Unknown names warn in the console and render an empty 24-box.
 * - Inside the comparison shell (index.html) it also announces itself
 *   ('soprano-design:ready'), forwards unmodified key presses
 *   ('soprano-design:key') so the shell's shortcuts keep working after a click
 *   inside the frame, and takes part in the shell's synced scrolling:
 *   posts { type: 'soprano-design:scroll', fraction: 0..1, anchor: { id, offset } | null }
 *   where anchor is the section[id] / header[id] / footer[id] landmark at the top
 *   of the viewport and offset the 0..1 position inside it; follows
 *   'soprano-design:scroll-to' with the same payload, matching the landmark id
 *   when this page has it and falling back to the fraction otherwise. Scrolls
 *   caused by scroll-to are not re-posted.
 *
 * window.SOPRANO_FRAME = { setMode(mode), hydrateIcons(root?) } for screens that
 * build DOM from script.
 */
(function () {
  'use strict';

  var MODES = ['dark', 'light'];
  var SVG_NS = 'http://www.w3.org/2000/svg';
  var root = document.documentElement;
  var embedded = window.parent !== window;

  function setMode(mode) {
    if (MODES.indexOf(mode) === -1) return;
    root.dataset.mode = mode;
    try {
      var url = new URL(location.href);
      if (url.searchParams.get('mode') !== mode) {
        url.searchParams.set('mode', mode);
        history.replaceState(history.state, '', url.href);
      }
    } catch (e) { /* file:// history may refuse; the attribute is what matters */ }
  }

  var initial = new URLSearchParams(location.search).get('mode') || root.dataset.mode;
  if (MODES.indexOf(initial) !== -1) root.dataset.mode = initial;

  function hydrateIcons(scope) {
    var registry = window.SOPRANO_ICONS || {};
    var nodes = (scope || document).querySelectorAll('[data-icon]:not(svg)');
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      var name = el.getAttribute('data-icon');
      var svg = document.createElementNS(SVG_NS, 'svg');
      for (var a = 0; a < el.attributes.length; a++) {
        var attr = el.attributes[a];
        if (attr.name !== 'class') svg.setAttribute(attr.name, attr.value);
      }
      svg.setAttribute('class', ('icon icon-' + name + ' ' + (el.getAttribute('class') || '')).trim());
      svg.setAttribute('viewBox', '0 0 24 24');
      svg.setAttribute('fill', 'none');
      svg.setAttribute('stroke', 'currentColor');
      svg.setAttribute('stroke-linecap', 'round');
      svg.setAttribute('stroke-linejoin', 'round');
      if (!el.hasAttribute('aria-label')) svg.setAttribute('aria-hidden', 'true');
      else svg.setAttribute('role', 'img');
      if (Object.prototype.hasOwnProperty.call(registry, name)) {
        svg.innerHTML = registry[name];
      } else {
        console.warn('[soprano-design] unknown icon "' + name + '"', el);
      }
      el.parentNode.replaceChild(svg, el);
    }
  }

  var scroller = function () { return document.scrollingElement || root; };
  var LANDMARKS = 'section[id], header[id], footer[id]';
  var appliedTop = null;

  // Landmark at the viewport top: the innermost one spanning it, else the last one
  // already passed (in a gap between sections; offset clamps to 1).
  function currentAnchor() {
    var list = document.querySelectorAll(LANDMARKS), spanning = null, passed = null;
    for (var i = 0; i < list.length; i++) {
      var r = list[i].getBoundingClientRect();
      if (r.height <= 0 || r.top > 1) continue;
      passed = { el: list[i], r: r };
      if (r.bottom > 0) spanning = passed;
    }
    var hit = spanning || passed;
    if (!hit) return null;
    return { id: hit.el.id, offset: Math.min(1, -hit.r.top / hit.r.height) };
  }

  function applyScroll(fraction, anchor) {
    var s = scroller();
    var max = Math.max(0, s.scrollHeight - s.clientHeight);
    var top = Math.min(1, Math.max(0, fraction)) * max;
    if (fraction > 0.001 && fraction < 0.999 && anchor && anchor.id) {
      var el = document.getElementById(anchor.id);
      if (el && el.matches(LANDMARKS)) {
        var r = el.getBoundingClientRect();
        top = r.top + s.scrollTop + (Number(anchor.offset) || 0) * r.height;
      }
    }
    top = Math.round(Math.min(max, Math.max(0, top)));
    appliedTop = top;
    s.scrollTop = top;
  }

  window.addEventListener('message', function (event) {
    var data = event.data;
    if (!data) return;
    if (data.type === 'soprano-design:mode') setMode(data.mode);
    else if (data.type === 'soprano-design:scroll-to' && typeof data.fraction === 'number') applyScroll(data.fraction, data.anchor);
  });

  if (embedded) {
    window.addEventListener('keydown', function (event) {
      if (event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return;
      var t = event.target;
      if (t && (t.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
      window.parent.postMessage({ type: 'soprano-design:key', key: event.key, shiftKey: event.shiftKey }, '*');
    });

    var pending = false;
    window.addEventListener('scroll', function () {
      if (pending) return;
      pending = true;
      requestAnimationFrame(function () {
        pending = false;
        var s = scroller();
        if (appliedTop !== null && Math.abs(s.scrollTop - appliedTop) < 2) return;
        appliedTop = null;
        var max = s.scrollHeight - s.clientHeight;
        window.parent.postMessage({ type: 'soprano-design:scroll', fraction: max > 0 ? s.scrollTop / max : 0, anchor: currentAnchor() }, '*');
      });
    }, { passive: true });
  }

  function ready() {
    hydrateIcons(document);
    if (embedded) window.parent.postMessage({ type: 'soprano-design:ready', mode: root.dataset.mode }, '*');
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready);
  else ready();

  window.SOPRANO_FRAME = { setMode: setMode, hydrateIcons: hydrateIcons };
})();
