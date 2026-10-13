// Credentials panel — 5 credential types.
//
// Selection updates LabState.credKind and bumps rebuildToken. The shell's
// _buildHandleFor consumes it when constructing twai-api transport (P2
// wiring; Adapter 1 doesn't use credentials).
//
// The apiKeyDevOnly row shows a danger banner — shipping an sk_ key to
// the browser is a firing offense.

import 'package:flutter/material.dart';

import '../lab_state.dart';
import '../theme.dart';

class CredentialsPanel extends StatelessWidget {
  final LabState state;
  const CredentialsPanel({super.key, required this.state});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) => ListView(
          children: [
            const LabSectionHeader(
              label: 'CREDENTIALS',
              hint:
                  'Which TwaiCredentials the SDK uses for twai-api transport. '
                  'Adapter-1 penthouse transport ignores this — it uses default anon.',
            ),
            _CredRow(
              value: CredKind.anonymous,
              label: 'AnonymousCredentials',
              sub: 'No auth. Default for staging development.',
              state: state,
            ),
            _CredRow(
              value: CredKind.publicKey,
              label: 'PublicKeyCredentials',
              sub: 'pk_… tenant public key. Safe for browsers.',
              state: state,
            ),
            _CredRow(
              value: CredKind.viewToken,
              label: 'ViewTokenCredentials',
              sub: 'Short-lived view tokens (gen-2wai flow).',
              state: state,
            ),
            _CredRow(
              value: CredKind.bearerJwt,
              label: 'BearerJwtCredentials',
              sub: 'Customer-issued JWTs (Lumara integration pattern).',
              state: state,
            ),
            _CredRow(
              value: CredKind.apiKeyDevOnly,
              label: 'TwaiApiKeyCredentials.devOnly()',
              sub: 'sk_… key in the browser. Development only.',
              state: state,
              danger: true,
            ),
            if (state.credKind == CredKind.apiKeyDevOnly)
              const _DangerBanner(),
            const SizedBox(height: 16),
            const _WiringNote(),
            const SizedBox(height: 24),
          ],
        ),
      );
}

class _CredRow extends StatelessWidget {
  final CredKind value;
  final String label;
  final String sub;
  final LabState state;
  final bool danger;
  const _CredRow({
    required this.value,
    required this.label,
    required this.sub,
    required this.state,
    this.danger = false,
  });
  @override
  Widget build(BuildContext context) {
    final selected = state.credKind == value;
    return InkWell(
      onTap: () => state.credKind = value,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? LabColors.chrome : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: selected
                  ? (danger ? LabColors.bad : LabColors.accent)
                  : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected
                    ? (danger ? LabColors.bad : LabColors.accent)
                    : LabColors.border,
                width: 2,
              ),
              color: selected
                  ? (danger ? LabColors.bad : LabColors.accent)
                  : Colors.transparent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Text(label,
                      style: const TextStyle(
                          color: LabColors.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 13)),
                  if (danger)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: LabColors.bad,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: const Text('DEV ONLY',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1)),
                      ),
                    ),
                ]),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(sub,
                      style: const TextStyle(
                          color: LabColors.textDim, fontSize: 11)),
                ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

class _DangerBanner extends StatelessWidget {
  const _DangerBanner();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: LabColors.bad.withValues(alpha: 0.15),
          border: Border.all(color: LabColors.bad),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Row(children: [
          Icon(Icons.warning_amber_rounded,
              color: LabColors.bad, size: 20),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'sk_ keys in the browser leak your tenant. Only use this in '
              'a dev-mode + local-only build. Never ship a production bundle '
              'with this credential type selected.',
              style: TextStyle(
                  color: LabColors.text, fontSize: 12, height: 1.4),
            ),
          ),
        ]),
      );
}

class _WiringNote extends StatelessWidget {
  const _WiringNote();
  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: LabColors.chrome,
          border: Border.all(color: LabColors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'P1 wires the selection into LabState only. Full twai-api client '
          'construction (baseUrl + credential dispatch) lands in P2 alongside '
          'the CORS-direct-vs-mint-proxy toggle. Adapter-1 (penthouse) transport '
          'ignores credentials in staging.',
          style: TextStyle(
              color: LabColors.textDim, fontSize: 12, height: 1.4),
        ),
      );
}
