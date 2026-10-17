-- Real panel: individually bounded selection patches cannot accumulate unbounded state.
local module = { Settings = {}, Host = { PAUSE_KEY = 'pause' }, Event = { ACTION = 'action' } }
local api, sends = nil, 0
OPX = {
 Modules = { Get = function() return module end },
 Result = { Ok = function(value) return { ok = true, value = value } end,
  Err = function(code) return { ok = false, error = code } end },
 Text = { Clean = function(value) return type(value) == 'string' and value or nil end },
 Table = { Count = function(value) local n = 0; for _ in pairs(value) do n = n + 1 end; return n end },
 Modal = { ValidId = function(value) return type(value) == 'string' and value ~= '' end,
  Nodes = function() return 1 end, Fits = function() return true end,
  FocusResponder = function() return function() end end,
  New = function() return { Reset = function() end, Blocked = function() return false end } end },
 UI = { Interactive = function() return {} end, On = function() end,
  Send = function() sends = sends + 1; return true end },
 Api = { Provide = function(_, _, value) api = value end }, Now = function() return 1 end,
}
function locale(key) return key end
dofile('modules/panel/client/main.lua')
module.Init(); module.Api()
local opened = api.Open({ id = 'test', owner = 'test', on = function() end })
assert(opened.ok)
local selected = {}
for index = 1, 64 do selected['tab' .. index] = 'item' end
assert(api.Update(opened.value.handle, { selected = selected }).ok)
local before = sends
local rejected = api.Update(opened.value.handle, { title = 'must not change', selected = { extra = 'item' } })
assert(not rejected.ok and rejected.error == 'invalid_selected')
assert(sends == before, 'oversized merged selection was sent')
assert(api.Update(opened.value.handle, { selected = { tab1 = false } }).ok)
print('panel merged selected bound passed')
