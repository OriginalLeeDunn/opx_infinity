--- Workplace: duty points, locker rooms and motor pools, per job and station.
-- @author dop42
--
-- SEVERAL STATIONS A JOB, EACH ON ITS OWN. A station belongs to ONE job of
-- config/character.lua JOBS and holds up to three points -- DUTY, WARDROBE,
-- GARAGE (with its PAD) -- each optional. A station the validator refuses is
-- refused ALONE, with a line at boot naming it.
--
-- POSITIONS 0, 0, 0 ARE "NOT SURVEYED YET". A point left at three exact zeros
-- is DISABLED -- no eye row, no request -- and named at boot; a garage whose
-- PAD is at zeros is disabled too. Stand on the spot and run
-- `/opx.workplace.capture <station> <duty|wardrobe|garage|pad>`, which prints
-- the line to paste here (the pad line carries your heading).
-- `/opx.workplace.stations` lists what is open, disabled and refused.
--
-- OUTFITS and FLEET are per JOB, shared by every station of that job; a
-- station's GARAGE may narrow its fleet with VEHICLES = { 'key', ... }.
-- MIN_GRADE is the job grade level needed (config/character.lua grades).
--
-- A UNIFORM is a set of equipment slots: Head, Face, InnerChest, OuterChest,
-- Legs, Feet, Outfit, each an `Items.*` clothing record (the fitting room's
-- catalogue, modules/appearance/data). A slot the uniform does not name is
-- emptied, unless KEEP_OTHERS = true; FEMALE / MALE override slots for that
-- body family. Underwear is never touched.

OPX.Config.MODULES.workplace = {
	enabled = true,

	-- Floor between two requests from one player, in milliseconds.
	REQUEST_MS = 800,

	-- Clocking in at a station of a job the character holds as a SECONDARY
	-- membership makes it their primary job first (character SetPlayerPrimaryJob).
	-- false refuses instead and asks them to switch job.
	SWITCH_PRIMARY = true,

	WARDROBE = {
		-- A uniform needs the job on duty (jobs with defaultDuty always are).
		ON_DUTY = true,
		-- Going off duty, or losing the job, puts the civilian look back.
		RESTORE_OFF_DUTY = true,
		-- The character metadata key the civilian look is kept under while a
		-- uniform is worn. Survives a logout: the look is never lost.
		METADATA = 'workplace_civvies',
	},

	GARAGE = {
		-- A service vehicle needs the job on duty (defaultDuty jobs always are).
		ON_DUTY = true,
		-- The host removes a service vehicle nobody handed back after this long.
		TTL_MIN = 180,
		-- How close to the pad the vehicle must be to be handed back, metres.
		RETURN_RADIUS = 15.0,
		-- No spawn while another vehicle stands this close to the pad, metres.
		PAD_CLEAR = 3.0,
		-- Most service vehicles out at once from one station; 0 for no ceiling.
		MAX_PER_STATION = 0,
	},

	-- ── uniforms, per job ──────────────────────────────────────────────────
	OUTFITS = {
		ncpd = {
			patrol = { LABEL = 'NCPD patrol uniform', MIN_GRADE = 0,
				WEAR = { Outfit = 'Items.SQ029_Police_Suit' } },
			street = { LABEL = 'NCPD street kit', MIN_GRADE = 1,
				WEAR = { OuterChest = 'Items.Cop_01_Set_Jacket', Legs = 'Items.Cop_01_Set_Pants',
					Feet = 'Items.Cop_01_Set_Boots', Face = 'Items.Cop_01_Set_Glasses' } },
			detective = { LABEL = 'Detective plainclothes', MIN_GRADE = 2,
				WEAR = { OuterChest = 'Items.Corporate_01_Set_FormalJacket',
					InnerChest = 'Items.Corporate_01_Set_FormalShirt', Legs = 'Items.Corporate_01_Set_Pants',
					Feet = 'Items.Corporate_01_Set_FormalShoes' } },
		},
		maxtac = {
			tactical = { LABEL = 'MaxTac tactical armor', MIN_GRADE = 0,
				WEAR = { Head = 'Items.SQ030_MaxTac_Helmet', OuterChest = 'Items.SQ030_MaxTac_Chest',
					Legs = 'Items.SQ030_MaxTac_Pants' } },
		},
		trauma = {
			response = { LABEL = 'Trauma Team uniform', MIN_GRADE = 0,
				WEAR = { Outfit = 'Items.Trauma_Team_Outfit' } },
		},
		arasaka = {
			office = { LABEL = 'Arasaka office suit', MIN_GRADE = 0,
				WEAR = { OuterChest = 'Items.FormalJacket_05_basic_02',
					InnerChest = 'Items.Corporate_01_Set_FormalShirt', Legs = 'Items.Corporate_01_Set_Pants',
					Feet = 'Items.Corporate_01_Set_FormalShoes' },
				FEMALE = { Legs = 'Items.FormalSkirt_01_rich_03' } },
			security = { LABEL = 'Arasaka security detail', MIN_GRADE = 1,
				WEAR = { Head = 'Items.Helmet_07_basic_01', OuterChest = 'Items.Vest_01_basic_02',
					Face = 'Items.Visor_02_basic_02', Legs = 'Items.Corporate_01_Set_Pants',
					Feet = 'Items.Corporate_01_Set_FormalShoes' } },
		},
		militech = {
			field = { LABEL = 'Militech field suit', MIN_GRADE = 0,
				WEAR = { Outfit = 'Items.Q005_Militech_Suit' } },
		},
		cabbie = {
			driver = { LABEL = 'Delamain driver suit', MIN_GRADE = 0,
				WEAR = { OuterChest = 'Items.Q000_Corpo_FormalJacket', Legs = 'Items.Q000_Corpo_FormalPants',
					Feet = 'Items.Q000_Corpo_FormalShoes' }, KEEP_OTHERS = true },
		},
		ripperdoc = {
			scrubs = { LABEL = 'Clinic coat', MIN_GRADE = 0,
				WEAR = { OuterChest = 'Items.Corporate_01_Set_FormalShirt' }, KEEP_OTHERS = true },
		},
		bartender = {
			bar = { LABEL = 'Bar staff shirt', MIN_GRADE = 0,
				WEAR = { InnerChest = 'Items.Corporate_01_Set_FormalShirt', Legs = 'Items.Corporate_01_Set_Pants' },
				KEEP_OTHERS = true },
		},
	},

	-- ── service fleets, per job ────────────────────────────────────────────
	--
	-- RECORD is a TweakDB vehicle record. PRIMARY / SECONDARY are optional
	-- paint { r, g, b }. Sirens and lights are the police module's business.
	FLEET = {
		ncpd = {
			cortes = { LABEL = 'Villefort Cortes patrol car', RECORD = 'Vehicle.v_standard2_villefort_cortes_police',
				MIN_GRADE = 0 },
			apollo = { LABEL = 'Brennan Apollo police bike', RECORD = 'Vehicle.v_sportbike3_brennan_apollo_police',
				MIN_GRADE = 1 },
			emperor = { LABEL = 'Chevalier Emperor unit', RECORD = 'Vehicle.v_standard3_chevalier_emperor_police',
				MIN_GRADE = 1 },
			merrimac = { LABEL = 'Thorton Merrimac interceptor', RECORD = 'Vehicle.v_standard25_thorton_merrimac_police',
				MIN_GRADE = 2 },
			behemoth = { LABEL = 'Militech Behemoth riot truck', RECORD = 'Vehicle.v_utility4_militech_behemoth_police',
				MIN_GRADE = 3 },
		},
		maxtac = {
			merrimac = { LABEL = 'MaxTac Merrimac', RECORD = 'Vehicle.v_standard25_thorton_merrimac_maxtac', MIN_GRADE = 0 },
			behemoth = { LABEL = 'MaxTac Behemoth', RECORD = 'Vehicle.v_utility4_militech_behemoth_maxtac', MIN_GRADE = 1 },
		},
		trauma = {
			responder = { LABEL = 'Trauma Team ground responder', RECORD = 'Vehicle.v_utility4_militech_behemoth',
				MIN_GRADE = 0, PRIMARY = { r = 230, g = 230, b = 230 }, SECONDARY = { r = 20, g = 90, b = 200 } },
		},
		arasaka = {
			cortes = { LABEL = 'Arasaka Cortes', RECORD = 'Vehicle.v_standard2_villefort_cortes_arasaka', MIN_GRADE = 0 },
			columbus = { LABEL = 'Arasaka Columbus van', RECORD = 'Vehicle.v_standard25_villefort_columbus_arasaka',
				MIN_GRADE = 1 },
		},
		militech = {
			emperor = { LABEL = 'Militech Emperor', RECORD = 'Vehicle.v_standard3_chevalier_emperor_militech', MIN_GRADE = 0 },
			hellhound = { LABEL = 'Militech Hellhound', RECORD = 'Vehicle.v_standard3_militech_hellhound_player',
				MIN_GRADE = 1 },
			basilisk = { LABEL = 'Militech Basilisk', RECORD = 'Vehicle.v_militech_basilisk_militech', MIN_GRADE = 3 },
		},
		cabbie = {
			cortes = { LABEL = 'Delamain Cortes cab', RECORD = 'Vehicle.v_standard2_villefort_cortes_delamain_taxi',
				MIN_GRADE = 0 },
		},
	},

	-- ── the stations ───────────────────────────────────────────────────────
	--
	--   key = {
	--     JOB = '<job>', LABEL = '<Night City place>', BUCKET = 0,
	--     DUTY = { X, Y, Z, RADIUS = 1.5, MIN_GRADE = 0 },
	--     WARDROBE = { X, Y, Z, RADIUS = 1.5 },
	--     GARAGE = { X, Y, Z, RADIUS = 2.0, PAD = { X, Y, Z, HEADING }, VEHICLES = { ... } },
	--   }
	STATIONS = {
		ncpd_kabuki = {
			JOB = 'ncpd', LABEL = 'NCPD precinct, Kabuki', BUCKET = 0,
			DUTY = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, MIN_GRADE = 0 },
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			GARAGE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, PAD = { X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 } },
		},
		ncpd_vista_del_rey = {
			JOB = 'ncpd', LABEL = 'NCPD precinct, Vista del Rey', BUCKET = 0,
			DUTY = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			GARAGE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, PAD = { X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 },
				VEHICLES = { 'cortes', 'apollo' } },
		},
		maxtac_hq = {
			JOB = 'maxtac', LABEL = 'MaxTac hangar, City Center', BUCKET = 0,
			DUTY = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			GARAGE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, PAD = { X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 } },
		},
		trauma_hq = {
			JOB = 'trauma', LABEL = 'Trauma Team International HQ, Corpo Plaza', BUCKET = 0,
			DUTY = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			GARAGE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, PAD = { X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 } },
		},
		ripperdoc_vik = {
			JOB = 'ripperdoc', LABEL = 'Viktor Vektor\'s clinic, Little China', BUCKET = 0,
			DUTY = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
		},
		delamain_hq = {
			-- Delamain drivers are on duty by definition (defaultDuty): no clock.
			JOB = 'cabbie', LABEL = 'Delamain HQ depot, Corpo Plaza', BUCKET = 0,
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			GARAGE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, PAD = { X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 } },
		},
		arasaka_tower = {
			JOB = 'arasaka', LABEL = 'Arasaka Tower lobby, Corpo Plaza', BUCKET = 0,
			DUTY = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			GARAGE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, PAD = { X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 } },
		},
		militech_lobby = {
			JOB = 'militech', LABEL = 'Militech regional office lobby, Corpo Plaza', BUCKET = 0,
			DUTY = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			GARAGE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, PAD = { X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 } },
		},
		afterlife = {
			-- Bartenders are on duty by definition (defaultDuty): no clock.
			JOB = 'bartender', LABEL = 'The Afterlife, Little China', BUCKET = 0,
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
		},
		lizzies_bar = {
			JOB = 'bartender', LABEL = 'Lizzie\'s Bar, Kabuki', BUCKET = 0,
			WARDROBE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
		},
	},
}
