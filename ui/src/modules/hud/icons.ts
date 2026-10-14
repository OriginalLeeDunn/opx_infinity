import { own } from '@/bridge/types'
/**
 * The five gauge glyphs, carried over verbatim from `ICONS` in `opx77_hud/web/hud.js`.
 *
 * Inline path data and not an icon font: there is no network inside a CEF surface, so a
 * font would resolve to nothing and every gauge would show a blank box. They are paths
 * rather than markup strings because the original assigned them with `innerHTML`, and
 * `v-html` on a payload-selected key is the same hole with a Vue accent.
 *
 * `currentColor` is what carries the gauge's tone down to the stroke, so nothing here names
 * a colour -- which is also why turning the whole HUD red in design pass 02 did not have to
 * touch this file.
 */
export const ICONS: Record<string, string[]> = {
  health: ['M8 13.5S2 10 2 6.2A3.2 3.2 0 0 1 8 4.6 3.2 3.2 0 0 1 14 6.2C14 10 8 13.5 8 13.5Z'],
  armor: ['M8 1.8 13.4 4v4.2c0 3.2-2.4 5.3-5.4 6.2-3-0.9-5.4-3-5.4-6.2V4Z'],
  stamina: ['M9.2 1.6 4.2 8.9h3.4l-.8 5.5 5-7.3H8.4Z'],
  hunger: [
    'M4.4 1.9v4.6a1.6 1.6 0 0 0 3.2 0V1.9',
    'M6 6.5v7.6',
    'M11.6 1.9c-1 0-1.8 1.6-1.8 3.6s.8 2.6 1.8 2.6Z',
    'M11.6 8.1v6'
  ],
  thirst: ['M8 1.8s4.3 4.6 4.3 7.5A4.3 4.3 0 0 1 8 14.2 4.3 4.3 0 0 1 3.7 9.3C3.7 6.4 8 1.8 8 1.8Z']
}

/** Unknown names draw nothing rather than an empty frame, as hud.js did. */
export function iconPaths(name: string): string[] {
  return own(ICONS, name) ?? []
}
