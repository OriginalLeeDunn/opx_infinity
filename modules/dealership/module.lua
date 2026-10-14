--- Dealerships: stand on a marker, pick a model, pay for it, choose the garage
--- it is delivered to.
-- @author XEROX710
--
-- Three things have to agree before a player owns anything, and they are all
-- decided on the server: the dealer exists and the player is standing on it,
-- the model is one THIS dealer sells, and the money is really there. The client
-- draws the list and sends one request; everything it believes is a hint.
--
-- THE VEHICLE IS NOT CREATED HERE. This module owns no car and no plate: it
-- charges the character, then registers the row through the `vehicles` contract
-- -- which counts the ceiling, draws the plate and writes the row -- and hands
-- the buyer the key of the garage they chose, so what comes out of that marker
-- afterwards is what they just bought. `vehicles` remains the only owner of
-- what a character owns, and of the rules about how much they may own.
--
-- `garages` is optional and only answers one question: which garages may be
-- named as a destination. Without it every purchase is filed under the vehicles
-- module's own default garage, which is a working dealership with one fewer
-- choice, not a broken one.
--
-- `character` is required on both halves: on the server it is the money and the
-- ownership oracle, and on the client it is where the price is read back and
-- where a purchase is announced.
--
-- `prompts` and `menu` are optional too. Without `menu` there is no list to
-- click and `/opx.dealership.buy <key>` still sells a car; without `prompts`
-- the markers still draw and only the strip row is missing.

local M = OPX.Modules.Declare{
	id = 'dealership',
	side = 'both',
	-- Not fatal: a server with no dealership is a server where nobody can buy a
	-- car, and that is a choice an operator may make with `enabled = false`.
	fatal = false,
	requires = { 'character' },
	-- `target` is optional on the same terms as the rest: without it the eye
	-- grows no "sell a vehicle" row and the showroom is a shop you buy from
	-- yourself, which is what it was before.
	-- `vehiclekeys` cuts the buyer a key; without it a car is sold with none.
	optional = { 'vehicles', 'garages', 'prompts', 'menu', 'target', 'vehiclekeys' },
}

-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` always comes from the authenticated connection.
	ASK = OPX.Event(NET, 'dealership', 'ask'),
	BUY = OPX.Event(NET, 'dealership', 'buy'),
	-- The runtime placement path: where the operator is standing and which way
	-- they are looking, for a preview point being placed or taken away. NOTHING
	-- IN THIS RESOURCE RAISES THESE TWO ANY MORE -- the staff menu's Dev screen
	-- was the only caller and the owner deleted it on 2026-09-21. A showroom car
	-- is written in PREVIEW.POINTS in config/dealership.lua; see client/exports.
	-- A salesperson offering a vehicle to the player they picked off the eye,
	-- and that player's own answer to it. TWO EVENTS AND NOT ONE, because they
	-- come from two different connections and only one of them is the buyer.
	OFFER = OPX.Event(NET, 'dealership', 'offer'),
	DECIDE = OPX.Event(NET, 'dealership', 'decide'),

	-- Server to client: the dealers this player may see, what is for sale and at
	-- what price, one verdict, and the offer a buyer has to answer.
	SYNC = OPX.Event(NET, 'dealership', 'sync'),
	STOCK = OPX.Event(NET, 'dealership', 'stock'),
	ANSWER = OPX.Event(NET, 'dealership', 'answer'),
	OFFERED = OPX.Event(NET, 'dealership', 'offered'),
	-- What became of an offer, sent to the SELLER: the buyer said no, the buyer
	-- said nothing, or the sale went through and this is the commission.
	SETTLED = OPX.Event(NET, 'dealership', 'settled'),
	-- What became of an offer, sent to the BUYER when it ended without their
	-- answer: it ran out, or the seller left. Carries the offer's token, so a
	-- withdrawal of an offer already replaced closes nothing.
	WITHDRAWN = OPX.Event(NET, 'dealership', 'withdrawn'),

	-- The client's own bus. `decision` carries every verdict, local refusals
	-- included. Public: a bare AddEventHandler reaches it.
	ON_DECISION = OPX.Event(LOCAL, 'dealership', 'decision'),

	-- The public SERVER bus, for other resources: a vehicle was sold, at the
	-- counter or face to face. Raised by the server only, `(buyer, { ... })`;
	-- see `core/server/publish.lua` and docs/MANUAL.md "For creators".
	ON_SOLD = OPX.Event(LOCAL, 'dealership', 'sold'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`: without it a client waiting on one of several requests
-- cannot tell which `error.tooFast` is its own.
M.Operation = {
	BUY = 'dealershipBuy',
	-- Offering a vehicle to another player, and that player's answer.
	OFFER = 'dealershipOffer',
	DECIDE = 'dealershipDecide',
}

--- The two kinds a dealer may declare.
-- THE SAME TWO THE GARAGES USE, and deliberately not a third vocabulary: a
-- dealer is a category of place, and the category decides which of the two
-- things it sells. A `garage` dealer sells ground vehicles, an `avpad` dealer
-- sells AVs, and a record that disagrees with the dealer's kind is refused.
M.KIND = { GARAGE = 'garage', AVPAD = 'avpad' }
