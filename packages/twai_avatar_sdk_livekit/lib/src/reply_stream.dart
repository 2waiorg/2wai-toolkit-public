/// Dart port of `clg_penthouse_pets/frontend/src/lean/reply_stream.ts`.
///
/// The `2wai.reply` LiveKit data topic carries ordered protocol frames
/// (start/delta/end|cancel|error) that assemble into a streaming
/// assistant reply. [ReplyStreamReducer] accumulates deltas by
/// `reply_id` + `seq`, fires callbacks as text grows, and enforces the
/// direction-tag strip that Alex insisted on before shipping — a
/// mistaken tag reaching the training corpus is a much harder failure
/// to notice than one visible in the chat feed.
///
/// Kept mechanically parallel to the TypeScript so a bug fixed in
/// either can be lifted verbatim.
library;

/// Voice Expression tags — an EXACT vocabulary from
/// `avatar-brain/src/core/expression.py`. Do NOT switch to a generic
/// `\[[^\]]*\]` sweep: the app renders `[CARD: ...]` markers as tap
/// chips, and a greedy strip would eat them.
const _expressionTags = <String>{
  // base tier — any avatar
  'happy', 'delighted', 'excited', 'curious', 'calm',
  'sad', 'fearful', 'surprised',
  'teasing', 'playful', 'warm', 'gentle', 'serious', 'confident',
  'laughs', 'giggles', 'sighs', 'gasps', 'breathes deeply',
  'whispering', 'softly', 'low voice', 'shouting',
  // adult tier — adult-classed avatars only
  'flirty', 'breathy', 'moans', 'sultry', 'sensual', 'seductive', 'aroused',
};

// The optional `\*?` and the surrounding `\s*` are load-bearing, not
// defensive padding. The brain renders a tag at one of four emphasis levels —
// `[tag]`, `[TAG]`, `[*tag*]`, `[*TAG*]` (avatar-brain `expression_tuning.py`)
// — and `whispering` is STARRED BY DEFAULT because the plain form doesn't
// read as a whisper by ear. So the single most common tag on the platform
// arrives in a form the plain pattern can't match, and `[*whispering*]`
// renders raw into the chat bubble on every gen avatar. Match all four
// levels here.
//
// FOUR copies of this pattern now exist across the stack: here (Dart),
// `twai-web-sdk/packages/core/src/replyStream.ts` (JS, ca30749 2026-09-05),
// `clg_pp_payment/frontend/src/lean/reply_stream.ts` (PP, fixed 2026-08-27),
// and `avatar-brain/src/core/expression.py` `_ANY_TAG`. They drift silently
// and the symptom is a raw tag on screen. Change one, change all four.
final RegExp _expressionTagRe = RegExp(
  '\\[\\s*\\*?\\s*(?:${_expressionTags.join('|')})\\s*\\*?\\s*\\]\\s*',
  caseSensitive: false,
);

/// Remove audio tags from text bound for the chat feed.
String stripExpressionTags(String text) {
  if (text.isEmpty || !text.contains('[')) return text;
  return text.replaceAll(_expressionTagRe, '');
}

enum ReplyTerminalKind { end, cancel, error }

/// One frame from the `2wai.reply` topic. Untyped `text` is present for
/// delta and end frames.
class ReplyFrame {
  final int v;
  final String replyId;
  final int seq;
  final String kind;   // 'start' | 'delta' | 'end' | 'cancel' | 'error'
  final String? text;

  const ReplyFrame({
    required this.v,
    required this.replyId,
    required this.seq,
    required this.kind,
    this.text,
  });

  static const _validKinds = {'start', 'delta', 'end', 'cancel', 'error'};

  static ReplyFrame? tryParse(Object? json) {
    if (json is! Map) return null;
    final v = json['v'];
    final replyId = json['reply_id'];
    final seq = json['seq'];
    final kind = json['kind'];
    if (v != 1 || replyId is! String || seq is! int || kind is! String) {
      return null;
    }
    // Junk on the reply topic must not latch `sawProtocol` (which
    // suppresses fallback transcription): reject empty reply_id,
    // negative seq, and unknown kinds here rather than at apply().
    if (replyId.isEmpty) return null;
    if (seq < 0) return null;
    if (!_validKinds.contains(kind)) return null;
    // If `text` is present it must be a string; a numeric text (e.g.
    // brain bug emitting an int) is a malformed frame, not a
    // text-less one.
    final rawText = json['text'];
    if (rawText != null && rawText is! String) return null;
    return ReplyFrame(
      v: v,
      replyId: replyId,
      seq: seq,
      kind: kind,
      text: rawText as String?,
    );
  }
}

typedef ReplyId = String;

/// Strict in-order reducer for the `2wai.reply` data topic.
///
/// Semantics ported verbatim from the TypeScript:
///
/// - A `start` frame with `seq: 0` opens a reply. Any `start` with a new
///   `reply_id` replaces the current one (out-of-band cancellation).
/// - `delta` frames must arrive with strictly monotonic `seq`. Gaps or
///   duplicates are silently dropped (the sender is single-writer FIFO).
/// - Terminal frames (`end`/`cancel`/`error`) close the current reply.
///   The `text` field on terminals, when present, becomes the canonical
///   text (reconciles any late-lost delta).
/// - Direction tags are stripped from displayed text unless [keepTags]
///   returns true (admin-review mode).
class ReplyStreamReducer {
  final void Function(ReplyId id)? onStart;
  final void Function(String text, ReplyId id)? onText;
  final void Function(String text, ReplyTerminalKind kind, ReplyId id)? onComplete;
  final bool Function()? keepTags;

  String? _activeId;
  int _nextSeq = 0;
  String _text = '';
  bool _protocolSeen = false;

  ReplyStreamReducer({
    this.onStart,
    this.onText,
    this.onComplete,
    this.keepTags,
  });

  /// True once ANY protocol frame (start/delta/terminal) has been
  /// observed. LiveKit's fallback `lk.transcription` handler checks
  /// this to avoid double-publishing when both channels fire.
  bool get sawProtocol => _protocolSeen;

  void reset() {
    _activeId = null;
    _nextSeq = 0;
    _text = '';
    _protocolSeen = false;
  }

  String _clean(String text) => (keepTags?.call() ?? false)
      ? text
      : stripExpressionTags(text);

  void apply(ReplyFrame frame) {
    _protocolSeen = true;
    switch (frame.kind) {
      case 'start':
        if (frame.seq != 0) return;   // malformed; ignore
        _activeId = frame.replyId;
        _nextSeq = 1;
        _text = '';
        onStart?.call(frame.replyId);
      case 'delta':
        if (_activeId != frame.replyId) return;
        if (frame.seq != _nextSeq) return;
        _nextSeq++;
        final chunk = frame.text ?? '';
        if (chunk.isEmpty) return;
        // Strip per CHUNK, not per buffer. Tag stripping is anchored
        // on a completed `[tag]` in a single delta; a tag split
        // across two deltas ("[fli" then "rty] hi") matches neither
        // chunk and leaks into the emitted text until the terminal
        // frame repairs it. See the `a_tag_split_across_two_deltas
        // _leaks_transiently_and_is_repaired_at_completion` vector.
        _text += _clean(chunk);
        onText?.call(_text, frame.replyId);
      case 'end':
      case 'cancel':
      case 'error':
        if (_activeId != frame.replyId) return;
        // Terminal `text` (canonical assembled string) overrides
        // whatever the reducer built from deltas — reconciles any
        // in-flight loss AND repairs a Voice Expression tag split
        // across deltas (a tag pattern only matches within one
        // chunk, so the split-tag repair only fires here).
        //
        // Emit onText once with the repaired text BEFORE onComplete
        // if the cleaned terminal text differs from what the last
        // onText delivered — that's what repaints the bubble. If
        // the terminal matches the buffer (uninterrupted happy
        // path), skip the redundant text event so the same bubble
        // is not repainted with the identical string.
        final finalText = frame.text ?? _text;
        final kind = switch (frame.kind) {
          'cancel' => ReplyTerminalKind.cancel,
          'error' => ReplyTerminalKind.error,
          _ => ReplyTerminalKind.end,
        };
        // Terminal text is authoritative and represents the whole
        // reply, so it is stripped as a WHOLE (which repairs any
        // split-tag leak that the per-chunk strip could not catch).
        // Compare against the running (already per-chunk-cleaned)
        // buffer; only emit a repair text event when they differ.
        final cleanedFinal = _clean(finalText);
        if (cleanedFinal != _text) {
          onText?.call(cleanedFinal, frame.replyId);
        }
        onComplete?.call(cleanedFinal, kind, frame.replyId);
        _activeId = null;
        _nextSeq = 0;
        _text = '';
      default:
        // Unknown kind — silently drop, but keep protocolSeen set so
        // the fallback path stays disabled for this reply.
    }
  }
}
