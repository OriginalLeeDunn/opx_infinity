--- Where the key strip sits, how much of it is drawn, and what takes it down.
-- @author dop42
--
-- The ceilings are the page's own, repeated here because the strip is bounded by
-- the screen it sits on and not by what a caller asks for: `MAX_ROWS` is one
-- budget across every group, so eight groups of eight rows is a wall rather than
-- a hint. The page repeats them again rather than trusting its sender.

OPX.Config.MODULES.prompts = {
	enabled = true,

	-- bottom-right, bottom-left, top-right or top-left.
	ANCHOR = 'bottom-right',
	-- Pixels above the anchored edge's inset, 0..540 on the 1080-high surface.
	--
	-- 270 BECAUSE THE BOTTOM-RIGHT CORNER IS THE MINIMAP'S. The game's own map
	-- sits there now, round (opx_sandy_view 1.4.18, `opx_minimap.archive`): a
	-- 450-unit circle on the HUD's 3840x2160 grid, 72 units off the bottom, with
	-- the district name 54 units above it -- 576 units, which is 288 px of this
	-- 1080-high surface on a 16:9 screen and 259 on a 16:10 one. The strip's foot
	-- is the inset (28) plus this, so 270 opens it just above the district name
	-- on both. 0 put the prompts straight over the map.
	OFFSET = 270,
	-- Widest a row grows, 200..960 pixels at 1920 wide.
	MAX_WIDTH = 420,
	-- Rows drawn at once across every group, 1..24.
	MAX_ROWS = 10,

	-- Step aside while the chat box, a form or the pause menu has the keyboard,
	-- and while the player has turned the HUD off.
	HIDE_WHEN_CAPTURED = true,
	FOLLOW_HUD = true,

	-- Milliseconds between two passes, and between two checks of every owner
	-- against the runtime. A pass over an empty store answers at once.
	TICK_MS = 150,
	OWNER_SWEEP_MS = 1000,
}
