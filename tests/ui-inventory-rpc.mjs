/** Regression checks for inventory request lifetime, without a browser or game.
 * Run with `node tests/ui-inventory-rpc.mjs` after installing the UI dependencies.
 * Compile the real SFC functions so the request and reset paths stay under test.
 */
import fs from 'node:fs'
import assert from 'node:assert/strict'
import ts from 'typescript'

const source = fs.readFileSync(new URL('../ui/src/modules/inventory/InventoryView.vue', import.meta.url), 'utf8')
const script = source.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)?.[1]
assert.ok(script, 'inventory setup script must exist')
const parsed = ts.createSourceFile('inventory.ts', script, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
const functions = parsed.statements.filter((statement) =>
  ts.isFunctionDeclaration(statement) && ['ask', 'blank'].includes(statement.name?.text)
)
assert.equal(functions.length, 2, 'test requires the real ask and blank functions')
const generation = parsed.statements.find((statement) =>
  ts.isVariableStatement(statement) && statement.declarationList.declarations.some((declaration) =>
    ts.isIdentifier(declaration.name) && declaration.name.text === 'requestGeneration'
  )
)
assert.ok(generation, 'request lifetime state must exist')
const code = ts.transpileModule(
  [generation, ...functions].map((statement) => statement.getText(parsed)).join('\n'),
  { compilerOptions: { target: ts.ScriptTarget.ES2022 } }
).outputText

const ref = (value) => ({ value })
const handle = ref('old')
const busy = ref(false)
const status = ref('')
const calls = []
class BridgeError extends Error {
  constructor(key) {
    super(key)
    this.localeKey = key
  }
}
const context = {
  handle, busy, status, BridgeError,
  open: ref(true), primary: ref(null), secondary: ref(null), nearby: ref([]),
  split: { open: false }, hovered: { container: 0, slot: 0 },
  endDrag() {}, unbindPointer() {}, closeMenu() {},
  label: (key) => key,
  TIMEOUT_MS: 5000,
  request: () => new Promise((resolve, reject) => calls.push({ resolve, reject }))
}
const make = new Function(...Object.keys(context), `${code}\nreturn { ask, blank }`)
const api = make(...Object.values(context))

const old = api.ask('move')
await api.ask('drop')
assert.equal(calls.length, 1, 'busy inventory must not send a duplicate mutation')
api.blank()
handle.value = 'new'
const current = api.ask('sort')
calls[0].reject(new BridgeError('error.rpc_timeout'))
await old
assert.equal(status.value, '', 'old timeout must not contaminate the new opening')
assert.equal(busy.value, true, 'old completion must not unlock a new request')
calls[1].resolve({})
await current
assert.equal(busy.value, false, 'current completion must unlock its own request')

const timeout = api.ask('sort')
calls[2].reject(new BridgeError('error.rpc_timeout'))
await timeout
assert.equal(status.value, 'timeout', 'current timeout must still report failure')
assert.equal(busy.value, false)

console.log('PASS inventory stale timeout, lock isolation, duplicate mutations, current timeout')
