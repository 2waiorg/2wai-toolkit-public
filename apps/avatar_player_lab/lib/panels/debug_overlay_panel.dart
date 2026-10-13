// Debug overlay panel — DEV MODE ONLY.
//
// Renders the shared TwaiDebugController buffer full-height inside the
// right pane. Because dev-mode activates the controller at boot (see
// main.dart), by the time the user opens this tab the buffer already
// has BUILD tag + platform + any debugPrint / errors captured since
// launch.

import 'package:flutter/material.dart';
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

import '../theme.dart';

class DebugOverlayPanel extends StatelessWidget {
  const DebugOverlayPanel({super.key});

  @override
  Widget build(BuildContext context) => Column(children: [
        Container(
          color: LabColors.chrome,
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: Row(children: [
            const Icon(Icons.bug_report_outlined,
                size: 16, color: LabColors.accent),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'TwaiDebugOverlay — captures debugPrint + FlutterError + PlatformError',
                style: TextStyle(
                    color: LabColors.text,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline, size: 14),
              label: const Text('CLEAR'),
              onPressed: () => TwaiDebugController.instance.clear(),
            ),
          ]),
        ),
        const Divider(),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: TwaiDebugOverlay(
              interactive: true,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.72),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: LabColors.border),
              ),
            ),
          ),
        ),
      ]);
}
