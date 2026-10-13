/// Metadata for a single avatar, as returned by [AvatarAdminClient.allAvatars].
/// Matches the shape from `protocol.md` §4 "query_avatar".
class AvatarMetadata {
  final String avatarName;
  final String prompt;
  final DateTime createAt;
  final DateTime updateAt;

  const AvatarMetadata({
    required this.avatarName,
    required this.prompt,
    required this.createAt,
    required this.updateAt,
  });

  factory AvatarMetadata.fromJson(Map<String, dynamic> json) {
    return AvatarMetadata(
      avatarName: json['avatar_name'] as String,
      prompt: json['prompt'] as String? ?? '',
      createAt: DateTime.fromMillisecondsSinceEpoch(
        (json['create_at'] as num? ?? 0).toInt(),
      ),
      updateAt: DateTime.fromMillisecondsSinceEpoch(
        (json['update_at'] as num? ?? 0).toInt(),
      ),
    );
  }

  @override
  String toString() => 'AvatarMetadata($avatarName)';
}

/// Result envelope from `/add_avatar` and `/delete_avatar`.
class AvatarMutationResult {
  final int code;
  final String data;
  final bool? webrtcReleased;
  final bool? clearAvatarCache;
  final int? cacheBust;

  const AvatarMutationResult({
    required this.code,
    required this.data,
    this.webrtcReleased,
    this.clearAvatarCache,
    this.cacheBust,
  });

  factory AvatarMutationResult.fromJson(Map<String, dynamic> json) {
    return AvatarMutationResult(
      code: (json['code'] as num? ?? -1).toInt(),
      data: json['data'] as String? ?? '',
      webrtcReleased: json['webrtcReleased'] as bool?,
      clearAvatarCache: json['clearAvatarCache'] as bool?,
      cacheBust: (json['cacheBust'] as num?)?.toInt(),
    );
  }
}
