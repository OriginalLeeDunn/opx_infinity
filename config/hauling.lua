--- Hauling: the sites, the crates, the vehicles that carry them and the pay.
-- @author dop42
--
-- A SITE IS A LIST OF POINTS AND A LIST OF DROP-OFFS. The server puts one crate
-- on each free point, players race to claim one, carry it, load it into a
-- vehicle, drive it to a drop-off and are paid. There is no `/start`: the ALT
-- target eye on a crate is the whole entry, and a site is "open" for as long as
-- it has crates on it.
--
-- `POINTS` IS THE STRUCTURAL CAP ON THE REFILL LOOP. One crate per point, so the
-- loop cannot overfill the world: there is nowhere to put an extra crate. That
-- is the first of three belts. `MAX_CRATES` below is the second, counted across
-- every site. The platform's own ceiling -- 2,048 props per resource, 8,192 in
-- the registry -- is the third and the only one that is not ours to move.
--
-- ============================================================================
-- EVERY POSITION IN THIS FILE IS A PLACEHOLDER AND THE MODULE REFUSES TO USE ONE
-- ============================================================================
--
-- `config/elevators.lua` in this same tree is the cautionary tale and the reason
-- this block is written the way it is. Four lifts shipped with positions carried
-- over from a standalone resource that had said they were samples; the warning
-- did not survive the port, the coordinates passed every shape check the
-- validator made -- finite numbers, whole indexes, a LABEL on every row -- and
-- they matched nothing in Night City. The failure was silent and it was total:
-- no lift was ever adopted and no panel ever opened, for weeks, with a green
-- test suite behind it.
--
-- So a point whose X, Y and Z are all exactly zero is treated here as what it
-- is -- an unfilled blank -- and a SITE THAT HOLDS ONE IS DISABLED at boot with
-- a line naming it. Nothing is spawned there. That is deliberately louder than a
-- warning: a hauling job whose crates never appear looks exactly like a hauling
-- job nobody has walked past yet, and the operator would have no way to tell.
--
-- To make a site real, stand on each spot in game and read your own position off
-- the client developer console, then paste it into a POINTS row. The same for
-- each DROPOFFS entry. Points must be at least MIN_POINT_GAP metres apart, or
-- two crates spawn inside each other and the target eye can only ever pick the
-- nearer one.
--
-- THE MODEL IS A CURATED ALIAS AND NEVER A `.mesh` PATH. A raw depot mesh path
-- renders as placeholder geometry AND CANNOT BE ATTACHED AT ALL -- which for
-- this job means the pickup succeeds, the crate vanishes into the carrier, and
-- nothing is ever visibly carried. `crate.small` is the default because it is
-- the one alias in the shipped examples that has actually been carried and
-- hand-tuned by somebody standing in front of it.
--
-- `Open77.props.catalog()` ON THE SERVER IS ALWAYS AN EMPTY TABLE, so a MODEL
-- cannot be checked against a list here. The server half checks it by TRYING:
-- at boot it creates one crate at a site's first point, and a site whose model
-- answers `unknown_alias` is disabled with a line rather than left to spawn
-- nothing for the rest of the session.

OPX.Config.MODULES.hauling = {
	enabled = true,

	-- The crate alias every site uses unless it names its own MODEL. A curated
	-- alias, never a path -- see the header.
	MODEL = 'crate.small',

	-- Crates this module may have standing in the world at once, across every
	-- site. The second belt: POINTS already caps each site, and this caps the sum
	-- so a config that grows six sites past anyone's attention still cannot walk
	-- into the platform's per-resource prop ceiling.
	MAX_CRATES = 64,

	-- How long each bar takes, in milliseconds.
	--
	-- THE SERVER OWNS THIS CLOCK. `modules/progress` is client-side only, so the
	-- bar a player sees is a bar their own machine is counting and a patched
	-- client can count it to zero instantly. The server stamps the claim and
	-- refuses a completion that arrives sooner than PICKUP_MS minus the tolerance
	-- below; the bar is presentation, the stamp is the rule.
	PICKUP_MS = 4000,
	LOAD_MS = 3000,
	DELIVER_MS = 5000,

	-- Milliseconds a completion may arrive early and still be believed. It covers
	-- the round trip and the client's own frame granularity, and nothing else. Set
	-- it to zero and an honest player on a bad connection is refused; set it to
	-- PICKUP_MS and the check is gone.
	CLOCK_TOLERANCE_MS = 500,

	-- CLAIMS EXPIRE. A player who claims a crate and then walks away, alt-tabs or
	-- stands in a menu would otherwise freeze that crate for everybody for the
	-- life of the process -- and one frozen crate on a four-point site is a
	-- quarter of the job gone. The reap pass releases any claim older than the
	-- bar it was taken for plus this grace.
	--
	-- Both shipped examples release a claim only on disconnect. That alone is
	-- what this number exists to fix.
	CLAIM_GRACE_MS = 20000,

	-- Metres a player may stand from a crate and still act on it, and from a
	-- vehicle to load into it. Checked ON THE SERVER, from the server's own
	-- reading of the player's position -- the client's row is a hint about what to
	-- draw and is never believed.
	--
	-- THE SERVER HAS NO PHYSICS WORLD, so there is no line of sight in either
	-- number: a player on the floor above a crate is "within 3 metres" of it and
	-- the server cannot tell. Keep them small.
	REACH = 3.0,
	VEHICLE_REACH = 4.5,

	-- Metres two POINTS of one site must be apart. Closer than this and two crates
	-- overlap: the eye picks whichever mesh the ray meets first and the other is
	-- unreachable.
	MIN_POINT_GAP = 2.0,

	-- How often the refill-and-reap pass runs, in milliseconds. Also declared as
	-- the HAUL_REFILL_MS tunable by the server half, which re-reads it every pass
	-- -- so an operator retunes the spawn rate from the panel without a restart.
	REFILL_MS = 60000,

	-- What a delivered crate pays, and out of which pocket. A site may name its
	-- own PAY. `EDDIES` is cash and `BANK` is the account; the pair is in
	-- `config/shared.lua`.
	PAY_PER_CRATE = 150,
	CURRENCY = 'EDDIES',

	-- WHICH ROW THE TARGET EYE DRAWS THE CRATE UNDER.
	--
	-- `prop` registers ONE row against the `prop` target kind and filters it with
	-- a table lookup on the prop id the server pushed. It is constant work per
	-- pick, needs no periodic job at all, and the eye lands on the crate mesh
	-- itself, so aiming is exact.
	--
	-- `world` is the fallback for a build whose screen ray does not report a
	-- server-owned prop as `kind = 'prop'`. It registers one row against any bare
	-- surface and matches the hit POINT against the crate positions the server
	-- pushed, within REACH. Still one row, still no periodic job -- but the player
	-- aims at the ground near the crate rather than at the crate.
	--
	-- Change this only if crates visibly exist and the eye offers nothing on them.
	TARGET_KIND = 'prop',

	-- HOW A CARRIED CRATE SITS ON THE BODY. UNTUNED HERE.
	--
	-- These numbers are `rp_nomade`'s, measured in game against `crate.small` and
	-- its own carry pose on 2026-09-19. They are the best starting point anyone
	-- has, and they are still somebody else's measurement of somebody else's
	-- animation: expect to move them.
	--
	-- `BONE` is a named slot of the player rig -- "RightHand", "LeftHand",
	-- "Chest", "Head" -- or "" for the body root. A hand slot follows the arm
	-- swing and the crate swings with it; the chest keeps the box level whatever
	-- the arms do, which is what a two-handed carry looks like. A slot the rig
	-- does not expose hides the crate entirely, and "" always exists.
	--
	-- OFFSET is metres in that slot's own frame, each axis within 20; ROTATION is
	-- degrees, each within 360. If the box sits inside the body, raise the axis
	-- that points forward; if it floats, lower the one that points up.
	CARRY = {
		BONE = 'Chest',
		OFFSET = { x = -0.135, y = -0.60, z = 0.008 },
		ROTATION = { x = 0.0, y = 90.0, z = 0.0 },
	},

	-- WHAT THE PLAYER DOES WHILE THE PICKUP BAR RUNS. The owner, 2026-09-24: "il
	-- y a pas une animation qui peut etre play quand on prend le props ? une
	-- bonne animation". A kneeling workspot from the platform's own catalogue
	-- (`open77_animations/shared/catalog.lua`), played for the length of the bar;
	-- `carry_pickup` then lifts the crate and `carry` holds it.
	--
	--   'scavenge'  kneel, both hands working at something on the ground
	--   'examine'   kneel and look the thing over
	--   'repair'    kneel with a screwdriver (the workspot brings its own)
	--   'mechanic'  kneel with a wrench (the workspot brings its own)
	--   ''          none: the player just stands through the bar
	--
	-- A SITE MAY NAME ITS OWN PICKUP_POSE, and its own MODEL and CARRY: the owner,
	-- 2026-09-24, "des props plus logique pour les zone et des animation
	-- differente". CARRY belongs to the model -- the numbers below are measured on
	-- `crate.small` -- so a site whose box sits wrong in the hands gets its own
	-- CARRY block rather than a change here. The carry itself stays `carry` on
	-- every site: it is the only two-handed carry the platform ships, and
	-- `hold_item_walk` spawns a soda can of its own.
	--
	-- Both are marked `asset_verified_runtime_pending` by the platform, and a
	-- workspot ends if the player walks off -- which ends nothing else.
	PICKUP_POSE = 'scavenge',

	-- PUTTING A CARRIED CRATE DOWN. The owner, 2026-09-23: "pendant qu'on carry
	-- ont peux faire x pour la drop". DROP_KEY is the default binding (players
	-- rebind it under Pause -> Settings -> KEY BINDINGS); the crate lands
	-- DROP_DISTANCE metres in front of the player and anyone may pick it up.
	--
	-- A dropped crate still holds its point, so one left lying in an alley would
	-- take that point out of the job for good. After DROP_RETURN_MS untouched it
	-- goes back to its point on the next refill pass.
	DROP_KEY = 'X',
	DROP_DISTANCE = 0.7,
	DROP_RETURN_MS = 300000,

	-- WHAT A LOADED CRATE BECOMES. Loading takes the crate out of the world and
	-- puts one of this item in the vehicle's trunk, tagged with the site it came
	-- from (`metadata.site`), which is what a drop-off pays by. Declared in
	-- `modules/inventory/data/items.lua`; its WEIGHT is what caps a trunk.
	--
	-- THE OWNER, 2026-09-23: "des qu'il pose dans le vehicule cela deviens un
	-- item". The crate used to be bolted into the bed as a prop, which needed a
	-- measured bed per vehicle and never had one.
	--
	-- A delivery sells every crate of the site at one of its DROPOFFS, in one
	-- bar: the ones in the seller's BAG, and the ones in the trunk of every
	-- vehicle parked inside the drop-off that the seller owns or holds the key
	-- to (an unowned truck somebody else drove there is not theirs to sell from).
	-- Bag sales are deliberate -- `adult_shop_clouds.sale` below is up a building
	-- where no vehicle can park, and sells out of the bag only.
	ITEM = 'hauling_crate',

	-- primary reads the worked job; any counts every membership for the grade but
	-- never for ON_DUTY, because the memberships table carries grades and not a
	-- clock. The same word, with the same two values, on `config/elevators.lua`,
	-- `config/teleports.lua` and `config/gunsmith.lua`: a site's JOBS block is
	-- decided by the one gate in `lib/shared/jobgate.lua`.
	MEMBERSHIP = 'primary',

	-- ========================================================================
	-- THE TWO SITES BELOW ARE SAMPLES. EVERY POSITION IN THEM IS A PLACEHOLDER
	-- ZERO AND BOTH SITES ARE THEREFORE DISABLED AT BOOT. See the header.
	-- ========================================================================
	--
	-- A site's key is its durable name: it is what the log lines say, what the
	-- crate records are grouped under, and what an operator types at the
	-- diagnostic. It never changes.
	--
	-- JOBS IS DELIBERATELY ABSENT FROM BOTH. The owner asked for a job-free job,
	-- which reads as "no whitelist" and not as "unpaid": anyone may haul, and
	-- hauling pays. Adding `JOBS = { nomad = 0 }` to a site makes it a whitelist,
	-- and `ON_DUTY = true` beside it narrows that to whoever is clocked on.
	SITES = {
		docks = {
			LABEL = 'DOCKS YARD',
			BUCKET = 0,

			-- One crate per point. PLACEHOLDERS -- survey these.
			POINTS = {
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
			},

			-- What the target eye says on a crate of this site. The operator's own
			-- words, not translated.
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Heavy. Get it into a vehicle.',
				ICON = 'box',
			},

			-- Crates the refill pass may add in one pass, so a freshly emptied site
			-- refills over a few minutes instead of all at once.
			SPAWN_PER_PASS = 2,

			-- Milliseconds a point stays empty after its crate leaves it. Without
			-- this a delivered crate is replaced before the driver is out of the
			-- yard and the site never reads as worked.
			RESPAWN_MS = 120000,

			-- Several destinations per site is the same code, and it is the first
			-- thing anyone asks for after the second site. RADIUS is metres.
			-- PLACEHOLDERS -- survey these too.
			DROPOFFS = {
				warehouse = { LABEL = 'Warehouse', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorMale', YAW = 0.0 } },
				yard = { LABEL = 'Back Yard', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorFemale', YAW = 0.0 } },
			},
		},

		-- Surveyed in game on 2026-09-23. The two crates are 2.14m apart, just
		-- over MIN_POINT_GAP: move one and check the gap.
		pacifica_butcher = {
			LABEL = 'Butcher shop and market',
			BUCKET = 0,
			-- market delivery crate.
			MODEL = 'crate.delivery',
			PICKUP_POSE = 'scavenge',

			-- Where the map pin goes. Without it the pin falls on the first point.
			BLIP = { X = -1819.71, Y = -1970.77, Z = 52.50 },

			POINTS = {
				{ X = -1816.63, Y = -1977.91, Z = 52.50, YAW = 248.1 },
				{ X = -1815.79, Y = -1975.94, Z = 52.50, YAW = 246.9 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Market stock. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,

			-- A drop-off is a seller: ALT on its NPC, then sell. Every crate of this
			-- site in the player's bag, and in the trunk of any vehicle
			-- parked within RADIUS, goes in one bar. The sale point is ~14m from the
			-- crates; RADIUS 6 keeps a truck loading at the crates out of it.
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = -1819.13, Y = -1964.37, Z = 51.50, RADIUS = 6.0,
					NPC = { RECORD = 'Character.VendorMale', YAW = 254.0 },
				},
			},
		},

		-- ── Surveyed in game by LucReali on 2026-09-24 ──────────────────────────
		-- Their "Prop" rows are POINTS and their "Sale" rows are DROPOFFS, headings
		-- as YAW. Their "Compra" (buy) rows have no counterpart here -- hauling has
		-- no start point -- and are not used. Every sale is far from its crates,
		-- so RADIUS 8 cannot reach a truck loading in the yard.

		dakota = {
			LABEL = 'Dakota',
			BUCKET = 0,
			-- a Badlands fixer: an ammo box.
			MODEL = 'crate.ammo_box',
			PICKUP_POSE = 'examine',
			POINTS = {
				{ X = 2594.36, Y = -53.31, Z = 84.86, YAW = 124.7 },
				{ X = 2593.03, Y = -58.59, Z = 84.89, YAW = 38.7 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Badlands stock. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = 2415.83, Y = -790.27, Z = 66.66, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorMale', YAW = 352.9 },
				},
			},
		},

		parking_megabuilding_06 = {
			LABEL = 'Parking + Megabuilding 06',
			BUCKET = 0,
			-- building supplies in a wooden crate.
			MODEL = 'crate.small',
			PICKUP_POSE = 'scavenge',
			POINTS = {
				{ X = -526.35, Y = -1325.51, Z = 11.88, YAW = 135.3 },
				{ X = -519.45, Y = -1330.41, Z = 11.93, YAW = 136.3 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Building supplies. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = -192.91, Y = -877.58, Z = 11.46, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorFemale', YAW = 20.7 },
				},
			},
		},

		mechanic = {
			LABEL = 'Mechanic',
			BUCKET = 0,
			-- spare parts: a toolbox, kneeling with a wrench.
			MODEL = 'container.toolbox',
			PICKUP_POSE = 'mechanic',
			POINTS = {
				{ X = -2456.16, Y = -909.03, Z = 9.26, YAW = 269.9 },
				{ X = -2465.86, Y = -905.14, Z = 8.16, YAW = 177.6 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Spare parts. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = -2043.13, Y = -602.83, Z = 2.84, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorMale', YAW = 85.8 },
				},
			},
		},

		airport_pharmacy = {
			LABEL = 'Airport pharmacy',
			BUCKET = 0,
			-- medical stock: a medical container.
			MODEL = 'medical.container',
			PICKUP_POSE = 'examine',
			POINTS = {
				{ X = -3584.61, Y = 365.48, Z = 32.52, YAW = 264.9 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Medical stock. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = -1361.08, Y = 617.55, Z = 4.44, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorFemale', YAW = 180.2 },
				},
			},
		},

		arasaka_port = {
			LABEL = 'Arasaka port',
			BUCKET = 0,
			-- corporate freight: a sealed case.
			MODEL = 'military.case',
			PICKUP_POSE = 'examine',
			POINTS = {
				{ X = -1246.29, Y = 549.03, Z = 7.42, YAW = 328.2 },
				{ X = -1247.52, Y = 578.04, Z = 4.85, YAW = 271.6 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Dock freight. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = -1559.54, Y = 618.85, Z = 9.30, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorMale', YAW = 254.1 },
				},
			},
		},

		delamain = {
			LABEL = 'Delamain',
			BUCKET = 0,
			-- fleet parts: a toolbox, kneeling with a screwdriver.
			MODEL = 'container.toolbox',
			PICKUP_POSE = 'repair',
			POINTS = {
				{ X = -1013.62, Y = -136.09, Z = 3.51, YAW = 232.4 },
				{ X = -1012.43, Y = -156.83, Z = 3.51, YAW = 322.8 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Fleet parts. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = -1436.29, Y = -179.89, Z = 8.18, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorFemale', YAW = 322.6 },
				},
			},
		},

		waterfront_garage = {
			LABEL = 'Waterfront garage',
			BUCKET = 0,
			-- garage stock in a cardboard box.
			MODEL = 'crate.cardboard',
			PICKUP_POSE = 'repair',
			POINTS = {
				{ X = -2335.01, Y = 536.86, Z = 11.23, YAW = 84.7 },
				{ X = -2342.56, Y = 540.47, Z = 11.23, YAW = 178.9 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Garage stock. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = -1918.49, Y = -121.60, Z = 7.56, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorMale', YAW = 180.7 },
				},
			},
		},

		garage_mechanic = {
			LABEL = 'Garage / Mechanic',
			BUCKET = 0,
			-- spare parts: a toolbox, kneeling with a wrench.
			MODEL = 'container.toolbox',
			PICKUP_POSE = 'mechanic',
			POINTS = {
				{ X = -2381.65, Y = 285.58, Z = 12.98, YAW = 180.2 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Spare parts. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = -2420.51, Y = 465.42, Z = 11.24, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorFemale', YAW = 321.6 },
				},
			},
		},

		-- Two sales. `sale` is at Z 128 -- up a building, so it sells out of a bag
		-- but no vehicle can park inside its RADIUS; `sale_street` is at ground level.
		adult_shop_clouds = {
			LABEL = 'Adult shop & Clouds',
			BUCKET = 0,
			-- club stock, discreetly boxed.
			MODEL = 'crate.cardboard',
			PICKUP_POSE = 'scavenge',
			POINTS = {
				{ X = -865.13, Y = 136.10, Z = 7.29, YAW = 54.8 },
				{ X = -859.39, Y = 130.62, Z = 7.29, YAW = 50.6 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Club stock. Get it into a vehicle.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 120000,
			DROPOFFS = {
				sale = {
					LABEL = 'Sale', X = -662.21, Y = 811.13, Z = 128.27, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorMale', YAW = 62.6 },
				},
				sale_street = {
					LABEL = 'Street sale', X = -666.55, Y = 846.12, Z = 19.49, RADIUS = 8.0,
					NPC = { RECORD = 'Character.VendorFemale', YAW = 345.1 },
				},
			},
		},

		badlands = {
			LABEL = 'BADLANDS DEPOT',
			BUCKET = 0,
			POINTS = {
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
			},
			TARGET = {
				LABEL = 'Pick up the crate',
				DESCRIPTION = 'Depot stock. Somebody wants it moved.',
				ICON = 'box',
			},
			SPAWN_PER_PASS = 1,
			RESPAWN_MS = 180000,
			PAY = 220,
			DROPOFFS = {
				camp = { LABEL = 'Nomad Camp', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 10.0,
					NPC = { RECORD = 'Character.VendorMale', YAW = 0.0 } },
			},
		},
	},
}
