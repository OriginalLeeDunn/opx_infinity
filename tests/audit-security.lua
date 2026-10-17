--- Regression checks for deferred disconnects and private staff responses.
-- @author dop42
--
-- Run with `lua tests/audit-security.lua`; explicit coroutine boundaries model
-- the host's queued threads and database reads without a running server.

local function load(path, env)
	assert(loadfile(path, 't', setmetatable(env, { __index = _G })))()
end

local handlers, threads, events = {}, {}, {}
local account = 'first'
local env = {
	OPX = { Host = { PLAYER_DISCONNECTED = 'disconnect' }, Channel = { INTERNAL = 'internal' },
		Event = function(_, area, event) return area .. ':' .. event end,
		Now = function() return 0 end },
	GetPlayerIdentifier = function() return account end,
	GetPlayerName = function() return 'name' end,
	Open77 = { log = { warn = function() end } },
	AddEventHandler = function(event, fn) handlers[event] = fn end,
	TriggerEvent = function(...) events[#events + 1] = { ... } end,
	CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
	Wait = coroutine.yield,
}
load('core/server/sessions.lua', env)
local OPX = env.OPX
local first = OPX.EnsureSession(7)
handlers.disconnect(7)
assert(coroutine.resume(threads[1]))
account = 'second'
local second = OPX.EnsureSession(7)
assert(first ~= second)
assert(coroutine.resume(threads[1]))
assert(OPX.Sessions[7] == second, 'deferred cleanup erased the replacement session')
OPX.ForgetSession(7)
local count = #events
OPX.ForgetSession(7)
assert(#events == count, 'missing session emitted an identity-free departure')

-- Load the actual menu against yielding readers, then replace or revoke its
-- audience while the database is suspended. No sensitive response may escape.
local grants, sent, commands = {}, {}, {}
local M = { OPENER = 'menu', Command = { MENU = 'menu', CHARACTER_FIND = 'find',
	CHARACTER_LIST = 'characters', INVENTORY_VIEW = 'view', INVENTORY_REMOVE = 'remove' },
	Event = { REFRESH = 'refresh', TARGET_REPORT = 'report', FOUND = 'found',
		BAG = 'bag', CHARACTERS = 'characters', ITEMS = 'items' },
	Server = {}, Inventory = {}, Offline = {}, Characters = {}, Players = {}, World = {} }
for _, grant in pairs(M.Command) do grants[grant] = true end
M.Server.Commands = function() return {} end
M.Server.Command = function(name, spec) commands[name] = spec end
M.Server.Cooled = function() return false end
M.Server.Permitted = function(_, grant) return grants[grant] == true end
M.Server.Audit = function() end
M.Server.Heavy = function(_, _, fn) fn() end
M.Offline.Page = function() coroutine.yield(); return { { firstName = 'private' } } end
M.Characters.Rows = M.Offline.Page
M.Inventory.Target = function() return 'target' end
M.Inventory.Bag = function() coroutine.yield(); return { items = {} } end
M.Inventory.Catalog = function() return { items = {} } end
env.OPX.Modules = { Get = function() return M end }
env.OPX.Tune = { Number = function() return 0 end }
env.RegisterNetEvent = function(event, fn) handlers[event] = fn end
env.TriggerClientEvent = function(...) sent[#sent + 1] = { ... } end
env.source = 7
load('modules/admin/server/menu.lua', env)
M.Menu.Register()

local function request(topic, arg, change)
	account = 'operator'
	OPX.EnsureSession(7)
	grants.find, grants.characters, grants.view, grants.remove, grants.menu = true, true, true, true, true
	local before = #sent
	local task = coroutine.create(function() handlers.refresh(topic, arg) end)
	assert(coroutine.resume(task))
	assert(coroutine.status(task) == 'suspended', 'reader did not reach database boundary')
	change()
	assert(coroutine.resume(task))
	return #sent - before
end
assert(request('found', { mode = 'recent' }, function() end) == 1, 'legitimate result was dropped')
for _, entry in ipairs({ { 'found', { mode = 'recent' } }, { 'characters', '8' }, { 'bag', '8' } }) do
	assert(request(entry[1], entry[2], function()
		account = 'stranger'
		OPX.EnsureSession(7)
	end) == 0, 'private response reached a recycled slot')
	assert(request(entry[1], entry[2], function() grants.menu = false end) == 0,
		'private response survived opener revocation')
end
assert(request('found', { mode = 'recent' }, function() grants.find = false end) == 0,
	'private response survived its specific grant revocation')

env.GetCurrentResourceName = function() return 'test' end
load('modules/admin/server/main.lua', env)
M.Server.Permitted = function(_, grant) return grants[grant] == true end
account, grants.find = 'operator', true
OPX.EnsureSession(7)
local allowed = M.Server.Recipient(7, 'find')
assert(allowed(), 'valid typed-read recipient was refused')
grants.find = false
assert(not allowed(), 'typed-read recipient survived grant revocation')
grants.find = true
local ran = 0
M.Server.Heavy(7, 'test', function() ran = ran + 1 end)
local queued = threads[#threads]
account = 'replacement'
OPX.EnsureSession(7)
assert(not allowed(), 'typed-read recipient survived connection replacement')
assert(coroutine.resume(queued))
assert(ran == 0, 'a deferred staff worker ran for the replacement connection')
M.Server.ForgetHeavy(7)
M.Server.Heavy(7, 'test', function() ran = ran + 1 end)
assert(coroutine.resume(threads[#threads]))
assert(ran == 1, 'a current staff worker failed to run')

local character, named = {}, 0
character.Event = { ANNOUNCE = 'announce', NAME = 'name', HEADING = 'heading', LOADED = 'loaded' }
character.Operation = { NAME = 'name' }
character.Settings = { DEFAULT_SPAWN = { SET = true }, JOBS = {}, GANGS = {} }
character.GetPlayer = function() return character.player end
character.SetName = function(player)
	assert(player == character.player, 'request renamed another character')
	named = named + 1
	return { ok = true, value = { firstName = 'A', lastName = 'B' } }
end
env.OPX.Modules.Get = function() return character end
env.OPX.Host.PLAYER_CONNECTED, env.OPX.Host.PLAYER_READY = 'connect', 'ready'
env.OPX.Command = { Register = function() end }
env.OPX.Table = { Count = function() return 0 end }
env.OPX.Cooling = function() return false end
env.OPX.NotifyLocale = function() end
env.Open77.log.debug = function() end
load('modules/character/server/main.lua', env)
character.Start()
account = 'newcomer'
character.player = { PlayerData = { userId = 'previous-account' } }
local before = #sent
handlers.announce()
assert(#sent == before, 'announce disclosed the previous account PlayerData')
handlers.name({ firstName = 'A', lastName = 'B' })
assert(named == 0, 'a new account could rename the previous account character')
character.player = { PlayerData = { userId = account } }
handlers.name({ firstName = 'A', lastName = 'B' })
local pending = threads[#threads]
account = 'another-account'
OPX.EnsureSession(7)
character.player = { PlayerData = { userId = account } }
assert(coroutine.resume(pending))
assert(named == 0, 'queued naming renamed the next connection character')
handlers.name({ firstName = 'A', lastName = 'B' })
assert(coroutine.resume(threads[#threads]))
assert(named == 1, 'the current connection could not name its own character')

local progress = { Ending = { STOPPED = 'stopped', FINISHED = 'finished',
	CANCELLED = 'cancelled', INTERRUPTED = 'interrupted' },
	Event = { START = 'startProgress', CANCEL = 'cancelProgress', REPORT = 'reportProgress',
		ON_FINISHED = 'progressFinished' } }
local contract, now, verdict = nil, 0, nil
character.player.PlayerData.citizenId = 'character-a'
OPX.Modules.Get = function() return progress end
OPX.Result = { Ok = function(value) return { ok = true, value = value } end,
	Err = function(code) return { ok = false, error = code } end }
OPX.Api = { Get = function() return character end,
	Provide = function(_, _, value) contract = value end }
OPX.Text = { Clean = function(text) return text end }
OPX.Table.DeepCopy = function(value) return value end
OPX.Publish = function() end
OPX.Now = function() return now end
load('modules/progress/server/main.lua', env)
progress.Init()
progress.Api()
progress.Start()
local function startBar()
	verdict = nil
	local result = contract.Start(7, 'test', { durationMs = 1000, label = 'Test' },
		function(_, outcome) verdict = outcome end)
	assert(result.ok, result.error)
	return result.value.id
end
local id = startBar()
now = 1000
handlers.reportProgress(id, 'finished')
assert(verdict and verdict.completed, 'legitimate progress completion was refused')
id = startBar()
character.player.PlayerData.citizenId = 'character-b'
now = 2000
handlers.reportProgress(id, 'finished')
assert(verdict and not verdict.completed and verdict.ending == 'left',
	'progress completed on a different character')
id = startBar()
account = 'replacement-account'
OPX.EnsureSession(7)
now = 3000
handlers.reportProgress(id, 'finished')
assert(verdict and not verdict.completed, 'progress completed on a different account')
id = startBar()
local timeout = threads[#threads]
character.player.PlayerData.citizenId = 'character-c'
assert(coroutine.resume(timeout))
assert(verdict and not verdict.completed and verdict.ending == 'left',
	'the watchdog retained progress after a character switch')
id = startBar()
local sentBefore = #sent
character.player.PlayerData.citizenId = 'character-d'
assert(not contract.Stop(7, 'test', id).ok)
assert(#sent == sentBefore, 'stopping an obsolete bar cancelled the new occupant client')
id = startBar()
character.player.PlayerData.citizenId = 'character-e'
assert(contract.State(7).value == nil, 'state disclosed an obsolete bar')

local lifecycle = { OPX = { IsServer = true, Config = { MODULES = {} } },
	Open77 = { log = { error = function() end } } }
load('core/shared/registry.lua', lifecycle)
load('core/shared/lifecycle.lua', lifecycle)
local api, modules = lifecycle.OPX.Api, lifecycle.OPX.Modules
local upstream = modules.Declare({ id = 'upstream' })
upstream.Api = function() error('provider failed') end
local dependent = modules.Declare({ id = 'dependent', requires = { 'upstream' } })
dependent.Api = function() api.Provide('dependent', 1, {}) end
local optional = modules.Declare({ id = 'optional', optional = { 'dependent' } })
optional.Start = function()
	assert(api.Get('dependent') == nil, 'optional consumer received a contract of a module that cannot start')
end
assert(modules.Run())
assert(modules.Record('dependent').State == 'unavailable')
assert(api.Get('dependent') == nil, 'unavailable provider retained its published contract')

local exports, caller, invoiceReads = {}, 'writer', 0
OPX.Config = { SERVER = { EXPORTS = { READ = '*', WRITERS = '*' } } }
OPX.Booted = true
OPX.Host.RESOURCE_STOP = 'resourceStop'
OPX.Audit = { Log = function() end }
env.Open77.log.error = function() end
env.GetInvokingResource = function() return caller end
env.exports = function(name, fn) exports[name] = fn end
load('core/shared/exports.lua', env)
local invoices = { Issue = function(spec) return OPX.Result.Ok(spec.source) end,
	Get = function()
		invoiceReads = invoiceReads + 1
		return OPX.Result.Ok({ source = 'ext:' .. string.rep('a', 28) })
	end,
	Cancel = function() return OPX.Result.Ok(true) end }
OPX.Api.Get = function(name)
	if name == 'invoices' then return invoices end
	if name == 'character' then return character end
end
character.GetPlayerByCitizenId = function() return character.player end
OPX.CitizenId = { Parse = function(value) return OPX.Result.Ok(value) end }
load('core/server/exports.lua', env)
local function exported(name, ...)
	local args, result = table.pack(...), nil
	local task = coroutine.create(function() result = exports[name](table.unpack(args, 1, args.n)) end)
	while coroutine.status(task) ~= 'dead' do
		local before = #threads
		assert(coroutine.resume(task))
		for index = before + 1, #threads do assert(coroutine.resume(threads[index])) end
	end
	return result
end
character.player.PlayerData.userId = 'departed-account'
assert(not exported('GetPlayerData', 7).ok, 'export exposed a stale account character')
assert(not exported('GetPlayerByCitizenId', 'AAA-AAAA').ok, 'citizen export exposed a stale account character')
caller = string.rep('a', 28) .. '-other'
assert(not exported('IssueInvoice', 7, 8, 10, 'test').ok,
	'long caller issued an invoice under a truncated namespace')
assert(not exported('CancelInvoice', 1).ok and invoiceReads == 0,
	'long caller could access another caller invoice namespace')
caller = 'writer'
assert(exported('IssueInvoice', 7, 8, 10, 'test').value == 'ext:writer',
	'an unambiguous caller could not issue its invoice')
print('security audit regressions passed')
