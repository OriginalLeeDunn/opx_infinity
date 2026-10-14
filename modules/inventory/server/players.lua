--- Who each player is, and the life of their bag.
-- @author dop42
--
-- A bag is loaded when a character enters the world, and written and forgotten
-- when it leaves. A client's word is never taken for a citizen id: the answer
-- comes from the `character` contract, which is the only thing that knows which
-- character a connection has loaded.
--
-- WHAT THIS RUNTIME DELETED. Who was loaded used to be read from another
-- resource's change cursor: one reader at a time, a generation token, a jump to
-- the head on the first read or when the other resource came back, a re-ask of
-- every known player, and one in-flight identity question per connection with a
-- 35-second wait behind it. In one Lua state a character loading is an event on
-- the internal channel and reading who is loaded is a function call.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Containers = M.Containers
local KIND = M.KIND

M.Players = {}
local Players = M.Players

-- The character this module has a bag open for, per connection, and the reverse.
local bySource = {}
local byCitizen = {}

--- The `character` contract, or nil.
-- Resolved in `Start` into `M.Contracts` and read through a function rather than
-- captured: `Init` runs before any contract is published, and a local taken then
-- would be nil for the life of the resource.
local function characterApi()
	return M.Contracts.character
end

--- The citizen id loaded on a connection, or nil.
-- @author dop42
-- @param source Source
-- @return CitizenId|nil
function Players.Citizen(source)
	local entry = bySource[source]
	return entry and entry.citizenId or nil
end

--- The connection a citizen id is loaded on, or nil.
-- @author dop42
-- @param citizenId CitizenId
-- @return Source|nil
function Players.SourceOf(citizenId)
	return byCitizen[citizenId]
end

--- A snapshot of every connection this module holds a character for.
-- @author dop42
-- @return table[]
function Players.List()
	local out = {}
	for source, entry in pairs(bySource) do
		out[#out + 1] = { source = source, citizenId = entry.citizenId }
	end
	return out
end

--- Whether nothing holds the player at the readiness gate.
-- @author dop42
-- @param source Source
-- @return boolean
function Players.GateOpen(source)
	return OPX.Gate.IsReady(source)
end

--- Whether the player is in a body and not dead.
-- Somebody behind a continue screen has no life state at all, so they are not
-- alive. With no life reader every player counts as alive: refusing everybody
-- because a host call is missing is worse than the thing the check prevents.
-- @author dop42
-- @param source Source
-- @return boolean
function Players.Alive(source)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.getLifeState) ~= 'function' then return true end
	local read, life = pcall(players.getLifeState, source)
	if not read or type(life) ~= 'table' then return false end
	if type(players.isDead) == 'function' then
		local deadRead, dead = pcall(players.isDead, source)
		if deadRead and dead == true then return false end
	end
	return true
end

--- Whether the player may act on a container at all, and the refusal if not.
---
--- ONE DOOR, BECAUSE THERE WERE SEVEN. `GateOpen` and `Alive` were written out
--- as two separate lines at every handler, and four of them carried only the
--- first: `drop`, `takeDrop`, `openStash` and `openTrunk`/`openGlovebox`. A
--- player on the floor could therefore empty their bag into a pile or into a
--- boot -- the down screen is drawn by the CLIENT, so closing it proves nothing
--- about what the connection can still send. Dumping contraband before a staff
--- search is the obvious use.
---
--- Anything a player drives has to come through here, so that a handler added
--- later cannot half-remember the pair.
-- @author dop42
-- @param source Source
-- @return boolean
-- @return string|nil the refusal code, when it is false
function Players.MayAct(source)
	if not Players.GateOpen(source) then return false, 'not_ready' end
	if not Players.Alive(source) then return false, 'dead' end
	return true
end

--- Lets go of what a connection holds that is not its bag: the weapon in hand,
--- the use and drop windows, and the second container it has open.
---
--- APART FROM `Release` BECAUSE A CONNECTION CAN HOLD THESE WITH NO CHARACTER
--- BOUND TO IT: a character re-bound to a newer connection leaves the older one
--- unbound, and a staff search is a view opened by whoever asked. `Release`
--- stops at "nobody is bound here", so a departure skipped all of it -- and the
--- next player given that id inherited a STAFF view, which reach does not
--- check, onto somebody else's container.
-- @param source Source
-- @param connected boolean whether the connection is still there to be told
local function forgetConnection(source, connected)
	M.Weapons.Forget(source, connected)
	M.Actions.Forget(source)
	Containers.CloseSecondary(source, false)
end

--- Records a citizen id on a connection, dropping a stale binding of the same
--- character somewhere else.
local function bind(source, citizenId)
	local previous = byCitizen[citizenId]
	if previous and previous ~= source and bySource[previous] ~= nil then
		bySource[previous] = nil
		forgetConnection(previous, false)
	end
	bySource[source] = { citizenId = citizenId }
	byCitizen[citizenId] = source
end

--- The player's bag, loading it when it is not held yet.
-- Yields. The character may have left while the bag was loading, which is why the
-- citizen id is read again afterwards: a bag handed back then would belong to
-- somebody who is no longer there.
-- @author dop42
-- @param source Source
-- @return table|nil
-- @return string|nil
function Players.Bag(source)
	local citizenId = Players.Citizen(source)
	if not citizenId then return nil, 'not_loaded' end
	local bag, reason = Containers.Load(KIND.CHARACTER, citizenId,
		Options.BAG_SLOTS, Options.BAG_MAX_WEIGHT)
	if not bag then return nil, reason end
	if Players.Citizen(source) ~= citizenId then return nil, 'not_loaded' end
	-- A player back in the world before their bag was released takes it back
	-- rather than being handed a leftover waiting to be written and dropped.
	bag.unloadWhenClean = nil
	return bag, nil
end

--- Resolves a typed citizen id to a living character, through the contract.
-- @author dop42
-- @param token any
-- @return CitizenId|nil
-- @return string|nil
function Players.Identify(token)
	if type(token) ~= 'string' or #token > 32 then return nil, 'bad_target' end
	local api = characterApi()
	if api == nil then return nil, 'storage' end

	local online = api.GetPlayerByCitizenId(token)
	if online then return online.PlayerData.citizenId, nil end

	local found = api.GetCharacter(token)
	if not found.ok then
		return nil, found.error == 'character.notFound' and 'no_character' or 'storage'
	end
	local answer = found.value
	local citizenId = answer.player and answer.player.PlayerData.citizenId
		or (answer.entity and answer.entity.citizenId)
	if not Common.Word(citizenId, 16) then return nil, 'no_character' end
	return citizenId, nil
end

--- Loads a bag by citizen id, and says whether this call was the one to load it.
-- The second answer is what tells a staff command it borrowed the bag and has to
-- settle it again afterwards.
-- @author dop42
-- @param citizenId CitizenId
-- @return table|nil
-- @return boolean
-- @return string|nil
function Players.LoadBag(citizenId)
	local held = Containers.Find(KIND.CHARACTER, citizenId) ~= nil
	local bag, reason = Containers.Load(KIND.CHARACTER, citizenId,
		Options.BAG_SLOTS, Options.BAG_MAX_WEIGHT)
	return bag, not held, reason
end

--- Writes and forgets an offline character's bag once nobody has it open.
-- @author dop42
-- @param bag table
function Players.Settle(bag)
	if Players.SourceOf(bag.owner) then return end
	for _, view in ipairs(Containers.Viewers()) do
		if view.id == bag.id then return end
	end
	Containers.Unload(bag.id)
end

--- Whether a staff search currently has this container open.
-- @author dop42
-- @param id integer
-- @return boolean
function Players.Searched(id)
	for _, view in ipairs(Containers.Viewers()) do
		if view.id == id and view.staff then return true end
	end
	return false
end

--- Puts away a departed character's weapon, views and bag.
-- Idempotent: a departure reaches this module both as a host disconnect and as
-- the character module's own unload, and the two may arrive in either order.
--
-- `citizenId` names WHICH character is leaving. Between the event and this call a
-- second character may have been adopted on the same connection, and releasing by
-- connection alone would unload that one instead.
-- @author dop42
-- @param source Source
-- @param reason string unloaded, switched, disconnected or deleted
-- @param citizenId CitizenId|nil releases only this character when given
function Players.Release(source, reason, citizenId)
	local entry = bySource[source]
	if not entry then
		if reason == 'disconnected' then forgetConnection(source, false) end
		return
	end
	if citizenId ~= nil and entry.citizenId ~= citizenId then return end
	bySource[source] = nil
	if byCitizen[entry.citizenId] == source then byCitizen[entry.citizenId] = nil end

	local connected = reason ~= 'disconnected'
	forgetConnection(source, connected)
	if connected then TriggerClientEvent(M.Event.RESET, source) end

	local bag = Containers.Find(KIND.CHARACTER, entry.citizenId)
	-- A staff search keeps it open; closing that search writes and forgets it.
	if bag and not Players.Searched(bag.id) then Containers.Unload(bag.id) end
end

--- Reads who is loaded on a connection and loads or releases accordingly.
-- Yields, because loading the bag does. Safe to call again at any time: the
-- client's hello goes through it, and it answers from the contract rather than
-- from anything the client said.
-- @author dop42
-- @param source Source
-- @return table|nil the bag
-- @return string|nil
function Players.Attach(source)
	source = Common.Integer(source, 1, 2147483647)
	if not source then return nil, 'bad_request' end
	local api = characterApi()
	if api == nil then return nil, 'storage' end

	local player = api.GetPlayer(source)
	local citizenId = player and player.PlayerData.citizenId or nil

	local held = Players.Citizen(source)
	if held and held ~= citizenId then Players.Release(source, 'switched') end
	if not citizenId then return nil, 'not_loaded' end

	bind(source, citizenId)
	local bag, reason = Players.Bag(source)
	if bag then Containers.Publish(bag) end
	return bag, reason
end

--- Releases every connection the host no longer knows about.
-- The one case a missed departure leaves behind: a bag held for somebody who is
-- not there holds their row out of the write path for the rest of the session.
-- @author dop42
function Players.PruneVanished()
	local players = Open77.players
	if type(players) ~= 'table' or type(players.all) ~= 'function' then return end
	local read, list = pcall(players.all)
	if not read or type(list) ~= 'table' then return end

	local known = {}
	for index = 1, #list do known[tonumber(list[index]) or 0] = true end

	local gone = {}
	for source in pairs(bySource) do
		if not known[source] then gone[#gone + 1] = source end
	end
	for index = 1, #gone do
		local source = gone[index]
		CreateThread(function() Players.Release(source, 'disconnected') end)
	end
end

--- Wires the doors a character's arrival and departure come through.
-- @author dop42
function Players.Wire()
	-- The character module's cross-module bus. Both handlers run on a thread of
	-- their own: loading and unloading a bag reach the database, and an event
	-- handler is not resumed after it yields.
	AddEventHandler(M.Event.IN_CHARACTER_LOADED, function(source)
		CreateThread(function() Players.Attach(source) end)
	end)

	AddEventHandler(M.Event.IN_CHARACTER_UNLOADED, function(source, data)
		local citizenId = type(data) == 'table' and data.citizenId or nil
		if citizenId == nil or Players.Citizen(source) ~= citizenId then return end
		CreateThread(function() Players.Release(source, 'unloaded', citizenId) end)
	end)

	AddEventHandler(M.Event.IN_CHARACTER_DELETED, function(source, citizenId)
		if citizenId == nil or Players.Citizen(source) ~= citizenId then return end
		CreateThread(function() Players.Release(source, 'deleted', citizenId) end)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local source = tonumber(playerId)
		if not source then return end
		OPX.ForgetCooldowns(source)
		CreateThread(function() Players.Release(source, 'disconnected') end)
	end)
end
