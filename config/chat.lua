--- Where the box sits, how much it keeps, and the two floors it applies.
-- @author dop42
--
-- Read by both halves: the caps are applied on the client for what a player can
-- type and on the server for what arrives, and the two must agree.

OPX.Config.MODULES.chat = {
	enabled = true,

	-- bottom-left, bottom-center, top-left or top-center; anything else reads as
	-- bottom-left.
	ANCHOR = 'top-center',

	-- Pixels above the anchored inset on a 1080-high surface, and the box width
	-- on a 1920-wide one.
	--
	-- WITH A TOP ANCHOR THE OFFSET IS MEASURED FROM THE TOP EDGE, not the bottom.
	-- That is the whole reason the box moved up here: the bottom-left corner is
	-- where `config/hud.lua` puts the vitals and the status chips, and every value
	-- tried down there -- 155, 300, 460 -- either sat on that stack or floated in
	-- the middle of the screen. The top edge is empty.
	--
	-- This is the one number to move if it lands wrong. Nothing in the code
	-- depends on it.
	--
	-- 88 AND NOT 48 SINCE THE OPX BADGE (2026-09-29, `extras/opx_logo_hud`): the
	-- badge fills the platform's reserved top strip, 76 px at 1080 (the design
	-- system's CHROME_STRIP, 7% of the height), and a box at 48 drew its input
	-- line across the lower half of the logo. 88 is the strip plus a 12 px gap.
	OFFSET = 88,
	WIDTH = 620,

	-- Lines kept on screen; older ones fall off the top.
	HISTORY = 60,

	-- Milliseconds a line stays visible while the box is closed; 0 never fades.
	FADE_MS = 12000,

	-- Longest message a player may send, in characters and not in bytes.
	MAX_LENGTH = 240,

	-- Milliseconds between two messages from one player.
	RATE_MS = 800,

	-- A line goes to every client, so only a connection with a LOADED character
	-- may send one (the owner's ruling, 2026-10) -- or one holding this ACL
	-- right, so staff can still be reached from the character screen. The
	-- console speaks through the `chat` contract and is never asked.
	STAFF_PERMISSION = 'command.opx.admin',

	-- Milliseconds between two suggestion lists for one player. Anyone can ask
	-- and the answer is kilobytes, so it keeps a floor of its own.
	READY_MS = 5000,

	-- Refused commands as toasts; false puts a red line in the box instead.
	NOTIFY = true,

	-- The default a player rebinds in the pause menu; false registers none.
	--
	-- This runtime binds its own key because the platform's `open77_chat` -- the
	-- only other thing that raises `open77:chat:open` -- is not in this server's
	-- `resources.load`. With neither, the box has no way to be opened and never
	-- appears in the shortcuts tab at all. Loading `open77_chat` alongside this is
	-- supported: both keys reach the same handler.
	KEYS = {
		OPEN = 'T',
	},
}
