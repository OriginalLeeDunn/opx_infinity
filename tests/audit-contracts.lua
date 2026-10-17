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
	Audit = { Safe = tostring }, JobGate = { Evaluate = function() return true end },
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
