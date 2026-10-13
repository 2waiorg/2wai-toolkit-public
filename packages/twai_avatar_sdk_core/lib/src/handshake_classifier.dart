/// Server-side classifier for the `/ext-api/mse_stream` handshake
/// frame. Reference-mirrored 1:1 from twai-protocol's
/// `conformance/harness/reference-client.mjs:27-40`.
///
/// **The rule** (mirrors `inference_service/worker_server.py` handshake
/// handling): a conforming server closes 1002 on
///   - non-JSON,
///   - missing `session_id`,
///   - or config timeout.
/// Every other shape accepts; the server fills defaults for
/// `avatar_id` / `ttsSelection` / `avatarVoice` / `stream_type`.
///
/// This function is used two ways:
/// 1. **Server-side** — actually gate incoming WS connections. Not
///    what this SDK does (we're a client), but a Dart port of
///    main_service could use it.
/// 2. **Client-side conformance** — the Dart conformance runner
///    (see `test/protocol_conformance_test.dart`) feeds this the
///    shared `handshake-cases.json` vectors and asserts every case
///    classifies to the expected `{accept, closeCode?}`. That's the
///    contract that makes "the frames my client sends will be
///    accepted" a machine-checkable claim.
library;

import 'dart:convert';

/// Result of classifying a handshake frame.
class HandshakeClassification {
  const HandshakeClassification({required this.accept, this.closeCode});

  final bool accept;
  final int? closeCode;

  Map<String, dynamic> toJson() => {
        'accept': accept,
        if (closeCode != null) 'closeCode': closeCode,
      };

  @override
  String toString() =>
      'HandshakeClassification(accept=$accept, closeCode=$closeCode)';
}

/// Classify a handshake frame. Provide EXACTLY ONE of:
/// - [input] — an already-decoded JSON map (fast path used by tests
///   and by servers that decode centrally)
/// - [raw] — the raw text frame as sent by the client (server may
///   receive it as a string on the wire; classifier decodes)
///
/// [timedOut] short-circuits — if true, returns `{accept: false,
/// closeCode: 1002}` before touching [input] / [raw].
HandshakeClassification classifyHandshake({
  Map<String, dynamic>? input,
  String? raw,
  bool timedOut = false,
}) {
  if (timedOut) {
    return const HandshakeClassification(accept: false, closeCode: 1002);
  }
  Map<String, dynamic>? obj = input;
  if (obj == null) {
    if (raw is! String) {
      return const HandshakeClassification(accept: false, closeCode: 1002);
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return const HandshakeClassification(accept: false, closeCode: 1002);
      }
      obj = decoded;
    } on FormatException {
      return const HandshakeClassification(accept: false, closeCode: 1002);
    }
  }
  final sid = obj['session_id'];
  if (sid is! String || sid.isEmpty) {
    return const HandshakeClassification(accept: false, closeCode: 1002);
  }
  return const HandshakeClassification(accept: true);
}
