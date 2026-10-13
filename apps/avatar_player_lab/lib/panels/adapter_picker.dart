// Adapter + avatar picker — the top-left tab of the panel stack.
//
// Per Decision #8 (2026-08-13): descriptive labels, not "Adapter 1/4"
// numbers. Per Decision #9: 5 avatars seeded. Per Decision #7 (everything
// ON): all 5 avatars visible on boot; user picks Sophi by default (boot
// subject).
//
// Two greyed-out "coming soon" adapter rows honor the roadmap without
// pretending they work today.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../known_avatars.dart';
import '../lab_state.dart';
import '../lab_shell.dart' show showLabSnack;
import '../theme.dart';

class AdapterPickerPanel extends StatelessWidget {
  final LabState state;
  const AdapterPickerPanel({super.key, required this.state});

  /// Render every seeded avatar grouped under a mini-header for its
  /// transport. Order matches TRANSPORT list above: T0 first, REST
  /// next, historical MSE last. Empty groups are skipped so the panel
  /// stays terse.
  List<Widget> _avatarsByTransport(LabState s) {
    const groups = <(LabTransport, String)>[
      (LabTransport.liveKit, 'TRANSPORT 0 · LIVEKIT'),
      (LabTransport.twaiApiRestWss, 'REST · twai-api'),
      (LabTransport.penthouseMseWs, 'HISTORICAL · Penthouse MSE'),
    ];
    final out = <Widget>[];
    for (final g in groups) {
      final rows = kSeededAvatars.where((a) => a.transport == g.$1).toList();
      if (rows.isEmpty) continue;
      out.add(Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
        child: Text(
          g.$2,
          style: const TextStyle(
            color: LabColors.textDim,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4,
            fontSize: 9,
          ),
        ),
      ));
      for (final r in rows) {
        out.add(_AvatarRow(seeded: r, state: s));
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) => ListView(
          children: [
            // ── TRANSPORTS ────────────────────────────────────────
            // Three CORE going forward: Transport 0 (LiveKit),
            // REST (twai-api gateway), On-device (Shape #3). The
            // Penthouse MSE wire is boxed at the bottom under
            // HISTORICAL — kept for regression testing until every
            // consumer app migrates.
            const LabSectionHeader(
              label: 'TRANSPORT',
              hint:
                  'Wire layer between the app and the pipeline. Auto-picks per avatar; override to force.',
            ),
            _TransportRow(
              label: 'Transport 0 · LiveKit + WebRTC',
              sub:
                  'THE current live-chat wire · Dart port of Mason\'s engine.ts · '
                  'engine-native widget, no ChatSession shim, no MSE watchdogs',
              value: LabTransport.liveKit,
              state: state,
              live: true,
            ),
            _TransportRow(
              label: 'REST · twai-api gateway',
              sub:
                  'Speak-first request/response over the twai-api HTTP surface · '
                  'Adapter 4 for Mila + echo/SSE Alman',
              value: LabTransport.twaiApiRestWss,
              state: state,
              live: true,
            ),
            const _ComingSoonRow(
              label: 'On-device · Shape #3 (edge)',
              sub:
                  'Local avatar rendering, no network transport · Talk2Jesus '
                  'iOS reference live on App Store · SDK-32 in progress',
            ),
            const LabSectionHeader(
              label: 'HISTORICAL · deprecated wires',
              hint:
                  'Retained for regression testing until every consumer app migrates.',
            ),
            _TransportRow(
              label: 'Penthouse MSE-over-WS (Krystal)',
              sub:
                  'Adapter 1 · Sophi, Bella, Drew native here · retired per ADR-045 + ADR-049',
              value: LabTransport.penthouseMseWs,
              state: state,
              live: true,
            ),
            const Divider(),
            LabSectionHeader(
              label: 'AVATAR',
              hint:
                  'Grouped by transport. Pick a row to swap in place.',
              trailing: _RefreshLiveRosterButton(state: state),
            ),
            ..._avatarsByTransport(state),
            _LiveRosterSection(state: state),
            const Divider(),
            const LabSectionHeader(
              label: 'TWAI-API MINT PROXY',
              hint: 'One field, tenant-scoped. Mila works against Mason\'s '
                  'apimila-demo shared proxy. Dr. Alman needs his own tenant\'s '
                  'proxy (Lumara-style — sk_ + avt_ registered on your tenant); '
                  'apimila-demo won\'t know his avatar_id. NEEDS PROXY is the '
                  'expected state until you fill this in.',
            ),
            _MintProxyField(state: state),
            const Divider(),
            const LabSectionHeader(
              label: 'TWAI-API DIRECT (sk_)',
              hint:
                  'Alternative to mint proxy: paste an sk_test / sk_live key + '
                  'hit api.2wai.ai direct (Mason\'s CORS opt-in). DEV ONLY — '
                  'sk_ in a browser is a firing offense in production. Wins '
                  'over the mint proxy when both are set.',
            ),
            _DirectApiKeyField(state: state),
            const SizedBox(height: 24),
          ],
        ),
      );
}

/// Computed status for each seeded avatar — drives the row badge.
enum _AvatarStatus { live, needsProxy, needsVerification }

_AvatarStatus _statusFor(SeededAvatar s, LabState state) {
  if (s.avatar.slug == 'drew-scott') {
    return _AvatarStatus.needsVerification;
  }
  if (s.transport == LabTransport.twaiApiRestWss) {
    // Either API DIRECT (sk_) or mint proxy unlocks Adapter-4.
    final wired = state.directApiKey != null || state.milaProxyUrl != null;
    return wired ? _AvatarStatus.live : _AvatarStatus.needsProxy;
  }
  return _AvatarStatus.live;
}

class _MintProxyField extends StatefulWidget {
  final LabState state;
  const _MintProxyField({required this.state});
  @override
  State<_MintProxyField> createState() => _MintProxyFieldState();
}

class _MintProxyFieldState extends State<_MintProxyField> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.state.milaProxyUrl ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _ping() async {
    final url = widget.state.milaProxyUrl;
    if (url == null) {
      showLabSnack(context, 'No proxy URL set — APPLY first.', bad: true);
      return;
    }
    widget.state.setProxyStatus(ProxyStatus.checking);
    final sw = Stopwatch()..start();
    try {
      // Try /healthz (Node reference) first, then / as fallback.
      var resp = await http
          .get(Uri.parse('${url.replaceAll(RegExp(r'/$'), '')}/healthz'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 404) {
        resp = await http
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 5));
      }
      sw.stop();
      if (!mounted) return;
      if (resp.statusCode >= 200 && resp.statusCode < 500) {
        widget.state.setProxyStatus(ProxyStatus.ok, ms: sw.elapsedMilliseconds);
      } else {
        widget.state.setProxyStatus(
          ProxyStatus.fail,
          ms: sw.elapsedMilliseconds,
          error: 'HTTP ${resp.statusCode}',
        );
      }
    } catch (e) {
      sw.stop();
      if (!mounted) return;
      widget.state.setProxyStatus(
        ProxyStatus.fail,
        ms: sw.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Row(children: [
            _ProxyStatusLed(state: widget.state),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _ctrl,
                decoration: const InputDecoration(
                  hintText: 'https://your-server/apimila-api',
                  hintStyle: TextStyle(color: LabColors.textMuted),
                ),
                style: const TextStyle(color: LabColors.text, fontSize: 13),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () {
                widget.state.milaProxyUrl = _ctrl.text;
                // Auto-ping on APPLY so status is fresh.
                if (widget.state.milaProxyUrl != null) _ping();
              },
              child: const Text('APPLY'),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.network_check, size: 14),
              label: const Text('PING PROXY'),
              onPressed: widget.state.milaProxyUrl == null ? null : _ping,
            ),
            const SizedBox(width: 6),
            OutlinedButton(
              onPressed: () {
                _ctrl.clear();
                widget.state.milaProxyUrl = null;
              },
              child: const Text('CLEAR'),
            ),
            const SizedBox(width: 8),
            Expanded(child: _ProxyStatusText(state: widget.state)),
          ]),
        ),
      ]);
}

class _ProxyStatusLed extends StatelessWidget {
  final LabState state;
  const _ProxyStatusLed({required this.state});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) {
          final color = switch (state.proxyStatus) {
            ProxyStatus.unknown => LabColors.comingSoon,
            ProxyStatus.checking => LabColors.wait,
            ProxyStatus.ok => LabColors.live,
            ProxyStatus.fail => LabColors.bad,
          };
          return Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: state.proxyStatus == ProxyStatus.ok
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.6),
                        blurRadius: 8,
                        spreadRadius: 1,
                      )
                    ]
                  : null,
            ),
          );
        },
      );
}

class _ProxyStatusText extends StatelessWidget {
  final LabState state;
  const _ProxyStatusText({required this.state});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) {
          final ms = state.proxyPingMs;
          final err = state.proxyPingError;
          final text = switch (state.proxyStatus) {
            ProxyStatus.unknown => 'Not pinged',
            ProxyStatus.checking => 'Pinging…',
            ProxyStatus.ok => 'UP · ${ms ?? "?"} ms',
            ProxyStatus.fail =>
              'DOWN · ${ms != null ? "$ms ms · " : ""}${err ?? ""}',
          };
          final color = switch (state.proxyStatus) {
            ProxyStatus.ok => LabColors.live,
            ProxyStatus.fail => LabColors.bad,
            _ => LabColors.textDim,
          };
          return Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 11),
          );
        },
      );
}

class _TransportRow extends StatelessWidget {
  final String label;
  final String sub;
  final LabTransport value;
  final LabState state;
  final bool live;
  const _TransportRow({
    required this.label,
    required this.sub,
    required this.value,
    required this.state,
    required this.live,
  });
  @override
  Widget build(BuildContext context) {
    final selected = state.effectiveTransport == value;
    final overridden = state.transportOverride == value;
    return InkWell(
      onTap: () {
        // Toggle override: if already forcing this transport, clear override.
        state.transportOverride = overridden ? null : value;
        // Convenience: when the new transport is picked, auto-swap the
        // avatar to the first seeded entry that supports it. Prevents
        // the "clicked LiveKit but stayed on Sophi -> 404 no_such_avatar"
        // trap. No-op when we're clearing the override.
        if (!overridden) {
          final match = kSeededAvatars
              .where((a) => a.transport == value)
              .cast<SeededAvatar?>()
              .firstWhere((_) => true, orElse: () => null);
          if (match != null && !identical(match, state.avatar)) {
            state.avatar = match;
          }
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? LabColors.chrome : LabColors.panel,
          border: Border(
            left: BorderSide(
              color: selected ? LabColors.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: live ? LabColors.live : LabColors.comingSoon,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: LabColors.text,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(sub,
                      style: const TextStyle(
                          color: LabColors.textDim, fontSize: 11)),
                ),
              ],
            ),
          ),
          if (overridden)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                color: LabColors.accent,
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Text('FORCED',
                  style: TextStyle(
                      color: LabColors.accentOn,
                      fontSize: 9,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w800)),
            )
          else if (selected)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(left: 8),
              decoration: BoxDecoration(
                border: Border.all(color: LabColors.live),
                borderRadius: BorderRadius.circular(2),
              ),
              child: const Text('AUTO',
                  style: TextStyle(
                      color: LabColors.live,
                      fontSize: 9,
                      letterSpacing: 1,
                      fontWeight: FontWeight.w800)),
            ),
        ]),
      ),
    );
  }
}

class _ComingSoonRow extends StatelessWidget {
  final String label;
  final String sub;
  const _ComingSoonRow({required this.label, required this.sub});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: const BoxDecoration(
          color: LabColors.panel,
          border: Border(
            left: BorderSide(color: Colors.transparent, width: 3),
          ),
        ),
        child: Row(children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: LabColors.comingSoon,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: LabColors.textDim,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(sub,
                      style: const TextStyle(
                          color: LabColors.textMuted, fontSize: 11)),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: LabColors.comingSoon,
              borderRadius: BorderRadius.circular(2),
            ),
            child: const Text('COMING SOON',
                style: TextStyle(
                    color: LabColors.text,
                    fontSize: 9,
                    letterSpacing: 1,
                    fontWeight: FontWeight.w800)),
          ),
        ]),
      );
}

class _AvatarRow extends StatelessWidget {
  final SeededAvatar seeded;
  final LabState state;
  const _AvatarRow({required this.seeded, required this.state});
  @override
  Widget build(BuildContext context) {
    final selected = state.avatar.avatar.slug == seeded.avatar.slug;
    final transportLabel = switch (seeded.transport) {
      LabTransport.penthouseMseWs => 'PENTHOUSE',
      LabTransport.twaiApiRestWss => 'TWAI-API',
      LabTransport.liveKit => 'TRANSPORT 0',
    };
    final status = _statusFor(seeded, state);
    final (statusLabel, statusColor) = switch (status) {
      _AvatarStatus.live => ('LIVE', LabColors.live),
      _AvatarStatus.needsProxy => ('NEEDS PROXY', LabColors.wait),
      _AvatarStatus.needsVerification => ('NEEDS VERIFY', LabColors.bad),
    };
    return InkWell(
      onTap: () => state.avatar = seeded,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? LabColors.chrome : LabColors.panel,
          border: Border(
            left: BorderSide(
              color: selected ? LabColors.accent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(children: [
                  Text(seeded.avatar.name,
                      style: const TextStyle(
                          color: LabColors.text,
                          fontWeight: FontWeight.w700,
                          fontSize: 13)),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      border: Border.all(color: LabColors.border),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(transportLabel,
                        style: const TextStyle(
                            color: LabColors.textDim,
                            fontSize: 8,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: statusColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(statusLabel,
                        style: TextStyle(
                            color: status == _AvatarStatus.live
                                ? LabColors.stage
                                : Colors.white,
                            fontSize: 8,
                            letterSpacing: 1,
                            fontWeight: FontWeight.w800)),
                  ),
                ]),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(seeded.tagline,
                      style: const TextStyle(
                          color: LabColors.textDim, fontSize: 11)),
                ),
                if (seeded.note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(seeded.note!,
                        style: const TextStyle(
                            color: LabColors.textMuted,
                            fontSize: 10,
                            fontStyle: FontStyle.italic)),
                  ),
              ],
            ),
          ),
        ]),
      ),
    );
  }
}

// ---- REFRESH LIVE ROSTER + view ------------------------------------------

class _RefreshLiveRosterButton extends StatelessWidget {
  final LabState state;
  const _RefreshLiveRosterButton({required this.state});

  Future<void> _refresh(BuildContext context) async {
    state.beginLiveRosterFetch();
    try {
      final resp = await http
          .get(Uri.parse(
              'https://staging.coreledgergroup.com/ext-api-muse/query_avatar'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode != 200) {
        state.setLiveRosterError('HTTP ${resp.statusCode}');
        return;
      }
      // Response shape: {"code":0,"data":[{"avatar_name":"...", ...}, ...]}
      final decoded = _extractAvatarNames(resp.body);
      state.setLiveRoster(decoded);
    } catch (e) {
      state.setLiveRosterError(e.toString());
    }
  }

  static List<String> _extractAvatarNames(String body) {
    final names = <String>[];
    // Cheap-and-cheerful regex extraction — the payload is very large and
    // dart:convert.jsonDecode + Map traversal is slower than needed. The
    // shape is stable: "avatar_name": "SomeName".
    for (final m in RegExp(r'"avatar_name"\s*:\s*"([^"]+)"').allMatches(body)) {
      names.add(m.group(1)!);
    }
    return names;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) => OutlinedButton.icon(
          icon: state.liveRosterFetching
              ? const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: LabColors.accent))
              : const Icon(Icons.cloud_download_outlined, size: 14),
          label: Text(state.liveRoster == null ? 'REFRESH LIVE' : 'REFRESH'),
          onPressed: state.liveRosterFetching ? null : () => _refresh(context),
        ),
      );
}

class _LiveRosterSection extends StatelessWidget {
  final LabState state;
  const _LiveRosterSection({required this.state});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: state,
        builder: (_, __) {
          if (state.liveRoster == null && state.liveRosterError == null) {
            return const SizedBox.shrink();
          }
          if (state.liveRosterError != null) {
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: LabColors.bad.withValues(alpha: 0.15),
                border: Border.all(color: LabColors.bad),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Live-roster refresh failed: ${state.liveRosterError}',
                style: const TextStyle(color: LabColors.text, fontSize: 11),
              ),
            );
          }
          final names = state.liveRoster!;
          // Group by base name (strip TrailingTalk N / _sN suffixes).
          final grouped = <String, List<String>>{};
          for (final n in names) {
            final base = n.replaceAll(RegExp(r'Talk\d+.*$'), '');
            grouped.putIfAbsent(base, () => []).add(n);
          }
          final ts = state.liveRosterFetchedAt!;
          final tsStr = '${ts.hour.toString().padLeft(2, '0')}:'
              '${ts.minute.toString().padLeft(2, '0')}:'
              '${ts.second.toString().padLeft(2, '0')}';
          return Column(children: [
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(children: [
                const Text('LIVE ROSTER',
                    style: TextStyle(
                        color: LabColors.textDim,
                        fontSize: 10,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Text('${names.length} pipelines · ${grouped.length} avatars · fetched $tsStr',
                    style: const TextStyle(
                        color: LabColors.textDim, fontSize: 10)),
              ]),
            ),
            for (final entry in grouped.entries)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
                child: DefaultTextStyle(
                  style: const TextStyle(
                      color: LabColors.text,
                      fontFamily: 'monospace',
                      fontSize: 11,
                      height: 1.3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 200,
                          child: Text(entry.key,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: LabColors.text,
                                  fontWeight: FontWeight.w700)),
                        ),
                        Expanded(
                          child: Text(
                            entry.value.length == 1
                                ? entry.value.first
                                : '${entry.value.length} variants: '
                                    '${entry.value.take(3).join(", ")}${entry.value.length > 3 ? "…" : ""}',
                            style: const TextStyle(color: LabColors.textDim),
                          ),
                        ),
                      ]),
                ),
              ),
          ]);
        },
      );
}

// ---- API DIRECT (sk_) field ---------------------------------------------

class _DirectApiKeyField extends StatefulWidget {
  final LabState state;
  const _DirectApiKeyField({required this.state});
  @override
  State<_DirectApiKeyField> createState() => _DirectApiKeyFieldState();
}

class _DirectApiKeyFieldState extends State<_DirectApiKeyField> {
  late final TextEditingController _ctrl;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.state.directApiKey ?? '');
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: widget.state,
        builder: (_, __) {
          final live = widget.state.directApiKey != null;
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: live ? LabColors.bad : LabColors.comingSoon,
                    shape: BoxShape.circle,
                    boxShadow: live
                        ? [
                            BoxShadow(
                              color: LabColors.bad.withValues(alpha: 0.6),
                              blurRadius: 8,
                              spreadRadius: 1,
                            )
                          ]
                        : null,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    obscureText: _obscure,
                    decoration: InputDecoration(
                      hintText: 'sk_test_… or sk_live_…',
                      hintStyle: const TextStyle(color: LabColors.textMuted),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 16,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    style: const TextStyle(
                        color: LabColors.text,
                        fontFamily: 'monospace',
                        fontSize: 12),
                  ),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                OutlinedButton(
                  onPressed: () {
                    widget.state.directApiKey = _ctrl.text;
                  },
                  child: const Text('APPLY'),
                ),
                const SizedBox(width: 6),
                OutlinedButton(
                  onPressed: () {
                    _ctrl.clear();
                    widget.state.directApiKey = null;
                  },
                  child: const Text('CLEAR'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(children: [
                    Flexible(
                      child: Text(
                        live
                            ? 'DIRECT ACTIVE — hitting api.2wai.ai/v1/*'
                            : 'Inactive',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: live ? LabColors.bad : LabColors.textDim,
                            fontSize: 11,
                            fontWeight: live
                                ? FontWeight.w700
                                : FontWeight.w400),
                      ),
                    ),
                    if (widget.state.directApiKeyFromEnv) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: LabColors.live,
                          borderRadius: BorderRadius.circular(2),
                        ),
                        child: const Text(
                          'FROM ENV',
                          style: TextStyle(
                              color: LabColors.stage,
                              fontSize: 9,
                              letterSpacing: 1,
                              fontWeight: FontWeight.w800),
                        ),
                      ),
                    ],
                  ]),
                ),
              ]),
            ),
          ]);
        },
      );
}

