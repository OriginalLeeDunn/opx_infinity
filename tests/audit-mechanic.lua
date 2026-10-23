--- Mechanic role, recipient and completion reservation regressions.
-- @author dop42

local function load(path, env)
	assert(loadfile(path, 't', setmetatable(env, { __index = _G })))()
end
local M = { OWNER = 'mechanic', Mode = { KIT = 'kit', SHOP = 'shop' }, CallKind = {},
	IMPOUNDED = 2, Event = setmetatable({}, { __index = function(_, key) return key end }) }
local raw = { SHOPS = { workshop = { JOBS = { mechanic = 0 }, STASH = { X = 1, Y = 1, Z = 1 },
	LOT = { X = 1, Y = 1, Z = 1 } } }, IMPOUND = { ENABLED = true } }
local player = { PlayerData = { citizenId = 'worker', userId = 'account', job = { name = 'mechanic' } } }
local opened, callback, removed, repaired = 0, nil, 0, 0
local tasks, sent = {}, {}
local snapshot = { id = 'vehicle', x = 1, y = 1, z = 1, bucket = 0, health = 0.5 }
local character = { GetPlayer = function() return player end }
local inventory = { OpenStash = function() opened = opened + 1; return { ok = true } end,
	GetItemCount = function() return { ok = true, value = 1 } end,
	RemoveItem = function() removed = removed + 1; coroutine.yield(); return { ok = true } end }
local vehicles = { SetState = function() return { ok = true } end,
	List = function() coroutine.yield(); return { ok = true, value = { { state = 2, plate = 'TEST', record = 'Car' } } } end }
local progress = { Start = function(_, _, _, fn) callback = fn; return { ok = true, value = { id = 1 } } end }
local OPX = { Modules = { Get = function() return M end }, Config = { MODULES = { mechanic = raw }, SHARED = {} },
	Math = { Finite = tonumber }, Spots = { Coordinate = tonumber, ServerReach = function(value) return value end },
	Result = { Ok = function(value) return { ok = true, value = value } end,
		Err = function(code) return { ok = false, error = code } end },
	Api = { Get = function(name)
		if name == 'character' then return character end
		if name == 'inventory' then return inventory end
		if name == 'vehicles' then return vehicles end
		if name == 'progress' then return progress end
	end }, Now = function() return 0 end, Life = { Down = function() return false end },
	Audit = { Log = function() end }, Publish = function() end, Vehicle = { DisplayName = tostring } }
local env = { OPX = OPX,
	Open77 = { players = { position = function() return { x = 1, y = 1, z = 1 } end },
		vehicles = { all = function() return { snapshot } end, get = function() return snapshot end,
			setHealth = function() repaired = repaired + 1; return true end, repair = function() return true end },
		log = { error = function() end } },
	TriggerClientEvent = function(name, _, value) sent[#sent + 1] = { name, value } end,
	CreateThread = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end,
	locale = function(key) return key end }
load('lib/shared/jobgate.lua', env)
load('modules/mechanic/shared/model.lua', env)
load('modules/mechanic/server/dispatch.lua', env)
load('modules/mechanic/server/main.lua', env)
M.Init()
M.Server.OnStash(7, { shop = 'workshop' })
assert(opened == 1, 'valid mechanic could not open its parts room')
raw.SHOPS.workshop.JOBS = nil
M.Init()
M.Server.OnStash(7, { shop = 'workshop' })
assert(opened == 1, 'missing job config opened the parts room to everybody')
M.Server.OnImpound(7, {})
assert(sent[#sent][2].code == 'not_authorised', 'missing impound jobs allowed towing')
raw.SHOPS.workshop.JOBS = { mechanic = true }
M.Init()
M.Server.OnStash(7, { shop = 'workshop' })
assert(opened == 1, 'invalid minimum grade became grade zero')
raw.SHOPS.workshop.JOBS = { mechanic = 0 }
M.Init()
local before = #sent
local task = coroutine.create(function() M.Server.OnLot(7, { shop = 'workshop' }) end)
assert(coroutine.resume(task))
player = { PlayerData = { citizenId = 'replacement', userId = 'other', job = { name = 'mechanic' } } }
assert(coroutine.resume(task))
assert(#sent == before, 'impound listing reached a replacement character')
M.Server.OnRepair(7, { mode = 'kit' })
assert(callback, 'kit repair did not start')
callback(7, { completed = true })
local commit = tasks[#tasks]
assert(coroutine.resume(commit))
assert(removed == 1 and coroutine.status(commit) == 'suspended')
M.Server.OnRepair(7, { mode = 'kit' })
assert(sent[#sent][2].code == 'busy', 'worker reservation was released while the commit yielded')
assert(coroutine.resume(commit))
assert(repaired == 1, 'normal kit repair did not complete')
M.Server.OnRepair(7, { mode = 'kit' })
callback(7, { completed = true })
commit = tasks[#tasks]
assert(coroutine.resume(commit))
local originalCitizen = player.PlayerData.citizenId
local refundedTo
inventory.AddItem = function(target) refundedTo = target; return { ok = true } end
player = { PlayerData = { citizenId = 'third-character', job = { name = 'unemployed' } } }
assert(coroutine.resume(commit))
assert(repaired == 1, 'kit repaired a vehicle after its worker changed character during removal')
assert(refundedTo == originalCitizen, 'cancelled kit was refunded to the replacement character')
-- The diagnostic is a canonical read gated by duty, reach and bucket.
player = { PlayerData = { citizenId = 'worker', job = { name = 'mechanic', onDuty = true } } }
M.Init()
snapshot.id, snapshot.health = 101, 0.6
snapshot.doors, snapshot.windows = 3, 1
snapshot.ownerName, snapshot.citizenId = 'private owner', 'private-citizen'
local readId
env.Open77.vehicles.get = function(id) readId = id; return snapshot end
env.Open77.vehicles.getDamage = function() return { tires = 5, glass = 3, lights = 1, detachedParts = 4 } end
M.Server.OnDiagnose(7, { vehicleId = '101', health = 1, fee = 0 })
local report = sent[#sent][2]
assert(sent[#sent][1] == 'DIAGNOSTIC_VIEW' and readId == 101, 'diagnostic did not read the canonical vehicle')
assert(report.health == 60 and report.missing == 40 and report.tires == 2 and report.glass == 2
 and report.lights == 1 and report.detached == 1 and report.doors == 2 and report.windows == 1,
 'diagnostic did not report the actual damage channels')
local quote = M.Model.Quote(M.Model.Settings(raw), 40)
assert(report.quote.fee == quote.fee and report.quote.parts == quote.parts, 'diagnostic estimate diverged from repairs')
assert(report.ownerName == nil and report.citizenId == nil and report.vehicleId == nil,
 'diagnostic leaked vehicle ownership')
player.PlayerData.job.onDuty = false
M.Server.OnDiagnose(7, { vehicleId = '101' })
assert(sent[#sent][2].code == 'not_mechanic', 'off-duty mechanic could run a diagnostic')
player.PlayerData.job.onDuty = true
snapshot.bucket = 9
M.Server.OnDiagnose(7, { vehicleId = '101' })
assert(sent[#sent][2].code == 'vehicle_far', 'diagnostic crossed routing buckets')
snapshot.bucket, snapshot.x = 0, 1000
M.Server.OnDiagnose(7, { vehicleId = '101' })
assert(sent[#sent][2].code == 'vehicle_far', 'diagnostic accepted a remote vehicle')
snapshot.x, snapshot.health = 1, 1
env.Open77.vehicles.getDamage = function() return { detachedParts = 1 } end
M.Server.OnDiagnose(7, { vehicleId = '101' })
assert(sent[#sent][2].missing == 5 and sent[#sent][2].quote.parts > 0,
 'a detached panel did not require repair')
env.Open77.vehicles.getDamage = function() return { tires = 0, glass = 0, lights = 0, detachedParts = 0 } end
M.Server.OnDiagnose(7, { vehicleId = '101' })
assert(sent[#sent][2].quote.fee == 0 and sent[#sent][2].quote.parts == 0,
 'a pristine vehicle received a billable diagnostic estimate')
-- Hood actions must be explicit, local, on duty, in a bay and on an empty car.
raw.SHOPS.workshop.BAYS = { { X = 1, Y = 1, Z = 1, RADIUS = 6 } }
M.Init()
local hoodWrites = {}
env.Open77.vehicles.setDoorOpen = function(id, door, opened)
	hoodWrites[#hoodWrites + 1] = { id, door, opened }
	return true
end
M.Server.OnHood(7, { vehicleId = '101', opened = true, door = 4 })
assert(#hoodWrites == 1 and hoodWrites[1][1] == 101 and hoodWrites[1][2] == 5
	and hoodWrites[1][3] == true, 'hood action trusted a client-selected door')
M.Server.OnHood(7, { vehicleId = '101', opened = false })
assert(#hoodWrites == 2 and hoodWrites[2][3] == false)
M.Server.OnHood(7, { vehicleId = '101', opened = 'true' })
assert(#hoodWrites == 2, 'hood action accepted an ambiguous state')
player.PlayerData.job.onDuty = false
M.Server.OnHood(7, { vehicleId = '101', opened = true })
assert(#hoodWrites == 2 and sent[#sent][2].code == 'off_duty')
player.PlayerData.job.onDuty = true
raw.MEMBERSHIP = 'any'
player.PlayerData.job.name, player.PlayerData.jobs = 'ncpd', { mechanic = 0, ncpd = 0 }
M.Init()
M.Server.OnHood(7, { vehicleId = '101', opened = true })
assert(#hoodWrites == 2 and sent[#sent][2].code == 'off_duty',
	'duty in another primary job granted workshop hood access through a secondary membership')
raw.MEMBERSHIP, player.PlayerData.job.name, player.PlayerData.jobs = nil, 'mechanic', nil
M.Init()
snapshot.occupants = { 8 }
M.Server.OnHood(7, { vehicleId = '101', opened = true })
assert(#hoodWrites == 2 and sent[#sent][2].code == 'occupied')
snapshot.occupants, snapshot.bucket = {}, 9
M.Server.OnHood(7, { vehicleId = '101', opened = true })
assert(#hoodWrites == 2 and sent[#sent][2].code == 'vehicle_far')
snapshot.bucket = 0
raw.SHOPS.workshop.BAYS = {}
M.Init()
M.Server.OnHood(7, { vehicleId = '101', opened = true })
assert(#hoodWrites == 2 and sent[#sent][2].code == 'not_in_bay')
raw.SHOPS.workshop.BAYS = { { X = 1, Y = 1, Z = 1, RADIUS = 6 } }
M.Init()
env.Open77.vehicles.setDoorOpen = function() return false, 'not_owner' end
M.Server.OnHood(7, { vehicleId = '101', opened = true })
assert(sent[#sent][2].code == 'not_ours', 'native refusal was reported as a successful hood action')
-- The network entry point applies the shared per-player floor before queuing work.
local network = {}
env.RegisterNetEvent = function(event, handler) network[event] = handler end
env.AddEventHandler = function() end
env.source = 7
env.Open77.log.warn, env.Open77.log.info = function() end, function() end
OPX.Command = { Register = function() end }
OPX.Scheduler = { Every = function() end }
OPX.Host = { PLAYER_DISCONNECTED = 'disconnect' }
M.Start()
network.DIAGNOSE({ vehicleId = '101' })
assert(coroutine.resume(tasks[#tasks]))
assert(sent[#sent][1] == 'DIAGNOSTIC_VIEW', 'diagnostic network entry did not open the report')
network.DIAGNOSE({ vehicleId = '101' })
assert(sent[#sent][2].code == 'rate_limited', 'diagnostic requests were not rate limited')
print('mechanic audit regressions passed')
