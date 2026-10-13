// Conditional-import barrel for the platform-specific
// TransparentVideoIdle build helper.
//
//   Web build (dart.library.html present) → uses HtmlElementView +
//     <video> with <source> tags for HEVC-alpha .mov (Safari/iOS)
//     and VP9-alpha .webm (Chrome/Firefox/Edge). Browser picks the
//     first format it can decode with alpha; the video composites
//     over whatever's behind it via the browser's native alpha path.
//   Native build → falls back to the opaque fallback URL via the
//     existing _LoopingVideoIdle. Non-web platforms can't currently
//     render alpha-channel video reliably from Flutter (video_player
//     doesn't expose an alpha compositing path). Callers get an
//     opaque render — the API contract on TransparentVideoIdle is
//     explicit about this.
export 'transparent_video_idle_impl_native.dart'
    if (dart.library.html) 'transparent_video_idle_impl_web.dart';
