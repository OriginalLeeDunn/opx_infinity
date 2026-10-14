--- Saved destinations, announcements, and the roster, status and audit reads.
-- @author dop42

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Text = OPX.Text
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit
local inform = Server.Inform
local count = Server.Count

M.World = {}
local World = M.World

-- Shape version of the destinations carried across a reload. A reload under
-- `reload_policy "reconnect"` still keeps the host's state store, so a spot saved
-- in game survives one; a restart clears it, which is what `(until restart)` in
-- the list says.
local STATE_PROTOCOL = 1

-- Every destination by name, configured and added in game, and the in-game ones
-- on their own so that a reseed keeps them.
local locations, runtime = {}, {}

-- Host clock when this module started, for the uptime line.
local startedAtMs = 0

-- Builds one destination from typed or stored values, nil when unusable.
local function locationOf(name, label, x, y, z, heading, isRuntime)
	name = Text.Slug(name)
	x, y, z = Text.Finite(x), Text.Finite(y), Text.Finite(z)
	if name == nil or x == nil or y == nil or z == nil then return nil end
	return { name = name, label = M.Trimmed(label, 48) or name, x = x, y = y, z = z,
		heading = Text.Finite(heading) or 0.0, runtime = isRuntime }
end

-- Rebuilds the list from config, then lays the in-game additions over it.
local function seed()
	locations = {}
	local configured = M.Settings.LOCATIONS
	for position, row in ipairs(type(configured) == 'table' and configured or {}) do
		local location = type(row) == 'table'
			and locationOf(row.NAME, row.LABEL, row.X, row.Y, row.Z, row.HEADING, false) or nil
		if location == nil then
			Open77.log.warn(('[admin] LOCATIONS #%d ignored: NAME must be a slug and X, Y, Z numbers')
				:format(position))
		else
			locations[location.name] = location
		end
	end
	for name, row in pairs(runtime) do locations[name] = row end
end

-- The namespace this module carries under. `Open77.state` holds ONE value per
-- resource -- not a key-value store -- and this module is not the only writer
-- in it: `modules/weather/server/state.lua` carries the world clock, its epoch
-- and its preset. Writing the blob whole, which is what this did, meant
-- whichever wrote last destroyed the other's state: place a destination and the
-- clock restarts on the next reload, let the weather roll and the destinations
-- are gone. Neither crashed, because each refuses a blob that does not carry
-- its own protocol number -- so the loser simply cold-started, and the only
-- sign of it was weather logging "carried state ignored: protocol nil is not 1"
-- against a blob that was never weather's. `OPX.Carry` is the one blob divided
-- up, a namespace per writer.
local CARRY = 'admin.world'

-- Hands the in-game destinations to the host's reload store.
local function save()
	local list = {}
	for _, row in pairs(runtime) do list[#list + 1] = row end
	OPX.Carry.Save(CARRY, { protocol = STATE_PROTOCOL, locations = list })
end

-- Adopts the destinations carried across a reload, when the shape matches.
local function restore()
	local carried = OPX.Carry.Load(CARRY)
	if type(carried) ~= 'table' or carried.protocol ~= STATE_PROTOCOL then return end
	for _, row in ipairs(type(carried.locations) == 'table' and carried.locations or {}) do
		local location = type(row) == 'table'
			and locationOf(row.name, row.label, row.x, row.y, row.z, row.heading, true) or nil
		if location then runtime[location.name] = location end
	end
end

--- Every destination, sorted by name, as the menu draws it.
-- @author dop42
-- @return table[]
function World.Locations()
	local list = {}
	for _, row in pairs(locations) do list[#list + 1] = row end
	table.sort(list, function(left, right) return left.name < right.name end)
	return list
end

--- Builds one roster row as the server sees the player.
-- @author dop42
-- @param playerId Source
-- @param origin table|nil the operator's position, for the distance
-- @return table|nil
function World.RosterRow(playerId, origin)
	local user = Server.NameOf(playerId)
	if user == nil then return nil end
	local position = Server.PositionOf(playerId)
	local life = Server.LifeOf(playerId)
	local state = 'loading'
	if life ~= nil then
		local admitted = Server.Admit(playerId)
		local deadRead, dead = pcall(Open77.players.isDead, playerId)
		state = not admitted and 'gate' or (deadRead and dead == true) and 'down' or 'up'
	end
	local distance
	-- Same bucket only: a distance across two buckets is a number with no meaning.
	if origin and position and origin.bucket == position.bucket then
		distance = math.floor(math.sqrt(OPX.Math.DistanceSquared(position, origin)) + 0.5)
	end
	-- THE CHARACTER IS THE NAME. A roster is read to find a person, and the person
	-- everybody in the city has been talking to is the character, not the account
	-- behind it. The account is not dropped for it -- it rides beside as `user`, so
	-- a row can still be matched to a ban or an audit line -- and it is what `name`
	-- falls back to for a slot that has loaded no character yet, which is every
	-- slot for the first few seconds.
	local character = Server.CharacterOf(playerId)
	return { id = playerId, name = character or user, user = character and user or nil,
		citizenId = Server.CitizenBagOf(playerId), state = state,
		bucket = position and position.bucket or 0, distance = distance }
end

--- The whole roster as seen from one operator, or from nowhere.
-- @author dop42
-- @param playerId Source|nil
-- @return table[]
function World.Roster(playerId)
	local origin = playerId and playerId > 0 and Server.PositionOf(playerId) or nil
	local rows = {}
	for _, id in ipairs(Server.PlayerIds()) do
		local row = World.RosterRow(id, origin)
		if row then rows[#rows + 1] = row end
	end
	return rows
end

-- One line naming what this module can and cannot reach, for the status report.
local function contractLine()
	local parts = {}
	for _, name in ipairs({ 'character', 'inventory', 'vehicles', 'downed', 'prompts' }) do
		parts[#parts + 1] = ('%s=%s'):format(name,
			Server.Contract(name) ~= nil and 'yes' or 'no')
	end
	local read, doors = pcall(GetResourceState, M.NETWORKED_DOORS)
	parts[#parts + 1] = ('%s=%s'):format(M.NETWORKED_DOORS,
		read and tostring(doors or '?') or '?')
	return table.concat(parts, '  ')
end

--- Registers the destination, announcement and read commands.
-- @author dop42
function World.Register()
	startedAtMs = Server.NowMs()
	restore()
	seed()

	Server.Command(Command.PLAYER_SEND, {
		help = 'admin.help.send',
		params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' },
			{ name = 'location', help = 'admin.help.locationName' } },
		handler = function(source, args, raw)
			if count(args) ~= 2 then return answer(source, raw, false, 'admin.usage.send') end
			local playerId = Server.Target(source, raw, args[1], 'admin.player.send')
			if playerId == nil then return end
			local location = locations[tostring(args[2]):lower()]
			if location == nil then return refuse(source, raw, 'unknown_location') end
			local placed, code, reason = Server.Place(playerId,
				{ x = location.x, y = location.y, z = location.z }, location.heading, nil, 'send')
			audit(source, 'admin.player.send', placed, playerId,
				('%s %s'):format(location.name, code or ''))
			if not placed then return refuse(source, raw, code, { reason = reason, id = playerId }) end
			inform(source, playerId, 'admin.toast.sent', { label = location.label })
			answer(source, raw, true, 'admin.done.sent',
				{ id = playerId, name = Server.LabelOf(playerId) or '?', label = location.label })
		end,
	})

	Server.Command(Command.WORLD_LOC_ADD, {
		help = 'admin.help.locAdd',
		params = { { name = 'name', help = 'admin.help.locationName' },
			{ name = 'label', help = 'admin.help.locationLabel', optional = true } },
		inGame = true,
		handler = function(source, args, raw)
			local name = Text.Slug(args[1])
			if name == nil then return refuse(source, raw, 'bad_location_name') end
			local position = Server.PositionOf(source)
			if position == nil then return refuse(source, raw, 'no_position') end
			local label = M.Trimmed(Text.Rest(args, 2), 48) or name
			runtime[name] = { name = name, label = label, x = position.x, y = position.y,
				z = position.z, heading = 0.0, runtime = true }
			save()
			seed()
			audit(source, 'admin.world.loc.add', true, nil,
				('%s %.1f %.1f %.1f'):format(name, position.x, position.y, position.z))
			answer(source, raw, true, 'admin.done.locAdded', { name = name, label = label })
		end,
	})

	Server.Command(Command.WORLD_LOC_REMOVE, {
		help = 'admin.help.locRemove', params = { { name = 'name', help = 'admin.help.locationName' } },
		handler = function(source, args, raw)
			local name = Text.Slug(args[1])
			if name == nil or locations[name] == nil then
				return refuse(source, raw, 'unknown_location')
			end
			-- A configured row is not this command's to remove: it would come back
			-- at the next start and look like the command had failed.
			if runtime[name] == nil then return refuse(source, raw, 'seeded_location') end
			runtime[name] = nil
			save()
			seed()
			audit(source, 'admin.world.loc.remove', true, nil, name)
			answer(source, raw, true, 'admin.done.locRemoved', { name = name })
		end,
	})

	-- When the last announcement went out, from anybody. See the floor below.
	local lastAnnounced = nil

	Server.Command(Command.WORLD_ANNOUNCE, {
		help = 'admin.help.announce', params = { { name = 'text', help = 'admin.help.announceText' } },
		handler = function(source, args, raw)
			local settings = M.Section('ANNOUNCE')
			local text = M.Trimmed(Text.Rest(args, 1),
				math.floor(M.Bounded('ANNOUNCE.MAX_CHARACTERS', settings.MAX_CHARACTERS, 1, 2000, 240)))
			if text == nil then return refuse(source, raw, 'empty_text') end

			-- ONE ANNOUNCEMENT AT A TIME, server-wide. The only floor used to be the
			-- per-operator action floor (400ms), so one operator could put two and a
			-- half full-screen messages a second on every player, each with two
			-- stingers and a chat line, and two operators twice that. The console is
			-- not held to it: an operator at the console is the server.
			local floorMs = math.floor(M.Bounded('ANNOUNCE.COOLDOWN_MS', settings.COOLDOWN_MS,
				0, 600000, 10000))
			local now = Server.NowMs()
			if source > 0 and lastAnnounced ~= nil and now - lastAnnounced < floorMs then
				return refuse(source, raw, 'too_fast')
			end
			lastAnnounced = now

			local lifetime = math.floor(OPX.Tune.Number('ADMIN_ANNOUNCE_MS', 1000))
			local title = locale('admin.announce.title')
			local delivered = 0
			for _, playerId in ipairs(Server.PlayerIds()) do
				-- OUR OWN OVERLAY, NOT THE PLATFORM'S NOTIFICATION PACKAGE, and the
				-- reason is the stingers: they play before and after the message, and
				-- only the page that owns the toast's clock can hold the message back
				-- until the first has finished. `OPX.Notify` hands the sentence to a
				-- package this runtime does not draw, so it could be told when to
				-- appear but never when to wait.
				--
				-- Nothing about the presentation crosses the wire: the text and how long
				-- it stays are facts every client needs, and which clips sit around it
				-- is a local config, so a client with no clips still gets the message.
				-- Best effort per player: one client that cannot be reached must not
				-- stop the announcement reaching the rest.
				local sent = pcall(TriggerClientEvent, M.Event.ANNOUNCE, playerId,
					{ text = text, durationMs = lifetime })
				if sent then delivered = delivered + 1 end
				-- The chat line goes out on core's own answer channel rather than a
				-- chat module's, so that whatever draws a chat log draws it and this
				-- module names nobody.
				if settings.CHAT ~= false then
					pcall(OPX.CommandResult, playerId, true, ('%s: %s'):format(title, text))
				end
			end
			audit(source, 'admin.world.announce', true, nil, text)
			answer(source, raw, true, 'admin.done.announced', { count = delivered })
		end,
	})

	Server.Command(Command.READ_STATUS, {
		help = 'admin.help.readStatus', read = true,
		handler = function(source, _, raw)
			local ids = Server.PlayerIds()
			local up = 0
			for _, playerId in ipairs(ids) do
				if Server.Admit(playerId) then up = up + 1 end
			end
			local lines = {
				locale('admin.status.summary', {
					players = #ids, up = up, vehicles = M.Vehicles.SpawnedCount(),
					minutes = math.floor((Server.NowMs() - startedAtMs) / 60000),
				}),
				contractLine(),
			}
			answer(source, raw, true, 'admin.text.lines', { lines = table.concat(lines, '\n') })
		end,
	})

	Server.Command(Command.READ_AUDIT, {
		help = 'admin.help.readAudit',
		params = { { name = 'count', help = 'admin.help.auditCount', optional = true } }, read = true,
		handler = function(source, args, raw)
			local wanted = math.min(40, math.max(1, Text.Integer(args[1]) or 15))
			local entries = Server.Recent(wanted)
			local lines = { locale('admin.audit.header', { count = #entries }) }
			local atMs = Server.NowMs()
			for _, entry in ipairs(entries) do
				lines[#lines + 1] = locale(entry.ok and 'admin.audit.row' or 'admin.audit.rowFailed', {
					seq = entry.seq,
					minutes = math.floor((atMs - entry.atMs) / 60000),
					actor = entry.actorName,
					event = entry.event,
					target = entry.target and ('%s (%d)'):format(entry.targetName or '?', entry.target)
						or '-',
					detail = entry.detail,
				})
			end
			answer(source, raw, true, 'admin.text.lines', { lines = table.concat(lines, '\n') })
		end,
	})
end
