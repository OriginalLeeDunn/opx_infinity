/** Run with `node tests/ui-radio-ptt.mjs`; exercises the real handset handlers. */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import ts from 'typescript'

const source = fs.readFileSync(new URL('../ui/src/modules/radio/RadioHolo.vue', import.meta.url), 'utf8')
const script = source.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)?.[1]
assert.ok(script)
const parsed = ts.createSourceFile('radio.ts', script, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
const functions = parsed.statements.filter((statement) => ts.isFunctionDeclaration(statement)
  && ['listenForRelease', 'pttDown', 'pttUp'].includes(statement.name?.text))
assert.equal(functions.length, 3)
const code = ts.transpileModule(functions.map((statement) => statement.getText(parsed)).join('\n'),
  { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText
const listeners = new Map()
const window = {
  addEventListener(name, callback) {
    if (!listeners.has(name)) listeners.set(name, new Set())
    listeners.get(name).add(callback)
  },
  removeEventListener(name, callback) { listeners.get(name)?.delete(callback) },
  dispatch(name) { for (const callback of Array.from(listeners.get(name) ?? [])) callback({}) }
}
const pressing = { value: false }
const emitted = []
const make = new Function('window', 'pressing', 'emit', `${code}\nreturn { pttDown, pttUp }`)
const api = make(window, pressing, (channel, payload) => emitted.push({ channel, payload }))

api.pttDown({ button: 2 })
assert.equal(emitted.length, 0, 'secondary button must not transmit')
for (const event of ['blur', 'pointercancel', 'pointerup']) {
  api.pttDown({ button: 0 })
  api.pttDown({ button: 0 })
  assert.equal(pressing.value, true)
  assert.equal(emitted.at(-1).payload.on, true)
  const count = emitted.length
  window.dispatch(event)
  assert.equal(pressing.value, false, `${event} must release the handset key`)
  assert.equal(emitted.length, count + 1, 'release must emit once')
  assert.equal(emitted.at(-1).payload.on, false)
  for (const callbacks of listeners.values()) assert.equal(callbacks.size, 0, 'release must remove listeners')
  window.dispatch(event)
  api.pttUp()
  assert.equal(emitted.length, count + 1, 'repeated release must be idempotent')
}
console.log('PASS radio pointer release, cancellation, blur, listener cleanup and duplicate edges')
