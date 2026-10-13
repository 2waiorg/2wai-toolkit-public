/// Pluggable credential provider for the 2wai pipeline + `/api/*`
/// surface. Modeled after `twai-web-sdk`'s `TwaiCredentials` so the
/// two SDKs share auth vocabulary and consumers can switch languages
/// without re-learning the auth model.
///
/// # Why not just `String? publishableKey`?
///
/// The pipeline speaks three different auth vectors and the flat
/// string can't express them:
///
/// 1. **Anonymous** — public avatars on the muse pipeline today
///    (no headers).
/// 2. **Publishable key** — tenant-scoped, browser-safe; today we
///    send it as `Authorization: Bearer <pk>` and `?key=<pk>` on the
///    WS URL. Web SDK sends `X-Twai-Key` header instead — see docs
///    on [PublicKeyCredentials] for the alignment path.
/// 3. **View token** — rid-scoped, short-lived (~5 min TTL), minted
///    by gen-2wai for private avatars, verified by the pipeline as
///    `X-View-Token`. Rotatable in place so a long-lived session can
///    refresh without reconnecting.
/// 4. **Bearer JWT** — the gen-2wai user token minted after OTP
///    verification; consumed by `/api/gen/*` endpoints. Distinct
///    from the publishable key even though the header shape matches.
///
/// # Backward compatibility
///
/// Existing callers passing `publishableKey: 'pk_xxx'` on
/// [TwaiClient] / [TwaiApiClient] / [TwaiPlayerHandle] keep working —
/// the flat field is treated as a shortcut for
/// `credentials: PublicKeyCredentials('pk_xxx')`.
abstract class TwaiCredentials {
  const TwaiCredentials();

  /// Headers to attach to HTTP requests (`/api/*`, `/ext-api/*`).
  /// Merged into the client's default `Content-Type` etc.
  Map<String, String> httpHeaders();

  /// Query parameters to append to the WebSocket URL. Needed because
  /// browsers can't set custom headers on WS handshakes — the SDK
  /// falls back to URL params for anything the browser can't
  /// otherwise attach.
  Map<String, String> wsQueryParams();

  /// Resolve the effective credentials for a session/client that accepts
  /// both a typed [TwaiCredentials] and the legacy `publishableKey: String?`
  /// shortcut. Precedence:
  ///
  ///   1. [credentials] if non-null — wins even if [publishableKey] is set.
  ///   2. [PublicKeyCredentials]([publishableKey]) if it is non-null + non-empty.
  ///   3. [AnonymousCredentials].
  ///
  /// Kept as a static helper so every adapter (MSE-over-WS, Pipeline v1.3,
  /// twai-api) resolves the same way — one behavior spec, one place to
  /// change it.
  static TwaiCredentials resolve({
    TwaiCredentials? credentials,
    String? publishableKey,
  }) {
    if (credentials != null) return credentials;
    if (publishableKey != null && publishableKey.isNotEmpty) {
      return PublicKeyCredentials(publishableKey);
    }
    return const AnonymousCredentials();
  }
}

/// No auth headers. The current default for the pipeline's public
/// avatars.
class AnonymousCredentials extends TwaiCredentials {
  const AnonymousCredentials();

  @override
  Map<String, String> httpHeaders() => const {};

  @override
  Map<String, String> wsQueryParams() => const {};
}

/// Publishable (tenant-scope) key. Safe to ship in browser HTML.
///
/// **Cross-SDK header parity (fixed 2026-07-27):** the SDK now sends
/// BOTH `Authorization: Bearer <key>` (the historical shape used by
/// penthouse main_service) AND `X-Twai-Key: <key>` (the shape
/// `twai-web-sdk`'s `PublicKeyCredentials` uses). Nginx accepts both
/// since 2026-07-22 (`bda96b5`, the CORS+headers rollout — see
/// `nginx-prod.conf` Allow-Headers list). Sending both means backend
/// changes that flip from one to the other don't require an SDK bump,
/// and cross-SDK migrations (Dart ↔ TS) don't hit auth drift.
class PublicKeyCredentials extends TwaiCredentials {
  const PublicKeyCredentials(this.key);

  final String key;

  @override
  Map<String, String> httpHeaders() => key.isEmpty
      ? const {}
      : {
          'Authorization': 'Bearer $key',
          'X-Twai-Key': key,
        };

  @override
  Map<String, String> wsQueryParams() =>
      key.isEmpty ? const {} : {'key': key};
}

/// Rid-scoped view token minted by gen-2wai for a private avatar.
/// Rotatable in place so the app can refresh without reconnecting the
/// session; setToken is atomic — the next HTTP request uses the new
/// token.
///
/// Sent as `X-View-Token` header (HTTP) + `?view_token=` (WS URL).
class ViewTokenCredentials extends TwaiCredentials {
  ViewTokenCredentials(String initialToken) : _token = initialToken;

  String _token;

  /// Current token — read-only for callers, mutated only via
  /// [setToken] so the class stays the sole owner of the auth state.
  String get token => _token;

  /// Swap in a fresh token (e.g. after re-hitting
  /// `/api/gen/view-token/{owner}/{name}`). Effective immediately for
  /// subsequent requests; in-flight requests already used the old
  /// token.
  void setToken(String next) {
    _token = next;
  }

  @override
  Map<String, String> httpHeaders() =>
      _token.isEmpty ? const {} : {'X-View-Token': _token};

  @override
  Map<String, String> wsQueryParams() =>
      _token.isEmpty ? const {} : {'view_token': _token};
}

/// Server-side twai-api key (`sk_test_...` / `sk_live_...`).
///
/// **NEVER ship this in a browser bundle**. The `sk_` grants
/// unrestricted session-mint + speak power against the twai-api
/// tenant — it belongs on a customer server that fronts the SDK's
/// mint requests. The `.devOnly` factory is named that way to make
/// misuse obvious in code review.
///
/// For prod split-plane: don't use this class at all. Instead, point
/// the SDK's [TwaiApiRestClient] at your own mint-proxy server (which
/// holds the sk_ server-side) using anonymous or customer-defined
/// bearer credentials.
class TwaiApiKeyCredentials extends TwaiCredentials {
  /// Development-only. Wrap the sk_ key for direct SDK -> twai-api
  /// calls. Do not use in a shipped browser build.
  const TwaiApiKeyCredentials.devOnly(this.secretKey);

  final String secretKey;

  @override
  Map<String, String> httpHeaders() =>
      secretKey.isEmpty ? const {} : {'Authorization': 'Bearer $secretKey'};

  /// The twai-api WS handshake authenticates via the `?token=` query
  /// param carrying the mint's `client_token` — the sk_ never rides on
  /// the WS URL.
  @override
  Map<String, String> wsQueryParams() => const {};
}

/// User-scope Bearer JWT — the token gen-2wai mints after OTP
/// verification. Consumed by `/api/gen/*` and any other user-scoped
/// endpoint that speaks `HTTPBearer`. Distinct from
/// [PublicKeyCredentials] because the *meaning* differs even though
/// the wire header is the same shape — swapping between them is
/// meaningful for logging + telemetry.
class BearerJwtCredentials extends TwaiCredentials {
  const BearerJwtCredentials(this.jwt);

  final String jwt;

  @override
  Map<String, String> httpHeaders() =>
      jwt.isEmpty ? const {} : {'Authorization': 'Bearer $jwt'};

  @override
  Map<String, String> wsQueryParams() => const {};
}
