--- Native acceptance and character isolation for cosmetic cyberarm persistence.
-- @author dop42
--
-- Exercise the real service with a small host: no game is needed to prove that
-- the acknowledgement precedes persistence and cannot cross a character switch.
local checks = 0
local function check(label, value)
	assert(value, label)
	checks = checks + 1
	print('ok ' .. label)
end
local function channel(_, module, name) return module .. ':' .. name end
local handlers, sent, writes = {}, {}, {}
local data = { citizenId = 'OWNER001' }
local metadata, near, hasArms = {}, true, true
local time = 2000
local M = {
	Event = { STYLE = 'style', STYLE_DATA = 'data', STYLE_APPLY = 'apply', STYLE_RESULT = 'result',
		STYLE_RESTORE = 'restore', ON_OPERATED = 'operated' },
	Settings = { STYLES = { ENABLED = true, RECORDS = {} } },
	S = { chrome = { gorilla = { slot = 'arms' } } },
	Model = { ChairAt = function() return near and {} or nil end },
	Start = function() end, Stop = function() end,
}
local character = {
	GetPlayer = function(player) return player == 7 and { PlayerData = data } or nil end,
	GetMetadata = function(_, key) return metadata[key] end,
	SetMetadata = function(player, key, value)
		writes[#writes + 1] = { player = player, key = key, value = value }
		metadata[key] = value
		return true
	end,
}
local env = setmetatable({
	OPX = {
		Modules = { Get = function() return M end }, Api = { Get = function() return character end },
		Now = function() return time end, Life = { Down = function() return false end },
		Spots = { ServerReach = function() return 0 end },
		Channel = { INTERNAL = 'internal' }, Event = channel,
		Host = { PLAYER_DISCONNECTED = 'disconnect' }, NotifyLocale = function() end,
	},
	Open77 = { players = { position = function() return { x = 1, y = 2, z = 3, bucket = 0 } end },
		cyberware = { current = function() return { arms = hasArms and { profile = 'gorilla_arms' } or nil } end } },
	RegisterNetEvent = function(name, fn) handlers[name] = fn end,
	AddEventHandler = function(name, fn) handlers[name] = fn end,
	TriggerClientEvent = function(name, player, ...)
		sent[#sent + 1] = { name = name, player = player, args = { ... } }
	end,
}, { __index = _G })
assert(loadfile('modules/ripperdoc/server/styles.lua', 't', env))()
M.Start()
local function fire(event, player, ...)
	env.source = player
	handlers[event](...)
end
local function submit(style)
	time = time + 1100
	fire('style', 7, style)
	return sent[#sent]
end
local style = { schemaVersion = 1, enabled = true, record = '0x1234',
	primary = { r = 0, g = 20, b = 255 }, secondary = { r = 255, g = 120, b = 0 } }
local offered = submit(style)
check('authorized submission targets the owner only', offered.name == 'apply' and offered.player == 7)
check('submitting a style does not persist it', #writes == 0)
fire('result', 8, offered.args[1], true)
check('another player cannot acknowledge the owners request', #writes == 0)
fire('result', 7, offered.args[1], false)
check('native failure keeps the previous selection', #writes == 0 and sent[#sent].name == 'restore')
offered = submit(style)
fire('result', 7, offered.args[1], true)
check('native acceptance saves the owners bounded snapshot', #writes == 1 and writes[1].value.primary.b == 255)
fire('result', 7, offered.args[1], true)
check('duplicate acknowledgement cannot repeat the write', #writes == 1)
offered = submit(style)
data = { citizenId = 'OTHER001' }
fire('result', 7, offered.args[1], true)
check('switching characters invalidates an outstanding request', #writes == 1)
offered = submit(style)
time = time + 16000
fire('result', 7, offered.args[1], true)
check('expired native acceptance cannot save', #writes == 1)
near = false
offered = submit(style)
check('a player away from the clinic receives no native projection', offered.name ~= 'apply')
near, hasArms = true, false
offered = submit(style)
check('the cosmetic service does not install Gorilla Arms', offered.name ~= 'apply')
hasArms = true
M.Settings.STYLES.RECORDS = { ['0x5678'] = true }
offered = submit(style)
check('operator model restrictions are checked on the server', offered.name ~= 'apply')
M.Settings.STYLES.RECORDS = {}
fire('style', 7, 'restore') -- Rate limited until the next window.
time = time + 1100
fire('style', 7, 'restore')
check('restoration sends the saved colors only to their owner', sent[#sent].name == 'restore'
	and sent[#sent].player == 7 and sent[#sent].args[1].primary.b == 255)
handlers.operated(7, { applied = true, chrome = 'gorilla', action = 'remove' })
check('removing arm implants clears their cosmetic override', sent[#sent].name == 'restore' and sent[#sent].args[1] == false)
print(('%d cyberarm lifecycle checks passed'):format(checks))

do
	local hooks, jobs, pushes = {}, {}, {}
	local now, nextId, held = 0, 0, true
	local module = { Start = function() end, Stop = function() end,
		Screen = { Held = function() return held end } }
	local runtime = setmetatable({
		OPX = { Modules = { Get = function() return module end },
			Now = function() return now end,
			UI = { Send = function(_, _, payload) pushes[#pushes + 1] = payload end },
			Scheduler = { Every = function(name, _, fn) jobs[name] = fn; return name end,
				Cancel = function(name) jobs[name] = nil end } },
		Open77 = { weapons = { snapshot = function() nextId = nextId + 1; return nextId end } },
		AddEventHandler = function(name, fn) hooks[name] = fn end,
	}, { __index = _G })
	assert(loadfile('modules/inventory/client/weapon-hud.lua', 't', runtime))()
	module.Start()
	local refresh = jobs['inventory:weapon-hud']
	local function row(id, slot, rounds)
		hooks['open77:weapons:state'](id, slot, '', 'weapon', 'true', 'true', 'false', '', 'pistol',
			30, 10, rounds, 18, 'false')
	end
	refresh()
	row(1, 1, 12); row(1, 4, 8)
	check('HUD rows remain private until the full snapshot completes', #pushes == 0)
	hooks['open77:weapons:completed'](1, 'assign', 'true')
	check('unrelated operations cannot publish partial HUD state', #pushes == 0)
	hooks['open77:weapons:completed'](1, 'snapshot', 'true')
	check('the complete HUD replaces both hands at once', #pushes == 1 and #pushes[1].hands == 2
		and pushes[1].hands[1].magazine == 12 and pushes[1].hands[2].magazine == 8)
	refresh(); refresh()
	check('only one HUD snapshot is in flight', nextId == 2)
	row(1, 4, 99)
	hooks['open77:weapons:completed'](2, 'snapshot', 'false')
	check('failed snapshots clear stale readings', #pushes == 2 and #pushes[2].hands == 0)
	refresh(); row(3, 1, 3)
	hooks['open77:weapons:completed'](3, 'snapshot', 'true')
	refresh(); now = 13000; refresh()
	check('timeouts clear the HUD without publishing partial rows', #pushes[#pushes].hands == 0)
	held = false
	local count = #pushes
	refresh(); refresh()
	check('an empty HUD costs no repeated page writes', #pushes == count)
	module.Stop()
	check('stopping releases the HUD polling job', jobs['inventory:weapon-hud'] == nil)
end
print(('%d cosmetic and HUD checks passed'):format(checks))

do
	local hooks, jobs, outgoing = {}, {}, {}
	local menuSpec, formSpec, closes, resets, applies = nil, nil, 0, 0, 0
	local failReady = false
	local module = { Event = M.Event, Settings = { CLINICS = {} },
		Start = function() end, Stop = function() end }
	local menu = {
		Open = function(spec) menuSpec = spec; return { ok = true, value = { handle = 1 } } end,
		Close = function() closes = closes + 1 end,
	}
	local form = {
		Open = function(spec) formSpec = spec; return { ok = true, value = { handle = 2 } } end,
		Close = function() closes = closes + 1 end,
	}
	local records = {}
	for i = 1, 80 do records[i] = { type = 'strongarms', record = '0x' .. i, colors = { { r = 1, g = 2, b = 3 } } } end
	local native = {
		customizationCatalog = function() return records end,
		getCustomization = function() return nil end,
		setCustomization = function(value)
			check('native style projection receives a local snapshot only', type(value) == 'table')
			applies = applies + 1
			if failReady then failReady = false; return nil, 'body_not_ready' end
			return true
		end,
		resetCustomization = function() resets = resets + 1; return true end,
	}
	local runtime = setmetatable({
		OPX = {
			Modules = { Get = function() return module end },
			Api = { Get = function(name) return name == 'menu' and menu or name == 'form' and form or nil end },
			Text = { Clean = function(s, n) return s:sub(1, n) end },
			Toast = { Locale = function() end }, Note = function() end,
			Event = channel, Channel = { LOCAL = 'local' },
			Scheduler = { Every = function(name, _, fn) jobs[name] = fn; return name end,
				Cancel = function(name) jobs[name] = nil end },
		},
		Open77 = { cyberware = native }, locale = function(key) return key end,
		Wait = function() end, CreateThread = function(fn) fn() end,
		RegisterNetEvent = function(name, fn) hooks[name] = fn end,
		AddEventHandler = function(name, fn) hooks[name] = fn end,
		RegisterCommand = function() end,
		TriggerServerEvent = function(name, ...) outgoing[#outgoing + 1] = { name = name, args = { ... } } end,
	}, { __index = _G })
	assert(loadfile('modules/ripperdoc/client/styles.lua', 't', runtime))()
	module.Start()
	hooks.data({ family = 'strongarms', records = {} })
	check('installed style catalogs are not truncated to the form option limit', #menuSpec.items == 80)
	menuSpec.on({ action = 'select', data = { index = 80 } })
	check('native palette defaults reach the RGB fields', formSpec.fields[1].value == '010203')
	local count = #outgoing
	formSpec.on({ action = 'submit', values = { primary = 'notRGB', secondary = '000000' } })
	check('invalid RGB never reaches the server', #outgoing == count)
	formSpec.on({ action = 'submit', values = { primary = 'FF8000', secondary = '0011AA' } })
	local selected = outgoing[#outgoing].args[1]
	check('model identifiers and both RGB triplets survive selection', selected.record == '0x80'
		and selected.primary.r == 255 and selected.primary.g == 128 and selected.secondary.b == 170)
	hooks.apply('ticket', selected)
	check('native acceptance is acknowledged before server persistence', outgoing[#outgoing].name == 'result'
		and outgoing[#outgoing].args[1] == 'ticket' and outgoing[#outgoing].args[2] == true)
	failReady = true
	hooks.restore(selected)
	jobs['ripperdoc:style'](); jobs['ripperdoc:style']()
	check('restoration retries native body readiness', applies == 3)
	hooks['character:unloaded']()
	check('character unload closes owned views and releases native appearance', closes == 2 and resets == 1)
	module.Stop()
	check('stopping releases the cosmetic restoration job', jobs['ripperdoc:style'] == nil)
end
print(('%d dual weapon HUD and cyberarm lifecycle checks passed'):format(checks))
