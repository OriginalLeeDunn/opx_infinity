--- Teleports: the two ends of every shortcut, and who may take it.
-- @author dop42
--
-- WHY THIS MODULE EXISTS, in the owner's own words: there are places in Night
-- City a player simply cannot walk to. A rooftop with no reachable stair, a
-- mezzanine whose only lift is a set dressing, an interior the game enters
-- through a cutscene nobody can trigger here. This is a TRAVERSAL FIX first --
-- the locked ones are a role-play device on top of it, not the point of it.
--
-- A TELEPORT IS TWO ENDS AND A DIRECTION. `ENTRY` is where a player stands to
-- use it and `EXIT` is where they land. `RETURN = true` makes the exit an
-- entrance as well, so the shortcut works both ways; leave it out and the trip
-- is one-way. That is an operator's choice and never an assumption of this
-- module's -- a service hatch you drop through and walk out of is as legitimate
-- a design as a lift.
--
-- Both ends carry their own LABEL, because the row a player reads names WHERE
-- THEY ARE GOING and not where they are: standing at the ENTRY the strip offers
-- the EXIT's label, and standing at the EXIT of a two-way it offers the ENTRY's.
--
-- JOBS is job name -> minimum grade level, exactly as `config/elevators.lua`
-- writes it, and both read it through the one gate in `lib/shared/jobgate.lua`.
-- ON_DUTY additionally demands the job be the one being WORKED. REASON is the
-- operator's own words and is never translated: it is what a refused player is
-- told instead of a bare error code.
--
-- THE GATE APPLIES TO THE OUTBOUND LEG ONLY, AND THAT IS DELIBERATE. A player
-- whose duty ends -- or whose job is taken away by staff -- while they are
-- standing on the far side of a locked teleport would otherwise be stranded in
-- a place with, by this module's own premise, NO WALKABLE WAY OUT. Locking the
-- way back would turn the fix into the bug. There is no setting for it because
-- a setting for it is a setting for stranding people.
--
-- NOTHING HERE DECIDES ANYTHING. The client draws a marker and posts a row from
-- what the server sent it, and the server re-derives the destination, the job
-- gate and the distance from THIS FILE before it moves anybody. A client that
-- asks for a key that is not below, or for the back leg of a one-way, or from
-- across the map, is refused by `modules/teleports/server/main.lua` -- see the
-- note at the top of that file.
--
-- The marker vocabulary is fixed by the engine and not by this file: styles are
-- `interaction`, `objective`, `spawn` and `danger`, shapes are `ring` and
-- `cylinder`, RADIUS is 0.1..50 and MAX_DISTANCE is 1..500. Anything else is
-- answered `unsupported_style`/`unsupported_shape` by `Open77.markers`.

OPX.Config.MODULES.teleports = {
	enabled = true,

	-- Flat metres from a declared entrance within which it may be used. Small on
	-- purpose: a teleport is a spot you stand on, not a room you are in.
	USE_RADIUS = 2.0,

	-- Metres ABOVE OR BELOW an entrance that still count as standing on it, and
	-- the one radius the elevators module deliberately does not have. A lift is
	-- called from every floor of its own shaft, so it measures across the ground
	-- and ignores Z. A teleport pad is a disc: somebody on the walkway six metres
	-- overhead is not standing on it, and -- the case this number is really for --
	-- neither is somebody FALLING PAST IT. Without the band, a body dropping
	-- through the marker's column passes the flat test for as long as the fall
	-- lasts, and a teleport taken mid-fall arrives with the fall still on it.
	USE_HEIGHT = 2.5,

	-- What an entrance's marker looks like. `interaction` is the style that says
	-- "walk up to this and press something", which is exactly the gesture.
	MARKER = { shape = 'cylinder', style = 'interaction', RADIUS = 1.2 },

	-- The style a LOCKED entrance is drawn in instead, so a player can see from
	-- across the street that a shortcut is not theirs before walking to it. Only
	-- read when DENIED = 'shown'.
	LOCKED_STYLE = 'danger',

	-- shown draws a locked entrance in LOCKED_STYLE and lets the key say why;
	-- hidden draws no marker for it at all. Neither is a gate -- the server
	-- refuses the request either way -- so this is purely what an operator wants
	-- players to be able to see exists.
	DENIED = 'shown',

	-- Metres at which a marker stops being drawn at all, 1..500.
	MAX_DISTANCE = 120.0,

	-- Metres the marker is lifted off the declared Z, 0..2. Not decoration: a
	-- marker left at exact floor height is co-planar with the floor and draws
	-- nothing at all.
	GROUND_OFFSET = 0.06,

	-- The client's marker/row pass, and how often it re-asks the server for the
	-- list. The poll is what carries a duty toggle or a promotion to the strip
	-- without a rejoin, because the ALLOWED flag on each row is the server's
	-- answer and not the client's own reckoning.
	POLL_MS = 15000,
	SCAN_MS = 500,

	-- Past this snapshot age every gated entrance closes; an ungated one stays
	-- open, because a broken character read must not wall off a shortcut that
	-- was never locked. The server stamps its own read, so in practice this only
	-- ever bites when the character contract itself is unreachable.
	JOB_MAX_AGE_MS = 60000,

	-- primary reads the worked job; any counts every membership for the grade
	-- but never for ON_DUTY, because the memberships table carries grades and
	-- not a clock.
	MEMBERSHIP = 'primary',

	-- The screen fade the platform draws around the move, in milliseconds.
	FADE_MS = 400,

	-- How long the platform's arrival watch may run before it gives up,
	-- 1000..30000. The watch re-issues the teleport every 250 ms while the body
	-- is sinking through an unstreamed floor, so this is mostly a budget for
	-- STREAMING and not for the move: a destination that regularly spends ten
	-- seconds here is a destination whose coordinates want checking.
	SETTLE_MS = 12000,

	-- Requests one player may make per window. The move itself is bounded by the
	-- one-at-a-time lock in the server half; this bounds the asking.
	REQUEST_WINDOW_MS = 10000,
	-- 6, as every other place (garages, dealers, lifts) over the same window.
	REQUESTS_PER_WINDOW = 6,

	-- The key pressed while standing on an entrance. ID is stable, because a
	-- player's rebind is stored under it; NAME is the catalogue key of the
	-- pause-menu label. E, like the garages, the dealership and the clothing
	-- stores, because it is the same gesture in all of them -- and a separate
	-- MAPPING, so rebinding one does not move the others.
	KEY = { ID = 'opx.teleports.use', NAME = 'teleports.key.use', DEFAULT = 'E' },

	-- ACL-gated diagnostic; false registers none. It prints every teleport, its
	-- two ends, its gate and how its trips have gone, which is operator
	-- information.
	COMMAND = 'opx.teleports.where',

	-- ─────────────────────────────────────────────────────────────────────────
	-- EVERY COORDINATE BELOW IS AN EXAMPLE AND NONE OF THEM IS THIS SERVER'S
	-- WORLD. They are here to show the shape of a one-way, a two-way and a
	-- job-locked entry, and they are switched OFF -- `enabled = false` on each --
	-- so an operator who has not surveyed anything ships no teleports rather
	-- than three that drop players into a hillside.
	--
	-- This warning is written large because the sibling module got it wrong.
	-- `config/elevators.lua` carried four sample lifts whose "placeholder" note
	-- did not survive the port, and for weeks the file read as a description of
	-- this server's Night City when not one position had ever been surveyed.
	-- Nothing in `Access.Problems` could see it either: a made-up coordinate is
	-- shaped exactly like a real one.
	--
	-- TO MAKE ONE REAL you need three things the operator alone can supply:
	--
	--   1. The ENTRY position. Stand where the player should stand and read it
	--      off `/opx.admin.self.pos`, which copies it to the clipboard.
	--   2. The EXIT position AND HEADING. Stand where they should land, facing
	--      the way they should face, and read both off the same command -- the
	--      HEADING in the row it copies really is your own facing now. It was a
	--      hardcoded `0.0` until 2026-09-21, so an exit captured before then and
	--      never turned by hand lands everybody facing north. Land
	--      people on FLOOR they can already see -- the platform's arrival watch
	--      will re-issue the move while the body sinks through an unstreamed
	--      floor, but it cannot conjure a floor that is not there, and a
	--      destination with nothing under it ends in `settle_timeout` every
	--      time. The server logs that against the key.
	--   3. Real JOB NAMES. `arasaka`, `ncpd` and the rest below are the sample
	--      names `config/character.lua` ships; a JOBS entry naming a job that
	--      does not exist on this server is not an error anything can detect --
	--      it is simply a teleport nobody can ever take. The gate cannot check
	--      them, because job definitions load after this file does.
	-- ─────────────────────────────────────────────────────────────────────────
	POINTS = {
		-- A TWO-WAY, UNGATED: the plain case, and the one the owner asked for.
		-- A rooftop with no stair. Anyone may go up, and going back down is the
		-- same marker in reverse.
		example_rooftop = {
			enabled = false,
			LABEL = 'EXAMPLE: rooftop shortcut',
			BUCKET = 0,
			ENTRY = { LABEL = 'Street', X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 },
			EXIT = { LABEL = 'Rooftop', X = 0.0, Y = 0.0, Z = 30.0, HEADING = 180.0 },
			RETURN = true,
		},

		-- A ONE-WAY: a service hatch you drop through and walk out of. No
		-- RETURN, so the exit is a landing spot and never a marker.
		example_hatch = {
			enabled = false,
			LABEL = 'EXAMPLE: service hatch',
			BUCKET = 0,
			ENTRY = { LABEL = 'Hatch', X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 },
			EXIT = { LABEL = 'Maintenance level', X = 0.0, Y = 0.0, Z = -10.0, HEADING = 90.0 },
		},

		-- A LOCKED TWO-WAY, with the reason a refused player is shown. Note what
		-- the gate does NOT cover: the way back. Someone who goes off duty on the
		-- secure floor still gets out.
		--
		-- DISMOUNT lets a player be pulled out of a vehicle rather than refused.
		-- It defaults off and is left off here: the platform unmounts behind the
		-- fade and the car stays where it was, which on a lot with server-owned
		-- vehicles is somebody's Caliburn abandoned across a doorway. Turn it on
		-- for a pad where that is the intent.
		example_secure = {
			enabled = false,
			LABEL = 'EXAMPLE: secure floor',
			BUCKET = 0,
			ENTRY = { LABEL = 'Lobby', X = 0.0, Y = 0.0, Z = 0.0, HEADING = 0.0 },
			EXIT = { LABEL = 'Secure floor', X = 0.0, Y = 0.0, Z = 60.0, HEADING = 270.0 },
			RETURN = true,
			DISMOUNT = false,
			JOBS = { arasaka = 2 },
			ON_DUTY = true,
			REASON = 'Arasaka Counterintel, on duty',
		},
	},
}
