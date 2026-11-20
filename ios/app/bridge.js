// window.Android for iOS: the same 20-method bridge the panel (main.js) expects from the Android shell.
// The native side writes the readable values into window.__pbNative (before this script runs, and again whenever a
// value changes), because WKWebView message handlers are asynchronous and cannot return a value. Actions are posted to
// the native side, which only accepts them from the panel's main frame.
// This script is loaded by index.html (main frame only); widget iframes have their own window and never get Android.
(function () {
  'use strict';
  window.__phoneboxKey = 'ios'; // main.js passes this as the first argument; the native side does not rely on it
  var N = function () { return window.__pbNative || {}; };
  var post = function (m, a) {
    try { window.webkit.messageHandlers.phonebox.postMessage({ m: m, a: a || [] }); } catch (e) { /* not in the app */ }
  };
  var nextListenId = 0;
  window.Android = {
    // values (written by the native side)
    battery: function () { return JSON.stringify(N().battery || { level: -1, plugged: false, temp: 0, source: '', usb: null }); },
    transport: function () { return N().transport || 'none'; },
    is24Hour: function () { return N().is24Hour !== false; },
    sensors: function () { return JSON.stringify(N().sensors || { light: false, proximity: false }); },
    pcs: function () { return JSON.stringify(N().pcs || []); },
    version: function () { return N().version || ''; },
    canListen: function () { return !!N().canListen; },
    // dictation: the id is made here so the call can return it at once
    listen: function (key, lang, offline) {
      var id = ++nextListenId;
      post('listen', [String(lang || ''), !!offline, id]);
      return id;
    },
    stopListening: function (key, id) { post('stopListening', [id | 0]); },
    cancelListening: function (key, id) { post('cancelListening', [id | 0]); },
    // actions
    haptic: function () { post('haptic'); },
    buzz: function (key, pattern) { post('buzz', [String(pattern || '')]); },
    setBrightness: function (key, v) { post('setBrightness', [+v]); },
    setOrientation: function (key, mode) { post('setOrientation', [String(mode || '')]); },
    trackpad: function (key, type, dx, dy, delta) { post('trackpad', [String(type), +dx || 0, +dy || 0, +delta || 0]); },
    selectPc: function (key, id) { post('selectPc', [String(id)]); },
    forgetPc: function (key, id) { post('forgetPc', [String(id)]); },
    setVolumeKeys: function (key, on) { post('setVolumeKeys', [!!on]); },
    setPinned: function (key, on) { post('setPinned', [!!on]); },
    setHomeScreen: function (key, on) { post('setHomeScreen', [!!on]); }
  };
})();
