/**
 * Bundle entry for samples/vanilla_js. Re-exports the surface the sample
 * uses from both @twai/player and @twai/core so a single bundled
 * <script src="/twai-player.js"> works.
 */
export {
  MseAvatarSession,
  AvatarView,
  ApiAvatarSession,
  ApiAvatarView,
} from '@twai/player';
export {
  TwaiEnvironment,
  AnonymousCredentials,
  PublicKeyCredentials,
  ViewTokenCredentials,
} from '@twai/core';
