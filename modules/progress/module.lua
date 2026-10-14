--- A timed action the player has to see through: a bar, a lock, and one answer.
-- @author dop42
--
-- WHAT THIS IS FOR. Eating is the case it was written for and the shape is
-- general: something takes a few seconds, the player should not be able to walk
-- out of it halfway, and the screen has to say how long is left. Three things,
-- and only the second of them is hard.
--
-- A MODULE AND NOT A LIBRARY FUNCTION, which was the first design and the wrong
-- one. `opx_lib` runs inside the CONSUMER's VM and owns no surface: it could
-- hold the clock and take the input lock, but it could not draw, so the drawing
-- would have landed back here anyway under a seam nobody asked for. A bar is a
-- screen, screens are modules in this runtime, and `menu`, `panel` and `form`
-- are the three that already say so.
--
-- IT NEVER TAKES FOCUS, and that is a rule rather than an omission. `ui-kit`
-- puts it plainly: taking keyboard and cursor stops game input wholesale, and a
-- progress bar that must stop the player moving uses `Open77.input` instead.
-- So this draws on the OVERLAY surface, which cannot take the keyboard at all,
-- and holds the player with an input block that is released on every exit.
--
-- ONE AT A TIME, BY DESIGN. A second bar over the first is two clocks and two
-- locks racing to release the same actions; the second caller is refused with
-- `progress_busy` and decides for itself whether that is an error. The owner is
-- an argument, as it is for `prompts`: inside one runtime a caller is a module
-- calling a function, so the name is a label for expiry and for refusing a stop
-- that did not start it.
--
-- THE ANSWER IS THE POINT. `Start` answers a Result immediately -- the bar is
-- up, or it is not -- and the OUTCOME arrives later on `ON_DONE`, carrying
-- whether it finished or was cut short and why. A caller that needs to act on
-- completion listens; a caller that only wanted the gesture ignores it.

local M = OPX.Modules.Declare{
	id = 'progress',
	side = 'both',
	-- A runtime with no bar is a runtime where a timed action has no picture.
	-- Nothing about it is load-bearing enough to stop a resource.
	fatal = false,
	-- `downed` so a bar comes down with the player rather than floating over the
	-- death screen, and `animations` so a caller can name a gesture and have the
	-- two live and die together. Both optional: without either the bar still
	-- counts, still locks and still answers.
	optional = { 'downed', 'animations' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

M.Event = {
	-- Server to client, one player at a time. The server has no bar of its own,
	-- so a server-side caller sends one of these.
	START = OPX.Event(NET, 'progress', 'start'),
	CANCEL = OPX.Event(NET, 'progress', 'cancel'),
	-- Client to server: how a bar the server numbered ended, `(id, ending)`.
	-- Attacker-controlled like every client event; the server keeps its own clock.
	REPORT = OPX.Event(NET, 'progress', 'report'),

	-- Server only, public: how a bar the server started ended, as the server
	-- decided it. `(source, { id, owner, ending, completed, elapsedMs })`.
	ON_FINISHED = OPX.Event(LOCAL, 'progress', 'finished'),

	-- Client-local. What this module says when a bar ends, however it ended.
	ON_DONE = OPX.Event(LOCAL, 'progress', 'done'),
	-- Client-local. Up or down, for anything that stands aside for a bar.
	ON_STATE = OPX.Event(LOCAL, 'progress', 'state'),
}

--- Why a bar ended. A closed set, named here rather than spelled at each site.
--
-- `finished` is the only one that means the action happened. Every other value
-- is the action NOT happening, and a caller that treats them as a success is
-- the bug this vocabulary exists to make hard to write.
M.Ending = {
	-- The clock ran out with nobody stopping it.
	FINISHED = 'finished',
	-- The caller took it down itself.
	STOPPED = 'stopped',
	-- The player pressed the cancel key on a bar that allowed one.
	CANCELLED = 'cancelled',
	-- They went down, the character left, or the module stopped.
	INTERRUPTED = 'interrupted',
}

--- The actions a bar takes away while it is up.
--
-- NAMED HERE AND NOT IN CONFIG, because this is not a preference: a bar that
-- let the player walk away from the thing they are doing is not holding them to
-- it. `config/progress.lua` chooses whether a given bar locks at all; it does
-- not choose which levers a lock pulls.
--
-- THE VOCABULARY IS THE PLATFORM'S AND IT IS FIVE WORDS. `Movement`, `Map`,
-- `Hub`, `FastTravel`, `Attack` -- curated rather than an engine enum dump,
-- because Cyberpunk has no single input-blocking lever and a large minority of
-- actions cannot be refused at all. Anything else answers `unknown_action`.
-- (The first draft of this line read Forward, Back, Left, Right, Sprint, Jump,
-- Attack, Aim. Every one of those but `Attack` would have been refused, and the
-- bar would have held nobody.)
--
-- Two of the five. `Movement` is the whole of "stay put" and `Attack` stops a
-- player shooting through a sandwich. NOT `Map` or `Hub`: those are screens, and
-- `input-blocking` is explicit that a player who cannot act must still be able
-- to say so. NOT `FastTravel` either -- it needs a terminal, and a player
-- standing at one is not the case this exists for.
--
-- The camera is untouched by all of it, which is right: a player held still may
-- still look around, and taking that turns eating into a cutscene.
M.LOCKED = { 'Movement', 'Attack' }
