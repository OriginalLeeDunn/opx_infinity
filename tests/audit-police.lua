--- Police role, jurisdiction, delayed cuff and frisk recipient regressions.
-- @author dop42

local function load(path, env)
	assert(loadfile(path, 't', setmetatable(env, { __index = _G })))()
end
local capabilities = { CUFF = 'cuff', FRISK = 'frisk', IMPOUND = 'impound', FINE = 'fine' }
local M = { Capability = capabilities, Action = { cuff = 'cuff', frisk = 'frisk' },
	Event = setmetatable({}, { __index = function(_, key) return key end }) }
local raw = { SERVICES = { ncpd = { JOBS = { ncpd = 0 }, CAPABILITIES = { cuff = 0, frisk = 0, impound = 0, fine = 0 } } },
	CUFFS = { ITEM = 'cuffs', CONSUME = false, DURATION_MS = 1000 } }
raw.CRIMES = { theft = { FINE = 100 } }
local players = { [7] = { PlayerData = { citizenId = 'officer', job = { name = 'ncpd' } } },
	[8] = { PlayerData = { citizenId = 'suspect', job = { name = 'unemployed' } } } }
local writes, callback, down = 0, nil, false
local sent = {}
local character = { GetPlayer = function(id) return players[id] end,
	GetMetadata = function() return {} end,
	SetMetadata = function() writes = writes + 1; return true end }
local inventory = { GetItemCount = function() return { ok = true, value = 1 } end,
	GetInventory = function() coroutine.yield(); return { ok = true, value = { items = {} } } end }
local OPX = { Modules = { Get = function() return M end }, Config = { MODULES = { police = raw }, SHARED = {} },
	Math = { Finite = tonumber }, Spots = { Coordinate = tonumber },
	Result = { Ok = function(value) return { ok = true, value = value } end,
		Err = function(code) return { ok = false, error = code } end },
	Api = { Get = function(name)
		if name == 'character' then return character end
		if name == 'inventory' then return inventory end
		if name == 'progress' then return { Start = function(_, _, _, fn)
			callback = fn; return { ok = true, value = { id = 1 } }
		end } end
		if name == 'downed' then return { IsDown = function()
			return { ok = true, value = { down = down, stage = 'wounded' } }
		end } end
	end }, Now = function() return 1000 end, Table = { DeepCopy = function(value) return value end },
	Audit = { Log = function() end }, Publish = function() end, NotifyLocale = function() end }
local env = { OPX = OPX, Open77 = { players = { position = function()
	return { x = 1, y = 1, z = 1, bucket = 0 }
	end }, vehicles = { get = function() return { x = 1, y = 1, z = 1, bucket = 10 } end } },
	TriggerClientEvent = function(name, _, value) sent[#sent + 1] = { name, value } end,
	locale = function(key) return key end }
load('lib/shared/jobgate.lua', env)
load('modules/police/shared/access.lua', env)
load('modules/police/server/dispatch.lua', env)
load('modules/police/server/main.lua', env)
M.Init()
M.Server.OnImpound(7, { vehicleId = 1 })
assert(sent[#sent][2].code == 'vehicle_far', 'impound ignored routing bucket')
M.Server.OnAct(7, { target = 8, action = 'cuff' })
assert(callback, 'valid cuff did not start')
players[8] = { PlayerData = { citizenId = 'new-suspect', job = { name = 'unemployed' } } }
callback(7, { completed = true })
assert(writes == 0, 'delayed cuff restrained another character')
down = true
local before = #sent
local task = coroutine.create(function() M.Server.OnAct(7, { target = 8, action = 'frisk' }) end)
assert(coroutine.resume(task))
players[7] = { PlayerData = { citizenId = 'replacement-officer', job = { name = 'ncpd' } } }
assert(coroutine.resume(task))
assert(#sent == before, 'frisk disclosed the old search to a replacement officer')
raw.SERVICES.ncpd.JOBS = nil
M.Init()
M.Server.OnBoard(7)
assert(sent[#sent][2].code == 'not_member', 'missing police jobs granted public police access')
raw.SERVICES.ncpd.JOBS = { ncpd = 0 }
raw.SERVICES.ncpd.ENCLAVES = {}
local config = M.Access.Settings(raw)
assert(not M.Access.InJurisdiction(config.services.ncpd, { x = 1, y = 1, z = 1 }),
	'an explicitly empty enclave list granted global jurisdiction')
raw.SERVICES.ncpd.ENCLAVES = nil
config = M.Access.Settings(raw)
assert(M.Access.InJurisdiction(config.services.ncpd, { x = 1, y = 1, z = 1 }))
assert(M.Access.Jobs({ jobs = { ncpd = true } }, 0).ncpd == false,
	'a malformed police grade became grade zero')
-- A debit refused after a character switch must never become the new one's debt.
M.Init()
players[7] = { PlayerData = { citizenId = 'officer', job = { name = 'ncpd' } } }
players[8] = { PlayerData = { citizenId = 'suspect', job = { name = 'unemployed' } } }
local debtOn, refundTo, debitTarget
character.GetMoney = function() return 50 end
character.RemoveMoney = function(target) debitTarget = target; coroutine.yield(); return false end
character.SetMetadata = function(id) debtOn = id; return true end
local fineTask = coroutine.create(function() M.Server.OnFine(7, { target = 8, code = 'theft', amount = 100 }) end)
assert(coroutine.resume(fineTask))
players[8] = { PlayerData = { citizenId = 'innocent-replacement', job = { name = 'unemployed' } } }
assert(coroutine.resume(fineTask))
assert(debitTarget == 'suspect' and debtOn == nil, 'an interrupted fine became the replacement character debt')
-- Even a debit that completed before its hook resumed refunds the original citizen.
players[8] = { PlayerData = { citizenId = 'suspect', job = { name = 'unemployed' } } }
character.RemoveMoney = function() coroutine.yield(); return true end
character.AddMoneyOffline = function(cid, _, amount) refundTo = cid; assert(amount == 50); return { ok = true } end
fineTask = coroutine.create(function() M.Server.OnFine(7, { target = 8, code = 'theft', amount = 100 }) end)
assert(coroutine.resume(fineTask))
players[8] = { PlayerData = { citizenId = 'another-innocent', job = { name = 'unemployed' } } }
assert(coroutine.resume(fineTask))
assert(refundTo == 'suspect' and debtOn == nil, 'interrupted fine refunded a reused player slot')
print('police audit regressions passed')
