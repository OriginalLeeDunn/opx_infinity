--- Staff rows on the target eye: yourself, players, vehicles, doors and the sky.
-- @author dop42
--
-- EVERY ROW ENDS IN A COMMAND LINE. `canInteract`, `checked` and `onSelect` are
-- plain functions called in-process -- that is what makes three dozen staff rows
-- affordable, where the same rows across a resource boundary were three dozen
-- host calls per pick -- but none of them decides anything. A row is offered when
-- the access map says the ACL would grant the command it sends, and the host
-- resolves that command again when the line arrives.
--
-- The checkbox states come from the SERVER (`bodies`) or from a replicated
-- snapshot, never from a guess: a box drawn from a guess flips the wrong way
-- exactly when it matters.

local M = OPX.Modules.Get('admin')

local Client = M.Client
local Text = OPX.Text
local Command = M.Command

M.Target = {}
local Target = M.Target

-- Rows sent in one registration.
--
-- One row per registration resume. With all grants enabled, two rows measured
-- 5,139 instructions in the current registry; one keeps the same rows available
-- at 4,173. The extra frames occur only when access changes, never per tick.
local BATCH = 1

-- Milliseconds before the first access request, then between two. A grant taken
-- away has to reach the eye without the operator opening the menu.
local ACCESS_FIRST_MS, ACCESS_EVERY_MS = 5000, 60000

-- Weather presets the sky lists, leaving room for the other sky rows.
local MAX_PRESETS = 8

-- The register call for each kind, and the order they are registered in.
-- THREE MORE KINDS THAN THIS MODULE USED TO REACH, and the inspector is why.
-- The eye distinguishes a networked prop, a vanilla world surface and an NPC,
-- and staff rows could be drawn on none of them -- so "what am I looking at"
-- could be asked of a door and a vehicle and of nothing else in the city.
--
-- `sky` STAYS LAST. `register` walks this list in order and yields between the
-- kinds; the order is otherwise only a reading order.
local REGISTERS = { self = 'RegisterSelf', player = 'RegisterPlayers',
	vehicle = 'RegisterVehicles', door = 'RegisterDoors',
	prop = 'RegisterProps', npc = 'RegisterNpcs', world = 'RegisterWorld',
	sky = 'RegisterSky' }
local KINDS = { 'self', 'player', 'vehicle', 'door', 'prop', 'npc', 'world', 'sky' }

-- Metres the rows reach, read once at start.
local distance = 10.0

-- The last access map, and whether the host could read the ACL at all.
local access, aclKnown = nil, false

-- Signature of the rows the eye holds for this module, nil for none.
local registered

-- Whether a registration is running, and whether another is wanted after it.
local syncing, dirty = false, false
local generation = 0

-- Whether the server last said this player's body is hidden, and which players
-- it said are held still. Nil until it has said.
local invisible, frozenIds = nil, nil

-- The ped each player is wearing, by player id, the one this player is wearing,
-- and whether the server said this build can change a model at all. Nil until it
-- has said.
local wornPeds, wornSelf, modelsUp = nil, nil, nil

-- The scheduler handle for the access poll.
local job

-- Every row, built in Start once the locale and the settings are readable.
local ROWS, BY_ID = {}, {}

-- Sends a command line, answering whether it left.
local function run(tokens)
	return Client.Execute(tokens)
end

-- A positive whole id the context's target names under a key, as text.
local function idOf(context, key)
	local target = type(context) == 'table' and context.target or nil
	local id = type(target) == 'table' and math.tointeger(target[key]) or nil
	if id == nil or id < 1 then return nil end
	return ('%d'):format(id)
end

-- The live snapshot of the door the context hit, or nil while the official door
-- service runs and owns every door.
local function doorOf(context)
	if Client.Running(M.NETWORKED_DOORS) then return nil end
	local target = type(context) == 'table' and context.target or nil
	local entity = type(target) == 'table' and target.engineEntity or nil
	local native = Open77.doors
	if type(entity) ~= 'string' or type(native) ~= 'table' or type(native.state) ~= 'function' then
		return nil
	end
	local read, door = pcall(native.state, entity)
	if not read or type(door) ~= 'table' or type(door.id) ~= 'string' then return nil end
	return door
end

-- A select that runs a command naming the targeted player.
local function onPlayer(name)
	return function(context)
		local id = idOf(context, 'playerId')
		return id ~= nil and run({ name, id })
	end
end

-- A select that runs a command naming the targeted vehicle, then extra words.
local function onVehicle(name, ...)
	local extra = { ... }
	return function(context)
		local id = idOf(context, 'vehicleId')
		if id == nil then return false end
		return run({ name, id, table.unpack(extra) })
	end
end

-- A check that the eye hit a door, a lift door only when lifts pass.
local function doorThere(lifts)
	return function(context)
		local door = doorOf(context)
		return door ~= nil and (lifts or not door.lift)
	end
end

-- A state reading one boolean field of the targeted door's snapshot.
local function doorReads(field)
	return function(context)
		local door = doorOf(context)
		if door == nil then return nil end
		return door[field] == true
	end
end

-- A select that sends the door the action undoing what one of its fields reads.
local function onDoorFlip(field, onAction, offAction)
	return function(context)
		local door = doorOf(context)
		if door == nil then return false end
		return run({ Command.WORLD_DOOR, door.id, door[field] == true and offAction or onAction })
	end
end

-- The states the checkboxes read.
local function noclipOn() return Client.IsNoclip() end
local function godOn() return Client.GodMode() end
local function invisibleOn() return invisible end
local function tagsOn() return M.Tags.IsShown() end
local function pvpOn() return M.Combat.IsPvp() end

local function frozenOn(context)
	local id = idOf(context, 'playerId')
	if id == nil or frozenIds == nil then return nil end
	return frozenIds[tonumber(id)] == true
end

local function lockedOn(context)
	local id = idOf(context, 'vehicleId')
	local vehicles = Open77.vehicles
	if id == nil or type(vehicles) ~= 'table' or type(vehicles.isLocked) ~= 'function' then
		return nil
	end
	local read, value = pcall(vehicles.isLocked, tonumber(id))
	if not read or type(value) ~= 'boolean' then return nil end
	return value
end

-- A select that runs a switch command with the word undoing what its state
-- reads, and with NO word -- so the server toggles -- when it reads nothing.
local function onFlip(state, name, key, ...)
	local extra = { ... }
	return function(context)
		local tokens = { name }
		if key ~= nil then
			local id = idOf(context, key)
			if id == nil then return false end
			tokens[2] = id
		end
		for _, word in ipairs(extra) do tokens[#tokens + 1] = word end
		local on = state(context)
		if type(on) == 'boolean' then tokens[#tokens + 1] = on and 'off' or 'on' end
		return run(tokens)
	end
end

--- Whether the server last said the operator's own body is hidden.
-- @author dop42
-- @return boolean|nil
function Target.IsInvisible()
	return invisible
end

--- Whether the server last said a player is held still.
-- @author dop42
-- @param playerId integer
-- @return boolean|nil
function Target.IsFrozen(playerId)
	if frozenIds == nil then return nil end
	return frozenIds[playerId] == true
end

--- The ped the server last said a player is wearing, or nil for their own body.
-- A row NAME out of `data/peds.lua` where the record is one this module knows,
-- and the bare record where another resource put it on.
-- @author dop42
-- @param playerId integer
-- @return string|nil
function Target.ModelOf(playerId)
	if wornPeds == nil then return nil end
	return wornPeds[playerId]
end

--- The ped the server last said THIS player is wearing, or nil.
-- Beside `ModelOf` rather than through it: the operator's own row is drawn
-- before the roster has named this client to itself.
-- @author dop42
-- @return string|nil
function Target.SelfModel()
	return wornSelf
end

--- Whether the server last said this build can change a player's model.
-- True before it has said: a row greyed on a guess is worse than one the host
-- refuses with a reason the operator can read.
-- @author dop42
-- @return boolean
function Target.HasModels()
	return modelsUp ~= false
end

-- Builds every row. Called once from Start, so the locale is readable and the
-- ── the inspector: what am I actually looking at ─────────────────────────────
--
-- THE OWNER: "avoir un categorie dev pour avoir des tool avoir le nom de props
-- get position etc possible aussi de l'utiliser avec alt".
--
-- IT REPORTS WHAT THE PLATFORM RETURNED AND NOT A LIST OF FIELDS THIS FILE
-- GUESSED. A curated read-out -- model, position, distance -- is a read-out that
-- is wrong the day the platform adds a field, and silently: the operator sees
-- four lines and has no way to know a fifth existed. So the walk below takes
-- every SCALAR in the ray's answer and in the thing it hit, sorts them, and
-- prints the lot. A dev tool that hides what it found is not one.
--
-- THIS IS NOT THE SCREEN THAT WAS REMOVED. That one offered garage and dealer
-- placement -- writes dressed as configuration, on a server whose configuration
-- is files -- and went on the owner's word. This reads and writes nothing: it
-- answers a question about the world and puts the answer on the clipboard.
--
-- Gated on `SELF_POS`, which is the grant that already means "may read where
-- things are" and is already registered and already in the access map. A new
-- ACL name for the same question would be a second grant an operator has to
-- know about, and yesterday's lesson was about exactly that.

-- The last inspection, so the Dev screen can show it and copy it again without
-- the operator having to aim a second time.
local lastInspection = nil

-- Numbers, strings and booleans read as themselves; everything else is named by
-- its type rather than dumped. A nested table in a ray answer is a vector, and
-- the three that matter are lifted out by name below.
local function scalar(value)
	local kind = type(value)
	if kind == 'number' then
		-- Coordinates to two places: an operator pasting one into a config wants
		-- the number they can read, not seventeen digits of float.
		if value % 1 ~= 0 then return ('%.2f'):format(value) end
		return tostring(value)
	end
	if kind == 'string' or kind == 'boolean' then return tostring(value) end
	return nil
end

-- A vector as one line, or nil when it is not one.
local function vector(value)
	if type(value) ~= 'table' then return nil end
	local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
	if x == nil or y == nil or z == nil then return nil end
	return ('%.2f, %.2f, %.2f'):format(x, y, z)
end

-- Every readable field of one table, as `name=value` lines, sorted so two
-- inspections of the same thing read the same way.
local function fieldsOf(source, prefix, into)
	if type(source) ~= 'table' then return end
	local names = {}
	for name in pairs(source) do names[#names + 1] = tostring(name) end
	table.sort(names)
	for _, name in ipairs(names) do
		local value = source[name]
		local line = scalar(value) or vector(value)
		if line ~= nil then into[#into + 1] = ('%s%s=%s'):format(prefix, name, line) end
	end
end

--- Everything the eye knows about one pick, as text.
-- @author dop42
-- @param context table
-- @return string
function Target.Inspect(context)
	local lines = {}
	fieldsOf(context, '', lines)
	-- The thing that was hit, prefixed so a field name that appears on both --
	-- `kind` does -- is not two lines claiming to be one.
	fieldsOf(type(context) == 'table' and context.target or nil, 'target.', lines)
	if #lines == 0 then return 'nothing readable under the cursor' end
	return table.concat(lines, '\n')
end

--- The last inspection this client made, or nil.
-- @author dop42
-- @return string|nil
function Target.LastInspection()
	return lastInspection
end

-- Copies one block and says whether it went. A host with no clipboard costs the
-- copy and not the answer: it is on screen and in the journal either way.
local function copyBlock(text)
	local clipboard = Open77.clipboard
	if type(clipboard) ~= 'table' or type(clipboard.setText) ~= 'function' then
		return false
	end
	local wrote, ok = pcall(clipboard.setText, text)
	return wrote and ok == true
end

-- What the inspector row does, wherever it is drawn.
local function inspect(context)
	local report = Target.Inspect(context)
	lastInspection = report
	local copied = copyBlock(report)

	-- THREE PLACES, ON PURPOSE. The toast is what the operator sees now and is
	-- one line; the clipboard is what they paste into a config; and the journal
	-- is the only one of the three an operator can read AFTER the fact, from
	-- another machine, which is what makes a report somebody sent you usable.
	Client.Toast(copied and 'admin.target.inspected' or 'admin.target.inspectedNoCopy',
		{ kind = tostring(type(context) == 'table' and context.kind or '?') },
		copied and 'success' or 'info')
	OPX.Note('admin', ('inspected %s -- %s'):format(
		tostring(type(context) == 'table' and context.kind or '?'),
		report:gsub('\n', ' | ')))
	return true
end

-- configured presets have been checked.
local function buildRows()
	local links = M.Section('LINKS')
	local rows = {
		{ id = 'selfNoclip', folder = 'move', kind = 'self', label = 'admin.target.noclip',
			icon = 'bolt', grant = Command.SELF_NOCLIP, state = noclipOn,
			select = onFlip(noclipOn, Command.SELF_NOCLIP) },
		{ id = 'selfGod', folder = 'state', kind = 'self', label = 'admin.target.god', icon = 'shield',
			grant = Command.SELF_GOD, state = godOn, select = onFlip(godOn, Command.SELF_GOD) },
		{ id = 'selfInvisible', folder = 'state', kind = 'self', label = 'admin.target.invisible',
			icon = 'hidden', grant = Command.SELF_INVISIBLE, state = invisibleOn,
			select = onFlip(invisibleOn, Command.SELF_INVISIBLE) },
		{ id = 'selfHeal', folder = 'state', kind = 'self', label = 'admin.target.heal', icon = 'heal',
			grant = Command.SELF_HEAL, select = function() return run({ Command.SELF_HEAL }) end },
		{ id = 'selfAmmo', folder = 'state', kind = 'self', label = 'admin.target.ammo', icon = 'ammo',
			grant = Command.WEAPON_AMMO,
			select = function() return run({ Command.WEAPON_AMMO, 'me' }) end },
		{ id = 'selfTags', folder = 'state', kind = 'self', label = 'admin.target.tags', icon = 'tag',
			grant = Command.SELF_TAGS, state = tagsOn, select = onFlip(tagsOn, Command.SELF_TAGS) },
		{ id = 'selfMap', folder = 'move', kind = 'self', label = 'admin.target.maptravel',
			icon = 'map', grant = Command.SELF_MAPTRAVEL,
			select = function() return run({ Command.SELF_MAPTRAVEL }) end },
		{ id = 'selfPos', folder = 'move', kind = 'self', label = 'admin.target.pos', icon = 'info',
			grant = Command.SELF_POS, select = function() return run({ Command.SELF_POS }) end },
		{ id = 'selfMenu', kind = 'self', label = 'admin.target.selfMenu', icon = 'gear',
			grant = M.OPENER, select = function() return M.Menu.OpenAt('self') end },

		{ id = 'playerManage', kind = 'player', label = 'admin.target.manage', icon = 'person',
			grant = M.OPENER, select = function(context)
				local id = idOf(context, 'playerId')
				return id ~= nil and M.Menu.OpenAt('player', tonumber(id))
			end },
		{ id = 'playerHeal', kind = 'player', label = 'admin.target.heal', icon = 'heal',
			grant = Command.PLAYER_HEAL, select = onPlayer(Command.PLAYER_HEAL) },
		{ id = 'playerRevive', kind = 'player', label = 'admin.target.revive', icon = 'heart',
			grant = Command.PLAYER_REVIVE, select = onPlayer(Command.PLAYER_REVIVE) },
		{ id = 'playerFreeze', kind = 'player', label = 'admin.target.freeze', icon = 'lock',
			grant = Command.PLAYER_FREEZE, state = frozenOn,
			select = onFlip(frozenOn, Command.PLAYER_FREEZE, 'playerId') },
		{ id = 'playerBag', kind = 'player', label = 'admin.target.bag', icon = 'box',
			grant = links.INVENTORY_OPEN,
			select = links.INVENTORY_OPEN and onPlayer(links.INVENTORY_OPEN) or nil },
		{ id = 'playerKick', folder = 'moderation', kind = 'player', label = 'admin.target.kick',
			-- `confirm = false`: these open the kick form, which confirms on its own.
			icon = 'door', danger = true, confirm = false, grant = Command.MODERATE_KICK,
			select = function(context)
				local id = idOf(context, 'playerId')
				return id ~= nil and M.Menu.OpenAt('player', tonumber(id), 'kick')
			end },
		{ id = 'playerBan', folder = 'moderation', kind = 'player', label = 'admin.target.ban',
			icon = 'ban', danger = true, confirm = false, grant = Command.MODERATE_BAN,
			select = function(context)
				local id = idOf(context, 'playerId')
				return id ~= nil and M.Menu.OpenAt('player', tonumber(id), 'ban')
			end },

		{ id = 'vehicleEnter', kind = 'vehicle', label = 'admin.target.enter', icon = 'door',
			grant = Command.VEHICLE_ENTER, select = onVehicle(Command.VEHICLE_ENTER) },
		{ id = 'vehicleRepair', kind = 'vehicle', label = 'admin.target.repair', icon = 'tool',
			grant = Command.VEHICLE_REPAIR, select = onVehicle(Command.VEHICLE_REPAIR, 'full') },
		{ id = 'vehicleBody', kind = 'vehicle', label = 'admin.target.repairVisual', icon = 'tool',
			grant = Command.VEHICLE_REPAIR, select = onVehicle(Command.VEHICLE_REPAIR, 'visual') },
		{ id = 'vehicleLock', kind = 'vehicle', label = 'admin.target.vehicleLocked', icon = 'lock',
			grant = Command.VEHICLE_FLAG, state = lockedOn,
			select = onFlip(lockedOn, Command.VEHICLE_FLAG, 'vehicleId', 'locked') },
		-- "on peut se donner la clé du véhicule précis": the id the eye landed on,
		-- and the server resolves that vehicle's plate itself.
		{ id = 'vehicleKey', kind = 'vehicle', label = 'admin.target.vehicleKey', icon = 'key',
			grant = Command.VEHICLE_KEY, select = onVehicle(Command.VEHICLE_KEY) },
		{ id = 'vehicleRemove', kind = 'vehicle', label = 'admin.target.removeVehicle', icon = 'trash',
			danger = true, grant = Command.VEHICLE_REMOVE, select = onVehicle(Command.VEHICLE_REMOVE) },

		{ id = 'doorOpen', kind = 'door', label = 'admin.target.doorOpen', icon = 'door',
			grant = Command.WORLD_DOOR, check = doorThere(false), state = doorReads('open'),
			select = onDoorFlip('open', 'open', 'close') },
		{ id = 'doorLock', kind = 'door', label = 'admin.target.doorLocked', icon = 'lock',
			grant = Command.WORLD_DOOR, check = doorThere(true), state = doorReads('locked'),
			select = onDoorFlip('locked', 'lock', 'unlock') },
		{ id = 'doorReset', kind = 'door', label = 'admin.target.doorReset', icon = 'refresh',
			grant = Command.WORLD_DOOR,
			check = function(context) return doorOf(context) ~= nil end,
			select = function(context)
				local door = doorOf(context)
				return door ~= nil and run({ Command.WORLD_DOOR, door.id, 'reset' })
			end },
		{ id = 'doorCopy', kind = 'door', label = 'admin.target.doorCopy', icon = 'tag',
			grant = Command.WORLD_DOOR,
			check = function(context) return doorOf(context) ~= nil end,
			select = function(context)
				local door = doorOf(context)
				local clipboard = Open77.clipboard
				if door == nil or type(clipboard) ~= 'table'
					or type(clipboard.setText) ~= 'function' then
					return false
				end
				local read, copied = pcall(clipboard.setText, door.id)
				local ok = read and copied == true
				Client.Toast(ok and 'admin.target.doorCopied' or 'admin.target.clipboardMissing',
					{ door = door.id }, ok and 'success' or 'error')
				return ok
			end },


		-- ── THE INSPECTOR, ON EVERY KIND THE EYE CAN NAME ───────────────────
		-- "possible aussi de l'utiliser avec alt". One row per kind rather than
		-- one row: `kind` is how this module's registration batches, so a single
		-- entry could only ever be drawn on one of them.
		--
		-- `folder` puts all eight under one heading, so they read as one tool
		-- rather than as eight rows that happen to share a name.
		{ id = 'devInspect_self', kind = 'self', folder = 'dev',
			label = 'admin.target.inspect', icon = 'info',
			grant = Command.SELF_POS, select = inspect },
		{ id = 'devInspect_player', kind = 'player', folder = 'dev',
			label = 'admin.target.inspect', icon = 'info',
			grant = Command.SELF_POS, select = inspect },
		{ id = 'devInspect_vehicle', kind = 'vehicle', folder = 'dev',
			label = 'admin.target.inspect', icon = 'info',
			grant = Command.SELF_POS, select = inspect },
		{ id = 'devInspect_door', kind = 'door', folder = 'dev',
			label = 'admin.target.inspect', icon = 'info',
			grant = Command.SELF_POS, select = inspect },
		{ id = 'devInspect_prop', kind = 'prop', folder = 'dev',
			label = 'admin.target.inspect', icon = 'info',
			grant = Command.SELF_POS, select = inspect },
		{ id = 'devInspect_npc', kind = 'npc', folder = 'dev',
			label = 'admin.target.inspect', icon = 'info',
			grant = Command.SELF_POS, select = inspect },
		{ id = 'devInspect_world', kind = 'world', folder = 'dev',
			label = 'admin.target.inspect', icon = 'info',
			grant = Command.SELF_POS, select = inspect },
		-- NOT ON THE SKY, and the reason is a real cost rather than taste. The sky
		-- list is bounded and `MAX_PRESETS` is deliberately sized to leave room for
		-- the other sky rows -- so an eighth row there pushes a WEATHER PRESET off
		-- the list, which the suite caught within a minute. Losing `sandstorm` to a
		-- dev row is a bad trade, and inspecting the sky names no object anyway:
		-- the ray answers an origin and a direction and there is nothing there.
		{ id = 'skyNoclip', kind = 'sky', label = 'admin.target.noclip', icon = 'bolt',
			grant = Command.SELF_NOCLIP, state = noclipOn,
			select = onFlip(noclipOn, Command.SELF_NOCLIP) },
		{ id = 'skyPvp', kind = 'sky', label = 'admin.target.pvp', icon = 'weapon',
			grant = Command.WORLD_PVP, state = pvpOn, select = onFlip(pvpOn, Command.WORLD_PVP) },
	}

	local listed = 0
	local presets = M.Settings.WEATHER_PRESETS
	for _, preset in ipairs(type(presets) == 'table' and presets or {}) do
		if listed < MAX_PRESETS and type(preset) == 'string' and preset:match('^[%w_%-]+$') then
			listed = listed + 1
			local key = 'admin.weather.' .. preset
			rows[#rows + 1] = { id = 'skyWeather_' .. preset, folder = 'weather', kind = 'sky',
				icon = 'weather', grant = links.WEATHER_SET,
				text = function()
					local name = locale(key)
					if name == key then name = preset end
					return locale('admin.target.weatherPreset', { preset = name })
				end,
				select = links.WEATHER_SET and function() return run({ links.WEATHER_SET, preset }) end
					or nil }
		end
	end
	rows[#rows + 1] = { id = 'skyWeatherNext', folder = 'weather', kind = 'sky',
		label = 'admin.target.weatherNext', icon = 'refresh', grant = links.WEATHER_NEXT,
		select = links.WEATHER_NEXT and function() return run({ links.WEATHER_NEXT }) end or nil }
	rows[#rows + 1] = { id = 'skyTime', folder = 'weather', kind = 'sky', label = 'admin.target.time',
		icon = 'clock',
		grant = links.TIME, select = function() return M.Menu.OpenAt('time') end }

	ROWS, BY_ID = {}, {}
	for _, definition in ipairs(rows) do
		-- A row whose command is switched off in LINKS has no select at all and is
		-- dropped here rather than registered and refused later.
		if definition.select ~= nil then
			ROWS[#ROWS + 1] = definition
			BY_ID[definition.id] = definition
		end
	end
end

-- Whether the last access map grants a command. The opener's grant is what makes
-- a player staff at all, so nothing is offered without it.
local function granted(name)
	if access == nil or access[M.OPENER] ~= true or type(name) ~= 'string' or name == '' then
		return false
	end
	return not aclKnown or access[name] == true
end

-- The row an observation names, or nil for anything that is not one of ours or
-- is no longer granted.
local function rowOf(context)
	if type(context) ~= 'table' then return nil end
	local option = type(context.option) == 'table' and context.option or nil
	local data = option and type(option.data) == 'table' and option.data or nil
	local row = data and BY_ID[data.row] or nil
	if row == nil or not granted(row.grant) then return nil end
	return row
end

--- The grants the last access map REFUSED, once each, in the order the rows ask
--- for them.
--
-- THE OWNER REPORTED THIS AS A MISSING FEATURE AND IT IS A MISSING GRANT.
-- "pour le target quand je interagis avec le ciel j'ai pas les options admin pour
-- modifier la meteo etc." -- the ten weather and time rows were not drawn on the
-- sky, and nothing anywhere said why.
--
-- The rows were built, the config had the command names, and the server's access
-- map did ask the ACL about them -- `menuCommands` in `server/menu.lua` walks
-- every value in LINKS as well as this module's own commands, so the first guess,
-- that the map covered only admin's own, is wrong. The ACL simply said no.
-- `opx.weather.set`, `opx.weather.next` and `opx.time` are the WEATHER module's
-- commands, and a staff role written the way `docs/MANUAL.md` writes one --
-- `command.opx.admin` plus `command.opx.admin.*` -- holds neither. So `granted`
-- correctly dropped every row that ends in one, and the sky was left with the two
-- rows whose grants ARE admin's own, Noclip and PvP. The same mechanism takes
-- `playerBag` off a player, which ends in `opx.inventory.open`.
--
-- The MENU does not have this problem, and the difference is the whole of the
-- fix: it draws the row and greys it with "Refusé" (`denied` in `client/menu.lua`),
-- so an operator can see that the row exists and that their role is what is in
-- the way. The eye has no greyed state -- `Registry.Matches` refuses a row that
-- is not enabled, so a row it cannot run is a row it cannot draw -- and an
-- omission on a list nobody has ever seen complete is indistinguishable from a
-- feature that was never written. Hence this: the eye cannot show the operator,
-- so it tells the SERVER, in the one line it already sends per registration, and
-- the names it prints are exactly the `command.<name>` entries to add to
-- `acl.jsonc`.
local function refusals()
	local names, seen = {}, {}
	for _, row in ipairs(ROWS) do
		local grant = row.grant
		if type(grant) == 'string' and grant ~= '' and not seen[grant] and not granted(grant) then
			seen[grant] = true
			names[#names + 1] = grant
		end
	end
	return names
end

-- The signature of what the access map grants: the granted row ids. Cheap, and
-- what `register` compares first -- an access refresh arrives every time the
-- operator leaves the menu's root, and almost never changes a grant.
local function grantedSignature()
	local ids = {}
	for _, row in ipairs(ROWS) do
		if granted(row.grant) then ids[#ids + 1] = row.id end
	end
	return table.concat(ids, ',')
end

-- The definitions the access map grants, by kind, and their signature.
local function wanted(token)
	local byKind, ids = {}, {}
	-- Once, not once per row: the same word heads every folder.
	local heading = locale('admin.target.group')
	for index, row in ipairs(ROWS) do
		-- Built on the registration thread, a few rows a resume: the first
		-- registration builds every granted row, about 8,000 instructions in one go.
		if index % 8 == 0 and coroutine.isyieldable() then Wait(0) end
		if token ~= generation then return {}, '' end
		if granted(row.grant) then
			byKind[row.kind] = byKind[row.kind] or {}
			local group = heading
			if row.folder then
				group = ('%s/%s'):format(group, locale('admin.target.folder.' .. row.folder))
			end
			table.insert(byKind[row.kind], {
				id = 'admin_' .. row.id,
				label = row.text and row.text() or locale(row.label),
				group = group,
				icon = row.icon,
				danger = row.danger == true,
				-- A danger row asks for a second click on the eye unless it says
				-- otherwise (the vehicle remove does not; kick and ban open a form).
				confirm = row.confirm,
				distance = distance,
				order = 100 + index,
				-- Plain functions, called in-process. This is what makes three dozen
				-- rows cost a table lookup each instead of a host call each.
				canInteract = row.check and function(context)
					local found = rowOf(context)
					if found == nil then return false end
					return found.check == nil or found.check(context) == true
				end or nil,
				checked = row.state and function(context)
					local found = rowOf(context)
					if found == nil or found.state == nil then return nil end
					local on = found.state(context)
					if type(on) ~= 'boolean' then return nil end
					return on
				end or nil,
				onSelect = function(context)
					local found = rowOf(context)
					if found == nil then return false end
					if found.check ~= nil and found.check(context) ~= true then return false end
					return found.select(context) == true
				end,
				data = { row = row.id },
			})
			ids[#ids + 1] = row.id
		end
	end
	return byKind, table.concat(ids, ',')
end

-- Tells the server how the registration went, so it lands in the server log: a
-- row refused on one machine is otherwise only visible on that machine.
local function report(line)
	TriggerServerEvent(M.Event.TARGET_REPORT, line)
end

-- Replaces this module's rows on the eye with the granted ones.
local function register(contract, byKind, signature, token)
	if token ~= generation then return false end
	if signature == registered then return true end
	local cleared = contract.Clear(M.OWNER)
	if not cleared.ok then
		report('clear refused: ' .. tostring(cleared.error))
		return false
	end
	registered = ''
	for _, kind in ipairs(KINDS) do
		local rows = byKind[kind] or {}
		-- One resume per kind, and the whole of the fix for a defect that read as a
		-- missing feature for days. Every row this module owns was built AND
		-- registered inside the single resume that delivers the access map, and that
		-- resume ran out of instruction budget partway down this list: the coroutine
		-- unwound with no error, no log and no refusal, leaving the kinds registered
		-- so far on the eye and the rest never registered at all. `sky` is last in
		-- KINDS, so `sky` is what the operator never saw -- ALT on themselves drew
		-- rows, ALT on the sky drew nothing, and every explanation that starts at the
		-- eye (the raycast, `Matches`, the ACL) is reasoning about rows that were
		-- never put there.
		--
		-- The journal named it by what it did NOT say: twelve rows live on the eye,
		-- and the closing `report` below -- which is unconditional on the way out --
		-- never sent once across a dozen restarts. Registration runs on an access
		-- change, not per tick, so a frame per registration call costs nothing.
		for first = 1, #rows, BATCH do
			-- PER BATCH AND NOT PER KIND, which is where this line started and
			-- where it was not quite enough. A kind with more than BATCH rows --
			-- `self` has ten -- registered two batches in one resume, and the
			-- journal caught the result the hour the inspector went in, on a
			-- client that was simply a little further into its frame:
			--
			--   [admin] target rows, player 4: staff rows not registered:
			--   modules/target/shared/model.lua:143: script execution budget exceeded
			--
			-- It was reported rather than silent because the `pcall` around this
			-- is there, which is the whole argument for the `pcall` -- but a
			-- registration that reports itself dying is still a client with no
			-- staff rows. One resume per REGISTRATION CALL costs a frame only
			-- when a kind is big enough to need two.
			Wait(0)
			if token ~= generation then return false end
			local batch = {}
			for index = first, math.min(first + BATCH - 1, #rows) do batch[#batch + 1] = rows[index] end
			local answer = contract[REGISTERS[kind]](M.OWNER, batch)
			if not answer.ok then
				local line = ('the %s staff rows were not registered: %s')
					:format(kind, tostring(answer.error))
				Open77.log.warn('[admin] ' .. line)
				report(line)
				contract.Clear(M.OWNER)
				registered = nil
				return false
			end
		end
	end
	registered = signature
	-- The closing line walks every row again for the grants it dropped; it does
	-- not need to share a resume with the last batch.
	if coroutine.isyieldable() then Wait(0) end
	local total = 0
	for _, rows in pairs(byKind) do total = total + #rows end
	-- THE ROWS THAT ARE NOT THERE ARE THE HALF WORTH READING. A count alone said
	-- "26 staff rows on the eye" whether that was all 37 this module has or, as it
	-- was for the operator who reported the missing weather, 26 of them -- so the
	-- line was true and answered nothing. `refusals` names the grants, and a name
	-- here is the `command.<name>` to put in `acl.jsonc`.
	local missing = refusals()
	if #missing == 0 then
		report(('%d staff rows on the eye'):format(total))
	else
		report(('%d staff rows on the eye; %d hidden, this ACL does not grant: %s')
			:format(total, #ROWS - total, table.concat(missing, ' ')))
	end
	return true
end

-- Brings the eye's rows in line with the access map, one registration at a time.
local function sync()
	local contract = Client.Contract('target')
	if contract == nil then
		registered = nil
		return
	end
	if syncing then
		dirty = true
		return
	end
	syncing = true
	local token = generation
	-- Registration runs on a thread of its own, and the `Wait(0)` in `register` is
	-- the only reason it needs one. `Target.Access` is a net event handler, and
	-- whether a handler may yield is the host's business rather than this module's
	-- -- the test suite calls it straight, with no coroutine under it at all, and
	-- said so the moment the yield went in. A thread the host started can always
	-- yield, so every kind gets a resume, and the `syncing`/`dirty` pair that was
	-- already here for re-entrancy is exactly the guard an asynchronous sync wants.
	CreateThread(function()
	repeat
		if token ~= generation then return end
		dirty = false
		-- UNCHANGED GRANTS COST A SIGNATURE, NOT A REBUILD. Building every
		-- definition -- three dozen rows, three closures and a few catalogue
		-- reads each -- ran before `register` could notice nothing had changed,
		-- and it ran in the same resume as the clear and the first batch. Now
		-- the ids are compared first, and a real change builds, yields, and then
		-- registers on a fresh resume.
		if registered == nil or grantedSignature() ~= registered then
			local built, byKind, signature = pcall(wanted, token)
			if built then
				Wait(0)
				-- Protected for the reason the loop above yields: `register` raising is how
				-- this module lost two fifths of its rows in silence. A raise is now a line
				-- in the server log instead of an absence in it.
				local done, failure = pcall(register, contract, byKind, signature, token)
				if not done then
					registered = nil
					Open77.log.warn('[admin] staff rows: ' .. tostring(failure))
					report('staff rows not registered: ' .. tostring(failure))
				end
			else
				registered = nil
				Open77.log.warn('[admin] staff rows: ' .. tostring(byKind))
				report('staff rows not built: ' .. tostring(byKind))
			end
		end
	until not dirty or token ~= generation
	if token == generation then syncing = false end
	end)
end

--- Takes an access map from the opener or from a refresh, and registers what it
--- grants.
-- @author dop42
-- @param payload table
function Target.Access(payload)
	if type(payload) ~= 'table' or type(payload.access) ~= 'table' then return end
	access, aclKnown = payload.access, payload.aclKnown == true
	sync()
end

--- Builds the rows, wires the body states and starts the access poll.
-- @author dop42
function Target.Start()
	distance = math.min(12, math.max(1, Text.Finite(M.Section('TARGET').DISTANCE) or 10))
	buildRows()

	RegisterNetEvent(M.Event.BODIES, function(payload)
		if type(payload) ~= 'table' then return end
		local held = {}
		-- An empty list may not survive the trip as a table: none reads as nobody
		-- held, which is the truthful answer either way.
		for _, value in ipairs(type(payload.frozen) == 'table' and payload.frozen or {}) do
			local id = math.tointeger(tonumber(value) or 0)
			if id ~= nil and id > 0 then held[id] = true end
		end
		local peds = {}
		for _, row in ipairs(type(payload.worn) == 'table' and payload.worn or {}) do
			local id = type(row) == 'table' and math.tointeger(tonumber(row.id) or 0) or nil
			local ped = type(row) == 'table' and M.Trimmed(row.ped, 64) or nil
			if id ~= nil and id > 0 and ped ~= nil then peds[id] = ped end
		end
		invisible, frozenIds, wornPeds = payload.invisible == true, held, peds
		wornSelf = M.Trimmed(payload.wornSelf, 64)
		modelsUp = payload.models ~= false
		M.Menu.Refresh()
	end)

	-- A grant taken away has to reach the eye without the operator opening the
	-- menu, so the access map is asked for on its own schedule.
	local first = true
	job = OPX.Scheduler.Every('admin.target.access', ACCESS_FIRST_MS, function()
		TriggerServerEvent(M.Event.REFRESH, 'access')
		if first then
			first = false
			OPX.Scheduler.Cancel(job)
			job = OPX.Scheduler.Every('admin.target.access', ACCESS_EVERY_MS, function()
				TriggerServerEvent(M.Event.REFRESH, 'access')
			end)
		end
	end)
end

--- Takes every staff row off the eye.
-- @author dop42
function Target.Stop()
	generation = generation + 1
	syncing, dirty = false, false
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	local contract = Client.Contract('target')
	if contract ~= nil then contract.Clear(M.OWNER) end
	registered = nil
end
