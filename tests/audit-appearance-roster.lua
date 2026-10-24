--- Empty-server appearance reports must not imply failed player replication.
-- @author dop42
local now, nearby, requested = 10000, {}, nil
local hooks, warnings = {}, {}
local M = { Settings = {}, Face = { worldEligible = true }, OFFICIAL = 'open77_appearance',
	Clothing = { SLOTS = {}, OUTFIT_SLOTS = {}, DEFAULT = { equipment = {} } },
	Runtime = { NowMs = function() return now end },
	Event = { PRESENT_ACK = 'ack', REPLAYED = 'replayed', RESEND = 'resend', LOOK = 'look', REPLAY = 'replay' } }
local env = setmetatable({ OPX = { Modules = { Get = function() return M end }, Host = { WORLD_READY = 'world' } },
	Open77 = { players = { nearby = function() return nearby end },
		log = { info = function() end, debug = function() end, warn = function(line) warnings[#warnings + 1] = line end } },
	GetResourceState = function() return 'stopped' end,
	RegisterNetEvent = function(name, fn) hooks[name] = fn end,
	AddEventHandler = function() end,
	TriggerServerEvent = function(name, sequence) if name == 'replay' then requested = sequence end; return true end,
}, { __index = _G })
assert(loadfile('modules/appearance/client/presence.lua', 't', env))()
M.Presence.Init(); M.Presence.Wire(); M.Presence.Check()
hooks.replayed(requested)
now = 25000; M.Presence.Check()
assert(#warnings == 0, 'being alone produced an appearance failure warning')
nearby = { { playerId = 2 } }
now = 40000; M.Presence.Check()
assert(#warnings == 1 and warnings[1]:find('no look has arrived', 1, true),
	'a nearby peer without an appearance no longer raises the diagnostic')
now = 55000; M.Presence.Check()
assert(#warnings == 1, 'the missing-appearance warning repeats every pass')
print('appearance roster: empty server stays quiet; a real missing peer warns once')
