--- The JSON stand-in must preserve false values just like the host codec.
-- @author dop42
local Host = dofile('tests/host.lua')
local json = Host.json
assert(json.encode({ visible = false }) == '{"visible":false}')
local copy = json.decode(json.encode({ enabled = false, nested = { locked = false }, [2] = false }))
assert(copy.enabled == false and copy.nested.locked == false and copy['2'] == false)
assert(json.decode('false') == false)
assert(json.decode('true') == true)
assert(json.decode('null') == nil)
print('host JSON: 5 checks passed')
