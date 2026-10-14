--- The staff tool: find a player, get to them, fix them, move them, arm them,
--- hand them a car, or remove them from the server.
-- @author dop42
--
-- THIS MODULE ADDS NO AUTHORITY OF ITS OWN. Every staff action is a restricted
-- command, and the host resolves `command.<name>` against `acl.jsonc` BEFORE the
-- handler runs. Nothing here checks a permission and nothing here should: the
-- host has already decided, and a second check would only diverge from it. The
-- menu, the eye and the forms are HINTS -- they grey out what the ACL would
-- refuse, and the server re-derives everything when the command arrives. A
-- client that drew a row it should not have still gets refused by the host.
--
-- `OPX.Command.Register(name, { restricted = true }, handler)` is the only door.
-- It owns the ACL flag and the suggestion list, and it only offers a restricted
-- command to a player the ACL would let run it.
--
-- WHAT IT OWNS AND WHAT IT DOES NOT. No character data: what a character IS
-- belongs to `character`, what it CARRIES to `inventory`, the sky to `weather`.
-- The menu drives their commands by name through `LINKS` rather than calling
-- their contracts, because a contract call from a client is no permission check.
-- Nothing is written to the database, so there is no `server/storage.lua`.
--
-- Every contract but `character` is optional and each is asked for with
-- `OPX.Api.Get`. An answer of nil costs one logged line and one feature; the
-- commands keep working from the chat box and the console either way. That is
-- the whole point of a staff tool: it must not refuse to start because the menu
-- is missing at the moment somebody has to be removed from the server.
--
-- ONE THING THE CONTRACTS CANNOT SAY. `inventory`'s item view carries
-- `weapon = true` and `ammo = true` and nothing else -- not a weapon's class, not
-- the ammunition item it loads, not an ammunition item's full load. So the
-- weapon screens list weapons in one paged list rather than by class, and
-- ammunition is named by its own item rather than inferred from a weapon. Adding
-- `class`, `ammoName` and `ammoMax` to `Catalog.ViewOf` would restore both.

local M = OPX.Modules.Declare{
	id = 'admin',
	side = 'both',
	fatal = false,
	-- A citizen id is only a name until `character` says who holds it, and every
	-- audit line is attributed through it.
	requires = { 'character' },
	-- Each of these is one feature. `menu`, `form` and `target` are the three
	-- surfaces; `inventory` is the bag and weapon rows; `vehicles` proves a plate;
	-- `downed` keeps the menu usable while the operator is on the floor; `prompts`
	-- draws the travel strip.
	-- `diagnostics` is the odd one out: it carries no feature, it carries the
	-- relay that puts a client-side fault in the SERVER journal, which is the
	-- only copy an operator can read. Declared so the dependency is visible and
	-- ordered rather than discovered at the call site; `Client.Journal` still
	-- checks, because an optional module may be disabled.
	-- `vehiclekeys` cuts the key to a vehicle staff spawn or ask for.
	optional = { 'menu', 'form', 'target', 'inventory', 'vehicles', 'downed', 'prompts',
		'diagnostics', 'vehiclekeys' },
}

-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local `TriggerEvent` on a
-- NET name would re-enter the handler registered for the wire.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

M.Event = {
	-- Server to client.
	OPEN = OPX.Event(NET, 'admin', 'open'),
	ACCESS = OPX.Event(NET, 'admin', 'access'),
	ROSTER = OPX.Event(NET, 'admin', 'roster'),
	LOCATIONS = OPX.Event(NET, 'admin', 'locations'),
	ITEMS = OPX.Event(NET, 'admin', 'items'),
	BAG = OPX.Event(NET, 'admin', 'bag'),
	-- One account's characters, chunked like every other list and tagged with the
	-- player they were read for, so an answer that arrives after the operator has
	-- moved on to somebody else is dropped rather than drawn as theirs.
	CHARACTERS = OPX.Event(NET, 'admin', 'characters'),
	-- One page of the find screen. Tagged like the list above it, but with the
	-- QUESTION rather than a player id: the tag is the mode, the term and the
	-- cursor the page was read for, because an operator who has typed a second
	-- term must not have the first one's answer drawn under it.
	FOUND = OPX.Event(NET, 'admin', 'found'),
	ANSWER = OPX.Event(NET, 'admin', 'answer'),
	TRAVEL = OPX.Event(NET, 'admin', 'travel'),
	BODIES = OPX.Event(NET, 'admin', 'bodies'),
	TAGS_STATE = OPX.Event(NET, 'admin', 'tagsState'),
	TAG_ROWS = OPX.Event(NET, 'admin', 'tagRows'),
	DOORS = OPX.Event(NET, 'admin', 'doors'),
	DOOR = OPX.Event(NET, 'admin', 'door'),
	PVP = OPX.Event(NET, 'admin', 'pvp'),
	-- The world announcement. It used to ride `OPX.Notify`, which is the platform's
	-- own notification package -- a surface this runtime does not draw. It is this
	-- module's event now because the message is wrapped in two stingers, and only
	-- the page that owns a toast's clock can hold it back until the first has
	-- played. The server sends the sentence and its lifetime and nothing else: how
	-- it is wrapped is the receiving client's own config.
	ANNOUNCE = OPX.Event(NET, 'admin', 'announce'),

	-- Client to server. Every payload is attacker-controlled; only `source` is
	-- not, and no payload mutates anything: the five below ask for a list, ask
	-- for a switch back, or report. Every mutation is a command.
	REFRESH = OPX.Event(NET, 'admin', 'refresh'),
	-- The one thing a client can say about noclip: the native went off under it,
	-- so the server's own idea of who is flying is stale. It carries a boolean
	-- and nothing else -- there is no payload here that could hide a body the
	-- operator did not ask to hide, and the off direction is the safe one.
	NOCLIP_BODY = OPX.Event(NET, 'admin', 'noclipBody'),
	TAGS_RESTORE = OPX.Event(NET, 'admin', 'tagsRestore'),
	DOORS_HELLO = OPX.Event(NET, 'admin', 'doorsHello'),
	PVP_REQUEST = OPX.Event(NET, 'admin', 'pvpRequest'),
	TARGET_REPORT = OPX.Event(NET, 'admin', 'targetReport'),

	-- The client's own bus. `TAGS` is the view seam for the staff name tags; see
	-- `client/tags.lua`. Public: a bare AddEventHandler reaches it.
	ON_TAGS = OPX.Event(LOCAL, 'admin', 'tags'),
	ON_DOWNED = OPX.Event(LOCAL, 'downed', 'changed'),
}

--- The host's own names, listed once. Neither may be renamed here: they are the
--- command dispatcher's contract, and a typed line is the only thing that ever
--- reaches it.
M.Host = {
	COMMAND_EXECUTE = 'open77:command:execute',
	COMMAND_RESULT = 'open77:command:result',
}

--- The name this module gives when a contract asks a caller to name itself.
-- There is no invoking resource for an in-process call, so `menu`, `form`,
-- `target`, `prompts` and `downed` all take an owner as an argument.
M.OWNER = 'admin'

--- The official door service. While it runs it owns every door and this module's
--- own door sync stands down.
M.NETWORKED_DOORS = 'open77_doors'

--- The opener command, whose grant is what makes a player staff.
M.OPENER = 'opx.admin'

-- STAFF IMMUNITY, two raw ACL rights (not commands, so `command.*` grants
-- neither). A player holding IMMUNE is shielded from every harmful staff action
-- -- kick, ban, kill, health, armour, freeze, model, bring, send, teleport,
-- observe, wardrobe, holster, stripping their bag or weapons, renaming or
-- deleting their character -- unless the operator holds OVERRIDE. The console
-- is exempt. See `Server.Protected`.
M.IMMUNE = 'opx.admin.immune'
M.OVERRIDE = 'opx.admin.override'

-- A raw ACL right: the vehicle commands that take a typed id act on any live
-- vehicle, in any instance and at any distance. Without it the vehicle must be
-- in the operator's instance and within VEHICLES.REACH (or carry them).
M.VEHICLE_ANYWHERE = 'opx.admin.vehicle.anywhere'

--- Every command name, in one place, so a rename is followed here and nowhere
--- else. The VALUE is what the operator writes in `acl.jsonc` as `command.<name>`.
M.Command = {
	MENU = 'opx.admin',

	SELF_NOCLIP = 'opx.admin.self.noclip',
	SELF_SPEED = 'opx.admin.self.speed',
	SELF_MAPTRAVEL = 'opx.admin.self.maptravel',
	SELF_HEAL = 'opx.admin.self.heal',
	SELF_REVIVE = 'opx.admin.self.revive',
	SELF_GOD = 'opx.admin.self.god',
	SELF_INVISIBLE = 'opx.admin.self.invisible',
	SELF_POS = 'opx.admin.self.pos',
	SELF_TAGS = 'opx.admin.self.tags',
	SELF_MODEL = 'opx.admin.self.model',

	PLAYER_GOTO = 'opx.admin.player.goto',
	PLAYER_BRING = 'opx.admin.player.bring',
	PLAYER_TP = 'opx.admin.player.tp',
	PLAYER_SEND = 'opx.admin.player.send',
	PLAYER_OBSERVE = 'opx.admin.player.observe',
	PLAYER_HEAL = 'opx.admin.player.heal',
	PLAYER_REVIVE = 'opx.admin.player.revive',
	PLAYER_GOD = 'opx.admin.player.god',
	PLAYER_FREEZE = 'opx.admin.player.freeze',
	PLAYER_KILL = 'opx.admin.player.kill',
	PLAYER_HEALTH = 'opx.admin.player.health',
	PLAYER_ARMOR = 'opx.admin.player.armor',
	PLAYER_MODEL = 'opx.admin.player.model',
	PLAYER_WARDROBE = 'opx.admin.player.wardrobe',

	-- The ACCOUNT's characters, not the body in the world. `opx.admin.player.*` is
	-- the session and the puppet -- freeze it, heal it, move it -- and every one
	-- of those dies with the connection. These three reach the ROWS behind it,
	-- which outlive it, so they are a namespace of their own: an operator trusted
	-- to unfreeze somebody is not automatically trusted to rename or delete a
	-- character they will still own tomorrow.
	CHARACTER_LIST = 'opx.admin.character.list',
	CHARACTER_RENAME = 'opx.admin.character.rename',
	CHARACTER_DELETE = 'opx.admin.character.delete',
	-- THE SAME AREA AND A SEPARATE GRANT, and the split is deliberate both ways.
	-- The area is `character` for the reason above: what this finds is a row that
	-- outlives every connection, and putting a second noun beside it -- an
	-- `opx.admin.offline.*` -- would spell one thing two ways in `acl.jsonc`.
	--
	-- The grant is its own because the BLAST RADIUS is not the same. `.list` is
	-- bounded by an account somebody is holding: whatever it answers, it is one
	-- person's rows, and the operator is already dealing with that person. This
	-- one is a directory of everybody who has ever played -- names, account
	-- names, when each was last here -- and reads it out of the table rather than
	-- out of a session. An operator trusted to look at the person in front of
	-- them is not automatically trusted to enumerate the player base, so the two
	-- are granted and revoked apart.
	CHARACTER_FIND = 'opx.admin.character.find',

	MODERATE_KICK = 'opx.admin.moderate.kick',
	MODERATE_BAN = 'opx.admin.moderate.ban',

	-- MONEY BACK TO A CHARACTER, which is a separate trust from every command
	-- above it: an operator who may unfreeze somebody is not automatically an
	-- operator who may write a balance. `me` is the caller, resolved from the
	-- server-side source and never from anything a client sends.
	RECOVERY_MONEY = 'opx.admin.recovery.money',

	VEHICLE_SPAWN = 'opx.admin.vehicle.spawn',
	VEHICLE_GIVE = 'opx.admin.vehicle.give',
	VEHICLE_REMOVE = 'opx.admin.vehicle.remove',
	VEHICLE_CLEANUP = 'opx.admin.vehicle.cleanup',
	VEHICLE_REPAIR = 'opx.admin.vehicle.repair',
	VEHICLE_ENTER = 'opx.admin.vehicle.enter',
	VEHICLE_FLAG = 'opx.admin.vehicle.flag',
	-- A KEY TO ONE PRECISE VEHICLE, into the operator's own bag. Under
	-- `opx.admin.vehicle.*` like the rest of the vehicle tools, so a role written
	-- the way docs/MANUAL.md writes one already holds it; revoked alone, it takes the
	-- eye row and the menu row with it and nothing else.
	VEHICLE_KEY = 'opx.admin.vehicle.key',

	INVENTORY_VIEW = 'opx.admin.inventory.view',
	INVENTORY_GIVE = 'opx.admin.inventory.give',
	INVENTORY_REMOVE = 'opx.admin.inventory.remove',
	INVENTORY_CLEAR = 'opx.admin.inventory.clear',

	WEAPON_GIVE = 'opx.admin.weapon.give',
	WEAPON_GIVEAMMO = 'opx.admin.weapon.giveammo',
	WEAPON_AMMO = 'opx.admin.weapon.ammo',
	WEAPON_REMOVE = 'opx.admin.weapon.remove',
	WEAPON_HOLSTER = 'opx.admin.weapon.holster',
	WEAPON_READ = 'opx.admin.weapon.read',

	WORLD_LOC_ADD = 'opx.admin.world.loc.add',
	WORLD_LOC_REMOVE = 'opx.admin.world.loc.remove',
	WORLD_ANNOUNCE = 'opx.admin.world.announce',
	WORLD_PVP = 'opx.admin.world.pvp',
	WORLD_DOOR = 'opx.admin.world.door',

	READ_STATUS = 'opx.admin.read.status',
	READ_AUDIT = 'opx.admin.read.audit',

	-- THE DEV GROUP STOOD HERE AND IS GONE. It was a SECOND VOCABULARY -- five
	-- command names belonging to `garages` and `dealership`, which this module
	-- does not register -- and the Dev screen was the only thing that read them:
	-- it ran those commands so an operator did not have to keep a chat line in
	-- their head. The owner deleted that screen on 2026-09-21 ("il y a pas de
	-- config live c'est tous par les fichier config donc degage moi ce menu est
	-- pass moi tous dans les config"), and with it the last reader.
	--
	-- `opx.garages.list`, `opx.garages.bring`, `opx.dealership.list`, `.stock`
	-- and `.buy` are all still registered by the modules that own them and are
	-- still ACL-gated by the host. Nothing about them changed; an operator types
	-- them, which is what the rows were typing on their behalf.
	--
	-- GOING WITH IT: the loop underneath, which read `COMMANDS` out of two other
	-- modules' config at load. That was a written-down exception to the one rule
	-- `config/entry.lua` states outright -- "a module may not read another
	-- module's settings" -- and its own note said it should end "when the Dev
	-- group next needs work". This was that.
}

--- The tunables this module contributes to the operator panel.
-- Declared once, from the server's `Init`, with the configured value as the
-- default; read through `OPX.Tune.Number` at the moment of use and never
-- captured into a file-scope local, which would freeze a live value for the life
-- of the resource.
M.TUNABLES = {
	ADMIN_RATE_ACTION_MS = {
		value = 400,
		type = 'integer', min = 0, max = 60000, step = 50, unit = 'ms', apply = 'live',
		label = 'Action floor', group = 'Staff', order = 1,
		description =
			'Least time between two runs of one mutating staff command by one operator. It is ' ..
			'a fairness limit and not a security boundary: the ACL is checked whether or not ' ..
			'the floor was waited for. The console is never cooled.',
	},

	ADMIN_RATE_READ_MS = {
		value = 1000,
		type = 'integer', min = 0, max = 60000, step = 100, unit = 'ms', apply = 'live',
		label = 'Read floor', group = 'Staff', order = 2,
		description =
			'Least time between two runs of one reading staff command. Reads are the expensive ' ..
			'ones: a bag list walks every stack a character holds.',
	},

	ADMIN_RATE_REFRESH_MS = {
		value = 750,
		type = 'integer', min = 0, max = 60000, step = 50, unit = 'ms', apply = 'live',
		label = 'Menu refresh floor', group = 'Staff', order = 3,
		description =
			'Least time between two requests for the same menu list from one operator. Each ' ..
			'topic keeps its own slot, so a roster refresh never blocks a bag refresh.',
	},

	ADMIN_AUDIT_ENTRIES = {
		value = 200,
		type = 'integer', min = 10, max = 2000, step = 10, apply = 'live',
		label = 'Audit entries kept', group = 'Staff', order = 4,
		description =
			'How many staff actions the in-memory ring keeps for `opx.admin.read.audit`. The ' ..
			'platform log beside it is the record; this is only what can be read back in game, ' ..
			'and it is gone at the next restart.',
	},

	ADMIN_TOAST_MS = {
		value = 6000,
		type = 'integer', min = 1000, max = 60000, step = 500, unit = 'ms', apply = 'live',
		label = 'Target toast lifetime', group = 'Staff', order = 5,
		description = 'How long the toast a staff action raises on its target stays up.',
	},

	ADMIN_PLACEMENT_GRACE_MS = {
		value = 5000,
		type = 'integer', min = 0, max = 60000, step = 500, unit = 'ms', apply = 'live',
		label = 'Placement grace', group = 'Staff', order = 6,
		description =
			'Respawn protection a moved or revived player gets. A placement is a kill and a ' ..
			'respawn, so without it a player teleported into traffic dies on arrival.',
	},

	ADMIN_ANNOUNCE_MS = {
		value = 12000,
		type = 'integer', min = 1000, max = 120000, step = 500, unit = 'ms', apply = 'live',
		label = 'Announcement lifetime', group = 'Staff', order = 7,
		description = 'How long an announcement toast stays on every client.',
	},

	ADMIN_VEHICLE_PER_OWNER = {
		value = 8,
		type = 'integer', min = 1, max = 100, step = 1, apply = 'live',
		label = 'Staff vehicles per player', group = 'Staff', order = 8,
		description =
			'How many vehicles this module keeps out per player at once. A spawn past the cap ' ..
			'is refused rather than silently removing an older one.',
	},

	ADMIN_VEHICLE_NEAR_RADIUS = {
		value = 30.0,
		type = 'number', min = 1, max = 200, step = 1, unit = 'm', apply = 'live',
		label = 'Near vehicle radius', group = 'Staff', order = 9,
		description =
			'Metres `near` searches when the operator is on foot. Sitting in a vehicle always ' ..
			'answers that vehicle, whatever this says.',
	},

	ADMIN_INVENTORY_MAX_COUNT = {
		value = 10000,
		type = 'integer', min = 1, max = 1000000, step = 100, apply = 'live',
		label = 'Largest item count', group = 'Staff', order = 10,
		description =
			'Largest count an item or ammunition give or removal accepts. The bag refuses on ' ..
			'weight and slots long before this; it is a typo guard.',
	},

	ADMIN_TAGS_REFRESH_MS = {
		value = 2000,
		type = 'integer', min = 500, max = 60000, step = 250, unit = 'ms', apply = 'live',
		label = 'Name tag list interval', group = 'Staff', order = 11,
		description =
			'Milliseconds between two name lists sent to each staff member with tags on. An ' ..
			'unchanged list is not sent again, so this is a ceiling rather than a cost.',
	},
}

--- Display text with its control characters blanked, trimmed at both ends and
--- cut to `maximum` characters; nil for anything that is not text or is empty.
-- @author dop42
--
-- `OPX.Text.Clean` neither trims nor answers nil for an empty string, and half
-- this module reads a nil answer as "nothing was typed". Kept here rather than
-- changed there: trimming is this module's rule about typed arguments, not the
-- runtime's rule about display text.
-- @param value any
-- @param maximum integer characters
-- @return string|nil
function M.Trimmed(value, maximum)
	if type(value) == 'number' then value = tostring(value) end
	if type(value) ~= 'string' then return nil end
	value = OPX.String.Trim((value:gsub('%c', ' ')))
	if value == '' then return nil end
	if #value > maximum then value = value:sub(1, OPX.Text.Span(value, maximum)) end
	return value
end

--- A configured number, or the fallback for anything arithmetic would raise on.
-- @author dop42
-- @param value any
-- @param fallback number
-- @return number
function M.Number(value, fallback)
	return OPX.Text.Finite(value) or fallback
end

--- A configured number inside its range, or the fallback, named once when it is
--- neither.
-- @author dop42
-- @param path string how the warning names it, e.g. NOCLIP.STEP
-- @param value any
-- @param low number
-- @param high number
-- @param fallback number
-- @return number
function M.Bounded(path, value, low, high, fallback)
	if value == nil then return fallback end
	local number = OPX.Text.Finite(value)
	if number ~= nil and number >= low and number <= high then return number end
	Open77.log.warn(('[admin] config: %s must be a number in %s..%s; using %s')
		:format(path, tostring(low), tostring(high), tostring(fallback)))
	return fallback
end

--- One table out of the module settings, or an empty one.
-- @author dop42
-- @param name string
-- @return table
function M.Section(name)
	local section = M.Settings[name]
	return type(section) == 'table' and section or {}
end
