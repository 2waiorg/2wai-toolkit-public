// 2wai Avatar Web Component loader.
//
// Customer integration is two lines:
//
//   <script src="https://cdn.2wai.ai/embed/embed.js" defer></script>
//   <twai-avatar avatar-id="RedJesusTalk1" voice-id="9c32..." env="2wai-staging"></twai-avatar>
//
// What this file does:
//   1. Defines <twai-avatar> (video only) and <twai-chat> (video + chat UI)
//      as HTML custom elements.
//   2. On the first connectedCallback of either, dynamically loads Flutter's
//      engine loader (flutter.js) and tells Flutter to render into that
//      specific element via the hostElement config option.
//   3. Once Dart boots, it calls window.__twaiEmbedReady(bridge) with an
//      object exposing connect()/disconnect()/send(text). This file proxies
//      the element's methods through that bridge.
//
// V1 constraints:
//   - One <twai-avatar> OR one <twai-chat> per page. Flutter Web's engine is
//     single-instance; multi-mount is a known follow-on.
//   - No Shadow DOM yet. Host page styles can leak in.
(function () {
  'use strict';

  // The path to this file's directory — used to resolve flutter.js relative
  // to embed.js. Falls back to /embed/ if currentScript is unavailable
  // (e.g. when embed.js is imported as a module).
  const SCRIPT_BASE = (function () {
    const s = document.currentScript;
    if (s && s.src) {
      return s.src.substring(0, s.src.lastIndexOf('/') + 1);
    }
    return '/embed/';
  })();

  let mounted = false;
  let bridge = null;
  let mountedHost = null;
  const bridgeWaiters = [];

  // Chrome's autoplay-with-sound policy blocks playback on a fresh page
  // load until the user has interacted with the document. The Dart-
  // side <video> element starts muted (so video does play immediately);
  // we unmute on the first real user gesture. Capture-phase listeners
  // on the document catch the gesture before any host-page handlers
  // could swallow it.
  let audioUnlocked = false;
  function unlockAudio() {
    if (audioUnlocked) return;
    if (!mountedHost) return;
    const videos = mountedHost.querySelectorAll('video');
    if (videos.length === 0) return;
    audioUnlocked = true;
    videos.forEach((v) => {
      v.muted = false;
      v.volume = 1.0;
      // Re-issue play() inside the gesture so the browser re-evaluates
      // autoplay permission with audio enabled.
      const p = v.play();
      if (p && p.catch) p.catch(() => {});
    });
    document.removeEventListener('click', unlockAudio, true);
    document.removeEventListener('keydown', unlockAudio, true);
    document.removeEventListener('touchstart', unlockAudio, true);
  }
  document.addEventListener('click', unlockAudio, true);
  document.addEventListener('keydown', unlockAudio, true);
  document.addEventListener('touchstart', unlockAudio, true);

  // Dart calls this once it boots, passing a bridge object with the
  // imperative API (connect/disconnect/send) and an event dispatcher.
  window.__twaiEmbedReady = function (b) {
    bridge = b;
    bridgeWaiters.splice(0).forEach((resolve) => resolve(b));
  };

  function whenBridgeReady() {
    if (bridge) return Promise.resolve(bridge);
    return new Promise((resolve) => bridgeWaiters.push(resolve));
  }

  function loadFlutterInto(hostElement) {
    if (mounted) {
      console.warn(
        '[twai] only one <twai-avatar> or <twai-chat> per page in v1 — ' +
          'ignoring extra element'
      );
      hostElement.innerHTML =
        '<div style="color:#888;padding:1em;font:14px monospace">' +
        '[twai] only one embed per page in v1</div>';
      return;
    }
    mounted = true;
    mountedHost = hostElement;

    // Hand the host element to Dart via a global. Dart reads
    // window.__twaiHostElement after engine init and uses its tag name +
    // attributes to drive the widget tree.
    window.__twaiHostElement = hostElement;

    function startLoad() {
      _flutter.loader.load({
        config: { hostElement: hostElement },
        onEntrypointLoaded: async (engineInitializer) => {
          const appRunner = await engineInitializer.initializeEngine({
            hostElement: hostElement,
          });
          await appRunner.runApp();
        },
      });
    }

    // flutter_bootstrap.js is our customized template — it sets up
    // _flutter.loader + _flutter.buildConfig but does NOT auto-call
    // load(). It signals readiness via window.__twaiFlutterReady. We
    // bridge whichever side gets there first.
    if (window.__twaiFlutterReady) {
      startLoad();
    } else {
      window.__twaiOnFlutterReady = startLoad;
      const script = document.createElement('script');
      script.src = SCRIPT_BASE + 'flutter_bootstrap.js';
      document.head.appendChild(script);
    }
  }

  // Shared base: same JS API on both elements; the tag name disambiguates
  // which widget Dart should mount.
  function defineTwaiElement(tagName) {
    class TwaiElement extends HTMLElement {
      connectedCallback() {
        loadFlutterInto(this);
      }

      async connect() {
        return (await whenBridgeReady()).connect();
      }

      async disconnect() {
        return (await whenBridgeReady()).disconnect();
      }

      async send(text) {
        return (await whenBridgeReady()).send(text);
      }

      // Push-to-talk voice input. Typical wiring:
      //   btn.addEventListener('pointerdown', () => el.startListening());
      //   btn.addEventListener('pointerup',   () => el.stopListening());
      // Listen for 'transcript' (interim) and 'transcript-final'
      // (committed text) events to update UI / pre-fill an input.
      async startListening() {
        return (await whenBridgeReady()).startListening();
      }

      async stopListening() {
        return (await whenBridgeReady()).stopListening();
      }

      async cancelListening() {
        return (await whenBridgeReady()).cancelListening();
      }

      // Sync read of whether the recognizer initialized successfully.
      // Returns false on platforms / browsers without STT support
      // (Windows / Linux native, Firefox web). Use this to hide a
      // mic button on unsupported targets.
      voiceInputAvailable() {
        return bridge ? bridge.voiceInputAvailable() : false;
      }

      get sessionId() {
        return bridge ? bridge.sessionId : null;
      }
    }
    customElements.define(tagName, TwaiElement);
  }

  defineTwaiElement('twai-avatar');
  defineTwaiElement('twai-chat');
})();
