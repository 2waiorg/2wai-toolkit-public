import 'dart:convert';

import 'package:http/http.dart' as http;

import 'gen_admin_errors.dart';
import 'gen_admin_types.dart';

/// Client for gen-2wai — the self-serve avatar-generation service at
/// `gen.2wai.ai`. Wraps the OTP-based auth flow, the wizard endpoints
/// (`/api/gen/*`), and the pipeline-status polling.
///
/// This is a *different backend* from the pipeline registry that
/// [AvatarAdminClient] talks to. Gen-2wai owns Postgres rows for
/// user-submitted avatars and orchestrates a 7-stage async pipeline
/// (validate → reserve credits → voice clone → footage/Wav2Lip →
/// register → smoke verify → notify) that culminates in an
/// `/ext-api/add_avatar` call against `main_service`. Once an avatar
/// is `ready` on the gen side, it also lives in the pipeline registry
/// and can be served through the normal SDK adapters.
///
/// ## Auth flow
///
/// ```dart
/// final gen = GenAdminClient(
///   baseUrl: Uri.parse('https://gen.2wai.ai'),
/// );
/// await gen.requestOtp('me@example.com');
/// // (user checks email, gets a 6-digit code)
/// final token = await gen.verifyOtp(
///   email: 'me@example.com',
///   code: '123456',
/// );
/// gen.authenticate(token);
/// final me = await gen.getMe();
/// ```
///
/// After [authenticate] the client attaches `Authorization: Bearer <token>`
/// to every request. Store the token durably (secure storage on mobile,
/// httponly cookie on web) so the operator doesn't have to re-verify on
/// every session.
class GenAdminClient {
  GenAdminClient({
    required this.baseUrl,
    http.Client? httpClient,
    String? accessToken,
  })  : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null,
        _accessToken = accessToken;

  /// Backend base URL — e.g. `https://gen.2wai.ai`. Paths are appended
  /// verbatim (no `/ext-api` prefix; gen-2wai uses `/api/gen/*` and
  /// `/api/auth/*`).
  final Uri baseUrl;

  final http.Client _http;
  final bool _ownsClient;

  String? _accessToken;

  /// The current bearer token, if any. Null before [authenticate] is
  /// called or after [clearAuth].
  String? get accessToken => _accessToken;

  /// True if a token is set and will be attached to authed requests.
  bool get isAuthenticated => _accessToken != null;

  /// Store a bearer token — call after [verifyOtp] returns, or when
  /// rehydrating a token from secure storage on app launch.
  void authenticate(String token) {
    if (token.isEmpty) {
      throw ArgumentError.value(token, 'token', 'must not be empty');
    }
    _accessToken = token;
  }

  /// Drop the stored token. Subsequent authed calls will throw
  /// [GenApiUnauthorizedException]. Use on logout.
  void clearAuth() {
    _accessToken = null;
  }

  // ── Auth: OTP request / verify / me ─────────────────────────────────

  /// Request an OTP by email. Always returns void on success (200) —
  /// the server intentionally does not distinguish "new email" from
  /// "existing user" to avoid enumeration. On non-200 throws.
  Future<void> requestOtp(String email) async {
    await _postJson('/api/auth/request-otp', {'email': email}, authed: false);
  }

  /// Verify an OTP code and return an access token. Throws
  /// [GenApiUnauthorizedException] on wrong/expired/too-many-attempts.
  /// The returned token is NOT stored on the client automatically —
  /// callers should [authenticate] it (allowing them to persist it
  /// however they choose first).
  Future<String> verifyOtp({
    required String email,
    required String code,
  }) async {
    final json = await _postJson(
      '/api/auth/verify-otp',
      {'email': email, 'code': code},
      authed: false,
    );
    final token = json['access_token'];
    if (token is! String || token.isEmpty) {
      throw GenApiTransportException(
        cause: StateError('expected string access_token, got $token'),
        message: 'Malformed verify-otp response',
      );
    }
    return token;
  }

  /// Return the current authenticated user.
  Future<GenUser> getMe() async {
    final json = await _getJson('/api/auth/me');
    return GenUser.fromJson(json);
  }

  // ── Wizard: name check / uploads / submissions ──────────────────────

  /// Check whether an avatar name is available for the current user
  /// and return the normalized form (what the server will store).
  Future<GenNameCheck> checkName(String avatarname) async {
    final json = await _getJson(
      '/api/gen/name-check',
      query: {'avatarname': avatarname},
    );
    return GenNameCheck.fromJson(json);
  }

  /// Mint an Azure Blob SAS URL the caller can PUT asset bytes to.
  /// [kind] selects `idle` (idle-loop MP4), `talking` (talking-source
  /// MP4), `voice` (reference audio WAV), or `all` to get every URL
  /// at once. Returns the target URL + the blob path to reference
  /// back to the server when creating a submission.
  Future<GenSasResponse> uploadSas({required GenAssetKind kind}) async {
    final json = await _postJson('/api/gen/uploads/sas', {'kind': kind.wire});
    return GenSasResponse.fromJson(json);
  }

  /// Create a submission — kicks off the 7-stage pipeline. Requires
  /// consent to be attested (matches the server's 422 rule); if you
  /// omit or set `consentAttested: false` the server will reject.
  ///
  /// [form] is the personality/backstory dict passed through to the
  /// brain scaffolder. [assetRefs] is the blob-path map returned by
  /// [uploadSas] calls (`{idle_blob, talking_blob, voice_blob}`).
  Future<GenSubmissionResult> createSubmission({
    required String avatarname,
    Map<String, dynamic> form = const {},
    Map<String, dynamic> assetRefs = const {},
    bool consentAttested = true,
  }) async {
    final json = await _postJson('/api/gen/submissions', {
      'avatarname': avatarname,
      'form': form,
      'asset_refs': assetRefs,
      'consent_attested': consentAttested,
    });
    return GenSubmissionResult.fromJson(json);
  }

  /// List the current user's avatars, newest first.
  Future<List<GenAvatarSummary>> listAvatars() async {
    final json = await _getJson('/api/gen/avatars');
    final data = json['avatars'];
    if (data is! List) {
      throw GenApiTransportException(
        cause: StateError('expected list in "avatars", got $data'),
        message: 'Malformed /api/gen/avatars response',
      );
    }
    return [
      for (final a in data.cast<Map<String, dynamic>>())
        GenAvatarSummary.fromJson(a),
    ];
  }

  /// Poll submission status by submission id. Same payload shape as
  /// [avatarStatus] — pick whichever id you have on hand (the wizard
  /// starts with submissionId; the dashboard uses rid).
  Future<GenSubmissionStatus> submissionStatus(int submissionId) async {
    final json =
        await _getJson('/api/gen/submission/$submissionId/status');
    return GenSubmissionStatus.fromJson(json);
  }

  /// Poll submission status by avatar rid — convenient for pages
  /// keyed on the avatar (dashboard resume, progress page).
  Future<GenSubmissionStatus> avatarStatus(String rid) async {
    final json = await _getJson('/api/gen/avatars/$rid/status');
    return GenSubmissionStatus.fromJson(json);
  }

  /// Fetch the stored persona + configured/status flags for the
  /// personality-edit form.
  Future<GenBrainConfig> getBrain(String rid) async {
    final json = await _getJson('/api/gen/avatars/$rid/brain');
    return GenBrainConfig.fromJson(json);
  }

  /// Save the persona and kick off the (slow) brain scaffold. Returns
  /// immediately with `brainStatus=configuring`; poll [avatarStatus]
  /// to observe the ~30-180s scaffold completing.
  Future<void> putBrain({
    required String rid,
    required Map<String, dynamic> persona,
  }) async {
    await _putJson('/api/gen/avatars/$rid/brain', {'persona': persona});
  }

  /// Delete an avatar the user no longer wants. Tears down the brain
  /// + blob assets; DB row is authoritative and committed first.
  /// Idempotent — a missing/non-owned avatar 404s.
  Future<void> deleteAvatar(String rid) async {
    await _deleteJson('/api/gen/avatars/$rid');
  }

  /// Mint a short-lived view token for embedding a private (Gen_)
  /// avatar. Server-side TTL is `gen_view_token_ttl_s` (default 300s
  /// per 2waiorg/gen-2wai:app/config.py:161). Callers should schedule
  /// a re-mint before expiry — `ViewTokenCredentials.setToken()`
  /// swaps the token in place without reconnecting the session.
  ///
  /// The response also includes the hydrated avatar record (same
  /// shape as `/api/gen/catalog/{owner}/{name}`), so a single call
  /// gets both the credential and the playable catalog.
  Future<GenViewToken> mintViewToken({
    required String owner,
    required String avatarname,
  }) async {
    final json = await _getJson('/api/gen/view-token/$owner/$avatarname');
    return GenViewToken.fromJson(json);
  }

  /// Trigger a re-studio (re-clip pass) on an existing avatar — the
  /// gen-2wai pipeline re-renders the talking clips from the current
  /// bake without re-cloning the voice or re-scaffolding the brain.
  /// Fire-and-forget; poll [avatarStatus] to observe the re-pipeline
  /// running through its stages.
  Future<void> requestReclips(String rid) async {
    await _postJson('/api/gen/avatars/$rid/reclips', const {});
  }

  /// Upload raw bytes to an Azure Blob SAS URL returned by
  /// [uploadSas]. Uses the `x-ms-blob-type: BlockBlob` header the
  /// SAS grant expects; on non-2xx throws [GenApiTransportException]
  /// with the Azure error body.
  ///
  /// Split out from the wizard-flow methods because the SAS PUT
  /// bypasses gen-2wai entirely (the URL points at Azure Blob
  /// Storage directly) — no bearer token, no `/api/*` route.
  ///
  /// `contentType` is the MIME to declare on the upload; defaults
  /// to the reasonable choice per [GenAssetKind]:
  /// - idle / talking → `video/mp4`
  /// - voice → `audio/wav`
  Future<void> uploadBytes({
    required Uri uploadUrl,
    required List<int> bytes,
    String contentType = 'application/octet-stream',
  }) async {
    final http.Response resp;
    try {
      resp = await _http.put(
        uploadUrl,
        headers: {
          'x-ms-blob-type': 'BlockBlob',
          'Content-Type': contentType,
        },
        body: bytes,
      );
    } on Exception catch (e) {
      throw GenApiTransportException(
        cause: e,
        message: 'PUT $uploadUrl failed: $e',
      );
    }
    if (resp.statusCode >= 400) {
      throw GenApiTransportException(
        cause: StateError('Azure Blob PUT ${resp.statusCode}: ${resp.body}'),
        message: 'Asset upload failed (HTTP ${resp.statusCode})',
      );
    }
  }

  // ── HTTP helpers ────────────────────────────────────────────────────

  Uri _resolve(String path, {Map<String, String>? query}) {
    final base = baseUrl.resolve(path);
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: {
      ...base.queryParameters,
      ...query,
    });
  }

  Map<String, String> _headers({required bool authed, bool json = false}) {
    final h = <String, String>{};
    if (json) h['Content-Type'] = 'application/json';
    if (authed) {
      final t = _accessToken;
      if (t == null) {
        throw StateError(
          'GenAdminClient has no access token — call authenticate() first.',
        );
      }
      h['Authorization'] = 'Bearer $t';
    }
    return h;
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? query,
    bool authed = true,
  }) async {
    final url = _resolve(path, query: query);
    final http.Response resp;
    try {
      resp = await _http.get(url, headers: _headers(authed: authed));
    } on Exception catch (e) {
      throw GenApiTransportException(
        cause: e,
        message: 'GET $url failed: $e',
      );
    }
    return _decode(resp);
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body, {
    bool authed = true,
  }) async {
    final url = _resolve(path);
    final http.Response resp;
    try {
      resp = await _http.post(
        url,
        headers: _headers(authed: authed, json: true),
        body: jsonEncode(body),
      );
    } on Exception catch (e) {
      throw GenApiTransportException(
        cause: e,
        message: 'POST $url failed: $e',
      );
    }
    return _decode(resp);
  }

  Future<Map<String, dynamic>> _putJson(
    String path,
    Map<String, dynamic> body, {
    bool authed = true,
  }) async {
    final url = _resolve(path);
    final http.Response resp;
    try {
      resp = await _http.put(
        url,
        headers: _headers(authed: authed, json: true),
        body: jsonEncode(body),
      );
    } on Exception catch (e) {
      throw GenApiTransportException(
        cause: e,
        message: 'PUT $url failed: $e',
      );
    }
    return _decode(resp);
  }

  Future<Map<String, dynamic>> _deleteJson(
    String path, {
    bool authed = true,
  }) async {
    final url = _resolve(path);
    final http.Response resp;
    try {
      resp = await _http.delete(url, headers: _headers(authed: authed));
    } on Exception catch (e) {
      throw GenApiTransportException(
        cause: e,
        message: 'DELETE $url failed: $e',
      );
    }
    return _decode(resp);
  }

  Map<String, dynamic> _decode(http.Response resp) {
    if (resp.statusCode >= 400) {
      final detail = _extractDetail(resp.body);
      throw switch (resp.statusCode) {
        401 => GenApiUnauthorizedException(body: resp.body, detail: detail),
        402 =>
          GenApiInsufficientCreditsException(body: resp.body, detail: detail),
        403 => GenApiForbiddenException(body: resp.body, detail: detail),
        404 => GenApiNotFoundException(body: resp.body, detail: detail),
        422 => GenApiValidationException(body: resp.body, detail: detail),
        429 => GenApiRateLimitedException(body: resp.body, detail: detail),
        _ => GenApiHttpException(
            statusCode: resp.statusCode,
            body: resp.body,
            detail: detail,
          ),
      };
    }
    final Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('Expected JSON object, got ${decoded.runtimeType}');
      }
      json = decoded;
    } on FormatException catch (e) {
      throw GenApiTransportException(
        cause: e,
        message: 'Could not parse response: ${resp.body}',
      );
    }
    return json;
  }

  /// Try to pull FastAPI's `{"detail": "..."}` off an error body. If
  /// the body isn't JSON or has no detail, returns null and the raw
  /// body is surfaced via the exception's `body` field.
  static String? _extractDetail(String body) {
    if (body.isEmpty) return null;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded['detail'] is String) {
        return decoded['detail'] as String;
      }
    } catch (_) {
      // Non-JSON error body — nothing more to extract.
    }
    return null;
  }

  /// Release the internal HTTP client (if we created it).
  void close() {
    if (_ownsClient) _http.close();
  }
}
