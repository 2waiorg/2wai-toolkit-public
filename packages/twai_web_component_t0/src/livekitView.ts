/**
 * LiveKitAvatarView — T0 idle<->live crossfade widget for the 2wai Avatar
 * Toolkit's JS package.
 *
 * Transitional. This file is a byte-parallel copy of `packages/player/src/
 * livekitView.ts` in twai-web-sdk PR #3 (branch `feat/web-component-t0-
 * proposal`). When Mason's sub-project 3 lands and @twai/player ships its own
 * T0 view, this file is deleted and the toolkit's `<twai-avatar-t0>` element
 * re-points at `@twai/player`. Keep the two in sync until then.
 *
 * DOM shape: root div + looping idle <video> + live <video>. Engine session
 * comes from @twai/core's `createAvatarSession`. Single-element media mode
 * (audio in the video element) matches the two-video layout; two-element mode
 * is available on the engine directly.
 *
 * Auth: this view never fetches. The host supplies either a mint closure or
 * a `mintUrl`; both classify through `mintResultFromFetch` so the mint-error
 * taxonomy is uniform.
 *
 * Styling hooks (class names, override in your app CSS):
 *   .twai-avatar-root .twai-idle-video .twai-live-video
 */
import type {
  ChatEncoding,
  LiveKitAvatarSession,
  MintResult,
} from '@twai/core'
import { createAvatarSession, mintResultFromFetch } from '@twai/core'

/** Mint closure signature; same shape @twai/core's engine takes. */
export type MintClosure = () => Promise<MintResult>

/** Callbacks fired as the engine progresses. All optional; hosts opt in. */
export interface LiveKitAvatarViewCallbacks {
  onWarming?: (room: string) => void
  onReady?: (room: string) => void
  onSpeakingStart?: () => void
  onSpeakingStop?: () => void
  onReplyStart?: (replyId: string) => void
  onReplyText?: (replyId: string, text: string) => void
  onReplyComplete?: (
    replyId: string,
    text: string,
    kind: 'end' | 'cancel' | 'error',
  ) => void
  onEnded?: (cause: 'agent-ended' | 'transport-ended') => void
  onNotice?: (kind: 'sessions-busy' | 'renderer-timeout') => void
  /**
   * Terminal errors from `connect()` reach here. Non-terminal engine
   * conditions surface as their own callback (notice, ended) instead.
   */
  onError?: (err: unknown) => void
}

export interface LiveKitAvatarViewOptions extends LiveKitAvatarViewCallbacks {
  /**
   * Mint closure. Preferred over `mintUrl` when both are set; if neither is
   * set `connect()` throws.
   */
  mint?: MintClosure
  /**
   * URL POSTed to on connect. Response is classified via
   * `mintResultFromFetch`. Ignored if `mint` is set.
   */
  mintUrl?: string
  /**
   * `fetch` init merged with `{ method: 'POST' }` when `mintUrl` is used.
   * Use this to send headers, credentials, or a body — a mint proxy that
   * needs an avatar_id in a JSON body is the common case.
   */
  mintInit?: RequestInit
  /** Passed through to the engine. See `AvatarSessionOptions.chatEncoding`. */
  chatEncoding?: ChatEncoding
  /** Passed through to the engine. Rarely overridden. */
  agentIdentityPrefix?: string
  /** Passed through to the engine. See replyStream's `keepTags`. */
  keepTags?: () => boolean

  /** Looping idle video shown when not speaking. */
  idleUrl?: string
  /** Poster image while the idle video loads. */
  posterUrl?: string
  /** Crossfade duration in ms; default 180. */
  fadeMs?: number
}

/**
 * The T0 view. Public API: `mount`, `connect`, `send`, `disconnect`,
 * `destroy`, plus `resumePlayback` for the first user gesture.
 */
export class LiveKitAvatarView {
  session: LiveKitAvatarSession | null = null
  private root: HTMLElement | null = null
  private idleVideo: HTMLVideoElement | null = null
  private liveVideo: HTMLVideoElement | null = null
  private readonly opts: LiveKitAvatarViewOptions
  private readonly fadeMs: number

  constructor(opts: LiveKitAvatarViewOptions) {
    this.opts = opts
    this.fadeMs = opts.fadeMs ?? 180
  }

  /** Build the DOM under `container` and return the root element. */
  mount(container: HTMLElement): HTMLElement {
    const root = document.createElement('div')
    root.className = 'twai-avatar-root'
    root.style.cssText =
      'position:relative;width:100%;height:100%;overflow:hidden;background:#000'

    const idle = document.createElement('video')
    idle.className = 'twai-idle-video'
    idle.muted = true
    idle.loop = true
    idle.autoplay = true
    idle.playsInline = true
    idle.setAttribute('playsinline', '')
    idle.style.cssText = this.layerCss(1)
    if (this.opts.idleUrl) idle.src = this.opts.idleUrl
    if (this.opts.posterUrl) idle.poster = this.opts.posterUrl

    const live = document.createElement('video')
    live.className = 'twai-live-video'
    live.playsInline = true
    live.setAttribute('playsinline', '')
    // Single-element mode: video element is the only audio sink, so it must
    // NOT be pre-muted here. The engine's attach() retries muted only if an
    // unmuted play() is refused; resumePlayback() undoes that on first user
    // gesture.
    live.style.cssText = this.layerCss(0)

    root.appendChild(idle)
    root.appendChild(live)
    container.appendChild(root)

    this.root = root
    this.idleVideo = idle
    this.liveVideo = live
    idle.play().catch(() => {
      /* autoplay may defer to gesture */
    })
    return root
  }

  /**
   * Build the engine session and join the room. Idempotent: a second call on
   * a live view is a no-op. Mint failures reach `onError` and re-throw with
   * their taxonomy intact (`MintRateLimited` / `MintUnavailable`).
   */
  async connect(): Promise<void> {
    if (!this.liveVideo) {
      throw new Error('LiveKitAvatarView.connect() called before mount()')
    }
    if (this.session) return
    const mint = this.resolveMint()
    const session = createAvatarSession({
      mint,
      media: { video: this.liveVideo },
      chatEncoding: this.opts.chatEncoding,
      agentIdentityPrefix: this.opts.agentIdentityPrefix,
      keepTags: this.opts.keepTags,
      onHandlerError: err => this.opts.onError?.(err),
    })
    this.session = session
    this.wireEvents(session)
    try {
      await session.connect()
    } catch (err) {
      this.opts.onError?.(err)
      throw err
    }
  }

  /**
   * Publish a chat turn. Throws `SessionNotReady` if the renderer hasn't
   * settled yet — hosts branch on `err.kind === 'not-ready'` to distinguish
   * "too early" from "publish failed".
   */
  send(text: string, extra?: Record<string, unknown>): Promise<void> {
    const session = this.session
    if (!session) {
      return Promise.reject(
        new Error('LiveKitAvatarView.send() called before connect()'),
      )
    }
    return session.send(text, extra)
  }

  /**
   * Resume LiveKit's own autoplay gates. Wire to a click handler on the host
   * page so the first user gesture unmutes and plays.
   */
  resumePlayback(): Promise<void> {
    return this.session?.resumePlayback() ?? Promise.resolve()
  }

  /** Drop the session without removing the DOM. `destroy()` does both. */
  async disconnect(): Promise<void> {
    const session = this.session
    if (!session) return
    this.session = null
    await session.disconnect()
  }

  /** Full teardown: disconnect the session and remove the DOM. */
  destroy(): void {
    void this.disconnect()
    if (this.root?.parentElement) this.root.parentElement.removeChild(this.root)
    this.root = null
    this.idleVideo = null
    this.liveVideo = null
  }

  private resolveMint(): MintClosure {
    if (this.opts.mint) return this.opts.mint
    const url = this.opts.mintUrl
    if (!url) {
      throw new Error(
        'LiveKitAvatarView: `mint` closure or `mintUrl` is required',
      )
    }
    const baseInit: RequestInit = { method: 'POST', ...this.opts.mintInit }
    return () => mintResultFromFetch(fetch(url, baseInit))
  }

  private wireEvents(session: LiveKitAvatarSession): void {
    const cb = this.opts
    session.on('warming', e => cb.onWarming?.(e.room))
    session.on('ready', e => cb.onReady?.(e.room))
    session.on('speaking', e => {
      if (e.active) {
        this.showLive()
        cb.onSpeakingStart?.()
      } else {
        this.showIdle()
        cb.onSpeakingStop?.()
      }
    })
    session.on('reply:start', e => cb.onReplyStart?.(e.replyId))
    session.on('reply:text', e => cb.onReplyText?.(e.replyId, e.text))
    session.on('reply:complete', e =>
      cb.onReplyComplete?.(e.replyId, e.text, e.kind),
    )
    session.on('track:lost', e => {
      if (e.kind === 'video') this.showIdle()
    })
    session.on('ended', e => {
      this.showIdle()
      cb.onEnded?.(e.cause)
    })
    session.on('notice', e => cb.onNotice?.(e.kind))
  }

  private layerCss(opacity: number): string {
    return `position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:${opacity};transition:opacity ${this.fadeMs}ms ease`
  }

  private showLive(): void {
    if (this.liveVideo) this.liveVideo.style.opacity = '1'
    if (this.idleVideo) this.idleVideo.style.opacity = '0'
  }

  private showIdle(): void {
    if (this.liveVideo) this.liveVideo.style.opacity = '0'
    if (this.idleVideo) this.idleVideo.style.opacity = '1'
  }
}
