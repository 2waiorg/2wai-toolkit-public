/// Diff PP's LiveKit-eligible avatars against our tenant registrations
/// and print (or --apply) the exact commands needed to bring the two in
/// sync.
///
/// Read-only by default. `--apply` runs the mutations after a printed
/// confirmation. Runs are safe to re-run: only avatars that don't
/// already exist on our tenant with the same (pipeline_name,
/// livekit_profile) tuple are proposed for registration.
///
/// Sources of truth this tool reads (never edits):
///
///   - PP staging LIVEKIT_AVATAR_SLUGS env on pp-v3-public-test — the
///     authoritative allowlist of profiles the PP broker will accept.
///   - PP frontend `clg_penthouse_pets/frontend/src/lean/avatars.ts`
///     — the pipeline_name + idleUrl per (avatar, outfit).
///   - Our twai-api tenant DB via GET /admin/avatars/{avt_} — current
///     registered rows on the tenant.
///   - HEAD-check every idleUrl before proposing to ship it (Bella
///     black-screen 2026-08-25 was one wrong-URL character).
///
/// Sources of truth this tool WRITES (only under --apply):
///
///   - Our twai-api tenant DB (POST /admin/avatars) — add new rows.
///   - Our twai-api container app env
///     (TWAI_LIVEKIT_ALLOWED_PROFILES_CSV) — append missing profiles.
///
/// Never touches PP's DB / PP's env / broker config on the
/// wav2lip-training VM. Those are Mason's territory.
///
/// Usage:
///
///     dart run tool/register_livekit_avatars.dart
///     dart run tool/register_livekit_avatars.dart --apply
///
/// Optional flags (all with sensible defaults):
///
///     --pp-avatars-ts <path>   Default:
///                              c:/Dev/clg_penthouse_pets/frontend/src/lean/avatars.ts
///     --tenant <id>            Default: ten_0e2277049d82a22bbb02ed30
///     --gateway <url>          Default: https://api.2wai.ai
///     --twai-container <name>  Default: twai-api / rg-2wai-staging
///     --pp-container <name>    Default: pp-v3-public-test / rg-2wai-staging
///     --admin-key <key>        Default: az containerapp secret show ...
library;

import 'dart:convert';
import 'dart:io';

const _defaultPPAvatarsTs =
    'c:/Dev/clg_penthouse_pets/frontend/src/lean/avatars.ts';
const _defaultTenant = 'ten_0e2277049d82a22bbb02ed30';
const _defaultGateway = 'https://api.2wai.ai';
const _defaultTwaiContainer = 'twai-api';
const _defaultTwaiRg = 'rg-2wai-staging';
const _defaultPPContainer = 'pp-v3-public-test';
const _defaultPPRg = 'rg-2wai-staging';
const _blobBase = 'https://2waiassets.blob.core.windows.net/avatars/';

class _Args {
  final String ppAvatarsTs;
  final String tenant;
  final String gateway;
  final String twaiContainer;
  final String twaiRg;
  final String ppContainer;
  final String ppRg;
  final String? adminKey;
  final bool apply;
  /// Outfit-slug allowlist. Default `casual,date,swim` keeps the lab
  /// PG. `--outfits all` disables the filter.
  final Set<String> outfits;

  _Args({
    required this.ppAvatarsTs,
    required this.tenant,
    required this.gateway,
    required this.twaiContainer,
    required this.twaiRg,
    required this.ppContainer,
    required this.ppRg,
    required this.adminKey,
    required this.apply,
    required this.outfits,
  });

  static _Args parse(List<String> argv) {
    String get(String flag, String fallback) {
      final i = argv.indexOf(flag);
      return (i >= 0 && i + 1 < argv.length) ? argv[i + 1] : fallback;
    }

    final outfitsRaw = get('--outfits', 'casual,date,swim');
    final outfits = outfitsRaw == 'all'
        ? <String>{}
        : outfitsRaw
            .split(',')
            .map((s) => s.trim().toLowerCase())
            .where((s) => s.isNotEmpty)
            .toSet();

    return _Args(
      ppAvatarsTs: get('--pp-avatars-ts', _defaultPPAvatarsTs),
      tenant: get('--tenant', _defaultTenant),
      gateway: get('--gateway', _defaultGateway),
      twaiContainer: get('--twai-container', _defaultTwaiContainer),
      twaiRg: get('--twai-rg', _defaultTwaiRg),
      ppContainer: get('--pp-container', _defaultPPContainer),
      ppRg: get('--pp-rg', _defaultPPRg),
      adminKey: argv.contains('--admin-key')
          ? argv[argv.indexOf('--admin-key') + 1]
          : null,
      apply: argv.contains('--apply'),
      outfits: outfits,
    );
  }
}

/// One (avatar, outfit) tuple parsed from PP's avatars.ts.
class _PPEntry {
  final String avatarSlug;
  final String outfitSlug;
  final String pipelineName;
  final String idleUrl;

  _PPEntry({
    required this.avatarSlug,
    required this.outfitSlug,
    required this.pipelineName,
    required this.idleUrl,
  });

  @override
  String toString() =>
      '$avatarSlug/$outfitSlug pipeline=$pipelineName';
}

/// Parse `PP_AVATARS: Avatar[] = [ ... ]` from PP's avatars.ts.
///
/// LINE-BASED, not brace-counting. The PP source uses a stable indent
/// convention: avatar objects are opened by a line matching exactly
/// `^  {$` and closed by `^  },$` or `^  }$`. Outfit objects live
/// one level deeper (`^      {$` etc.) — but for our purposes we
/// only need to slice the file into avatar chunks and grep each with
/// narrow regex. Brace-counting turned out to be too fragile: TS
/// comments and regex-in-source can contain `{`/`}` that the counter
/// treats as syntax, and the parser silently returned zero blocks
/// (verified 2026-08-26 by dry-run against pp-avatars.ts).
List<_PPEntry> _parsePPAvatars(String source) {
  final entries = <_PPEntry>[];
  final lines = source.split('\n');

  final ppStartIdx = lines.indexWhere((l) => l.startsWith('const PP_AVATARS'));
  if (ppStartIdx < 0) {
    stderr.writeln('ERROR: could not find `const PP_AVATARS` line');
    exit(2);
  }
  // Find end of PP_AVATARS array — a line starting with `]` at
  // column 0, after ppStartIdx.
  final ppEndIdx = lines.indexWhere((l) => l.startsWith(']'), ppStartIdx + 1);
  if (ppEndIdx < 0) {
    stderr.writeln('ERROR: could not find end of PP_AVATARS array');
    exit(2);
  }
  final ppSlice = lines.sublist(ppStartIdx + 1, ppEndIdx);

  // Split into avatar chunks by `^  {$` / `^  },$` line markers.
  final avatarChunks = <List<String>>[];
  List<String>? current;
  for (final line in ppSlice) {
    if (line == '  {') {
      current = <String>[];
    } else if (line == '  },' || line == '  }') {
      if (current != null) {
        avatarChunks.add(current);
        current = null;
      }
    } else {
      current?.add(line);
    }
  }

  final avatarSlugRe = RegExp(r"^\s*slug:\s*'([^']+)'");
  final outfitOpenRe = RegExp(r'^      \{$');
  final outfitCloseRe = RegExp(r'^      \},?$');
  final pipelineNameRe = RegExp(r"pipelineName:\s*'([^']+)'");
  final idleUrlBlobRe = RegExp(r"^\s*idleUrl:\s*blob\('([^']+)'\)");

  for (final chunk in avatarChunks) {
    // Avatar slug — first `slug: '...'` at ANY indentation within
    // the top level (before outfits).
    String? avatarSlug;
    for (final line in chunk) {
      final m = avatarSlugRe.firstMatch(line);
      if (m != null) {
        avatarSlug = m.group(1);
        break;
      }
    }
    if (avatarSlug == null) continue;

    // Iterate outfit sub-blocks.
    List<String>? outfitLines;
    for (final line in chunk) {
      if (outfitOpenRe.hasMatch(line)) {
        outfitLines = <String>[];
      } else if (outfitCloseRe.hasMatch(line) && outfitLines != null) {
        // Grep the outfit chunk for pipelineName + idleUrl(blob).
        String? pipeline;
        String? idleBlob;
        for (final ol in outfitLines) {
          pipeline ??= pipelineNameRe.firstMatch(ol)?.group(1);
          idleBlob ??= idleUrlBlobRe.firstMatch(ol)?.group(1);
        }
        // Outfit slug — first `slug: '...'` inside the outfit.
        String? outfitSlug;
        for (final ol in outfitLines) {
          final m = avatarSlugRe.firstMatch(ol);
          if (m != null) {
            outfitSlug = m.group(1);
            break;
          }
        }
        if (pipeline != null && idleBlob != null && outfitSlug != null) {
          entries.add(_PPEntry(
            avatarSlug: avatarSlug,
            outfitSlug: outfitSlug,
            pipelineName: pipeline,
            idleUrl: '$_blobBase$idleBlob',
          ));
        }
        outfitLines = null;
      } else {
        outfitLines?.add(line);
      }
    }
  }
  return entries;
}

/// Run a subprocess and return stdout, throwing on non-zero exit.
Future<String> _run(
  String executable,
  List<String> args, {
  bool quiet = false,
}) async {
  final r = await Process.run(executable, args, runInShell: true);
  if (r.exitCode != 0) {
    if (!quiet) {
      stderr.writeln('$executable ${args.join(' ')}');
      stderr.writeln(r.stderr);
    }
    throw ProcessException(
        executable, args, '${r.stderr}', r.exitCode);
  }
  return (r.stdout as String).trim();
}

Future<Set<String>> _readPPAllowlist(_Args a) async {
  final raw = await _run('az', [
    'containerapp',
    'show',
    '-g',
    a.ppRg,
    '-n',
    a.ppContainer,
    '--query',
    "properties.template.containers[0].env[?name=='LIVEKIT_AVATAR_SLUGS'].value | [0]",
    '-o',
    'tsv',
  ]);
  if (raw.isEmpty || raw == 'null') return <String>{};
  return raw
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();
}

Future<String> _readOurAllowlist(_Args a) async {
  final raw = await _run('az', [
    'containerapp',
    'show',
    '-g',
    a.twaiRg,
    '-n',
    a.twaiContainer,
    '--query',
    "properties.template.containers[0].env[?name=='TWAI_LIVEKIT_ALLOWED_PROFILES_CSV'].value | [0]",
    '-o',
    'tsv',
  ]);
  return raw == 'null' ? '' : raw;
}

Future<String> _fetchAdminKey(_Args a) async {
  return await _run('az', [
    'containerapp',
    'secret',
    'show',
    '-n',
    a.twaiContainer,
    '-g',
    a.twaiRg,
    '--secret-name',
    'admin-key',
    '--query',
    'value',
    '-o',
    'tsv',
  ]);
}

/// Fetch a single avatar row on our tenant by avt_ id. Returns null if
/// gateway 404s (not registered). The gateway has no "list all avatars
/// on a tenant" endpoint — see admin.py — so the tool discovers what
/// we've already registered by reading known_avatars.dart below.
Future<Map<String, Object?>?> _getOurAvatar(
    _Args a, String adminKey, String avtId) async {
  final client = HttpClient();
  try {
    final req =
        await client.getUrl(Uri.parse('${a.gateway}/admin/avatars/$avtId'));
    req.headers.set('Authorization', 'Bearer $adminKey');
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 404) return null;
    if (res.statusCode >= 400) {
      throw HttpException('GET /admin/avatars/$avtId: ${res.statusCode} $body');
    }
    return jsonDecode(body) as Map<String, Object?>;
  } finally {
    client.close();
  }
}

/// Parse T0 registrations already known to our lab (known_avatars.dart).
/// Returns a list of `{avatarSlug, outfitSlug, avtId, pipelineName}`
/// records for every SeededAvatar whose transport is `.liveKit`.
///
/// The gateway has no per-tenant list endpoint, so this file is the
/// tool's authoritative "what have we already registered" source.
class _OurRegistration {
  final String avatarSlug;
  final String outfitSlug;
  final String avtId;
  _OurRegistration({
    required this.avatarSlug,
    required this.outfitSlug,
    required this.avtId,
  });
}

List<_OurRegistration> _parseKnownAvatarsT0(String source) {
  final regs = <_OurRegistration>[];
  final lines = source.split('\n');
  // Scan for PlayerAvatar declarations. Each has a `slug:` and one or
  // more outfits with `slug:` + `pipelineName: 'avt_...'`. We only care
  // about tuples whose pipelineName starts with `avt_` (tenant-scoped
  // registrations, i.e. anything on Transport 0).
  String? currentAvatarSlug;
  String? currentOutfitSlug;
  final slugRe = RegExp(r"slug:\s*'([^']+)'");
  final pipelineRe = RegExp(r"pipelineName:\s*'(avt_[^']+)'");
  for (final line in lines) {
    final s = slugRe.firstMatch(line);
    if (s != null) {
      // The FIRST slug after a PlayerAvatar( opens the avatar; then
      // each PlayerOutfit(...) has its own slug. Since we can't
      // easily know which is which without state, treat every
      // slug: as potentially both: track the latest avatar and
      // outfit slugs, then reset the outfit tracking on a
      // PlayerAvatar keyword.
      if (line.contains('PlayerOutfit') ||
          _hasPreviousOutfitContext(lines, line)) {
        currentOutfitSlug = s.group(1);
      } else {
        currentAvatarSlug = s.group(1);
        currentOutfitSlug = null;
      }
    }
    final p = pipelineRe.firstMatch(line);
    if (p != null &&
        currentAvatarSlug != null &&
        currentOutfitSlug != null) {
      regs.add(_OurRegistration(
        avatarSlug: currentAvatarSlug,
        outfitSlug: currentOutfitSlug,
        avtId: p.group(1)!,
      ));
    }
  }
  return regs;
}

// Very cheap heuristic: look at preceding lines for PlayerOutfit(
// within a small window. If found, this slug: line belongs to an
// outfit, not the avatar. Not perfect — the parser trades some
// robustness for zero deps — but good enough given the small set of
// avatars.
bool _hasPreviousOutfitContext(List<String> allLines, String line) {
  final idx = allLines.indexOf(line);
  if (idx < 0) return false;
  for (var i = idx - 1; i >= 0 && i > idx - 4; i--) {
    if (allLines[i].contains('PlayerOutfit(')) return true;
    if (allLines[i].contains('PlayerAvatar(')) return false;
  }
  return false;
}

Future<int> _headStatus(String url) async {
  final client = HttpClient();
  try {
    final req = await client.headUrl(Uri.parse(url));
    final res = await req.close();
    await res.drain();
    return res.statusCode;
  } catch (e) {
    return -1;
  } finally {
    client.close();
  }
}

/// Register [entry] on the tenant. Returns the created avt_ id on 201,
/// null on failure (message already printed). Caller collects the ids
/// to feed into the known_avatars.dart regeneration.
Future<String?> _register(_Args a, String adminKey, _PPEntry entry,
    {required String displayName}) async {
  final client = HttpClient();
  try {
    final req = await client
        .postUrl(Uri.parse('${a.gateway}/admin/avatars'));
    req.headers.set('Authorization', 'Bearer $adminKey');
    req.headers.set('Content-Type', 'application/json');
    req.write(jsonEncode({
      'tenant_id': a.tenant,
      'name': displayName,
      'pipeline_name': entry.pipelineName,
      'livekit_profile': entry.avatarSlug,
    }));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    if (res.statusCode == 201) {
      final id = _extractAvtId(body);
      stdout.writeln('  ✓ $displayName → $id');
      return id.startsWith('avt_') ? id : null;
    } else {
      stdout.writeln('  ✗ $displayName → HTTP ${res.statusCode}: $body');
      return null;
    }
  } finally {
    client.close();
  }
}

String _extractAvtId(String jsonBody) {
  try {
    final d = jsonDecode(jsonBody);
    if (d is Map && d['id'] is String) return d['id'] as String;
  } catch (_) {}
  return '(no id in response)';
}

Future<void> main(List<String> argv) async {
  if (argv.contains('--help') || argv.contains('-h')) {
    stdout.writeln('See the library-level doc at the top of this file.');
    exit(0);
  }
  final args = _Args.parse(argv);

  stdout.writeln('== register_livekit_avatars ==');
  stdout.writeln('  tenant:       ${args.tenant}');
  stdout.writeln('  gateway:      ${args.gateway}');
  stdout.writeln('  pp-avatars:   ${args.ppAvatarsTs}');
  stdout.writeln('  apply:        ${args.apply}');
  stdout.writeln('');

  // 1. Load PP catalog + allowlist
  final ppSrc = await File(args.ppAvatarsTs).readAsString();
  final ppEntries = _parsePPAvatars(ppSrc);
  stdout.writeln('PP catalog: ${ppEntries.length} (avatar, outfit) tuples');

  final ppAllow = await _readPPAllowlist(args);
  stdout.writeln('PP allowlist (${ppAllow.length}): ${ppAllow.join(', ')}');

  final ourAllow = await _readOurAllowlist(args);
  final ourAllowSet = ourAllow
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty)
      .toSet();
  stdout.writeln('Our allowlist (${ourAllowSet.length}): '
      '${ourAllowSet.join(', ')}');

  // 2. Filter PP catalog:
  //   - avatar slug must be in PP's LiveKit allowlist
  //   - outfit slug must be in --outfits (default casual,date,swim
  //     keeps the lab PG; empty set means allow all)
  final eligible = ppEntries.where((e) {
    if (!ppAllow.contains(e.avatarSlug)) return false;
    if (args.outfits.isNotEmpty && !args.outfits.contains(e.outfitSlug)) {
      return false;
    }
    return true;
  }).toList();
  stdout.writeln('\nEligible (in PP allowlist): '
      '${eligible.length} tuples across '
      '${eligible.map((e) => e.avatarSlug).toSet().length} avatars');
  for (final e in eligible) {
    stdout.writeln('  $e');
  }

  // 3. Load our EXISTING registrations from known_avatars.dart. The
  // gateway has no "list all tenant avatars" endpoint (see admin.py),
  // so this file is the source of truth for "what we've registered".
  final adminKey = args.adminKey ?? await _fetchAdminKey(args);
  const knownAvatarsPath =
      'lib/known_avatars.dart'; // relative to CWD (apps/avatar_player_lab)
  final knownSrc = await File(knownAvatarsPath).readAsString();
  final ourRegs = _parseKnownAvatarsT0(knownSrc);
  stdout.writeln('\nOur registered (from known_avatars.dart): '
      '${ourRegs.length} tuples');
  for (final r in ourRegs) {
    stdout.writeln('  ${r.avatarSlug}/${r.outfitSlug} → ${r.avtId}');
  }

  // Optional: verify each avt_ still exists on the gateway. Any 404
  // means the tenant DB and our lab file have drifted (either the
  // row was deleted or our lab has a stale id). Reported but not
  // corrected — that's a manual decision.
  stdout.writeln('\nVerifying tenant DB rows:');
  for (final r in ourRegs) {
    final row = await _getOurAvatar(args, adminKey, r.avtId);
    if (row == null) {
      stdout.writeln('  ✗ ${r.avtId} (${r.avatarSlug}/${r.outfitSlug}) — 404 on tenant');
    } else {
      final dbPipeline = row['pipeline_name'];
      final ppMatch = ppEntries.firstWhere(
        (e) => e.avatarSlug == r.avatarSlug && e.outfitSlug == r.outfitSlug,
        orElse: () => _PPEntry(
            avatarSlug: '', outfitSlug: '', pipelineName: '', idleUrl: ''),
      );
      final drift = ppMatch.pipelineName.isNotEmpty &&
          dbPipeline != ppMatch.pipelineName;
      final marker = drift ? '⚠ DRIFT' : '✓';
      stdout.writeln('  $marker  ${r.avtId}  db=$dbPipeline'
          '${drift ? "  pp=${ppMatch.pipelineName}" : ""}');
    }
  }

  // 4. Diff: which PP eligible tuples are NOT already registered?
  final ourKey =
      ourRegs.map((r) => '${r.avatarSlug}/${r.outfitSlug}').toSet();
  final missing = eligible
      .where((e) => !ourKey.contains('${e.avatarSlug}/${e.outfitSlug}'))
      .toList();
  stdout.writeln('\nMissing from our tenant: ${missing.length} tuples');

  // 5. HEAD-check each missing entry's idle URL
  stdout.writeln('\nIdle URL health-check:');
  final urlOk = <_PPEntry, bool>{};
  for (final e in missing) {
    final status = await _headStatus(e.idleUrl);
    final ok = status >= 200 && status < 400;
    urlOk[e] = ok;
    stdout.writeln(
        '  ${ok ? "✓" : "✗"} HTTP $status  ${e.avatarSlug}/${e.outfitSlug}  ${e.idleUrl}');
  }

  final registerable = missing.where((e) => urlOk[e] == true).toList();

  // 6. Allowlist diff
  final missingProfiles = registerable
      .map((e) => e.avatarSlug)
      .toSet()
      .where((s) => !ourAllowSet.contains(s))
      .toList();

  stdout.writeln('\n=== REGISTRATION PLAN ===');
  stdout.writeln('New avatar rows: ${registerable.length}');
  for (final e in registerable) {
    stdout.writeln(
        '  POST /admin/avatars  name="${_displayName(e)}"  pipeline=${e.pipelineName}  profile=${e.avatarSlug}');
  }
  if (missingProfiles.isNotEmpty) {
    final newAllow = <String>{...ourAllowSet, ...missingProfiles}.toList()
      ..sort();
    stdout.writeln('\nAllowlist update:');
    stdout.writeln('  TWAI_LIVEKIT_ALLOWED_PROFILES_CSV = ${newAllow.join(",")}');
    stdout.writeln(
        '  az containerapp update -n ${args.twaiContainer} -g ${args.twaiRg} '
        '--set-env-vars TWAI_LIVEKIT_ALLOWED_PROFILES_CSV=${newAllow.join(",")}');
  } else {
    stdout.writeln('\nAllowlist: no updates needed');
  }

  if (!args.apply) {
    stdout.writeln('\n(dry-run — pass --apply to execute)');
    return;
  }

  // 7. Execute
  stdout.writeln('\n=== APPLYING ===');
  final newlyRegistered = <_RegisteredT0>[];
  for (final e in registerable) {
    final avtId = await _register(args, adminKey, e, displayName: _displayName(e));
    if (avtId != null) {
      newlyRegistered.add(_RegisteredT0(
        avatarSlug: e.avatarSlug,
        outfitSlug: e.outfitSlug,
        avtId: avtId,
        idleUrl: e.idleUrl,
      ));
    }
  }
  if (missingProfiles.isNotEmpty) {
    final newAllow = <String>{...ourAllowSet, ...missingProfiles}.toList()
      ..sort();
    stdout.writeln('\nUpdating allowlist env var…');
    try {
      await _run('az', [
        'containerapp',
        'update',
        '-n',
        args.twaiContainer,
        '-g',
        args.twaiRg,
        '--set-env-vars',
        'TWAI_LIVEKIT_ALLOWED_PROFILES_CSV=${newAllow.join(",")}',
        '-o',
        'none',
      ]);
      stdout.writeln('  ✓ allowlist = ${newAllow.join(",")}');
    } catch (e) {
      stdout.writeln('  ✗ allowlist update failed: $e');
    }
  }

  // 8. Rewrite known_avatars.dart. Merge existing regs (avt_ids + look
  // up idleUrl from PP catalog) with the newly-registered ones. This
  // is what makes the tool "auto-add the defs" per Jim's ask — no
  // hand-editing after registration. Backup goes to
  // known_avatars.dart.bak first.
  final fullRegs = <_RegisteredT0>[
    for (final r in ourRegs)
      _RegisteredT0(
        avatarSlug: r.avatarSlug,
        outfitSlug: r.outfitSlug,
        avtId: r.avtId,
        idleUrl: ppEntries
            .firstWhere(
              (p) =>
                  p.avatarSlug == r.avatarSlug && p.outfitSlug == r.outfitSlug,
              orElse: () => _PPEntry(
                avatarSlug: r.avatarSlug,
                outfitSlug: r.outfitSlug,
                pipelineName: '',
                idleUrl: '',
              ),
            )
            .idleUrl,
      ),
    ...newlyRegistered,
  ];
  // Drop `_drAlman` — he's hand-maintained above the markers and the
  // generated block deliberately omits him to avoid conflict. He gets
  // his own SeededAvatar row emitted by the seeded-block generator.
  final regsForCodegen =
      fullRegs.where((r) => r.avatarSlug != 'dr-alman').toList();

  stdout.writeln('\nRegenerating known_avatars.dart T0 blocks…');
  final err = await _regenerateKnownAvatars(
    knownAvatarsPath: knownAvatarsPath,
    regs: regsForCodegen,
    ppLiveKitAllowlist: ppAllow,
  );
  if (err != null) {
    stdout.writeln('  ✗ $err');
  } else {
    stdout.writeln(
        '  ✓ rewrote $knownAvatarsPath (backup at $knownAvatarsPath.bak)');
  }

  stdout.writeln('\nDone.');
}

String _displayName(_PPEntry e) =>
    '${_titleCase(e.avatarSlug)} (${_titleCase(e.outfitSlug)})';

String _titleCase(String slug) => slug
    .split('-')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

/// Full T0 catalog after a successful [--apply] run: existing regs plus
/// the newly-created ones. Feeds the codegen for known_avatars.dart.
class _RegisteredT0 {
  final String avatarSlug;
  final String outfitSlug;
  final String avtId;
  final String idleUrl;
  _RegisteredT0({
    required this.avatarSlug,
    required this.outfitSlug,
    required this.avtId,
    required this.idleUrl,
  });
}

/// Regenerate the TRANSPORT-0-AVATARS-BEGIN/END and
/// TRANSPORT-0-SEEDED-BEGIN/END blocks in [knownAvatarsPath] using
/// [regs]. Writes a `.bak` copy first. Returns null on success, or an
/// error message.
Future<String?> _regenerateKnownAvatars({
  required String knownAvatarsPath,
  required List<_RegisteredT0> regs,
  required Set<String> ppLiveKitAllowlist,
}) async {
  // Filter to avatars actually in PP's LiveKit allowlist. The parser
  // picked up ANY PlayerAvatar with an `avt_` pipeline_name from
  // known_avatars.dart — that includes Adapter-4 avatars like Mila
  // whose pipelineName is also an `avt_` id but who are NOT on
  // Transport 0. Passing them through would put Mila in the T0
  // picker section, which is wrong.
  regs = regs.where((r) => ppLiveKitAllowlist.contains(r.avatarSlug)).toList();
  final file = File(knownAvatarsPath);
  final original = await file.readAsString();

  const avatarsBegin = '// TRANSPORT-0-AVATARS-BEGIN';
  const avatarsEnd = '// TRANSPORT-0-AVATARS-END';
  const seededBegin = '  // TRANSPORT-0-SEEDED-BEGIN';
  const seededEnd = '  // TRANSPORT-0-SEEDED-END';

  for (final marker in [avatarsBegin, avatarsEnd, seededBegin, seededEnd]) {
    if (!original.contains(marker)) {
      return 'missing marker in known_avatars.dart: `$marker`';
    }
  }

  // Group registrations by avatar. Order per PP catalog: krystal-harper,
  // sophi-summers, bella-reid, bella-vaunt (alphabetical is fine — the
  // picker groups by transport, not by insertion order within transport).
  final grouped = <String, List<_RegisteredT0>>{};
  for (final r in regs) {
    grouped.putIfAbsent(r.avatarSlug, () => []).add(r);
  }
  final avatarSlugsSorted = grouped.keys.toList()..sort();

  final avatarsBlock = StringBuffer()
    ..writeln('$avatarsBegin — regenerated by tool/register_livekit_avatars.dart.')
    ..writeln('// Do NOT edit by hand between the markers; --apply overwrites.');
  for (final slug in avatarSlugsSorted) {
    final avatarOutfits = grouped[slug]!
      ..sort((a, b) => a.outfitSlug.compareTo(b.outfitSlug));
    final constName = '_${_camelCase(slug)}T0';
    avatarsBlock
      ..writeln()
      ..writeln('const $constName = PlayerAvatar(')
      ..writeln("  slug: '$slug',")
      ..writeln("  name: '${_titleCase(slug)}',")
      ..writeln("  tagline: 'Transport 0 · ${_titleCase(slug)}',")
      // Empty voiceId → mint closure sends null → broker uses profile
      // default (matches PP's live behaviour).
      ..writeln("  voiceId: '',")
      ..writeln('  outfits: [');
    for (final o in avatarOutfits) {
      avatarsBlock
        ..writeln('    PlayerOutfit(')
        ..writeln("      slug: '${o.outfitSlug}',")
        ..writeln("      name: '${_titleCase(o.outfitSlug)}',")
        ..writeln("      pipelineName: '${o.avtId}',")
        ..writeln("      idleUrl:")
        ..writeln("          '${o.idleUrl}',")
        ..writeln('    ),');
    }
    avatarsBlock
      ..writeln('  ],')
      ..writeln(');');
  }
  avatarsBlock.writeln();
  avatarsBlock.write(avatarsEnd);

  final seededBlock = StringBuffer()
    ..writeln('$seededBegin — regenerated by tool.')
    ..writeln('  // Dr. Alman stays first (boot subject).')
    ..writeln('  SeededAvatar(')
    ..writeln('    avatar: _drAlman,')
    ..writeln('    transport: LabTransport.liveKit,')
    ..writeln(
        "    tagline: 'Transport 0 · Mental-health companion · verified boot subject',")
    ..writeln("    note: 'WebRTC + Soniox · avatar.livekit_profile=livealman',")
    ..writeln('    usesBrain: true,')
    ..writeln('  ),');
  for (final slug in avatarSlugsSorted) {
    final constName = '_${_camelCase(slug)}T0';
    final outfitCount = grouped[slug]!.length;
    seededBlock
      ..writeln('  SeededAvatar(')
      ..writeln('    avatar: $constName,')
      ..writeln('    transport: LabTransport.liveKit,')
      ..writeln(
          "    tagline: 'Transport 0 · ${_titleCase(slug)}',")
      ..writeln(
          "    note: '$outfitCount outfit${outfitCount == 1 ? "" : "s"} · livekit_profile=$slug',")
      ..writeln('  ),');
  }
  seededBlock.write(seededEnd);

  // Replace between markers. Use non-greedy dot-match-newline via
  // multiline flags.
  final avatarsRe = RegExp(
    RegExp.escape(avatarsBegin) + r'.*?' + RegExp.escape(avatarsEnd),
    dotAll: true,
  );
  final seededRe = RegExp(
    RegExp.escape(seededBegin) + r'.*?' + RegExp.escape(seededEnd),
    dotAll: true,
  );

  var updated = original.replaceFirst(avatarsRe, avatarsBlock.toString());
  updated = updated.replaceFirst(seededRe, seededBlock.toString());

  if (updated == original) {
    return 'regeneration produced no diff (markers matched but block was identical)';
  }

  await File('$knownAvatarsPath.bak').writeAsString(original);
  await file.writeAsString(updated);
  return null;
}

/// `krystal-harper` -> `krystalHarper`
String _camelCase(String slug) {
  final parts = slug.split('-');
  if (parts.isEmpty) return slug;
  final head = parts.first;
  final tail = parts
      .skip(1)
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join();
  return '$head$tail';
}
