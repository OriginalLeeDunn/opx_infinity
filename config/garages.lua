--- Where an owned vehicle may be brought out, and the glowing markers that say so.
-- @author XEROX710
--
-- A GARAGE IS A NAME, AND A NAME MAY BE IN SEVERAL PLACES. That is the whole of
-- the rework, in the owner's own words: "change les system de garage". Before
-- it, a garage WAS a point -- one marker, one key, one car out where the marker
-- stood -- so a player who stored a car in Watson could only ever fetch it in
-- Watson, and an operator who wanted the same garage on two sides of a building
-- had to make two garages and file the cars under one of them.
--
-- So a garage is a KEY with a list of LOCATIONS, and each location is three
-- different kinds of point:
--
--   MENU   where the list opens. It shows EVERY vehicle filed under this
--          garage's key, whichever location it was stored at -- that is what
--          makes storing in Watson and fetching in Japantown one garage rather
--          than two.
--   ENTRY  the ONE point a vehicle is taken in at. One, deliberately: driving in
--          is a thing you do at a door, and two doors to one garage is two
--          places a player has to guess between.
--   EXITS  the points a vehicle comes OUT at, tried IN THE ORDER WRITTEN. The
--          first one with nothing parked on it wins. When every one of them is
--          occupied the bring-out is REFUSED and the player is told so, which is
--          the owner's own choice over the two alternatives -- queueing behind a
--          car nobody may move, or spawning on top of it.
--
-- THE KEY IS WHAT A VEHICLE'S `garage` COLUMN HOLDS, and it is the same key the
-- points used to be named by, which is why no row anywhere had to be rewritten
-- for this: `garage1` was a spot and is now a garage, and every car filed under
-- `garage1` still comes out of it.
--
-- THE COMMANDS THAT PLACED A SPOT ARE GONE. `/opx.garages.add` and
-- `/opx.garages.remove` wrote into `opx77_garages`, so the shape of the world
-- lived in a table nobody had a copy of. A garage is written here now. The
-- module still READS that table at boot and adopts anything in it that this file
-- does not name -- see `modules/garages/server/main.lua`, "the legacy adoption"
-- -- and prints each one as the block to paste in here, so nothing an operator
-- ever placed is lost by the commands going away. `/opx.garages.export` hands
-- the same blocks to a person in game, on demand.
--
-- KIND decides what may come out: a `garage` brings out a ground vehicle, an
-- `avpad` brings out an AV record. It belongs to the GARAGE and not to a point,
-- because a garage that took cars in at one location and AVs at another would be
-- a garage whose own list means two things.
--
-- X, Y and Z are validated, and only X and Y are measured against: a pad on a
-- roof is used by someone standing on the roof, and someone on the street below
-- it is not near it. HEADING is the yaw a vehicle is created with, so it is a
-- field of ENTRY and of an EXIT and NOT of MENU -- nothing is created at a menu
-- point, and a heading on a record nothing turns is a field a later author wires
-- up by mistake.
--
-- HOW TO CAPTURE ONE OF THOSE POINTS. Stand on it, FACE THE WAY A CAR COMING
-- OUT SHOULD FACE, and run `/opx.admin.self.pos` -- Self -> Position on the
-- staff menu, or the row on the target eye. It copies
-- `{ NAME = "here", LABEL = "Here", X = ..., Y = ..., Z = ..., HEADING = ... }`
-- to your operating system clipboard, with the facing you are really standing
-- at, and you paste the numbers into a MENU, an ENTRY or an EXIT below. That is
-- the whole capture path on this server. It is a COMMAND and not a menu on
-- purpose: the owner deleted the staff menu's Dev screen on 2026-09-21 --
-- "il y a pas de config live c'est tous par les fichier config donc degage moi
-- ce menu est pass moi tous dans les config" -- because a screen that places
-- things teaches an operator to set a server up somewhere nobody can read
-- afterwards. This command places nothing. It reads a number and hands it to
-- you, and you put it in the file.
--
-- The marker vocabulary is fixed by the engine and not by this file: styles are
-- `interaction`, `objective`, `spawn` and `danger`, shapes are `ring` and
-- `cylinder`, RADIUS is 0.1..50 and MAX_DISTANCE is 1..500. Anything else is
-- answered `unsupported_style`/`unsupported_shape` by `Open77.markers`, which is
-- why every preset below glows with a stock style rather than a custom one.

OPX.Config.MODULES.garages = {
	enabled = true,

	-- Flat metres from the declared X and Y within which a point may be used.
	USE_RADIUS = 4.0,

	-- HOW MUCH ROOM AN EXIT NEEDS TO COUNT AS FREE, in flat metres. Every
	-- server vehicle in the location's routing bucket is measured against every
	-- exit in turn, and an exit with one inside this radius is skipped.
	--
	-- 3.0 rather than a car's own length: the measure is between two PIVOTS, and
	-- a pivot is the chassis centre, so two vehicles three metres apart are two
	-- vehicles touching. Larger refuses a bay that would have fitted; smaller
	-- drops a car through the roof of the one already parked there.
	--
	-- The vehicle being fetched is never counted against its own exit: a car
	-- left standing on the only exit of its own garage would otherwise be a car
	-- that can never be recalled.
	EXIT_CLEARANCE = 3.0,

	-- What a marker looks like, per KIND for the menu point and per ROLE for the
	-- door. All three are engine presets and all three glow.
	--
	-- `entry` is its own look on purpose: the menu point and the door are two
	-- different promises -- one opens a list, one takes the car you are sitting
	-- in -- and a player who cannot tell them apart drives into the wrong one.
	MARKER = {
		garage = { shape = 'cylinder', style = 'spawn', RADIUS = 2.5 },
		avpad = { shape = 'ring', style = 'objective', RADIUS = 3.5 },
		entry = { shape = 'ring', style = 'interaction', RADIUS = 3.0 },
	},

	-- Metres at which a marker stops being drawn at all, 1..500.
	MAX_DISTANCE = 150.0,

	-- Metres the marker is lifted off the declared Z, 0..2.
	--
	-- Not decoration. A ring is the marker mesh flattened to 0.04 m, so one
	-- placed at exact floor height is co-planar with the floor and draws NOTHING:
	-- the entity spawns, the marker is listed, and the pad looks empty. The
	-- platform's own POI path lifts its markers by the same 0.06 m for exactly
	-- this reason, and the research notes recommend the small lift against
	-- z-fighting. Every kind shares the one value.
	GROUND_OFFSET = 0.06,

	-- Metres above the pad an AV is created, so it does not start half-buried.
	-- An AV record's pivot is the chassis centre, the same reason freeroam lifts
	-- its own AV spawns.
	AV_LIFT = 1.2,

	-- PUTTING AN AIRCRAFT AWAY FROM ITS COCKPIT. The owner, 2026-10-03: "theres
	-- no way for me to put av back in hanger when i fly back to the av garage".
	-- `USE_RADIUS` is a walk-up reach, and an AV's pilot sits metres from the
	-- middle of the hull (3.7 m in the MaxTac AV, measured): a hull set down
	-- squarely on its pad left the pilot out of reach of the pad's door, so the
	-- key had nothing to put away. A pilot SEATED IN AN AIRCRAFT reaches a pad's
	-- door within `RADIUS` flat metres, and no higher than `HEIGHT` metres over
	-- it -- landed, or a low hover; higher than that, putting it away would take
	-- the hull out from under a pilot in the air. On foot and in a car the reach
	-- is `USE_RADIUS`, as before.
	AV_PUTAWAY = { RADIUS = 14.0, HEIGHT = 6.0 },

	-- WHICH RECORDS ARE AVs IS NOT A GARAGE SETTING. It is one list,
	-- `AV_MATCHES` in `config/shared.lua`, read by one helper: this module, the
	-- dealership and the admin catalogue each used to carry their own, and a
	-- record that flies at a dealer and not in a garage is a car you can buy at a
	-- pad you cannot recall it at.

	-- The marker/scan loop. SCAN_MS also decides how long a marker stays up
	-- after a read fails.
	SCAN_MS = 500,
	-- How often the client re-asks for the list, so a change of routing bucket
	-- is picked up without a rejoin.
	POLL_MS = 15000,

	REQUEST_WINDOW_MS = 10000,
	REQUESTS_PER_WINDOW = 6,
	-- Floor between two bring-outs from one connection.
	COOLDOWN_MS = 3000,

	-- The key that opens the list at a menu point, and puts a vehicle away at a
	-- door. ID is stable, because a player's rebind is stored under it; NAME is
	-- the catalogue key of the pause-menu label.
	KEY = { ID = 'opx.garages.use', NAME = 'garages.key.use', DEFAULT = 'E' },

	-- THE LIST IS A PANEL, NOT A STRIP, for the reason the dealership's own
	-- MENU block spells out: a garage list is read standing still. The menu
	-- module clamps every one of these (240..1200 px, 120..1200 px tall, 3..24
	-- rows), so a typo here is a wrong size and never a menu that fails to open.
	MENU = {
		ANCHOR = 'center',
		WIDTH = 560,
		HEIGHT = 560,
		MAX_HEIGHT_VH = 88,
		VISIBLE_ROWS = 12,
	},

	-- How often, in milliseconds, every job vehicle that is out is held against
	-- its holder's job, grade and duty -- see JOB_VEHICLES at the bottom of this
	-- file. A change of job or duty through `/opx.job`, a desk or `/opx.duty` is
	-- acted on at once; this pass is what catches the ones that announce nothing
	-- (a dismissal, a character going back to the selection screen).
	JOB_SWEEP_MS = 5000,

	-- ACL-gated; each is refused unless the player holds `command.<name>`.
	--
	-- `add` and `remove` ARE GONE, and this is the whole of what is left. They
	-- wrote a place every player uses into a table that only existed on one
	-- host; a garage is a line in this file now. See the header. `export` is
	-- the other half of that sentence: it hands back the block to paste for
	-- every garage that still lives only in that table.
	COMMANDS = {
		list = 'opx.garages.list',
		bring = 'opx.garages.bring',
		export = 'opx.garages.export',
	},

	-- EVERY GARAGE ON THE SERVER.
	--
	-- LABEL is the operator's own words and is never translated. The key is the
	-- durable name: a vehicle's `garage` column holds it and every command names
	-- it, so keys are added freely and NEVER renamed -- renaming one orphans
	-- every car filed under it.
	--
	-- The two below were captured in game when a garage was still a single
	-- point, and were checked in on 2026-09-21 off the boot log. They are
	-- written here as one location each whose menu, door and only exit are that
	-- one captured point, which is exactly what they did before -- stand on the
	-- marker, press the key, the car appears where you are standing. Give either
	-- of them a second location, or a second exit, and it becomes the thing the
	-- rework is for.
	GARAGES = {
		garage1 = {
			LABEL = 'garage1',
			KIND = 'garage',
			LOCATIONS = {
				{
					BUCKET = 0,
					MENU = { X = -1527.21, Y = -218.56, Z = 7.86 },
					ENTRY = { X = -1527.21, Y = -218.56, Z = 7.86, HEADING = 199.6 },
					EXITS = {
						{ X = -1527.21, Y = -218.56, Z = 7.86, HEADING = 199.6 },
					},
				},
			},
		},

		garage2 = {
			LABEL = 'garage2',
			KIND = 'garage',
			LOCATIONS = {
				{
					BUCKET = 0,
					MENU = { X = 89.67, Y = -569.73, Z = 7.56 },
					ENTRY = { X = 89.67, Y = -569.73, Z = 7.56, HEADING = 242.1 },
					EXITS = {
						{ X = 89.67, Y = -569.73, Z = 7.56, HEADING = 242.1 },
					},
				},
			},
		},
	},

	-- ── THE JOB FLEET: the vehicles a job brings with it ────────────────────
	--
	-- "give all maxtac and ncpd workers the vehicles they need in there garage
	-- with proper labels" and "required avs for the role job needs to be in the
	-- garage for players by defualt" -- the owner's words. Every row below is in
	-- the garage list of every holder of its job, at its grade and above, BY
	-- DEFAULT: nothing is bought, granted or issued first, and a member hired
	-- today and one hired a year ago find the same rows the moment they open a
	-- garage.
	--
	-- WHERE A ROW SHOWS. At every garage of the right KIND the player may use: a
	-- ground vehicle at every `garage`, an AV at every `avpad` -- the MaxTac
	-- hangars of `config/avgarages.lua` included, behind their own gate as
	-- always. Which of the two a row is, is the record's own fact, decided by the
	-- one AV rule (`AV_MATCHES` in `config/shared.lua`), never written here.
	-- NCPD's AV therefore needs a pad NCPD may use: the MaxTac hangars are
	-- MaxTac's, so give the station a public `KIND = 'avpad'` garage in GARAGES
	-- above -- a public pad lists the NCPD AV to NCPD alone, at its grade and on
	-- duty, and everybody else's own AVs to them as before.
	--
	-- WHO. The job is the character's PRIMARY job, at the row's grade or above,
	-- and clocked on when `ON_DUTY` is true (the default) -- the job gate
	-- `lib/shared/jobgate.lua`, the same decision the MaxTac pads make. A grade
	-- block holds what that grade ADDS: an Officer takes out everything a Cadet
	-- does, and more. A job or a grade `config/character.lua` does not define
	-- is refused at boot rather than listed to nobody.
	--
	-- WHAT THEY ARE. JOB VEHICLES, NEVER OWNED. A row is signed out, not given:
	-- it has no plate and no row in `opx77_vehicles`, so it cannot be sold,
	-- handed over, stored as a car of their own or counted against the ownership
	-- ceiling, and its boot holds nothing past the vehicle. One of each row per
	-- member: picking one that is already out brings it to the exit, the way a
	-- car of their own is recalled. Driven into a garage door it goes back to
	-- the pool. It goes back on its own when the holder leaves the job, drops
	-- below its grade, clocks off or changes character -- the moment nobody is
	-- sitting in it (JOB_SWEEP_MS above), because nothing is pulled out from
	-- under a driver -- and at once when the holder leaves the server.
	--
	--   KEY     the row's durable name, unique across this whole block: what a
	--           list row and a request carry. Letters, digits, `_ - .`
	--   RECORD  the TweakDB vehicle record, as a spawn names it
	--   LABEL   the catalogue key of its name, in `modules/garages/locales.lua`
	--           beside every language the server carries. Plain words work too
	--           -- a key the catalogue does not hold reads as itself -- but a
	--           list read in two languages wants a key
	--   APPEARANCE  optional: the livery, one of the appearance names the
	--           record's entity template carries. The vehicle is created in
	--           it, on every player's game. Absent, the record's own livery
	--
	-- THE SHIPPED ROWS ARE THE BASE GAME'S OWN POLICE RECORDS, the player-usable
	-- ones the NCPD prevention records (`config/ncpd.lua` LADDER) are built on,
	-- climbing with rank the way the heat ladder climbs: the Cortes of Heat 1
	-- for a Cadet, the Hella and the Apollo bike of Heats 2 and 3 for an
	-- Officer, the Emperor and the Merrimac of Heat 4 for a Detective, the
	-- Hellhound of Heat 5 for the Captain. MaxTac's are its own: the Merrimac
	-- in MaxTac livery and `Vehicle.max_tac_av`, the Surveyor the division's
	-- insertion flies (`config/ncpd.lua` MAXTAC.AV).
	--
	-- THE TWO AIRCRAFT. The platform flies as an AV only a `Vehicle.av_*`
	-- record, or exactly `Vehicle.max_tac_av`; anything else comes out as a car
	-- that cannot leave the ground. So:
	--   * the NCPD air unit is `Vehicle.av_zetatech_atlus` in the Atlus's own
	--     NCPD livery, `zetatech_atlus_ncpd_01` -- the airframe the base game
	--     puts in NCPD service (`Vehicle.sq026_av_ncpd` is the same Atlus with
	--     that livery). `Vehicle.q001_police_av`, the prologue's police AV, is
	--     not an `av_*` record and never flew. A civilian's Atlus keeps its own
	--     livery: the appearance belongs to this row, not to the record.
	--   * MaxTac's `Vehicle.max_tac_av` names the base game's CLOAKED livery,
	--     invisible but for its stickers and thrusters, so it comes out in the
	--     same airframe's visible MaxTac livery, `zetatech_surveyor__basic_ep1_maxtac_01`.
	--     opx_sandy_view's `OpxMaxTacAv.reds` draws that livery on every game
	--     as well, for a Surveyor created without one.
	-- An AV row shows at an `avpad` the player may use. The MaxTac hangars of
	-- `config/avgarages.lua` are MaxTac's; NCPD's AV needs a public
	-- `KIND = 'avpad'` garage in GARAGES above (docs/ncpd-maxtac.md, section 8).
	JOB_VEHICLES = {
		ncpd = {
			ON_DUTY = true,
			GRADES = {
				-- Cadet
				[0] = {
					{ KEY = 'ncpd_cortes', RECORD = 'Vehicle.v_standard2_villefort_cortes_police',
						LABEL = 'garages.job.vehicle.ncpdCortes' },
				},
				-- Officer
				[1] = {
					{ KEY = 'ncpd_hella', RECORD = 'Vehicle.v_standard2_archer_hella_police',
						LABEL = 'garages.job.vehicle.ncpdHella' },
					{ KEY = 'ncpd_apollo', RECORD = 'Vehicle.v_sportbike3_brennan_apollo_police',
						LABEL = 'garages.job.vehicle.ncpdApollo' },
				},
				-- Detective
				[2] = {
					{ KEY = 'ncpd_emperor', RECORD = 'Vehicle.v_standard3_chevalier_emperor_police',
						LABEL = 'garages.job.vehicle.ncpdEmperor' },
					{ KEY = 'ncpd_merrimac', RECORD = 'Vehicle.v_standard25_thorton_merrimac_police',
						LABEL = 'garages.job.vehicle.ncpdMerrimac' },
					{ KEY = 'ncpd_av', RECORD = 'Vehicle.av_zetatech_atlus',
						APPEARANCE = 'zetatech_atlus_ncpd_01',
						LABEL = 'garages.job.vehicle.ncpdAv' },
				},
				-- Captain
				[3] = {
					{ KEY = 'ncpd_hellhound', RECORD = 'Vehicle.v_standard3_militech_hellhound_police',
						LABEL = 'garages.job.vehicle.ncpdHellhound' },
				},
			},
		},

		maxtac = {
			ON_DUTY = true,
			GRADES = {
				-- Operator, and so the Squad Lead too: the division's AV is what
				-- the role IS, and every operator finds it at the hangar.
				[0] = {
					{ KEY = 'maxtac_av', RECORD = 'Vehicle.max_tac_av',
						APPEARANCE = 'zetatech_surveyor__basic_ep1_maxtac_01',
						LABEL = 'garages.job.vehicle.maxtacAv' },
					{ KEY = 'maxtac_merrimac', RECORD = 'Vehicle.v_standard25_thorton_merrimac_maxtac',
						LABEL = 'garages.job.vehicle.maxtacMerrimac' },
				},
			},
		},
	},
}
