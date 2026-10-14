--- The player HUD: gauges, the read-out, the chip strip, the mic and the dial.
-- @author dop42
--
-- It owns no state and decides nothing about the player. Every number on screen
-- belongs to another module or to the engine, and this one samples, formats,
-- tones and pushes it to the overlay page.
--
-- What it does own are the two decisions the page is deliberately incapable of:
-- the tone a gauge takes at a value, and how a number is written. The page never
-- picks a colour and never formats an amount, so a HUD that disagreed with the
-- rest of the runtime about what "low" means could only ever be this file.
--
-- `character` is required because there is no read-out without a character.
-- `needs` and `downed` are optional and degrade to silence: no needs means the
-- hunger and thirst gauges simply do not exist, and no downed module means
-- nobody is ever down. `fuel` is read the same way and is NOT declared: it
-- needs `prompts`, which needs this, and the graph refuses a cycle by name. The
-- dial asks for its contract each draw, and without it draws no fuel line --
-- Cyberpunk has no tank of its own to read.

OPX.Modules.Declare{
	id = 'hud',
	side = 'client',
	fatal = false,
	requires = { 'character' },
	optional = { 'needs', 'downed' },
}
