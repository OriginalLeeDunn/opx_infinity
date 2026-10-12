--- How long a downed player waits, where they wake, and who may stand them up.
-- @author dop42

OPX.Config.MODULES.downed = {
	enabled = true,

	-- Seconds down before GIVE UP unlocks, and how long it is held so that a
	-- stray click respawns nobody. The server enforces both.
	GIVE_UP_AFTER_S = 120,
	GIVE_UP_HOLD_MS = 1500,

	-- How a player who gave up wakes, in the bucket they fell in: a fraction of
	-- full health, and the spawn protection that follows.
	RESPAWN = {
		HEALTH = 0.5,
		GRACE_MS = 5000,
	},

	-- The fade to black around a give up: out before the body moves, in once it
	-- stands at the medical center HOLD_MS later. Durations in milliseconds.
	FADE = { ENABLED = true, MS = 600, HOLD_MS = 1500 },

	-- Respawn points, the nearest to the fall winning. Replace the starter row
	-- with your own medical centers.
	HOSPITALS = {
		{ LABEL = 'Watson medical center', X = -667.14, Y = -382.61, Z = 9.16, HEADING = 0.0 },
	},

	-- What a revive through the contract leaves the player with.
	REVIVE = {
		HEALTH = 0.35,
		GRACE_MS = 3000,
	},

	-- Callers allowed to revive, and callers allowed to set the screen aside
	-- while their own surface is up. A caller now gives its own name, so both are
	-- switches rather than boundaries.
	REVIVERS = '*',
	-- Keys are MODULE ids, the name a caller passes to the downed contract's
	-- `Suspend`. `admin` is the only caller: the staff menu sets the screen aside
	-- so a downed staff member can still use it. (`opx77_admin`, the resource
	-- `admin` replaced, was listed here too; another resource cannot reach this
	-- runtime's contracts at all, so that entry could never match a caller.)
	SUSPENDERS = { admin = true },

	-- Stock HUD components hidden while down.
	--
	-- ALL THIRTEEN, WHICH IS NOT WHAT `config/hud.lua` DOES, and the difference
	-- is the point. That list is a steady state and leaves the crosshair, the
	-- scanner and the phone to the game, because a player who is up needs to aim
	-- and scan. This is a player bleeding out: they cannot aim, cannot scan, and
	-- are not taking a call. Every stock component is chrome over a screen that
	-- has one thing to say.
	--
	-- Seven of these were named and six were absent, which read as a decision and
	-- was a gap. `Open77.hud.components()` is the authority on the set; a name
	-- this build does not know is refused per component and costs nothing.
	VANILLA_HUD = {
		'minimap', 'compass', 'clock', 'health', 'stamina', 'weapon', 'speedometer',
		'questTracker', 'phone', 'scanner', 'vanillaNotifications', 'crosshair', 'hubMenu',
	},
}
