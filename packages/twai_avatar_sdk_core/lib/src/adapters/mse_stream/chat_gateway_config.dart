/// Per-session configuration for the `POST /ext-api/human` chat gateway.
///
/// The `sessionId`, `avatarName`, `avatarVoice`, and `ttsSelection` MUST
/// match the values sent in the WS handshake (see [MseStreamConfig]) —
/// the gateway uses them to route the synthesized response into the
/// open WebSocket. See `docs/protocol.md` §2.
class ChatGatewayConfig {
  /// Session id correlating this POST with an open WS. **Must** match
  /// the WS handshake's `session_id`.
  final String sessionId;

  /// Pipeline avatar id. **Must** match the WS handshake's `avatar_id`.
  final String avatarName;

  /// Voice reference UUID. **Must** match the WS handshake's `avatarVoice`.
  final String avatarVoice;

  /// TTS provider slot. **Must** match the WS handshake's `ttsSelection`.
  final String ttsSelection;

  /// Stable per-user id for brain-side memory scoping (mem0 / Qdrant).
  /// Pass `null` for anonymous; a UUID for authenticated.
  final String? userId;

  /// LLM streaming chunk granularity (numeric string). Default `'10'`.
  final String chunkSize;

  /// Whether to render audio for the reply. Default `true`.
  final bool displayVoice;

  /// If a previous message is still rendering, cancel it. Default `true`.
  final bool interrupt;

  /// Request type. Only `'chat'` is documented today.
  final String type;

  const ChatGatewayConfig({
    required this.sessionId,
    required this.avatarName,
    required this.avatarVoice,
    required this.ttsSelection,
    required this.userId,
    this.chunkSize = '10',
    this.displayVoice = true,
    this.interrupt = true,
    this.type = 'chat',
  });

  /// Build the JSON request body for `sendMessage(text)`.
  ///
  /// [gamificationLevel] and [avatarStateBlock] are per-turn optional
  /// fields added to `POST /ext-api/human` by penthouse's
  /// `ops/origin-routed-brain` Patch #70 (r14). main_service forwards
  /// them to the brain's chat call so the brain can shape its reply
  /// based on the user's Trust Stage / avatar state. Both default to
  /// absent (key omitted from the body) when null; brain treats absent
  /// as Stage 1 / no extra context. See `docs/protocol.md` §2.
  Map<String, dynamic> bodyFor(
    String text, {
    num? gamificationLevel,
    Object? avatarStateBlock,
  }) =>
      {
        'text': text,
        'sessionid': sessionId,
        'avatarName': avatarName,
        'avatarVoice': avatarVoice,
        'ttsSelection': ttsSelection,
        'chunkSize': chunkSize,
        'displayVoice': displayVoice,
        'interrupt': interrupt,
        'type': type,
        'userId': userId,
        if (gamificationLevel != null) 'gamificationLevel': gamificationLevel,
        if (avatarStateBlock != null) 'avatarStateBlock': avatarStateBlock,
      };
}
