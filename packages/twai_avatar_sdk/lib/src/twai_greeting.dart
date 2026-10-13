import 'package:flutter/foundation.dart';
import 'package:twai_avatar_sdk_core/twai_avatar_sdk_core.dart'
    show TwaiApiGreetingPayload;

/// A greeting the avatar plays or sends when a session begins.
///
/// Three variants, each covering a documented production pattern:
///
///   - [TwaiGreeting.none] — explicit opt-out; the default when the
///     parameter is omitted on `TwaiTransport0Player`.
///   - [TwaiGreeting.text] — programmatic opener message: when the
///     engine reaches `ready`, send a one-time programmatic turn to
///     the brain so the avatar's first reply is already in-context.
///     Lumara Dr. Alman and `apps/mmm_demo` both do this today by
///     hand; this variant industrializes that pattern.
///   - [TwaiGreeting.rendered] — pre-rendered greeting video served
///     by gen-2wai's catalog hydrate (`{id, video_url, text}` shape).
///     Plays in the idle slot BEFORE the live LiveKit room comes up,
///     fires an audible-played event on completion so the consumer can
///     confirm consumption (gen-2wai's return-greeting handshake).
///   - [TwaiGreeting.dynamic] — a host-provided callback that resolves
///     the real greeting at connect time. Delegates to whatever
///     concrete variant the callback returns. Useful when the choice
///     depends on a server round-trip (e.g., "is there a return
///     greeting waiting for this user?").
///
/// Design shape: four variants (text / rendered / dynamic / none) kept
/// orthogonal so the player handles them without special-casing.
sealed class TwaiGreeting {
  const TwaiGreeting();

  /// No greeting. Explicit opt-out; equivalent to passing nothing.
  const factory TwaiGreeting.none() = TwaiGreetingNone;

  /// Pattern B — programmatic opener message.
  ///
  /// On `onReady` (plus [sendAfterReady] delay for the engine's
  /// SEND_GRACE_MS window), the player calls `engine.send([text])`
  /// exactly once per [scopeId]. Guarded by the persistence store
  /// (default: `SharedPreferencesGreetingStore`), so the same opener
  /// does not fire again on reconnect within the same app session —
  /// or across launches if [onceForever] is true.
  ///
  /// Consumer typically wires [onSent] to log the opener in their
  /// chat UI (the opener is a user-shaped message to the brain, not
  /// an avatar reply, so it won't surface through `onReplyText`).
  const factory TwaiGreeting.text({
    required String text,
    required String scopeId,
    bool onceForever,
    Duration sendAfterReady,
    VoidCallback? onSent,
  }) = TwaiGreetingText;

  /// Pattern A — pre-rendered greeting video.
  ///
  /// On engine construction, the player renders [videoUrl] in the
  /// idle slot (replacing the normal `AvatarIdleSource` for the
  /// duration of the greeting). On completion, [onAudiblyPlayed]
  /// fires with `wasAudible = (element.muted == false && volume > 0)`;
  /// the consumer uses that to confirm consumption of a return
  /// greeting (gen-2wai's `POST /api/gen/greeting/played { key }`
  /// with [consumptionKey]). Intro greetings skip the confirmation
  /// POST (server treats intro keys as no-op).
  ///
  /// NOT WIRED YET into `TwaiTransport0Player` — ships in Phase 2
  /// alongside catalog hydrate. The type is defined now so consumers
  /// building against pub.dev don't see a breaking change when the
  /// widget integration lands.
  const factory TwaiGreeting.rendered({
    required Uri videoUrl,
    required String text,
    required String id,
    required GreetingKind kind,
    String? consumptionKey,
    ValueChanged<TwaiGreetingPlayedEvent>? onAudiblyPlayed,
  }) = TwaiGreetingRendered;

  /// Fetches the concrete greeting at connect time. The widget
  /// awaits [fetch] on construction, then dispatches whichever
  /// concrete variant comes back.
  ///
  /// Useful when the choice depends on server state (return-greeting
  /// availability check, catalog hydrate, etc.) that the consumer
  /// does not have at widget-construction time.
  ///
  /// NOT WIRED YET into `TwaiTransport0Player` — see [TwaiGreeting.rendered].
  const factory TwaiGreeting.dynamic({
    required Future<TwaiGreeting> Function() fetch,
  }) = TwaiGreetingDynamic;

  /// Convenience constructor: build a [TwaiGreeting.rendered] from a
  /// [TwaiApiGreetingPayload] (what `TwaiApiRestClient.getAvatar()`
  /// returns under `avatar.greeting`). One-line path for the
  /// catalog-hydrate-driven consumer:
  ///
  /// ```dart
  /// final result = await rest.getAvatar(owner: '2wai', name: 'brian-alman');
  /// final greeting = result.avatar.greeting == null
  ///     ? const TwaiGreeting.none()
  ///     : TwaiGreeting.fromCatalog(
  ///         result.avatar.greeting!,
  ///         onAudiblyPlayed: (ev) => confirmGreetingPlayed(ev.consumptionKey),
  ///       );
  /// ```
  ///
  /// Maps the wire kind (`"intro"` / `"return"`) to [GreetingKind]
  /// (`intro` / `returning`; `returning` because `return` is a
  /// reserved Dart keyword). Wire values outside the pair fall back to
  /// [GreetingKind.intro] — the server contract only emits those two
  /// today, and `intro` is the safer default (no consumption POST).
  factory TwaiGreeting.fromCatalog(
    TwaiApiGreetingPayload payload, {
    ValueChanged<TwaiGreetingPlayedEvent>? onAudiblyPlayed,
  }) =>
      TwaiGreeting.rendered(
        id: payload.id,
        videoUrl: payload.videoUrl,
        text: payload.text,
        kind: payload.kind == 'return'
            ? GreetingKind.returning
            : GreetingKind.intro,
        consumptionKey: payload.consumptionKey,
        onAudiblyPlayed: onAudiblyPlayed,
      );
}

/// [TwaiGreeting.none] — the explicit opt-out variant.
final class TwaiGreetingNone extends TwaiGreeting {
  const TwaiGreetingNone();
}

/// [TwaiGreeting.text] — Pattern B. See `TwaiGreeting.text` for the
/// construction contract.
final class TwaiGreetingText extends TwaiGreeting {
  const TwaiGreetingText({
    required this.text,
    required this.scopeId,
    this.onceForever = true,
    this.sendAfterReady = const Duration(milliseconds: 400),
    this.onSent,
  });

  /// The opener message sent to the brain, one time, as a user-shaped
  /// turn. The avatar's reply follows from this prompt.
  final String text;

  /// Persistence key — opaque to the SDK. Scope it to whatever
  /// granularity the opener is "once per" (e.g.,
  /// `'opener:${userId}:${avatarId}'` for per-user-per-avatar,
  /// `'opener:${sku}'` for a product-chat opener).
  final String scopeId;

  /// If true (default): the opener fires at most once per
  /// `scopeId` across app launches (`SharedPreferencesGreetingStore`
  /// persists the flag). If false: once per app session only
  /// (reset by `InMemoryGreetingStore` on cold start). Pass false
  /// to match the current `apps/mmm_demo` behavior; pass true for
  /// a "user has heard this intro already" product-level flag.
  final bool onceForever;

  /// Delay after `onReady` before sending the opener. Covers the
  /// engine's SEND_GRACE_MS window — a send too close to `ready`
  /// risks the first phoneme getting clipped. 400ms is a conservative
  /// safe margin verified across the shipped demos.
  final Duration sendAfterReady;

  /// Fires right after `engine.send(text)` completes successfully.
  /// Consumers that render the chat log should add the opener as a
  /// user message here; it won't surface through `onReplyText` because
  /// `onReplyText` is agent-side only. Does NOT fire if the opener
  /// was skipped because [scopeId] was already sent, or if the send
  /// threw — on error the scopeId is rolled back so a later ready
  /// can retry.
  final VoidCallback? onSent;
}

/// [TwaiGreeting.rendered] — Pattern A. See `TwaiGreeting.rendered`
/// for the construction contract. Phase 2 wiring; type available now.
final class TwaiGreetingRendered extends TwaiGreeting {
  const TwaiGreetingRendered({
    required this.videoUrl,
    required this.text,
    required this.id,
    required this.kind,
    this.consumptionKey,
    this.onAudiblyPlayed,
  });

  /// Signed/public URL for the pre-rendered MP4. gen-2wai mints a
  /// read-SAS; the URL is time-limited.
  final Uri videoUrl;

  /// The script that was spoken in the video. Useful for captions,
  /// chat-log display, or accessibility surfaces.
  final String text;

  /// The server's greeting row id (gen-2wai `GenGreeting.id` or
  /// `GenReturnGreeting.id`). Opaque to the SDK; surfaces so a host
  /// can key its own analytics or confirmation call.
  final String id;

  /// Whether this is a first-visit intro or a return-visit greeting.
  /// Drives the consumption-confirmation decision: intro keys are
  /// no-ops server-side; return keys must be confirmed.
  final GreetingKind kind;

  /// gen-2wai's `rg-{id}-{epoch}` hand-off key for a return greeting,
  /// or null for intros. Pass this back to the server's
  /// `POST /api/gen/greeting/played { key }` from
  /// [onAudiblyPlayed] when `wasAudible` is true.
  final String? consumptionKey;

  /// Fires when the video completes playback. [TwaiGreetingPlayedEvent.wasAudible]
  /// is false when the browser gated audio behind a user gesture
  /// (common first-attempt on mobile) — the server should NOT consume
  /// a return greeting in that case. Consumer typically fires a
  /// best-effort POST to the confirmation endpoint when wasAudible is
  /// true.
  final ValueChanged<TwaiGreetingPlayedEvent>? onAudiblyPlayed;
}

/// [TwaiGreeting.dynamic] — fetches the concrete variant at connect
/// time. Phase 2 wiring; type available now.
final class TwaiGreetingDynamic extends TwaiGreeting {
  const TwaiGreetingDynamic({required this.fetch});

  final Future<TwaiGreeting> Function() fetch;
}

/// Whether a greeting is a first-visit intro or a return greeting
/// (gen-2wai `kind: "intro"` vs `kind: "return"`).
///
/// `returning` is used instead of `return` because `return` is a
/// reserved Dart keyword.
enum GreetingKind { intro, returning }

/// Payload for [TwaiGreetingRendered.onAudiblyPlayed].
///
/// [wasAudible] is the critical bit: a greeting that played muted
/// (browser autoplay gate on mobile first-attempt) must NOT be
/// reported to the server as consumed — the user did not actually
/// experience it.
class TwaiGreetingPlayedEvent {
  const TwaiGreetingPlayedEvent({
    required this.greetingId,
    required this.kind,
    required this.wasAudible,
    this.consumptionKey,
  });

  final String greetingId;
  final GreetingKind kind;
  final bool wasAudible;
  final String? consumptionKey;
}
