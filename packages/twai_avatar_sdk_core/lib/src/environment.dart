/// Named backend environment for the 2wai avatar pipeline.
///
/// Wraps a name + base URL so app code can pick environments by
/// reference instead of typing URLs. Three environments ship
/// predefined (`localDev`, `twaiStaging`, `twaiProd`); customers can
/// add their own via [register] (e.g. for self-hosted prod or
/// alternative staging deployments).
///
/// Three ways to select an environment in app code:
///
/// 1. **Direct reference**: `TwaiEnvironment.twaiStaging` — explicit,
///    locked at compile time.
/// 2. **`--dart-define`**: `TwaiEnvironment.fromDartDefine()` reads
///    `TWAI_ENV=<name>` passed at `flutter run --dart-define=…`. Best
///    for build-time switching (CI matrix, launch scripts).
/// 3. **Runtime lookup**: `TwaiEnvironment.named('2wai-staging')` —
///    pair with `flutter_dotenv` or any runtime config source to
///    read the name from a `.env` file the app ships with.
///
/// Example usage in app code:
///
/// ```dart
/// final env = TwaiEnvironment.fromDartDefine(
///   defaultName: '2wai-staging',
/// );
/// final session = MseStreamChatSession(
///   baseUrl: env.baseUrl,
///   ttsSelection: 'tts5',
///   userId: null,
/// );
/// ```
///
/// At launch:
/// ```
/// flutter run --dart-define=TWAI_ENV=2wai-prod -d <device>
/// ```
class TwaiEnvironment {
  TwaiEnvironment({required this.name, required this.baseUrl});

  /// Short human-readable label (`'2wai-staging'`, `'my-tenant-prod'`,
  /// etc.). Used as the lookup key in [_registry] and in log lines.
  final String name;

  /// Backend base URL the SDK resolves `/ext-api/*` paths against.
  /// Penthouse-style MSE wire is at `{baseUrl}/ext-api/mse_stream` and
  /// `{baseUrl}/ext-api/human`.
  final Uri baseUrl;

  @override
  String toString() => 'TwaiEnvironment($name → $baseUrl)';

  // ── Predefined environments ────────────────────────────────────────

  /// Customer's own local main_service instance (e.g. `2wai-avatar-pipeline/server/server.py`).
  /// Default port is 8000 (uvicorn default). Override via [register] if
  /// the local instance binds elsewhere.
  static final TwaiEnvironment localDev = TwaiEnvironment(
    name: 'local-dev',
    baseUrl: Uri.parse('http://localhost:8000'),
  );

  /// 2wai's hosted staging environment. Backed by Penthouse Pets'
  /// staging infrastructure on the shared krystal GPU VM — keep
  /// test traffic short (real soft-launch users on the same VM).
  static final TwaiEnvironment twaiStaging = TwaiEnvironment(
    name: '2wai-staging',
    baseUrl: Uri.parse('https://staging.coreledgergroup.com'),
  );

  /// 2wai's hosted production environment. Same shared pipeline
  /// infrastructure; routes through the production penthousepets.com
  /// nginx fronting main_service.
  static final TwaiEnvironment twaiProd = TwaiEnvironment(
    name: '2wai-prod',
    baseUrl: Uri.parse('https://www.penthousepets.com'),
  );

  /// twai-api gateway — the new `/v1/*` REST + WS surface Mason built
  /// (2waiorg/twai-api, deployed 2026-07-25). Distinct from
  /// [twaiStaging] / [twaiProd] which point at the penthouse
  /// `/ext-api/*` surface (Adapter 1); this env is what [TwaiApiChatSession]
  /// (Adapter 4) expects. Uses the raw Azure FQDN — swap to
  /// `https://api.2wai.ai` once DNS + CORS are live.
  static final TwaiEnvironment twaiApi = TwaiEnvironment(
    name: 'twai-api',
    baseUrl: Uri.parse(
        'https://twai-api.purpleglacier-ffec85d8.westus2.azurecontainerapps.io'),
  );

  // ── Registry & lookup ──────────────────────────────────────────────

  // Registry initializer references the predefined envs directly, which
  // forces their static-final initialization at first registry access.
  // (Earlier version put _register() calls inside each env's initializer,
  // which only ran when the env itself was referenced — a `named()` call
  // before any static-field touch would find an empty registry.)
  static final Map<String, TwaiEnvironment> _registry = {
    localDev.name: localDev,
    twaiStaging.name: twaiStaging,
    twaiProd.name: twaiProd,
    twaiApi.name: twaiApi,
  };

  /// Register a custom environment for later lookup by [named] or
  /// [fromDartDefine]. Overwrites a previous registration with the
  /// same name. Returns the registered environment for chaining.
  ///
  /// Typical use — customer-hosted prod:
  /// ```dart
  /// TwaiEnvironment.register(TwaiEnvironment(
  ///   name: 'acme-prod',
  ///   baseUrl: Uri.parse('https://avatars.acme.com'),
  /// ));
  /// ```
  static TwaiEnvironment register(TwaiEnvironment env) {
    _registry[env.name] = env;
    return env;
  }

  /// All registered environments — built-in plus anything passed to
  /// [register]. Useful for admin UIs that surface env pickers.
  static List<TwaiEnvironment> get all => List.unmodifiable(_registry.values);

  /// Look up a registered environment by name. Throws [ArgumentError]
  /// if no environment with that name is registered.
  static TwaiEnvironment named(String name) {
    final env = _registry[name];
    if (env == null) {
      throw ArgumentError(
        'No TwaiEnvironment registered with name "$name". '
        'Known: ${_registry.keys.toList()}.',
      );
    }
    return env;
  }

  /// Look up a registered environment by name from the build-time
  /// `--dart-define=TWAI_ENV=<name>` flag. Falls back to [defaultName]
  /// (which itself defaults to `'local-dev'`) when the flag is unset.
  ///
  /// Example launch:
  /// ```
  /// flutter run --dart-define=TWAI_ENV=2wai-staging
  /// ```
  static TwaiEnvironment fromDartDefine({String defaultName = 'local-dev'}) {
    const envName = String.fromEnvironment('TWAI_ENV', defaultValue: '');
    return named(envName.isEmpty ? defaultName : envName);
  }
}
