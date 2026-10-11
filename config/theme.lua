--- The server's visual identity: a style, one accent colour and five knobs around it.
-- @author dop42
--
-- The values below ARE what ships. Change one, restart, and the surface follows.
-- `STYLE` picks the look and the block of the same name tunes it, so switching
-- look is one word and each look keeps its own colours. Inside a block, `ACCENT`
-- is the only knob that matters most of the time: everything coloured on the
-- screen is derived from it, so one hex moves the whole look at once.
--
-- Server-only. The client is told its theme over the wire and keeps no local
-- copy, so a player cannot pick their own.

OPX.Config.MODULES.theme = {
	enabled = true,

	-- The look, and the only two there are:
	--   'cyberpunk'  red, outlined, chamfered, tilted toward the screen edge,
	--                with a scanline over every enclosure. The house look.
	--   'minimal'    the same surfaces, quiet: thin rounded hairlines, flat
	--                planes, no scanline, no bloom, grey and white on black.
	-- Anything else is refused with a line in the journal and the page keeps
	-- the cyberpunk look its stylesheet ships with.
	STYLE = 'cyberpunk',

	-- ── the cyberpunk look ──────────────────────────────────────────────────
	cyberpunk = {
		-- The identity. `#RRGGBB` and nothing else -- `#fff`, `red` and
		-- `rgb(255,0,0)` are each refused with a line in the journal.
		--
		-- Pick something with room above it: the ladder climbs about 21 points of
		-- lightness from here up to the alarm, so an accent that is already very
		-- light has nowhere left to escalate to. The module says so at boot.
		ACCENT = '#ff3b47',

		-- The alarm rung. The one place a second hue is allowed: everything else is
		-- the accent at some brightness, and the alarm's whole job is to be unlike
		-- the rest. A blue server may well want an amber one.
		ALARM = '#ffa8ae',

		-- How dark the ground under running type is, 0.20 to 0.98. 0.78 is the floor
		-- for reading a sentence over live gameplay at night. The quiet and lit
		-- washes follow it, 0.20 below and 0.12 above.
		PLATE_OPACITY = 0.78,

		-- The scanline over enclosed surfaces. 1 is what ships, 0 turns it off, 2
		-- doubles it; held at 3 however high this goes, past which it stops being a
		-- texture and becomes a barcode over the game.
		INTERLACE = 1,

		-- How far an anchored surface leans away from its screen edge, in degrees,
		-- 0 to 15. 0 is flat, which the design already supports.
		TILT = 7,

		-- The chamfer, as a scale over the 6 / 12 / 20 pixel set. Under 1 is squarer
		-- and more industrial, over 1 is a heavier cut; the three move together.
		-- Never 0: augmented-ui needs a cut before it draws a border at all.
		CUT = 1,
	},

	-- ── the minimal look ────────────────────────────────────────────────────
	-- The same knobs. What is not a knob -- the type, the radius, the hairline
	-- weight -- is `ui/src/design-system/minimal.css`.
	minimal = {
		-- A neutral light grey, and nothing but grey and white on this surface: no
		-- saturation anywhere, so every rung derived from it is a grey too. It
		-- sits just inside the band where the lit state still has room above it.
		ACCENT = '#c6c6c6',

		-- Pure white. The voice is a grey here, so the alarm escalates in
		-- luminance alone -- the one step left above the lit rung -- and the
		-- surfaces give it a heavier stroke to carry the rest.
		ALARM = '#ffffff',

		-- A little lighter than the house ground. The type on it is a pale grey,
		-- which holds against the street at a lower opacity than red does.
		PLATE_OPACITY = 0.72,

		-- No scanline and no lean: both are the cyberpunk look's, not this one's.
		INTERLACE = 0,
		TILT = 0,

		-- Here this is the ROUNDNESS, not a chamfer: the corners are rounded at
		-- half the cut size, so 1 is 3 / 6 / 10 pixels and 2 is twice as soft.
		CUT = 1,
	},
}
