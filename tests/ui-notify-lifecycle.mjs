/** Run with node tests/ui-notify-lifecycle.mjs; exercises the actual notification controller. */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import ts from 'typescript'
const source = fs.readFileSync(new URL('../ui/src/modules/notify/NotifyRoot.vue', import.meta.url), 'utf8')
const script = source.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)?.[1]
assert.ok(script)
const parsed = ts.createSourceFile('notify.ts', script, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
const statements = parsed.statements.filter((statement) => !ts.isImportDeclaration(statement))
const code = ts.transpileModule(statements.map((statement) => statement.getText(parsed)).join('\n'),
  { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText
const channels = new Map()
const intervals = new Set()
const timeouts = []
const clips = []
let unmount
const ref = (value) => ({ value })
const make = new Function('onMounted', 'onUnmounted', 'ref', 'shallowRef', 'playClip', 'stingerOf',
  'emit', 'guard', 'diagReport', 'num', 'text', 'useBridge', 'useLocale', 'window', 'setInterval',
  'clearInterval', `${code}\nreturn { toasts }`)
const api = make(() => {}, (fn) => { unmount = fn }, ref, ref,
  () => new Promise((resolve) => clips.push(() => resolve({ played: true }))), (value) => value ?? null,
  () => {}, (_context, fn) => fn(), () => {}, (value, fallback = 0) => typeof value === 'number' ? value : fallback,
  (value, fallback = '') => typeof value === 'string' ? value : fallback,
  (name, fn) => channels.set(name, fn), () => ({ t: (value) => value }),
  { setTimeout: (fn) => timeouts.push(fn) },
  (fn) => { intervals.add(fn); return fn }, (fn) => intervals.delete(fn))
const announce = () => channels.get('opx:notify:show')({ id: 'same', durationMs: 5000,
  stinger: { open: 'opening', close: '', volume: 1 } })
announce()
channels.get('opx:notify:dismiss')({ id: 'same' })
announce()
assert.equal(clips.length, 2)
clips[0]()
await new Promise((resolve) => setImmediate(resolve))
assert.equal(api.toasts.value.at(-1).held, true, 'old audio cannot reveal a replacement using the same id')
clips[1]()
await new Promise((resolve) => setImmediate(resolve))
assert.equal(api.toasts.value.at(-1).held, false, 'its own audio reveals the replacement')
channels.get('opx:notify:clear')({})
announce()
unmount()
assert.equal(intervals.size, 0)
clips[2]()
await new Promise((resolve) => setImmediate(resolve))
assert.equal(intervals.size, 0, 'opening audio completing after unmount cannot restart the timer')
assert.equal(api.toasts.value.at(-1).held, true)
console.log('PASS notification record identity, audio completion and unmount timer cleanup')
