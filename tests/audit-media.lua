--- Story quotas reserve capacity before a bag operation yields.
-- @author dop42
-- Run with `lua tests/audit-media.lua`.

local file = assert(io.open('modules/media/server/main.lua'))
local code = file:read('a'); file:close()
local original = { PlayerData = { citizenId = 'original', job = { name = 'reporter', onDuty = true,
	grade = { level = 0 } }, charInfo = {} } }
local current, items = original, {}
local character = { GetPlayer = function() return current end, GetMetadata = function() return {} end }
local inventory = { CanCarry = function() coroutine.yield(); return { ok = true, value = true } end,
	AddItem = function(target) items[#items + 1] = target; return { ok = true } end }
local M = { Model = { NetworkOf = function() return 'news' end,
	Prune = function(rows) return rows or {} end, Line = function(raw) return raw end, Words = function() return 1 end },
	Command = {}, Event = {} }
local env = setmetatable({ OPX = {
	Modules = { Get = function() return M end }, Cooling = function() return false end,
	Api = { Get = function(name) return name == 'character' and character or name == 'inventory' and inventory end },
	Math = { Finite = tonumber }, Text = { Clean = function(value) return value end },
	Locale = { Exists = function() return true end }, NotifyLocale = function() end,
	Audit = { Log = function() end }, Now = function() return 1000 end,
}, Open77 = { time = { unix = function() return 100 end } } }, { __index = _G })
local reset = assert(load(code .. [[
return function()
 built = { job = 'reporter', onDuty = true, metadata = 'press', requestMs = 100,
 story = { minGrade = 0, maxPerHour = 1, cooldownMs = 0, headline = {}, body = {} }, items = { story = { name = 'draft' } } }
 storiesBy = {}
end
]], '@modules/media/server/main.lua', 't', env))()
local function story()
	local result
	local co = coroutine.create(function() result = { M.Story(7, { headline = 'Title', body = 'Body' }) } end)
	local ok, why = coroutine.resume(co); assert(ok, why)
	return co, function() return table.unpack(result) end
end
reset()
local first = story()
assert(coroutine.status(first) == 'suspended')
local second, result = story()
assert(coroutine.status(second) == 'dead')
assert(select(2, result()) == 'story_quota', 'concurrent drafts exceeded the hourly quota')
assert(coroutine.resume(first))
assert(#items == 1 and items[1] == 'original', 'the draft was not delivered to its original citizen')
reset(); items = {}
local pending = story()
current = { PlayerData = { citizenId = 'replacement' } }
assert(coroutine.resume(pending))
assert(#items == 0, 'a queued draft was given to a replacement character')
current = original
local retry = story()
assert(coroutine.status(retry) == 'suspended', 'an interrupted draft leaked its quota reservation')
assert(coroutine.resume(retry))
assert(#items == 1)
print('media story audit regression checks passed')
