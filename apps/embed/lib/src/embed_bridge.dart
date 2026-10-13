import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

/// JS interop surface between the embed Dart app and the hand-written
/// `embed.js` loader. Three concerns live here:
///
///   1. Reading the host `HTMLElement` (tag name + attributes) that
///      `embed.js` stashed on `window` before booting Flutter.
///   2. Publishing the imperative API (`connect` / `disconnect` / `send`
///      / mic controls / `sessionId`) back to JS via
///      `window.__twaiEmbedReady(bridge)`.
///   3. Firing custom DOM events (`connected`, `reply`, `speaking-start`,
///      `speaking-end`, `error`, `disconnected`, `transcript`,
///      `transcript-final`) on the host element so page-level JS can
///      listen with `element.addEventListener`.

/// Snapshot of what `embed.js` passes us about the host: its tag name
/// (`twai-avatar` vs `twai-chat`) and the parsed HTML attributes.
///
/// **Attributes (Transport 0):**
///   avatar-id       (required) — tenant-scoped `avt_...` from POST /admin/avatars
///   mint-proxy-url  (required) — HTTPS URL of the customer's mint proxy
///   idle-url        (recommended) — MP4 loop while the avatar is silent
///   voice-id        (optional) — tenant `vc_...` override; broker profile default otherwise
///
/// **Legacy MSE-era attributes** — `env`, `base-url`, `sink`, `api-key`
/// are ignored on T0. They were the Adapter 1 knobs; the wire moved to
/// LiveKit on 2026-08-22 (ADR-045 / ADR-049) and the mint-proxy pattern
/// replaced client-held publishable keys.
class EmbedConfig {
  EmbedConfig({
    required this.element,
    required this.tagName,
    required this.avatarId,
    required this.voiceId,
    required this.mintProxyUrl,
    required this.idleUrl,
    required this.sttUrl,
  });

  final web.HTMLElement element;
  final String tagName;
  final String? avatarId;
  final String? voiceId;
  final String? mintProxyUrl;
  final String? idleUrl;
  /// Optional server-side STT endpoint (Whisper-shaped). When present,
  /// the transcriber uses HttpSttTranscriber instead of the browser's
  /// SpeechRecognition — same trade-off documented in the sample apps
  /// (Studio moved off browser STT on 2026-09-04).
  final String? sttUrl;

  bool get isChatMode => tagName == 'twai-chat';
}

/// Returns null if `embed.js` hasn't stashed a host element on `window`.
/// In that case the page is likely loading us via `flutter run` directly
/// (dev mode without the custom-element wrapper); callers should fall
/// back to a hardcoded debug config.
EmbedConfig? readEmbedConfig() {
  // `__twaiHostElement` is a property on `window` (set by embed.js), not
  // a function — read via globalContext rather than declaring it as
  // `external` (which would try to *call* it).
  final raw = globalContext['__twaiHostElement'];
  if (raw == null) return null;
  final el = raw as web.HTMLElement;
  return EmbedConfig(
    element: el,
    tagName: el.tagName.toLowerCase(),
    avatarId: _attr(el, 'avatar-id'),
    voiceId: _attr(el, 'voice-id'),
    mintProxyUrl: _attr(el, 'mint-proxy-url'),
    idleUrl: _attr(el, 'idle-url'),
    sttUrl: _attr(el, 'stt-url'),
  );
}

String? _attr(web.HTMLElement el, String name) {
  final v = el.getAttribute(name);
  if (v == null || v.isEmpty) return null;
  return v;
}

/// Imperative API exposed to JS-land. Methods return a `JSPromise<JSAny?>`
/// so JS callers can `await element.connect()` etc.
extension type _Bridge._(JSObject _) implements JSObject {
  external factory _Bridge({
    required JSFunction connect,
    required JSFunction disconnect,
    required JSFunction send,
    required JSFunction startListening,
    required JSFunction stopListening,
    required JSFunction cancelListening,
    required JSFunction voiceInputAvailable,
    required String? sessionId,
  });
}

@JS('window.__twaiEmbedReady')
external void _signalReady(JSObject bridge);

/// Wires the Dart-side callbacks to the JS bridge object. Called once
/// per page lifetime, immediately after the LiveKit engine is
/// constructed (or right after mount if `autoConnect: true`).
///
/// The `sessionId` getter is captured lazily via a closure in the
/// bridge — JS reads `element.sessionId` at any time and gets the
/// current value (or null if not connected).
void publishBridge({
  required Future<void> Function() connect,
  required Future<void> Function() disconnect,
  required Future<void> Function(String text) send,
  required Future<void> Function() startListening,
  required Future<void> Function() stopListening,
  required Future<void> Function() cancelListening,
  required bool Function() voiceInputAvailable,
  required String? Function() sessionId,
}) {
  final bridge = _Bridge(
    connect: (() => connect().toJS).toJS,
    disconnect: (() => disconnect().toJS).toJS,
    send: ((JSString t) => send(t.toDart).toJS).toJS,
    startListening: (() => startListening().toJS).toJS,
    stopListening: (() => stopListening().toJS).toJS,
    cancelListening: (() => cancelListening().toJS).toJS,
    voiceInputAvailable: (() => voiceInputAvailable().toJS).toJS,
    sessionId: sessionId(),
  );
  _signalReady(bridge);
}

/// Fire a `CustomEvent` on the host element. Page-level JS listens via
/// `element.addEventListener('reply', e => console.log(e.detail))`.
void dispatchEvent(web.HTMLElement host, String type, {JSAny? detail}) {
  final init = web.CustomEventInit(detail: detail, bubbles: true);
  host.dispatchEvent(web.CustomEvent(type, init));
}

/// Structured payload for the `error` CustomEvent. Pages branch on
/// `event.detail.kind` to decide whether to retry, rotate the key, or
/// surface the message verbatim.
///
/// **T0 error kinds:**
///   - `mint-rate-limited` — 429 from mint proxy; retry after N seconds
///   - `mint-unavailable` — mint proxy unreachable or non-2xx
///   - `livekit-not-allowed` — avatar's `livekit_profile` not in gateway allowlist
///   - `agent-ended` — server-side warmup or brain failure
///   - `transport-ended` — LiveKit room disconnected unexpectedly
///   - `voice-*` — client-side STT / mic issues (unchanged from MSE era)
///   - `unknown` — fallback
extension type ErrorDetail._(JSObject _) implements JSObject {
  external factory ErrorDetail({
    required String kind,
    required String message,
    required bool permanent,
  });
}
