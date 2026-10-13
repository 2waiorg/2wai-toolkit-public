/// Shape returned by `GET /api/auth/me`.
class GenUser {
  const GenUser({
    required this.id,
    required this.email,
    required this.username,
    required this.displayName,
    required this.credits,
    required this.subscriptionTier,
    required this.level,
  });

  final int id;
  final String email;
  final String username;
  final String displayName;

  /// Remaining credit balance. Each avatar creation costs
  /// `settings.avatar_create_cost` (30 as of 2026-07-06).
  final int credits;

  /// `"free"` / paid tier slug. Server-defined vocabulary.
  final String subscriptionTier;

  /// Gamification level, currently always 1.
  final int level;

  factory GenUser.fromJson(Map<String, dynamic> json) => GenUser(
        id: (json['id'] as num).toInt(),
        email: json['email'] as String,
        username: json['username'] as String,
        displayName: (json['display_name'] as String?) ?? json['username'] as String,
        credits: (json['credits'] as num? ?? 0).toInt(),
        subscriptionTier: (json['subscription_tier'] as String?) ?? 'free',
        level: (json['level'] as num? ?? 1).toInt(),
      );
}

/// Shape returned by `GET /api/gen/name-check`.
class GenNameCheck {
  const GenNameCheck({required this.available, required this.normalized});

  /// True if the name is not yet taken by another of *the caller's*
  /// avatars. Uniqueness is per-user, not global.
  final bool available;

  /// Server-normalized form (lowercased, punctuation stripped). Empty
  /// string when the input can't be normalized at all.
  final String normalized;

  factory GenNameCheck.fromJson(Map<String, dynamic> json) => GenNameCheck(
        available: json['available'] as bool? ?? false,
        normalized: (json['normalized'] as String?) ?? '',
      );
}

/// `kind` field on `POST /api/gen/uploads/sas`.
enum GenAssetKind {
  idle('idle'),
  talking('talking'),
  voice('voice'),

  /// Return SAS URLs for all three assets in one call. The response's
  /// `all` map holds every kind's `<kind>_sas` + `<kind>_path`.
  all('all');

  const GenAssetKind(this.wire);
  final String wire;
}

/// Response for `POST /api/gen/uploads/sas`.
///
/// Two shapes depending on the request:
/// - kind ∈ {idle, talking, voice}: [uploadUrl] + [blobPath] are the
///   single asset's target.
/// - kind == all: [uploadUrl]/[blobPath] point at the idle slot (for
///   backwards-compat) and [all] holds every kind's SAS + path keyed
///   as `idle_sas`/`idle_path`/…
class GenSasResponse {
  const GenSasResponse({
    required this.uploadUrl,
    required this.blobPath,
    this.all,
  });

  final String uploadUrl;
  final String blobPath;

  /// Present only when the request `kind` was `all`. Keys:
  /// `idle_sas`, `idle_path`, `talking_sas`, `talking_path`,
  /// `voice_sas`, `voice_path`.
  final Map<String, String>? all;

  factory GenSasResponse.fromJson(Map<String, dynamic> json) => GenSasResponse(
        uploadUrl: json['upload_url'] as String,
        blobPath: json['blob_path'] as String,
        all: json['all'] == null
            ? null
            : Map<String, String>.from(
                (json['all'] as Map).map(
                  (k, v) => MapEntry(k.toString(), v.toString()),
                ),
              ),
      );
}

/// Response for `POST /api/gen/submissions`.
class GenSubmissionResult {
  const GenSubmissionResult({required this.submissionId, required this.rid});

  /// Numeric submission id — feed to [GenAdminClient.submissionStatus].
  final int submissionId;

  /// Human-readable resource id — feed to [GenAdminClient.avatarStatus]
  /// or use to build the viewer URL.
  final String rid;

  factory GenSubmissionResult.fromJson(Map<String, dynamic> json) =>
      GenSubmissionResult(
        submissionId: (json['submission_id'] as num).toInt(),
        rid: json['rid'] as String,
      );
}

/// Row from `GET /api/gen/avatars`.
class GenAvatarSummary {
  const GenAvatarSummary({
    required this.id,
    required this.avatarname,
    required this.rid,
    required this.status,
    required this.idleUrl,
    required this.posterUrl,
    this.createdAt,
  });

  final int id;
  final String avatarname;
  final String rid;

  /// Whole-avatar status. See [GenAvatarStatus] for the vocabulary.
  final GenAvatarStatus status;

  /// Fresh Azure Blob SAS URL for the idle-loop clip. Minted per
  /// request; treat as short-lived (typically <1 hour).
  final String idleUrl;

  /// Fresh SAS URL for the poster still.
  final String posterUrl;

  final DateTime? createdAt;

  factory GenAvatarSummary.fromJson(Map<String, dynamic> json) =>
      GenAvatarSummary(
        id: (json['id'] as num).toInt(),
        avatarname: json['avatarname'] as String,
        rid: json['rid'] as String,
        status: GenAvatarStatus.fromWire(json['status'] as String? ?? ''),
        idleUrl: (json['idle_url'] as String?) ?? '',
        posterUrl: (json['poster_url'] as String?) ?? '',
        createdAt: json['created_at'] is String
            ? DateTime.tryParse(json['created_at'] as String)
            : null,
      );
}

/// The 7-stage render pipeline stages, in canonical order.
///
/// Emitted by the server as raw slugs (`"validate"`, `"reserve_credits"`,
/// …). Brain configuration is deliberately NOT one of these — the brain
/// is scaffolded through a parallel path (`PUT /api/gen/avatars/{rid}/brain`)
/// so a user can fill in personality while the render is still running.
enum GenStage {
  validate('validate'),
  reserveCredits('reserve_credits'),
  voiceClone('voice_clone'),
  footageWav2lip('footage_wav2lip'),
  register('register'),
  smokeVerify('smoke_verify'),
  notify('notify');

  const GenStage(this.wire);
  final String wire;

  static GenStage fromWire(String s) => values.firstWhere(
        (v) => v.wire == s,
        orElse: () => validate,
      );
}

/// Per-stage state carried inside a status payload's `stages` map.
enum GenStageState {
  pending('pending'),
  running('running'),
  done('done'),
  failed('failed');

  const GenStageState(this.wire);
  final String wire;

  static GenStageState fromWire(String s) => values.firstWhere(
        (v) => v.wire == s,
        orElse: () => pending,
      );
}

/// Whole-avatar status (`GenAvatar.status` server-side).
enum GenAvatarStatus {
  processing('processing'),
  needsPersonality('needs_personality'),
  ready('ready'),
  failed('failed'),
  queued('queued'),

  /// A status the server may send that this SDK build doesn't recognize.
  /// Preserves forward-compat — treat as non-terminal.
  unknown('');

  const GenAvatarStatus(this.wire);
  final String wire;

  bool get isTerminal =>
      this == GenAvatarStatus.ready || this == GenAvatarStatus.failed;

  static GenAvatarStatus fromWire(String s) => values.firstWhere(
        (v) => v.wire == s,
        orElse: () => unknown,
      );
}

/// Brain configuration status (`GenAvatar.brain_status`).
enum GenBrainStatus {
  none('none'),
  configuring('configuring'),
  ready('ready'),
  failed('failed'),
  unknown('');

  const GenBrainStatus(this.wire);
  final String wire;

  static GenBrainStatus fromWire(String s) => values.firstWhere(
        (v) => v.wire == s,
        orElse: () => unknown,
      );
}

/// Response from `GET /api/gen/submission/{id}/status` or
/// `GET /api/gen/avatars/{rid}/status` — same shape both.
class GenSubmissionStatus {
  const GenSubmissionStatus({
    required this.rid,
    required this.currentStage,
    required this.stages,
    required this.overallPct,
    required this.status,
    required this.avatarStatus,
    required this.brainStatus,
    required this.brainConfigured,
    this.errorMessage,
  });

  /// Human-readable avatar id — echoed on every status response for
  /// UI convenience.
  final String rid;

  /// The stage the pipeline is currently attempting.
  final GenStage currentStage;

  /// Map of every stage → its current state. Stages absent from the
  /// server response default to [GenStageState.pending].
  final Map<GenStage, GenStageState> stages;

  /// 0–100 rounded percentage — count of done stages / 7.
  final int overallPct;

  /// Render-pipeline status: `running` / `queued` / `ready` /
  /// `failed` / `verification_deferred`. Held raw (not enum'd) because
  /// the vocabulary overlaps but doesn't fully match
  /// [GenAvatarStatus] — pipeline `ready` gates but doesn't equal
  /// avatar `ready` (which also needs brain to land).
  final String status;

  /// Overall avatar status — pipeline done AND brain done gives
  /// [GenAvatarStatus.ready]; pipeline done + brain missing gives
  /// [GenAvatarStatus.needsPersonality].
  final GenAvatarStatus avatarStatus;

  /// Brain-scaffold status. Parallel to the render pipeline; the two
  /// converge on avatar-ready.
  final GenBrainStatus brainStatus;

  /// True if brain slug exists on the row — a shortcut server-side
  /// signal that the brain has been at least once scaffolded.
  final bool brainConfigured;

  /// Server-supplied error message when a stage failed. Free-form.
  final String? errorMessage;

  /// True when both the render pipeline is done AND the brain is
  /// configured/ready — i.e. the avatar is chat-ready end-to-end.
  bool get isReady => avatarStatus == GenAvatarStatus.ready;

  factory GenSubmissionStatus.fromJson(Map<String, dynamic> json) {
    final rawStages = json['stages'] as Map? ?? const {};
    return GenSubmissionStatus(
      rid: json['rid'] as String? ?? '',
      currentStage: GenStage.fromWire(json['current_stage'] as String? ?? ''),
      stages: {
        for (final s in GenStage.values)
          s: GenStageState.fromWire(
            rawStages[s.wire] as String? ?? 'pending',
          ),
      },
      overallPct: (json['overall_pct'] as num? ?? 0).toInt(),
      status: json['status'] as String? ?? '',
      avatarStatus:
          GenAvatarStatus.fromWire(json['avatar_status'] as String? ?? ''),
      brainStatus:
          GenBrainStatus.fromWire(json['brain_status'] as String? ?? ''),
      brainConfigured: json['brain_configured'] as bool? ?? false,
      errorMessage: json['error_message'] as String?,
    );
  }
}

/// Response from `GET /api/gen/avatars/{rid}/brain`.
class GenBrainConfig {
  const GenBrainConfig({
    required this.persona,
    required this.configured,
    required this.brainStatus,
    required this.coreFields,
  });

  /// The stored personality dict — keys are freeform but always
  /// include the [coreFields] entries once configured.
  final Map<String, dynamic> persona;

  /// Legacy-compatible shortcut: brain_slug exists on the row. New
  /// integrations should prefer [brainStatus] for finer detail.
  final bool configured;

  final GenBrainStatus brainStatus;

  /// Persona fields the server considers required (missing them makes
  /// `PUT /brain` 422). Present in the response so admin UIs can drive
  /// their required-field validation from the server rather than
  /// hardcoding the list.
  final List<String> coreFields;

  factory GenBrainConfig.fromJson(Map<String, dynamic> json) => GenBrainConfig(
        persona: Map<String, dynamic>.from(
          (json['persona'] as Map?) ?? const {},
        ),
        configured: json['configured'] as bool? ?? false,
        brainStatus:
            GenBrainStatus.fromWire(json['brain_status'] as String? ?? ''),
        coreFields: [
          for (final f in (json['core_fields'] as List? ?? const []))
            f.toString(),
        ],
      );
}

/// Response from `GET /api/gen/view-token/{owner}/{avatarname}`.
/// Bundles the short-lived (~5min) rid-scoped view token together
/// with the hydrated avatar catalog — one round-trip gets everything
/// a player embed needs.
class GenViewToken {
  const GenViewToken({
    required this.viewToken,
    required this.avatar,
  });

  /// Rid-scoped HS256 JWT. Feed to `ViewTokenCredentials(token)` and
  /// pass to `TwaiPlayerHandle(credentials: ...)`. Rotate before
  /// expiry by calling [GenAdminClient.mintViewToken] again — the
  /// wall-clock TTL is on the server (`gen_view_token_ttl_s`,
  /// default 300s).
  final String viewToken;

  /// The hydrated avatar record — same shape gen-2wai returns from
  /// `/api/gen/catalog/{owner}/{avatarname}`. Ready to hand to
  /// `TwaiPlayerHandle.fromSlug()` (or to `AvatarCatalogResponse.fromJson`
  /// for the wire type).
  final Map<String, dynamic> avatar;

  factory GenViewToken.fromJson(Map<String, dynamic> json) => GenViewToken(
        viewToken: json['view_token'] as String,
        avatar: Map<String, dynamic>.from(
          (json['avatar'] as Map?) ?? const <String, dynamic>{},
        ),
      );
}
