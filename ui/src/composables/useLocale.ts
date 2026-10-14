import { computed } from 'vue'
import { ui } from '@/stores/ui'

/**
 * Locale keys in, player's language out.
 *
 * The page holds no English. Every label crossing the bridge is a key -- `opx:reply`
 * errors, module payloads, rpc rejections -- because Lua owns the player's language
 * and `locales/en.lua` is where the sentence lives. A page that hardcodes "Loading..."
 * is a page that is English-only in a platform that is not.
 *
 * A missing key renders as the key. Loudly wrong is the point: an untranslated
 * `demo.row.balance` on screen gets fixed, an invented "Balance" never does.
 *
 * BUT ONLY ONCE THE CATALOGUE HAS LANDED. Before that, every key is missing because
 * none has arrived, and painting them all as raw keys is what players saw on a cold
 * join (`hud.voice.state.idle` on the HUD). Until `stringsReady`, a miss draws nothing:
 * a blank label for a frame or two, never a key.
 */
export function useLocale() {
  const strings = computed(() => ui.strings)

  function t(key: string, vars?: Record<string, string | number>): string {
    const template = strings.value[key]
    // `typeof`, not `=== undefined`: the catalogue is a plain object, and a key like
    // `constructor` would otherwise return the inherited function and `.replace` throw.
    if (typeof template !== 'string') return ui.stringsReady ? key : ''
    if (!vars) return template
    return template.replace(/\{(\w+)\}/g, (whole, name: string) => {
      const value = vars[name]
      return value === undefined ? whole : String(value)
    })
  }

  /** True when the key exists. Use to decide whether to render a row at all. */
  function has(key: string): boolean {
    return typeof strings.value[key] === 'string'
  }

  return { t, has }
}
