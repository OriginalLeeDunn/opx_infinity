--- Where the effect strip sits, and every need with its bounds.
-- @author dop42
--
-- `NEEDS` is the whole vocabulary: a key absent from here is refused by every
-- call and never stored, and a key added to it is served at its `DEFAULT` to
-- characters whose stored row predates it. `MIN` and `MAX` bound it on both
-- halves, and `DECAY_PER_MINUTE` is optional -- a need without one only moves
-- when something moves it.
--
-- THE SERVER OWNS EVERY VALUE (the owner's ruling, 2026-10). The decay below is
-- charged by the server, on its own clock, while the character is loaded; a need
-- goes up only when an item's `USE.STATUS` is consumed, through
-- `/opx.needs.set` (ACL `command.opx.needs.set`), or through the creator
-- exports `AddNeeds` / `SetNeeds` (EXPORTS.WRITERS). The client draws what the
-- server sends and cannot send a value back. Nothing happens to a body whose
-- need reaches MIN.

OPX.Config.MODULES.needs = {
	enabled = true,

	-- The corner a view places the strip in, and the pixels it sits above that
	-- corner, clear of the gauges. Both travel in the published strip.
	ANCHOR = 'bottom-left',
	OFFSET = 120,

	-- Chips published at once; the rest are counted in `hidden`.
	MAX_VISIBLE = 6,

	NEEDS = {
		hunger = { MIN = 0, MAX = 100, DEFAULT = 100, DECAY_PER_MINUTE = 0.20 },
		thirst = { MIN = 0, MAX = 100, DEFAULT = 100, DECAY_PER_MINUTE = 0.28 },
		stamina = { MIN = 0, MAX = 100, DEFAULT = 100 },
		streetCred = { MIN = 0, MAX = 100000, DEFAULT = 0 },
	},

	-- Milliseconds between two decay charges on the server. Each charge is a
	-- `values` event to the player, so this is also how often the gauges move.
	DECAY_MS = 60000,

	-- Milliseconds between two server writes of the values it holds.
	AUTOSAVE_MS = 300000,
}
