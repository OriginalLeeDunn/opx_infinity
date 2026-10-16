--- The game's own loading screen: what this resource hides behind it, and the cover.
-- @author dop42
--
-- `modules/loading` reads the platform's native loading lifecycle
-- (`Open77.screen.loadingState`) and does two things with it. It takes the
-- HUD-like views off the page while a load is up -- the gauges, the key strip,
-- the toasts, the eye, the name tags -- because they were drawn over the game's
-- own loading screen as if the player were still standing in the street. And it
-- can draw the OPX cover over that screen for the loads that happen in play: a
-- teleport, a lift between floors, a respawn. Never the join: the connection
-- screen is the platform's, and `web/loading.html` already dresses it.
--
-- A CLIENT THAT IS TOO OLD TO ANSWER LOSES BOTH AND NOTHING ELSE. The reader
-- arrived after op77.78; on a build without it the module says so once in the
-- player's own log and every view keeps exactly the visibility it had.

OPX.Config.MODULES.loading = {
	enabled = true,

	-- Whether the HUD-like views step aside while the game is loading. They are
	-- hidden on the page, never switched off: each one keeps its own idea of
	-- whether it should be on screen, and gets it back the moment the load ends.
	-- A view the player had closed stays closed.
	HIDE_HUD = true,

	COVER = {
		-- The branded screen over the game's own during a load in play. False
		-- leaves the native screen alone; the views above still step aside.
		ENABLED = true,

		-- The film behind the cover, `web/loading.webm`, muted. False draws the
		-- poster still alone, which is the lighter of the two: the cover is a
		-- page composited over the game, and a film is a decoder running for as
		-- long as it is up. It is only mounted while the cover is.
		VIDEO = true,

		-- How long a load must have been running before the cover goes up, in
		-- milliseconds. A load shorter than this is a blink, and a cover that
		-- flashes up and away for it is noise. Bounded 0..5000.
		DELAY_MS = 250,

		-- THE NAME IN THE BAY, for a server that wants its own on the cover: the
		-- brand mark and the line under it. Plain text, at most 32 characters
		-- each; empty keeps the cover's own OPEN//77 and Infinity. The join
		-- screen has the same two lines in `web/loading.html`'s LOADSCREEN block,
		-- which this file cannot reach -- that page runs before any Lua does --
		-- so a server that names one names both.
		NAME = '',
		SUBTITLE = '',
	},

	-- How often the loading state is read, in milliseconds. One host call and a
	-- comparison of the revision it answers when nothing moved, which is what
	-- every pass but a handful per load is. Bounded 50..2000.
	POLL_MS = 200,
}
