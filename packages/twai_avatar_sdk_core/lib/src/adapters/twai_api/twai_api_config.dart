/// Value types for the twai-api (`/v1/*`) wire.
///
/// The gateway (`c:\Dev\twai-api`) is a pure REST + WS relay: it holds no
/// LLM, no per-turn state — it mints sessions, ships fMP4 over WS, and
/// forwards `POST /speak` text to muse. The customer supplies the brain.
///
/// See `apps/twai_api_demo/lib/main.dart` for a zero-SDK reference that
/// exercises the same wire; this file is the SDK-side value-type layer
/// underneath that same wire.
library;

import 'dart:convert';

/// The `POST /v1/sessions` request body. Sent by the SDK (dev mode) or
/// by the customer's server (prod split-plane) to mint a new session.
///
/// The gateway currently accepts `mode: 'video'` only. `voice_id` is
/// optional — the avatar's default voice is used when omitted.
class TwaiApiSessionRequest {
  const TwaiApiSessionRequest({
    required this.avatarId,
    this.voiceId,
    this.mode = 'video',
  });

  final String avatarId;
  final String? voiceId;
  final String mode;

  Map<String, dynamic> toJson() => {
        'avatar_id': avatarId,
        'mode': mode,
        if (voiceId != null) 'voice_id': voiceId,
      };
}

/// The `POST /v1/sessions` response — the "session mint". Everything the
/// SDK needs to open a WS and start streaming.
///
/// In prod split-plane, this exact shape is what a customer's mint-proxy
/// returns to the SDK (verbatim passthrough from the gateway's response).
class TwaiApiSessionMint {
  const TwaiApiSessionMint({
    required this.sessionId,
    required this.clientToken,
    required this.websocketUrl,
    this.transport,
  });

  /// Server-assigned session id — used on all subsequent control-plane
  /// calls (`/speak`, `/interrupt`, `DELETE`).
  final String sessionId;

  /// Short-TTL (default 3600s) HS256 JWT the SDK sends as `?token=` on
  /// the WS URL. Not needed for HTTP calls — those use the server key.
  final String clientToken;

  /// Fully-qualified WebSocket URL, `client_token` already appended as
  /// `?token=`. The SDK connects to this verbatim.
  final Uri websocketUrl;

  /// Opaque server hint (e.g. `'ws_v1'`) — logged for diagnostics.
  final String? transport;

  factory TwaiApiSessionMint.fromJson(Map<String, dynamic> json) {
    final wsUrlRaw = json['websocket_url'];
    if (wsUrlRaw is! String) {
      throw const FormatException('missing websocket_url');
    }
    return TwaiApiSessionMint(
      sessionId: json['session_id'] as String,
      clientToken: json['client_token'] as String,
      websocketUrl: Uri.parse(wsUrlRaw),
      transport: json['transport'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'client_token': clientToken,
        'websocket_url': websocketUrl.toString(),
        if (transport != null) 'transport': transport,
      };

  @override
  String toString() =>
      'TwaiApiSessionMint(sessionId=$sessionId, ws=$websocketUrl)';
}

/// Handy JSON body builder for `POST /v1/sessions/{sid}/speak`.
String speakBodyJson(String text, {String? voiceId}) => jsonEncode({
      'text': text,
      if (voiceId != null) 'voice_id': voiceId,
    });

// -------------------------------------------------------------------------
// LiveKit transport (Adapter 5) — POST /v1/sessions {transport: "livekit"}
// -------------------------------------------------------------------------

/// `POST /v1/sessions` body variant that requests the LiveKit transport.
///
/// Same endpoint as [TwaiApiSessionRequest], different `transport`
/// field. The response envelope differs — see [TwaiApiLiveKitMint].
///
/// `userId` is the brain-scoped opaque identifier; passing the same
/// value across sessions gives the brain memory continuity for that
/// end-user. Null = the gateway synthesises a per-session id (no
/// memory).
class TwaiApiLiveKitSessionRequest {
  const TwaiApiLiveKitSessionRequest({
    required this.avatarId,
    this.voiceId,
    this.userId,
    this.mode = 'video',
  });

  final String avatarId;
  final String? voiceId;
  final String? userId;
  final String mode;

  Map<String, dynamic> toJson() => {
        'avatar_id': avatarId,
        'mode': mode,
        'transport': 'livekit',
        if (voiceId != null) 'voice_id': voiceId,
        if (userId != null) 'user_id': userId,
      };
}

/// `POST /v1/sessions` response for `transport: "livekit"`.
///
/// The SDK hands these fields to `livekit_client`:
///   `Room().connect(livekitUrl, participantToken)`
///
/// The gateway's `agent_identity` hint tells the client which
/// participant is the avatar-serving agent (identity prefix pattern:
/// `livealman-agent-*`) so track subscribes from other participants
/// (e.g. observability sidecars) are ignored.
class TwaiApiLiveKitMint {
  const TwaiApiLiveKitMint({
    required this.sessionId,
    required this.livekitUrl,
    required this.roomName,
    required this.participantToken,
    this.agentIdentity,
  });

  final String sessionId;
  final Uri livekitUrl;
  final String roomName;
  final String participantToken;
  final String? agentIdentity;

  factory TwaiApiLiveKitMint.fromJson(Map<String, dynamic> json) {
    final urlRaw = json['livekit_url'];
    if (urlRaw is! String) {
      throw const FormatException('missing livekit_url');
    }
    return TwaiApiLiveKitMint(
      sessionId: json['session_id'] as String,
      livekitUrl: Uri.parse(urlRaw),
      roomName: json['room_name'] as String,
      participantToken: json['participant_token'] as String,
      agentIdentity: json['agent_identity'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
        'session_id': sessionId,
        'transport': 'livekit',
        'livekit_url': livekitUrl.toString(),
        'room_name': roomName,
        'participant_token': participantToken,
        if (agentIdentity != null) 'agent_identity': agentIdentity,
      };

  @override
  String toString() =>
      'TwaiApiLiveKitMint(sessionId=$sessionId, room=$roomName)';
}

// ── Catalog hydrate ─────────────────────────────────────────────────────
//
// `GET /v1/avatars/{owner}/{name}` — resolve an avatar by (owner, name)
// to a playable record. See docs/catalog_hydrate_plan.md for the full
// design + the gateway contract.
//
// The gateway proxies gen-2wai's `GET /api/gen/avatar-page/{owner}/{name}`
// (slim developer-facing shape), strips social fields, enriches the
// greeting payload with id/kind/consumption_key from the richer
// internal catalog row, and (for private avatars owned by the
// authenticating sk_ tenant) also mints and returns a view token so
// the SDK can authenticate subsequent session mints.
//
// Owner slug convention: `"2wai"` for house avatars (per gen-2wai's
// `HOUSE_OWNER` constant); lowercase, URL-safe, hyphen-separated for
// user- and enterprise-owned avatars.

/// Response from `GET /v1/avatars/{owner}/{name}`. Wraps the hydrated
/// [TwaiApiAvatar] and (for private tenant-owned avatars) a
/// [ViewTokenCredentials] the consumer should use when minting the
/// session for this avatar.
class TwaiApiAvatarResult {
  const TwaiApiAvatarResult({required this.avatar, this.viewToken});

  final TwaiApiAvatar avatar;

  /// Non-null when the avatar is private (`avatar.listed == false`)
  /// and the authenticating `sk_` tenant owns it. Pass to the next
  /// session mint — e.g. by rebuilding the [TwaiApiRestClient] with
  /// this as the `credentials:` arg, or by threading it through to
  /// the engine's mint closure. Server-side TTL defaults to 300 s;
  /// consumers that keep the token should re-mint before expiry.
  ///
  /// Null when the avatar is public — no extra auth beyond the
  /// original `sk_` is needed.
  final Object? viewToken;

  factory TwaiApiAvatarResult.fromJson(Map<String, dynamic> json) =>
      TwaiApiAvatarResult(
        avatar: TwaiApiAvatar.fromJson(
            (json['avatar'] as Map).cast<String, dynamic>()),
        // Deliberately `Object?` + late typing: `ViewTokenCredentials`
        // lives in credentials.dart (same package) but importing it
        // here would create a wide import surface for the common case
        // (public avatar, no view token). The sdk-layer caller that
        // actually consumes the token performs the cast — see
        // `TwaiApiRestClient.getAvatar` wrapper for the typed shape.
        viewToken: json['view_token'],
      );
}

/// Hydrated avatar record. Shape is explicitly minimal — the gateway
/// strips gen-2wai's internal viewer fields (`delivery`, `chatEncoding`,
/// `lipsync_engine`, `brain_model`, `brain_avatar`, `media` manifest,
/// `actions`, `gestures`, `outfits[]` variants, `tagline`) and social
/// / UGC fields (`description`, `topics`, `likeCount`, `likedByMe`,
/// `shareUrl`, `publicName`, `house`, `ownerDisplay`).
///
/// Everything the SDK needs for playback is here:
///   - [avatarId] is the ONLY mint input (server resolves profile +
///     default voice from it).
///   - [idleUrl] / [posterUrl] are signed URLs (12 h TTL from gen-2wai's
///     SAS tokens). Nullable because gen-2wai's `AvatarPage` carries
///     them nullable.
///   - [greeting] is non-null when the server has an active greeting
///     configured. Pass to `TwaiGreeting.fromCatalog(greeting)` for
///     one-line Phase-2 integration.
class TwaiApiAvatar {
  const TwaiApiAvatar({
    required this.owner,
    required this.name,
    required this.displayName,
    required this.avatarId,
    required this.listed,
    this.idleUrl,
    this.posterUrl,
    this.greeting,
  });

  /// Owner slug — `"2wai"` for house avatars, lowercase handle for
  /// user- and enterprise-owned avatars.
  final String owner;

  /// URL-safe avatar handle under [owner] — e.g. `"brian-alman"`,
  /// `"krystal-casual"`.
  final String name;

  /// Human-facing display name — e.g. `"Dr. Brian Alman"`, `"Krystal"`.
  final String displayName;

  /// The `avt_*` record id. Pass to
  /// [TwaiApiLiveKitSessionRequest.avatarId] on the next mint.
  final String avatarId;

  /// True when the avatar is on gen-2wai's public catalog. False for
  /// unlisted / private avatars — in that case the containing
  /// [TwaiApiAvatarResult.viewToken] is non-null.
  final bool listed;

  /// Signed MP4 URL for the looping idle video. Nullable per gen-2wai.
  final Uri? idleUrl;

  /// Signed JPG URL for the idle's first frame. Nullable per gen-2wai.
  final Uri? posterUrl;

  /// Active greeting, or null when the avatar has none configured.
  final TwaiApiGreetingPayload? greeting;

  factory TwaiApiAvatar.fromJson(Map<String, dynamic> json) => TwaiApiAvatar(
        owner: json['owner'] as String,
        name: json['name'] as String,
        displayName: json['display_name'] as String,
        avatarId: json['avatar_id'] as String,
        listed: json['listed'] as bool,
        idleUrl: _parseUriOrNull(json['idle_url']),
        posterUrl: _parseUriOrNull(json['poster_url']),
        greeting: json['greeting'] is Map
            ? TwaiApiGreetingPayload.fromJson(
                (json['greeting'] as Map).cast<String, dynamic>())
            : null,
      );

  Map<String, dynamic> toJson() => {
        'owner': owner,
        'name': name,
        'display_name': displayName,
        'avatar_id': avatarId,
        'listed': listed,
        if (idleUrl != null) 'idle_url': idleUrl.toString(),
        if (posterUrl != null) 'poster_url': posterUrl.toString(),
        if (greeting != null) 'greeting': greeting!.toJson(),
      };

  @override
  String toString() =>
      'TwaiApiAvatar(owner=$owner, name=$name, avatarId=$avatarId, listed=$listed)';
}

/// Hydrated greeting payload — matches the shape that
/// `TwaiGreeting.fromCatalog(payload)` in the Flutter SDK consumes
/// one-line.
///
/// Wire kind is `"intro"` or `"return"` (gen-2wai convention). The
/// Flutter adapter maps `"return"` to `GreetingKind.returning`
/// (because `return` is a reserved Dart keyword).
class TwaiApiGreetingPayload {
  const TwaiApiGreetingPayload({
    required this.id,
    required this.videoUrl,
    required this.text,
    required this.kind,
    this.consumptionKey,
  });

  /// Gateway-synthesised id (either `grt_*` for intro, `rg_*` for
  /// returning). Opaque to the SDK; useful for host-side analytics
  /// correlation.
  final String id;

  /// Signed MP4 URL for the pre-rendered greeting video.
  final Uri videoUrl;

  /// The script the greeting speaks — displayable as a caption /
  /// transcript.
  final String text;

  /// Wire kind: `"intro"` (first-visit) or `"return"` (return visit).
  /// String rather than an enum so the core adapter stays enum-free;
  /// the Flutter SDK converts to [GreetingKind] in
  /// `TwaiGreeting.fromCatalog`.
  final String kind;

  /// gen-2wai's `rg-{id}-{epoch}` hand-off key — present only when
  /// [kind] is `"return"`. Pass back to the server's `POST
  /// /v1/greetings/played` route when the greeting plays audibly, so
  /// the server marks it consumed and does not serve it again.
  final String? consumptionKey;

  factory TwaiApiGreetingPayload.fromJson(Map<String, dynamic> json) =>
      TwaiApiGreetingPayload(
        id: json['id'] as String,
        videoUrl: Uri.parse(json['video_url'] as String),
        text: json['text'] as String,
        kind: json['kind'] as String,
        consumptionKey: json['consumption_key'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'video_url': videoUrl.toString(),
        'text': text,
        'kind': kind,
        if (consumptionKey != null) 'consumption_key': consumptionKey,
      };
}

Uri? _parseUriOrNull(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return Uri.parse(raw);
  } on FormatException {
    return null;
  }
}
