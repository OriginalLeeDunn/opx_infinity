--- Connected machines, keyed by the account the host vouches for.
-- @author dop42
--
-- A session is a connected machine; a character is something a module loads onto
-- one. They are not the same thing and confusing them is how a framework either
-- refuses a legitimate connection or trusts a character that was never loaded:
-- someone sitting in a selection screen has a session and no character.
--
-- `playerId` is recycled and `userId` is durable, so the id is only ever a lookup
-- key and every read re-checks the account behind the slot. A departure nobody
-- reported then becomes a non-event instead of a hole.
--
-- Core owns sessions. It does NOT own the character roster -- that belongs to
-- whichever module provides the `character` contract, and core must not know its
-- name. `ForgetSession` announces on the internal channel and lets that module
-- do its own unloading.

OPX.Sessions = {}

local FORGOTTEN = OPX.Event(OPX.Channel.INTERNAL, 'session', 'forgotten')

-- Kept once found. During boot the global may not be installed yet, and a nil
-- cached now would answer "nobody" for every call afterwards.
local identifierOf

--- The durable account id the host vouches for, or nil before it can be read.
-- @author dop42
-- @param playerId Source
-- @return UserId|nil
function OPX.UserIdOf(playerId)
	if identifierOf then return identifierOf(playerId) end
	local fn = GetPlayerIdentifier
	if not fn then return nil end
	identifierOf = fn
	return fn(playerId)
end

--- The player's chosen display name, which the Master has verified.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function OPX.DisplayNameOf(playerId)
	local fn = GetPlayerName
	return fn and fn(playerId) or nil
end

--- The session on a slot, creating it or evicting a stale one. The only way a
--- session is ever made: without a verified identity nothing can be attributed
--- to it, so the session is forgotten and the answer is nil.
-- @author dop42
-- @param playerId Source|string host events carry strings
-- @return table|nil
function OPX.EnsureSession(playerId)
	playerId = tonumber(playerId)
	if not playerId or playerId <= 0 then return nil end

	local userId = OPX.UserIdOf(playerId)
	if userId == nil or userId == '' then
		OPX.ForgetSession(playerId)
		return nil
	end

	local session = OPX.Sessions[playerId]
	if session then
		if session.userId == userId then return session end
		Open77.log.warn(('[session] slot %d now belongs to a different account, evicting')
			:format(playerId))
		OPX.ForgetSession(playerId)
	end

	session = {
		source = playerId,
		userId = userId,
		displayName = OPX.DisplayNameOf(playerId) or '',
		connectedAt = OPX.Now(),
		gateSession = nil,
	}
	OPX.Sessions[playerId] = session
	return session
end

--- Drops a session. This disconnects, it does not discard: the session is marked
--- `departing` first, for whoever still holds a reference to it.
---
--- THE ANNOUNCEMENT IS NOT READ WHILE THE SESSION STILL EXISTS, whatever this
--- docstring used to say. The server `TriggerEvent` is QUEUED -- the devkit card
--- (op77.45 on): "publishing appends to the host's queue, the host drains it at
--- the next tick boundary" -- so every handler runs a tick later, after the line
--- below has removed the session, and on the eviction path after `EnsureSession`
--- has already put the NEXT account's session on the same slot. A handler that
--- reads `OPX.Sessions[playerId]` is therefore reading somebody else's, or
--- nobody's. The account the departed session belonged to travels with the
--- event instead, so a handler can tell which of the two it is looking at.
-- @author dop42
-- @param playerId Source
function OPX.ForgetSession(playerId)
	playerId = tonumber(playerId)
	if not playerId then return end

	local session = OPX.Sessions[playerId]
	if session then session.departing = true end

	TriggerEvent(FORGOTTEN, playerId, session and session.userId or nil)

	OPX.Sessions[playerId] = nil
end

--- Whether the account behind a slot is still the one the session was made for.
--- A false answer means the id was recycled, and anything keyed on it is stale.
-- @author dop42
-- @param playerId Source
-- @return boolean
function OPX.SessionHolds(playerId)
	local session = OPX.Sessions[playerId]
	if not session then return false end
	return session.userId == OPX.UserIdOf(playerId)
end

-- A FLOOR UNDER THE SESSION TABLE, and it had none. `OPX.ForgetSession` exists
-- here and every call to it on the departure path lives in the module that owns
-- characters: disable that module, have it fail in `Init`, or have it dropped
-- for a missing dependency, and nothing removes a session ever again. A slot
-- that is never reused keeps a departed player's session readable and
-- attributable, `core/server/buckets.lua` walks dead slots at stop, and
-- `OPX.Buckets.Isolate` goes on believing a recycled slot has a session.
--
-- DEFERRED BY A FRAME, deliberately. The character module documents an order --
-- `Logout` samples the position while the session is still there, and only then
-- is it forgotten -- and a handler registered here at load runs BEFORE every
-- module's. So this does not race it: it runs after the frame and clears up
-- only what nobody claimed, which is the definition of a floor.
AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(rawPlayerId)
	local playerId = tonumber(rawPlayerId)
	if not playerId then return end

	local function sweep()
		if OPX.Sessions[playerId] == nil then return end
		Open77.log.warn(('[session] slot %d left a session behind; no module claimed the ' ..
			'departure'):format(playerId))
		OPX.ForgetSession(playerId)
	end

	if type(CreateThread) == 'function' then
		CreateThread(function()
			Wait(0)
			sweep()
		end)
	else
		sweep()
	end
end)
