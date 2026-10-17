--- Justice fails closed on unavailable records and stale private recipients.
-- @author dop42

local function load(path, env)
	assert(loadfile(path, 't', setmetatable(env, { __index = _G })))()
end
local M = { Settings = { POLICE = { JOBS = { ncpd = 0 } }, LAWYER = { JOBS = { lawyer = 0 } },
	JUDGE = { JOBS = { judge = 0 } }, CARD_ITEM = { NAME = false },
	CITY_HALLS = { hall = { DESK = { X = 1, Y = 1, Z = 1 } } },
	LICENCES = { gun = { FEE = 100, DAYS = 0, CLEAN = true } } },
	Kind = { OFFENCE = 'offence', VERDICT = 'verdict', WARRANT = 'warrant' },
	LICENCES_KEY = 'licences', Event = setmetatable({}, { __index = function(_, key) return key end }),
	Command = { DESKS = 'desks', CAPTURE = 'capture' } }
local players = { [7] = { PlayerData = { citizenId = 'judge-id', job = { name = 'judge' } } },
	[8] = { PlayerData = { citizenId = 'lawyer-id', job = { name = 'lawyer' } } },
	[9] = { PlayerData = { citizenId = 'client-id', job = { name = 'unemployed' } } } }
local now, debits, represented = 0, 0, 0
local sent = {}
local character = { GetPlayer = function(id) return players[id] end,
	GetPlayerByCitizenId = function(cid)
		for id, player in pairs(players) do
			player.PlayerData.source = id
			if player.PlayerData.citizenId == cid then return player end
		end
	end,
	GetMetadata = function() return {} end, GetMoney = function() return 1000 end,
	RemoveMoney = function() debits = debits + 1; return true end }
local OPX = { Modules = { Get = function() return M end }, Math = { Finite = tonumber },
	Spots = { Coordinate = tonumber, ServerReach = function(value) return value end },
	Result = { Ok = function(value) return { ok = true, value = value } end,
		Err = function(code) return { ok = false, error = code } end },
	Now = function() return now end, Cooling = function() return false end,
	Storage = { Query = function() return { ok = false, error = 'database unavailable' } end },
	Api = { Get = function(name) if name == 'character' then return character end end },
	Text = { Clean = function(value) return value end },
	Table = { Count = function(value) local n = 0; for _ in pairs(value) do n = n + 1 end; return n end },
	Schema = { Add = function() end }, Command = { Register = function() end },
	Scheduler = { Every = function() return 1 end }, Host = { PLAYER_DISCONNECTED = 'disconnect' },
	Event = function(_, area, event) return area .. ':' .. event end, Channel = { LOCAL = 'on' } }
OPX.CitizenId = { Parse = function(value) return OPX.Result.Ok(value) end }
local env = { OPX = OPX, Open77 = { players = { position = function() return { x = 1, y = 1, z = 1 } end },
	log = { error = function() end, warn = function() end, info = function() end } },
	TriggerClientEvent = function(name, _, value) sent[#sent + 1] = { name, value } end,
	AddEventHandler = function() end, RegisterNetEvent = function() end, locale = function(key) return key end }
load('lib/shared/jobgate.lua', env)
load('modules/justice/shared/access.lua', env)
load('modules/justice/server/storage.lua', env)
assert(M.Storage.List('client-id', 30, false) == nil, 'failed database read became an empty record')
assert(not M.Access.Clean(nil, 0, 30), 'an unavailable record qualified for a clean licence')
load('modules/justice/server/main.lua', env)
M.Init()
M.Start()
M.Storage.List = function() return nil end
M.Buy(9, 'hall', 'gun')
assert(debits == 0, 'a clean licence was sold without a successful record check')
M.Storage.List = function() coroutine.yield(); return {} end
local before = #sent
local task = coroutine.create(function() M.ViewRecord(7, 'client-id') end)
assert(coroutine.resume(task))
players[7] = { PlayerData = { citizenId = 'replacement', job = { name = 'judge' } } }
assert(coroutine.resume(task))
assert(#sent == before, 'private record reached the replacement judge')
M.Storage.Pending = function() coroutine.yield(); return {} end
M.Storage.Warrants = function() return {} end
M.Storage.Cases = function() return {} end
before = #sent
task = coroutine.create(function() M.Office(7) end)
assert(coroutine.resume(task))
players[7].PlayerData.job.name = 'unemployed'
assert(coroutine.resume(task))
assert(#sent == before, 'the court archive survived judge-role revocation')
M.Storage.Counsel = function() return nil end
M.Storage.SetCounsel = function() represented = represented + 1; return true end
local offered, id = M.Offer(8, 9)
assert(offered and id)
now = 30000
local accepted, reason = M.Consent(9, id, true)
assert(not accepted and reason == 'expired' and represented == 0,
	'an expired lawyer invitation was accepted')
print('justice audit regressions passed')
