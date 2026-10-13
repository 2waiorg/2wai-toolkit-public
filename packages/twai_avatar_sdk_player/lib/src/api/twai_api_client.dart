import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart';

import '../gesture.dart';
import 'avatar_catalog.dart';
import 'twai_api_types.dart';

/// HTTP client for the reference server's `/api/*` surface — the
/// user-scoped authenticated endpoints alongside the pipeline WS.
///
/// This is the second half of what `TwaiPlayerHandle` handles for
/// developers: alongside the pipeline session (streaming, mood
/// headers, chat gateway) the reference makes a fanout of
/// `/api/gamification/*` + `/api/avatars/{slug}/*` calls that shape
/// the user's experience (XP, level-ups, gestures / frames catalog,
/// initial progress state).
///
/// Every endpoint on this client silently returns `null` (or an
/// empty list) on HTTP / network error — the reference player fails
/// open on these because they're auxiliary. If a customer needs
/// hard failures, they wrap the client at their layer.
///
/// # Endpoints modeled
///
/// - `GET /api/gamification/progress/avatar/{slug}` — initial
///   [PetProgress]
/// - `POST /api/gamification/award-message` — XP + level in one
///   payload ([AwardMessageResponse])
/// - `POST /api/gamification/record-assistant-message` — audit-only
/// - `GET /api/avatars/{slug}/state-block` — brain context block
/// - `GET /api/avatars/{slug}/gestures` — emote catalog
/// - `GET /api/avatars/{slug}/frames` — frame catalog
class TwaiApiClient {
  TwaiApiClient({
    required this.baseUrl,
    this.authToken,
    TwaiCredentials? credentials,
    http.Client? httpClient,
    this.requestTimeout = const Duration(seconds: 3),
  })  : _http = httpClient ?? http.Client(),
        // Explicit credentials win; otherwise fold the flat
        // [authToken] into a [BearerJwtCredentials]. Both null =>
        // anonymous. Keeps existing `authToken:` callers working
        // while unlocking `credentials: ViewTokenCredentials(...)`
        // for gen-2wai-minted view-token flows.
        credentials = credentials ??
            (authToken != null && authToken.isNotEmpty
                ? BearerJwtCredentials(authToken)
                : const AnonymousCredentials());

  /// Origin URL — e.g. `https://staging.coreledgergroup.com`. The
  /// `/api` prefix is appended by each endpoint method. Sourced from
  /// [TwaiEnvironment.baseUrl] in the typical case.
  final Uri baseUrl;

  /// Legacy flat Bearer JWT param. Prefer [credentials] for anything
  /// beyond the plain-JWT case (view tokens, publishable keys,
  /// mixed auth). Held here for backward compatibility.
  final String? authToken;

  /// Resolved credentials the client attaches to every request. Non-
  /// null; defaults to [AnonymousCredentials] when nothing was
  /// provided. See [TwaiCredentials] for the shape.
  final TwaiCredentials credentials;

  /// Per-request timeout for every fail-open `/api/*` endpoint on
  /// this client. When a call exceeds this, the client returns the
  /// same fail-open default it would on any other error (null /
  /// empty list / void) — the caller can't tell the difference.
  ///
  /// Load-bearing for [TwaiPlayerHandle.send]: the state-block
  /// fetch is `await`ed inline before the chat POST, so a stalled
  /// endpoint would freeze the whole send loop without this
  /// timeout. Confirmed via jesus regression 2026-07-21 where
  /// staging's `/api/avatars/{slug}/state-block` didn't respond
  /// promptly and hung the facade profile's `send()`.
  ///
  /// Default 3s — comfortable for real success paths (state-block
  /// is a small GET) without letting a wedged endpoint block user
  /// input. Set higher for slow tenants; disable via
  /// `Duration(days: 999)` if you want the old blocking behavior.
  final Duration requestTimeout;

  final http.Client _http;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        ...credentials.httpHeaders(),
      };

  Uri _u(String path) => baseUrl.replace(
        path: '${baseUrl.path.replaceAll(RegExp(r'/$'), '')}$path',
      );

  /// Fetch initial [PetProgress] for [avatarSlug]. Returns `null` on
  /// network / HTTP / parse error — the reference retries up to 3× on
  /// this endpoint but with soft caps; here we just try once and let
  /// the caller (facade) retry or fall back to defaults.
  Future<PetProgress?> fetchProgress(String avatarSlug) async {
    try {
      final res = await _http
          .get(
            _u('/api/gamification/progress/avatar/$avatarSlug'),
            headers: _headers,
          )
          .timeout(requestTimeout);
      if (res.statusCode != 200) return null;
      return PetProgress.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetch the canonical avatar catalog for [avatarSlug]. Dispatches
  /// on slug shape:
  ///
  /// - `'owner/name'` (contains `/`) → gen-2wai's
  ///   `GET /api/gen/catalog/{owner}/{name}` — private per-user
  ///   avatars; requires the caller's auth token to match `owner`.
  /// - Bare slug → the pipeline's `GET /api/avatars/{slug}` — public
  ///   or shared avatars.
  ///
  /// Returns `null` on network / HTTP / parse error (fail-open, same
  /// discipline as the other endpoints on this client). Callers that
  /// care about the reason (404 vs 401 vs network) can construct
  /// their own request.
  ///
  /// **Backend gap (2026-07-19)**: the pipeline's
  /// `/api/avatars/{slug}` response omits `pipelineName` per outfit,
  /// which the SDK needs to construct the WebSocket handshake. For
  /// muse-baked avatars whose catalog comes from the pipeline (not
  /// gen-2wai), the resolver in [TwaiPlayerHandle.fromSlug] merges
  /// this thin response with the bundled `KnownAvatars` catalog. See
  /// [AvatarCatalog] docstring for the field-level story.
  Future<AvatarCatalogResponse?> fetchAvatarCatalog(String slug) async {
    final path = slug.contains('/')
        ? '/api/gen/catalog/$slug'
        : '/api/avatars/$slug';
    try {
      final res = await _http
          .get(_u(path), headers: _headers)
          .timeout(requestTimeout);
      if (res.statusCode != 200) return null;
      return AvatarCatalogResponse.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fetch the gesture (emote) catalog for [avatarSlug]. The server
  /// blanks out `video_url` on locked entries and sets `is_unlocked`
  /// per the caller's tier + level + owned kits.
  Future<List<PlayerGesture>> fetchGestures(String avatarSlug) async {
    try {
      final res = await _http
          .get(
            _u('/api/avatars/$avatarSlug/gestures'),
            headers: _headers,
          )
          .timeout(requestTimeout);
      if (res.statusCode != 200) return const [];
      final list = jsonDecode(res.body) as List<dynamic>;
      return list
          .map((e) => _gestureFromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Fetch the frame catalog for [avatarSlug].
  Future<List<PlayerFrame>> fetchFrames(String avatarSlug) async {
    try {
      final res = await _http
          .get(
            _u('/api/avatars/$avatarSlug/frames'),
            headers: _headers,
          )
          .timeout(requestTimeout);
      if (res.statusCode != 200) return const [];
      final list = jsonDecode(res.body) as List<dynamic>;
      return list
          .map((e) => _frameFromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Fetch the assembled "## Avatar state" context block for
  /// [avatarSlug]. The server returns `{ block: string }`; we return
  /// the string. This is fed inline into the brain's `POST /human`
  /// body as `avatarStateBlock`.
  Future<String?> fetchStateBlock(String avatarSlug) async {
    try {
      final res = await _http
          .get(
            _u('/api/avatars/$avatarSlug/state-block'),
            headers: _headers,
          )
          .timeout(requestTimeout);
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final block = j['block'];
      return block is String ? block : null;
    } catch (_) {
      return null;
    }
  }

  /// Fire the XP scoring for a user message. Runs server-side against
  /// a local heuristic (does NOT touch the brain), so it can run in
  /// parallel with `/human` without serial latency.
  ///
  /// Returns `null` on HTTP / network error — the reference explicitly
  /// tolerates this ("a slow XP path can never delay reply rendering,
  /// and a brain error never blocks XP feedback").
  Future<AwardMessageResponse?> awardMessage({
    required String avatarSlug,
    required String message,
  }) async {
    try {
      final res = await _http
          .post(
            _u('/api/gamification/award-message'),
            headers: _headers,
            body: jsonEncode({
              'avatar_slug': avatarSlug,
              'message': message,
            }),
          )
          .timeout(requestTimeout);
      if (res.statusCode != 200) return null;
      return AwardMessageResponse.fromJson(
        jsonDecode(res.body) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Fire-and-forget audit persistence — the reference calls this
  /// after the brain's reply text is displayed, so the assistant side
  /// of the conversation lands in `chat_messages` alongside the
  /// user's message. Never blocks the UX; errors are swallowed.
  Future<void> recordAssistantMessage({
    required String avatarSlug,
    required String reply,
  }) async {
    try {
      await _http
          .post(
            _u('/api/gamification/record-assistant-message'),
            headers: _headers,
            body: jsonEncode({
              'avatar_slug': avatarSlug,
              'message': reply,
            }),
          )
          .timeout(requestTimeout);
    } catch (_) {
      // audit-only — don't surface errors to the user
    }
  }

  /// Release the underlying HTTP client's resources. Idempotent.
  void close() => _http.close();

  // ── JSON decoders for content types defined in gesture.dart ──

  PlayerGesture _gestureFromJson(Map<String, dynamic> j) => PlayerGesture(
        id: j['id'] as String,
        slug: j['slug'] as String,
        displayName: j['display_name'] as String,
        videoUrl: (j['video_url'] as String?) ?? '',
        isUnlocked: (j['is_unlocked'] as bool?) ?? false,
        thumbnailUrl: j['thumbnail_url'] as String?,
        unlockLevel: j['unlock_level'] as int?,
        outfitSlug: j['outfit_slug'] as String?,
      );

  PlayerFrame _frameFromJson(Map<String, dynamic> j) => PlayerFrame(
        id: j['id'] as String,
        slug: j['slug'] as String,
        frameNumber: (j['frame_number'] as int?) ?? 0,
        outfitSlug: j['outfit_slug'] as String,
        unlockLevel: (j['unlock_level'] as int?) ?? 0,
        mainClipUrl: (j['main_clip_url'] as String?) ?? '',
        isUnlocked: (j['is_unlocked'] as bool?) ?? false,
        thumbnailUrl: j['thumbnail_url'] as String?,
      );
}
