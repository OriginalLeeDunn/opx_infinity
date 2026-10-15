--- Clock, weather table and command names.
-- @author dop42
--
-- `WEATHER` is a roll order, not a setting: `NAME` is what staff type and what
-- the state stores, so rows are added freely and never renamed. `WEIGHT` is
-- relative to the other rows and 0 never rolls. Only DAY_LENGTH_MINUTES = 180
-- matches the engine's own day.

OPX.Config.MODULES.weather = {
	enabled = true,

	DAY_LENGTH_MINUTES = 180,
	START_TIME = { HOUR = 12, MINUTE = 0, SECOND = 0 },
	TIME_FROZEN = false,
	WEATHER_FROZEN = false,
	INITIAL_WEATHER = 'sunny',

	WEATHER = {
		{ NAME = 'sunny', PRESET = '24h_weather_sunny', WEIGHT = 28,
			MIN_SECONDS = 480, MAX_SECONDS = 900, TRANSITION_SECONDS = 18 },
		{ NAME = 'lightclouds', PRESET = '24h_weather_light_clouds', WEIGHT = 24,
			MIN_SECONDS = 360, MAX_SECONDS = 720, TRANSITION_SECONDS = 20 },
		{ NAME = 'cloudy', PRESET = '24h_weather_cloudy', WEIGHT = 18,
			MIN_SECONDS = 300, MAX_SECONDS = 600, TRANSITION_SECONDS = 24 },
		{ NAME = 'rain', PRESET = '24h_weather_rain', WEIGHT = 12,
			MIN_SECONDS = 180, MAX_SECONDS = 420, TRANSITION_SECONDS = 30 },
		{ NAME = 'heavyclouds', PRESET = '24h_weather_heavy_clouds', WEIGHT = 8,
			MIN_SECONDS = 240, MAX_SECONDS = 480, TRANSITION_SECONDS = 26 },
		{ NAME = 'fog', PRESET = '24h_weather_fog', WEIGHT = 5,
			MIN_SECONDS = 180, MAX_SECONDS = 360, TRANSITION_SECONDS = 28 },
		{ NAME = 'pollution', PRESET = '24h_weather_pollution', WEIGHT = 3,
			MIN_SECONDS = 180, MAX_SECONDS = 360, TRANSITION_SECONDS = 28 },
		{ NAME = 'sandstorm', PRESET = '24h_weather_sandstorm', WEIGHT = 2,
			MIN_SECONDS = 120, MAX_SECONDS = 300, TRANSITION_SECONDS = 35 },
	},

	-- THE AMBIENT WORLD, per routing bucket (`Open77.world.setPopulation`, see
	-- modules/weather/server/population.lua). CROWD is a real fraction of the
	-- vanilla pedestrian density, 0..1. TRAFFIC is a switch on 2.31 -- the engine
	-- has no vehicle density modifier, so it is vanilla traffic or none. POLICE is
	-- the game's own NCPD NPC spawns: off, because on this server the police are
	-- players and a vanilla unit exists on one client only. A bucket with no row
	-- keeps the host's own population (the vanilla world). Live changes:
	-- `/opx.population <bucket> <crowd> <traffic on|off> <police on|off>`.
	POPULATION = {
		ENABLED = true,
		BUCKETS = {
			[0] = { CROWD = 0.8, TRAFFIC = true, POLICE = false },
		},
	},

	COMMANDS = {
		STATUS = { NAME = 'opx.weather', RESTRICTED = false },
		PRESETS = { NAME = 'opx.weather.presets', RESTRICTED = false },
		SET = { NAME = 'opx.weather.set', RESTRICTED = true },
		NEXT = { NAME = 'opx.weather.next', RESTRICTED = true },
		FREEZE = { NAME = 'opx.weather.freeze', RESTRICTED = true },
		TIME = { NAME = 'opx.time', RESTRICTED = true },
		TIME_FREEZE = { NAME = 'opx.time.freeze', RESTRICTED = true },
		DAY_LENGTH = { NAME = 'opx.time.length', RESTRICTED = true },
		-- A PLAYER'S OWN TIME SKIP, for a mission's "wait until" or "come back
		-- tomorrow" step. The base game's time skip is refused in a session, and
		-- at the engine's rate a day is three real hours. `/opx.wait <hours>`
		-- moves the clock on the asking player's game only, 1 to 23 hours ahead;
		-- the shared hour stands back on that game for 20 minutes (the same hold
		-- a mission's own move of the clock gets) and then comes back. Nobody
		-- else's sky moves. Open to every player; '' switches it off.
		WAIT = { NAME = 'opx.wait', RESTRICTED = false },
		POPULATION = { NAME = 'opx.population', RESTRICTED = true },
	},
}
