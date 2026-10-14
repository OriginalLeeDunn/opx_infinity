--- The MaxTac AV recall pads: where the division's aircraft comes out.
-- @author XEROX710
--
-- THIS FILE IS THE GARAGES MACHINERY, WORN BY ANOTHER NAME. A pad here is a
-- GARAGE in every sense `config/garages.lua` defines -- a key, locations, a
-- menu point, a door, ordered exits, a vehicle filed under the key recalled to
-- a free one -- with two differences, and both of them are the whole reason
-- this file exists rather than a block in that one:
--
--   * IT IS SEPARATE. The owner asked for it in as many words: the AV garage
--     needs its own config. A MaxTac hangar is placed at a headquarters
--     (`config/headquarters.lua` designates the place) and moved when the
--     headquarters moves; a file of its own is what lets that happen without
--     wading through every ground garage on the server.
--   * IT ISSUES THE DIVISION'S OWN AIRCRAFT. `FLEET` below is every hull the
--     hangar may hand out -- the MaxTac birds included -- offered at the menu
--     beside whatever a character already owns. A ground garage recalls what
--     you parked; a pad also issues what the division flies.
--   * IT IS GATED. Every pad below is behind the job gate
--     (`lib/shared/jobgate.lua`, the same decision an armoury, a lift floor and
--     a hauling site make): only the jobs in `JOBS`, on the duty state
--     `ON_DUTY` names, may list what is parked there, bring one out, or put
--     one away. A division's aircraft is not a car any character may recall.
--
-- WHAT IS THE SAME AND DELIBERATELY SO. `KIND = 'avpad'` is the only KIND this
-- file accepts -- a ground garage belongs in `config/garages.lua`, beside the
-- other ground garages -- and the blocks below are shaped exactly as that
-- file's are, down to the MENU/ENTRY/EXITS triple. The keys live in the same
-- space as every garage's: a vehicle's `garage` column may hold any of them,
-- and a key is NEVER renamed, because renaming one orphans every vehicle filed
-- under it.
--
-- HOW TO CAPTURE ONE -- THE SAME BARGAIN AS THE HEADQUARTERS. Stand where the
-- pad should be and run `/opx.avgarages.add [key] [label]`: the server reads
-- where you stand and which way you face (HEADING is the yaw a recalled AV is
-- created with), saves the pad, draws it for everyone at once, and answers with
-- the block to paste below. Capture for today, config for ever: the block in
-- THIS file is the record that outlives a database reset, and `/opx.avgarages.remove`
-- takes a captured pad away again. `/opx.admin.self.pos` still copies
-- `{ NAME, LABEL, X, Y, Z, HEADING }` for the operator filling a MENU, an ENTRY
-- or an EXIT below by hand.
--
-- The marker vocabulary is fixed by the engine: styles are `interaction`,
-- `objective`, `spawn` and `danger`, shapes are `ring` and `cylinder`, RADIUS
-- is 0.1..50 and MAX_DISTANCE is 1..500. `config/garages.lua` owns the marker
-- LOOK for every pad -- `MARKER.avpad` and `MARKER.entry` there apply here too,
-- because a pad drawn one way in a hangar and another way at a dealer is a pad
-- a player has to learn twice.

OPX.Config.MODULES.avgarages = {
	enabled = true,

	-- WHO MAY USE A PAD HERE. `JOBS` is `{ jobName = minimumGrade }`, and
	-- `ON_DUTY` says whether they must be clocked on. The gate is
	-- `lib/shared/jobgate.lua` through the garages module's own adapter, so
	-- these two fields mean exactly what they mean on a lift floor, an armory
	-- bench and a hauling site: a holder of the job at the grade, in the duty
	-- state named, passes; everybody else is refused BY NAME -- job, grade or
	-- duty, whichever they were closest to.
	--
	-- AN ABSENT OR EMPTIED JOBS CLOSES EVERY PAD BELOW TO EVERYBODY. The owner
	-- decided a hangar is never public by accident: a pad the gate names no
	-- crew for refuses the list, the bring-out and the put-away alike
	-- (`garages.padClosed`), and the boot journal says so. A public pad belongs
	-- in config/garages.lua, which has no gate.
	--
	-- `ncpd_maxtac` USED TO SIT BESIDE `maxtac` HERE AND IS GONE (2026-09-26).
	-- It was a draft division name: the character catalogue never defined it,
	-- and no character row in any database on the box holds it -- both
	-- schemas, live and deleted, checked. A gate list is not a place for
	-- folklore; a name that matches nobody invites the next reader to invent
	-- the job it names.
	JOBS = { maxtac = 0 },
	ON_DUTY = true,

	-- WHERE THE RECALLING PILOT SITS. An aircraft comes out of a pad hovering a
	-- lift above the marker, and the only seat that ever mattered is the one the
	-- flight controls are authored at: the platform flies an AV from ANY seat a
	-- body holds (`VehicleReplication` promotes whichever seat its pilot took),
	-- but "pilotable from inside" starts with being INSIDE -- so the moment the
	-- hull exists, the owner who recalled it is placed at the controls rather
	-- than left to find the mount of a hovering airframe.
	--
	-- A canonical seat name -- `seat_front_left`, `seat_front_right`,
	-- `seat_back_left` or `seat_back_right` -- and `false` for "hands off": the
	-- recall then behaves as it always did and the pilot climbs in themselves.
	-- A name the platform cannot spell is a boot problem and no seat at all,
	-- never a silently substituted one.
	PILOT_SEAT = 'seat_front_left',

	-- THE DIVISION'S OWN AIRCRAFT: every hull a pad may hand out, the MaxTac
	-- birds included. The rows ride the hangar menu beside the vehicles a
	-- character already owns, so "all the AVs" is one list an operator edits
	-- rather than a code change.
	--
	-- NOT TO BE CONFUSED WITH THE JOB FLEET. The AV the MaxTac role needs is
	-- already at the top of every pad's list for every operator on duty, BY
	-- DEFAULT and never owned -- `config/garages.lua` JOB_VEHICLES, under the
	-- job's own caption. What this list adds below it is stock a pad ISSUES,
	-- which then belongs to whoever drew it.
	--
	-- A picked hull is ISSUED, not borrowed: it is registered under the
	-- character's name and filed at the pad, so it stores, recalls and persists
	-- exactly like a vehicle they own -- and it counts against the garage limit
	-- the vehicles module enforces, because a division's stock is drawn on and
	-- never duplicated. WHO may draw is the gate above; WHAT may be drawn is
	-- this list, and a record not on it is refused by name even when a client
	-- asks for it directly.
	--
	-- AN ISSUED HULL STAYS WITH THE JOB, NOT THE MEMBER. The row remembers which
	-- job issued it and at what floor; the moment its holder no longer holds
	-- that job at that grade -- fired, a notice handed in, demoted below the
	-- floor, or taken off the job by an operator, online or offline -- the hull
	-- goes back to the fleet: every key to it is revoked, it is taken out of the
	-- world if it is out, and the row is deleted. Clocking off does not count.
	--
	-- RECORD is the TweakDB vehicle record. LABEL is the operator's own words
	-- and is never translated -- a row shows it exactly as a station shows its
	-- LABEL -- and an absent LABEL shows the record. The order below is the
	-- menu's order. A pad may carry its own `FLEET = { ... }` to replace this
	-- list, or `FLEET = false` to issue nothing at all -- and `FLEET = {}` is
	-- that same choice said another way. Both read as "this garage issues none
	-- of the division's aircraft"; "the hangar does not issue that hull" is
	-- only ever said by a pad that HAS a list, about a record not on it.
	--
	-- The drones, the public trains, `av_test` and the cosmetic `_quest` /
	-- `_no_thruster` variants are left out of the shipped list on purpose: a
	-- hangar issues aircraft a crew flies. Add any of them here if this server
	-- wants them.
	--
	-- AND THREE RECORDS NO GAME CAN DRAW. `Vehicle.av_luxury`,
	-- `Vehicle.av_militech` and `Vehicle.av_trauma` name entity templates that
	-- are in none of the game's archives (2.31, base and Phantom Liberty: their
	-- resource hashes are missing from all 584,344 files), so a hull issued in one
	-- is registered by every game and never drawn -- the bot lab heard the Trauma
	-- Team's AV and never saw it (2026-10-07). `q001_luxury_av` and
	-- `q001_trauma_av` below are the same aircraft with templates that exist.
	-- Every record left here was checked the same way.
	FLEET = {
		{ RECORD = 'Vehicle.av_militech_manticore', LABEL = 'Militech Manticore' },
		{ RECORD = 'Vehicle.av_rayfield_excalibur', LABEL = 'Rayfield Excalibur' },
		{ RECORD = 'Vehicle.av_kurt_barghest', LABEL = 'Barghest AV' },
		{ RECORD = 'Vehicle.av_zetatech_atlus', LABEL = 'Zetatech Atlus' },
		{ RECORD = 'Vehicle.av_zetatech_octant', LABEL = 'Zetatech Octant' },
		{ RECORD = 'Vehicle.av_zetatech_surveyor', LABEL = 'Zetatech Surveyor' },
		{ RECORD = 'Vehicle.av_zetatech_valgus', LABEL = 'Zetatech Valgus' },
		{ RECORD = 'Vehicle.batty_av', LABEL = 'Batty AV' },
		{ RECORD = 'Vehicle.q001_luxury_av', LABEL = 'Luxury AV' },
		{ RECORD = 'Vehicle.q001_police_av', LABEL = 'Police AV' },
		{ RECORD = 'Vehicle.q001_trauma_av', LABEL = 'Trauma Team AV' },
		{ RECORD = 'Vehicle.mq027_news_av', LABEL = 'Zetatech News AV' },
		{ RECORD = 'Vehicle.q110_huge_cargo_av', LABEL = 'Cargo AV' },
		{ RECORD = 'Vehicle.q110_max_tac_heli', LABEL = 'MaxTac Helicopter' },
		{ RECORD = 'Vehicle.max_tac_av', LABEL = 'MaxTac AV' },
		{ RECORD = 'Vehicle.max_tac_av1', LABEL = 'MaxTac AV 1' },
		{ RECORD = 'Vehicle.max_tac_av2', LABEL = 'MaxTac AV 2' },
		{ RECORD = 'Vehicle.max_tac_av3', LABEL = 'MaxTac AV 3' },
		{ RECORD = 'Vehicle.max_tac_av_2nd_wave1', LABEL = 'MaxTac AV (2nd wave 1)' },
		{ RECORD = 'Vehicle.max_tac_av_2nd_wave2', LABEL = 'MaxTac AV (2nd wave 2)' },
		{ RECORD = 'Vehicle.max_tac_av_2nd_wave3', LABEL = 'MaxTac AV (2nd wave 3)' },
		{ RECORD = 'Vehicle.mq030_max_tac_av', LABEL = 'MaxTac AV (MQ030)' },
		{ RECORD = 'Vehicle.q001_max_tac_av', LABEL = 'MaxTac AV (Q001)' },
		{ RECORD = 'Vehicle.q001_maxtac_av', LABEL = 'MaxTac AV (Q001 variant)' },
		{ RECORD = 'Vehicle.q304_max_tac_av', LABEL = 'MaxTac AV (Q304)' },
		{ RECORD = 'Vehicle.q304_max_tac_av_detailed', LABEL = 'MaxTac AV (Q304 detailed)' },
	},

	-- THE CAPTURE COMMANDS, and nothing is named when a name is emptied:
	-- `add = ''` switches the capture path off and leaves the file the whole
	-- placement path again. Both are ACL-gated like every other placement
	-- command (`command.<name>` in acl.jsonc).
	COMMANDS = {
		add = 'opx.avgarages.add',
		remove = 'opx.avgarages.remove',
	},

	-- EVERY MAXTAC AV PAD ON THE SERVER, in the exact block shape
	-- `config/garages.lua` uses.
	--
	-- LABEL is the operator's own words and is never translated. KIND must be
	-- `avpad`; a block naming `garage` here is refused at boot with a warning,
	-- because a ground garage in the division's hangar file is a garage the
	-- operator will look for in the wrong file.
	--
	-- NOTHING IS SHIPPED HERE, on purpose: a pad at a coordinate nobody ever
	-- stood at is a pad an AV cannot land on. Stand where the pad goes -- at
	-- the headquarters `config/headquarters.lua` designates -- run
	-- `/opx.avgarages.add`, and paste the block it answers with (the shape of
	-- the one commented out below).
	GARAGES = {
		-- maxtac_av1 = {
		-- 	LABEL = 'MaxTac AV pad',
		-- 	KIND = 'avpad',
		-- 	LOCATIONS = {
		-- 		{
		-- 			BUCKET = 0,
		-- 			MENU = { X = -1527.21, Y = -218.56, Z = 7.86 },
		-- 			ENTRY = { X = -1527.21, Y = -218.56, Z = 7.86, HEADING = 199.6 },
		-- 			EXITS = {
		-- 				{ X = -1527.21, Y = -218.56, Z = 7.86, HEADING = 199.6 },
		-- 			},
		-- 		},
		-- 	},
		-- },
	},
}
