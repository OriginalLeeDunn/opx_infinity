--- Bar: bartenders, bars and food stalls.
-- @author dop42
--
-- WHAT IS HERE (P1): venues (a counter, a back-room stash, a supplier point)
-- worked by their staff; stock bought at the supplier into the venue stash;
-- drinks and dishes MIXED at the counter under a server-timed bar, out of that
-- stash into the bartender's bag; a customer SERVED through the platform's
-- two-player `give` (with their consent) and billed -- an `invoices` bill when
-- that module runs, a direct charge otherwise -- with the house's share paid to
-- the venue's treasury through `accounts` when that runs; and the items
-- themselves, registered at boot, whose use feeds `needs` and whose alcohol
-- blurs the drinker's own screen. NPC customers, happy hours, a tip jar and
-- per-venue employment are P2.
--
-- WHY NOT A CRAFTING BENCH. `crafting` takes its materials out of the
-- crafter's BAG and hands the output over later at the bench; a bar's stock
-- lives in the venue STASH and a drink is poured in seconds, in front of the
-- customer. So the counter is this module's own short bar, in the house order:
-- check before the bar (the stock is there, the bartender may), a bar the
-- server times, revalidate everything, then commit -- the ingredients out of
-- the stash first, the drink created last, and a partial failure unwound. No
-- escrow: nothing is taken before the bar ends, so a cancel, a crash or a
-- disconnect mid-bar has nothing to give back.
--
-- SERVER AUTHORITATIVE. A client says "this venue", "this recipe", "this
-- customer, this drink"; the server re-reads the gate, the distance, the stash,
-- the bag, the price and the purse every time, and answers with a locale key.
--
-- `character` and `inventory` are required: no purse, no bag, no bar.
-- `progress` (no bar, no mixing), `target` (no eye) and `menu` (no screen) are
-- optional; `invoices`, `accounts` and `needs` are contracts asked at run time.

local M = OPX.Modules.Declare{
	id = 'bar',
	side = 'both',
	fatal = false,
	requires = { 'character', 'inventory' },
	optional = { 'progress', 'target', 'menu' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the only truth; every field is re-read.
	-- `(venueId)`: the counter's screen (what can be mixed with the stock).
	COUNTER = OPX.Event(NET, 'bar', 'counter'),
	-- `(venueId, recipeKey)`: mix one.
	MIX = OPX.Event(NET, 'bar', 'mix'),
	-- `(venueId)`: open the venue stash.
	STASH = OPX.Event(NET, 'bar', 'stash'),
	-- `(venueId)`: the supplier's catalogue.
	SUPPLY = OPX.Event(NET, 'bar', 'supply'),
	-- `(venueId, index)`: buy one catalogue row into the stash.
	BUY = OPX.Event(NET, 'bar', 'buy'),
	-- `(targetId)`: what may I serve this customer.
	SERVE_MENU = OPX.Event(NET, 'bar', 'serveMenu'),
	-- `(targetId, item)`: serve it.
	SERVE = OPX.Event(NET, 'bar', 'serve'),

	-- Server to client.
	-- `{ ok, code, params }`: the answer to every request, a locale key.
	ANSWER = OPX.Event(NET, 'bar', 'answer'),
	-- `{ kind = 'counter'|'supply'|'serve', ... }`: a screen to draw.
	VIEW = OPX.Event(NET, 'bar', 'view'),

	-- The public SERVER bus, `(source, payload)`.
	-- `{ citizenId, venue, recipe, item, count, where = 'bag'|'stash' }`.
	ON_MIXED = OPX.Event(LOCAL, 'bar', 'mixed'),
	-- `{ citizenId, venue, item, count, price }`: stock bought.
	ON_BOUGHT = OPX.Event(LOCAL, 'bar', 'bought'),
	-- `{ venue, item, price, bartender, customer, billing = 'invoice'|'direct'|'free', invoice }`.
	ON_SERVED = OPX.Event(LOCAL, 'bar', 'served'),
}

--- The ACL entries.
M.Command = {
	VENUES = 'opx.bar.venues',
}

--- The owner name for bars, rows and runtime items.
M.OWNER = 'bar'
