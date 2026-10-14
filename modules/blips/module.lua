--- Blips: real Cyberpunk mappins for the places a player has to be able to find.
-- @author dop42
--
-- THE COMPLAINT THIS ANSWERS, repeated over several sessions: "ce serais cool
-- de voir des blips sur la minimap", then "sur la map je vois pas les blips".
-- A player could not see where a garage, a dealer, a shop, a shortcut or a job
-- was. `config/blips.lua` carries the long version of why -- the short version
-- is that this runtime had never created a blip, and the minimap hypothesis was
-- half true about the minimap and wrong about the fullscreen map.
--
-- IT IS CLIENT-ONLY AND IT HAS NO SERVER HALF. `Open77.blips` is a client API
-- and every position it needs is already on the client: the garages, dealership
-- and teleports modules are each told their own list by their own server half
-- and publish it on a `Runtime` accessor, and shops and the job sites are in
-- `shared_script` config that both sides already load. A server half here would
-- be a second copy of four lists that are already correct.
--
-- NOTHING HERE DECIDES ANYTHING, and that is the whole shape of the module. It
-- does not filter by routing bucket -- the servers already did, before the
-- lists reached this client. It does not evaluate a job gate -- teleports
-- already marked each entrance allowed or refused. It does not own a
-- coordinate. It reads six lists somebody else is authoritative for and turns
-- them into pins, which means a blip cannot disagree with the thing it points
-- at: if the pin is wrong, the list is wrong, and there is one place to fix it.
--
-- WHY IT READS RATHER THAN SUBSCRIBES. The obvious implementation is a
-- `RegisterNetEvent` on each source module's SYNC event, and it was written
-- that way first. It is wrong twice. The small reason is that it would put a
-- second handler on a wire another module owns, so a payload shape change
-- breaks a module that never mentioned this one. THE REASON THAT DECIDED IT is
-- that the test host models `RegisterNetEvent` as ONE HANDLER PER NAME --
-- `netEvents[name] = fn`, an assignment and not an append -- so a second
-- registration on `opx:net:garages:sync` does not add a listener, it SILENTLY
-- REPLACES the garages module's own. Depending on manifest order that is either
-- this module never hearing anything or the garages module losing its spots
-- entirely, and the suite would have reported the second as a garages failure.
-- Polling the accessors those handlers already write into costs one table read
-- every four seconds and cannot do that to anybody.
--
-- EVERY SOURCE IS OPTIONAL AND ABSENCE IS NORMAL. A server with no dealership
-- has no dealership blips and no warnings about it; `requires` is empty on
-- purpose, because a map with four of its five categories on it is worth having
-- and a hard dependency would mean a disabled module takes the map with it.

local M = OPX.Modules.Declare{
	id = 'blips',
	-- No server file exists, so declaring 'both' would mark a side that never
	-- loads anything as part of this module's lifecycle.
	side = 'client',
	-- Not fatal, and this is the one place it is worth being explicit about why:
	-- a map pin is a convenience. A resource that refuses to boot because the
	-- map was not drawn has turned a missing nicety into an outage, and the
	-- outage is strictly worse than the thing it was protecting.
	fatal = false,
	requires = {},
	-- Read for their positions, never called into beyond a plain list read. Each
	-- is handled as absent when it is absent.
	optional = { 'garages', 'dealership', 'teleports', 'shops', 'hud', 'headquarters', 'bank', 'fuel' },
}

--- The categories this module knows how to source, in the order they are built.
-- The order is the order they consume the `MAX` budget in, so it is the order
-- of what survives a server that has captured more spots than the platform's
-- 128-per-resource quota allows. A headquarters first: it designates where the
-- station is, every other category is placed around it, and it is a handful of
-- pins that must survive the day the captures outnumber the quota. Garages
-- next because the owner named them first and a player who cannot find their
-- own car is the loudest case.
-- Bank branches and gas stations last: a player looks for a branch when there
-- is a paycheck to draw and for a station when the tank is low, and a server
-- has a handful of each.
M.ORDER = { 'headquarters', 'garages', 'dealership', 'shops', 'teleports', 'jobs', 'bank', 'fuel' }

--- The vanilla HUD component whose hide also hides mappins ON THE MINIMAP.
-- Named here rather than spelled at the call site because the boot note quotes
-- it back to the operator and the two must be the same word.
M.MINIMAP_COMPONENT = 'minimap'

--- The engine's own bounds on `range`, in metres. Outside these, `create`
--- answers `invalid_range`; this module refuses the value at boot instead, so
--- an operator learns it from a line naming their category rather than from a
--- blip that is simply not there.
M.MIN_RANGE, M.MAX_RANGE = 0, 4000

--- The platform's per-resource blip quota. `config/blips.lua`'s `MAX` is
--- clamped to it: a config that asked for more would be asking the engine to
--- refuse the surplus one create at a time.
M.QUOTA = 128

--- The options `Open77.blips.create` refuses BY NAME, mapped to the setting
--- that actually does the job. An operator who writes one of these into a
--- category gets a boot line naming the category, the key and the replacement.
--
-- THE POINT IS THAT THEY ARE NAMED. Before the platform added these refusals an
-- unknown key was simply ignored, so `create{ sprite = 'loot', colour = '#f00' }`
-- handed back a perfectly good blip that was not red and never said so. This
-- table is that refusal moved one level earlier, to boot, where it can name the
-- file the operator has open.
--
-- `COLOR` IS NOT AMONG THEM AND THAT IS NEW. This table used to refuse it with
-- "a mappin has no such field", which was true when it was written (build
-- 2.31.13+op77.76) and is not true since the native Ink adapter grew per-widget
-- colours: `color` is now a real `create`/`update`/`setColor` field, exactly
-- `#RRGGBB`/`#RRGGBBAA`, and `unsupported_option` belongs to the British
-- spelling alone. What the engine still refuses is the platform catalogue's
-- own list: `colour` (use `color`), `alpha`/`opacity` (the alpha bytes live in
-- `color`), `scale` (per sprite, never per pin), `category`, `shortRange` (use
-- `range`) and `kind`.
M.REFUSED_KEYS = {
	COLOUR = 'COLOR',
	ALPHA = 'COLOR', OPACITY = 'COLOR', SCALE = 'SPRITE',
	CATEGORY = 'SPRITE',
	SHORTRANGE = 'RANGE', SHORT_RANGE = 'RANGE',
}
