--- Invoices: bills between players and companies.
-- @author dop42
--
-- AN EMPLOYEE BILLS, THE CUSTOMER CONSENTS, THE SERVER MOVES THE EDDIES. A
-- Delamain driver ALTs their fare (or types `/opx.bill`), the fare's screen asks
-- PAY / PUT IT ON MY TAB / REFUSE, and on a yes the bill leaves their bank, the
-- employee keeps their cut and the company treasury takes the rest. A bill the
-- customer accepted but could not cover stays on their tab (`/opx.bills`) and
-- survives a restart; they pay it later from there.
--
-- A SERVICE OTHER MODULES BILL THROUGH. The contract `invoices` v1
-- (`OPX.Api.Get('invoices')`) is how a mechanic, a bar or a lawyer module asks
-- for money with consent: `Issue{ issuer, target, amount, reason, account?,
-- cutPct?, source? }`, `Pending(player)`, `Cancel(id)`. Nothing here knows those
-- modules; they name the company account themselves.
--
-- THE STATES, all owned by the server:
--
--   asked -> settling -> paid
--        \-> unpaid -> settling -> paid
--        \-> refused | expired | cancelled        unpaid -> expired | cancelled
--   settling -> unpaid (the charge was refused: not enough eddies)
--   settling -> disputed (a crash left the charge unknowable: staff decide)
--
-- `settling` is the one state in which money moves, and it is written BEFORE
-- the first eddie does. Each movement is a ledger row keyed
-- `invoices:<id>:<phase>`: reserved, moved, committed. A restart that finds a
-- `settling` row settles again and finds the receipts of whatever already moved.
--
-- `character` is required (no purse, no bill). `accounts` is SOFT: without it
-- the whole bill goes to the employee. `target`, `menu`, `form` are client
-- conveniences; without them `/opx.bill` and `/opx.bills` still reach the
-- server, which carries on for the contract.

local M = OPX.Modules.Declare{
	id = 'invoices',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'target', 'menu', 'form' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- `{ target, amount, reason }`: bill the player at `target`.
	ISSUE = OPX.Event(NET, 'invoices', 'issue'),
	-- `{ verb, id?, choice? }`, verb one of:
	--   respond  the customer's answer to a prompt, choice one of pay, later, refuse
	--   pay      pay a bill on my tab
	--   cancel   withdraw a bill I raised
	--   list     send me my bills (no id)
	ACT = OPX.Event(NET, 'invoices', 'act'),

	-- Server to client.
	-- The prompt: `{ id, company, issuer, amount, reason, moneyType, ttlS }`.
	ASK = OPX.Event(NET, 'invoices', 'ask'),
	-- `{ id }`: the prompt for this bill is over (answered elsewhere, expired).
	ASK_CLOSED = OPX.Event(NET, 'invoices', 'askClosed'),
	-- `{ owed = { rows }, issued = { rows }, moneyType }`.
	SHOW_LIST = OPX.Event(NET, 'invoices', 'showList'),

	-- The public SERVER bus, `(source|nil, payload)`; payload `{ id, amount,
	-- account, source, issuerCid, targetCid }` (`source` the billing service).
	ON_ISSUED = OPX.Event(LOCAL, 'invoices', 'issued'),
	ON_PAID = OPX.Event(LOCAL, 'invoices', 'paid'),
	ON_REFUSED = OPX.Event(LOCAL, 'invoices', 'refused'),
	ON_EXPIRED = OPX.Event(LOCAL, 'invoices', 'expired'),
	ON_CANCELLED = OPX.Event(LOCAL, 'invoices', 'cancelled'),
}

--- The states, spelt once. See the header for the graph.
M.State = {
	ASKED = 'asked',
	UNPAID = 'unpaid',
	SETTLING = 'settling',
	PAID = 'paid',
	REFUSED = 'refused',
	EXPIRED = 'expired',
	CANCELLED = 'cancelled',
	DISPUTED = 'disputed',
}

--- The ledger phases: `invoices:<id>:<phase>`, so each happens at most once.
M.Phase = {
	CHARGE = 'charge', -- the bill, out of the customer's purse
	CUT = 'cut', -- the employee's share
	REST = 'rest', -- the company's share (or the employee's, without a company)
}
