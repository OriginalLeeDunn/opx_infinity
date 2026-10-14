--- Crafting: an order placed at a bench, collected later, by whoever owns the bench.
-- @author dop42
--
-- WHAT THIS MODULE IS, AND WHAT IT IS NOT. It is a shared service: a consumer
-- module registers a BENCH -- a place with a list of recipes and a gate of its
-- own -- and this module takes the materials, holds the order for as long as the
-- recipe says, and hands the output back when somebody comes to collect it. It
-- is NOT a trade. It knows nothing about gunsmiths, ripperdocs or cooks, it
-- never reads a job, and the one question it cannot answer -- "may this player
-- use this bench" -- is asked back to the consumer as a function.
--
-- THE ONE REQUIREMENT THAT SHAPES EVERYTHING: you start a craft and you walk
-- away. So an order is NOT a progress bar.
--
--   `modules/progress/` is the timed-action bar and it is the wrong tool here by
--   construction: it takes `Movement` and `Attack` off the player for the whole
--   duration, which is precisely what walking away is. It is right for the two
--   seconds of HANDING THE MATERIALS OVER and wrong for the twenty minutes
--   afterwards, and that is how it is used -- the bench plays a short bar while
--   the order is placed and owns nothing after it.
--
--   An order is a ROW WITH A DEADLINE. Nothing about it lives in a client, in a
--   Lua timer or in a table this module holds: the row is the order, the
--   database's own clock decides when it is ready, and this module is only what
--   reads and writes it. A player who walks off, shuts the screen, disconnects
--   or watches the server restart comes back to exactly the same row.
--
-- WHAT HAPPENS WHEN THE PLAYER LEAVES: THE ORDER KEEPS COOKING, and it is the
-- only answer that is not a theft. The materials were taken when the order was
-- placed -- see below -- so at the moment of the disconnect the server is
-- holding something of theirs. Cancelling would have to give it back, into a bag
-- that is no longer loaded, on a path that a crash can run twice; keeping it
-- costs nothing and is what the player expects of an order they placed. The row
-- is keyed on the CITIZEN ID and never on the connection slot, so it belongs to
-- the character rather than to the session, and a slot recycled to somebody else
-- reaches none of it.
--
-- MATERIALS ARE TAKEN WHEN THE ORDER IS PLACED, NEVER WHEN IT IS COLLECTED. The
-- alternative loses on both sides: a player could queue the whole bench off one
-- set of materials and then be refused at every collection, and the refusal
-- would arrive twenty minutes after the decision that caused it.
--
-- THERE IS NO CANCEL, DELIBERATELY. A cancel means a refund, a refund means
-- putting items back into a bag that may be full and money back into a ledger
-- this module does not own, and both have to be exactly-once against a row two
-- callers may reach at the same time. Nothing in the brief asks for one. An
-- order accepted is an order paid for, the way handing materials to a gunsmith
-- is, and the whole class of double-refund bugs never exists.
--
-- COLLECTION IS MANUAL, AT THE BENCH. A finished order is not pushed into the
-- bag when the clock runs out, because at that moment there may be no bag: the
-- character may be offline, or carrying too much. So the order waits on the
-- shelf, and the only thing that can fail is a collection -- which the player
-- can see, understand and retry.

local M = OPX.Modules.Declare{
	id = 'crafting',
	side = 'both',
	-- Not fatal. A runtime with no crafting is a runtime where nothing can be
	-- made, which is a missing feature and not a broken server -- and every
	-- consumer resolves this module through the contract, so they degrade with
	-- it rather than failing.
	fatal = false,
	-- `inventory` for the materials and the output, `character` for the citizen
	-- id an order is filed under and for the fee. Both REQUIRED: without either
	-- there is no order that could be honestly placed, so refusing to start is
	-- more truthful than a bench that takes nothing and yields nothing.
	requires = { 'inventory', 'character' },
	-- `menu` draws the screen, `progress` covers the moment of handing the
	-- materials over. Without the first the bench is unreachable rather than
	-- broken; without the second the order is simply placed at once.
	optional = { 'menu', 'progress' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

M.Event = {
	-- Client to server. "I am standing at this bench and I want the screen."
	-- The server re-measures the distance: a client can ask from anywhere.
	OPEN = OPX.Event(NET, 'crafting', 'open'),

	-- Client to server. "Place this order." The recipe is named by key; nothing
	-- about its cost, its yield or its duration crosses the wire in this
	-- direction, because all three are read on the server from its own tables.
	ORDER = OPX.Event(NET, 'crafting', 'order'),

	-- Client to server. "Give me what is finished." The order is named by the id
	-- the server minted, and the server proves ownership again before it claims.
	COLLECT = OPX.Event(NET, 'crafting', 'collect'),

	-- Server to client. The whole screen in one payload: the bench, the recipes
	-- this player may order with what they are carrying, and the orders on the
	-- shelf. Sent in answer to every one of the three above, so the screen never
	-- has to guess what a refusal did to it.
	VIEW = OPX.Event(NET, 'crafting', 'view'),

	-- Server to client. A refusal, named. Separate from VIEW because a refusal
	-- may arrive when there is no view to send -- the bench does not exist, the
	-- player is too far, the rate limit fired.
	REFUSED = OPX.Event(NET, 'crafting', 'refused'),

	-- Client-local. What the crafting screen is doing, for anything that wants
	-- to watch it rather than own it. Public: a bare AddEventHandler reaches it.
	ON_STATE = OPX.Event(LOCAL, 'crafting', 'state'),

	-- Server only, public: an order placed, and one handed over.
	-- `(source, { citizenId, bench, recipe, item, count, ... })`.
	ON_ORDERED = OPX.Event(LOCAL, 'crafting', 'ordered'),
	ON_COLLECTED = OPX.Event(LOCAL, 'crafting', 'collected'),
}

--- Why a request was refused, as a CLOSED set.
--
-- Named here rather than spelled at each site, and kept short and machine-like,
-- because every one of them is also a locale key under `crafting.` -- the same
-- arrangement `shops` uses. A code with no sentence behind it reaches the player
-- as `error.unavailable` with the real code logged, which is a safety net and
-- not a plan.
M.Refusal = {
	-- Nobody registered a bench under that key.
	NO_SUCH_BENCH = 'no_such_bench',
	-- The bench has no recipe of that name, or the consumer's gate refused it.
	NO_SUCH_RECIPE = 'no_such_recipe',
	-- The consumer's own gate said no and gave no reason of its own.
	NOT_FOR_YOU = 'not_for_you',
	-- The bench has a position and the player is not standing at it.
	TOO_FAR = 'too_far',
	-- The server cannot read where the player is, so it cannot prove the reach.
	NO_POSITION = 'no_position',
	-- No character is loaded, so there is no citizen id to file an order under.
	NO_CHARACTER = 'no_character',
	-- Materials missing, or not enough of them.
	SHORT = 'short',
	-- The fee could not be taken.
	CANNOT_PAY = 'cannot_pay',
	-- This character already has as many orders cooking here as the bench allows.
	QUEUE_FULL = 'queue_full',
	-- The order is not this character's, or it has already been collected.
	NO_SUCH_ORDER = 'no_such_order',
	-- The order exists and is still cooking.
	NOT_READY = 'not_ready',
	-- The output will not fit in the bag. Retryable, and the order is untouched.
	NO_ROOM = 'no_room',
	-- Too many requests in the window.
	TOO_FAST = 'too_fast',
	-- The player is down. The down screen is the client's; this is the server's.
	DOWNED = 'downed',
	-- The database would not answer. Nothing was taken and nothing was placed.
	UNAVAILABLE = 'unavailable',
}
