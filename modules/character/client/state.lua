--- The OTHER people: what this client may know about them, and the plate over
--- their heads.
-- @author dop42
--
-- THE OWNER'S DECISION: never a name to a stranger. In roleplay a character's
-- name is learnt by meeting them, so this client is told nothing about anybody
-- but its own character -- the server stopped replicating names, citizen ids,
-- jobs and gangs on the state bag (see `server/state.lua`). The three readers
-- below stay on the contract so a resource that called them keeps running, and
-- they answer what is now true: nothing.
--
--   local who = OPX.Api.Get('character').GetPlayerIdentity(playerId)
--   who.name, who.username, who.citizenId   --> nil, nil, nil
--
-- THE PLATE. The platform draws a plate over every remote body, labelled with
-- the account's gamertag. This file used to replace it with the CHARACTER's name
-- -- which put every name in the city over every head, for anybody who looked.
-- Neither belongs over a stranger's head: the gamertag is out-of-character, the
-- character's name is theirs to give. So every remote plate is hidden. Staff who
-- need to know who is who turn on the staff name tags, behind the ACL.
--
-- HOW. `Open77.nameplates.set(id, { visible = false })` per remote player, for
-- every id on the client's roster (`players.all`, which lists a player before
-- their body streams, so a plate is hidden before it is ever drawn). A pass runs
-- on `OPX.Scheduler` -- never a loop of its own: an overrun of the per-resume
-- budget kills a `while true` loop silently -- and calls the native only for an
-- id it has not hidden yet, at most VEIL_PER_PASS of them, so a full server
-- joining at once costs a few passes and never one long resume.

local M = OPX.Modules.Get('character')

M.PlayerState = {}
local PlayerState = M.PlayerState

-- Answered for anybody, so a caller may always index the result. Shared and
-- never handed out to be written.
local EMPTY = {}

-- Milliseconds between two veil passes.
local VEIL_MS = 1000

-- New plates hidden in one pass, at most. The rest wait for the next one.
local VEIL_PER_PASS = 16

-- Players whose plate this VM has hidden, by id.
local veiled = {}

-- The scheduler handle, so `Stop` can retire it.
local job = nil

-- Logged once each.
local reported = {}

local function warnOnce(key, message)
	if reported[key] then return end
	reported[key] = true
	Open77.log.warn('[character] ' .. message)
end

--- Whether this client's host replicates bags. Kept for callers of the old
--- contract; nothing here reads a bag any more.
-- @author dop42
-- @return boolean
function PlayerState.Available()
	local state = Open77.state
	return type(state) == 'table' and type(state.player) == 'function'
end

--- What this client may know about another player: nothing. An empty table,
--- so a caller written against the old contract can still index it.
-- @author dop42
-- @param playerId Source
-- @return table
function PlayerState.Of(playerId)
	return EMPTY
end

--- The character name of another player: never known here.
-- @author dop42
-- @param playerId Source
-- @return nil
function PlayerState.NameOf(playerId)
	return nil
end

--- The identity of another player: three nils, in a fresh table.
-- @author dop42
-- @param playerId Source
-- @return table
function PlayerState.IdentityOf(playerId)
	return { name = nil, username = nil, citizenId = nil }
end

-- The plate API, or nil on a build without it. Indexed by name before it is
-- called: a client build without the namespace would otherwise raise.
local function plates()
	local api = Open77.nameplates
	if type(api) ~= 'table' or type(api.set) ~= 'function' then return nil end
	return api
end

--- Hides the plate over one remote player. Answers whether it is hidden.
-- @author dop42
-- @param playerId Source
-- @return boolean
function PlayerState.Veil(playerId)
	playerId = tonumber(playerId)
	if playerId == nil or playerId <= 0 then return false end
	local api = plates()
	if api == nil then return false end
	local called, applied, why = pcall(api.set, playerId, { visible = false })
	if not called or applied == false then
		warnOnce('veil', ('the plate over %d could not be hidden: %s')
			:format(playerId, tostring(called and why or applied)))
		return false
	end
	veiled[playerId] = true
	return true
end

-- One pass: hides the plate of every remote player not hidden yet, and hands
-- back the overrides of the ones who left.
local function pass()
	if plates() == nil then return end
	-- Our own id first, and no pass without it: the local body has no plate to
	-- hide, and an override aimed at it is one the platform refuses.
	local own = OPX.Lib.Players.LocalId()
	local self = own.ok and tonumber(own.value) or nil
	if self == nil then return end
	local roster = OPX.Lib.Players.All()
	if not roster.ok or type(roster.value) ~= 'table' then return end

	local present, budget = {}, VEIL_PER_PASS
	for _, value in ipairs(roster.value) do
		local id = tonumber(value)
		if id ~= nil and id > 0 and id ~= self then
			present[id] = true
			if not veiled[id] and budget > 0 then
				budget = budget - 1
				PlayerState.Veil(id)
			end
		end
	end
	-- Somebody who left takes their override with them, so a recycled id is
	-- hidden again on purpose rather than by a leftover.
	local api = plates()
	for id in pairs(veiled) do
		if not present[id] then
			veiled[id] = nil
			if type(api.remove) == 'function' then pcall(api.remove, id) end
		end
	end
end

--- One veil pass, run by the scheduler; on the module so a test can count what
--- a pass costs.
PlayerState.Pass = pass

--- Starts the veil pass.
-- @author dop42
function PlayerState.Start()
	if plates() == nil then
		return warnOnce('noPlates', 'this client has no Open77.nameplates: remote plates '
			.. 'cannot be hidden and will show the account name')
	end
	job = OPX.Scheduler.Every('character:veil', VEIL_MS, function()
		local ran, failure = pcall(pass)
		if not ran then warnOnce('veilRaised', 'the veil pass raised: ' .. tostring(failure)) end
	end)
end

--- Retires the pass and hands every plate back to the platform.
-- The platform cleans overrides up when the RESOURCE stops; a module stopped on
-- its own would otherwise leave them in place with nothing maintaining them.
-- @author dop42
function PlayerState.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	local api = Open77.nameplates
	for playerId in pairs(veiled) do
		if type(api) == 'table' and type(api.remove) == 'function' then
			pcall(api.remove, playerId)
		end
	end
	veiled = {}
end
