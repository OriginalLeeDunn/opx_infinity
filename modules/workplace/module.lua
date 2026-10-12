--- Workplace: where a job starts its shift -- the duty clock, the locker room
--- and the motor pool, per job, at several stations each.
-- @author dop42
--
-- THREE POINTS A STATION, NOTHING MORE. An NCPD precinct, the Trauma Team HQ,
-- a Delamain depot or an Arasaka lobby is a STATION of one job, and holds up to
-- three surveyed spheres on the eye:
--
--   DUTY      clock in / clock out, through the character contract's
--             `SetJobDuty` -- this module never writes `onDuty` itself.
--   WARDROBE  put on a uniform of the job (per grade), and back to civilian.
--             The uniform is written through the APPEARANCE contract
--             (`SaveClothing`), which is the one door clothes go through and
--             what re-dresses the puppet on the client; the player's own look
--             is kept on their character metadata until they take it off.
--   GARAGE    take out a service vehicle of the job (per grade) on a pad, one
--             per player, with a key cut through `vehiclekeys`; bring it back
--             to the pad to hand it in. It is a SERVER vehicle with a TTL and
--             no row: nothing durable is attached to a car the job owns.
--
-- EVERYTHING IS THE SERVER'S. A client names a station, an outfit or a vehicle
-- and nothing else: the reach, the bucket, the job, the grade and the duty
-- flag are read here, and the menus are built from what the server sends.
-- Going off duty, losing the job, switching character or leaving hands the
-- vehicle back and (when configured) the civilian look.
--
-- Only `character` is required. `appearance` is the wardrobe, `vehiclekeys`
-- the key, `target` and `menu` the client's doors; each one missing closes its
-- door and says so once.

local M = OPX.Modules.Declare{
	id = 'workplace',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'appearance', 'vehiclekeys', 'vehicles', 'inventory', 'target', 'menu', 'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- `{ station }`: clock in or out at a station's duty point.
	DUTY = OPX.Event(NET, 'workplace', 'duty'),
	-- `{ station, kind = 'wardrobe'|'garage' }`: send me that point's menu.
	ASK = OPX.Event(NET, 'workplace', 'ask'),
	-- `{ station, outfit }`: put on an outfit at a wardrobe.
	WEAR = OPX.Event(NET, 'workplace', 'wear'),
	-- `{ station }`: back to the look I came in with.
	CIVVIES = OPX.Event(NET, 'workplace', 'civvies'),
	-- `{ station, vehicle }`: take a service vehicle out on the pad.
	SPAWN = OPX.Event(NET, 'workplace', 'spawn'),
	-- `{ station }`: hand my service vehicle back.
	RETURN = OPX.Event(NET, 'workplace', 'return'),

	-- Server to client: one point's menu, `{ station, kind, label, rows =
	-- { { key, label, worn? } }, worn?, out? }`.
	MENU = OPX.Event(NET, 'workplace', 'menu'),

	-- The public SERVER bus.
	-- `(player, { job, station, onDuty })`: clocked in or out at a station.
	ON_DUTY = OPX.Event(LOCAL, 'workplace', 'duty'),
	-- `(player, { job, station, outfit|nil })`: a uniform on (outfit) or off (nil).
	ON_UNIFORM = OPX.Event(LOCAL, 'workplace', 'uniform'),
	-- `(player, { job, station, vehicle, id, plate|nil, reason })`: a service
	-- vehicle out (`reason = 'spawned'`) or gone (returned, off_duty, ...).
	ON_FLEET = OPX.Event(LOCAL, 'workplace', 'fleet'),
}

--- The ACL entries, spelt once. A command's host gate is `command.<name>`.
M.Command = {
	CAPTURE = 'opx.workplace.capture',
	STATIONS = 'opx.workplace.stations',
}

--- The three points a station may hold, and the pad a garage spawns on.
M.Point = {
	DUTY = 'duty',
	WARDROBE = 'wardrobe',
	GARAGE = 'garage',
}

--- The visible equipment slots a uniform may set, as the appearance module
--- names them. Underwear is never touched by a uniform.
M.SLOTS = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit' }
