/**
 * <twai-avatar-t0> — 2wai Avatar Toolkit's T0 (LiveKit) custom element.
 *
 * Transitional. Byte-parallel to `packages/web-component/src/twaiAvatarLiveKit.ts`
 * in twai-web-sdk PR #3 (branch `feat/web-component-t0-proposal`), with two
 * branding differences:
 *
 *   - Default tag is `<twai-avatar-t0>` (matches the toolkit's "T0" vocabulary
 *     for the LiveKit transport); Mason's package uses `<twai-avatar-lk>`.
 *   - Registration function is `defineTwaiAvatarT0`.
 *
 * When Mason's sub-project 3 lands, this file is deleted and consumers migrate
 * to `@twai/web-component/livekit` (or whatever tag it ships under). Until
 * then, this is the JS T0 web-component surface for toolkit consumers.
 *
 * Attributes (all optional except one of `mint-url` / a JS-side `mint`):
 *   mint-url                     URL POSTed to for a MintResult. Required
 *                                unless a `mint` closure is set via the JS
 *                                property `element.mint` before connect().
 *   idle-url                     looping idle video
 *   poster-url                   poster image
 *   agent-identity-prefix        engine default is 'livealman-agent-'
 *   chat-encoding                'envelope' (default) | 'text'
 *   keep-tags                    presence keeps direction tags in reply text
 *                                (admin review mode)
 *   fade-ms                      idle<->live crossfade duration; default 180
 *   autoconnect                  presence => connect on mount
 *   stt-url                      when set, renders a push-to-talk mic
 *                                button that POSTs recorded audio to this
 *                                endpoint (multipart field "audio",
 *                                response { text }). Uses @twai/mic.
 *   mic-auto-send                presence: auto-send the transcript to the
 *                                avatar on release (default). Absent: only
 *                                emits `twai-transcript` for host wiring.
 *
 * Methods:
 *   connect(): Promise<void>
 *   send(text, extra?): Promise<void>
 *   resumePlayback(): Promise<void>   // wire to a click for autoplay unlock
 *   disconnect(): Promise<void>
 *   startMic(): Promise<void>         // programmatic mic control
 *   stopMic(): Promise<string>
 *   cancelMic(): void
 *
 * Events:
 *   twai-warming        detail:{room}
 *   twai-ready          detail:{room}
 *   twai-speaking-start
 *   twai-speaking-stop
 *   twai-reply-start    detail:{replyId}
 *   twai-reply          detail:{replyId, text}
 *   twai-reply-complete detail:{replyId, text, kind}
 *   twai-ended          detail:{cause}
 *   twai-notice         detail:{kind}
 *   twai-error          detail:{error}
 *   twai-mic-start
 *   twai-mic-stop
 *   twai-transcript     detail:{text}
 *   twai-mic-error      detail:{error}
 */
import { TwaiMic } from '@twai/mic'

import {
  LiveKitAvatarView,
  type LiveKitAvatarViewOptions,
  type MintClosure,
} from './livekitView.js'

export class TwaiAvatarT0Element extends HTMLElement {
  private view: LiveKitAvatarView | null = null
  private mic: TwaiMic | null = null
  private micButton: HTMLButtonElement | null = null
  private isSpeaking = false
  private isListening = false
  /**
   * Optional host-side mint closure. Set via JS before `connect()`; takes
   * precedence over the `mint-url` attribute if both are present.
   */
  mint?: MintClosure

  static get observedAttributes(): string[] {
    return ['idle-url', 'poster-url']
  }

  connectedCallback(): void {
    if (this.view) return
    const opts: LiveKitAvatarViewOptions = {
      mint: this.mint,
      mintUrl: this.getAttribute('mint-url') ?? undefined,
      idleUrl: this.getAttribute('idle-url') ?? undefined,
      posterUrl: this.getAttribute('poster-url') ?? undefined,
      agentIdentityPrefix:
        this.getAttribute('agent-identity-prefix') ?? undefined,
      chatEncoding: this.readChatEncoding(),
      keepTags: this.hasAttribute('keep-tags') ? () => true : undefined,
      fadeMs: this.readFadeMs(),
      onWarming: room => this.emit('twai-warming', { room }),
      onReady: room => this.emit('twai-ready', { room }),
      onSpeakingStart: () => {
        this.isSpeaking = true
        this.refreshMicButtonState()
        this.emit('twai-speaking-start', {})
      },
      onSpeakingStop: () => {
        this.isSpeaking = false
        this.refreshMicButtonState()
        this.emit('twai-speaking-stop', {})
      },
      onReplyStart: replyId => this.emit('twai-reply-start', { replyId }),
      onReplyText: (replyId, text) =>
        this.emit('twai-reply', { replyId, text }),
      onReplyComplete: (replyId, text, kind) =>
        this.emit('twai-reply-complete', { replyId, text, kind }),
      onEnded: cause => this.emit('twai-ended', { cause }),
      onNotice: kind => this.emit('twai-notice', { kind }),
      onError: error => this.emit('twai-error', { error }),
    }

    this.view = new LiveKitAvatarView(opts)
    this.style.display = this.style.display || 'block'
    this.view.mount(this)

    const sttUrl = this.getAttribute('stt-url')
    if (sttUrl) this.installMicButton(sttUrl)

    if (this.hasAttribute('autoconnect')) {
      this.connect().catch(err => this.emit('twai-error', { error: err }))
    }
  }

  disconnectedCallback(): void {
    this.mic?.cancel()
    this.mic = null
    this.micButton?.remove()
    this.micButton = null
    this.view?.destroy()
    this.view = null
  }

  attributeChangedCallback(): void {
    // idle-url / poster-url are only read at mount; changing them live has
    // no effect. Left declared so future live-swap logic doesn't silently
    // miss the observer wiring.
  }

  async connect(): Promise<void> {
    if (!this.view) throw new Error('<twai-avatar-t0> not mounted')
    await this.view.connect()
  }

  send(text: string, extra?: Record<string, unknown>): Promise<void> {
    if (!this.view) throw new Error('<twai-avatar-t0> not mounted')
    return this.view.send(text, extra)
  }

  resumePlayback(): Promise<void> {
    return this.view?.resumePlayback() ?? Promise.resolve()
  }

  disconnect(): Promise<void> {
    return this.view?.disconnect() ?? Promise.resolve()
  }

  /** Imperative mic control (host page can drive its own button). */
  async startMic(): Promise<void> {
    if (!this.mic || this.isListening || this.isSpeaking) return
    this.isListening = true
    this.refreshMicButtonState()
    this.emit('twai-mic-start', {})
    try {
      await this.mic.start()
    } catch (err) {
      this.isListening = false
      this.refreshMicButtonState()
      this.emit('twai-mic-error', { error: err })
    }
  }

  async stopMic(): Promise<string> {
    if (!this.mic || !this.isListening) return ''
    const text = await this.mic.stop()
    this.isListening = false
    this.refreshMicButtonState()
    this.emit('twai-mic-stop', {})
    if (text) {
      this.emit('twai-transcript', { text })
      if (this.readMicAutoSend()) {
        void this.send(text).catch(err =>
          this.emit('twai-error', { error: err }),
        )
      }
    }
    return text
  }

  cancelMic(): void {
    if (!this.mic || !this.isListening) return
    this.mic.cancel()
    this.isListening = false
    this.refreshMicButtonState()
    this.emit('twai-mic-stop', {})
  }

  private installMicButton(sttUrl: string): void {
    this.mic = new TwaiMic({
      sttUrl,
      onError: err => this.emit('twai-mic-error', { error: err }),
    })
    const btn = document.createElement('button')
    btn.type = 'button'
    btn.className = 'twai-mic-button'
    btn.setAttribute('aria-label', 'Hold to speak')
    btn.style.cssText = [
      'position:absolute',
      'bottom:12px',
      'right:12px',
      'width:56px',
      'height:56px',
      'border-radius:50%',
      'border:none',
      'background:rgba(0,0,0,0.55)',
      'color:#fff',
      'font-size:22px',
      'cursor:pointer',
      'display:flex',
      'align-items:center',
      'justify-content:center',
      'transition:background 150ms ease',
      'touch-action:none',
      'user-select:none',
      '-webkit-user-select:none',
      'z-index:10',
    ].join(';')
    btn.textContent = 'MIC'
    btn.addEventListener('pointerdown', ev => {
      ev.preventDefault()
      void this.startMic()
    })
    btn.addEventListener('pointerup', () => void this.stopMic())
    btn.addEventListener('pointerleave', () => this.cancelMic())
    btn.addEventListener('pointercancel', () => this.cancelMic())
    // Host page can style .twai-mic-button freely; the inline styles are
    // fallbacks so it looks reasonable without any CSS.
    this.appendChild(btn)
    this.micButton = btn
    this.refreshMicButtonState()
  }

  private refreshMicButtonState(): void {
    const btn = this.micButton
    if (!btn) return
    const disabled = this.isSpeaking
    btn.disabled = disabled
    btn.style.opacity = disabled ? '0.4' : '1'
    btn.style.background = this.isListening
      ? 'rgba(220,40,40,0.85)'
      : 'rgba(0,0,0,0.55)'
    btn.textContent = this.isListening ? '● REC' : 'MIC'
  }

  private readMicAutoSend(): boolean {
    // Default true. Absent attribute → auto-send. Presence of
    // `mic-auto-send="false"` disables; any other value keeps default.
    const v = this.getAttribute('mic-auto-send')
    if (v === null || v === '') return true
    return v !== 'false'
  }

  private readChatEncoding(): LiveKitAvatarViewOptions['chatEncoding'] {
    const v = this.getAttribute('chat-encoding')
    if (v === 'envelope' || v === 'text') return v
    return undefined
  }

  private readFadeMs(): number | undefined {
    const raw = this.getAttribute('fade-ms')
    if (raw == null) return undefined
    const n = Number.parseInt(raw, 10)
    return Number.isFinite(n) && n >= 0 ? n : undefined
  }

  private emit(type: string, detail: Record<string, unknown>): void {
    this.dispatchEvent(
      new CustomEvent(type, { detail, bubbles: true, composed: true }),
    )
  }
}

let defined = false
/**
 * Register the T0 element. Default tag is `<twai-avatar-t0>`; pass another
 * (e.g. `'twai-avatar'`) to bind under a different name. Idempotent.
 *
 * No auto-registration on import — call this explicitly so the tag choice is
 * always the host's, and so two packages defining the same tag can't collide
 * silently.
 */
export function defineTwaiAvatarT0(tag = 'twai-avatar-t0'): void {
  if (defined || typeof customElements === 'undefined') return
  if (!customElements.get(tag)) customElements.define(tag, TwaiAvatarT0Element)
  defined = true
}
