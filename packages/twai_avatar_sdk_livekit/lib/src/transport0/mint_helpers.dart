/// Mint-response classification — Dart port of
/// `packages/core/src/mintHelpers.ts`. The one place a token endpoint's
/// reply becomes a [MintResult] or a typed mint error.
///
/// The engine never fetches. Hosts inject a zero-arg `mint` closure and
/// call these helpers from inside it so the parsing of "enabled /
/// disabled / rate-limited / unavailable" is IDENTICAL in every host,
/// or the same 429 shows a wait in one surface and a generic failure in
/// another.
///
/// Two independent decisions about 429, kept separate because they
/// answer to different things:
///
///   - It is TERMINAL: nothing here retries or reschedules, and hosts
///     must not either. This is the one the server-side silent-session
///     guard depends on (spec §6.2); an auto-retry behind the user's
///     back is exactly what that guard exists to catch.
///   - Its body is never read. The wait is in the header, so the body
///     carries nothing the caller needs, and not touching it means a
///     429 cannot also fail as a parse error.
///
/// The same body-skipping applies to every other non-2xx status:
/// classifying from the status alone is total — it cannot itself fail
/// and it cannot hand a server's error prose to a host as if it were a
/// mint result. Operators reading a 503 go to the mint service's own
/// logs, which have the full story.
library;

import 'dart:convert';

import 'engine_types.dart';

/// The part of an HTTP response this helper needs. A real
/// `http.Response` or `HttpClientResponse` structurally satisfies it
/// (via a wrapper); anything else that can report a status, a
/// case-sensitive header, and a parseable body works too — which is
/// what keeps this module free of both `dart:io` and `package:http`.
abstract class MintResponseLike {
  int get status;

  /// **Case-sensitive** lookup, by design. A real HTTP headers map
  /// normalises case, but a proxy adapter often hands over a
  /// lowercase-keyed plain object; a case-sensitive miss would
  /// silently degrade EVERY 429 to the 60s fallback and the wait
  /// would look plausible so nothing would ever look broken. The
  /// helper asks for both spellings by hand below.
  String? headerValue(String name);

  /// Parse the body as JSON. Raise a [FormatException] on non-JSON
  /// bodies (the standard `jsonDecode` behaviour), or a different
  /// error class if the body is not readable at all.
  Future<Object?> readJson();
}

/// Classify a mint endpoint's response. Resolves to the [MintResult]
/// the engine acts on, or throws [MintRateLimited] / [MintUnavailable].
Future<MintResult> mintResultFromResponse(MintResponseLike res) async {
  // Status first, body never — see the 429 notes above.
  if (res.status == 429) {
    // Both spellings, by hand. See MintResponseLike.headerValue.
    final retryAfter =
        res.headerValue('Retry-After') ?? res.headerValue('retry-after');
    final parsed = int.tryParse(retryAfter ?? '') ?? -1;
    throw MintRateLimited(parsed);
  }
  if (res.status < 200 || res.status >= 300) {
    throw MintUnavailable('HTTP ${res.status}');
  }

  Object? parsed;
  try {
    parsed = await res.readJson();
  } on FormatException catch (err) {
    // We read a body and it wasn't JSON (a proxy error page, an HTML
    // login redirect, a truncated response).
    throw MintUnavailable('non-JSON body', cause: err);
  } catch (err) {
    // We couldn't read the body at all — already consumed, connection
    // terminated mid-read — which points at the caller or the transport
    // rather than at what the server said.
    throw MintUnavailable('unreadable body', cause: err);
  }

  // A body that is null, a bare string, or a list reads every field as
  // undefined and falls through the same missing-url/token gate below.
  final body = parsed is Map ? parsed : null;

  // Strict `== false`: only an explicit `false` disables. An absent
  // flag means the endpoint simply doesn't have one (livealman
  // family's `{url, token, room}`). PP tests truthiness, but we ship
  // the strict form so `{url, token, room}` isn't misread as
  // "chat is turned off".
  if (body?['enabled'] == false) return const MintResultDisabled();

  final url = body?['url'] is String ? body!['url'] as String : '';
  final token = body?['token'] is String ? body!['token'] as String : '';
  if (url.isEmpty || token.isEmpty) {
    throw MintUnavailable('mint response missing url/token');
  }

  return MintResultEnabled(
    url: url,
    token: token,
    // The livealman token endpoint may omit `room`; the engine treats
    // "" as "the server named it, ask the Room object once connected".
    room: body?['room'] is String ? body!['room'] as String : '',
  );
}

/// [mintResultFromResponse], but starting one step earlier — from the
/// pending request rather than a response that already arrived.
///
///     mint: () => mintResultFromFetch(_get(url));
///
/// Without this, the request's OWN failure is the one thing hosts have
/// to classify themselves — DNS failure, connection refused, TLS
/// errors, aborts, all before there is any response to hand over.
Future<MintResult> mintResultFromFetch(
  Future<MintResponseLike> response,
) async {
  MintResponseLike res;
  try {
    res = await response;
  } catch (err) {
    throw MintUnavailable('mint request failed', cause: err);
  }
  // Deliberately OUTSIDE the try. Classification throws errors that
  // are already correctly typed, and a catch spanning this call would
  // rewrap a MintRateLimited as MintUnavailable — turning a 429 with
  // a real wait into a generic failure, which is the exact bug this
  // module exists to prevent.
  return mintResultFromResponse(res);
}

/// Convenience adapter: build a [MintResponseLike] from a Dart
/// `{status, headers, bodyText}` triple. The conformance runner uses
/// this to feed mint-cases.json rows through the classifier; hosts
/// integrating with `package:http` typically write their own thin
/// wrapper instead.
class SimpleMintResponse implements MintResponseLike {
  @override
  final int status;

  final Map<String, String> _headers;
  final String _bodyText;
  final bool _bodyReadable;

  int _jsonReads = 0;
  int get jsonReads => _jsonReads;

  SimpleMintResponse({
    required this.status,
    Map<String, String>? headers,
    String bodyText = '',
    bool bodyReadable = true,
  })  : _headers = headers ?? const {},
        _bodyText = bodyText,
        _bodyReadable = bodyReadable;

  @override
  String? headerValue(String name) => _headers[name];

  @override
  Future<Object?> readJson() async {
    _jsonReads++;
    if (!_bodyReadable) {
      // Distinct from a JSON parse failure: this is "the body could
      // not be read at all," which mintResultFromResponse maps to
      // `unreadable body`.
      throw StateError('Body is unusable: Body has already been read');
    }
    return jsonDecode(_bodyText);
  }
}
