--- Clothing shops, the looks they carry, and the outfits a player keeps.
-- @author dop42
--
-- WHAT THIS MODULE IS. A place in the world that opens the fitting room and
-- sends a bill afterwards. It owns no garments and stocks nothing.
--
-- THE ONE FACT THAT SHAPES ALL OF IT: the clothing catalogue is CLIENT-ONLY.
-- `Open77.equipment.records` runs on the game thread and the dedicated server
-- has no equivalent -- `modules/appearance/server/main.lua` says so and refuses
-- to grow into membership validation. So the server cannot answer "is this
-- jacket real, and what is it worth". It can answer "you changed what is on
-- your legs", because the nine slot names are a closed set both sides share.
-- Hence a price per SLOT, and hence a bill that is COUNTED rather than looked
-- up. See `config/shops.lua`.
--
-- WHAT THE CLIENT IS TRUSTED WITH, AND WHAT IT IS NOT. It is trusted to say
-- which slots differ, because it is the only half that can see them. It is not
-- trusted with the price, the shop's reach, the player's money, or whether a
-- job may take a uniform -- all four are read on the server from its own
-- tables. A client that named a total would be a client setting prices.
--
-- THE CHARGE IS NOT ATOMIC WITH THE SAVE, and pretending otherwise would be
-- worse than saying so. Money lives on the character row and clothing lives in
-- its own table, written by `appearance` through a debounce this module does
-- not own; there is no transaction spanning the two. So the order is: the room
-- closes, the bill is taken, and a bill that CANNOT be taken is answered by
-- putting the old look back. Compensation, not atomicity. The window is the two
-- seconds of the clothing debounce and the honest name for it is a window.

local M = OPX.Modules.Declare{
	id = 'shops',
	side = 'both',
	-- Not fatal: a runtime with no shops is a runtime where nobody can buy
	-- clothes, which is a missing feature and not a broken server.
	fatal = false,
	-- `character` for the money and the job; `appearance` for the fitting room
	-- and the look that is worn.
	requires = { 'character', 'appearance' },
	-- The eye that puts a row on the shop floor, the menu the looks and the saved
	-- outfits are listed in, and the form an outfit name and a share code are
	-- typed into. Without them the shop is unreachable, or reachable with fewer
	-- screens, rather than broken -- which is the whole difference between
	-- optional and required.
	optional = { 'target', 'menu', 'form' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

M.Event = {
	-- Client to server. "I am at this shop and I want the room." The server
	-- re-measures the distance before it answers, because a client can ask from
	-- anywhere.
	OPEN = OPX.Event(NET, 'shops', 'open'),

	-- `BILL` and `RESTORE` were here: the client reported the slots it changed
	-- and the server charged them after the fact. The fitting room this module
	-- opens is priced now, and `appearance` charges its save before writing it
	-- (see `chargeFor` in server/main.lua); a refused charge puts the stored look
	-- back through the clothing half's own restart.

	-- Server to client. The ready-made looks this shop carries FOR THIS PLAYER
	-- -- the job gate is applied before the list is sent, so a uniform nobody
	-- may take is not a row somebody has to be refused at.
	LOOKS = OPX.Event(NET, 'shops', 'looks'),

	-- Client to server. "Put this ready-made look on me."
	WEAR = OPX.Event(NET, 'shops', 'wear'),

	-- Server to client. A look to put on, already paid for and already checked.
	PUT_ON = OPX.Event(NET, 'shops', 'putOn'),

	-- Saved outfits, both directions.
	SAVE = OPX.Event(NET, 'shops', 'save'),
	LIST = OPX.Event(NET, 'shops', 'list'),
	SAVED = OPX.Event(NET, 'shops', 'saved'),
	LOAD = OPX.Event(NET, 'shops', 'load'),
	DELETE = OPX.Event(NET, 'shops', 'delete'),

	-- Share codes. `SHARE` mints one for a saved outfit, `REDEEM` takes one
	-- somebody read out, and `CODE` carries the minted one back.
	SHARE = OPX.Event(NET, 'shops', 'share'),
	REDEEM = OPX.Event(NET, 'shops', 'redeem'),
	CODE = OPX.Event(NET, 'shops', 'code'),

	-- Client-local. What the shop half has to say to whatever draws it.
	ON_STATE = OPX.Event(LOCAL, 'shops', 'state'),
}

--- The nine slot names a bill may mention.
--
-- MIRRORED FROM `appearance`, DELIBERATELY, and the duplication is the lesser
-- evil. `config/entry.lua` states the rule this follows: a module may not read
-- another module's settings, and reaching into `appearance`'s client-only
-- `Clothing.SLOTS` from a shared file would also break the server half, which
-- has no such table. A test holds the two lists against each other so the
-- copy cannot drift.
M.SLOTS = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit',
	'UnderwearTop', 'UnderwearBottom' }

local IS_SLOT = {}
for index = 1, #M.SLOTS do IS_SLOT[M.SLOTS[index]] = true end

--- Whether a name is one of the nine.
-- @author dop42
-- @param name any
-- @return boolean
function M.IsSlot(name)
	return type(name) == 'string' and IS_SLOT[name] == true
end

--- The slots on which two looks differ.
--
-- WORKS ON THE `equipment` HALF ONLY, which is the half a bill is about: the
-- wardrobe outfits under it are seven saved sets the player flips between and
-- flipping between them buys nothing. A slot is different when the record name
-- is different, and `false` -- an empty slot -- is a value like any other, so
-- taking a hat off is a change and is billed as one.
-- @author dop42
-- @param before table|nil the `equipment` table walked in with
-- @param after table|nil the `equipment` table walked out with
-- @return table an array of slot names, in the canonical order
function M.Changed(before, after)
	before = type(before) == 'table' and before or {}
	after = type(after) == 'table' and after or {}

	local moved = {}
	for index = 1, #M.SLOTS do
		local slot = M.SLOTS[index]
		-- Normalised to a comparable pair first: nil and false both mean "no
		-- garment", and a record that arrived as nil on one side and false on the
		-- other is not a purchase.
		local was = before[slot]
		local now = after[slot]
		if was == nil then was = false end
		if now == nil then now = false end
		if was ~= now then moved[#moved + 1] = slot end
	end
	return moved
end

--- What a list of changed slots costs at one shop.
--
-- The shop's own `PRICES` are merged OVER the defaults, so a shop states only
-- what it charges differently and an absent slot is free. Unknown slot names
-- are worth nothing rather than raising: the caller has already validated them
-- and a second raise here would only turn a refused sale into a broken one.
-- @author dop42
-- @param prices table the resolved price table for this shop
-- @param slots table an array of slot names
-- @return integer
function M.Bill(prices, slots)
	if type(prices) ~= 'table' or type(slots) ~= 'table' then return 0 end
	local total = 0
	for index = 1, #slots do
		local price = tonumber(prices[slots[index]])
		if price ~= nil and price > 0 then total = total + math.floor(price) end
	end
	return total
end

--- One shop's price table: the defaults with its own override on top.
-- @author dop42
-- @param defaults table|nil
-- @param override table|nil
-- @return table
function M.Prices(defaults, override)
	local resolved = {}
	if type(defaults) == 'table' then
		for slot, price in pairs(defaults) do
			if M.IsSlot(slot) then resolved[slot] = tonumber(price) end
		end
	end
	if type(override) == 'table' then
		for slot, price in pairs(override) do
			if M.IsSlot(slot) then resolved[slot] = tonumber(price) end
		end
	end
	return resolved
end

-- ── share codes ─────────────────────────────────────────────────────────────
-- A CODE IS NOT A SECRET and is not built like one. It names a look, and a look
-- is public the moment somebody wears it down the street; the code exists so
-- one player can read it out to another, which is the whole of the design
-- brief. What it must survive is a person saying it aloud badly.
--
-- So the alphabet has no `I`, no `O`, no `0` and no `1`: the two pairs every
-- handwritten and spoken code loses. Reading is case-insensitive and ignores
-- dashes and spaces, because somebody WILL type it back with the dashes in the
-- wrong places.

local ALPHABET = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ'

--- Turns whatever somebody typed into the code it was meant to be, or nil.
-- @author dop42
-- @param text any
-- @param length integer
-- @return string|nil
function M.CleanCode(text, length)
	if type(text) ~= 'string' then return nil end
	length = tonumber(length) or 8

	-- Case and punctuation are forgiven, because somebody WILL type the dashes
	-- back in the wrong places or leave them out entirely.
	local kept = text:upper():gsub('[^%w]', '')

	-- AND NOTHING IS GUESSED. It is tempting to read a typed `0` as `O` and an
	-- `I` as `1`, the way Crockford's base32 does -- but that mapping exists for
	-- alphabets which CONTAIN one of each pair, and this one contains neither.
	-- There is no correct target to map onto, so a guess here would silently
	-- hand somebody a different look than the one they were read out. A code
	-- cannot contain those characters, so a code that does is a mistake, and
	-- saying so is the only honest answer.
	if #kept ~= length then return nil end
	for index = 1, #kept do
		if not ALPHABET:find(kept:sub(index, index), 1, true) then return nil end
	end
	return kept
end

--- Mints a code from a source of random integers.
--
-- The generator is passed in rather than reached for, so the server states its
-- own and a test states a predictable one. It is called with (1, #ALPHABET).
-- @author dop42
-- @param length integer
-- @param pick function
-- @return string
function M.MintCode(length, pick)
	length = tonumber(length) or 8
	local out = {}
	for index = 1, length do
		local at = pick(1, #ALPHABET)
		out[index] = ALPHABET:sub(at, at)
	end
	return table.concat(out)
end

--- The alphabet, for anything that needs to say what a code may contain.
M.CODE_ALPHABET = ALPHABET
