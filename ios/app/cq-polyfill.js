// Container-query length units (cqw, cqh, cqi, cqb, cqmin, cqmax) for Safari before 16 (iOS 15). sync-www.sh rewrites the
// panel's CSS from "12cqw" to "calc(12 * var(--cq-w, 1vw))"; this script sets --cq-w and friends on every container
// the panel declares (.w, .wc, .radio-carousel), from its content box, and keeps them current.
(function () {
  'use strict';
  if (window.CSS && CSS.supports && CSS.supports('font-size', '1cqw')) return; // a WebView that has them needs nothing
  var SELECTOR = '.w,.wc,.radio-carousel';
  var sizes = new WeakMap();
  function apply(el) {
    var s = sizes.get(el);
    if (!s) return;
    var st = el.style, w = s.w / 100 + 'px', h = s.h / 100 + 'px';
    // an inline-size container (.wc) only has a width: its heights come from the container around it
    st.setProperty('--cq-w', w); st.setProperty('--cq-i', w);
    if (!el.classList.contains('wc')) {
      st.setProperty('--cq-h', h); st.setProperty('--cq-b', h);
      st.setProperty('--cq-min', Math.min(s.w, s.h) / 100 + 'px'); st.setProperty('--cq-max', Math.max(s.w, s.h) / 100 + 'px');
    }
  }
  // a polyfill must never break the panel: failures are shown in the panel's own error box and swallowed
  function guard(fn) { return function () { try { return fn.apply(this, arguments); } catch (e) { if (window.__pbFail) window.__pbFail('cq-polyfill: ' + (e && e.message)); } }; }
  // Variables are set in the next frame, never inside the observer callback: changing layout there makes Safari report a
  // "ResizeObserver loop" error, which the page sees as an uncatchable "Script error."
  var queue = [], scheduled = false;
  var flush = guard(function () {
    scheduled = false;
    var q = queue; queue = [];
    q.forEach(function (e) { sizes.set(e.target, { w: e.contentRect.width, h: e.contentRect.height }); apply(e.target); });
  });
  var ro = new ResizeObserver(guard(function (entries) {
    queue.push.apply(queue, entries);
    if (!scheduled) { scheduled = true; requestAnimationFrame(flush); }
  }));
  // code that rewrites a container's style attribute drops the variables: put them back
  var styleWatch = new MutationObserver(guard(function (list) {
    list.forEach(function (m) { if (!m.target.style.getPropertyValue('--cq-w')) apply(m.target); });
  }));
  function watch(el) {
    if (el.__cq) return;
    el.__cq = true;
    ro.observe(el);
    styleWatch.observe(el, { attributes: true, attributeFilter: ['style'] });
  }
  function scan(root) {
    if (root.matches && root.matches(SELECTOR)) watch(root);
    if (root.querySelectorAll) Array.prototype.forEach.call(root.querySelectorAll(SELECTOR), watch);
  }
  new MutationObserver(guard(function (list) {
    list.forEach(function (m) { Array.prototype.forEach.call(m.addedNodes, function (n) { if (n.nodeType === 1) scan(n); }); });
  })).observe(document.documentElement, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', guard(function () { scan(document); }));
})();
