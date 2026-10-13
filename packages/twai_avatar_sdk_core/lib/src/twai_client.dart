import 'package:http/http.dart' as http;

import 'adapters/mse_stream/mse_stream_chat_session.dart';
import 'adapters/mse_stream/mse_stream_client.dart' show WebSocketChannelFactory;
import 'adapters/pipeline_v13/pipeline_v13_chat_session.dart';
import 'adapters/twai_api/twai_api_chat_session.dart';
import 'adapters/twai_api/twai_api_client.dart';
import 'admin/avatar_admin_client.dart';
import 'credentials.dart';
import 'environment.dart';

/// The 2wai SDK's entry point — a single object representing one
/// tenant's authenticated handle to the 2wai backend.
///
/// Everything else in the SDK flows from a [TwaiClient]:
///
/// ```dart
/// final twai = TwaiClient(
///   env: TwaiEnvironment.named('2wai-prod'),
///   publishableKey: 'pk_live_xxx',
///   secretKey: 'sk_live_xxx',           // optional, server-side only
/// );
///
/// // Chat session pre-wired with this tenant's env + publishable key
/// final session = twai.mseStreamSession(ttsSelection: 'tts5');
/// await session.connect(Avatar(id: 'jesus', voiceId: '...'));
///
/// // Admin client pre-wired with this tenant's secret key
/// final admin = twai.admin(developerMode: true);
/// await admin.readyAvatars();
///
/// twai.close();
/// ```
///
/// One [TwaiClient] = one tenant. A server-side integration proxying
/// multiple customers holds N clients.
///
/// **Key-scope safety:** [admin] throws if [secretKey] was null at
/// construction, so a publishable-only client (e.g. one initialized
/// from browser-visible config) can't accidentally hand admin power
/// to the wrong layer.
///
/// **Resource sharing:** every session and admin call produced from
/// this client shares a single [http.Client] for connection pooling.
/// Call [close] once when the tenant is fully done with the SDK; the
/// shared client is released then. Sessions created from this client
/// will not close the shared client themselves on their own `close()`.
///
/// Future per-tenant features (priority lanes, region routing,
/// resource quotas, telemetry attribution) will hang off this class —
/// growing the [TwaiClient] API is the only thing customers have to
/// learn as the SDK gains capabilities.
class TwaiClient {
  TwaiClient({
    required this.env,
    this.publishableKey,
    this.secretKey,
    TwaiCredentials? credentials,
    http.Client? httpClient,
    WebSocketChannelFactory? channelFactory,
  })  : _http = httpClient ?? http.Client(),
        _ownsHttp = httpClient == null,
        _channelFactory = channelFactory,
        // Explicit credentials win. Otherwise the flat publishableKey
        // constructs a default PublicKeyCredentials so existing
        // callers keep working. Null credentials + null key falls back
        // to anonymous.
        credentials = credentials ??
            (publishableKey != null && publishableKey.isNotEmpty
                ? PublicKeyCredentials(publishableKey)
                : const AnonymousCredentials());

  /// Backend environment (which baseUrl to talk to). Held verbatim so
  /// `client.env.name` is available for diagnostics / stats panels.
  final TwaiEnvironment env;

  /// Chat-scope key (safe to ship in browser HTML). Threaded into every
  /// chat session produced from this client. Null = anonymous chat.
  final String? publishableKey;

  /// Admin-scope key (server-side only — NEVER ship in browser HTML).
  /// Required for [admin]; null leaves [admin] unavailable.
  final String? secretKey;

  /// Resolved chat-scope credentials. Non-null; defaults to
  /// [AnonymousCredentials] when nothing was provided. Every chat
  /// session produced from this client inherits these; new
  /// TwaiCredentials-aware callers can override per-session in the
  /// future.
  final TwaiCredentials credentials;

  final http.Client _http;
  final bool _ownsHttp;
  final WebSocketChannelFactory? _channelFactory;
  bool _closed = false;

  /// Open a new Adapter 1 (MSE-over-WS) chat session bound to this
  /// tenant. Returned session is unconnected — call `connect(avatar)`
  /// next. Multiple sessions per client are fine (e.g. one per end-user
  /// in a server-side proxy).
  MseStreamChatSession mseStreamSession({
    required String ttsSelection,
    String? userId,
    String? sessionId,
    String pathPrefix = '/ext-api',
  }) {
    _checkOpen();
    return MseStreamChatSession(
      baseUrl: env.baseUrl,
      ttsSelection: ttsSelection,
      userId: userId,
      publishableKey: publishableKey,
      sessionId: sessionId,
      pathPrefix: pathPrefix,
      httpClient: _http,
      channelFactory: _channelFactory,
    );
  }

  /// Open a new Adapter 2 (v1.3 `POST /chat`) chat session bound to
  /// this tenant.
  PipelineV13ChatSession pipelineV13Session() {
    _checkOpen();
    return PipelineV13ChatSession(
      baseUrl: env.baseUrl,
      publishableKey: publishableKey,
      httpClient: _http,
    );
  }

  /// Open a new Adapter 4 (twai-api `/v1/*`) chat session bound to this
  /// tenant.
  ///
  /// This factory covers the **dev direct** mode: the SDK holds an
  /// `sk_` key (via [secretKey] on this client) and calls the twai-api
  /// gateway directly. That path is only appropriate for prototypes,
  /// internal tools, and Mason's own dev harnesses — an sk_ in a
  /// browser is per-user compromise.
  ///
  /// For prod **split-plane** deployments, construct a
  /// [TwaiApiRestClient] pointed at your own mint-proxy server and
  /// pass it to [TwaiApiChatSession] directly — bypass this factory.
  /// Step 5 (`apps/twai_api_starter`) ships reference proxies.
  ///
  /// Optional [brain] callback: when provided, the SDK invokes it on
  /// every [ChatSession.sendMessage] to turn user text into the reply
  /// the avatar should speak (via `POST /v1/sessions/{sid}/speak`).
  /// When omitted, the avatar echoes the sent text verbatim — useful
  /// for demos, scripted tours, and TTS-endpoint-style integrations.
  TwaiApiChatSession apiSession({
    TwaiBrainCallback? brain,
    TwaiStreamingBrainCallback? streamingBrain,
  }) {
    _checkOpen();
    final sk = secretKey;
    if (sk == null || sk.isEmpty) {
      throw StateError(
        'TwaiClient.apiSession() requires secretKey (an sk_ key) at '
        'construction. For prod split-plane, construct TwaiApiChatSession '
        'directly with a mint-proxy TwaiApiRestClient.',
      );
    }
    final rest = TwaiApiRestClient(
      baseUrl: env.baseUrl,
      credentials: TwaiApiKeyCredentials.devOnly(sk),
      httpClient: _http,
    );
    return TwaiApiChatSession(
      restClient: rest,
      brain: brain,
      streamingBrain: streamingBrain,
      channelFactory: _channelFactory,
    );
  }

  /// Admin client for the avatar registry. Requires both:
  ///   - [secretKey] set at TwaiClient construction
  ///   - explicit `developerMode: true` — kept from the old API as a
  ///     guard against accidentally wiring admin into production code
  ///
  /// Throws [StateError] if [secretKey] is null. Use a separate
  /// server-side [TwaiClient] with `sk_live_...` for any admin work;
  /// never put a secret key in browser-visible config.
  AvatarAdminClient admin({required bool developerMode}) {
    _checkOpen();
    final key = secretKey;
    if (key == null) {
      throw StateError(
        'TwaiClient.admin requires secretKey at construction. '
        'For browser-side embeds, use a publishable key only; for '
        'server-side admin, construct a separate TwaiClient with '
        'sk_live_... — never ship a secret key to a browser.',
      );
    }
    return AvatarAdminClient(
      baseUrl: env.baseUrl,
      developerMode: developerMode,
      secretKey: key,
      httpClient: _http,
    );
  }

  /// Release the shared [http.Client] (when this TwaiClient owns it).
  /// Sessions created from this client are independent — their own
  /// `close()` does not need this; but their HTTP requests will start
  /// failing after [close] runs.
  ///
  /// Idempotent. No-op if a customer-provided [http.Client] was passed
  /// at construction — that client's lifecycle is the caller's.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsHttp) _http.close();
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('TwaiClient.close() has been called on this instance');
    }
  }
}
