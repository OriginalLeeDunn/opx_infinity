import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import ts from 'typescript'
import { shallowRef } from 'vue'

function compile(file, require) {
  const source = readFileSync(new URL(file, import.meta.url), 'utf8')
  const code = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText
  const context = { exports: {}, URL, require }
  vm.runInNewContext(code, context)
  return context.exports
}
const store = compile('../ui/src/stores/images.ts', () => ({ shallowRef }))
const { imageFromFile: resolve } = compile('../ui/src/modules/inventory/format.ts', () => store)
const packet = (revision, index, total, entries) => ({ revision, index, total, entries })
assert.equal(resolve('water', ''), '', 'no configuration means no pictures')
store.applyImages(packet(1, 2, 2, [{ name: 'clothing/a.webp', url: 'https://cdn.example/a' }]))
assert.equal(resolve('garment', 'clothing/a.webp'), '', 'partial snapshots stay invisible')
store.applyImages(packet(1, 1, 2, [{ name: 'water.png', url: 'https://cdn.example/water' }]))
assert.equal(resolve('water', ''), 'https://cdn.example/water')
assert.equal(resolve('garment', 'clothing/a.webp'), 'https://cdn.example/a')
assert.equal(resolve('missing', ''), '')
store.applyImages(packet(2, 1, 1, [
  { name: 'bad.png', url: 'javascript:bad' },
  { name: 'broken.png', url: 'bad url' },
  { name: '../bad.png', url: 'https://cdn.example/private' },
  { name: 'water.png', url: 'https://cdn.example/new' }
]))
assert.equal(resolve('water', ''), 'https://cdn.example/new')
assert.equal(resolve('bad', ''), '')
assert.equal(resolve('broken', ''), '')
assert.equal(resolve('garment', 'clothing/a.webp'), '', 'completed snapshots remove old pictures')
store.applyImages(packet(1, 1, 1, [{ name: 'water.png', url: 'https://cdn.example/stale' }]))
assert.equal(resolve('water', ''), 'https://cdn.example/new', 'stale snapshots are ignored')
store.applyImages(packet(3, 1, 1, []))
assert.equal(resolve('water', ''), '')
console.log('CDN catalogue paging, stale snapshots, name resolution and no-local-image mode passed')
