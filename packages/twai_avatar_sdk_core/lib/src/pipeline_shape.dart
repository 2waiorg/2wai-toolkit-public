/// Which SDK transport / rendering stack a session runs on.
/// Distinct from [AvatarStack] — this picks the *ChatSession
/// concrete type*; [AvatarStack] only picks the nginx pathPrefix
/// within the hosted-MSE shape.
///
/// | Shape                | ChatSession type            | Where render happens |
/// |----------------------|------------------------------|----------------------|
/// | [mseHosted]          | `MseStreamChatSession`       | Server (Wav2Lip/muse) |
/// | [pipelineV13]        | `PipelineV13ChatSession`     | Server (v1.3 per-msg) |
/// | [onDevice]           | `LocalChatSession` (Layer 1) | Client (Layer 2 impl) |
///
/// See `docs/edge_offline_shape.md` for the three-shape framing
/// (integration Shape #1 / #2 / #3). `AvatarProfile.shape` carries
/// this value; the customer app dispatches to the right session
/// constructor.
enum PipelineShape {
  /// Adapter 1 — Penthouse MSE-over-WebSocket. Server does Wav2Lip
  /// (or muse per pathPrefix) render + TTS + brain. Client receives
  /// a fragmented-MP4 stream. Default for hosted avatars.
  mseHosted,

  /// Adapter 2 — Pipeline v1.3 POST /chat → single MP4 per message.
  /// Simpler protocol; higher per-message latency; no continuous
  /// idle stream. Used mostly for constrained clients + legacy.
  pipelineV13,

  /// Shape #3 — fully on-device via the Layer 1 orchestrator
  /// (`LocalChatSession` from `twai_avatar_sdk_local`). Customer
  /// app supplies concrete Layer 2 engines (BrainProvider /
  /// TtsProvider / AvatarRenderer). Airplane-mode compatible; no
  /// server traffic once loaded. Real engines land per SDK-32/33
  /// (Talk2Jesus iOS Swift plugin + portable ONNX); stub engines
  /// are shipped in the meantime for orchestration validation.
  onDevice,
}
