--- Consent to a pair survives neither character replacement nor reconnect.
-- @author dop42
local data = { [1] = {}, [2] = {} }
local sessions = { [1] = {}, [2] = {} }
local requested, now = 0, 0
local M = { MAX_REQUEST_ID = 1000, MIN_DURATION_MS = 100, SERVICE_MAX_MS = 10000,
	Event = {}, Opt = { SHARED = true, SHARED_ANY = true, SHARED_RANGE = 3,
		SHARED_DURATION_MS = 1000, SHARED_INVITE_MS = 5000 },
	Common = { Integer = function(v) return tonumber(v) end },
	Catalogue = { Entries = function() return {} end },
	Service = { Within = function() return true end, Ready = function() return true end,
		Offered = function(name) return { name = name, once = false } end } }
local env = setmetatable({ OPX = { Modules = { Get = function() return M end },
	Api = { Get = function() return { GetPlayer = function(p) return { PlayerData = data[p] } end } end },
	Sessions = sessions, UserIdOf = function(p) return 'account' .. p end,
	Now = function() return now end, Math = { Finite = tonumber }, Result = { Kind = function(_, k) return k end } },
	Open77 = { playerInteractions = { request = function() requested = requested + 1; return { id = 'pair' } end },
		players = { position = function() return { x = 0, y = 0, z = 0 } end,
			all = function() return { 1, 2 } end } }, TriggerClientEvent = function() end }, { __index = _G })
assert(loadfile('modules/animations/server/duo.lua', 't', env))()
local function invite()
	assert(M.Duo.Request(1, { actor = 'wave', target = 'wave' }).ok)
end
invite()
data[1] = {}
M.Duo.Reply(2, 1, true)
assert(requested == 0, 'new actor inherited an old invitation')
invite()
data[2] = {}
M.Duo.Reply(2, 2, true)
assert(requested == 0, 'replacement target accepted prior consent')
invite()
sessions[1] = {}
M.Duo.Reply(2, 3, true)
assert(requested == 0, 'reconnected actor inherited consent')
invite()
now = 5000
M.Duo.Reply(2, 4, true)
assert(requested == 0, 'consent accepted at its expiry')
now = 6000
invite()
M.Duo.Reply(2, 5, true)
assert(requested == 1, 'legitimate pair refused')
print('animation consent audit: PASS')
