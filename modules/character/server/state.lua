--- The replicated character bag: what the city is allowed to know about the
--- person standing in front of it -- which is nothing.
-- @author dop42
--
-- This file used to publish `citizenId`, `name`, `charInfo`, `job`, `gang`,
-- `username` and `life` onto every player's state bag, under the rule "if it
-- would be a leak on a name tag, it does not go in the bag". The rule was right
-- and the list was not: a player bag goes to EVERY client in that player's
-- routing bucket -- which is the whole city -- whatever the distance, whoever
-- they are, and a modified client keeps all of it. Every name, every citizen id,
-- every job and gang and grade, and who was down, was readable by anybody who
-- had never met anybody.
--
-- THE OWNER'S DECISION: never a name to a stranger. In roleplay a character's
-- name is learnt by meeting them; it is not handed to every client on connect.
-- So nothing about a character is replicated any more. A client knows its OWN
-- character, whole, on `M.Event.DATA`; staff learn who is who on the staff
-- name-tag list, behind the ACL (`modules/admin/server/tags.lua`); a contact is
-- named by the holocall module to the people who exchanged it. Nothing else
-- names anybody, and a new reader that wants to has to go through the server and
-- say why.
--
-- WHAT IS LEFT HERE is the cleanup. A resource reloaded over an older build
-- finds bags still carrying the old keys -- the bag outlives the VM that wrote
-- it -- so each retired key is cleared off a player's bag once, the first time
-- this file sees them, and again on unload. That costs one clear per key per
-- player per session and nothing after.

local M = OPX.Modules.Get('character')

M.State = {}
local State = M.State

-- The keys this module used to write, and must never write again. Kept only so
-- that a bag still carrying one from an older build is scrubbed.
local RETIRED = { 'citizenId', 'name', 'charInfo', 'job', 'gang', 'username', 'life' }

--- The keys a player bag carries from this module. Empty, and a test holds it
--- there: anything added to it reaches every client in the bucket.
State.KEYS = {}

-- Player ids whose bag has been scrubbed this session.
local scrubbed = {}

-- Refusals already logged, one line each.
local reported = {}

local function warnOnce(key, message)
	if reported[key] then return end
	reported[key] = true
	Open77.log.warn('[character] ' .. message)
end

--- Whether this host replicates bags at all.
-- `Open77.state` also carries `save`/`load`/`clear`, which are resource-private
-- storage and have nothing to do with bags, so the feature test names the
-- accessor and not the table.
-- @author dop42
-- @return boolean
function State.Available()
	local state = Open77.state
	return type(state) == 'table' and type(state.player) == 'function'
end

-- Takes every retired key off one bag. `unknown_bag` and a key that was never
-- there are the ordinary answers; anything else leaves a name or a citizen id
-- replicated to the whole bucket, which is worth a line.
local function scrub(source)
	-- Protected, and the selector is the reason: a slot that went while this was
	-- being called answers `invalid_state_selector`, and a host that answers it by
	-- raising rather than returning would take the caller down with it.
	local read, bag = pcall(Open77.state.player, source)
	if not read or type(bag) ~= 'table' then return end
	for _, key in ipairs(RETIRED) do
		local got, value = pcall(bag.get, bag, key)
		if got and value ~= nil then
			local called, cleared, why = pcall(bag.clear, bag, key)
			if (not called or cleared == false) and tostring(called and why or cleared)
				:find('unknown_bag', 1, true) == nil then
				warnOnce('clear:' .. key, ('bag key %s was not cleared for %s: %s')
					:format(key, tostring(source), tostring(called and why or cleared)))
			end
		end
	end
end

--- Publishes nothing, and scrubs the bag once.
-- Still called from `UpdatePlayerData` on every change -- the hook stays so a
-- reader of this file finds the decision where the publishing used to be -- and
-- costs one table read after the first call.
-- @author dop42
-- @param player Player
function State.Publish(player)
	if not State.Available() or type(player) ~= 'table' or player.Offline then return end
	local source = type(player.PlayerData) == 'table' and player.PlayerData.source or nil
	if type(source) ~= 'number' or source <= 0 or scrubbed[source] then return end
	scrubbed[source] = true
	scrub(source)
end

--- Scrubs a bag on unload and forgets it, so a recycled slot is scrubbed again.
-- @author dop42
-- @param source Source
function State.Clear(source)
	source = tonumber(source)
	if source == nil or source <= 0 then return end
	scrubbed[source] = nil
	if State.Available() then scrub(source) end
end

--- Scrubs every bag this session touched, on stop.
-- @author dop42
function State.Release()
	for source in pairs(scrubbed) do pcall(State.Clear, source) end
	scrubbed = {}
end
