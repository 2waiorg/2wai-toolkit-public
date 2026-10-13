// TwaiChatAutoScroller — small helper widget that jumps a scrollable
// to its max extent whenever [itemCount] increases. Intended for chat
// logs — wrap your ListView + pass the message-count. Toggling
// [enabled] false lets the user hold their scroll position while
// still receiving new messages.
//
// Kept intentionally minimal: the SDK doesn't own the scrollable, the
// list widget, or the message model. Consumer builds the ListView;
// this widget just orchestrates the post-frame scroll jump.

import 'package:flutter/material.dart';

class TwaiChatAutoScroller extends StatefulWidget {
  final ScrollController controller;
  final Widget child;
  final bool enabled;
  final int itemCount;
  final Duration animationDuration;
  final Curve animationCurve;

  const TwaiChatAutoScroller({
    super.key,
    required this.controller,
    required this.child,
    required this.itemCount,
    this.enabled = true,
    this.animationDuration = const Duration(milliseconds: 220),
    this.animationCurve = Curves.easeOut,
  });

  @override
  State<TwaiChatAutoScroller> createState() => _TwaiChatAutoScrollerState();
}

class _TwaiChatAutoScrollerState extends State<TwaiChatAutoScroller> {
  int _lastCount = 0;

  @override
  void initState() {
    super.initState();
    _lastCount = widget.itemCount;
  }

  @override
  void didUpdateWidget(covariant TwaiChatAutoScroller oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && widget.itemCount > _lastCount) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jump());
    }
    _lastCount = widget.itemCount;
  }

  void _jump() {
    if (!mounted) return;
    if (!widget.controller.hasClients) return;
    final target = widget.controller.position.maxScrollExtent;
    if (widget.animationDuration == Duration.zero) {
      widget.controller.jumpTo(target);
    } else {
      widget.controller.animateTo(
        target,
        duration: widget.animationDuration,
        curve: widget.animationCurve,
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
