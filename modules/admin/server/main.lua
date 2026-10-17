--- The server half's spine: answers, the audit, the readiness gate, placement and
--- the command registry every staff command file registers through.
-- @author dop42
--
-- THE ACL IS THE ONLY AUTHORITY. `M.Server.Command` is a thin wrapper over
-- `OPX.Command.Register(name, { restricted = true }, handler)`: the host resolves
-- `command.<name>` before the handler runs, and core owns the suggestion list and
-- only offers a restricted command to a player the ACL would let run it. No
-- handler in this module checks a permission, and none should -- the host has
-- already decided, and a second check would only diverge from it. There is no
-- argument for registering an unrestricted command: every one of them acts on the
-- world or on somebody.
--
-- `M.Server.Permitted` asks the ACL the same question, but only where there is no
-- command to resolve: the menu's access map, the refresh event, the travel-mode
-- revocation sweep, and who counts as staff for a name tag badge. It answers nil
-- when the host has no ACL reader, which callers read as "cannot say"; the
-- console is always allowed.

local M = OPX.Modules.Get('admin')

local Text = OPX.Text

--- Server-half helpers every staff command file reads.
M.Server = {}
local Server = M.Server

-- What a placement kill is attributed to.
local RESOURCE = GetCurrentResourceName()

-- Catalogue key a player reads for each refusal code. The codes stay codes in the
-- audit and the log; only a player reads the catalogue.
local ERRORS = {
	in_game_only = 'admin.error.inGameOnly',
	too_fast = 'admin.error.tooFast',
	failed = 'admin.error.failed',
	no_target = 'admin.error.noTarget',
	bad_target = 'admin.error.badTarget',
	console_has_no_player = 'admin.error.consoleNoPlayer',
	not_connected = 'admin.error.notConnected',
	self_target = 'admin.error.selfTarget',
	not_incarnated = 'admin.error.notIncarnated',
	gate_closed = 'admin.error.gateClosed',
	gate_unreadable = 'admin.error.gateUnreadable',
	no_position = 'admin.error.noPosition',
	kill_refused = 'admin.error.killRefused',
	kill_not_granted = 'admin.error.killNotGranted',
	target_protected = 'admin.error.targetProtected',
	weapon_not_granted = 'admin.error.weaponNotGranted',
	busy = 'admin.error.busy',
	vehicle_out_of_reach = 'admin.error.vehicleOutOfReach',
	respawn_refused = 'admin.error.respawnRefused',
	refused = 'admin.error.refused',
	bad_coordinates = 'admin.error.badCoordinates',
	bad_switch = 'admin.error.badSwitch',
	bad_duration = 'admin.error.badDuration',
	empty_text = 'admin.error.emptyText',
	unknown_vehicle = 'admin.error.unknownVehicle',
	vehicle_cap = 'admin.error.vehicleCap',
	no_vehicle = 'admin.error.noVehicle',
	occupied = 'admin.error.occupied',
	unsafe_repair = 'admin.error.unsafeRepair',
	bad_scope = 'admin.error.badScope',
	unknown_flag = 'admin.error.unknownFlag',
	not_ours = 'admin.error.notOurs',
	vehicles_unavailable = 'admin.error.vehiclesUnavailable',
	keys_unavailable = 'admin.error.keysUnavailable',
	unknown_weapon = 'admin.error.unknownWeapon',
	holster_unavailable = 'admin.error.holsterUnavailable',
	not_armed = 'admin.error.notArmed',
	unknown_ammo = 'admin.error.unknownAmmo',
	give_partial = 'admin.error.givePartial',
	inventory_unavailable = 'admin.error.inventoryUnavailable',
	bad_holder = 'admin.error.badHolder',
	no_character = 'admin.error.noCharacter',
	unknown_citizen = 'admin.error.unknownCitizen',
	unknown_item = 'admin.error.unknownItem',
	bad_count = 'admin.error.badCount',
	not_enough = 'admin.error.notEnough',
	bag_no_room = 'admin.error.bagNoRoom',
	bag_too_heavy = 'admin.error.bagTooHeavy',
	unknown_location = 'admin.error.unknownLocation',
	bad_location_name = 'admin.error.badLocationName',
	seeded_location = 'admin.error.seededLocation',
	bad_door = 'admin.error.badDoor',
	door_limit = 'admin.error.doorLimit',
	doors_networked = 'admin.error.doorsNetworked',
	combat_unavailable = 'admin.error.combatUnavailable',
	unknown_ped = 'admin.error.unknownPed',
	models_unavailable = 'admin.error.modelsUnavailable',
	bad_name = 'admin.error.badName',
	characters_unavailable = 'admin.error.charactersUnavailable',
	search_short = 'admin.error.searchShort',
	bad_request = 'admin.error.badRequest',
}

-- Refusal codes about typed input, answered as warnings rather than errors.
local TYPED = {
	too_fast = true, no_target = true, bad_target = true, self_target = true,
	bad_coordinates = true, bad_switch = true, bad_duration = true, empty_text = true,
	unknown_vehicle = true, bad_scope = true, unknown_flag = true, unknown_weapon = true,
	unknown_location = true, bad_location_name = true, bad_holder = true, unknown_citizen = true,
	unknown_item = true, bad_count = true, not_enough = true, unknown_ammo = true,
	bad_door = true, unknown_ped = true, bad_name = true, search_short = true,
}

-- The catalogue key a multi-line report is answered with.
local REPORT = 'admin.text.lines'

--- Host-monotonic milliseconds.
-- @author dop42
-- @return integer
function Server.NowMs()
	return OPX.Now()
end

--- A configured number, or the fallback for anything arithmetic would raise on.
-- @author dop42
-- @param value any
-- @param fallback number
-- @return number
function Server.Setting(value, fallback)
	return M.Number(value, fallback)
end

--- How many arguments were typed.
-- `args.n` is authoritative: `#args` reads a hole as the end of the list.
-- @author dop42
-- @param args table
-- @return integer
function Server.Count(args)
	local given = Text.Integer(args.n)
	if given == nil or given < 0 then return #args end
	return given
end

--- One answer back to whoever ran the command.
-- A report goes to the chat log through core's own answer channel, so that
-- whatever draws a chat log draws it and nothing has to name this module. Every
-- other answer goes to this module's client half on its own channel, because it
-- carries the typed line: that is what lets the menu put the answer under its
-- own list instead of only raising a toast.
-- @author dop42
-- @param source Source
-- @param raw string the typed line
-- @param ok boolean
-- @param key string catalogue key
-- @param params table|nil
-- @param kind string|nil info, success, warning or error; inferred when nil
-- @return boolean ok
function Server.Answer(source, raw, ok, key, params, kind)
	local player = tonumber(source) or 0
	if player <= 0 then
		local line = locale(key, params)
		if ok then Open77.log.info(line) else Open77.log.warn(line) end
		return ok == true
	end

	if key == REPORT then
		return OPX.CommandResult(player, ok == true, locale(key, params)) or ok == true
	end

	if kind == nil then
		if ok then
			kind = 'success'
		else
			kind = key:sub(1, 12) == 'admin.usage.' and 'warning' or 'error'
		end
	end
	TriggerClientEvent(M.Event.ANSWER, player, raw or '', ok == true, locale(key, params), kind)
	return ok == true
end

--- Answers a refusal by its code, with the host's own reason when it gave one.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param code string
-- @param params table|nil
-- @return boolean false
function Server.Refuse(source, raw, code, params)
	params = params or {}
	params.code = code
	params.reason = params.reason and M.Trimmed(params.reason, 64) or code
	Server.Answer(source, raw, false, ERRORS[code] or ERRORS.failed, params,
		TYPED[code] and 'warning' or 'error')
	return false
end

--- Raises a toast on the target player's screen, best effort.
-- A missing notification surface never fails the action that already happened.
-- @author dop42
-- @param playerId Source
-- @param key string catalogue key
-- @param params table|nil
-- @param kind string|nil
function Server.Tell(playerId, key, params, kind)
	pcall(OPX.Notify, playerId, locale(key, params), kind or 'info',
		math.floor(OPX.Tune.Number('ADMIN_TOAST_MS', 1000)))
end

--- Raises the INBOUND notice -- "a staff member did this to you" -- on the
--- target, and on nobody else. A staff member acting on themselves is told
--- nothing: they already have the command's own answer, and a second line
--- telling them what they just did is noise.
---
--- ONE DOOR, BECAUSE THERE WERE FOURTEEN. Every inbound notice in this module
--- was written as `if playerId ~= source then tell(playerId, ...) end` at its own
--- call site, fourteen times across six files, and the comparison is not part of
--- the sentence -- it is part of what an inbound notice IS. `admin.player.kill`
--- had already dropped it, so a staff member who killed themselves was told that
--- "a staff member killed you"; the owner reported the same shape on the give,
--- where giving themselves an item answered the command AND warned them that a
--- staff member had put something in their bag.
---
--- The comparison is on NUMBERS on both sides. A source arrives as a string on
--- some host paths -- see `core/server/answer.lua`, where four functions
--- normalise and two had to be fixed for exactly that -- and `'1' ~= 1` is true
--- in Lua, so an un-normalised comparison would let the notice through on the one
--- door it exists to close.
-- @author dop42
-- @param source Source the staff member who acted
-- @param playerId Source|nil the player it happened to, nil when nobody is there
-- @param key string catalogue key
-- @param params table|nil
-- @param kind string|nil
-- @return boolean whether the notice went out
function Server.Inform(source, playerId, key, params, kind)
	local target = tonumber(playerId)
	if target == nil or target <= 0 then return false end
	if target == (tonumber(source) or 0) then return false end
	Server.Tell(target, key, params, kind)
	return true
end

--- The Master-verified display name, cleaned for a log line or a row.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.NameOf(playerId)
	local read, name = pcall(OPX.DisplayNameOf, playerId)
	if not read then return nil end
	return M.Trimmed(name, 32)
end

--- The durable account id of a connected player.
-- A player id is recycled; this is what an audit line keeps.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.UserOf(playerId)
	if (tonumber(playerId) or 0) <= 0 then return nil end
	local read, identifier = pcall(OPX.UserIdOf, playerId)
	if not read then return nil end
	return M.Trimmed(identifier, 64)
end

-- The PlayerData of the character loaded on a slot, through the `character`
-- contract, or nil for a slot at the selection screen or a runtime without the
-- module.
local function loadedData(playerId)
	local character = OPX.Api.Get('character')
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	if (tonumber(playerId) or 0) <= 0 then return nil end
	local read, player = pcall(character.GetPlayer, playerId)
	if not read or type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
	return player.PlayerData
end

--- The name of the CHARACTER a player is playing, or nil.
--
-- Through the `character` contract, on the server. It was read off the player's
-- replicated state bag, and the bag no longer carries it: a bag goes to every
-- client in the bucket, and never a name to a stranger is the owner's decision
-- (`modules/character/server/state.lua`). Staff still see it -- on their own
-- lines and on the staff name-tag list, both behind the ACL.
--
-- Nil is an ordinary answer twice over: for somebody still at the selection
-- screen, and for a character that has not been named yet -- a character is a row
-- before it is anybody.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.CharacterOf(playerId)
	local data = loadedData(playerId)
	local info = data ~= nil and type(data.charInfo) == 'table' and data.charInfo or nil
	if info == nil then return nil end
	local first = type(info.firstName) == 'string' and info.firstName or ''
	local last = type(info.lastName) == 'string' and info.lastName or ''
	local full = OPX.String.Trim(first .. ' ' .. last)
	if full == '' then return nil end
	return M.Trimmed(full, 64)
end

--- The public id of the character a player is playing, through the contract.
-- Seven symbols in a three-dash-four group, and the one thing on a staff line
-- that survives a rename. Nil before a character is loaded.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.CitizenBagOf(playerId)
	local data = loadedData(playerId)
	return data ~= nil and M.Trimmed(data.citizenId, 32) or nil
end

--- What a staff line calls a player: the character, and the account behind it.
--
-- BOTH, ALWAYS, and never one or the other. A staff line naming only the
-- character cannot be matched to a ban, an audit row or a support ticket, all of
-- which are keyed on the account; a line naming only the account says nothing
-- about the person everybody else in the city was talking to. Nil means not
-- connected, which is what every caller of `NameOf` used it to mean.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.LabelOf(playerId)
	local user = Server.NameOf(playerId)
	if user == nil then return nil end
	local character = Server.CharacterOf(playerId)
	if character == nil then return user end
	return ('%s (%s)'):format(character, user)
end

--- The citizen id of the character a player has loaded, or nil.
-- Read through the `character` contract, never off that module's namespace.
-- @author dop42
-- @param playerId Source
-- @return string|nil
function Server.CitizenOf(playerId)
	local character = OPX.Api.Get('character')
	if character == nil or (tonumber(playerId) or 0) <= 0 then return nil end
	local read, player = pcall(character.GetPlayer, playerId)
	if not read or type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
	return player.PlayerData.citizenId
end

--- Every connected player id, sorted.
-- @author dop42
-- @return integer[]
function Server.PlayerIds()
	local read, players = pcall(Open77.players.all)
	local ids = {}
	for _, value in ipairs(read and type(players) == 'table' and players or {}) do
		local id = tonumber(value)
		if id and id > 0 then ids[#ids + 1] = id end
	end
	table.sort(ids)
	return ids
end

-- Resolves a typed target to a connected player id, or the caller.
local function targetOf(source, token)
	if token == nil then return nil, 'no_target' end
	local word = tostring(token):lower()
	if word == 'me' or word == 'self' then
		if source <= 0 then return nil, 'console_has_no_player' end
		return source, nil
	end
	local playerId = Text.Integer(token)
	if playerId == nil or playerId <= 0 then return nil, 'bad_target' end
	if Server.NameOf(playerId) == nil then return nil, 'not_connected' end
	return playerId, nil
end

--- One raw ACL right -- not a `command.` one -- true or false, or nil when the
--- ACL cannot be read. The console holds every right.
-- @author dop42
-- @param playerId Source
-- @param right string
-- @return boolean|nil
function Server.Holds(playerId, right)
	if (tonumber(playerId) or 0) <= 0 then return true end
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return nil end
	local read, allowed = pcall(acl.isAllowed, playerId, right)
	if not read then return nil end
	return allowed == true
end
local holds = Server.Holds

--- Whether a target is shielded from what an actor is about to do to them.
-- @author dop42
--
-- STAFF IMMUNITY. Nothing used to stop an operator kicking, banning, killing,
-- freezing, stripping or deleting a higher-ranked one: every grant applied to
-- every player alike. A player holding `M.IMMUNE` (`opx.admin.immune`, a raw
-- ACL right and not a command) is now shielded from every harmful staff action,
-- unless the actor holds `M.OVERRIDE` (`opx.admin.override`). The console is
-- the server and is never stopped; an operator acting on themselves never is
-- either. An immunity the ACL cannot answer is read as HELD: an action this
-- check cannot clear is one it refuses.
-- @param actor Source
-- @param target Source
-- @return boolean
function Server.Protected(actor, target)
	actor, target = tonumber(actor) or 0, tonumber(target)
	if actor <= 0 or target == nil or target <= 0 or actor == target then return false end
	if holds(target, M.IMMUNE) == false then return false end
	return holds(actor, M.OVERRIDE) ~= true
end

--- `Protected`, refused to the operator as `target_protected` and audited.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param target Source
-- @param event string the audit event of the action refused
-- @return boolean true when the action is to stop
function Server.Shielded(source, raw, target, event)
	if not Server.Protected(source, target) then return false end
	Server.Refuse(source, raw, 'target_protected',
		{ id = target, name = Server.LabelOf(target) or '?' })
	Server.Audit(source, event or 'admin.protected', false, target, 'target protected')
	return true
end

--- Resolves a typed target to a connected player, or answers why not. With
--- `harm` -- the audit event of an action that hurts the target -- a protected
--- target is refused as well (see `Server.Protected`).
-- @author dop42
-- @param source Source
-- @param raw string
-- @param token any
-- @param harm string|nil
-- @return integer|nil
function Server.Target(source, raw, token, harm)
	local playerId, code = targetOf(source, token)
	if playerId == nil then
		Server.Refuse(source, raw, code)
		return nil
	end
	if harm ~= nil and Server.Shielded(source, raw, playerId, harm) then return nil end
	return playerId
end

--- The replicated position and routing bucket, or nil before the world is up.
-- @author dop42
-- @param playerId Source
-- @return table|nil
function Server.PositionOf(playerId)
	local read, position = pcall(Open77.players.position, playerId)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = Text.Finite(position.x), Text.Finite(position.y), Text.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = Text.Integer(position.bucket) or 0,
		heading = Server.HeadingOf(playerId) }
end

--- The yaw a player's body is facing, or nil when the host cannot say.
-- @author dop42
--
-- WHY THIS IS A SECOND CALL. `Open77.players.position` answers `{ x, y, z,
-- bucket }` and nothing else -- there is no facing in it at all, which is why
-- `/opx.admin.self.pos` printed a hardcoded `HEADING = 0.0` for as long as it
-- existed. `Open77.players.get` is the rich read (2.31.13+op77.67) and carries
-- `heading` with its alias `yaw` once the player has ever reported a snapshot.
--
-- THIS IS NOW LOAD-BEARING and it was cosmetic before. The staff menu's Dev
-- screen used to place a showroom car facing whichever way the OPERATOR'S OWN
-- CLIENT was looking, because the client reads its own facing and a chat line
-- has none. The owner deleted that screen on 2026-09-21 and a showroom car is a
-- line in `config/dealership.lua` now -- so the one thing left that turns "where
-- I am standing, facing this way" into a config line is this command, and a
-- capture with no facing in it cannot write `HEADING`.
--
-- NIL RATHER THAN ZERO on a host that cannot answer. Zero is a legal facing, so
-- a fallback of zero would be indistinguishable from north and the caller could
-- not tell the operator that the number is a guess. `SELF_POS` says so.
-- @param playerId Source
-- @return number|nil degrees, 0..360
function Server.HeadingOf(playerId)
	local api = Open77.players
	if type(api) ~= 'table' or type(api.get) ~= 'function' then return nil end
	local read, snapshot = pcall(api.get, playerId)
	if not read or type(snapshot) ~= 'table' then return nil end
	local yaw = Text.Finite(snapshot.heading)
	if yaw == nil then yaw = Text.Finite(snapshot.yaw) end
	if yaw == nil then return nil end
	return yaw % 360.0
end

--- The host's life state for a player, or nil: loading and the selection screen
--- have none.
-- @author dop42
-- @param playerId Source
-- @return table|nil
function Server.LifeOf(playerId)
	local read, life = pcall(Open77.players.getLifeState, playerId)
	if not read or type(life) ~= 'table' then return nil end
	return life
end

--- Whether a player's body may be acted on at all.
-- Fails CLOSED when the gate cannot be read: nothing may teleport, spawn, kill or
-- respawn a player until their readiness gate has opened, and an unreadable gate
-- is not an open one. Kick and ban do not come through here.
-- @author dop42
-- @param playerId Source
-- @return boolean admitted
-- @return table|string the life state, or the refusal code
function Server.Admit(playerId)
	local life = Server.LifeOf(playerId)
	if life == nil then return false, 'not_incarnated' end
	local ready = Open77.ready
	if type(ready) ~= 'table' or type(ready.isReady) ~= 'function' then
		return false, 'gate_unreadable'
	end
	local read, open = pcall(ready.isReady, playerId)
	if not read then return false, 'gate_unreadable' end
	if open ~= true then return false, 'gate_closed' end
	return true, life
end

--- `Admit`, with a closed gate answered to the operator and audited.
-- @author dop42
-- @param source Source
-- @param raw string
-- @param playerId Source
-- @param event string
-- @return boolean
function Server.Admitted(source, raw, playerId, event)
	local admitted, code = Server.Admit(playerId)
	if admitted then return true end
	Server.Refuse(source, raw, code, { id = playerId })
	Server.Audit(source, event, false, playerId, code)
	return false
end

--- Health fraction and grace window a moved or revived player gets back.
-- @author dop42
-- @return table
function Server.Recovery()
	local placement = M.Section('PLACEMENT')
	return {
		health = math.min(1.0, math.max(0.01, Server.Setting(placement.HEALTH, 1.0))),
		graceMs = math.floor(OPX.Tune.Number('ADMIN_PLACEMENT_GRACE_MS', 0)),
	}
end

--- Moves a player through kill then respawn, reviving them in place on a refusal.
-- Never a transform write: a transform written on a client that is not incarnated
-- is exactly what the readiness gate exists to stop, and `respawn` is the one call
-- that places a body, a bucket and a health value together.
-- @author dop42
-- @param playerId Source
-- @param point table x, y, z
-- @param heading number|nil
-- @param bucket integer|nil nil keeps the bucket they are in
-- @param why string what the kill is attributed to
-- @return boolean ok
-- @return string|nil code
-- @return string|nil reason
function Server.Place(playerId, point, heading, bucket, why)
	local admitted, code = Server.Admit(playerId)
	if not admitted then return false, code end

	local recovery = Server.Recovery()
	if bucket == nil then
		local position = Server.PositionOf(playerId)
		bucket = position and position.bucket or 0
	end

	local killed = false
	local deadRead, dead = pcall(Open77.players.isDead, playerId)
	if not (deadRead and dead == true) then
		local ok, reason = Open77.players.kill(playerId, {
			cause = 'script',
			weapon = RESOURCE .. ':' .. why,
		})
		if not ok then return false, 'kill_refused', tostring(reason) end
		killed = true
	end

	local respawned, reason = Open77.players.respawn(playerId, {
		position = { x = point.x, y = point.y, z = point.z },
		heading = heading or 0.0,
		bucket = bucket,
		health = recovery.health,
		graceMs = recovery.graceMs,
	})
	if not respawned then
		-- The player is dead on the floor where they stood; put them back up
		-- rather than leaving them there because a move failed.
		if killed then pcall(Open77.players.revive, playerId, recovery) end
		return false, 'respawn_refused', tostring(reason)
	end
	return true
end

-- The in-memory audit ring, oldest entry first, and the sequence it is numbered
-- by. The platform log line written beside every entry is the record; this is
-- only what `opx.admin.read.audit` can read back, and it is gone at a restart.
local ledger = {}
local sequence = 0

--- Records one staff action: an `[audit]` line and an entry in the ring.
-- @author dop42
-- @param source Source 0 for the console
-- @param event string stable and greppable, like admin.player.kill
-- @param ok boolean
-- @param target Source|nil the player acted on, if any
-- @param detail string|nil English, for the log
function Server.Audit(source, event, ok, target, detail)
	local actor = tonumber(source) or 0
	sequence = sequence + 1
	local entry = {
		seq = sequence,
		atMs = Server.NowMs(),
		event = event,
		ok = ok == true,
		actor = actor,
		-- The character AND the account, because an audit row that names only one
		-- of them is a row nobody can act on. See `Server.LabelOf`.
		actorName = actor > 0 and (Server.LabelOf(actor) or '?') or 'console',
		target = target,
		targetName = target and Server.LabelOf(target) or nil,
		detail = M.Trimmed(detail, 120) or '',
	}
	ledger[#ledger + 1] = entry
	local keep = math.floor(OPX.Tune.Number('ADMIN_AUDIT_ENTRIES', 10))
	while #ledger > keep do table.remove(ledger, 1) end

	OPX.Audit.Log({
		event = event,
		severity = entry.ok and 'info' or 'warn',
		message = entry.detail,
		source = actor > 0 and actor or nil,
		userId = actor > 0 and Server.UserOf(actor) or nil,
		citizenId = actor > 0 and Server.CitizenOf(actor) or nil,
		data = {
			actorName = entry.actorName,
			target = target,
			targetUser = target and Server.UserOf(target) or nil,
			targetName = entry.targetName,
		},
	})
end

--- The most recent audit entries, newest last.
-- @author dop42
-- @param count integer
-- @return table[]
function Server.Recent(count)
	local out = {}
	for index = math.max(1, #ledger - count + 1), #ledger do out[#out + 1] = ledger[index] end
	return out
end

-- Registered commands, in registration order, and the set of names.
local commands = {}
local byName = {}

--- Whether this run falls inside the operator's floor for a command or a topic,
--- recording the attempt when it does not.
-- The window is core's, per player and per key, and a departing player's windows
-- are dropped by core. The console is never cooled.
-- @author dop42
-- @param player Source
-- @param key string
-- @param intervalMs number
-- @return boolean cooled true when the run is to be dropped
function Server.Cooled(player, key, intervalMs)
	if (tonumber(player) or 0) <= 0 then return false end
	return OPX.Cooling(player, 'admin:' .. key, intervalMs)
end

--- Captures the recipient of a yielding read and rechecks their grant on reply.
-- Console responses have no recyclable player slot.
function Server.Recipient(player, grant)
	if player <= 0 then return function() return true end end
	local userId, session = OPX.UserIdOf(player), OPX.Sessions[player]
	return function()
		return userId ~= nil and OPX.UserIdOf(player) == userId and
			OPX.Sessions[player] == session and Server.Permitted(player, grant) == true
	end
end

-- ── one heavy request in flight per operator ─────────────────────────────────
--
-- THE SERVER'S TASK QUOTA IS 1,024, and every bag, weapon and character command
-- -- and every list the menu asks for -- runs on a thread of its own because the
-- contract read yields. The floors are per command and per topic, so one
-- operator walking through different commands could start twenty or forty
-- threads a second, and against a slow database they piled up. Now each
-- operator has at most ONE such thread: a typed command that arrives while it
-- runs is refused as `busy`, and a menu list (which has a key) waits its turn
-- in that same thread -- the newest ask per key, so a screen asked for three
-- times is read once.
local workers = {}

-- A worker this old is presumed stuck -- a read that never answered -- and no
-- longer holds the operator's slot.
local HEAVY_STALE_MS = 30000

--- Runs one heavy request on the operator's single worker thread.
-- @author dop42
-- @param source Source
-- @param raw string|nil the command line, for a refusal; nil for a menu list
-- @param fn function the request; may yield
-- @param key string|nil a menu list's topic: queued behind a running request
-- instead of refused
-- @return boolean whether it was taken
function Server.Heavy(source, raw, fn, key)
	local player = tonumber(source) or 0
	if player <= 0 then
		CreateThread(fn)
		return true
	end
	-- A queued request belongs to the connection that submitted it. Clearing
	-- the worker on disconnect cannot cancel a coroutine the host already queued.
	local userId, session = OPX.UserIdOf(player), OPX.Sessions[player]
	local requested = fn
	fn = function()
		if userId == nil or OPX.UserIdOf(player) ~= userId or
			OPX.Sessions[player] ~= session then return end
		return requested()
	end
	local worker = workers[player]
	if worker ~= nil and Server.NowMs() - worker.since > HEAVY_STALE_MS then
		workers[player], worker = nil, nil
	end
	if worker ~= nil then
		if key ~= nil then
			if worker.keys[key] == nil then worker.queue[#worker.queue + 1] = key end
			worker.keys[key] = fn
			return true
		end
		Server.Refuse(player, raw or '', 'busy')
		return false
	end
	worker = { queue = {}, keys = {}, since = Server.NowMs() }
	workers[player] = worker
	CreateThread(function()
		local run = fn
		while run ~= nil and workers[player] == worker do
			worker.since = Server.NowMs()
			local ran, failure = pcall(run)
			if not ran then
				Open77.log.error(('[admin] a staff request raised: %s'):format(tostring(failure)))
			end
			run = nil
			local nextKey = table.remove(worker.queue, 1)
			if nextKey ~= nil then
				run = worker.keys[nextKey]
				worker.keys[nextKey] = nil
			end
		end
		if workers[player] == worker then workers[player] = nil end
	end)
	return true
end

--- Forgets a departing operator's worker; a running request ends on its own.
-- @author dop42
-- @param playerId Source
function Server.ForgetHeavy(playerId)
	workers[tonumber(playerId) or 0] = nil
end

--- Registers one restricted staff command with its floor and its raise guard.
-- Always restricted: the host resolves `command.<name>` before the handler runs.
-- @author dop42
-- @param name string
-- @param spec table help, params, read, inGame, handler
function Server.Command(name, spec)
	if byName[name] ~= nil then
		Open77.log.error(('[admin] command %s is registered twice; the second is dropped')
			:format(name))
		return
	end

	local entry = { name = name, help = spec.help, params = spec.params or {} }
	commands[#commands + 1] = entry
	byName[name] = entry

	-- Core renders a command's own help at send time, from the key, so a language
	-- change is reflected without re-registering. It does NOT render a
	-- PARAMETER's help, so that one is rendered here or the key itself would
	-- reach the chat box. The catalogue is loaded before any module starts and
	-- the active language is settled at load, so there is nothing to re-render.
	local params = {}
	for index, parameter in ipairs(entry.params) do
		params[index] = {
			name = parameter.name,
			help = parameter.help and locale(parameter.help) or nil,
			optional = parameter.optional == true or nil,
		}
	end

	OPX.Command.Register(name, {
		restricted = true,
		help = spec.help,
		params = params,
	}, function(source, args, raw)
		local player = tonumber(source) or 0
		raw = type(raw) == 'string' and raw or name
		args = type(args) == 'table' and args or { n = 0 }
		if spec.inGame and player <= 0 then return Server.Refuse(player, raw, 'in_game_only') end
		-- Read at the moment of use, never captured: the floor is a live tunable.
		local floor = spec.read and OPX.Tune.Number('ADMIN_RATE_READ_MS', 0)
			or OPX.Tune.Number('ADMIN_RATE_ACTION_MS', 0)
		if Server.Cooled(player, name, floor) then return Server.Refuse(player, raw, 'too_fast') end
		-- Guarded: a raise inside a command handler is otherwise swallowed with no
		-- answer at all, which reads to an operator as a command that did nothing.
		local ran, failure = pcall(spec.handler, player, args, raw)
		if not ran then
			Open77.log.error(('[admin] %s raised: %s'):format(name, tostring(failure)))
			Server.Refuse(player, raw, 'failed')
		end
	end)
end

--- Every registered command name, in registration order.
-- @author dop42
-- @return table[]
function Server.Commands()
	return commands
end

--- Whether the host ACL grants a command, nil when it cannot say.
-- For the places that are NOT a command: the access map, the refresh event, the
-- travel revocation sweep and the name tag badge. The console is always true.
-- @author dop42
-- @param playerId Source
-- @param name string
-- @return boolean|nil
function Server.Permitted(playerId, name)
	if playerId <= 0 then return true end
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return nil end
	local read, allowed = pcall(acl.isAllowed, playerId, 'command.' .. name)
	if not read then return nil end
	return allowed == true
end

--- The contracts this half reads, resolved once in `Start`.
-- A nil answer is one feature off and never a fault; every caller checks.
M.Contracts = M.Contracts or {}

--- One optional contract, logging its absence once.
-- @author dop42
-- @param name string
-- @return table|nil
function Server.Contract(name)
	return M.Contracts[name]
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state and declares the tunables. Never yields, and reaches no
--- other module: nothing has published a contract yet.
-- @author dop42
function M.Init()
	M.Contracts = {}
	ledger = {}
	sequence = 0
	commands = {}
	byName = {}

	-- The configured value becomes the panel entry's default, so an operator sets
	-- the starting point in config and moves it live from the panel.
	local rate = M.Section('RATE')
	local placement = M.Section('PLACEMENT')
	local vehicles = M.Section('VEHICLES')
	local announce = M.Section('ANNOUNCE')
	local inventory = M.Section('INVENTORY')
	local tags = M.Section('TAGS')

	local block = {}
	for key, spec in pairs(M.TUNABLES) do
		local copy = {}
		for field, value in pairs(spec) do copy[field] = value end
		block[key] = copy
	end
	block.ADMIN_RATE_ACTION_MS.value = math.floor(M.Bounded('RATE.ACTION_MS', rate.ACTION_MS,
		0, 60000, 400))
	block.ADMIN_RATE_READ_MS.value = math.floor(M.Bounded('RATE.READ_MS', rate.READ_MS,
		0, 60000, 1000))
	block.ADMIN_RATE_REFRESH_MS.value = math.floor(M.Bounded('RATE.REFRESH_MS', rate.REFRESH_MS,
		0, 60000, 750))
	block.ADMIN_AUDIT_ENTRIES.value = math.floor(M.Bounded('AUDIT_ENTRIES', M.Settings.AUDIT_ENTRIES,
		10, 2000, 200))
	block.ADMIN_TOAST_MS.value = math.floor(M.Bounded('TOAST_MS', M.Settings.TOAST_MS,
		1000, 60000, 6000))
	block.ADMIN_PLACEMENT_GRACE_MS.value = math.floor(M.Bounded('PLACEMENT.GRACE_MS',
		placement.GRACE_MS, 0, 60000, 5000))
	block.ADMIN_ANNOUNCE_MS.value = math.floor(M.Bounded('ANNOUNCE.DURATION_MS',
		announce.DURATION_MS, 1000, 120000, 12000))
	block.ADMIN_VEHICLE_PER_OWNER.value = math.floor(M.Bounded('VEHICLES.PER_OWNER',
		vehicles.PER_OWNER, 1, 100, 8))
	block.ADMIN_VEHICLE_NEAR_RADIUS.value = M.Bounded('VEHICLES.NEAR_RADIUS',
		vehicles.NEAR_RADIUS, 1, 200, 30.0)
	block.ADMIN_INVENTORY_MAX_COUNT.value = math.floor(M.Bounded('INVENTORY.MAX_COUNT',
		inventory.MAX_COUNT, 1, 1000000, 10000))
	block.ADMIN_TAGS_REFRESH_MS.value = math.floor(M.Bounded('TAGS.REFRESH_MS', tags.REFRESH_MS,
		500, 60000, 2000))

	OPX.Tune.Declare(block)
end

--- Publishes the server half of the contract.
-- Deliberately small: what another module may want is the roster this module
-- already builds and the audit it already keeps. Everything that CHANGES the
-- world stays a restricted command, because a contract call is no ACL check.
-- @author dop42
function M.Api()
	OPX.Api.Provide('admin', 1, {
		IsStaff = function(playerId)
			return OPX.Result.Ok({ staff = Server.Permitted(playerId, M.OPENER) == true })
		end,
		Roster = function() return OPX.Result.Ok({ rows = M.World.Roster(nil) }) end,
		RecentActions = function(count)
			local wanted = math.min(200, math.max(1, Text.Integer(count) or 15))
			return OPX.Result.Ok({ entries = Server.Recent(wanted) })
		end,
	})
end

--- Registers every command and starts the background passes. On a coroutine.
-- @author dop42
function M.Start()
	M.Contracts.character = OPX.Api.Get('character')
	M.Contracts.inventory = OPX.Api.Get('inventory')
	M.Contracts.vehicles = OPX.Api.Get('vehicles')
	M.Contracts.downed = OPX.Api.Get('downed')
	M.Contracts.prompts = OPX.Api.Get('prompts')
	-- RESOLVED HERE OR NOT AT ALL. `Server.Contract` reads this table rather than
	-- asking the registry, so a contract absent from this block answers nil for
	-- the whole session however well it is running -- which is exactly how the
	-- new fitting-room row refused every player with `appearance_unavailable` on
	-- a server where appearance was up and serving everybody else.
	M.Contracts.appearance = OPX.Api.Get('appearance')
	-- The vehicle keys contract: the key cut for every vehicle staff spawn, and
	-- the one `opx.admin.vehicle.key` hands the operator. Nil costs those two and
	-- nothing else.
	M.Contracts.vehiclekeys = OPX.Api.Get('vehiclekeys')

	if M.Contracts.inventory == nil then
		Open77.log.warn('[admin] no inventory contract: every weapon and bag command refuses, ' ..
			'and the menu greys their rows. Every other command is unaffected.')
	end

	for _, line in ipairs(M.Problems or {}) do Open77.log.warn('[admin] config: ' .. line) end

	if type(Open77.acl) ~= 'table' or type(Open77.acl.isAllowed) ~= 'function' then
		Open77.log.warn('[admin] Open77.acl is unavailable: the menu cannot grey out what the ' ..
			'ACL would refuse, and a travel mode is not revoked when its grant goes. Every ' ..
			'command is still gated by the host before its handler runs.')
	end

	M.Players.Register()
	M.Models.Register()
	M.Vehicles.Register()
	M.Inventory.Register()
	M.Weapons.Register()
	M.World.Register()
	M.Tags.Register()
	M.Combat.Register()
	M.Doors.Register()
	M.Characters.Register()
	M.Offline.Register()
	-- Last: the access map it sends lists what every other file registered.
	M.Menu.Register()

	Open77.log.info(('[admin] ready -- %d restricted commands; grant command.%s to open the menu')
		:format(#commands, M.OPENER))
end

--- Gives back every body this module hid or held, and takes down what it armed.
-- @author dop42
function M.Stop()
	M.Players.Release()
	M.Models.Release()
	M.Tags.Release()
	M.Doors.Release()
end
