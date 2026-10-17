--- Taxi billing never follows a recycled character or bypasses invoice refusal.
-- @author dop42

local function load(path, env)
	assert(loadfile(path, 't', setmetatable(env, { __index = _G })))()
end
local M = { Kind = { CALL = 'call', HAIL = 'hail', STREET = 'street' },
	Phase = { ENROUTE = 'enroute', RIDING = 'riding' },
	Event = setmetatable({}, { __index = function(_, key) return key end }) }
local raw = { MIN_RIDE_M = 0, COMPANIES = { cab = { JOBS = { taxi = 0 }, ON_DUTY = false,
	FARE = { BASE = 100, PER_KM = 10, MIN = 100 } } } }
local players = { [7] = { PlayerData = { citizenId = 'driver', job = { name = 'taxi' } } },
	[8] = { PlayerData = { citizenId = 'passenger', job = { name = 'unemployed' } } } }
local charged, issued = 0, 0
local invoiceEnabled = true
local character = { GetPlayer = function(id) return players[id] end,
	RemoveMoney = function() charged = charged + 1; return true end, AddMoney = function() return true end }
local OPX = { Modules = { Get = function() return M end }, Config = { MODULES = { taxi = raw }, SHARED = {} },
	Math = { Finite = tonumber }, Spots = { Coordinate = tonumber },
	Result = { Ok = function(value) return { ok = true, value = value } end },
	Api = { Get = function(name)
		if name == 'character' then return character end
		if name == 'invoices' and invoiceEnabled then return { Issue = function()
			issued = issued + 1; return { ok = false, error = 'invoice.busy' }
		end } end
	end }, Now = function() return 1000 end,
	Audit = { Log = function() end }, Publish = function() end, NotifyLocale = function() end,
	Locale = { Money = tostring } }
local env = { OPX = OPX, Open77 = { players = { all = function() return { 7, 8 } end,
	position = function() return { x = 1, y = 1, z = 1 } end },
	vehicles = { getPlayerSeat = function(id) return { vehicleId = 1,
		seat = id == 7 and 'seat_front_left' or 'seat_back_left' } end },
	log = { warn = function() end, info = function() end } },
	TriggerClientEvent = function() end, locale = function(key) return key end }
load('lib/shared/jobgate.lua', env)
load('modules/taxi/shared/model.lua', env)
load('modules/taxi/server/dispatch.lua', env)
load('modules/taxi/server/main.lua', env)
M.Init()
M.Server.OnHail(7)
local rides = M.Server.Rides()
assert(rides[7], 'valid hail did not start')
M.Server.OnStop(7)
assert(issued == 1 and charged == 0, 'invoice refusal fell back to a nonconsensual direct debit')
invoiceEnabled = false
M.Server.OnHail(7)
players[8] = { PlayerData = { citizenId = 'replacement-passenger', job = { name = 'unemployed' } } }
M.Server.OnStop(7)
assert(charged == 0, 'taxi debited the replacement passenger character')
M.Server.OnHail(7)
players[7] = { PlayerData = { citizenId = 'replacement-driver', job = { name = 'taxi' } } }
M.Server.Sweep()
rides = M.Server.Rides()
assert(rides[7] == nil and charged == 0, 'ride survived replacement of its driver')
M.Server.OnHail(7)
M.Server.OnStop(7)
assert(charged == 1, 'direct billing with no invoice service stopped working')
local malformed = M.Model.Jobs({ jobs = { taxi = true } }, 0)
assert(malformed.taxi == false, 'a malformed taxi grade became grade zero')
print('taxi audit regressions passed')
