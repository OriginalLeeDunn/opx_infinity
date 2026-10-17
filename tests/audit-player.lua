--- Regression checks for character updates crossing an asynchronous logout.
-- @author dop42
--
-- Run with `lua tests/audit-player.lua`; the real Player implementation is
-- exercised with a small host to keep identity and roster changes explicit.

local sent, account = {}, 'old-account'
local M = { Settings = { PLAYER = { STARTING_METADATA = {}, DEFAULT_JOB = 'none', DEFAULT_GANG = 'none' } },
	Event = { DATA = 'data' }, State = { Publish = function() end },
	Groups = { ResolveJob = function() return { ok = true, value = {} } end,
		ResolveGang = function() return { ok = true, value = {} } end } }
local OPX = { Modules = { Get = function() return M end }, Result = {},
	Config = { SHARED = { MONEY = { TYPES = { EDDIES = true } } } },
	UserIdOf = function() return account end }
local env = setmetatable({ OPX = OPX,
	TriggerClientEvent = function(...) sent[#sent + 1] = { ... } end }, { __index = _G })
assert(loadfile('modules/character/server/player.lua', 't', env))()
local player = M.CreatePlayer({ source = 7, userId = account, citizenId = 'original', money = {} })
M.Players[7] = player
player.Functions.UpdatePlayerData()
assert(#sent == 1, 'current owner must receive character updates')
account = 'new-account'
player.Functions.UpdatePlayerData()
assert(#sent == 1, 'old PlayerData leaked to a replacement account')
account = 'old-account'
M.Players[7] = M.CreatePlayer({ source = 7, userId = account, citizenId = 'replacement', money = {} })
player.Functions.UpdatePlayerData()
assert(#sent == 1, 'old PlayerData overwrote a different character of the same account')
assert(player.Revision == 3, 'stale changes must retain their revision for persistence')
M.Players[7] = nil
player.Functions.UpdatePlayerData()
assert(#sent == 1, 'departed PlayerData was sent after logout')
print('player audit regression checks passed')

-- A placement polls life state before its kill/respawn. Recycle the slot while
-- that poll is suspended and prove the replacement is never killed or moved.
local killed, moved = 0, 0
M.Players[7] = player
account = player.PlayerData.userId
OPX.Sessions = { [7] = { userId = account } }
OPX.UserIdOf = function() return account end
OPX.Buckets = { PlacementOf = function() return 0 end, Move = function() moved = moved + 1 end }
env.Wait = coroutine.yield
env.Open77 = { players = {
	getLifeState = function() return { phase = account == 'old-account' and 'loading' or 'alive' } end,
	kill = function() killed = killed + 1; return true end,
} }
assert(loadfile('modules/character/server/character.lua', 't', env))()
local placement = coroutine.create(function()
	local ok, why = M.PlaceCharacter(player, { x = 0, y = 0, z = 0 })
	assert(not ok and why == 'entry.noIdentity')
end)
assert(coroutine.resume(placement))
account = 'new-account'
M.Players[7] = nil
assert(coroutine.resume(placement))
assert(killed == 0 and moved == 0, 'placement acted on the replacement connection')
print('placement audit regression checks passed')

M.Players[7] = player
account = 'old-account'
assert(M.ResolvePlayer(7) == player)
account = 'new-account'
assert(M.ResolvePlayer(7) == nil, 'source resolution authorized a stale character')
assert(M.GetPlayer(7) == player, 'logout must retain access to the departing roster entry')
print('player source resolution regression checks passed')

local forgotten = 0
OPX.ForgetSession = function() forgotten = forgotten + 1 end
local replacementSession = { userId = account }
OPX.Sessions[7] = replacementSession
assert(#M.GetPlayers() == 0, 'stale characters must be excluded from public lists')
assert(forgotten == 0 and OPX.Sessions[7] == replacementSession,
	'a stale roster entry evicted the replacement account session')
OPX.Sessions[7] = { userId = player.PlayerData.userId }
assert(#M.GetPlayers() == 0 and forgotten == 1, 'the original stale session must still be evicted')
print('player list session ownership regression checks passed')
