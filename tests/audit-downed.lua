--- Wounding and bleed-out stay attached to the original character.
-- @author dop42

local function load(path, env)
	assert(loadfile(path, 't', setmetatable(env, { __index = _G })))()
end
local now, killed, healthWrites = 0, 0, 0
local player = { PlayerData = { citizenId = 'first' } }
local tasks, api = {}, nil
local M = { Settings = { MODE = 'wounded', WOUNDED = { HEALTH = 1, BLEED_OUT_S = 1 },
	HOSPITALS = { { X = 1, Y = 1, Z = 1 } } }, Storage = { SCHEMA = {},
	Ready = function() return false end, Write = function() end, Clear = function() end } }
local OPX = { Modules = { Get = function() return M end },
	Result = { Ok = function(value) return { ok = true, value = value } end,
		Err = function(code) return { ok = false, error = code } end },
	Event = function(_, area, event) return area .. ':' .. event end,
	Channel = { NET = 'net', LOCAL = 'on', INTERNAL = 'in' },
	Api = { Get = function() return { GetPlayer = function() return player end } end,
		Provide = function(_, _, value) api = value end },
	Host = { PLAYER_DISCONNECTED = 'disconnect' }, Now = function() return now end,
	UserIdOf = function() return 'account' end, Sessions = { [7] = {} },
	Audit = { Log = function() end }, Schema = { Add = function() end },
	Scheduler = { Every = function() end }, Publish = function() end }
local env = { OPX = OPX, Open77 = { players = {
	all = function() return {} end, getHealth = function() return { health = 10, maxHealth = 100 } end,
	getLifeState = function() return { phase = 'alive' } end,
	position = function() return { x = 1, y = 1, z = 1 } end,
	isDead = function() return false end, name = function() return 'Player' end,
	setHealth = function() healthWrites = healthWrites + 1; return true end,
	setFrozen = function() return true end, kill = function() killed = killed + 1; return true end },
	ready = { isReady = function() return true end },
	combat = { onDamage = function() return 1 end },
	log = { info = function() end, warn = function() end, error = function() end } },
	CreateThread = function(fn) tasks[#tasks + 1] = fn end,
	TriggerClientEvent = function() end, RegisterNetEvent = function() end, AddEventHandler = function() end }
load('lib/shared/math.lua', env)
load('lib/shared/text.lua', env)
load('modules/downed/server/main.lua', env)
M.Init()
M.Api()
M.Start()
M.Wounded.Arbitrate({ victim = 7, amount = 20 })
player = { PlayerData = { citizenId = 'second' } }
tasks[#tasks]()
assert(healthWrites == 0, 'queued damage wounded the replacement character')
M.Wounded.Arbitrate({ victim = 7, amount = 20 })
tasks[#tasks]()
assert(api.IsDown(7).value.down == true, 'a real wound was not recorded')
player = { PlayerData = { citizenId = 'third' } }
now = 2000
M.Wounded.Bleed()
assert(killed == 0, 'the old character bleed-out killed the replacement')
assert(api.IsDown(7).value.down == false, 'the replacement inherited the old down state')
M.Wounded.Arbitrate({ victim = 7, amount = 20 })
tasks[#tasks]()
now = 4000
M.Wounded.Bleed()
assert(killed == 1, 'the original character bleed-out stopped working')
print('downed audit regressions passed')
