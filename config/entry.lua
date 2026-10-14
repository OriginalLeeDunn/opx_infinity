--- What is asked of a character the server made empty.
-- @author dop42
--
-- Nothing here is authoritative. The only value a player still types is their
-- name, and the server checks it again and accepts it exactly once.
--
-- There is no roster and no stage in this module any more: an account is locked
-- on one character, a connection enters on it, and the lock is moved by a
-- command that disconnects. See `modules/entry/module.lua`.

OPX.Config.MODULES.entry = {
	enabled = true,

	-- Bounds on each half of a character name, in characters and not bytes. They
	-- MIRROR the character module's own bounds: this form repeats the server's
	-- rules, it does not replace them. A module may not read another module's
	-- settings, so the two are kept in step by hand; raising these past the
	-- server's only moves the refusal from the form to the server.
	NAME = { MIN = 2, MAX = 32 },

	-- How long a character that owes a name holds the join before its form has
	-- been put up, in seconds. The form waits for the look to settle, and the
	-- spawn menu is offered before that; without this hold the menu opened in
	-- the gap and the form then opened over it (the bot lab, 2026-10-07). The
	-- bound is for a look that never settles: past it the menu may open, and
	-- the form waits for the menu to close instead. Ten seconds is the floor.
	NAME_CLAIM_SECONDS = 90,
}
