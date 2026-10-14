--- Configuration every client receives. Nothing secret belongs here: it ships to
--- each player in the signed resource set.
-- @author dop42

OPX.Config.SHARED = {
	LOCALE = 'en',

	SERVER_NAME = 'OPEN//77',
	-- Where a server toast is drawn by `open77_notifications`: middle_left,
	-- top_left, top_center, top_right, bottom_left, bottom_center or
	-- bottom_right. A hyphen is accepted for an underscore; anything else is
	-- named once in the log and the package's own default is used.
	NOTIFY_POSITION = 'top_right',

	MONEY = {
		DEFAULT = 'EDDIES',
		TYPES = { EDDIES = 'EDDIES', BANK = 'BANK' },
		ALLOW_NEGATIVE = {},
	},

	-- The health pool every character is placed with, in POINTS.
	--
	-- IT LIVES HERE AND NOT UNDER A MODULE for the same reason `AV_MATCHES`
	-- does: how big a body's health pool is is a fact about this server, not
	-- about whoever is looking at it. `character` places against it, `downed`
	-- reads fractions of it, `hud` draws it, and `admin` reports it -- four
	-- readers is exactly how a number ends up written four times and edited
	-- once. The server applies it with `Open77.players.setMaxHealth`, which is
	-- the platform's canonical maximum: the client is TOLD, never asked.
	--
	-- The engine's own default is 100. Raising it does not make anybody
	-- tougher against a given hit by itself -- damage is the engine's -- it
	-- makes the pool deeper.
	HEALTH = {
		MAX = 250,

		-- What a stored health value was written against before `MAX` existed.
		-- Health is persisted in POINTS, so every row already in the database
		-- holds a number on a 0..100 scale. Read naively against a MAX of 250
		-- a character who logged out unhurt would come back at 40%, which is a
		-- punishment for a setting they did not change. A row at or above this
		-- is therefore placed at full. Do not raise it: it is a statement about
		-- what the old data MEANS, not a tunable.
		LEGACY_FULL = 100,
	},

	-- WHAT MAKES A TweakDB VEHICLE RECORD AN AV. Each entry is compared
	-- lower-cased, because the database column and the wire disagree about
	-- case, and matches a record in EITHER of two ways: it names the record's
	-- START -- `vehicle.av_` is the whole family -- or it lands on a word's END,
	-- the name ending with the entry or `_`, `.` or a digit coming right after.
	-- That second way is why `vehicle.batty_av`, `vehicle.q001_trauma_av` and
	-- every `max_tac` hull count while the Quadra Type-66 AVENGER, whose record
	-- carries `_avenger`, does not: an entry names a WORD, not three letters in
	-- the middle of one. The rule `open77_avcleanup` sweeps the world by.
	--
	-- IT LIVES HERE AND NOT UNDER A MODULE because whether a record flies is a
	-- fact about the record, not about who is looking at it. It was three lists
	-- under `garages`, `dealership` and `admin.VEHICLES`, and the day one of them
	-- was edited the staff catalogue and the dealer disagreed about the same car.
	-- `OPX.Vehicle.IsAvRecord` is the only reader; an empty list falls back to
	-- this default rather than meaning "nothing flies".
	AV_MATCHES = { 'vehicle.av_', 'vehicle.max_tac', '_av', '_heli' },

	-- Metres the SERVER adds to a place's reach (garages, dealers, fitting
	-- rooms, teleports, lifts, shops, crafting and gunsmith benches, vehicle
	-- keys) when it measures a press again. The client shows
	-- the row and sends the press from where IT stands; the server measures
	-- where it last OBSERVED the player, a moment behind. With no slack a row
	-- drawn at the edge of a marker was a press refused as "too far" -- the
	-- prompt said yes and the server said no to the same step. `doorlock` has
	-- its own `SLACK` for the same reason and the same default. 0 to 4.
	REACH_SLACK = 1.0,
}

--- Per-module settings. A module reads its own table as `module.Settings`, and
--- the one key the runtime itself reads is `enabled`:
---   enabled  = false   the module declares and stops there
OPX.Config.MODULES = {
	-- example = { enabled = true },
}
