/** Run with node tests/ui-spawn-focus.mjs; verifies the actual spawn key listener. */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import ts from 'typescript'
const source=fs.readFileSync(new URL('../ui/src/modules/spawn/SpawnView.vue',import.meta.url),'utf8')
const script=source.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)?.[1]
assert.ok(script)
const parsed=ts.createSourceFile('spawn.ts',script,ts.ScriptTarget.Latest,true,ts.ScriptKind.TS)
const fn=parsed.statements.find((node)=>ts.isFunctionDeclaration(node)&&node.name?.text==='onKeyDown')
assert.ok(fn)
const code=ts.transpileModule(fn.getText(parsed),{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText
let owner='form',moved=0,confirmed=0,prevented=0
const open={value:true}
const keyDown=new Function('open','focusOwner','move','confirm',`${code}\nreturn onKeyDown`)(
 open,()=>owner,(delta)=>{moved+=delta},()=>{confirmed++})
const key=(name)=>({key:name,defaultPrevented:false,preventDefault(){prevented++}})
keyDown(key('ArrowDown'));keyDown(key('Enter'))
assert.equal(moved,0,'a form above spawn owns its arrows')
assert.equal(confirmed,0,'a form above spawn cannot submit the spawn choice')
assert.equal(prevented,0,'spawn must leave the owning form events alone')
owner='spawn'
keyDown(key('ArrowDown'));keyDown(key('Enter'))
assert.equal(moved,1);assert.equal(confirmed,1)
open.value=false
keyDown(key('Enter'))
assert.equal(confirmed,1)
console.log('PASS spawn keyboard focus ownership and closed-state guard')

const formSource=fs.readFileSync(new URL('../ui/src/modules/form/FormView.vue',import.meta.url),'utf8')
const formScript=formSource.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)?.[1]
assert.ok(formScript)
const formParsed=ts.createSourceFile('form.ts',formScript,ts.ScriptTarget.Latest,true,ts.ScriptKind.TS)
const formFunctions=formParsed.statements.filter((node)=>ts.isFunctionDeclaration(node)&&['keyDown','syncCaret'].includes(node.name?.text))
assert.equal(formFunctions.length,2)
const formCode=ts.transpileModule(formFunctions.map((fn)=>fn.getText(formParsed)).join('\n'),{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText
let formEmits=0,caretRuns=0
owner='chat';open.value=true
const formApi=new Function('open','focusOwner','KEYS','focused','emit','handle','guard',`${formCode}\nreturn {keyDown,syncCaret}`)(
 open,()=>owner,{Enter:'enter',ArrowDown:'down'},{value:null},()=>{formEmits++},{value:'test'},()=>{caretRuns++})
formApi.keyDown(key('Enter'));formApi.keyDown(key('ArrowDown'));formApi.syncCaret()
assert.equal(formEmits,0,'background form cannot submit while chat owns focus')
assert.equal(caretRuns,0,'background frame cannot steal the chat caret')
owner='form';formApi.keyDown(key('Enter'));formApi.syncCaret()
assert.equal(formEmits,1);assert.equal(caretRuns,1)
console.log('PASS form keyboard and caret respect the current focus owner')

const targetSource=fs.readFileSync(new URL('../ui/src/modules/target/TargetView.vue',import.meta.url),'utf8')
const targetScript=targetSource.match(/<script setup lang="ts">([\s\S]*?)<\/script>/)?.[1]
assert.ok(targetScript)
const targetParsed=ts.createSourceFile('target.ts',targetScript,ts.ScriptTarget.Latest,true,ts.ScriptKind.TS)
const targetFn=targetParsed.statements.find((node)=>ts.isFunctionDeclaration(node)&&node.name?.text==='onKeyDown')
assert.ok(targetFn)
const targetCode=ts.transpileModule(targetFn.getText(targetParsed),{compilerOptions:{target:ts.ScriptTarget.ES2022}}).outputText
let targetWalks=0
owner='form'
const targetKeyDown=new Function('open','showList','focusOwner','flipped','VERTICAL','rowsIn','focusedDepth',`${targetCode}\nreturn onKeyDown`)(
 open,{value:true},()=>owner,{value:false},['ArrowDown'],()=>{targetWalks++;return []},()=>0)
const before=prevented
targetKeyDown(key('ArrowDown'))
assert.equal(targetWalks,0,'target must not steal keys before its Lua focus sweep closes it')
assert.equal(prevented,before)
owner='target';targetKeyDown(key('ArrowDown'))
assert.equal(targetWalks,1)
console.log('PASS target keyboard guard during focus handoff')
