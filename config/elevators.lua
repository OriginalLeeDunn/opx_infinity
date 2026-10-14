--- Elevators: the gate, the scan and every lift.
-- @author dop42
--
-- The durable name of an elevator is its key here: the id the host gives an
-- adopted lift changes at every restart. A floor is named by its NATIVE index,
-- never by its place in FLOORS.
--
-- A distance is measured ACROSS THE GROUND against the DECLARED position, in X
-- and Y; Z is validated and then ignored. So a lift is called from every floor
-- of its own shaft, and someone on the twelfth is as near the panel as someone
-- in the lobby.
--
-- JOBS is job name -> minimum grade level. REASON and LABEL are the operator's
-- own words and are never translated.
--
-- TRAVEL_MS, REQUEST_WINDOW_MS and REQUESTS_PER_WINDOW are also declared as
-- tunables by the server half; the values below are what they fall back to.
--
-- THE FOUR ELEVATORS BELOW ARE SAMPLES AND THEIR X/Y/Z ARE PLACEHOLDERS. They
-- were carried over verbatim from the standalone `opx77_elevators`, whose README
-- said so and whose warning did not survive the port -- so the config has since
-- read as a description of this server's world when it never was one. Not one of
-- the four positions was surveyed against a real shaft, and FLOOR_COUNT and every
-- FLOORS INDEX are guesses in the same way: a floor index is the NATIVE per-lift
-- index, which no one can know without standing at the lift.
--
-- Nothing here is wrong in a way `Access.Problems` can see. It checks shape --
-- finite coordinates, whole indexes inside FLOOR_COUNT, a LABEL on every row --
-- and a placeholder passes all of it. The failure is silent and it is total:
-- `Access.Locate` matches a sighted lift to a key only within MATCH_RADIUS metres
-- of the position declared here, so a position that is off by more than six
-- metres matches nothing, no lift is ever adopted, and no panel ever opens.
--
-- To make these real, stand at each shaft and read the lift off the client
-- developer console:
--
--   resource.emit open77:elevators:nearby 100
--
-- which lists every streamed native LiftDevice -- unmanaged ones included -- with
-- its engine hash and its exact position. Put that position in X/Y/Z, put the
-- hash in ENTITY when two shafts share a lobby, and take FLOOR_COUNT from the
-- device rather than from the storey count of the building.

OPX.Config.MODULES.elevators = {
	enabled = true,

	-- shown greys a refused floor; hidden leaves it out of the panel.
	DENIED_FLOORS = 'shown',

	-- primary reads the worked job, any counts every membership for the grade
	-- but never for ON_DUTY: the memberships table carries grades, not a clock.
	MEMBERSHIP = 'primary',

	-- Past this snapshot age every gated floor closes; a public floor stays open,
	-- because a broken character read must not lock a lobby.
	JOB_MAX_AGE_MS = 60000,

	POLL_MS = 15000,
	-- 500, the pace of every other place (garages, dealers, stores, teleports,
	-- doors): at 2000 the lift's row came up to two seconds after the player
	-- stepped up to the doors, and its key did nothing until it had.
	SCAN_MS = 500,

	MATCH_RADIUS = 6.0,
	USE_RADIUS = 4.0,
	SCAN_RADIUS = 40.0,

	TRAVEL_MS = 8000,
	REQUEST_WINDOW_MS = 10000,
	REQUESTS_PER_WINDOW = 6,

	-- The key that opens the floor list at a lift the player stands at. ID is
	-- what a rebind is stored under and never changes. DEFAULT = false declares
	-- no key, which leaves the contract's `OpenPanel` as the only way in -- and an
	-- adopted cabin is locked, so a shaft with no way in cannot be ridden at all.
	KEY = { ID = 'opx.elevators.use', NAME = 'elevators.key.use', DEFAULT = 'E' },

	-- ACL-gated diagnostic; false registers none.
	COMMAND = 'opx.elevators.where',

	ELEVATORS = {
		arasaka_tower = {
			LABEL = 'ARASAKA TOWER',
			X = -1521.40, Y = 892.75, Z = 42.10,
			BUCKET = 0,
			FLOOR_COUNT = 12,
			FLOORS = {
				{ INDEX = 0, LABEL = 'Plaza' },
				{ INDEX = 2, LABEL = 'Reception' },
				{ INDEX = 5, LABEL = 'Analytics', JOBS = { arasaka = 0 },
					REASON = 'Arasaka staff only' },
				{ INDEX = 8, LABEL = 'Counterintel', JOBS = { arasaka = 2, militech = 3 },
					REASON = 'Arasaka Counterintel' },
				{ INDEX = 11, LABEL = 'Executive Suite', JOBS = { arasaka = 3 },
					ON_DUTY = true, REASON = 'Arasaka Executive, on duty' },
			},
		},

		ncpd_watson = {
			LABEL = 'NCPD WATSON',
			X = -652.10, Y = 1394.55, Z = 12.40,
			BUCKET = 0,
			FLOOR_COUNT = 5,
			FLOORS = {
				{ INDEX = 0, LABEL = 'Street' },
				{ INDEX = 1, LABEL = 'Front Desk' },
				{ INDEX = 2, LABEL = 'Bullpen', JOBS = { ncpd = 0, maxtac = 0 },
					REASON = 'NCPD only' },
				{ INDEX = 3, LABEL = 'Holding', JOBS = { ncpd = 1, maxtac = 0 },
					ON_DUTY = true, REASON = 'NCPD Officer, on duty' },
				{ INDEX = 4, LABEL = 'Evidence', JOBS = { ncpd = 2 },
					ON_DUTY = true, REASON = 'NCPD Detective, on duty' },
			},
		},

		vik_clinic = {
			LABEL = 'VIKTOR VEKTOR',
			X = -1244.80, Y = 402.35, Z = 8.90,
			FLOOR_COUNT = 3,
			FLOORS = {
				{ INDEX = 0, LABEL = 'Street' },
				{ INDEX = 1, LABEL = 'Clinic' },
				{ INDEX = 2, LABEL = 'Back Room', JOBS = { ripperdoc = 1, trauma = 2 },
					REASON = 'Ripperdoc back room' },
			},
		},

		afterlife = {
			LABEL = 'AFTERLIFE',
			X = -1876.20, Y = 233.05, Z = 6.10,
			FLOOR_COUNT = 3,
			FLOORS = {
				{ INDEX = 0, LABEL = 'Main Floor' },
				{ INDEX = 1, LABEL = 'Booths', JOBS = { fixer = 0, merc = 2 },
					REASON = 'Fixers and Edgerunners' },
				{ INDEX = 2, LABEL = 'Cellar', JOBS = { fixer = 2 },
					REASON = 'Fixer, made' },
			},
		},
	},
}
