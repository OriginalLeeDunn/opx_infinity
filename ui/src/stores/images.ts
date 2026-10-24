import { shallowRef } from 'vue'

/** Only complete server snapshots replace the visible name-to-URL catalogue. */
export const imageUrls = shallowRef<Record<string, string>>(Object.create(null))
let revision = -1
let total = 0
let pages = new Map<number, Array<{ name: string; url: string }>>()

export function applyImages(value: unknown): void {
  if (!value || typeof value !== 'object') return
  const packet = value as Record<string, unknown>
  const version = packet.revision
  const index = packet.index
  const count = packet.total
  if (typeof version !== 'number' || !Number.isSafeInteger(version) || version < revision
    || typeof index !== 'number' || !Number.isSafeInteger(index) || index < 1
    || typeof count !== 'number' || !Number.isSafeInteger(count) || count < index || count > 6250
    || !Array.isArray(packet.entries) || packet.entries.length > 8) return
  const entries: Array<{ name: string; url: string }> = []
  for (const entry of packet.entries) {
    if (!entry || typeof entry !== 'object') continue
    const { name, url } = entry as Record<string, unknown>
    if (typeof name !== 'string' || name.length > 192 || typeof url !== 'string' || url.length > 1024
      || !/^[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*$/.test(name)
      || name.split('/').some((part) => part === '.' || part === '..')) continue
    try {
      const parsed = new URL(url)
      if (parsed.protocol === 'https:' && !parsed.username && !parsed.password) entries.push({ name, url })
    } catch { /* Invalid URLs never reach an image element. */ }
  }
  if (version !== revision) {
    revision = version
    total = count
    pages = new Map()
  }
  if (count !== total) return
  pages.set(index, entries)
  if (pages.size !== total) return
  const complete: Record<string, string> = Object.create(null)
  for (let page = 1; page <= total; page++) {
    for (const entry of pages.get(page) || []) complete[entry.name] = entry.url
  }
  imageUrls.value = complete
}
