--- A readiness watchdog belongs to a connection, including same-account rejoins.
-- @author dop42
-- Run with `lua tests/audit-gate.lua`.

local now, watches, released = 0, {}, 0
local session = { userId = 'same-account' }
local OPX = { Sessions = { [7] = session }, Config = { SERVER = {} },
	Channel = { INTERNAL = 'internal' }, Event = function() return 'event' end,
	Math = { IsFinite = function(n) return type(n) == 'number' and n == n and math.abs(n) < math.huge end,
		Clamp = function(n, a, b) return math.max(a, math.min(b, n)) end },
	Now = function() return now end, Modules = { Record = function() return {} end }, Host = {} }
local env = setmetatable({ OPX = OPX, Open77 = { ready = { participate = function() return true end },
	log = { info = function() end, warn = function() end, error = function() end } },
	AddEventHandler = function() end,
	CreateThread = function(fn) watches[#watches + 1] = coroutine.create(fn) end,
	Wait = coroutine.yield }, { __index = _G })
assert(loadfile('core/server/gate.lua', 't', env))()
OPX.Gate.Release = function() released = released + 1; return true end
assert(OPX.Gate.Watch(7, 1000))
assert(coroutine.resume(watches[1]))
OPX.Sessions[7] = { userId = 'same-account' }
now = 2000
assert(coroutine.resume(watches[1]))
assert(coroutine.status(watches[1]) == 'dead')
assert(released == 0, 'the old watchdog opened the same account\'s replacement connection')
assert(OPX.Gate.Watch(7, 1000))
assert(coroutine.resume(watches[2]))
now = 4000
assert(coroutine.resume(watches[2]))
assert(released == 1, 'a current watchdog failed to release its own connection')
print('readiness gate audit regression checks passed')
