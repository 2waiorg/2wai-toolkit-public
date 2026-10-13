/// Configuration for the v1.3 `POST /chat` pipeline adapter.
///
/// Field names match the reference Python client at
/// `2wai-avatar-pipeline/client/pipeline_client.py:26-37`. The current
/// reference server (`server.py`) is hardcoded single-avatar and ignores
/// these fields, but conformant v1.3 servers should honor them.
class PipelineV13Config {
  /// Avatar slug — e.g. `'sophi'`, `'KrystalHarperBikini'`. Current
  /// reference server ignores this; future multi-avatar deployments will
  /// use it to pick the talking-head clip set.
  final String avatar;

  /// Optional voice override (ElevenLabs voice id, Qwen voice UUID, etc).
  /// When `null`, the server uses its configured default.
  final String? voiceId;

  const PipelineV13Config({
    required this.avatar,
    this.voiceId,
  });

  /// Build the request body for `chat(message)`.
  Map<String, dynamic> bodyFor(
    String message, {
    List<Map<String, dynamic>>? history,
  }) =>
      {
        'avatar': avatar,
        'message': message,
        if (voiceId != null) 'voice_id': voiceId,
        if (history != null) 'history': history,
      };
}
