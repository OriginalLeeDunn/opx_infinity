--- Where a brand new character starts: the catalogue, and the one thing it owns.
-- @author dop42
--
-- WHAT THIS MODULE OWNS, and nothing else does: the list of places a player may
-- start, the choice a player makes between them, and the deadline that ends a
-- choice nobody makes. It does NOT own placement. `character` does, and always
-- has -- a placement is a kill followed by a respawn, and the gate, the buckets,
-- the fade and the stored-position rule all live on that side of the seam. So
-- this module decides WHERE and `character` performs the move:
--
--   character.PlacePending   ->  spawn.Offer(source, citizenId)
--   the player clicks        ->  the wire -> spawn's server half
--   spawn                    ->  character.PlaceCharacter(player, point)
--
-- The dependency runs that way round and deliberately not the other: `spawn`
-- requires nothing, and `character` reaches for this module through
-- `OPX.Api.Get('spawn')` at the moment it needs it. Declaring the dependency in
-- both directions would be a cycle, which the registry refuses at boot.
--
-- WHY THE CATALOGUE IS SHARED RATHER THAN SENT. `config/` is a shared script, so
-- both halves already hold the same list, and the server is still the only
-- authority on it: a client sends the ID of a spot and the server looks that ID
-- up in its own copy for the coordinates. Sending the whole list down the wire
-- would be the same data twice, and the page would then be able to draw a spot
-- the server has never heard of.

local M = OPX.Modules.Declare{
	id = 'spawn',
	side = 'both',
	-- Not fatal. A world with no spawn module is a world whose new characters
	-- land on `character.DEFAULT_SPAWN`, which is exactly the behaviour before
	-- this module existed.
	fatal = false,
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises.
-- Four across the wire and one on this VM's public bus. There is no intra-VM
-- channel: both halves of this module talk over the wire and nothing here is
-- private. The host dispatcher matches on the name alone, so a verb repeated
-- across channels would be a re-entrant handler; no verb below is.
M.Event = {
	-- Server to client. "Pick one, and you have this many milliseconds."
	OFFER = OPX.Event(NET, 'spawn', 'offer'),
	-- Server to client. The choice is over, whichever way it ended, and every
	-- reason the menu comes down arrives on this one name with a reason on it.
	-- A second name per outcome would be four handlers on the page for one view.
	CLOSE = OPX.Event(NET, 'spawn', 'close'),
	-- Client to server. Every payload on it is attacker-controlled; only
	-- `source` is not, and the id is looked up rather than trusted.
	CHOOSE = OPX.Event(NET, 'spawn', 'choose'),
	-- Client to server. "The menu is on screen now." THIS IS WHAT STARTS THE
	-- COUNTDOWN, and it exists because the choice is deliberately deferred while
	-- the entry module is asking its own question -- a brand new character is
	-- asked for a name and a spawn at the same moment, and two modals on one
	-- keyboard is one modal losing its focus.
	--
	-- Without it the server counts from the moment the offer was QUEUED, which is
	-- before anybody can see anything: measured on the live server, the offer was
	-- queued at 16:09:33 and the name form was answered at 16:10:14, so a
	-- forty-five second window left the player four seconds of menu -- and a form
	-- that ran a little longer than the window left them none at all. The window
	-- is the player's time to CHOOSE, so it starts when there is something to
	-- choose from.
	OPENED = OPX.Event(NET, 'spawn', 'opened'),

	-- Client to server. "The join is still busy ahead of the menu" -- the name
	-- form or the fitting room is up -- so the hold is not run out under it. See
	-- `M.Waiting`: it extends the hold, never past a hard cap, and never once
	-- the menu itself is up.
	WAITING = OPX.Event(NET, 'spawn', 'waiting'),

	-- THIS MODULE'S OWN STATE, ON THE LOCAL BUS, and the reason the header above
	-- is wrong about there being nothing to watch. It was: this menu only ever
	-- had to WAIT on somebody, and `entry` published what it was waiting behind.
	-- But the spawn menu is itself one of the three screens that owns the display
	-- at join -- the creator, the fitting room and this -- and the HUD must not
	-- draw over any of them. `entry` already says so for the other two; a module
	-- that stands aside for the whole join and then says nothing when its own
	-- turn comes is the one gap in that sequence.
	--
	-- Same shape as `entry:state` deliberately, so a listener holds one rule for
	-- both rather than a special case per publisher.
	ON_STATE = OPX.Event(LOCAL, 'spawn', 'state'),
}

--- The three answers to "which world enters are offered the menu?".
-- @author dop42
--
-- A CLOSED SET, NAMED HERE RATHER THAN SPELLED OUT AT THE COMPARISON. The server
-- half branches on these three strings, the suite asserts against them and the
-- operator types one of them into `config/spawn.lua`; a literal `'never'` written
-- at each of those places is three copies of a value with nothing keeping them in
-- step, and a typo in any one of them is a branch that is simply never taken.
--
-- Declared in module.lua and not in the server half because the NAMES are shared
-- even though the decision is not: the client never reads a policy -- it draws
-- whatever offer it is sent -- but the tests load this file to name the values
-- they configure, and a vocabulary that lives inside the half it steers cannot be
-- named from outside it.
M.Policy = {
	-- Only a character that has never stood anywhere, which the row's own
	-- position is what decides: it is nil until the first save after the first
	-- placement, so this is "once per character, ever".
	FIRST = 'first',
	-- Every world enter, a returning character included.
	ALWAYS = 'always',
	-- Nobody, ever. No offer, no hold and no deadline: `character` places the body
	-- in the same tick, from the row.
	NEVER = 'never',
}

--- What an unreadable `OFFER_POLICY` falls back to.
-- ALWAYS, because it is what this module did before the setting existed: a
-- fallback that changed behaviour would make a typo in the configuration look
-- like a feature somebody had asked for.
M.POLICY_DEFAULT = M.Policy.ALWAYS

--- Whether a value is one of the three policies.
-- Answers the value itself rather than a boolean, so a caller reads
-- `M.KnownPolicy(raw) or M.POLICY_DEFAULT` in one line -- but the refusal is
-- still the caller's to journal, because a warning belongs where it can be said
-- once at start rather than on every join.
-- @author dop42
-- @param value any
-- @return string|nil
function M.KnownPolicy(value)
	if type(value) ~= 'string' then return nil end
	for _, known in pairs(M.Policy) do
		if value == known then return known end
	end
	return nil
end

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`, whose channel is core's: without it a client waiting on
-- one of several requests cannot tell which `error.tooFast` is its own.
M.Operation = {
	CHOOSE = 'spawn',
}

-- The id of the "where I left off" card. Not a configured place -- it has no
-- coordinates, the character's own row does -- and a configured place may not
-- take it (see `validName`'s caller below).
M.RESUME_ID = 'resume'

-- Bounds on one configured entry. The catalogue is authored by hand, so these
-- exist to catch a typo rather than an attacker -- but a bad entry is skipped
-- rather than fatal, because losing the menu is not worth losing the world.
local MAX_LOCATIONS = 64
local MAX_ID = 32
local MAX_LABEL = 48
local MAX_DISTRICT = 32

-- The catalogue, built once on first use and shared by both accessors below.
local points
local byId

--- Whether a value is a bounded identifier.
-- The same shape `form` accepts for a field id, and for the same reason: an id
-- crosses the wire as a bare string and is used as a table key on both sides.
-- @param value any
-- @param maximum integer
-- @return boolean
local function validName(value, maximum)
	return type(value) == 'string' and #value > 0 and #value <= maximum
		and value:match('^[%w_:%-%.]+$') ~= nil
end

--- Normalises one configured entry, or answers nil.
-- @param raw any
-- @param index integer
-- @return table|nil
local function normalize(raw, index)
	if type(raw) ~= 'table' then return nil end

	local id = raw.id
	if not validName(id, MAX_ID) then
		Open77.log.warn(('[spawn] location %d has no usable id and is dropped'):format(index))
		return nil
	end
	if id == M.RESUME_ID then
		Open77.log.warn(('[spawn] location %d is named %q, which is the "where I left off" card; ' ..
			'it is dropped'):format(index, id))
		return nil
	end

	local label = raw.label
	if type(label) ~= 'string' or label == '' or #label > MAX_LABEL then
		Open77.log.warn(('[spawn] location %s has no usable label and is dropped'):format(id))
		return nil
	end

	-- The district is the hint line under the label. A spot without one is still
	-- a place to stand, so it keeps the empty string rather than being dropped.
	local district = raw.district
	if type(district) ~= 'string' or #district > MAX_DISTRICT then district = '' end

	-- NaN and infinity both fail this, and a coordinate that is neither of those
	-- but not a number would otherwise ride all the way into a respawn request.
	local x, y, z = tonumber(raw.x), tonumber(raw.y), tonumber(raw.z)
	if not (OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)) then
		Open77.log.warn(('[spawn] location %s has no finite position and is dropped'):format(id))
		return nil
	end

	-- A heading that is missing or not finite is 0.0 rather than a dropped spot:
	-- the value is a facing, and north is a facing.
	local heading = tonumber(raw.heading)
	if not OPX.Math.IsFinite(heading) then heading = 0.0 end

	return {
		id = id,
		label = label,
		district = district,
		x = x,
		y = y,
		z = z,
		heading = heading,
	}
end

--- Builds the catalogue from the configuration, once.
local function build()
	if points ~= nil then return end
	points, byId = {}, {}

	local raw = M.Settings.LOCATIONS
	if type(raw) ~= 'table' then
		Open77.log.warn('[spawn] no LOCATIONS are configured: every new character ' ..
			'lands on the default spawn')
		return
	end

	for index = 1, #raw do
		if #points >= MAX_LOCATIONS then
			Open77.log.warn(('[spawn] more than %d locations are configured: the rest ' ..
				'are ignored'):format(MAX_LOCATIONS))
			break
		end
		local point = normalize(raw[index], index)
		if point ~= nil then
			-- Two spots with one id would make the choice ambiguous: the wire
			-- carries the id alone, so the second would be unreachable.
			if byId[point.id] ~= nil then
				Open77.log.warn(('[spawn] location %s is configured twice: the second ' ..
					'is ignored'):format(point.id))
			else
				points[#points + 1] = point
				byId[point.id] = point
			end
		end
	end

	if #points == 0 then
		Open77.log.warn('[spawn] every configured location was unusable: every new ' ..
			'character lands on the default spawn')
	end
end

--- Every usable location, in configured order.
-- The list belongs to this module and is handed out rather than copied: a caller
-- that reorders or edits it changes where players spawn for everybody.
-- @author dop42
-- @return table[]
function M.Catalogue()
	build()
	return points
end

--- One location by id, or nil.
-- THE lookup the server does for every choice, and the only reason the wire can
-- carry a bare id: the coordinates come from here and never from the client.
-- @author dop42
-- @param id any
-- @return table|nil
function M.Point(id)
	build()
	if type(id) ~= 'string' then return nil end
	return byId[id]
end

--- Whether there is anything to choose between.
-- Answers false for a configuration with no usable entry, which is the whole of
-- what makes this module stand down and let `character` place directly.
-- @author dop42
-- @return boolean
function M.HasPoints()
	return #M.Catalogue() > 0
end

--- Reads a configured number with a floor.
-- The floor is also the answer for a setting that is missing or not finite, so no
-- caller ever compares a number against nil. The test is finiteness and not a NaN
-- test: an infinity passes `value ~= value` and would freeze an interval.
-- @author dop42
-- @param value any
-- @param floor number
-- @return number
function M.Number(value, floor)
	value = tonumber(value)
	if not OPX.Math.IsFinite(value) then return floor end
	if floor and value < floor then return floor end
	return value
end
