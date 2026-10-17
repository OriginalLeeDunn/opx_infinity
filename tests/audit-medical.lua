--- Medical consent and patient identity regressions without a running host.
-- @author dop42
--
-- The real server handlers run against controlled readers. The progress callback
-- and consent events are delivered after identity, position or time changes.

local function load(path, env)
	assert(loadfile(path, 't', setmetatable(env, { __index = _G })))()
end
local now, callback, healed, charged = 0, nil, 0, 0
local handlers, threads, sent = {}, {}, {}
local players = { [7] = { PlayerData = { citizenId = 'medic', userId = 'a', job = { name = 'medic' } } },
	[8] = { PlayerData = { citizenId = 'patient', userId = 'b', job = { name = 'unemployed' } } } }
local positions = { [7] = { x = 0, y = 0, z = 0 }, [8] = { x = 1, y = 0, z = 0 } }
local treatment = { key = 'heal', kind = 'heal', minGrade = 0, durationMs = 1000,
	items = {}, fee = 50, pay = 10, heal = 0.2, consent = false }
local service = { key = 'clinic', short = 'Clinic', label = 'Clinic', treatments = { heal = treatment },
	subscription = { enabled = false }, dispatch = { answers = 'anyone' },
	billing = { onUnpaid = 'refuse', moneyType = 'BANK', payMoneyType = 'BANK' },
	beds = {}, carry = { enabled = false } }
local config = { services = { clinic = service }, serviceOrder = { 'clinic' }, reach = 3,
	requestMs = 0, scanMs = 1000, membership = 'primary' }
local M = { Model = { Settings = function() return config end, Jobs = function() return { medic = 0 } end,
	Fee = function() return 50 end, Problems = function() return {} end },
	Kind = { CARRY = 'carry', REVIVE = 'revive', HEAL = 'heal' }, Reason = {},
	Event = setmetatable({}, { __index = function(_, key) return key end }) }
local character = { GetPlayer = function(id) return players[id] end,
	GetMetadata = function() return {} end, GetMoney = function() return 1000 end,
	RemoveMoney = function() charged = charged + 1; return true end,
	AddMoney = function() return true end }
local progress = { Start = function(_, _, _, fn) callback = fn; return { ok = true, value = { id = 1 } } end }
local env = { OPX = { Modules = { Get = function() return M end },
	Config = { MODULES = {}, SHARED = {} },
	Math = { Finite = tonumber }, Table = { DeepCopy = function(value) return value end },
	Result = { Ok = function(value) return { ok = true, value = value } end },
	Now = function() return now end,
	Api = { Get = function(name)
		if name == 'character' then return character end
		if name == 'progress' then return progress end
	end },
	JobGate = { Evaluate = function(_, snapshot) return snapshot.job.name == 'medic' end },
	Host = { PLAYER_DISCONNECTED = 'disconnect' }, Channel = { LOCAL = 'on' },
	Event = function(_, area, event) return area .. ':' .. event end,
	Scheduler = { Every = function() end }, Publish = function() end,
	Locale = { Money = tostring }, Audit = { Log = function() end }, NotifyLocale = function() end },
	Open77 = { players = { position = function(id) return positions[id] end,
		getHealth = function() return { health = 50, maxHealth = 100 } end,
		setHealth = function() healed = healed + 1; return true end },
		log = { warn = function() end, info = function() end, debug = function() end } },
	RegisterNetEvent = function(name, fn) handlers[name] = fn end,
	AddEventHandler = function() end,
	CreateThread = function(fn) threads[#threads + 1] = fn end,
	TriggerClientEvent = function(name, player, value) sent[#sent + 1] = { name, player, value } end,
	locale = function(key) return key end }
load('modules/medical/server/dispatch.lua', env)
load('modules/medical/server/main.lua', env)
M.Init()
M.Start()
local function treat()
	callback = nil
	M.Server.OnTreat(7, { target = 8, service = 'clinic', treatment = 'heal' })
end
treat()
assert(callback, 'valid treatment did not start')
players[8] = { PlayerData = { citizenId = 'new-patient', userId = 'b', job = { name = 'unemployed' } } }
callback(7, { completed = true })
assert(healed == 0 and charged == 0, 'the next patient character was healed or charged')
treat()
assert(callback)
callback(7, { completed = true })
assert(healed == 1 and charged == 1, 'valid treatment failed to heal and bill')
treatment.consent = true

local function consent(change)
	treat()
	assert(callback == nil, 'consent treatment began before acceptance')
	local invitation
	for index = #sent, 1, -1 do
		if sent[index][1] == 'ASK' then invitation = sent[index][3].inviteId; break end
	end
	assert(invitation)
	change()
	env.source = 8
	handlers.CONSENT({ inviteId = invitation, accepted = true })
	threads[#threads]()
	assert(callback == nil, 'an invalid consent began treatment')
end
consent(function() now = now + 20000 end)
consent(function() positions[7].x = 100 end)
positions[7].x = 0
consent(function() players[7].PlayerData.job.name = 'unemployed' end)
M.Model.Jobs = function() return nil end
treatment.consent = false
players[7].PlayerData.job.name = 'medic'
treat()
assert(callback == nil, 'a service missing its jobs became publicly accessible')
print('medical audit regressions passed')
