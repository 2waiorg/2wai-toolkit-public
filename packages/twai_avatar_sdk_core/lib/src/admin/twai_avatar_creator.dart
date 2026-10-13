import 'dart:async';

import 'package:http/http.dart' as http;

import '../environment.dart';
import 'gen_admin_client.dart';
import 'gen_admin_errors.dart';
import 'gen_admin_types.dart';

/// One-object facade over [GenAdminClient] for the "upload three
/// files, get a playable avatar" flow. Wraps the wizard endpoints in
/// task-shaped methods that match how a customer actually reasons
/// about avatar creation:
///
/// ```dart
/// final creator = TwaiAvatarCreator(env: TwaiEnvironment.twaiStaging);
///
/// // Sign-in (OTP)
/// await creator.requestOtp('mason@2wai.ai');
/// // ... user reads email, enters code ...
/// await creator.verifyAndSignIn(
///   email: 'mason@2wai.ai',
///   code: '123456',
/// );
///
/// // Fire the whole submission + polling loop in one call:
/// final result = await creator.createAvatar(
///   avatarname: 'nova',
///   idleBytes: idleMp4Bytes,
///   talkingBytes: talkingMp4Bytes,
///   voiceBytes: voiceWavBytes,
///   form: {
///     'name': 'Nova',
///     'oneliner': 'Cosmic guide',
///     'backstory': '...',
///     'personality': 'warm, curious',
///     'speaking_style': 'conversational',
///   },
///   onProgress: (status) => print('${status.stage}: ${status.avatarStatus}'),
/// );
/// // result.rid is now playable via TwaiPlayerHandle
/// ```
///
/// # Why this + [GenAdminClient]?
///
/// - [GenAdminClient] is the wire client — one method per endpoint,
///   symmetric with `/api/gen/*`. Right level for admin apps that
///   want the full step-by-step wizard UX.
/// - [TwaiAvatarCreator] is the customer-app entry point — bundles
///   asset upload + submission + status polling into `createAvatar()`,
///   surfaces progress via a callback, and returns everything the
///   app needs to start playing (rid + view-token).
///
/// Both live in the SDK; use whichever matches the shape of your
/// integration.
///
/// # Ownership
///
/// The creator owns an internal [GenAdminClient]. Call [close] when
/// done to release the shared HTTP client. Anonymous / signed-out
/// operations that don't need a token can be run against the same
/// instance; the token is stored on the internal client after
/// [verifyAndSignIn].
class TwaiAvatarCreator {
  TwaiAvatarCreator({
    required TwaiEnvironment env,
    http.Client? httpClient,
    String? accessToken,
    Duration pollInterval = const Duration(seconds: 2),
    Duration pollTimeout = const Duration(minutes: 15),
  })  : _client = GenAdminClient(
          baseUrl: env.baseUrl,
          httpClient: httpClient,
          accessToken: accessToken,
        ),
        _pollInterval = pollInterval,
        _pollTimeout = pollTimeout;

  /// Alternate constructor when you already hold a [GenAdminClient]
  /// (test fakes, shared HTTP pool with other admin surfaces).
  TwaiAvatarCreator.fromClient(
    this._client, {
    Duration pollInterval = const Duration(seconds: 2),
    Duration pollTimeout = const Duration(minutes: 15),
  })  : _pollInterval = pollInterval,
        _pollTimeout = pollTimeout;

  final GenAdminClient _client;
  final Duration _pollInterval;
  final Duration _pollTimeout;

  /// Escape hatch to the underlying wire client — for calls the
  /// facade doesn't wrap yet (brain edit, delete, list, reclips).
  GenAdminClient get client => _client;

  /// True after [verifyAndSignIn] (or when the creator was
  /// constructed with an `accessToken:`).
  bool get isAuthenticated => _client.isAuthenticated;

  // ══════════════════════════════════════════════════════════════════
  // Auth
  // ══════════════════════════════════════════════════════════════════

  /// Request an OTP by email. See [GenAdminClient.requestOtp].
  Future<void> requestOtp(String email) => _client.requestOtp(email);

  /// Verify the OTP code + stash the returned access token on the
  /// underlying client. Convenience over
  /// `verifyOtp() + authenticate()`.
  Future<GenUser> verifyAndSignIn({
    required String email,
    required String code,
  }) async {
    final token = await _client.verifyOtp(email: email, code: code);
    _client.authenticate(token);
    return _client.getMe();
  }

  /// Sign out — clears the token. Same as [GenAdminClient.clearAuth].
  void signOut() => _client.clearAuth();

  /// The current access token, if any. Persist to secure storage +
  /// pass back to the constructor's `accessToken:` on next launch to
  /// skip the OTP step.
  String? get accessToken => _client.accessToken;

  // ══════════════════════════════════════════════════════════════════
  // One-shot avatar creation
  // ══════════════════════════════════════════════════════════════════

  /// Full happy-path: upload the three asset files, submit the bake,
  /// poll to completion, return the identifiers. On failure at any
  /// step throws with the underlying [GenApiException].
  ///
  /// [onProgress] fires after every status poll (default every 2s
  /// — see the constructor's `pollInterval`) with the current
  /// [GenSubmissionStatus]. Useful for driving a progress bar.
  ///
  /// [pollTimeout] caps how long the method will wait for the
  /// pipeline to reach a terminal state (`ready` or `failed`). The
  /// default (15 min) is comfortable for the 7-stage bake; increase
  /// for longer footage.
  ///
  /// Returns a [TwaiAvatarCreation] with the rid + normalized
  /// avatarname + terminal status. To immediately play the new
  /// avatar, feed the rid to [mintViewToken] and pass the resulting
  /// token to a `ViewTokenCredentials(...)` + `TwaiPlayerHandle`.
  Future<TwaiAvatarCreation> createAvatar({
    required String avatarname,
    required List<int> idleBytes,
    required List<int> talkingBytes,
    required List<int> voiceBytes,
    Map<String, dynamic> form = const {},
    bool consentAttested = true,
    void Function(GenSubmissionStatus status)? onProgress,
  }) async {
    // 1. Get SAS urls for all three uploads in one call.
    final sas = await _client.uploadSas(kind: GenAssetKind.all);
    final all = sas.all;
    if (all == null) {
      throw GenApiTransportException(
        cause: StateError('uploadSas(kind: all) returned no `all` map'),
        message: 'Malformed SAS response',
      );
    }
    final idleSas = all['idle_sas'];
    final talkingSas = all['talking_sas'];
    final voiceSas = all['voice_sas'];
    final idlePath = all['idle_path'];
    final talkingPath = all['talking_path'];
    final voicePath = all['voice_path'];
    if (idleSas == null ||
        talkingSas == null ||
        voiceSas == null ||
        idlePath == null ||
        talkingPath == null ||
        voicePath == null) {
      throw GenApiTransportException(
        cause: StateError('SAS response missing one of the six keys: $all'),
        message: 'Malformed SAS response',
      );
    }

    // 2. Upload all three files in parallel. Azure Blob PUT tolerates
    //    concurrent uploads to distinct paths and there's no ordering
    //    dependency between them; parallelism cuts the wall-clock
    //    ~3x on typical 20-40MB assets.
    await Future.wait([
      _client.uploadBytes(
        uploadUrl: Uri.parse(idleSas),
        bytes: idleBytes,
        contentType: 'video/mp4',
      ),
      _client.uploadBytes(
        uploadUrl: Uri.parse(talkingSas),
        bytes: talkingBytes,
        contentType: 'video/mp4',
      ),
      _client.uploadBytes(
        uploadUrl: Uri.parse(voiceSas),
        bytes: voiceBytes,
        contentType: 'audio/wav',
      ),
    ]);

    // 3. Create the submission. Server kicks off the 7-stage
    //    pipeline as a background task (or enqueues it for the
    //    worker in prod).
    final submission = await _client.createSubmission(
      avatarname: avatarname,
      form: form,
      assetRefs: {
        'idle_blob': idlePath,
        'talking_blob': talkingPath,
        'voice_blob': voicePath,
      },
      consentAttested: consentAttested,
    );

    // 4. Poll to completion.
    final terminal = await _pollUntilTerminal(
      submission.rid,
      onProgress: onProgress,
    );

    if (terminal.avatarStatus == GenAvatarStatus.failed) {
      throw GenApiTransportException(
        cause: StateError(
          'Pipeline reported failed at ${terminal.currentStage.wire}: '
          '${terminal.errorMessage ?? "(no error message)"}',
        ),
        message: 'Avatar creation failed at stage ${terminal.currentStage.wire}',
      );
    }

    return TwaiAvatarCreation(
      rid: submission.rid,
      submissionId: submission.submissionId,
      avatarname: avatarname,
      terminalStatus: terminal,
    );
  }

  /// Observable status stream — polls [GenAdminClient.avatarStatus]
  /// every [pollInterval] until terminal (ready / failed) or the
  /// subscription is cancelled. Emits every poll for a stage change
  /// display; ends the stream on terminal.
  ///
  /// Different shape from [createAvatar]'s [onProgress]: this returns
  /// a `Stream` so a UI can `StreamBuilder` it directly. The two
  /// paths are equivalent under the hood.
  Stream<GenSubmissionStatus> watchProgress(String rid) async* {
    final deadline = DateTime.now().add(_pollTimeout);
    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        throw GenApiTransportException(
          cause: StateError('watchProgress exceeded $_pollTimeout'),
          message: 'Poll timeout waiting for rid=$rid',
        );
      }
      final status = await _client.avatarStatus(rid);
      yield status;
      if (status.avatarStatus == GenAvatarStatus.ready ||
          status.avatarStatus == GenAvatarStatus.failed) {
        return;
      }
      await Future<void>.delayed(_pollInterval);
    }
  }

  /// Mint a rid-scoped view token for embedding a private avatar.
  /// Direct pass-through to [GenAdminClient.mintViewToken]; hoisted
  /// onto the facade because it's the natural next call after
  /// [createAvatar] returns.
  Future<GenViewToken> mintViewToken({
    required String owner,
    required String avatarname,
  }) =>
      _client.mintViewToken(owner: owner, avatarname: avatarname);

  /// Convenience: check if an avatar name is available before
  /// starting the wizard.
  Future<GenNameCheck> checkName(String avatarname) =>
      _client.checkName(avatarname);

  /// Release the internal HTTP client. Idempotent.
  void close() => _client.close();

  // ══════════════════════════════════════════════════════════════════
  // Internals
  // ══════════════════════════════════════════════════════════════════

  Future<GenSubmissionStatus> _pollUntilTerminal(
    String rid, {
    void Function(GenSubmissionStatus)? onProgress,
  }) async {
    final deadline = DateTime.now().add(_pollTimeout);
    while (true) {
      if (DateTime.now().isAfter(deadline)) {
        throw GenApiTransportException(
          cause: StateError('createAvatar exceeded $_pollTimeout'),
          message: 'Poll timeout waiting for rid=$rid to reach terminal state',
        );
      }
      final status = await _client.avatarStatus(rid);
      onProgress?.call(status);
      if (status.avatarStatus == GenAvatarStatus.ready ||
          status.avatarStatus == GenAvatarStatus.failed) {
        return status;
      }
      await Future<void>.delayed(_pollInterval);
    }
  }
}

/// Terminal result of [TwaiAvatarCreator.createAvatar]. All fields
/// are non-null on success (the method throws before returning if
/// the pipeline reported `failed`).
class TwaiAvatarCreation {
  const TwaiAvatarCreation({
    required this.rid,
    required this.submissionId,
    required this.avatarname,
    required this.terminalStatus,
  });

  /// Server-assigned resource id. Use as the identifier when
  /// [TwaiAvatarCreator.mintViewToken] or resuming a dashboard row.
  final String rid;

  /// Numeric submission id — passed to
  /// [GenAdminClient.submissionStatus] if the caller needs another
  /// status poll (though `createAvatar` already awaited terminal).
  final int submissionId;

  /// Normalized avatarname the server stored — may differ from the
  /// user's input (e.g. `Nova The Great` → `nova-the-great`).
  final String avatarname;

  /// The final status snapshot at the moment the pipeline reached
  /// `ready`. Useful for a "created X seconds ago" line in the UI.
  final GenSubmissionStatus terminalStatus;
}
