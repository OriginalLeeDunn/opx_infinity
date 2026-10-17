--- A queued role change must not leave the old radio's speaking grant usable.
-- @author dop42
-- Run with `lua tests/audit-radio.lua`.

local file = assert(io.open('modules/radio/server/main.lua'))
local code = file:read('a'); file:close()
local current = { PlayerData = { citizenId = 'first', job = {} } }
local allowed, grants = true, 0
local M = { Model = { Allowed = function() return allowed and { 'secret' } or {} end }, Event = { KEYED = 'keyed' } }
local env = setmetatable({ OPX = {
	Modules = { Get = function() return M end }, Result = {}, Now = function() return 0 end,
	Cooling = function() return false end,
	Api = { Get = function(name)
		if name == 'character' then return { GetPlayer = function() return current end } end
	end },
	Publish = function() end, Audit = { Log = function() end },
}, Open77 = { voice = { createChannel = function() end,
	setChannelPlayerPermissions = function(_, _, rights)
		if rights.canSpeak then grants = grants + 1 end
		return true
	end,
	removePlayer = function() return true end,
} }, TriggerClientEvent = function() end }, { __index = _G })
local setup = assert(load(code .. [[
return function()
 built = { blockWhenDown = false, channels = { secret = { short = 'Secret' } } }
 states[7] = { citizenId = 'first', active = 'secret', joined = { secret = { listen = true } } }
 voiceIds.secret = 1
end
]], '@modules/radio/server/main.lua', 't', env))()
setup()
assert(M.Talk(7, true))
assert(grants == 1, 'an authorized character could not speak')
M.Talk(7, false)
allowed = false
assert(select(2, M.Talk(7, true)) == 'not_allowed')
assert(grants == 1, 'a revoked role kept speaking before its queued event arrived')
setup(); allowed = true
current = { PlayerData = { citizenId = 'replacement', job = {} } }
assert(select(2, M.Talk(7, true)) == 'not_loaded')
assert(grants == 1, 'a replacement character inherited speaking rights')
print('radio authority audit regression checks passed')
