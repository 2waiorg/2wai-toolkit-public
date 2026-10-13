// Wire panel — DEV MODE ONLY.
//
// Three sections:
//
// 1. SESSION SNAPSHOT — what the exerciser knows about the current
//    session: avatar / outfit / transport / effective mint-proxy URL /
//    handle status. Snapshot from LabState + the live handle.
//
// 2. MANUAL PROBE — a lightweight HTTP tool for firing arbitrary
//    GET/POST against any URL and inspecting the response inline. Uses
//    package:http (already a dep). Prefills the mint-proxy URL when set
//    so probing /v1/sessions or /v1/avatars is one tap away.
//
// 3. DEBUG FILTER — a live view of TwaiDebugController entries filtered
//    to lines that mention http:// / https:// / ws:// / /v1/ / /ext-api.
//    The SDK doesn't debug-print structured wire events today; anything
//    the app or a consumer decides to print via debugPrint('http: ...')
//    surfaces here. Structured per-request tracing is a future SDK add.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:twai_avatar_sdk/twai_avatar_sdk.dart';

import '../known_avatars.dart' show LabTransport;
import '../lab_state.dart';
import '../lab_shell.dart' show showLabSnack;
import '../theme.dart';

class WirePanel extends StatefulWidget {
  final LabState state;
  const WirePanel({super.key, required this.state});
  @override
  State<WirePanel> createState() => _WirePanelState();
}

class _WirePanelState extends State<WirePanel> {
  final _urlCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  String _method = 'GET';
  bool _probing = false;
  _ProbeResult? _lastResult;
  StreamSubscription<void>? _debugSub;

  @override
  void initState() {
    super.initState();
    // Prefill URL with mint proxy when set.
    _urlCtrl.text = widget.state.milaProxyUrl ?? '';
    widget.state.addListener(_onStateChange);
    _debugSub = TwaiDebugController.instance.changes.listen((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_onStateChange);
    _debugSub?.cancel();
    _urlCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  void _onStateChange() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _probe() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      showLabSnack(context, 'URL is required', bad: true);
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      showLabSnack(context, 'Invalid URL', bad: true);
      return;
    }
    setState(() => _probing = true);
    final stopwatch = Stopwatch()..start();
    try {
      http.Response resp;
      if (_method == 'GET') {
        resp = await http.get(uri).timeout(const Duration(seconds: 15));
      } else {
        resp = await http
            .post(
              uri,
              headers: {'Content-Type': 'application/json'},
              body: _bodyCtrl.text.isEmpty ? null : _bodyCtrl.text,
            )
            .timeout(const Duration(seconds: 15));
      }
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _probing = false;
        _lastResult = _ProbeResult(
          status: resp.statusCode,
          duration: stopwatch.elapsed,
          headers: resp.headers,
          body: _prettyBody(resp),
        );
      });
    } catch (e) {
      stopwatch.stop();
      if (!mounted) return;
      setState(() {
        _probing = false;
        _lastResult = _ProbeResult(
          status: 0,
          duration: stopwatch.elapsed,
          headers: const {},
          body: 'Error: $e',
          isError: true,
        );
      });
    }
  }

  String _prettyBody(http.Response resp) {
    final ct = resp.headers['content-type'] ?? '';
    if (ct.contains('json')) {
      try {
        final decoded = jsonDecode(resp.body);
        return const JsonEncoder.withIndent('  ').convert(decoded);
      } catch (_) {
        return resp.body;
      }
    }
    if (resp.body.length > 4096) {
      return '${resp.body.substring(0, 4096)}\n\n[…truncated at 4KB, total ${resp.body.length} bytes]';
    }
    return resp.body;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return ListView(
      children: [
        // ─── SESSION SNAPSHOT ───────────────────────────────
        Container(
          color: LabColors.chrome,
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          child: const Row(children: [
            Icon(Icons.lan_outlined, size: 16, color: LabColors.accent),
            SizedBox(width: 8),
            Text(
              'Wire inspector — session state + manual probe',
              style: TextStyle(
                  color: LabColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
            ),
          ]),
        ),
        const Divider(),
        const LabSectionHeader(
          label: 'SESSION SNAPSHOT',
          hint: 'What the exerciser knows about the currently-mounted session.',
        ),
        _SnapshotRow(name: 'Avatar', value: s.avatar.avatar.name),
        _SnapshotRow(name: 'Outfit', value: s.currentOutfit.name),
        _SnapshotRow(
            name: 'Pipeline',
            value: s.currentOutfit.pipelineName,
            mono: true),
        _SnapshotRow(
            name: 'Voice ID',
            value: s.avatar.avatar.voiceId,
            mono: true),
        _SnapshotRow(
          name: 'Transport',
          value: switch (s.effectiveTransport) {
            LabTransport.penthouseMseWs => 'Penthouse MSE-over-WS',
            LabTransport.twaiApiRestWss => 'twai-api REST + WSS',
            LabTransport.liveKit => 'LiveKit (WebRTC)',
          },
        ),
        _SnapshotRow(
          name: 'Mint proxy',
          value: s.milaProxyUrl ?? '(none — Adapter-1 doesn\'t need one)',
          mono: s.milaProxyUrl != null,
        ),
        _SnapshotRow(
          name: 'Env',
          value: switch (s.env) {
            EnvKind.staging => 'twaiStaging',
            EnvKind.prod => 'twaiProd',
            EnvKind.twaiApi => 'twaiApi',
          },
        ),
        _SnapshotRow(
            name: 'Path prefix override',
            value: s.pathPrefixOverride ?? '(none — SDK default /ext-api-muse)',
            mono: s.pathPrefixOverride != null),

        // ─── MANUAL PROBE ───────────────────────────────
        const Divider(),
        const LabSectionHeader(
          label: 'MANUAL PROBE',
          hint:
              'Fire an arbitrary GET/POST at any URL. Useful for smoking '
              'the mint proxy directly (/v1/sessions, /v1/avatars) or '
              'staging endpoints. Prefilled with the mint proxy URL.',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              _MethodDropdown(
                value: _method,
                onChanged: (v) => setState(() => _method = v),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _urlCtrl,
                  decoration: const InputDecoration(
                    hintText: 'https://api.example/v1/sessions',
                    hintStyle: TextStyle(color: LabColors.textMuted),
                  ),
                  style: const TextStyle(
                      color: LabColors.text,
                      fontFamily: 'monospace',
                      fontSize: 12),
                ),
              ),
            ]),
            if (_method == 'POST') ...[
              const SizedBox(height: 8),
              TextField(
                controller: _bodyCtrl,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  hintText:
                      '{"avatar_id":"...","mode":"video","voice_id":"..."}',
                  hintStyle: TextStyle(color: LabColors.textMuted),
                ),
                style: const TextStyle(
                    color: LabColors.text,
                    fontFamily: 'monospace',
                    fontSize: 12),
              ),
            ],
            const SizedBox(height: 8),
            Row(children: [
              ElevatedButton.icon(
                icon: _probing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: LabColors.accentOn))
                    : const Icon(Icons.rocket_launch, size: 16),
                label: Text(_probing ? 'PROBING…' : 'SEND'),
                onPressed: _probing ? null : _probe,
              ),
              const SizedBox(width: 8),
              if (_lastResult != null)
                OutlinedButton.icon(
                  icon: const Icon(Icons.clear, size: 14),
                  label: const Text('CLEAR RESULT'),
                  onPressed: () => setState(() => _lastResult = null),
                ),
            ]),
          ]),
        ),
        if (_lastResult != null) _ProbeResultView(result: _lastResult!),

        // ─── DEBUG FILTER ───────────────────────────────
        const Divider(),
        const LabSectionHeader(
          label: 'DEBUG BUFFER — HTTP / WS FILTER',
          hint:
              'Lines from TwaiDebugController that mention URLs or protocols. '
              'Structured per-request tracing is a future SDK add; today this '
              'shows whatever the SDK / app chooses to debugPrint about the wire.',
        ),
        _DebugFilteredView(),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SnapshotRow extends StatelessWidget {
  final String name;
  final String value;
  final bool mono;
  const _SnapshotRow({required this.name, required this.value, this.mono = false});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(
            width: 140,
            child: Text(name,
                style: const TextStyle(
                    color: LabColors.textDim,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                color: LabColors.text,
                fontSize: 12,
                fontFamily: mono ? 'monospace' : null,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ]),
      );
}

class _MethodDropdown extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _MethodDropdown({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: LabColors.chrome,
          border: Border.all(color: LabColors.border),
          borderRadius: BorderRadius.circular(4),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: value,
            dropdownColor: LabColors.chrome,
            style: const TextStyle(
                color: LabColors.text,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace'),
            items: const [
              DropdownMenuItem(value: 'GET', child: Text('GET')),
              DropdownMenuItem(value: 'POST', child: Text('POST')),
            ],
            onChanged: (v) {
              if (v != null) onChanged(v);
            },
          ),
        ),
      );
}

class _ProbeResult {
  final int status;
  final Duration duration;
  final Map<String, String> headers;
  final String body;
  final bool isError;
  _ProbeResult({
    required this.status,
    required this.duration,
    required this.headers,
    required this.body,
    this.isError = false,
  });
}

class _ProbeResultView extends StatelessWidget {
  final _ProbeResult result;
  const _ProbeResultView({required this.result});
  @override
  Widget build(BuildContext context) {
    final ok = result.status >= 200 && result.status < 300;
    final color = result.isError
        ? LabColors.bad
        : ok
            ? LabColors.live
            : LabColors.wait;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          color: color,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(children: [
            Text(
              result.isError
                  ? 'ERROR'
                  : '${result.status}',
              style: TextStyle(
                  color: color == LabColors.live
                      ? LabColors.stage
                      : Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                  fontFamily: 'monospace'),
            ),
            const SizedBox(width: 12),
            Text(
              '${result.duration.inMilliseconds} ms',
              style: TextStyle(
                  color: color == LabColors.live
                      ? LabColors.stage
                      : Colors.white,
                  fontSize: 11),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.copy, size: 14, color: Colors.white),
              tooltip: 'Copy body',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: result.body));
              },
            ),
          ]),
        ),
        if (result.headers.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 4),
            child: Text(
              result.headers.entries
                  .take(6)
                  .map((e) => '${e.key}: ${e.value}')
                  .join('\n'),
              style: const TextStyle(
                  color: LabColors.textDim,
                  fontSize: 10,
                  fontFamily: 'monospace',
                  height: 1.35),
            ),
          ),
          const Divider(height: 1),
        ],
        Container(
          constraints: const BoxConstraints(maxHeight: 360),
          padding: const EdgeInsets.all(10),
          child: SingleChildScrollView(
            child: SelectableText(
              result.body.isEmpty ? '(empty body)' : result.body,
              style: const TextStyle(
                  color: LabColors.text,
                  fontFamily: 'monospace',
                  fontSize: 11,
                  height: 1.35),
            ),
          ),
        ),
      ]),
    );
  }
}

class _DebugFilteredView extends StatelessWidget {
  static final _wirePattern = RegExp(
    r'https?://|wss?://|/v1/|/ext-api|/api/|POST |GET |DELETE ',
    caseSensitive: false,
  );

  @override
  Widget build(BuildContext context) {
    final all = TwaiDebugController.instance.entries;
    final filtered =
        all.where((e) => _wirePattern.hasMatch(e.message)).toList(growable: false);
    if (filtered.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'No wire-shaped debug entries yet. Send a message or trigger a '
          'reconnect to populate. Note: the SDK doesn\'t currently debug-print '
          'structured HTTP events — anything you see here comes from '
          'debugPrint("http: …") calls in the app or SDK.',
          style: TextStyle(color: LabColors.textDim, fontSize: 11, height: 1.4),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final e in filtered.reversed.take(50)) _debugRow(e),
        ],
      ),
    );
  }

  Widget _debugRow(DebugEntry e) {
    final t = e.at;
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    final ss = t.second.toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: DefaultTextStyle(
        style: const TextStyle(
            color: LabColors.text,
            fontFamily: 'monospace',
            fontSize: 10,
            height: 1.3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$hh:$mm:$ss', style: const TextStyle(color: LabColors.textMuted)),
          const SizedBox(width: 8),
          Expanded(child: SelectableText(e.message)),
        ]),
      ),
    );
  }
}
