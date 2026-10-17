--- Checks door authorization after an inventory or hook yield.
-- @author dop42
-- Run with `lua tests/audit-doorlock-request.lua`.

local file = assert(io.open('modules/doorlock/server/main.lua'))
local code = file:read('a')
file:close()
local account, x, changed, answer = 'first', 0, 0, nil
local M = { Access = {}, Storage = {}, Backend = { Apply = function() changed = changed + 1 end },
	Command = {}, Event = { ANSWER = 'answer' }, Settings = {} }
local Access = M.Access
Access.Id = function(value) return value end
Access.Slack = function() return 0 end
Access.DistanceSquared = function(_, px) return px * px end
Access.Evaluate = function() coroutine.yield(); return true, 'public' end
local sessions = { [7] = {} }
local env = setmetatable({ OPX = {
	Modules = { Get = function() return M end }, Result = {}, Sessions = sessions,
	UserIdOf = function() return account end, Now = function() return 0 end,
	Cooling = function() return false end,
	Math = { Finite = function(value) return tonumber(value) end },
	Api = { Get = function() return nil end }, Hooks = { Trigger = function() return true end },
}, Open77 = { players = { position = function() return { x = x, y = 0, z = 0, bucket = 0 } end },
	acl = { isAllowed = function() return false end } },
	TriggerClientEvent = function(_, _, payload) answer = payload end,
}, { __index = _G })
local testing = assert(load(code .. '\nreturn { toggle = toggle, install = install }', '@modules/doorlock/server/main.lua', 't', env))()
testing.install({ id = 1, ids = { 'leaf' }, bucket = 0, state = 1, maxDistance = 2 })
local function request(change)
	account, x, answer = 'first', 0, nil
	local co = coroutine.create(function() testing.toggle(7, { id = 1 }) end)
	assert(coroutine.resume(co))
	change()
	local ok, why = coroutine.resume(co)
	assert(ok, why)
	assert(coroutine.status(co) == 'dead')
	assert(answer and not answer.ok)
end
request(function() x = 100 end)
assert(answer.code == 'too_far', 'stale position authorized a remote unlock')
request(function() account = 'replacement' end)
assert(answer.code == 'not_allowed', 'stale account authorized a replacement player')
assert(changed == 0, 'rejected requests still changed a door')
print('doorlock request audit regression checks passed')
