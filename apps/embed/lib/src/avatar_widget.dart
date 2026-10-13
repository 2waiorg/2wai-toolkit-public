import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';
import 'package:twai_avatar_sdk_livekit/transport0.dart' as t0;

/// Video-only embed widget. The host page drives the chat — there's no
/// input field, no message bubbles, just the avatar video and its idle
/// loop.
///
/// The page wires up its own send button via `element.send(text)`; it
/// can also listen for `reply`, `speaking-start`, `speaking-end` events
/// on the host element to update its own UI.
class TwaiAvatarWidget extends StatelessWidget {
  const TwaiAvatarWidget({
    super.key,
    required this.mint,
    required this.idleUrl,
    required this.onEngine,
    required this.onState,
    required this.onSpeaking,
    required this.onReplyText,
    required this.onEnded,
    required this.onError,
  });

  final Future<t0.MintResult> Function() mint;
  final String? idleUrl;
  final void Function(t0.LiveKitEngine) onEngine;
  final void Function(t0.EngineState) onState;
  final void Function(t0.SpeakingActiveEvent) onSpeaking;
  final void Function(t0.ReplyTextEvent) onReplyText;
  final void Function(t0.EndedEvent) onEnded;
  final void Function(Object) onError;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF000000),
      child: t0.TwaiTransport0Player(
        mint: mint,
        idleBuilder: (ctx) => idleUrl != null && idleUrl!.isNotEmpty
            ? NetworkVideoIdle(Uri.parse(idleUrl!)).build(ctx)
            : const ColoredBox(color: Colors.black),
        onEngine: onEngine,
        onState: onState,
        onSpeaking: onSpeaking,
        onReplyText: onReplyText,
        onEnded: onEnded,
        onError: onError,
      ),
    );
  }
}
