--- Underworld: the illegal economy of Night City.
-- @author dop42
--
-- WHAT IS HERE (P1): dirty money as a bag item with a ledger; black-market
-- dealers (server NPCs that move between spots and keep their own stock);
-- drug labs (crafting benches behind a gang gate, with heat); drugs a player
-- can take (a screen effect, armour, an addiction counter and an overdose);
-- store robberies (a till with regrowing charges, a weapon, cops on duty, an
-- alarm); laundering at fronts (a batch that cooks into BANK, a daily cap);
-- and a player-to-player street deal through the platform's two-player
-- coordinator. Turf, vehicle theft, smuggling, heists and the rest are P2+.
--
-- ONE RULE FOR EVERY ACTION THAT MAKES VALUE: `server/op.lua`. Validate with
-- nothing yielding, claim (a table lock, no yield), RESERVE the inputs before
-- the bar (taken out of the bag into an escrow row, or refused), a bar the
-- server times, revalidate, then COMMIT once -- inputs destroyed first, value
-- created last, random amounts drawn from a hash of the op id and never from
-- `math.random` -- or CANCEL exactly once, which hands the escrow back. A server
-- that dies mid-bar finds the escrow rows at its next start and refunds them.
--
-- SERVER AUTHORITATIVE. A client says "this dealer", "this till", "that
-- amount"; the server re-reads the position, the bag, the gang, the clock and
-- the police roster every time, and answers with a locale key.
--
-- `character` and `inventory` are required: there is no illegal economy with no
-- purse and no bag. Everything else is optional and degrades: no `progress` is
-- no bar and therefore no robbery, deal or deposit (the bar is the clock and the
-- cancel key); no `crafting` is no lab; no `target` is no eye (and the server
-- half still works for a creator calling the contract); no `police` module
-- means alarms go straight to the officers on duty.

local M = OPX.Modules.Declare{
	id = 'underworld',
	side = 'both',
	fatal = false,
	requires = { 'character', 'inventory' },
	optional = { 'target', 'progress', 'crafting', 'menu', 'prompts', 'weather', 'downed',
		'animations' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- No payload: the dealers in the world and the client's own view, please.
	HELLO = OPX.Event(NET, 'underworld', 'hello'),
	-- `{ npc }` a dealer's NPC id as a decimal string: open their stall.
	DEALER = OPX.Event(NET, 'underworld', 'dealer'),
	-- `{ dealer, index, count, pay = 'dirty'|'clean' }`: buy one stock line.
	BUY = OPX.Event(NET, 'underworld', 'buy'),
	-- `{ dealer, index, count }`: sell to a dealer (a fence).
	SELL = OPX.Event(NET, 'underworld', 'sell'),
	-- `{ store }`: rob a till.
	ROB = OPX.Event(NET, 'underworld', 'rob'),
	-- `{ front }`: the front's counter (batches, what is left today).
	FRONT = OPX.Event(NET, 'underworld', 'front'),
	-- `{ front, amount }`: hand dirty eddies over to be washed.
	LAUNDER = OPX.Event(NET, 'underworld', 'launder'),
	-- `{ front }`: collect every ready batch at a front.
	COLLECT = OPX.Event(NET, 'underworld', 'collect'),
	-- `{ target }`: what may I offer this player.
	DEAL_MENU = OPX.Event(NET, 'underworld', 'dealMenu'),
	-- `{ target, item, count, price }`: offer it.
	DEAL_OFFER = OPX.Event(NET, 'underworld', 'dealOffer'),

	-- Server to client.
	-- `{ ok, code, params }`: the answer to every request, a locale key.
	ANSWER = OPX.Event(NET, 'underworld', 'answer'),
	-- `{ { npc, dealer, label } }`: the dealers standing in the world now.
	DEALERS = OPX.Event(NET, 'underworld', 'dealers'),
	-- A stall, a front's counter, a deal's choices: `{ kind, ... }`.
	VIEW = OPX.Event(NET, 'underworld', 'view'),
	-- To an officer: `{ kind, label, x, y, z, radius, seconds }` (x nil: no
	-- witness saw where).
	ALERT = OPX.Event(NET, 'underworld', 'alert'),

	-- The public SERVER bus, `(source|nil, payload)`.
	-- Dirty eddies made or destroyed: `{ citizenId, amount, source }`.
	ON_DIRTY = OPX.Event(LOCAL, 'underworld', 'dirty'),
	-- An alarm raised: `{ kind, label, x, y, z, witnessed }`.
	ON_ALERT = OPX.Event(LOCAL, 'underworld', 'alert'),
	-- A robbery, a deal, a deposit committed: `{ kind, citizenId, ... }`.
	ON_COMMITTED = OPX.Event(LOCAL, 'underworld', 'committed'),
}

--- The ACL entries, spelt once.
M.Command = {
	LEDGER = 'opx.underworld.ledger',
	CAPTURE = 'opx.underworld.capture',
	SITES = 'opx.underworld.sites',
	ADDICTION = 'opx.underworld.addiction',
}

--- The owner name for bars, rows, benches and runtime items.
M.OWNER = 'underworld'

--- The crafting bench key of a lab is this plus the lab's ID.
M.BENCH_PREFIX = 'underworld:'
