/** Exercise the actual pool gauge controller, including stale-frame cleanup. */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import ts from 'typescript'
const source = fs.readFileSync(new URL('../ui/src/modules/pool/PoolHud.vue', import.meta.url), 'utf8')
const script = source.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)?.[1]
assert.ok(script)
const parsed = ts.createSourceFile('pool.ts', script, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
const code = ts.transpileModule(parsed.statements.filter(s => !ts.isImportDeclaration(s)).map(s => s.getText(parsed)).join('\n'),
  { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText
const channels = new Map(), intervals = new Set()
let unmount, now = 1000
const ref = value => ({ value })
const api = new Function('list', 'computed', 'onUnmounted', 'ref', 'num', 'text', 'useBridge', 'setInterval', 'clearInterval', 'Date', `${code}\nreturn {visible,power,percent,rolling,score,duel,status,canShoot}`)(
  v => Array.isArray(v) ? v : [],
  fn => ({get value() {return fn()}}), fn => {unmount = fn}, ref,
  (v, fallback=0) => typeof v === 'number' && Number.isFinite(v) ? v : fallback,
  (v, fallback='') => typeof v === 'string' ? v : fallback,
  (name, fn) => channels.set(name, fn), fn => {intervals.add(fn);return fn}, fn => intervals.delete(fn), {now: () => now})
const frame = channels.get('opx:pool:frame')
frame({power: 0.42, phase: 'aim'})
assert.equal(api.visible.value, true);assert.equal(api.percent.value, 42)
frame({power: Number.NaN});assert.equal(api.power.value, 0)
frame({power: 7, phase: 'rolling'});assert.equal(api.power.value, 1);assert.equal(api.rolling.value, true)
frame({score:[3,Number.NaN],duel:true,status:'Your turn',canShoot:true});assert.deepEqual(api.score.value,[3,0]);assert.equal(api.canShoot.value,true);assert.equal(api.duel.value,true)
channels.get('opx:pool:hide')({});assert.equal(api.visible.value, false)
frame({power: 0.5});now += 501
for (const fn of intervals) fn()
assert.equal(api.visible.value, false, 'interrupted input left a stale shot gauge')
unmount();assert.equal(intervals.size, 0, 'unmount leaked the watchdog')
console.log('PASS pool gauge clamping, explicit hide, stale-frame expiry and timer cleanup')
