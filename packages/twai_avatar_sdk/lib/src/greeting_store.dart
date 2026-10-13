import 'package:shared_preferences/shared_preferences.dart';

/// Persistence for "has this greeting's scopeId been sent?".
///
/// Pluggable so a host app can plug in its own backend (e.g. secure
/// storage, or a server-synced flag that follows the user across
/// devices). Default implementations:
///
///   - [SharedPreferencesGreetingStore] — persists across app
///     launches via Flutter's `shared_preferences` plugin. The
///     default; matches `TwaiGreeting.text(onceForever: true)`.
///   - [InMemoryGreetingStore] — in-memory only; the flag resets on
///     cold start. Matches `TwaiGreeting.text(onceForever: false)`
///     and the pre-SDK `apps/mmm_demo._openerSent` behavior.
///
/// All methods must be safe to call concurrently with themselves and
/// with each other for different scopeIds; the SDK does not funnel
/// through a lock.
abstract class GreetingStore {
  /// True if `scopeId` has been marked sent and NOT subsequently
  /// cleared. False otherwise.
  Future<bool> hasBeenSent(String scopeId);

  /// Mark `scopeId` as sent. Idempotent; marking twice is a no-op.
  Future<void> markSent(String scopeId);

  /// Clear `scopeId` so the next check returns false. Used for
  /// "reset greeting" UX (e.g. a Settings → Reset button, or a
  /// test harness between runs).
  Future<void> clear(String scopeId);
}

/// Flag persists across app launches via `shared_preferences`.
///
/// Keys are namespaced with [prefix] so they can't collide with
/// other `shared_preferences` entries in the host app. Default
/// prefix is `twai_greeting:`.
class SharedPreferencesGreetingStore implements GreetingStore {
  SharedPreferencesGreetingStore({this.prefix = 'twai_greeting:'});

  final String prefix;

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  String _key(String scopeId) => '$prefix$scopeId';

  @override
  Future<bool> hasBeenSent(String scopeId) async {
    final prefs = await _prefs;
    return prefs.getBool(_key(scopeId)) ?? false;
  }

  @override
  Future<void> markSent(String scopeId) async {
    final prefs = await _prefs;
    await prefs.setBool(_key(scopeId), true);
  }

  @override
  Future<void> clear(String scopeId) async {
    final prefs = await _prefs;
    await prefs.remove(_key(scopeId));
  }
}

/// Flag is held in a `Set` for the lifetime of this process; cold
/// start wipes it.
///
/// Matches the pre-SDK `apps/mmm_demo._openerSent` bool: once-per-
/// app-session semantics. Also the right default for tests, where
/// `shared_preferences` would need `MockPlatformInterface` setup.
class InMemoryGreetingStore implements GreetingStore {
  final Set<String> _sent = <String>{};

  @override
  Future<bool> hasBeenSent(String scopeId) async => _sent.contains(scopeId);

  @override
  Future<void> markSent(String scopeId) async {
    _sent.add(scopeId);
  }

  @override
  Future<void> clear(String scopeId) async {
    _sent.remove(scopeId);
  }
}
