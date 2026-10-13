import 'admin/avatar_catalog.dart' show AvatarStack;
import 'chat_session.dart' show Avatar;
import 'pipeline_shape.dart';

/// The full config bundle a customer app needs to render + converse
/// with a specific avatar via a specific pipeline shape. Data-only —
/// no widgets, no Flutter — so it's serializable, persistable to
/// prefs / a database / a URL, and equatable.
///
/// The customer app maps a profile to a live [ChatSession] via a
/// simple dispatch based on [shape]:
///
/// ```dart
/// ChatSession sessionForProfile(AvatarProfile p) => switch (p.shape) {
///   PipelineShape.mseHosted => twaiClient.mseStreamSession(
///     ttsSelection: p.ttsSelection,
///     pathPrefix: p.stack.pathPrefix,
///   ),
///   PipelineShape.pipelineV13 => twaiClient.pipelineV13Session(),
///   PipelineShape.onDevice => LocalChatSession(
///     brainProvider: myBrainProvider,
///     ttsProvider: myTtsProvider,
///     avatarRenderer: myRenderer,
///     assetBundle: myBundle,
///   ),
/// };
/// ```
///
/// And the UI dispatch — `idleUrl` maps to a [NetworkVideoIdle] on
/// the widget side (or `AssetVideoIdle`, or whatever the app picks):
///
/// ```dart
/// TwaiAvatarStage(
///   session: session,
///   avatar: profile.avatar,
///   sinkFactory: platformSinkFactory,
///   idleSource: profile.idleUrl != null
///     ? NetworkVideoIdle(Uri.parse(profile.idleUrl!))
///     : const NoIdle(),
/// )
/// ```
///
/// This split (profile = data, session/widget = live objects) means
/// customer apps can define profiles in config files, ship a catalog
/// of them, hot-reload them, or fetch from a server — without any
/// widget or session lifecycle churn.
class AvatarProfile {
  const AvatarProfile({
    required this.name,
    required this.avatar,
    required this.shape,
    this.stack = AvatarStack.muse,
    this.ttsSelection = 'tts5',
    this.idleUrl,
  });

  /// Display label (menu / picker chip). Not sent on the wire.
  final String name;

  /// The Avatar the session connects to — carries pipeline avatar_id
  /// + voiceId. Same field used by every ChatSession's `connect()`.
  final Avatar avatar;

  /// Which SDK transport / rendering shape this profile uses. Drives
  /// dispatch to `MseStreamChatSession` / `PipelineV13ChatSession` /
  /// `LocalChatSession`.
  final PipelineShape shape;

  /// For MSE-hosted shape: which nginx prefix routes this session
  /// (muse vs onnx; wav2lip is retired 2026-07-17). Ignored for
  /// other shapes. Defaults to [AvatarStack.muse] — the only live
  /// production stack.
  final AvatarStack stack;

  /// TTS engine slot. Sent in the MSE handshake + /human POST.
  /// Ignored for shapes without server-side TTS (on-device etc.).
  /// Default `'tts5'` = Qwen3.
  final String ttsSelection;

  /// Optional URL for a looping muted idle-loop video to render
  /// between conversation turns. Customer app wraps into a
  /// [NetworkVideoIdle] on the widget side. Null → widget renders
  /// [NoIdle] and the pane is transparent between turns.
  final String? idleUrl;

  @override
  bool operator ==(Object other) =>
      other is AvatarProfile &&
      other.name == name &&
      other.avatar.id == avatar.id &&
      other.avatar.voiceId == avatar.voiceId &&
      other.shape == shape &&
      other.stack == stack &&
      other.ttsSelection == ttsSelection &&
      other.idleUrl == idleUrl;

  @override
  int get hashCode => Object.hash(
        name,
        avatar.id,
        avatar.voiceId,
        shape,
        stack,
        ttsSelection,
        idleUrl,
      );

  @override
  String toString() =>
      'AvatarProfile($name, avatar=${avatar.id}, shape=$shape)';
}
