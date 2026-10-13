// Shared "coming in Phase X" panel body. Used by every P1 panel scaffold
// in P0 so the tab surface is real but the content is honest about not
// being wired yet.

import 'package:flutter/material.dart';

import '../theme.dart';

class StubPanel extends StatelessWidget {
  final String phase;
  final String title;
  final String description;
  final List<String> bulletKnobs;
  const StubPanel({
    super.key,
    required this.phase,
    required this.title,
    required this.description,
    this.bulletKnobs = const [],
  });

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: LabColors.accent,
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(phase,
                  style: const TextStyle(
                      color: LabColors.accentOn,
                      fontSize: 9,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w800)),
            ),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    color: LabColors.text,
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                    letterSpacing: 0.5)),
          ]),
          const SizedBox(height: 12),
          Text(description,
              style: const TextStyle(color: LabColors.textDim, fontSize: 12)),
          if (bulletKnobs.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Text('KNOBS PLANNED',
                style: TextStyle(
                    color: LabColors.textDim,
                    fontSize: 10,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            for (final knob in bulletKnobs)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('  •  ',
                          style: TextStyle(color: LabColors.accent)),
                      Expanded(
                        child: Text(knob,
                            style: const TextStyle(
                                color: LabColors.text, fontSize: 12)),
                      ),
                    ]),
              ),
          ],
        ],
      );
}
