// ../../../twai-web-sdk/packages/core/dist/constants.js
var MSE_CODECS = 'video/mp4; codecs="avc1.42C01F, mp4a.40.2"';
var MSE_STREAM_PATH = "/ext-api/mse_stream";
var HUMAN_PATH = "/ext-api/human";
var HEALTH_PATH = "/ext-api/health";
var OFFER_PATH = "/ext-api/offer";
var HANDSHAKE_TIMEOUT_MS = 15e3;
var NO_RECONNECT_CLOSE_CODES = [1002, 1011];

// ../../../twai-web-sdk/packages/core/dist/errors.js
var TwaiError = class extends Error {
  kind;
  cause;
  constructor(kind, message, cause) {
    super(message);
    this.name = "TwaiError";
    this.kind = kind;
    this.cause = cause;
  }
};
var TwaiCodecError = class extends TwaiError {
  constructor(message, cause) {
    super("codec", message, cause);
    this.name = "TwaiCodecError";
  }
};
var TwaiConnectError = class extends TwaiError {
  constructor(message, cause) {
    super("connect", message, cause);
    this.name = "TwaiConnectError";
  }
};
var TwaiTransportError = class extends TwaiError {
  constructor(message, cause) {
    super("transport", message, cause);
    this.name = "TwaiTransportError";
  }
};
var TwaiChatError = class extends TwaiError {
  status;
  constructor(message, status, cause) {
    super("chat", message, cause);
    this.name = "TwaiChatError";
    this.status = status;
  }
};
var TwaiUnauthorizedError = class extends TwaiError {
  constructor(message, cause) {
    super("unauthorized", message, cause);
    this.name = "TwaiUnauthorizedError";
  }
};

// ../../../twai-web-sdk/packages/core/dist/environment.js
function suffixOf(path) {
  const i = path.indexOf("/", 1);
  return i >= 0 ? path.slice(i) : path;
}
var TwaiEnvironment = class {
  origin;
  basePath;
  constructor(opts = {}) {
    const origin = opts.origin ?? (typeof window !== "undefined" ? window.location.origin : void 0);
    if (!origin) {
      throw new Error("TwaiEnvironment requires an explicit origin outside the browser");
    }
    this.origin = origin.replace(/\/+$/, "");
    this.basePath = (opts.basePath ?? "/ext-api").replace(/\/+$/, "");
  }
  /** wss://host/<basePath>/mse_stream */
  mseWebSocketUrl() {
    const wsOrigin = this.origin.replace(/^http/, "ws");
    return `${wsOrigin}${this.basePath}${suffixOf(MSE_STREAM_PATH)}`;
  }
  humanUrl() {
    return `${this.origin}${this.basePath}${suffixOf(HUMAN_PATH)}`;
  }
  healthUrl() {
    return `${this.origin}${this.basePath}${suffixOf(HEALTH_PATH)}`;
  }
  offerUrl() {
    return `${this.origin}${this.basePath}${suffixOf(OFFER_PATH)}`;
  }
};

// ../../../twai-web-sdk/packages/core/dist/credentials.js
var AnonymousCredentials = class {
  headers() {
    return {};
  }
};
var PublicKeyCredentials = class {
  pk;
  constructor(pk) {
    this.pk = pk;
  }
  headers() {
    return this.pk ? { "X-Twai-Key": this.pk } : {};
  }
};
var ViewTokenCredentials = class {
  token;
  constructor(token) {
    this.token = token;
  }
  /** Rotate the token in place (tokens are short-lived; refresh without a new session). */
  setToken(token) {
    this.token = token;
  }
  headers() {
    return this.token ? { "X-View-Token": this.token } : {};
  }
};
function resolveCredentials(p) {
  if (!p)
    return new AnonymousCredentials();
  return typeof p === "function" ? p() : p;
}

// ../../../twai-web-sdk/packages/core/dist/speakingGate.js
var SpeakingGate = class {
  onFire;
  queue = [];
  seq = 0;
  constructor(onFire) {
    this.onFire = onFire;
  }
  enqueue(ev) {
    if (ev.value !== "start" && ev.value !== "stop")
      return;
    const pts = typeof ev.pts === "number" ? ev.pts : -Infinity;
    this.queue.push({ value: ev.value, pts, seq: this.seq++ });
  }
  /** Fire any queued transitions whose pts the playhead has reached, in order. */
  tick(currentTime) {
    while (this.queue.length > 0 && this.queue[0].pts <= currentTime) {
      const ev = this.queue.shift();
      try {
        this.onFire(ev.value);
      } catch (e) {
        console.error("[twai] speaking-gate onFire threw:", e);
      }
    }
  }
  reset() {
    this.queue.length = 0;
    this.seq = 0;
  }
};

// ../../../twai-web-sdk/packages/core/dist/chatGateway.js
var ChatGateway = class {
  env;
  credentials;
  constructor(opts) {
    this.env = opts.env;
    this.credentials = opts.credentials;
  }
  /** Send one chat turn. Throws TwaiUnauthorizedError on 401/403, TwaiChatError otherwise. */
  async send(text, session, opts = {}) {
    const creds = resolveCredentials(this.credentials);
    const body = {
      text,
      sessionid: session.sessionId,
      avatarName: session.avatar.avatarId,
      avatarVoice: session.avatar.avatarVoice,
      ttsSelection: session.avatar.ttsSelection,
      chunkSize: "10",
      displayVoice: true,
      type: "chat",
      interrupt: opts.interrupt ?? true,
      userId: session.userId ?? null
    };
    let res;
    try {
      res = await fetch(this.env.humanUrl(), {
        method: "POST",
        headers: { "Content-Type": "application/json", ...creds.headers() },
        body: JSON.stringify(body)
      });
    } catch (e) {
      throw new TwaiChatError("POST /human network error", void 0, e);
    }
    if (res.status === 401 || res.status === 403) {
      throw new TwaiUnauthorizedError(`/human ${res.status}: view token missing or invalid`);
    }
    if (!res.ok) {
      const detail = await res.text().catch(() => res.statusText);
      throw new TwaiChatError(`/human ${res.status}: ${detail.slice(0, 200)}`, res.status);
    }
    return await res.json().catch(() => ({ code: 0 }));
  }
};

// ../../../twai-web-sdk/packages/player/dist/mseSession.js
var ManagedMediaSourceCtor = typeof window !== "undefined" ? window.ManagedMediaSource : void 0;
var MediaSourceCtor = ManagedMediaSourceCtor ?? (typeof window !== "undefined" ? window.MediaSource : void 0);
var HAS_MANAGED_MS = ManagedMediaSourceCtor !== void 0;
var TRAILING_BUFFER_S = 5;
var LIVE_EDGE_TRIGGER_S = 1.2;
var LIVE_EDGE_TARGET_S = 0.6;
var SPEAK_WATCHDOG_MS = 12e3;
function makeSessionId() {
  return `mse-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
}
var MseAvatarSession = class {
  sessionId = makeSessionId();
  env;
  avatar;
  userId;
  cbs;
  gateway;
  autoReconnect;
  _status = "idle";
  socket = null;
  objectUrl = null;
  sourceBuffer = null;
  queue = [];
  videoEl = null;
  gate;
  speakWatchdog = null;
  reconnectTimer = null;
  awaitingSpeaking = false;
  reconnectUsed = false;
  closedByUser = false;
  gestureSeen = false;
  // First-gesture unmute. The <video> starts muted so Chrome's autoplay policy
  // doesn't reject play() before a user interacts; we unmute on the first
  // pointer/key/touch. Ported from mseClient.ts — without it the avatar is
  // silent for the whole session.
  gestureEvents = ["pointerdown", "keydown", "touchstart"];
  unmuteOnGesture = () => {
    this.gestureSeen = true;
    this.removeGestureListeners();
    const v = this.videoEl;
    if (v) {
      v.muted = false;
      v.play().catch(() => {
      });
    }
  };
  addGestureListeners() {
    for (const e of this.gestureEvents) {
      window.addEventListener(e, this.unmuteOnGesture, { passive: true });
    }
  }
  removeGestureListeners() {
    for (const e of this.gestureEvents) {
      try {
        window.removeEventListener(e, this.unmuteOnGesture);
      } catch {
      }
    }
  }
  /** True once the user has interacted since this session mounted. */
  hasUserGesture() {
    return this.gestureSeen;
  }
  constructor(opts) {
    this.env = opts.env;
    this.avatar = opts.avatar;
    this.userId = opts.userId ?? null;
    this.cbs = opts.callbacks ?? {};
    this.autoReconnect = opts.autoReconnect ?? true;
    this.gateway = new ChatGateway({ env: opts.env, credentials: opts.credentials });
    this.gate = new SpeakingGate((v) => {
      if (v === "start") {
        this.clearSpeakWatchdog();
        this.setStatus("speaking");
        this.safe(() => this.cbs.onSpeakingStart?.());
      } else {
        this.setStatus("ready");
        this.safe(() => this.cbs.onSpeakingStop?.());
      }
    });
  }
  get status() {
    return this._status;
  }
  setStatus(next) {
    if (this._status === next)
      return;
    this._status = next;
    this.safe(() => this.cbs.onStatusChange?.(next));
  }
  safe(fn) {
    try {
      fn();
    } catch (e) {
      console.error("[twai] session callback threw:", e);
    }
  }
  emitError(err) {
    this.safe(() => this.cbs.onError?.(err));
  }
  // ---- connect ----
  async connect(video) {
    if (this._status !== "idle" && this._status !== "closed" && this._status !== "failed") {
      throw new TwaiConnectError(`cannot connect from status=${this._status}`);
    }
    if (!MediaSourceCtor) {
      this.setStatus("failed");
      throw new TwaiCodecError("MediaSource is not available in this browser");
    }
    if (!MediaSourceCtor.isTypeSupported(MSE_CODECS)) {
      this.setStatus("failed");
      throw new TwaiCodecError(`codec not supported by this browser: ${MSE_CODECS}`);
    }
    this.closedByUser = false;
    this.videoEl = video;
    this.setStatus("connecting");
    const mediaSource = new MediaSourceCtor();
    const sourceOpenP = new Promise((resolve) => {
      mediaSource.addEventListener("sourceopen", () => resolve(), { once: true });
    });
    if (HAS_MANAGED_MS && "srcObject" in video) {
      video.removeAttribute("src");
      try {
        ;
        video.srcObject = mediaSource;
        this.objectUrl = null;
      } catch (e) {
        console.warn("[twai] srcObject attach failed, falling back to blob URL", e);
        this.objectUrl = URL.createObjectURL(mediaSource);
        video.srcObject = null;
        video.src = this.objectUrl;
      }
    } else {
      this.objectUrl = URL.createObjectURL(mediaSource);
      video.srcObject = null;
      video.src = this.objectUrl;
    }
    video.muted = !this.gestureSeen;
    try {
      video.load();
    } catch {
    }
    if (!this.gestureSeen)
      this.addGestureListeners();
    const ws = new WebSocket(this.env.mseWebSocketUrl());
    ws.binaryType = "arraybuffer";
    this.socket = ws;
    const wsOpenP = new Promise((resolve, reject) => {
      ws.addEventListener("open", () => resolve(), { once: true });
      ws.addEventListener("error", (e) => reject(e), { once: true });
    });
    let connectTimer;
    const timeoutP = new Promise((_, reject) => {
      connectTimer = setTimeout(() => reject(new TwaiConnectError("connect timed out")), HANDSHAKE_TIMEOUT_MS);
    });
    try {
      await Promise.race([Promise.all([sourceOpenP, wsOpenP]), timeoutP]);
    } catch (e) {
      if (connectTimer !== void 0)
        clearTimeout(connectTimer);
      this.setStatus("failed");
      this.disconnect();
      const err = e instanceof TwaiConnectError ? e : new TwaiConnectError("failed to open MediaSource or WebSocket", e);
      this.emitError(err);
      throw err;
    }
    if (connectTimer !== void 0)
      clearTimeout(connectTimer);
    if (mediaSource.readyState !== "open") {
      this.setStatus("failed");
      this.disconnect();
      throw new TwaiConnectError(`MediaSource not open (state=${mediaSource.readyState})`);
    }
    try {
      this.sourceBuffer = mediaSource.addSourceBuffer(MSE_CODECS);
      this.sourceBuffer.mode = "sequence";
    } catch (e) {
      this.setStatus("failed");
      this.disconnect();
      const err = new TwaiCodecError("addSourceBuffer failed", e);
      this.emitError(err);
      throw err;
    }
    this.sourceBuffer.addEventListener("updateend", () => {
      this.drain();
      this.evictIfNeeded();
    });
    ws.addEventListener("message", (evt) => this.onMessage(evt));
    ws.addEventListener("close", (evt) => this.onClose(evt));
    ws.addEventListener("error", () => {
      this.emitError(new TwaiTransportError("WebSocket error"));
    });
    video.addEventListener("timeupdate", this.onTimeUpdate);
    const handshake = {
      session_id: this.sessionId,
      avatar_id: this.avatar.avatarId,
      ttsSelection: this.avatar.ttsSelection,
      avatarVoice: this.avatar.avatarVoice,
      stream_type: "AV"
    };
    ws.send(JSON.stringify(handshake));
    const onPlaying = () => {
      this.reconnectUsed = false;
      this.setStatus("ready");
      video.removeEventListener("playing", onPlaying);
    };
    video.addEventListener("playing", onPlaying);
    video.play().catch(() => {
      if (!this.gestureSeen)
        video.muted = true;
      video.play().catch(() => {
      });
    });
  }
  onMessage(evt) {
    if (typeof evt.data === "string") {
      try {
        const m = JSON.parse(evt.data);
        if (m && m.type === "speaking" && (m.value === "start" || m.value === "stop")) {
          this.gate.enqueue(m);
          if (this.videoEl)
            this.gate.tick(this.videoEl.currentTime);
        }
      } catch {
      }
      return;
    }
    const buf = evt.data;
    this.safe(() => this.cbs.onFragment?.(buf.byteLength));
    this.queue.push(buf);
    this.drain();
  }
  onClose(evt) {
    if (this.closedByUser) {
      this.setStatus("closed");
      return;
    }
    const noReconnect = NO_RECONNECT_CLOSE_CODES.includes(evt.code);
    if (this.autoReconnect && !this.reconnectUsed && !noReconnect && this.videoEl) {
      this.reconnectUsed = true;
      const video = this.videoEl;
      this.teardownTransport();
      this.setStatus("connecting");
      this._status = "idle";
      this.reconnectTimer = setTimeout(() => {
        this.reconnectTimer = null;
        if (this.closedByUser)
          return;
        this.connect(video).catch((err) => this.emitError(err));
      }, 1500);
      return;
    }
    this.setStatus("closed");
  }
  drain() {
    const sb = this.sourceBuffer;
    if (!sb || sb.updating)
      return;
    const next = this.queue.shift();
    if (!next)
      return;
    try {
      sb.appendBuffer(next);
    } catch (e) {
      this.emitError(new TwaiTransportError("appendBuffer failed", e));
    }
  }
  evictIfNeeded() {
    const sb = this.sourceBuffer;
    const video = this.videoEl;
    if (!sb || sb.updating || this.queue.length > 0 || !video)
      return;
    const buffered = sb.buffered;
    if (buffered.length === 0)
      return;
    const start = buffered.start(0);
    const cutoff = video.currentTime - TRAILING_BUFFER_S;
    if (cutoff > start + 0.5) {
      try {
        sb.remove(start, cutoff);
      } catch {
      }
    }
  }
  onTimeUpdate = () => {
    const video = this.videoEl;
    const sb = this.sourceBuffer;
    if (!video)
      return;
    this.gate.tick(video.currentTime);
    if (sb && sb.buffered.length > 0) {
      const end = sb.buffered.end(sb.buffered.length - 1);
      if (end - video.currentTime > LIVE_EDGE_TRIGGER_S) {
        try {
          video.currentTime = end - LIVE_EDGE_TARGET_S;
        } catch {
        }
      }
    }
  };
  // ---- chat ----
  async send(text, opts = {}) {
    this.armSpeakWatchdog();
    let res;
    try {
      res = await this.gateway.send(text, { sessionId: this.sessionId, avatar: this.avatar, userId: this.userId }, opts);
    } catch (e) {
      this.clearSpeakWatchdog();
      this.emitError(e);
      throw e;
    }
    const reply = res?.res ?? res?.data;
    if (reply)
      this.safe(() => this.cbs.onReply?.(reply));
  }
  armSpeakWatchdog() {
    this.clearSpeakWatchdog();
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN)
      return;
    this.awaitingSpeaking = true;
    this.speakWatchdog = setTimeout(() => {
      if (this.awaitingSpeaking) {
        this.awaitingSpeaking = false;
        this.emitError(new TwaiTransportError("speak watchdog: no speaking=start within window"));
      }
    }, SPEAK_WATCHDOG_MS);
  }
  clearSpeakWatchdog() {
    this.awaitingSpeaking = false;
    if (this.speakWatchdog) {
      clearTimeout(this.speakWatchdog);
      this.speakWatchdog = null;
    }
  }
  // ---- teardown ----
  teardownTransport() {
    this.removeGestureListeners();
    if (this.socket) {
      try {
        this.socket.close();
      } catch {
      }
      this.socket = null;
    }
    if (this.videoEl) {
      this.videoEl.removeEventListener("timeupdate", this.onTimeUpdate);
      try {
        this.videoEl.srcObject = null;
        this.videoEl.removeAttribute("src");
        this.videoEl.load();
      } catch {
      }
    }
    if (this.objectUrl) {
      try {
        URL.revokeObjectURL(this.objectUrl);
      } catch {
      }
      this.objectUrl = null;
    }
    this.sourceBuffer = null;
    this.queue = [];
    this.gate.reset();
  }
  disconnect() {
    this.closedByUser = true;
    this.clearSpeakWatchdog();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.teardownTransport();
    this.videoEl = null;
    if (this._status !== "failed")
      this.setStatus("closed");
  }
};

// ../../../twai-web-sdk/packages/player/dist/avatarView.js
var AvatarView = class {
  session;
  root = null;
  idleVideo = null;
  liveVideo = null;
  opts;
  constructor(opts) {
    this.opts = opts;
    this.session = new MseAvatarSession({
      env: opts.env,
      avatar: opts.avatar,
      credentials: opts.credentials,
      userId: opts.userId,
      callbacks: {
        onStatusChange: (s) => {
          if (s !== "speaking")
            this.showIdle();
          this.opts.onStatusChange?.(s);
        },
        onSpeakingStart: () => {
          this.showLive();
          this.opts.onSpeakingStart?.();
        },
        onSpeakingStop: () => {
          this.showIdle();
          this.opts.onSpeakingStop?.();
        },
        onReply: (t) => this.opts.onReply?.(t),
        onError: (e) => this.opts.onError?.(e)
      }
    });
  }
  /** Build the DOM under `container` and return the root element. */
  mount(container) {
    const root = document.createElement("div");
    root.className = "twai-avatar-root";
    root.style.cssText = "position:relative;width:100%;height:100%;overflow:hidden;background:#000";
    const idle = document.createElement("video");
    idle.className = "twai-idle-video";
    idle.muted = true;
    idle.loop = true;
    idle.autoplay = true;
    idle.playsInline = true;
    idle.setAttribute("playsinline", "");
    idle.style.cssText = this.layerCss(1);
    if (this.opts.idleUrl)
      idle.src = this.opts.idleUrl;
    if (this.opts.posterUrl)
      idle.poster = this.opts.posterUrl;
    const live = document.createElement("video");
    live.className = "twai-live-video";
    live.playsInline = true;
    live.setAttribute("playsinline", "");
    live.style.cssText = this.layerCss(0);
    root.appendChild(idle);
    root.appendChild(live);
    container.appendChild(root);
    this.root = root;
    this.idleVideo = idle;
    this.liveVideo = live;
    idle.play().catch(() => {
    });
    return root;
  }
  layerCss(opacity) {
    return `position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:${opacity};transition:opacity .18s ease`;
  }
  showLive() {
    if (this.liveVideo)
      this.liveVideo.style.opacity = "1";
    if (this.idleVideo)
      this.idleVideo.style.opacity = "0";
  }
  showIdle() {
    if (this.liveVideo)
      this.liveVideo.style.opacity = "0";
    if (this.idleVideo)
      this.idleVideo.style.opacity = "1";
  }
  async connect() {
    if (!this.liveVideo)
      throw new Error("AvatarView.connect() called before mount()");
    await this.session.connect(this.liveVideo);
  }
  send(text, opts) {
    return this.session.send(text, opts);
  }
  disconnect() {
    this.session.disconnect();
  }
  /** Full teardown: disconnect the session and remove the DOM. */
  destroy() {
    this.disconnect();
    if (this.root && this.root.parentElement)
      this.root.parentElement.removeChild(this.root);
    this.root = null;
    this.idleVideo = null;
    this.liveVideo = null;
  }
  get status() {
    return this.session.status;
  }
};

// ../../../twai-web-sdk/packages/player/dist/apiSession.js
var ManagedMediaSourceCtor2 = typeof window !== "undefined" ? window.ManagedMediaSource : void 0;
var MediaSourceCtor2 = ManagedMediaSourceCtor2 ?? (typeof window !== "undefined" ? window.MediaSource : void 0);
var HAS_MANAGED_MS2 = ManagedMediaSourceCtor2 !== void 0;
var TRAILING_BUFFER_S2 = 5;
var LIVE_EDGE_TRIGGER_S2 = 1.2;
var LIVE_EDGE_TARGET_S2 = 0.6;
var SPEAK_WATCHDOG_MS2 = 12e3;
var ApiAvatarSession = class {
  sessionId;
  apiOrigin;
  sessionToken;
  speakEndpoint;
  cbs;
  autoReconnect;
  _status = "idle";
  socket = null;
  objectUrl = null;
  sourceBuffer = null;
  queue = [];
  videoEl = null;
  gate;
  speakWatchdog = null;
  reconnectTimer = null;
  awaitingSpeaking = false;
  reconnectUsed = false;
  closedByUser = false;
  gestureSeen = false;
  gestureEvents = ["pointerdown", "keydown", "touchstart"];
  unmuteOnGesture = () => {
    this.gestureSeen = true;
    this.removeGestureListeners();
    const v = this.videoEl;
    if (v) {
      v.muted = false;
      v.play().catch(() => {
      });
    }
  };
  addGestureListeners() {
    for (const e of this.gestureEvents)
      window.addEventListener(e, this.unmuteOnGesture, { passive: true });
  }
  removeGestureListeners() {
    for (const e of this.gestureEvents) {
      try {
        window.removeEventListener(e, this.unmuteOnGesture);
      } catch {
      }
    }
  }
  hasUserGesture() {
    return this.gestureSeen;
  }
  constructor(opts) {
    this.apiOrigin = opts.apiOrigin.replace(/\/+$/, "");
    this.sessionToken = opts.sessionToken;
    this.sessionId = opts.sessionId;
    this.speakEndpoint = opts.speakEndpoint;
    this.cbs = opts.callbacks ?? {};
    this.autoReconnect = opts.autoReconnect ?? true;
    this.gate = new SpeakingGate((v) => {
      if (v === "start") {
        this.clearSpeakWatchdog();
        this.setStatus("speaking");
        this.safe(() => this.cbs.onSpeakingStart?.());
      } else {
        this.setStatus("ready");
        this.safe(() => this.cbs.onSpeakingStop?.());
      }
    });
  }
  get status() {
    return this._status;
  }
  setStatus(next) {
    if (this._status === next)
      return;
    this._status = next;
    this.safe(() => this.cbs.onStatusChange?.(next));
  }
  safe(fn) {
    try {
      fn();
    } catch (e) {
      console.error("[twai] session callback threw:", e);
    }
  }
  emitError(err) {
    this.safe(() => this.cbs.onError?.(err));
  }
  /** wss://apiOrigin/v1/stream?token=<sessionToken> */
  wsUrl() {
    const wsOrigin = this.apiOrigin.replace(/^http/, "ws");
    return `${wsOrigin}/v1/stream?token=${encodeURIComponent(this.sessionToken)}`;
  }
  async connect(video) {
    if (this._status !== "idle" && this._status !== "closed" && this._status !== "failed") {
      throw new TwaiConnectError(`cannot connect from status=${this._status}`);
    }
    if (!MediaSourceCtor2) {
      this.setStatus("failed");
      throw new TwaiCodecError("MediaSource is not available in this browser");
    }
    if (!MediaSourceCtor2.isTypeSupported(MSE_CODECS)) {
      this.setStatus("failed");
      throw new TwaiCodecError(`codec not supported: ${MSE_CODECS}`);
    }
    this.closedByUser = false;
    this.videoEl = video;
    this.setStatus("connecting");
    const mediaSource = new MediaSourceCtor2();
    const sourceOpenP = new Promise((resolve) => {
      mediaSource.addEventListener("sourceopen", () => resolve(), { once: true });
    });
    if (HAS_MANAGED_MS2 && "srcObject" in video) {
      video.removeAttribute("src");
      try {
        ;
        video.srcObject = mediaSource;
        this.objectUrl = null;
      } catch {
        this.objectUrl = URL.createObjectURL(mediaSource);
        video.srcObject = null;
        video.src = this.objectUrl;
      }
    } else {
      this.objectUrl = URL.createObjectURL(mediaSource);
      video.srcObject = null;
      video.src = this.objectUrl;
    }
    video.muted = !this.gestureSeen;
    try {
      video.load();
    } catch {
    }
    if (!this.gestureSeen)
      this.addGestureListeners();
    const ws = new WebSocket(this.wsUrl());
    ws.binaryType = "arraybuffer";
    this.socket = ws;
    const wsOpenP = new Promise((resolve, reject) => {
      ws.addEventListener("open", () => resolve(), { once: true });
      ws.addEventListener("error", (e) => reject(e), { once: true });
    });
    let connectTimer;
    const timeoutP = new Promise((_, reject) => {
      connectTimer = setTimeout(() => reject(new TwaiConnectError("connect timed out")), HANDSHAKE_TIMEOUT_MS);
    });
    try {
      await Promise.race([Promise.all([sourceOpenP, wsOpenP]), timeoutP]);
    } catch (e) {
      if (connectTimer !== void 0)
        clearTimeout(connectTimer);
      this.setStatus("failed");
      this.disconnect();
      const err = e instanceof TwaiConnectError ? e : new TwaiConnectError("failed to open MediaSource or WebSocket", e);
      this.emitError(err);
      throw err;
    }
    if (connectTimer !== void 0)
      clearTimeout(connectTimer);
    if (mediaSource.readyState !== "open") {
      this.setStatus("failed");
      this.disconnect();
      throw new TwaiConnectError(`MediaSource not open (state=${mediaSource.readyState})`);
    }
    try {
      this.sourceBuffer = mediaSource.addSourceBuffer(MSE_CODECS);
      this.sourceBuffer.mode = "sequence";
    } catch (e) {
      this.setStatus("failed");
      this.disconnect();
      const err = new TwaiCodecError("addSourceBuffer failed", e);
      this.emitError(err);
      throw err;
    }
    this.sourceBuffer.addEventListener("updateend", () => {
      this.drain();
      this.evictIfNeeded();
    });
    ws.addEventListener("message", (evt) => this.onMessage(evt));
    ws.addEventListener("close", (evt) => this.onClose(evt));
    ws.addEventListener("error", () => this.emitError(new TwaiTransportError("WebSocket error")));
    video.addEventListener("timeupdate", this.onTimeUpdate);
    const onPlaying = () => {
      this.reconnectUsed = false;
      this.setStatus("ready");
      video.removeEventListener("playing", onPlaying);
    };
    video.addEventListener("playing", onPlaying);
    video.play().catch(() => {
      if (!this.gestureSeen)
        video.muted = true;
      video.play().catch(() => {
      });
    });
  }
  onMessage(evt) {
    if (typeof evt.data === "string") {
      try {
        const m = JSON.parse(evt.data);
        if (m && m.type === "speaking" && (m.value === "start" || m.value === "stop")) {
          this.gate.enqueue(m);
          if (this.videoEl)
            this.gate.tick(this.videoEl.currentTime);
        }
      } catch {
      }
      return;
    }
    const buf = evt.data;
    this.safe(() => this.cbs.onFragment?.(buf.byteLength));
    this.queue.push(buf);
    this.drain();
  }
  onClose(evt) {
    if (this.closedByUser) {
      this.setStatus("closed");
      return;
    }
    const noReconnect = NO_RECONNECT_CLOSE_CODES.includes(evt.code);
    if (this.autoReconnect && !this.reconnectUsed && !noReconnect && this.videoEl) {
      this.reconnectUsed = true;
      const video = this.videoEl;
      this.teardownTransport();
      this.setStatus("connecting");
      this._status = "idle";
      this.reconnectTimer = setTimeout(() => {
        this.reconnectTimer = null;
        if (this.closedByUser)
          return;
        this.connect(video).catch((err) => this.emitError(err));
      }, 1500);
      return;
    }
    this.setStatus("closed");
  }
  drain() {
    const sb = this.sourceBuffer;
    if (!sb || sb.updating)
      return;
    const next = this.queue.shift();
    if (!next)
      return;
    try {
      sb.appendBuffer(next);
    } catch (e) {
      this.emitError(new TwaiTransportError("appendBuffer failed", e));
    }
  }
  evictIfNeeded() {
    const sb = this.sourceBuffer;
    const video = this.videoEl;
    if (!sb || sb.updating || this.queue.length > 0 || !video)
      return;
    const buffered = sb.buffered;
    if (buffered.length === 0)
      return;
    const start = buffered.start(0);
    const cutoff = video.currentTime - TRAILING_BUFFER_S2;
    if (cutoff > start + 0.5) {
      try {
        sb.remove(start, cutoff);
      } catch {
      }
    }
  }
  onTimeUpdate = () => {
    const video = this.videoEl;
    const sb = this.sourceBuffer;
    if (!video)
      return;
    this.gate.tick(video.currentTime);
    if (sb && sb.buffered.length > 0) {
      const end = sb.buffered.end(sb.buffered.length - 1);
      if (end - video.currentTime > LIVE_EDGE_TRIGGER_S2) {
        try {
          video.currentTime = end - LIVE_EDGE_TARGET_S2;
        } catch {
        }
      }
    }
  };
  async send(text, opts = {}) {
    if (!this.speakEndpoint) {
      throw new TwaiChatError("ApiAvatarSession.send() requires a speakEndpoint option (developer-server proxy). Omit send() for view-only integrations that drive turns from your server.");
    }
    this.armSpeakWatchdog();
    let res;
    try {
      res = await fetch(this.speakEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ session_id: this.sessionId, text, interrupt: opts.interrupt ?? true })
      });
    } catch (e) {
      this.clearSpeakWatchdog();
      const err = new TwaiChatError("speakEndpoint network error", void 0, e);
      this.emitError(err);
      throw err;
    }
    if (!res.ok) {
      this.clearSpeakWatchdog();
      const detail = await res.text().catch(() => res.statusText);
      const err = new TwaiChatError(`speakEndpoint ${res.status}: ${detail.slice(0, 200)}`, res.status);
      this.emitError(err);
      throw err;
    }
    const body = await res.json().catch(() => ({}));
    if (body && typeof body.reply === "string") {
      const replyText = body.reply;
      this.safe(() => this.cbs.onReply?.(replyText));
    }
  }
  armSpeakWatchdog() {
    this.clearSpeakWatchdog();
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN)
      return;
    this.awaitingSpeaking = true;
    this.speakWatchdog = setTimeout(() => {
      if (this.awaitingSpeaking) {
        this.awaitingSpeaking = false;
        this.emitError(new TwaiTransportError("speak watchdog: no speaking=start within window"));
      }
    }, SPEAK_WATCHDOG_MS2);
  }
  clearSpeakWatchdog() {
    this.awaitingSpeaking = false;
    if (this.speakWatchdog) {
      clearTimeout(this.speakWatchdog);
      this.speakWatchdog = null;
    }
  }
  teardownTransport() {
    this.removeGestureListeners();
    if (this.socket) {
      try {
        this.socket.close();
      } catch {
      }
      this.socket = null;
    }
    if (this.videoEl) {
      this.videoEl.removeEventListener("timeupdate", this.onTimeUpdate);
      try {
        this.videoEl.srcObject = null;
        this.videoEl.removeAttribute("src");
        this.videoEl.load();
      } catch {
      }
    }
    if (this.objectUrl) {
      try {
        URL.revokeObjectURL(this.objectUrl);
      } catch {
      }
      this.objectUrl = null;
    }
    this.sourceBuffer = null;
    this.queue = [];
    this.gate.reset();
  }
  disconnect() {
    this.closedByUser = true;
    this.clearSpeakWatchdog();
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = null;
    }
    this.teardownTransport();
    this.videoEl = null;
    if (this._status !== "failed")
      this.setStatus("closed");
  }
};

// ../../../twai-web-sdk/packages/player/dist/apiAvatarView.js
var ApiAvatarView = class {
  session;
  root = null;
  idleVideo = null;
  liveVideo = null;
  opts;
  constructor(opts) {
    this.opts = opts;
    const userCallbacks = opts.callbacks ?? {};
    const hasIdle = !!opts.idleUrl;
    const wrappedCallbacks = {
      ...userCallbacks,
      onStatusChange: (s) => {
        if (hasIdle && s !== "speaking")
          this.showIdle();
        userCallbacks.onStatusChange?.(s);
      },
      onSpeakingStart: () => {
        this.showLive();
        userCallbacks.onSpeakingStart?.();
      },
      onSpeakingStop: () => {
        if (hasIdle)
          this.showIdle();
        userCallbacks.onSpeakingStop?.();
      }
    };
    this.session = new ApiAvatarSession({ ...opts, callbacks: wrappedCallbacks });
  }
  /** Build the DOM under `container` and return the root element. */
  mount(container) {
    const root = document.createElement("div");
    root.className = "twai-avatar-root";
    root.style.cssText = "position:relative;width:100%;height:100%;overflow:hidden;background:#000";
    const hasIdle = !!this.opts.idleUrl;
    const idle = document.createElement("video");
    idle.className = "twai-idle-video";
    idle.muted = true;
    idle.loop = true;
    idle.autoplay = true;
    idle.playsInline = true;
    idle.setAttribute("playsinline", "");
    idle.style.cssText = this.layerCss(hasIdle ? 1 : 0);
    if (this.opts.idleUrl)
      idle.src = this.opts.idleUrl;
    if (this.opts.posterUrl)
      idle.poster = this.opts.posterUrl;
    const live = document.createElement("video");
    live.className = "twai-live-video";
    live.playsInline = true;
    live.setAttribute("playsinline", "");
    live.style.cssText = this.layerCss(hasIdle ? 0 : 1);
    root.appendChild(idle);
    root.appendChild(live);
    container.appendChild(root);
    this.root = root;
    this.idleVideo = idle;
    this.liveVideo = live;
    idle.play().catch(() => {
    });
    return root;
  }
  layerCss(opacity) {
    return `position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:${opacity};transition:opacity .18s ease`;
  }
  showLive() {
    if (this.liveVideo)
      this.liveVideo.style.opacity = "1";
    if (this.idleVideo)
      this.idleVideo.style.opacity = "0";
  }
  showIdle() {
    if (this.liveVideo)
      this.liveVideo.style.opacity = "0";
    if (this.idleVideo)
      this.idleVideo.style.opacity = "1";
  }
  async connect() {
    if (!this.liveVideo)
      throw new Error("ApiAvatarView.connect() called before mount()");
    await this.session.connect(this.liveVideo);
  }
  send(text, opts) {
    return this.session.send(text, opts);
  }
  disconnect() {
    this.session.disconnect();
  }
  destroy() {
    this.disconnect();
    if (this.root && this.root.parentElement)
      this.root.parentElement.removeChild(this.root);
    this.root = null;
    this.idleVideo = null;
    this.liveVideo = null;
  }
  get status() {
    return this.session.status;
  }
};
export {
  AnonymousCredentials,
  ApiAvatarSession,
  ApiAvatarView,
  AvatarView,
  MseAvatarSession,
  PublicKeyCredentials,
  TwaiEnvironment,
  ViewTokenCredentials
};
