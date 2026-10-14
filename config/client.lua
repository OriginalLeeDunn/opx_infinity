--- Client-only configuration. Not authoritative: a modified client can change
--- every value here, and the server re-derives anything that matters.
-- @author dop42

OPX.Config.CLIENT = {
	-- ONE surface. It was two -- an overlay and an interactive layer -- and the two
	-- pages carried the Vue runtime, the design system and eight woff2 faces each:
	-- 926 kB where one page is 522. The HUD and the views are layers inside the page
	-- now, and the page takes focus only while a view is open.
	--
	-- `fps` is fixed at creation; the page handle has no setter. 60, because a
	-- pointer that lags feels broken, and a HUD that repaints more often than it
	-- changes costs only what CEF charges for an undamaged frame.
	--
	-- `hud` rather than `modal` for the layer: it is the only value the eleven
	-- shipped resources use, including `opx77_chat` and `opx77_target`, which both
	-- take focus on it. `modal` is real but unproven here.
	SURFACE = { layer = 'hud', zIndex = 700, fps = 60 },

	-- Where a toast that names no position of its own goes, and how wide the
	-- stacks are. The page holds the same two defaults and takes these on its
	-- own handshake, so an owner who deletes this block gets `top_right` at
	-- 340px rather than a broken surface.
	--
	-- One of seven the page draws: top_left, top_center, top_right, middle_left,
	-- bottom_left, bottom_center, bottom_right. An unknown name is refused by
	-- the page and the default stands.
	TOASTS = { position = 'top_right', width = 340 },

	-- WHO MAY CALL THE CLIENT CREATOR EXPORTS, `core/client/exports.lua`: open a
	-- menu, a form, a panel, a toast or a progress bar, put a row on the eye or a
	-- group on the key strip, play an animation, open a crafting bench, read the
	-- local player, on THIS player's own screen, or subscribe to the public
	-- client events (`Subscribe`). '*' is every client resource the server sends, or a set:
	-- { my_shop = true }. Open by default because everything behind it acts
	-- on the local player alone and the server re-derives anything that matters;
	-- a client config is advice in any case, not a lock.
	EXPORTS = {
		CALLERS = '*',
		-- The export a caller publishes to hear back -- a menu row chosen, a form
		-- answered, a bar ended -- when its call names no `reply` of its own.
		REPLY = 'OnOpxEvent',
	},

	-- ONE PRESS, ONE OWNER. Several features share a physical key out of the box
	-- -- E for garages, the dealership, the fitting rooms, teleports, lifts and
	-- doors; X for a progress bar's cancel, a call's decline and hang-up, putting
	-- a crate down and stopping an emote -- and the host fires EVERY mapping bound
	-- to a key from one press. So a press is contested: each of those features
	-- says whether it has something to do right now, and at which of these ranks,
	-- and only the highest acts; the rest stay silent. Two at the same rank go to
	-- the nearer one (a garage spot beside a door: whichever the player stands
	-- closer to). Only mappings bound to the SAME key contend, so a player who
	-- rebinds one of them apart gets both back. See `OPX.Spots.Key.Owns`.
	--
	-- Higher wins. Reorder freely; a missing name keeps its default below.
	KEY_PRIORITY = {
		PROGRESS = 100, -- a cancelable progress bar is up (X cancels it)
		-- the door the player is working on: a lockpick under way, or staff
		-- "Pick in world" on the door panel (E confirms). Beats a nearer spot.
		PICK = 95,
		OPEN = 90, -- the key closes a list it opened: garages, dealership (E)
		RINGING = 80, -- a call is ringing at the player (X declines)
		OUTGOING = 70, -- the player is ringing someone (X withdraws)
		CARRY = 60, -- a hauling crate is carried (X puts it down)
		EMOTE = 50, -- the player's own emote is playing (X stops it)
		SPOT = 20, -- at a garage, dealer, fitting room, lift, teleport or door (E)
		CALL = 10, -- on a call (X hangs up)
	},
}
