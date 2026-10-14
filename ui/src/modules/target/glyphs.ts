import { own } from '@/bridge/types'
/**
 * The row glyphs, carried over verbatim from `GLYPHS` in `opx77_target/web/target.js`.
 *
 * Inline path data and not an icon font: there is no network inside a CEF surface, so a
 * font would resolve to nothing and every row would show a blank box. Paths rather than
 * markup strings because the original built them with `createElementNS`, and `v-html` on
 * a payload-selected key is the same hole with a Vue accent.
 *
 * The set is CLOSED and Lua validates against the same names, so an unknown name is a
 * bug on one side or the other and falls back to `interact` rather than travelling
 * into an attribute nobody wrote.
 *
 * LUA HAS ONE LIST AND IT IS `core/shared/glyphs.lua`. `Model.ICONS` and `menu.M.ICONS`
 * are now ALIASES of that one table -- literally `= OPX.Glyphs` -- and the third name
 * this header used to send you to was deleted outright. It instructed the next author
 * to keep three hand-kept Lua lists in step in the same change, which is exactly the
 * regime that produced 47 names, 45 and 14 with no test looking. There is one Lua list,
 * it is generated from THIS file because the page is what can actually draw a path, and
 * `tests/` reads both files and holds them together -- the one seam no shared file can
 * close, a `.ts` being unloadable from Lua.
 *
 * `currentColor` is what carries the tone rules down to the stroke, so nothing here
 * names a colour.
 */
export const GLYPHS: Record<string, string[]> = {
  interact: ['M8 12V5a2 2 0 0 1 4 0v6', 'M12 9h3l4 4v4l-3 4h-5l-6-7a2 2 0 0 1 3-2Z'],
  person: ['M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z', 'M4 21v-3a8 8 0 0 1 16 0v3'],
  vehicle: ['M4 10l2-6h12l2 6', 'M3 10h18v8H3Z', 'M5 18v3m14-3v3M6 14h2m8 0h2'],
  info: ['M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z', 'M12 11v6m0-10v.2'],
  lock: ['M6 10V7a6 6 0 0 1 12 0v3', 'M4 10h16v11H4ZM12 14v3'],
  tool: ['M14 3a6 6 0 0 0-6 8l-6 6 5 5 6-6a6 6 0 0 0 8-7l-4 4-5-5 4-4Z'],
  location: ['M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 1 1 16 0Z', 'M15 10a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z'],
  box: ['M3 7l9-4 9 4v10l-9 4-9-4Z', 'M3 7l9 4 9-4M12 11v10'],
  door: ['M5 21V3h11l3 2v16', 'M3 21h18M13 12h.2'],
  heal: ['M9 3h6v6h6v6h-6v6H9v-6H3V9h6Z'],
  money: ['M2 6h20v12H2Z', 'M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0ZM6 9v.2M18 15v.2'],
  talk: ['M4 4h16v12H9l-5 4Z', 'M8 9h8M8 12h5'],
  folder: ['M3 6h6l2 2h10v11H3Z'],
  back: ['M15 5l-7 7 7 7'],

  /* ── THE SECOND BAND ───────────────────────────────────────────────────────
     Added so that EVERY row of every list can carry a glyph that says what it
     is. The first fourteen were the target eye's own vocabulary, and a menu
     drawn out of them alone said `tool` fourteen times over: the noclip switch,
     the weather presets, the ped families and the vehicle flags were all one
     picture, which is the same as no picture.

     Same rules as above, and they are why this is one flat object and not a
     second one: 24x24, stroke only, no fill, no colour, paths and not markup.
     A name added here is added to `core/shared/glyphs.lua` in the same change --
     the single list every Lua validator reads -- and a name in this file that is
     not in it can never reach a row. The suite fails if the two drift. */

  /* Finding something in a long list. */
  search: ['M11 18a7 7 0 1 1 0-14 7 7 0 0 1 0 14Z', 'M16.2 16.2 21 21'],
  filter: ['M3 5h18l-7 8.5V20l-4 2v-8.5Z'],
  list: ['M9 6h12M9 12h12M9 18h12', 'M4 6h.2M4 12h.2M4 18h.2'],
  star: ['M12 3.5l2.7 5.6 6.1.9-4.4 4.3 1 6.2-5.4-2.9-5.4 2.9 1-6.2L3.2 10l6.1-.9Z'],

  /* Force, and the refusal of it. */
  weapon: ['M3 7h12l4 4h3v3h-5l-2 5h-4l1-5H7a4 4 0 0 1-4-4Z'],
  ammo: ['M9 21V8l3-5 3 5v13Z', 'M9 13h6'],
  shield: ['M12 3l8 3v6c0 5.2-3.7 8.4-8 9.6C7.7 20.4 4 17.2 4 12V6Z'],
  ban: ['M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z', 'M5 5l14 14'],
  warning: ['M12 3 2.5 20h19Z', 'M12 10v4m0 3v.2'],

  /* What is shown, and what is not. */
  eye: ['M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z', 'M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z'],
  hidden: [
    'M4 4l16 16',
    'M9.5 5.4A10 10 0 0 1 12 5c6 0 10 7 10 7a18 18 0 0 1-3.2 4',
    'M6.3 8.3A18 18 0 0 0 2 12s4 7 10 7a10 10 0 0 0 3.6-.7'
  ],
  tag: ['M3 3h8l10 10-8 8L3 11Z', 'M7.5 7.5h.2'],

  /* The world, and the clock over it. */
  flag: ['M5 21V4', 'M5 5h13l-2.5 4L18 13H5Z'],
  map: ['M9 4 3 6.5v14L9 18l6 2.5 6-2.5v-14L15 6.5Z', 'M9 4v14M15 6.5v14'],
  world: [
    'M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z',
    'M2.5 9h19M2.5 15h19',
    'M12 2a14 14 0 0 1 0 20 14 14 0 0 1 0-20Z'
  ],
  clock: ['M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0Z', 'M12 6.5V12l3.5 2.5'],
  weather: ['M17.5 19H7a4.5 4.5 0 0 1-.6-9 6 6 0 0 1 11.3 2A3.5 3.5 0 0 1 17.5 19Z'],

  /* Machinery. */
  gear: [
    'M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z',
    'M12 2v3m0 14v3M2 12h3m14 0h3M4.9 4.9 7 7m10 10 2.1 2.1M19.1 4.9 17 7M7 17l-2.1 2.1'
  ],
  refresh: ['M20.5 12a8.5 8.5 0 1 1-2.6-6.1', 'M21 3.5V10h-6.5'],
  bolt: ['M13 2 4 14h7l-1 8 9-12h-7Z'],
  server: ['M3 4.5h18v6H3ZM3 13.5h18v6H3Z', 'M6.5 7.5h.2M6.5 16.5h.2'],
  key: ['M14 10a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z', 'M13.5 8.5H21m-3 0v3.5m-2.5-3.5v2.5'],

  /* Going somewhere, and the plain arithmetic of a list. */
  arrow: ['M4 12h14', 'M13 6l6 6-6 6'],
  plus: ['M12 5v14M5 12h14'],
  minus: ['M5 12h14'],
  trash: ['M4 7h16', 'M10 4h4', 'M6 7l1.2 14h9.6L18 7', 'M10 11v6m4-6v6'],

  /* A body, and what it does with its hands. */
  heart: ['M12 20.5S3.5 15.7 3.5 10A4.5 4.5 0 0 1 12 7.6 4.5 4.5 0 0 1 20.5 10c0 5.7-8.5 10.5-8.5 10.5Z'],
  emote: ['M13.5 4.2a1.8 1.8 0 1 1-3.6 0 1.8 1.8 0 0 1 3.6 0Z', 'M11.7 8v6', 'M7 9.5 11.7 8l4.8 1.5', 'M9 21l2.7-7 3.3 7'],
  food: ['M5 3v7a3 3 0 0 0 6 0V3', 'M8 3v18', 'M18 3c-2 2-2 7 0 9v9'],
  drink: ['M6 4h12l-1.5 16h-9Z', 'M7 10h10'],
  smoke: ['M3 15h13v4H3Z', 'M13 15v4', 'M18.5 6c1.8 1.2 1.8 3.3 0 4.5', 'M21.5 7.5c1.3 1.3 1.3 3.2 0 4.5']
}

/** An unknown name draws the generic glyph, never nothing and never raw markup. */
export function glyphPaths(name: string): string[] {
  return own(GLYPHS, name) ?? GLYPHS.interact
}
