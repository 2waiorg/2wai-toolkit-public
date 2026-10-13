import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'avatar_admin_config.dart';
import 'avatar_admin_errors.dart';
import 'tts_rules.dart';

/// Client for the `main_service` admin endpoints documented in
/// `protocol.md` §4 — register, list, delete, and edit avatars.
///
/// > **SECURITY:** these endpoints are currently **unauthenticated** on
/// > the server. Anyone with network reach to the gateway can mutate
/// > the avatar registry. The client requires an explicit
/// > `developerMode: true` flag at construction so this can't be wired
/// > into a production-facing app by accident.
///
/// Endpoints reach `main_service` (port 7862) via penthouse's nginx
/// `/ext-api/` proxy. Default `pathPrefix` is `/ext-api`; override if
/// the proxy mapping changes.
///
/// Typical use — registering a new avatar:
///
/// ```dart
/// final admin = AvatarAdminClient(
///   baseUrl: Uri.parse('https://staging.coreledgergroup.com'),
///   developerMode: true,
/// );
/// await admin.addAvatar(
///   avatarId: 'RedJesusTalk1',
///   prompt: 'You are Jesus...',
///   voiceId: '<voice-uuid>',
/// );
/// admin.close();
/// ```
///
/// Note: the avatar's pipeline assets (latents, coords, source videos)
/// must already exist at `/home/azureuser/data/avatars/<avatarId>/` on
/// the worker VM before `addAvatar` is called. This client only writes
/// the DB record; it does not upload assets.
class AvatarAdminClient {
  AvatarAdminClient({
    required this.baseUrl,
    required bool developerMode,
    this.secretKey,
    this.pathPrefix = '/ext-api',
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _ownsClient = httpClient == null {
    if (!developerMode) {
      throw StateError(
        'AvatarAdminClient targets unauthenticated admin endpoints — '
        'pass developerMode: true to acknowledge.',
      );
    }
  }

  /// Base URL of the gateway (e.g. `https://staging.coreledgergroup.com`).
  final Uri baseUrl;

  /// Optional secret API key. When non-null, every request is sent with
  /// `Authorization: Bearer <secretKey>`. Backend validation is not yet
  /// in place (probed 2026-05-30 — endpoints return 200 with no auth);
  /// this is the SDK side of the plumbing. NEVER ship a secret key in
  /// browser-visible HTML — secret keys are admin-scope and intended
  /// for server-to-server use only. For browser chat embeds use the
  /// publishable key on [MseStreamChatSession] instead.
  final String? secretKey;

  /// Prefix prepended to every admin endpoint path. Default `/ext-api`
  /// (matches penthouse's nginx `/ext-api/` → `main_service` proxy).
  final String pathPrefix;

  final http.Client _http;
  final bool _ownsClient;

  Uri _uri(String endpoint) => baseUrl.resolve('$pathPrefix$endpoint');

  Map<String, String> get _authHeaders {
    final key = secretKey;
    if (key == null) return const {};
    return {'Authorization': 'Bearer $key'};
  }

  Map<String, String> get _jsonHeaders => {
        'Content-Type': 'application/json',
        ..._authHeaders,
      };

  /// `GET /query_avatar_list` — avatars with `status="ready"` for this
  /// server (matched by the gateway's calling IP). Suitable for "which
  /// avatars can I chat with right now" lists.
  Future<List<String>> readyAvatars() async {
    final json = await _get('/query_avatar_list');
    final data = json['data'];
    if (data is! List) {
      throw AvatarAdminTransportException(
        cause: StateError('expected list in "data", got $data'),
        message: 'Malformed query_avatar_list response',
      );
    }
    return data.cast<String>();
  }

  /// `GET /query_avatar` — full avatar registry, regardless of readiness.
  Future<List<AvatarMetadata>> allAvatars() async {
    final json = await _get('/query_avatar');
    final data = json['data'];
    if (data is! List) {
      throw AvatarAdminTransportException(
        cause: StateError('expected list in "data", got $data'),
        message: 'Malformed query_avatar response',
      );
    }
    try {
      return data
          .cast<Map<String, dynamic>>()
          .map(AvatarMetadata.fromJson)
          .toList();
    } catch (e) {
      throw AvatarAdminTransportException(
        cause: e,
        message: 'Could not parse avatar metadata: $e',
      );
    }
  }

  /// `POST /query_prompt` (POST despite the name) — fetch the system
  /// prompt for one avatar.
  Future<String> getPrompt(String avatarName) async {
    final json = await _postJson('/query_prompt', {'avatarName': avatarName});
    final prompt = json['chatPrompt'];
    if (prompt is! String) {
      throw AvatarAdminTransportException(
        cause: StateError('expected string "chatPrompt", got $prompt'),
        message: 'Malformed query_prompt response',
      );
    }
    return prompt;
  }

  /// `POST /add_avatar` — register a new avatar.
  ///
  /// Pipeline assets must already exist on the worker VM at
  /// `/home/azureuser/data/avatars/<avatarId>/` before this is called.
  /// The server only creates the MongoDB record; it does not download
  /// or generate assets.
  Future<AvatarMutationResult> addAvatar({
    required String avatarId,
    required String prompt,
    required String voiceId,
    bool greenBg = true,
    bool needMiddles = false,
    String? sessionId,
  }) async {
    final json = await _postJson('/add_avatar', {
      'avatar_id': avatarId,
      'prompt': prompt,
      'voice_id': voiceId,
      'green_bg': greenBg,
      'need_middles': needMiddles,
      'handle': 'add',
      if (sessionId != null) 'sessionid': sessionId,
    });
    return AvatarMutationResult.fromJson(json);
  }

  /// `POST /delete_avatar` — remove an avatar's registration.
  /// When `deletePermanent` is true the server also `rm -rf`s the
  /// asset directory on the worker VM (irreversible).
  Future<AvatarMutationResult> deleteAvatar({
    required String avatarName,
    bool deletePermanent = false,
    String? sessionId,
  }) async {
    final json = await _postJson('/delete_avatar', {
      'avatarName': avatarName,
      'deletePermanent': deletePermanent,
      if (sessionId != null) 'sessionid': sessionId,
    });
    return AvatarMutationResult.fromJson(json);
  }

  /// `POST /change_prompt` — update an avatar's system prompt.
  Future<void> changePrompt({
    required String avatarName,
    required String chatPrompt,
    String? sessionId,
  }) async {
    await _postJson('/change_prompt', {
      'avatarName': avatarName,
      'chatPrompt': chatPrompt,
      if (sessionId != null) 'sessionid': sessionId,
    });
  }

  /// `POST /change_voice_list` — bulk voice reassignment. Pass a map of
  /// `avatar_id → voice_id`.
  Future<void> changeVoiceList(Map<String, String> avatarVoiceMap) async {
    await _postJson('/change_voice_list', avatarVoiceMap);
  }

  // ── TTS pronunciation rules ─────────────────────────────────────────
  //
  // Surface for the v2 pronunciation rules engine documented in
  // `clg_penthouse_pets/docs/TTS_RULES.md` (mason/tts-global-pronunciation
  // branch). The schema is stable; the REST endpoints below are NOT yet
  // exposed by main_service as of 2026-06-27 — calls will 404 until
  // Mason wires the routes. Wiring the SDK side now so customer code +
  // admin UI (SDK-29 in roadmap_reconciliation.md) can be built against
  // a stable contract.
  //
  // Endpoint convention (proposed; finalize with Mason at backend time):
  //   GET    /ext-api/tts/rules?scope=…&stage=…
  //   POST   /ext-api/tts/rules
  //   PUT    /ext-api/tts/rules/<id>
  //   DELETE /ext-api/tts/rules/<id>
  //   POST   /ext-api/tts/audition
  //
  // All wrap the standard {code, data, …} envelope used by every other
  // admin endpoint (`_decodeAndValidate` throws AvatarAdminProtocolException
  // on code != 0).

  /// List pronunciation rules. Filter by [scope] (e.g. `app:candy-ai`),
  /// [stage] (`brain_normalize` or `tts_prepass`), or both. With no
  /// filter, returns the server's default view (typically the caller's
  /// tenant scope + global). See [TtsRule] for the returned shape.
  Future<List<TtsRule>> listRules({
    TtsRuleScope? scope,
    TtsRuleStage? stage,
  }) async {
    final query = <String, String>{
      if (scope != null) 'scope': scope.value,
      if (stage != null) 'stage': stage.wire,
    };
    final json = await _get('/tts/rules', query: query.isEmpty ? null : query);
    final data = json['data'];
    if (data is! List) {
      throw AvatarAdminTransportException(
        cause: StateError('expected list in "data", got $data'),
        message: 'Malformed /tts/rules response',
      );
    }
    try {
      return data
          .cast<Map<String, dynamic>>()
          .map(TtsRule.fromJson)
          .toList();
    } catch (e) {
      throw AvatarAdminTransportException(
        cause: e,
        message: 'Could not parse TTS rules: $e',
      );
    }
  }

  /// Create a new rule. The submitted [rule] should have a null `id` —
  /// the server assigns one and returns the persisted rule in `data`.
  Future<TtsRule> addRule(TtsRule rule) async {
    final json = await _postJson('/tts/rules', rule.toJson());
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw AvatarAdminTransportException(
        cause: StateError('expected map in "data", got $data'),
        message: 'Malformed /tts/rules POST response',
      );
    }
    try {
      return TtsRule.fromJson(data);
    } catch (e) {
      throw AvatarAdminTransportException(
        cause: e,
        message: 'Could not parse created TTS rule: $e',
      );
    }
  }

  /// Replace an existing rule by id. PUT semantics — the rule body sent
  /// becomes the new persisted state (no patching). Server returns the
  /// updated rule.
  Future<TtsRule> updateRule(String id, TtsRule rule) async {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    final json = await _putJson('/tts/rules/$id', rule.copyWith(id: id).toJson());
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw AvatarAdminTransportException(
        cause: StateError('expected map in "data", got $data'),
        message: 'Malformed /tts/rules PUT response',
      );
    }
    try {
      return TtsRule.fromJson(data);
    } catch (e) {
      throw AvatarAdminTransportException(
        cause: e,
        message: 'Could not parse updated TTS rule: $e',
      );
    }
  }

  /// Delete a rule by id. Irreversible from the client side; rule lookup
  /// returns 404 thereafter. (Server may keep it in an audit log; that's
  /// the server's concern.)
  Future<void> deleteRule(String id) async {
    if (id.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    await _delete('/tts/rules/$id');
  }

  /// Synthesize [phrase] against the TTS engine with the current ruleset
  /// (optionally overlaid with [candidateRules] for "preview this change
  /// before saving"). Returns audio bytes the caller can drop into an
  /// `<audio>` element + the STT-back transcription for divergence
  /// review. See [TtsAuditionResult] for the returned shape.
  ///
  /// This wraps the same synth-and-score primitive Mason's `tts_harness`
  /// uses in its discover/correct loop, exposed as a single REST call so
  /// admin UIs don't need to vendor the harness.
  Future<TtsAuditionResult> auditionPhrase({
    required String phrase,
    String? voiceId,
    String? ttsSelection,
    List<TtsRule>? candidateRules,
  }) async {
    final body = <String, dynamic>{
      'phrase': phrase,
      if (voiceId != null) 'voiceId': voiceId,
      if (ttsSelection != null) 'ttsSelection': ttsSelection,
      if (candidateRules != null)
        'candidateRules': candidateRules.map((r) => r.toJson()).toList(),
    };
    final json = await _postJson('/tts/audition', body);
    final data = json['data'];
    if (data is! Map<String, dynamic>) {
      throw AvatarAdminTransportException(
        cause: StateError('expected map in "data", got $data'),
        message: 'Malformed /tts/audition response',
      );
    }
    try {
      return TtsAuditionResult.fromJson(data);
    } catch (e) {
      throw AvatarAdminTransportException(
        cause: e,
        message: 'Could not parse audition result: $e',
      );
    }
  }

  // ── HTTP helpers ────────────────────────────────────────────────────

  Uri _uriWithQuery(String endpoint, Map<String, String>? query) {
    final base = _uri(endpoint);
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: {
      ...base.queryParameters,
      ...query,
    });
  }

  Future<Map<String, dynamic>> _get(
    String endpoint, {
    Map<String, String>? query,
  }) async {
    final url = _uriWithQuery(endpoint, query);
    final http.Response resp;
    try {
      resp = await _http.get(url, headers: _authHeaders);
    } on Exception catch (e) {
      throw AvatarAdminTransportException(
        cause: e,
        message: 'GET $url failed: $e',
      );
    }
    return _decodeAndValidate(resp);
  }

  Future<Map<String, dynamic>> _postJson(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final http.Response resp;
    try {
      resp = await _http.post(
        _uri(endpoint),
        headers: _jsonHeaders,
        body: jsonEncode(body),
      );
    } on Exception catch (e) {
      throw AvatarAdminTransportException(
        cause: e,
        message: 'POST ${_uri(endpoint)} failed: $e',
      );
    }
    return _decodeAndValidate(resp);
  }

  Future<Map<String, dynamic>> _putJson(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final http.Response resp;
    try {
      resp = await _http.put(
        _uri(endpoint),
        headers: _jsonHeaders,
        body: jsonEncode(body),
      );
    } on Exception catch (e) {
      throw AvatarAdminTransportException(
        cause: e,
        message: 'PUT ${_uri(endpoint)} failed: $e',
      );
    }
    return _decodeAndValidate(resp);
  }

  Future<Map<String, dynamic>> _delete(String endpoint) async {
    final http.Response resp;
    try {
      resp = await _http.delete(_uri(endpoint), headers: _authHeaders);
    } on Exception catch (e) {
      throw AvatarAdminTransportException(
        cause: e,
        message: 'DELETE ${_uri(endpoint)} failed: $e',
      );
    }
    return _decodeAndValidate(resp);
  }

  Map<String, dynamic> _decodeAndValidate(http.Response resp) {
    if (resp.statusCode >= 400) {
      throw switch (resp.statusCode) {
        401 => AvatarAdminUnauthorizedException(body: resp.body),
        403 => AvatarAdminForbiddenException(body: resp.body),
        429 => AvatarAdminRateLimitedException(body: resp.body),
        _ => AvatarAdminHttpException(
            statusCode: resp.statusCode,
            body: resp.body,
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
      throw AvatarAdminTransportException(
        cause: e,
        message: 'Could not parse response: ${resp.body}',
      );
    }
    final code = json['code'];
    if (code is! int || code != 0) {
      throw AvatarAdminProtocolException(
        code: code is int ? code : -1,
        data: json['data'] as String? ?? json['msg'] as String?,
        message: 'Server returned code=$code',
      );
    }
    return json;
  }

  /// Release the internal HTTP client (if we created it).
  void close() {
    if (_ownsClient) _http.close();
  }
}
