--- Concurrent accepts of distinct gigs share the merc's configured cap.
-- @author dop42

local function load(path, env)
	assert(loadfile(path, 't', setmetatable(env, { __index = _G })))()
end
local State = { LOCKING = 'locking', POSTED = 'posted', ACCEPTED = 'accepted', IN_PROGRESS = 'in_progress',
	PROOF = 'proof', SETTLING = 'settling', PAID = 'paid', FAILED = 'failed', EXPIRED = 'expired',
	CANCELLED = 'cancelled', DISPUTED = 'disputed' }
local M = { State = State, Phase = {}, Funded = {}, Poster = { PLAYER = 'player', NPC = 'npc' },
	Event = setmetatable({}, { __index = function(_, key) return key end }) }
local character = { GetPlayer = function() return { PlayerData = { citizenId = 'merc' } } end,
	GetMetadata = function() return {} end }
-- Character contract returns the real roster object, not a fresh table per read.
local roster = character.GetPlayer()
character.GetPlayer = function() return roster end
local OPX = { Modules = { Get = function() return M end },
	Api = { Get = function(name) if name == 'character' then return character end end },
	Now = function() return 0 end, Config = { SHARED = {} },
	Audit = { Safe = tostring }, JobGate = { Evaluate = function() return true end, EvaluateGroups = function() return true end, GangProblems = function() return {} end },
	NotifyLocale = function() end, Publish = function() end }
M.Access = { TAKERS = {}, POSTERS = {}, CRED_KEY = 'cred', CURRENCY = 'EDDIES',
	MAX_ACTIVE_PER_MERC = 1, ACCEPT_TTL_S = 600,
	CredRecord = function() return { cred = 0 } end, Allowed = function() return true end,
	IsOpen = function() return true end, Split = function(amount) return amount, 0 end,
	IsWorking = function(state) return state == 'accepted' or state == 'in_progress' or state == 'proof' end }
M.Storage = { Move = function() coroutine.yield(); return { ok = true, value = true } end,
	History = function() return { ok = true } end }
local env = { OPX = OPX, Open77 = { log = { info = function() end } },
	TriggerClientEvent = function() end }
load('modules/contracts/server/main.lua', env)
local contracts = M.Server.Contracts()
for id = 1, 2 do
	contracts[id] = { id = id, type = 'manual', state = 'posted', rev = 0, deadlineAt = 1000,
		minCred = 0, objective = {}, reward = 100, cutPct = 0, title = 'Test' }
end
local accepted
local first = coroutine.create(function() accepted = M.Server.Accept(7, 1) end)
assert(coroutine.resume(first))
local second, reason = M.Server.Accept(7, 2)
assert(not second and reason == 'already_working', 'concurrent different-gig accepts bypassed the merc cap')
while coroutine.status(first) ~= 'dead' do assert(coroutine.resume(first)) end
assert(accepted and contracts[1].state == 'in_progress' and contracts[2].state == 'posted')
OPX.Math = { Finite = tonumber }
OPX.Spots = { Coordinate = tonumber, Integer = math.tointeger }
load('modules/contracts/shared/access.lua', env)
local gig = { id = 3, type = 'manual', objective = {}, reward = 100, cutPct = 0,
	posterKind = 'player', posterCid = 'fixer-id', posterName = 'Private RP Name' }
assert(M.Access.Public(gig).poster == 'fixer-id', 'the public gig exposed its player poster RP name')
gig.posterKind = 'npc'
assert(M.Access.Public(gig).poster == 'Private RP Name', 'an operator-defined NPC name was hidden')
print('contracts audit regressions passed')

-- The board can admit a faction without giving off-duty jobs a gang's clock.
load('lib/shared/jobgate.lua', env)
local source = assert(io.open('modules/contracts/server/main.lua'))
local code = source:read('a'); source:close()
local probe = assert(_G.load(code .. '\nreturn { passes = passes, grade = gradeIn }',
	'@contracts-groups-probe', 't', setmetatable(env, { __index = _G })))()
local block = { JOBS = { fixer = 1 }, GANGS = { valentinos = 2 }, ON_DUTY = true }
local data = { job = { name = 'fixer', grade = { level = 1 }, onDuty = false },
	gang = { name = 'valentinos', grade = { level = 2 } } }
assert(probe.passes(data, block), 'a gang member needed a job duty clock')
assert(probe.grade(data, block) == 2, 'gang posting/validation used an unrelated job grade')
data.gang.grade.level = 1
local ok, why = probe.passes(data, { GANGS = { valentinos = 2 } })
assert(not ok and why == 'gang_grade_too_low')
data.gang.name = 'none'
ok, why = probe.passes(data, { GANGS = { valentinos = 2 } })
assert(not ok and why == 'gang_required')
data.job.onDuty = true
assert(probe.passes(data, block), 'an existing authorised fixer was refused')
data.gangs = { valentinos = 3 }
M.Access.MEMBERSHIP = 'primary'
assert(not probe.passes(data, { GANGS = { valentinos = 2 } }))
M.Access.MEMBERSHIP = 'any'
assert(probe.passes(data, { GANGS = { valentinos = 2 } }))
assert(probe.grade(data, { GANGS = { valentinos = 2 } }) == 3)
assert(not probe.passes(data, { GANGS = 'valentinos' }), 'a malformed gang gate became public')
print('contracts faction gates passed')

-- Freelance access belongs only to explicitly public objective handlers.
OPX.Result = { Ok = function(value) return { ok = true, value = value } end,
	Err = function(error) return { ok = false, error = error } end }
OPX.Tune = { Number = function() return 100 end }
OPX.Audit.Log = function() end
OPX.Locale = { Money = tostring }
OPX.NotifyLocale = function() end
OPX.Publish = function() end
env.Open77.log.error = function() end
env.Open77.log.warn = function() end
M.Poster.EXT, M.Poster.NPC = 'ext', 'npc'
M.Funded.MINT, M.Funded.EXTERNAL = 'mint', 'external'
local A = M.Access
A.TAKERS = { JOBS = { merc = 0 } }
A.POSTERS = { JOBS = { fixer = 0 } }
A.TIERS = { { min = 0, label = 'Nobody' } }
A.BOARD_LIMIT, A.MAX_ACTIVE_PER_MERC, A.ACCEPT_TTL_S = 20, 1, 600
A.Tier = function() return 1, 'Nobody' end
A.CredRecord = function() return { cred = 0, done = 0, failed = 0 } end
A.NormalizeSpec = function(value) return value end
A.Text = function(value) return value end
A.Allowed = function() return true end
A.Keys = function() return {} end
A.Split = function(amount) return amount, 0 end
local test = assert(_G.load(code .. [[
loaded = true
return { register = apiRegister, unregister = apiUnregister, post = apiPost,
 accept = accept, board = boardFor, mint = createMint, generate = generate,
 contracts = contracts, types = types }
]], '@contracts-freelance-probe', 't', setmetatable(env, { __index = _G })))()
roster.PlayerData = { citizenId = 'freelancer', source = 7,
	job = { name = 'unemployed', grade = { level = 0 } } }
local allowStart = true
assert(test.register('citywork', { public = true, canStart = function() return allowStart, 'cannot_start' end }).ok)
assert(test.register('privatework', {}).ok)
local function gig(id, kind, reward)
	return { id = id, type = kind, state = 'posted', rev = 0, deadlineAt = 1000,
		minCred = 0, objective = {}, reward = reward or 60, cutPct = 0, title = 'Work' }
end
M.Storage.Move = function() return { ok = true, value = true } end
test.contracts[10], test.contracts[11] = gig(10, 'citywork'), gig(11, 'privatework')
local board = test.board(7)
assert(board.isTaker and #board.rows == 1 and board.rows[1].id == 10,
	'freelance access leaked into private gigs or hid the public board')
local accepted, reason = test.accept(7, 11)
assert(not accepted and reason == 'job_required')
allowStart = false
assert(#test.board(7).rows == 0, 'public gigs bypassed their type canStart on the board')
accepted, reason = test.accept(7, 10)
assert(not accepted and reason == 'cannot_start', 'public accept bypassed canStart')
allowStart = true
assert(test.accept(7, 10), 'a loaded freelancer could not accept public work')
assert(test.unregister('citywork').error == 'type_in_use')
test.contracts[10], test.contracts[11] = nil, nil
assert(test.unregister('citywork').ok)

-- API mint and fixer generation share a guard held before the ledger await.
local inserted, minted, failRead = 0, 0, false
M.Storage.MintedLastHour = function()
	coroutine.yield('ledger')
	return { ok = not failRead, value = minted }
end
M.Storage.Insert = function() inserted = inserted + 1; return { ok = true, value = 100 + inserted } end
local spec = { type = 'privatework', title = 'Maintenance', objective = {}, reward = 60,
	cutPct = 0, minCred = 0, deadlineS = 600, funded = 'mint' }
local posted
local co = coroutine.create(function() posted = test.post(spec) end)
assert(coroutine.resume(co))
assert(test.post(spec).error == 'mint_busy', 'two mint callers read the same unreserved budget')
assert(coroutine.resume(co))
assert(posted.ok and inserted == 1 and test.contracts[101].funded == 'mint')
local refused
co = coroutine.create(function() refused = test.post(spec) end)
assert(coroutine.resume(co)); assert(coroutine.resume(co))
assert(refused.error == 'mint_cap' and inserted == 1, 'open mint commitments were omitted')
-- A payout removes its commitment while SQL is awaited: the earlier snapshot
-- still counts it, even if the ledger read began before that payout committed.
co = coroutine.create(function() refused = test.post(spec) end)
assert(coroutine.resume(co)); test.contracts[101] = nil
assert(coroutine.resume(co))
assert(refused.error == 'mint_cap', 'settlement during the cap read freed the same budget twice')
minted = 80
co = coroutine.create(function() refused = test.post(spec) end)
assert(coroutine.resume(co)); assert(coroutine.resume(co))
assert(refused.error == 'mint_cap', 'persisted hourly mint payments were omitted')
failRead = true
co = coroutine.create(function() refused = test.post(spec) end)
assert(coroutine.resume(co)); assert(coroutine.resume(co))
assert(refused.error == 'storage', 'a failed mint ledger read allowed money creation')
failRead, minted = false, 0
co = coroutine.create(function() posted = test.post(spec) end)
assert(coroutine.resume(co)); assert(coroutine.resume(co))
assert(posted.ok, 'a failed budget read left the global reservation stuck')
print('contracts freelance access and shared mint budget passed')

-- Generation cannot bypass an API post that is waiting on its SQL budget read.
for id in pairs(test.contracts) do test.contracts[id] = nil end
A.Keys = function() return { 'regina' } end
A.Fixer = function() return { when = 'always', name = 'Regina', maxOpen = 5, everyS = 1,
	cutPct = 0, deadlineS = 600, templates = { { TYPE = 'deliver_item', TARGETS = { 'dock' }, REWARD = {} } } } end
A.Dropoff = function() return {} end
A.TypeEnabled = function() return true end
A.Pick = function() return 1 end
A.RewardIn = function() return 60 end
co = coroutine.create(function() posted = test.post(spec) end)
assert(coroutine.resume(co))
assert(test.unregister('privatework').error == 'type_in_use', 'a posting type vanished during its await')
local beforeGeneration = inserted
local generator = coroutine.create(test.generate)
assert(coroutine.resume(generator))
assert(coroutine.status(generator) == 'dead' and inserted == beforeGeneration,
	'fixer generation bypassed the shared API reservation')
assert(coroutine.resume(co)); assert(posted.ok)
for id in pairs(test.contracts) do test.contracts[id] = nil end
-- Reset the fake clock between fixer passes; generate owns its reservation too.
OPX.Now = function() return 5000 end
generator = coroutine.create(test.generate)
assert(coroutine.resume(generator))
assert(coroutine.status(generator) == 'suspended')
assert(test.post(spec).error == 'mint_busy', 'API posting bypassed the fixer reservation')
assert(coroutine.resume(generator))
assert(inserted == beforeGeneration + 2)

-- Incoming calls use the same type gate as board visibility, including canStart.
local notifications = 0
character.GetPlayers = function() return { roster } end
OPX.NotifyLocale = function(_, key) if key == 'contracts.incoming' then notifications = notifications + 1 end end
assert(test.register('publicnotice', { public = true, canStart = function() return allowStart end }).ok)
local notice = { type = 'publicnotice', title = 'Courier', objective = {}, reward = 1,
	cutPct = 0, minCred = 0, deadlineS = 600 }
allowStart = false
assert(test.post(notice).ok and notifications == 0)
allowStart = true
assert(test.post(notice).ok and notifications == 1)
notice.type = 'privatework'
assert(test.post(notice).ok and notifications == 1, 'private work notified an unauthorised freelancer')
print('contracts generator/API concurrency and notification gates passed')
local published
OPX.Api.Provide = function(name, _, api) if name == 'contracts' then published = api end end
M.Api()
assert(type(published.Accept) == 'function' and type(published.UnregisterObjectiveType) == 'function')
local privateId
for id, record in pairs(test.contracts) do if record.type == 'privatework' then privateId = id end end
assert(published.Accept(7, privateId).error == 'job_required', 'API Accept bypassed the existing taker gate')
print('contracts extension API passed')
