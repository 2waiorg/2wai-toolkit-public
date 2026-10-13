#!/usr/bin/env node
/**
 * MIRROR of `2waiorg/twai-protocol/tools/codec-check.mjs`.
 * Copied into this repo so CI is self-contained (no cross-repo
 * checkout needed for the drift check). Upstream is the
 * spec-of-record — if this mirror drifts, resync from
 * `c:\Dev\twai-protocol\tools\codec-check.mjs`.
 *
 * Codec-drift guard.
 *
 * Scans source trees for any `avc1.42XXXX` H.264 codec literal and fails if
 * any of them is not the golden profile (`avc1.42C01F`). This is the cheap,
 * high-value check that structurally prevents the 2026-07-07 outage class
 * (a stray `42E01F` leaves <video> stuck at HAVE_METADATA).
 *
 *   node tools/codec-check.mjs <path> [<path> ...]
 *
 * Intended to run in CI across every repo that touches the wire:
 *   node tools/codec-check.mjs ../twai-web-sdk/packages ../clg_pp_payment/frontend/src ../../Penthouse/avatar-player/src
 *
 * Exit 0 = clean, exit 1 = drift found.
 */
import { readFileSync, statSync, readdirSync } from 'node:fs'
import { join, extname } from 'node:path'

const GOLDEN = 'avc1.42C01F'
const CODEC_RE = /avc1\.42[0-9A-Fa-f]{4}/g
// Docs (.md) legitimately discuss the 42E01F anti-pattern; the drift guard is
// about executable code, so we scan code + config only.
const EXT_OK = new Set(['.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.dart', '.py', '.json'])
const SKIP_DIR = new Set(['node_modules', '.git', 'dist', 'build', '.next', 'coverage', '.venv'])

const roots = process.argv.slice(2)
if (roots.length === 0) {
  console.error('usage: node tools/codec-check.mjs <path> [<path> ...]')
  process.exit(2)
}

let scanned = 0
const hits = []
const drift = []

function walk(p) {
  let st
  try { st = statSync(p) } catch { return }
  if (st.isDirectory()) {
    for (const name of readdirSync(p)) {
      if (SKIP_DIR.has(name)) continue
      walk(join(p, name))
    }
  } else if (st.isFile() && EXT_OK.has(extname(p))) {
    scanned++
    const txt = readFileSync(p, 'utf8')
    const lines = txt.split('\n')
    lines.forEach((line, i) => {
      // Strip comment context so a doc-comment WARNING about the 42E01F
      // anti-pattern isn't flagged as drift. Skip pure comment / JSDoc lines;
      // cut inline `//` and `#` (dart/py/ts) trailing comments.
      const trimmed = line.trim()
      if (trimmed.startsWith('//') || trimmed.startsWith('*') || trimmed.startsWith('/*') || trimmed.startsWith('#')) return
      const code = line.replace(/\/\/.*$/, '').replace(/#.*$/, '')
      const m = code.match(CODEC_RE)
      if (m) {
        for (const codec of m) {
          const rec = { file: p, line: i + 1, codec, text: line.trim().slice(0, 120) }
          hits.push(rec)
          // Case-insensitive profile compare (42C01F == 42c01f).
          if (codec.toUpperCase() !== GOLDEN.toUpperCase()) drift.push(rec)
        }
      }
    })
  }
}

for (const r of roots) walk(r)

console.log(`codec-check: scanned ${scanned} files, found ${hits.length} codec literal(s)`)
for (const h of hits) console.log(`  ${h.file}:${h.line}  ${h.codec}`)

if (drift.length) {
  console.error(`\nDRIFT: ${drift.length} codec literal(s) are not ${GOLDEN}:`)
  for (const d of drift) console.error(`  ${d.file}:${d.line}  ${d.codec}   ${d.text}`)
  console.error('\nEvery client must use the golden profile. Import MSE_CODECS from @twai/core instead of hardcoding.')
  process.exit(1)
}
console.log(`\nOK — all codec literals are ${GOLDEN}.`)
