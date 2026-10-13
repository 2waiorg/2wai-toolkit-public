/**
 * @2wai/web-component-t0 — the toolkit's transitional JS T0 (LiveKit)
 * <twai-avatar-t0> custom element.
 *
 * No side effect on import. Consumers call `defineTwaiAvatarT0(tag?)` to
 * register the element — tag defaults to `<twai-avatar-t0>`.
 *
 * When Mason's upstream `@twai/web-component` ships its T0 shape (twai-web-sdk
 * PR #3 → sub-project 3), this package is deprecated and consumers migrate.
 * Wire, event names, and callable surface are byte-parallel to that PR so a
 * migration is a rename, not a rewrite.
 */
export {
  TwaiAvatarT0Element,
  defineTwaiAvatarT0,
} from './twaiAvatar.js'
export {
  LiveKitAvatarView,
} from './livekitView.js'
export type {
  LiveKitAvatarViewOptions,
  LiveKitAvatarViewCallbacks,
  MintClosure,
} from './livekitView.js'
