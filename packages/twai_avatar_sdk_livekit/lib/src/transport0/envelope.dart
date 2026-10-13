/// Internal construction seam for the `lk.chat` envelope.
///
/// Kept separate from [LiveKitEngine] so the cross-SDK conformance vectors can
/// exercise the exact production builder without constructing a LiveKit room.
/// This file is intentionally not exported from the Transport 0 barrel.
library;

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

Map<String, Object?> buildLiveKitChatEnvelope(
  String text, {
  Map<String, Object?>? extra,
}) {
  return <String, Object?>{
    if (extra != null) ...extra,
    'v': 1,
    'request_id': _uuid.v4(),
    'text': text,
  };
}
