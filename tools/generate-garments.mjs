#!/usr/bin/env node
/**
 * Builds the fitting room's garment pictures and names from a collected clothing set.
 *
 *   npm i --no-save sharp
 *   node tools/generate-garments.mjs <collection-dir>
 *
 * `<collection-dir>` is a clothing collection as the owner stages it: `manifest.json`
 * (one row per picture: slug, name, file, gender f|m, records), `items-catalogue.json`
 * (the server's own items table: record -> wardrobe slot) and `images/*.png`.
 *
 * WRITES, and nothing else:
 *   ui/public/images/clothing/*.webp          the pictures, re-encoded and deduplicated
 *   ui/public/images/clothing/ATTRIBUTION.md  where they came from, and whose they are
 *   modules/appearance/data/garments-<n>.lua  record -> name + picture per body family
 *
 * `npm run build` then copies `ui/public/images` to `web/images`, which is what ships.
 *
 * ONLY RECORDS THE SERVER KNOWS. A picture whose record is not in the server's items
 * table with a wardrobe slot is a file every client downloads and no fitting room can
 * ever show, so it is left out rather than shipped.
 *
 * WEBP AT 160 PX. A box in the picker grid is about 90 CSS pixels wide, so 160 still
 * covers a 1.75x surface; the 200 px source is a quarter more bytes for nothing a
 * player can see. Everything under `web/` is shipped to every client.
 *
 * THE LUA IS SHARDED, and for the reason `modules/inventory/shared/catalog.lua` gives:
 * the host checks a script's load time every 10,000 VM instructions and cancels the
 * whole resource set when a check falls past its deadline. A garment row costs about
 * eight and a half instructions to construct (measured), so a part holds at most
 * ROWS_PER_PART -- about 3,400 -- and stays well clear.
 * `tests/run.lua` measures every part against that ceiling.
 *
 * SHORT FILE NAMES. A client installs a server's resources under
 * `<game>/red4ext/plugins/Open77/cache/server-resources/sets/<64-hex>/resources/<resource>/`,
 * which on a Steam install in Program Files leaves 59 characters of MAX_PATH for a
 * file's path inside the resource, and one file past that fails the WHOLE resource on
 * that client. Every shipped path is held to 47 (59 less a 12-character margin for a
 * game installed deeper), and the wiki slugs ran to 59 here. A picture is therefore
 * named by the first HASH_LENGTH hex digits of the SHA-256 of its slug: deterministic
 * for a given collection, 35 characters as `web/images/clothing/<hash>.webp`, and
 * checked for collisions below. `tests/run.lua` holds every file under `web/` to the
 * same 47.
 *
 * sharp is NOT a dependency of this repository on purpose: it is a native binary every
 * `npm ci` would download for a step that runs when the owner restages the pictures.
 */
import { createHash } from 'node:crypto'
import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const IMAGES_OUT = join(ROOT, 'ui/public/images/clothing')
const DATA_OUT = join(ROOT, 'modules/appearance/data')

const SIZE = 160
const QUALITY = 75
const ALPHA_QUALITY = 80
const ROWS_PER_PART = 400
const HASH_LENGTH = 10
// The room a client leaves a shipped path (see above), less the margin.
const SHIPPED_PATH_MAX = 59 - 12
const SHIPPED_PREFIX = 'web/images/clothing/'

// The catalogue's slot names, mapped to the fitting room's. A record in a slot not
// listed here is not something the room dresses.
const SLOTS = {
  head: 'Head',
  face: 'Face',
  inner_chest: 'InnerChest',
  outer_chest: 'OuterChest',
  legs: 'Legs',
  feet: 'Feet',
  outfit: 'Outfit'
}

// The same bounds `modules/appearance/client/garments.lua` checks at run time.
const FILE_PATTERN = /^[A-Za-z0-9_.-]+$/
const FILE_MAX = 64
const NAME_MAX = 120

async function loadSharp() {
  try {
    return (await import('sharp')).default
  } catch {
    console.error('sharp is not installed. Run `npm i --no-save sharp` first.')
    process.exit(1)
  }
}

/** A Lua string literal. UTF-8 passes through; only what would end or bend it is escaped. */
function lua(text) {
  return `"${String(text).replace(/[\\"]/g, (c) => `\\${c}`).replace(/[\x00-\x1f\x7f]/g,
    (c) => `\\${String(c.charCodeAt(0)).padStart(3, '0')}`)}"`
}

/** Lua checks UTF-8 bytes, so cut whole characters within that same limit. */
function garmentName(value) {
  let name = ''
  let bytes = 0
  for (const character of String(value).trim()) {
    bytes += Buffer.byteLength(character, 'utf8')
    if (bytes > NAME_MAX) break
    name += character
  }
  return name
}

/** The shipped file name of a picture: a short, deterministic hash of its slug. */
function fileName(slug) {
  return `${createHash('sha256').update(slug).digest('hex').slice(0, HASH_LENGTH)}.webp`
}

/** Which of several pictures of one record and one body to keep. The most specific wiki
    page wins (fewest records on it), then the slug without a variant suffix, then the
    slug itself -- so a rerun on the same collection writes the same files. */
function better(a, b) {
  if (a.records.length !== b.records.length) return a.records.length - b.records.length
  const ax = /-x$/.test(a.slug) ? 1 : 0
  const bx = /-x$/.test(b.slug) ? 1 : 0
  if (ax !== bx) return ax - bx
  return a.slug < b.slug ? -1 : a.slug > b.slug ? 1 : 0
}

async function main() {
  const source = process.argv[2]
  if (!source) {
    console.error('usage: node tools/generate-garments.mjs <collection-dir>')
    process.exit(2)
  }
  const sharp = await loadSharp()
  const manifest = JSON.parse(readFileSync(join(source, 'manifest.json'), 'utf8'))
  const catalogue = JSON.parse(readFileSync(join(source, 'items-catalogue.json'), 'utf8'))

  const slotOf = new Map()
  for (const row of catalogue.records) {
    if (SLOTS[row.slot]) slotOf.set(row.record, SLOTS[row.slot])
  }

  // record -> { f: entry, m: entry }
  const chosen = new Map()
  let unknown = 0
  for (const entry of manifest) {
    if (entry.gender !== 'f' && entry.gender !== 'm') continue
    for (const record of entry.records || []) {
      if (!slotOf.has(record)) { unknown++; continue }
      const held = chosen.get(record) || {}
      if (!held[entry.gender] || better(entry, held[entry.gender]) < 0) held[entry.gender] = entry
      chosen.set(record, held)
    }
  }

  // Encode every picture that is used, once, and fold identical pixels onto one file.
  rmSync(IMAGES_OUT, { recursive: true, force: true })
  mkdirSync(IMAGES_OUT, { recursive: true })
  const fileOfSlug = new Map()
  const slugOfFile = new Map()
  const fileOfPixels = new Map()
  const slugs = new Set()
  for (const held of chosen.values()) for (const entry of Object.values(held)) slugs.add(entry.slug)
  const bySlug = new Map(manifest.map((entry) => [entry.slug, entry]))
  let bytes = 0
  let folded = 0
  for (const slug of [...slugs].sort()) {
    const entry = bySlug.get(slug)
    const input = readFileSync(join(source, entry.file))
    const pixels = await sharp(input).ensureAlpha().raw().toBuffer()
    const key = createHash('sha256').update(pixels).digest('hex')
    if (fileOfPixels.has(key)) {
      fileOfSlug.set(slug, fileOfPixels.get(key))
      folded++
      continue
    }
    const file = fileName(slug)
    if (!FILE_PATTERN.test(file) || file.length > FILE_MAX) throw new Error(`unusable file name ${file}`)
    if ((SHIPPED_PREFIX + file).length > SHIPPED_PATH_MAX) throw new Error(`file name too long: ${file}`)
    if (slugOfFile.has(file)) throw new Error(`file name ${file} names both ${slugOfFile.get(file)} and ${slug}`)
    slugOfFile.set(file, slug)
    const out = await sharp(input)
      .resize(SIZE, SIZE, { fit: 'inside', withoutEnlargement: true })
      .webp({ quality: QUALITY, alphaQuality: ALPHA_QUALITY, effort: 6 })
      .toBuffer()
    writeFileSync(join(IMAGES_OUT, file), out)
    bytes += out.length
    fileOfPixels.set(key, file)
    fileOfSlug.set(slug, file)
  }

  // The Lua, sorted by record so a diff between two runs is a diff of the data.
  const records = [...chosen.keys()].sort()
  const rows = records.map((record) => {
    const held = chosen.get(record)
    const named = garmentName((held.f || held.m).name)
    const fields = [`NAME = ${lua(named)}`]
    if (held.f) fields.push(`FEMALE = ${lua(fileOfSlug.get(held.f.slug))}`)
    if (held.m) fields.push(`MALE = ${lua(fileOfSlug.get(held.m.slug))}`)
    return `\t[${lua(record)}] = { ${fields.join(', ')} },`
  })

  for (const name of readdirSync(DATA_OUT, { withFileTypes: true })) {
    if (name.isFile() && /^garments-\d+\.lua$/.test(name.name)) rmSync(join(DATA_OUT, name.name))
  }
  mkdirSync(DATA_OUT, { recursive: true })
  // As few parts as the ceiling allows, and the rows spread evenly across them: a
  // last part holding three rows is a file that exists for no reason.
  const parts = Math.ceil(rows.length / ROWS_PER_PART)
  const perPart = Math.ceil(rows.length / parts)
  const written = []
  for (let part = 0; part < parts; part++) {
    const slice = rows.slice(part * perPart, (part + 1) * perPart)
    const file = `garments-${part + 1}.lua`
    written.push(`modules/appearance/data/${file}`)
    writeFileSync(join(DATA_OUT, file), [
      `--- The fitting room's garment names and pictures, part ${part + 1} of ${parts}.`,
      '-- GENERATED by tools/generate-garments.mjs. Do not edit: rerun it on the collection.',
      '--',
      '-- Record -> { NAME, FEMALE, MALE }: the item\'s own name, and the picture of it on',
      '-- each body family, as a file under web/images/clothing/. Either picture may be',
      '-- missing; `client/garments.lua` falls back to the other one, then to none.',
      '-- Names: Cyberpunk Wiki, CC BY-SA. Pictures: (c) CD PROJEKT RED. See the',
      '-- ATTRIBUTION.md next to the pictures.',
      '',
      "local Data = OPX.Modules.Get('appearance').Data",
      'local parts = Data.GARMENTS',
      'parts[#parts + 1] = {',
      ...slice,
      '}',
      ''
    ].join('\n'))
  }

  writeFileSync(join(IMAGES_OUT, 'ATTRIBUTION.md'), [
    '# Clothing pictures -- attribution',
    '',
    'The pictures in this folder are in-game renders of Cyberpunk 2077 items.',
    '**Images (c) CD PROJEKT RED.** Cyberpunk 2077 is a trademark of CD PROJEKT S.A.',
    'They are used to identify in-game items on a non-commercial fan server and are',
    'not covered by any licence in this repository.',
    '',
    'They were collected from the Cyberpunk Wiki (Fandom), https://cyberpunk.fandom.com',
    '(page "Cyberpunk 2077 Clothing" and each item\'s own page), and re-encoded to WebP.',
    'The item names in `modules/appearance/data/garments-*.lua` come from the same wiki,',
    'community content licensed under **CC BY-SA** (https://www.fandom.com/licensing).',
    '',
    'Record mapping: the Open77 items catalogue for game build ' +
      `${catalogue.gameBuild || '?'}, matched on the wiki's base id.`,
    '',
    'Regenerate with `tools/generate-garments.mjs`; do not edit these files by hand.',
    ''
  ].join('\n'))

  const manifestText = readFileSync(join(ROOT, 'open77.lua'), 'utf8')
  const missing = written.filter((file) => !manifestText.includes(`"${file}"`))
  const stale = [...manifestText.matchAll(/"(modules\/appearance\/data\/garments-\d+\.lua)"/g)]
    .map((match) => match[1]).filter((file) => !written.includes(file))

  const females = records.filter((r) => chosen.get(r).f).length
  const males = records.filter((r) => chosen.get(r).m).length
  console.log(`records with a picture: ${records.length} (female ${females}, male ${males})`)
  console.log(`pictures written: ${fileOfPixels.size} (${folded} folded as identical), ` +
    `${(bytes / 1048576).toFixed(2)} MiB`)
  console.log(`picture rows skipped for a record the server has no slot for: ${unknown}`)
  console.log(`lua parts: ${written.join(', ')}`)
  if (missing.length || stale.length) {
    console.error('open77.lua is out of step with the parts written:')
    for (const file of missing) console.error(`  add     client_script "${file}"`)
    for (const file of stale) console.error(`  remove  client_script "${file}"`)
    process.exitCode = 1
  }
  if (!existsSync(join(ROOT, 'modules/appearance/client/garments.lua'))) {
    console.error('modules/appearance/client/garments.lua is missing: nothing reads these parts')
    process.exitCode = 1
  }
}

main().catch((error) => {
  console.error(error)
  process.exit(1)
})
