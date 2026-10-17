/** Pure regressions for the generator's Lua literals and UTF-8 name bounds.
 * Read its actual helpers without running the image generator or loading sharp.
 */
import assert from 'node:assert/strict'
import fs from 'node:fs'
import ts from 'typescript'

const source = fs.readFileSync(new URL('../tools/generate-garments.mjs', import.meta.url), 'utf8')
const parsed = ts.createSourceFile('garments.js', source, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS)
const functions = parsed.statements.filter((statement) => ts.isFunctionDeclaration(statement)
  && ['lua', 'garmentName'].includes(statement.name?.text))
assert.equal(functions.length, 2)
const limit = parsed.statements.find((statement) => ts.isVariableStatement(statement)
  && statement.declarationList.declarations.some((declaration) => ts.isIdentifier(declaration.name)
    && declaration.name.text === 'NAME_MAX'))
assert.ok(limit)
const code = [limit, ...functions].map((statement) => statement.getText(parsed)).join('\n')
const { lua, garmentName } = new Function(`${code}\nreturn { lua, garmentName }`)()

assert.equal(lua('\x012'), '"\\0012"', 'a following digit must not extend a Lua decimal escape')
assert.equal(lua('\x0007'), '"\\00007"')
assert.equal(lua('a"b\\c\n'), '"a\\"b\\\\c\\010"')
assert.equal(lua('é'), '"é"', 'UTF-8 must pass through the literal')
assert.equal(garmentName('  Plain name  '), 'Plain name')
assert.equal(garmentName('x'.repeat(130)), 'x'.repeat(120))
assert.equal(garmentName('é'.repeat(100)), 'é'.repeat(60))
assert.equal(garmentName('x'.repeat(119) + 'é'), 'x'.repeat(119), 'cut before a multibyte character')
assert.equal(garmentName('😀'.repeat(40)), '😀'.repeat(30), 'do not cut a surrogate pair')
assert.equal(Buffer.byteLength(garmentName('夜'.repeat(100))), 120)
console.log('PASS garment Lua escape boundaries and UTF-8 byte limits')
