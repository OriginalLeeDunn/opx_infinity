--- Wearing an NPC body: the ped a player is projected as, and giving it back.
-- @author dop42
--
-- The record is never typed through: an operator names a ROW in
-- `data/peds.lua` and this file hands the host that row's record. A raw
-- `Character.*` string is accepted too, but only when it is a row's record --
-- the allowlist is the point, and the platform would otherwise take any of the
-- 6,582 extracted ids, most of which are quest bodies that do not animate on a
-- player.
--
-- THE BUILD MAY NOT HAVE THIS AT ALL. `Open77.players.setModel` and its aliases
-- are on the platform's main branch and, as of 2.31.13+op77.78, in NO published
-- server build (the devkit card says "since: not in any published build"). So
-- every call goes
-- through `api()`, which answers nil when the native is absent, and the command
-- then refuses with `models_unavailable` instead of raising. The menu rows stay
-- drawn: the ACL grants them, the catalogue is real, and the day the server is
-- upgraded they start working with no change here.
--
-- A ped is not a placement and not a respawn: the body stays where it stands.
-- The readiness gate is still checked, because a model written on a client that
-- is not incarnated is the same class of mistake a transform write would be.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Peds = M.Peds
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit
local inform = Server.Inform

M.Models = {}
local Models = M.Models

-- The ped each player wears, by row name. This module's own mark: the host's
-- reader comes first everywhere it can answer, and this is what is left when it
-- cannot.
local worn = {}

-- Typed words that mean "give the body back".
local OFF = { off = true, none = true, reset = true, self = true, own = true }

-- The host's player-model table, or nil on a build that has none.
local function api()
	local players = Open77.players
	if type(players) ~= 'table' then return nil end
	if type(players.setModel) ~= 'function' or type(players.resetModel) ~= 'function' then
		return nil
	end
	return players
end

-- The options a `setModel` takes: no appearance, the configured lifetime, and
-- whether a death takes the ped off.
local function options()
	local models = M.Section('MODELS')
	return {
		durationMs = math.floor(M.Bounded('MODELS.DURATION_MS', models.DURATION_MS,
			0, 86400000, 0)),
		resetOnDeath = models.RESET_ON_DEATH ~= false,
	}
end

-- Puts a ped on a player. Answers false and a reason the caller audits.
local function wear(playerId, entry)
	local players = api()
	if players == nil then return false, 'models_unavailable' end
	local called, ok, reason = pcall(players.setModel, playerId, entry.record, options())
	-- A raise is logged and answered by code: its text is a Lua error with a
	-- file and a line, which is the journal's business and not the operator's.
	if not called then
		Open77.log.error(('[admin] setModel raised: %s'):format(tostring(ok)))
		return false, 'raised'
	end
	if ok ~= true then return false, tostring(reason or 'refused') end
	worn[playerId] = entry.name
	return true
end

-- Takes a player's ped off, back to the body their character owns.
local function shed(playerId)
	local players = api()
	if players == nil then return false, 'models_unavailable' end
	local called, ok, reason = pcall(players.resetModel, playerId)
	if not called then
		Open77.log.error(('[admin] resetModel raised: %s'):format(tostring(ok)))
		return false, 'raised'
	end
	if ok ~= true then return false, tostring(reason or 'refused') end
	worn[playerId] = nil
	return true
end

--- The ped a player is wearing, as a row name or a bare record, or nil.
-- The host's own reader first: it is the only one that knows about a model this
-- module did not put on, and about one a death or a duration already took off.
-- A nil WITH a reason is the host refusing rather than saying "their own body",
-- so that case falls back to this module's mark.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Models.Worn(playerId)
	local players = api()
	if players ~= nil and type(players.getModel) == 'function' then
		local read, state, reason = pcall(players.getModel, playerId)
		if read and state == nil and reason == nil then return nil end
		if read and type(state) == 'table' and type(state.record) == 'string' then
			local entry = Peds.Ped(state.record)
			return entry and entry.name or M.Trimmed(state.record, 64)
		end
	end
	return worn[playerId]
end

--- Whether this build can change a player's model at all, for the menu.
-- @author dop42
-- @return boolean
function Models.Available()
	return api() ~= nil
end

-- Reads the typed word as a catalogue row, as "take it off", or as neither.
-- Nothing typed means "take it off" when they are wearing one, so that a staff
-- member who has morphed gets their body back by running the command bare.
local function chosen(playerId, token)
	local word = M.Trimmed(token, 255)
	if word == nil then
		if Models.Worn(playerId) ~= nil then return nil, true end
		return nil, false
	end
	if OFF[word:lower()] then return nil, true end
	return Peds.Ped(word), false
end

-- The one path both commands take.
local function setModel(source, raw, playerId, token, event)
	if not Server.Admitted(source, raw, playerId, event) then return end

	local entry, off = chosen(playerId, token)
	if entry == nil and not off then return refuse(source, raw, 'unknown_ped') end

	local ok, reason
	if off then ok, reason = shed(playerId) else ok, reason = wear(playerId, entry) end
	if not ok then
		audit(source, event, false, playerId, tostring(reason))
		refuse(source, raw, reason == 'models_unavailable' and 'models_unavailable' or 'refused',
			{ reason = reason })
		return
	end

	M.Players.PushToStaff()
	local name = Server.LabelOf(playerId) or '?'
	if off then
		audit(source, event, true, playerId, 'off')
		inform(source, playerId, 'admin.toast.modelOff', nil, 'info')
		answer(source, raw, true, 'admin.done.modelOff', { id = playerId, name = name })
		return
	end

	audit(source, event, true, playerId, entry.name)
	inform(source, playerId, 'admin.toast.model', { label = entry.label }, 'info')
	answer(source, raw, true, 'admin.done.model',
		{ id = playerId, name = name, label = entry.label, ped = entry.name })
end

--- Registers the two model commands and the host's own model events.
-- @author dop42
function Models.Register()
	Server.Command(Command.SELF_MODEL, {
		help = 'admin.help.selfModel',
		params = { { name = 'ped|off', help = 'admin.help.ped', optional = true } },
		inGame = true,
		handler = function(source, args, raw)
			setModel(source, raw, source, args[1], 'admin.self.model')
		end,
	})

	Server.Command(Command.PLAYER_MODEL, {
		help = 'admin.help.playerModel',
		params = { { name = 'playerId', help = 'admin.help.playerId' },
			{ name = 'ped|off', help = 'admin.help.ped', optional = true } },
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1], 'admin.player.model')
			if playerId == nil then return end
			setModel(source, raw, playerId, args[2], 'admin.player.model')
		end,
	})

	-- The host's own three. A build without models never raises them, and a
	-- handler registered for an event nobody raises costs nothing.
	AddEventHandler('onPlayerModelFailed', function(player, _, reason)
		local playerId = tonumber(player) or 0
		if playerId <= 0 then return end
		-- The body never changed, so the mark would lie to the next menu draw.
		worn[playerId] = nil
		Open77.log.warn(('[admin] model refused for player %d: %s'):format(playerId,
			tostring(reason)))
		M.Players.PushToStaff()
	end)

	AddEventHandler('onPlayerModelReady', function(player)
		local playerId = tonumber(player) or 0
		if playerId > 0 then M.Players.PushToStaff() end
	end)

	-- A duration running out, a death with `resetOnDeath`, or another resource:
	-- all three reach here, and all three mean this module's mark is stale.
	AddEventHandler('onPlayerModelChanged', function(player, record)
		local playerId = tonumber(player) or 0
		if playerId <= 0 then return end
		if type(record) ~= 'string' or record == '' then
			worn[playerId] = nil
		else
			local entry = Peds.Ped(record)
			worn[playerId] = entry and entry.name or nil
		end
		M.Players.PushToStaff()
	end)

	if not Models.Available() then
		Open77.log.warn(('[admin] this build has no players.setModel native: %s and %s refuse ' ..
			'with models_unavailable and the menu greys their rows. Every other command is ' ..
			'unaffected.'):format(Command.SELF_MODEL, Command.PLAYER_MODEL))
	end
end

--- Gives every borrowed body back when the resource stops.
-- Best effort and never fatal: the players are about to lose the resource that
-- put the ped on, and leaving them wearing it would outlive it.
-- @author dop42
function Models.Release()
	for playerId in pairs(worn) do pcall(shed, playerId) end
	worn = {}
end

--- Drops a departing player's mark.
-- @author dop42
-- @param playerId Source
function Models.Forget(playerId)
	worn[playerId] = nil
end
