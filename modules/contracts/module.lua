--- Contracts: the fixer / merc gig board.
-- @author dop42
--
-- A fixer posts a gig with the client's eddies LOCKED IN ESCROW, a merc takes
-- it, the server watches the objective and alone records the proof, and the
-- settlement pays the merc, hands the fixer their cut and moves street cred. A
-- gig that fails or runs out of time gives the escrow back to whoever put it up.
--
-- A GENERIC LAYER and not a fixer feature. The fixer is the main publisher, but
-- the contract (`OPX.Api.Get('contracts')`) lets another module post a gig of
-- its own -- a police bounty, a netrunner job -- and register an objective type
-- the server can measure. Nothing here knows those modules exist.
--
-- THE SERVER OWNS EVERY STATE. A client asks; the server re-reads the
-- character, the position, the bag and the gig itself, decides, and answers with
-- a locale key. The states are:
--
--   locking -> posted -> accepted -> in_progress -> proof -> settling -> paid
--                                 \-> settling -> failed | expired | cancelled
--   proof -> disputed (a manual gig nobody validated in time), staff resolve it
--
-- `settling` is the one state in which money moves. A terminal outcome is first
-- written as `settling` with the outcome beside it, then every payment is made
-- through the idempotent ledger, then the row becomes the outcome. A restart
-- that finds `settling` simply settles again: a payment already made is found
-- in the ledger and not made twice.
--
-- `character` is required: a gig that cannot be paid is not a gig. The rest are
-- optional and the module degrades: no `inventory`, no package gigs; no
-- `target`, the board's rows still work; no `menu` / `form`, no screen and the
-- server half carries on for the API.

local M = OPX.Modules.Declare{
	id = 'contracts',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'inventory', 'target', 'menu', 'form' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- `{ }`: send me the board.
	BOARD = OPX.Event(NET, 'contracts', 'board'),
	-- `{ }`: send me the posting form's choices.
	FORM = OPX.Event(NET, 'contracts', 'form'),
	-- `{ type, target, title, brief, reward, cut, deadline, tier }`
	POST = OPX.Event(NET, 'contracts', 'post'),
	-- `{ id, verb }`: verb one of accept, abandon, cancel, deliver, report,
	-- validate, reject, waypoint.
	ACT = OPX.Event(NET, 'contracts', 'act'),
	-- `{ npc }`: delivering at a drop-off NPC (the eye's row).
	DELIVER = OPX.Event(NET, 'contracts', 'deliver'),
	-- `{ }`: hello, what am I working on and who stands where.
	HELLO = OPX.Event(NET, 'contracts', 'hello'),

	-- Server to client.
	-- The board as this player may see it: `{ rows, mine, posted, cred, ... }`.
	SHOW_BOARD = OPX.Event(NET, 'contracts', 'showBoard'),
	-- The form's choices: `{ types, targets, cut, deadlines, tiers, reward }`.
	SHOW_FORM = OPX.Event(NET, 'contracts', 'showForm'),
	-- The gig this merc is working, or nil: `{ id, type, title, waypoint? }`.
	ACTIVE = OPX.Event(NET, 'contracts', 'active'),
	-- The NPCs: a list of `{ npc, kind = 'fixer'|'dropoff', key, label }`.
	NPCS = OPX.Event(NET, 'contracts', 'npcs'),

	-- The public SERVER bus, `(source|nil, payload)`. Ids, type, citizen ids and
	-- reward only -- never an objective's position, which is the merc's secret.
	ON_POSTED = OPX.Event(LOCAL, 'contracts', 'posted'),
	ON_ACCEPTED = OPX.Event(LOCAL, 'contracts', 'accepted'),
	ON_PAID = OPX.Event(LOCAL, 'contracts', 'paid'),
	ON_FAILED = OPX.Event(LOCAL, 'contracts', 'failed'),
	ON_EXPIRED = OPX.Event(LOCAL, 'contracts', 'expired'),
	ON_CANCELLED = OPX.Event(LOCAL, 'contracts', 'cancelled'),
}

--- The states, spelt once. See the header for the graph.
M.State = {
	LOCKING = 'locking',
	POSTED = 'posted',
	ACCEPTED = 'accepted',
	IN_PROGRESS = 'in_progress',
	PROOF = 'proof',
	SETTLING = 'settling',
	PAID = 'paid',
	FAILED = 'failed',
	EXPIRED = 'expired',
	CANCELLED = 'cancelled',
	DISPUTED = 'disputed',
}

--- Who put a gig up, and where its money came from.
M.Poster = { PLAYER = 'player', NPC = 'npc', EXT = 'ext' }
M.Funded = { PLAYER = 'player', MINT = 'mint', EXTERNAL = 'external' }

--- The ledger phases. An operation id is `contracts:<id>:<phase>`, so a phase
--- happens at most once per gig.
M.Phase = {
	RESERVE = 'reserve', -- the escrow taken from the poster
	FEE = 'fee', -- the posting fee, destroyed
	COMMIT = 'commit', -- the merc's pay
	CUT = 'cut', -- the fixer's cut
	REFUND = 'refund', -- the escrow back to the funder
	PENALTY = 'penalty', -- the merc's fine, to the funder
	MINT = 'mint', -- new money for an NPC gig's pay
}
