--- The authoritative half of the clothing shops.
-- @author dop42
--
-- WHAT IS DECIDED HERE AND NOWHERE ELSE: whether a player is standing at the
-- shop they name, what a change costs, whether they can pay for it, whether
-- their job lets them take a uniform, and what they are allowed to do with a
-- saved look. The client is believed about NOTHING, including which slots
-- changed.
--
-- THE BILL IS TAKEN WHERE THE CLOTHES ARE WRITTEN. The room this module opens
-- is a PRICED one (`appearance.OpenWardrobe` with a `charge`): when the client's
-- clothing save arrives, `appearance` diffs it against the stored record itself,
-- hands the moved slots to `chargeFor`, and writes the record only once the
-- money is taken -- a charge that fails is a save refused, and the client puts
-- the stored look back. It used to be the other way round: the client reported
-- the slots on `shops:bill` after its save had landed, so a client that never
-- sent the bill kept the clothes for free.

local M = OPX.Modules.Get('shops')


-- The `character` contract, resolved in Start. Money, jobs, and who a source is.
local character = nil

-- The `appearance` contract, for the fitting room and the stored look.
local appearance = nil

-- The shops, normalised once at Init: key -> { label, x, y, z, bucket, prices,
-- jobs, onDuty }.
local shops = {}

-- The ready-made looks, normalised once: key -> { label, cost, jobs, onDuty,
-- at, wear }.
local looks = {}

-- The settings that are read on every request, resolved once.
local tuning = {}

-- Least time between two presses of the saved-look doors by one player, and
-- between two share codes typed in. A fairness window and a brake on guessing,
-- not an authority: every request is still checked in full.
local OUTFIT_COOLDOWN_MS = 750
local REDEEM_COOLDOWN_MS = 2000

--- One boot line naming a config row that was dropped, and why.
-- Never fatal: a mistyped shop is one shop missing, not a server that will not
-- start, and an operator who cannot see WHICH one is an operator who cannot fix
-- it.
local function problem(text)
	Open77.log.warn('[shops] ' .. text)
end

--- A finite number within bounds, or nil.
local function bounded(value, low, high)
	local number = tonumber(value)
	if number == nil or number ~= number then return nil end
	if number < low or number > high then return nil end
	return number
end

--- Reads `JOBS = { name = minimumGrade }` into a clean table, or nil.
local function jobGate(raw, where)
	if raw == nil then return nil end
	if type(raw) ~= 'table' then
		problem(('%s: JOBS is not a table; the gate is ignored'):format(where))
		return nil
	end
	local gate, any = {}, false
	for name, grade in pairs(raw) do
		local level = bounded(grade, 0, 100)
		if type(name) ~= 'string' or name == '' or level == nil then
			problem(('%s: JOBS has an entry that is not name = grade; it is dropped')
				:format(where))
		else
			gate[name] = math.floor(level)
			any = true
		end
	end
	return any and gate or nil
end

--- Whether a player passes a job gate. No gate is no obstacle.
local function passes(source, gate, onDuty)
	if gate == nil then return true end
	if character == nil then return false end
	for name, grade in pairs(gate) do
		if character.HasJob(source, name, onDuty == true, grade) then return true end
	end
	return false
end

--- Reads the config once. Called from Init, which may not yield.
local function resolve()
	local settings = type(M.Settings) == 'table' and M.Settings or {}

	tuning.charge = settings.CHARGE ~= false
	tuning.currency = type(settings.CURRENCY) == 'string' and settings.CURRENCY or 'EDDIES'
	tuning.reach = bounded(settings.REACH, 0.5, 50.0) or 3.0

	local outfits = type(settings.OUTFITS) == 'table' and settings.OUTFITS or {}
	tuning.maxOutfits = math.floor(bounded(outfits.MAX_PER_CHARACTER, 1, 200) or 24)
	tuning.maxNameBytes = math.floor(bounded(outfits.MAX_NAME_BYTES, 4, 64) or 48)
	tuning.sharing = outfits.SHARING ~= false
	tuning.codeLength = math.floor(bounded(outfits.CODE_LENGTH, 4, 16) or 8)

	local defaults = M.Prices(settings.PRICES, nil)

	shops = {}
	local declared = type(settings.SHOPS) == 'table' and settings.SHOPS or {}
	for key, raw in pairs(declared) do
		local where = ('shop "%s"'):format(tostring(key))
		local x, y, z = bounded(raw.X, -1e6, 1e6), bounded(raw.Y, -1e6, 1e6),
			bounded(raw.Z, -1e6, 1e6)
		if type(key) ~= 'string' or key == '' then
			problem('a shop has no key; it is dropped')
		elseif type(raw) ~= 'table' then
			problem(('%s: the entry is not a table; it is dropped'):format(where))
		elseif x == nil or y == nil or z == nil then
			problem(('%s: X, Y or Z is not a finite number; it is dropped'):format(where))
		else
			shops[key] = {
				key = key,
				label = type(raw.LABEL) == 'string' and raw.LABEL or key,
				x = x, y = y, z = z,
				bucket = math.floor(bounded(raw.BUCKET, 0, 2147483647) or 0),
				prices = M.Prices(defaults, raw.PRICES),
				jobs = jobGate(raw.JOBS, where),
				onDuty = raw.ON_DUTY == true,
			}
		end
	end

	looks = {}
	local offered = type(settings.LOOKS) == 'table' and settings.LOOKS or {}
	for key, raw in pairs(offered) do
		local where = ('look "%s"'):format(tostring(key))
		if type(key) ~= 'string' or key == '' or type(raw) ~= 'table' then
			problem(('%s: the entry is not a keyed table; it is dropped'):format(where))
		elseif type(raw.WEAR) ~= 'table' then
			problem(('%s: WEAR is not a table, so it dresses nobody; it is dropped')
				:format(where))
		else
			-- The slots are filtered HERE rather than when the look is worn, so a
			-- typo is one boot line instead of a refusal every time somebody buys.
			local wear, any = {}, false
			for slot, record in pairs(raw.WEAR) do
				if not M.IsSlot(slot) then
					problem(('%s: "%s" is not a clothing slot; it is dropped')
						:format(where, tostring(slot)))
				elseif record == false or (type(record) == 'string'
					and record:match('^Items%.[%w_%.%-]+$') ~= nil) then
					wear[slot] = record
					any = true
				else
					problem(('%s: %s is not false and not an Items.* record; it is dropped')
						:format(where, tostring(slot)))
				end
			end

			if not any then
				problem(('%s: nothing in WEAR survived; it is dropped'):format(where))
			else
				looks[key] = {
					key = key,
					label = type(raw.LABEL) == 'string' and raw.LABEL or key,
					cost = math.floor(bounded(raw.COST, 0, 100000000) or 0),
					jobs = jobGate(raw.JOBS, where),
					onDuty = raw.ON_DUTY == true,
					at = type(raw.AT) == 'table' and raw.AT or nil,
					wear = wear,
				}
			end
		end
	end
end

--- Where a player is, and in which bucket, or nil.
local function positionOf(source)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.position) ~= 'function' then return nil end
	local read, position = pcall(players.position, source)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.floor(tonumber(position.bucket) or 0) }
end

--- The shop a player named, IF they are standing at it. Nil and a reason
--- otherwise.
--
-- THE DISTANCE IS MEASURED HERE, and this is the reason the whole request shape
-- is "name a shop" rather than "here is a price". A client asks; a client can
-- ask from anywhere and can ask about a shop on the other side of the city.
local function shopAt(source, key)
	local shop = type(key) == 'string' and shops[key] or nil
	if shop == nil then return nil, 'no_such_shop' end

	local position = positionOf(source)
	if position == nil then return nil, 'position_unknown' end
	if position.bucket ~= shop.bucket then return nil, 'too_far' end

	local dx, dy, dz = position.x - shop.x, position.y - shop.y, position.z - shop.z
	-- With the server's slack (`REACH_SLACK`): the eye row is offered out to
	-- REACH from where the client stood, a moment ahead of this position.
	if math.sqrt(dx * dx + dy * dy + dz * dz) > OPX.Spots.ServerReach(tuning.reach) then
		return nil, 'too_far'
	end

	if not passes(source, shop.jobs, shop.onDuty) then return nil, 'not_for_you' end
	-- Asked here so the room and a ready-made look both ask it: the down screen
	-- is the client's, and a client on the floor still sends the key.
	if OPX.Life.Down(source) then return nil, 'downed' end
	return shop
end

--- Tells one player something went wrong, in their own words.
--- Tells one player something went wrong, in their own words.
--
-- `OPX.NotifyLocale` is the house path: it renders the catalogue key, and a key
-- that is NOT in the catalogue becomes `error.unavailable` with the real code
-- logged, rather than a raw token being shown to a player.
local function refuse(source, key, data)
	OPX.NotifyLocale(source, key, data, 'error')
end

--- The sentence for a charge the wallet refused.
-- `RemoveMoney` always answers a reason, and for a short wallet it is the
-- character module's `money.insufficient` -- "You do not have enough money." --
-- so the shop's own sentence, the one that names the price, could never be
-- shown, in a room that shows no prices anywhere else.
local function unpaidKey(reason)
	if reason == nil or reason == 'money.insufficient' then return 'shops.cannotPay' end
	return reason
end

-- ── the fitting room ────────────────────────────────────────────────────────

--- The looks this shop carries that THIS player may take.
--
-- Gated before the list is sent, not after it is clicked: a uniform nobody may
-- wear is not a row somebody has to be refused at.
local function looksFor(source, shop)
	local out = {}
	for key, look in pairs(looks) do
		local here = look.at == nil
		if not here then
			for index = 1, #look.at do
				if look.at[index] == shop.key then here = true break end
			end
		end
		if here and passes(source, look.jobs, look.onDuty) then
			out[#out + 1] = { id = key, label = look.label, cost = look.cost }
		end
	end
	table.sort(out, function(left, right) return left.id < right.id end)
	return out
end

--- The stored clothing record of a player, or nil.
-- `GetClothing` answers a Result like every contract read; reading it as the
-- record itself made `onSave` refuse every look as `nothingWorn`.
local function storedClothing(source)
	if appearance == nil or type(appearance.GetClothing) ~= 'function' then return nil end
	local read = appearance.GetClothing(source)
	if type(read) ~= 'table' or not read.ok or type(read.value) ~= 'table' then return nil end
	return read.value
end

--- The charge a shop's fitting room puts on the save that leaves it.
--
-- Called by `appearance` with the slots IT computed, before the record is
-- written. Answers true -- with the undo that refunds it, should the write then
-- fail -- or false and `clothing.unpaid`, which refuses the save.
local function chargeFor(shop)
	return function(source, slots)
		if not tuning.charge then return true end
		local total = M.Bill(shop.prices, slots)
		if total <= 0 then return true end
		local reason = ('clothing at %s'):format(shop.label)
		local paid, refused = character.RemoveMoney(source, tuning.currency, total, reason)
		if not paid then
			refuse(source, unpaidKey(refused),
				{ total = OPX.Locale.Money(total, tuning.currency) })
			return false, 'clothing.unpaid'
		end
		OPX.NotifyLocale(source, 'shops.paid',
			{ total = OPX.Locale.Money(total, tuning.currency), shop = shop.label }, 'success')
		return true, nil, function()
			character.AddMoney(source, tuning.currency, total, 'refund: ' .. reason)
		end
	end
end

--- Dresses one player in a look, having told `appearance` the write is expected.
--
-- THE GRANT IS THE WHOLE REASON THIS IS A FUNCTION. `appearance` refuses a
-- clothing save that did not come through a door the server knows about --
-- otherwise the price of a change is whatever a rewritten client feels like
-- paying -- and the two doors below dress a player WITHOUT opening a fitting
-- room: a bought uniform, one of their own saved outfits. (A code somebody read
-- out was the third; it is worn inside a priced room now, see `onRedeem`.) The
-- clothes go on, the client's own debounced save follows a second or
-- two later, and without this it would be refused as roomless -- which for
-- `onWear` would mean money taken for clothes that do not survive the session.
--
-- The check is made before the clothes are sent and not after: a look put on a
-- player whose save will be refused is worse than one that never went on.
--
-- A LOOK GRANT, NOT A ROOM. What is granted is one save of exactly `wear` on top
-- of what is stored: an open grant here was ten minutes of the whole catalogue,
-- free, from anywhere a saved outfit could be loaded -- which is everywhere.
local function dressIn(source, look, wear, bill)
	if appearance == nil or type(appearance.AllowClothingSave) ~= 'function' then
		refuse(source, 'shops.unavailable')
		return false
	end
	if not appearance.AllowClothingSave(source, 'shops', { wear = wear, bill = bill }) then
		refuse(source, 'shops.unavailable')
		return false
	end
	TriggerClientEvent(M.Event.PUT_ON, source, { look = look, wear = wear })
	return true
end

--- The name a shop's fitting room is opened under, and later recognised by.
local function roomOwner(shop)
	return 'shops:' .. shop.key
end

--- "I am at this shop and I want the room."
local function onOpen(source, key)
	local shop, why = shopAt(source, key)
	if shop == nil then return refuse(source, 'shops.' .. why) end
	if appearance == nil or type(appearance.OpenWardrobe) ~= 'function' then
		return refuse(source, 'shops.unavailable')
	end

	-- AND THE PRICES, so the room can say what Save will cost before it costs
	-- it. The server still bills from its own table; this is the display.
	TriggerClientEvent(M.Event.LOOKS, source, { shop = shop.key, looks = looksFor(source, shop),
		prices = tuning.charge and shop.prices or {}, currency = tuning.currency })

	-- Opened under the shop's own name: a share code is redeemed only inside the
	-- room of the shop the player stands at (`onRedeem`).
	local ok, reason = appearance.OpenWardrobe(source,
		{ owner = roomOwner(shop), charge = chargeFor(shop) })
	if not ok then
		-- THE REASON GOES TO THE JOURNAL AND NOT ACROSS THE WIRE. `invalid_player`
		-- and whatever the `appearance` contract answers next are that module's
		-- internal vocabulary: they mean nothing to a player, they are not
		-- catalogue keys, and shipping them is this module handing a client the
		-- inside of another one. The operator is the one who can act on it, so
		-- the operator is who gets it.
		Open77.log.warn(('[shops] the fitting room at %s was refused for player %d: %s')
			:format(shop.key, source, tostring(reason)))
		refuse(source, 'shops.unavailable')
	end
end

--- "Put this ready-made look on me."
local function onWear(source, payload)
	if type(payload) ~= 'table' then return end
	local shop, why = shopAt(source, payload.shop)
	if shop == nil then return refuse(source, 'shops.' .. why) end

	local look = type(payload.look) == 'string' and looks[payload.look] or nil
	if look == nil then return refuse(source, 'shops.noSuchLook') end
	if not passes(source, look.jobs, look.onDuty) then
		return refuse(source, 'shops.notForYou')
	end
	if look.at ~= nil then
		local here = false
		for index = 1, #look.at do
			if look.at[index] == shop.key then here = true break end
		end
		if not here then return refuse(source, 'shops.notHere') end
	end

	if appearance == nil or type(appearance.AllowClothingSave) ~= 'function' then
		return refuse(source, 'shops.unavailable')
	end

	-- BILLED ON THE SAVE, NOT ON THE PICK. The uniform used to be charged here,
	-- the moment it was chosen, and a Cancel then kept the money and dropped
	-- the clothes. The price now rides on the look's grant, and `appearance`
	-- runs it only for the save that keeps the uniform: Cancel costs nothing,
	-- and a uniform this body cannot wear any of is never saved, so never paid.
	local bill = nil
	if tuning.charge and look.cost > 0 then
		bill = function(payer)
			local reason = ('%s at %s'):format(look.label, shop.label)
			local paid, refused = character.RemoveMoney(payer, tuning.currency, look.cost, reason)
			if not paid then
				refuse(payer, unpaidKey(refused), { total = OPX.Locale.Money(look.cost, tuning.currency) })
				return false, 'clothing.unpaid'
			end
			OPX.NotifyLocale(payer, 'shops.paid',
				{ total = OPX.Locale.Money(look.cost, tuning.currency), shop = shop.label }, 'success')
			return true, nil, function()
				character.AddMoney(payer, tuning.currency, look.cost, 'refund: ' .. reason)
			end
		end
	end

	dressIn(source, look.key, look.wear, bill)
end

-- ── saved looks ─────────────────────────────────────────────────────────────
-- A SAVED LOOK IS NOT A PURCHASE and costs nothing. It is the record the
-- character is already wearing, written down so they can come back to it -- you
-- have already paid for these clothes. What a shop sells is a CHANGE, and
-- loading a saved look at a shop is a change like any other: it goes through
-- the fitting room and is billed by the slots it moves.
--
-- WHICH IS WHY LOADING DOES NOT NEED A SHOP. A code somebody read out is a
-- costume you can put on anywhere; the money question is asked where the
-- clothes change, not where the list is kept.

--- The `equipment` half of a stored record, or nil.
-- Only the nine slots survive: a saved look is what is worn, and the seven
-- wardrobe outfits under it are a separate thing the player flips between.
local function equipmentOf(record)
	if type(record) ~= 'table' or type(record.equipment) ~= 'table' then return nil end
	local out, any = {}, false
	for index = 1, #M.SLOTS do
		local slot = M.SLOTS[index]
		local worn = record.equipment[slot]
		if worn == false or type(worn) == 'string' then
			out[slot] = worn
			any = true
		end
	end
	return any and out or nil
end

--- The citizen a source is playing, or nil.
local function citizenOf(source)
	if character == nil then return nil end
	local player = character.GetPlayer(source)
	local citizen = player and player.PlayerData and player.PlayerData.citizenId
	return type(citizen) == 'string' and citizen ~= '' and citizen or nil
end

--- Sends one player their whole saved list.
--- The saved look a request names, as the row id it can only be, or nil.
---
--- `tonumber` and `math.floor` were the whole check, and neither refuses
--- anything a JSON number can be: NaN floored is NaN, an infinity floored is an
--- infinity, and 1e300 is a float no row id is. Each went to the database as a
--- bound parameter -- three statements per guess, under the outfit window --
--- where the answer to "which row" should have been "none" before the query
--- was ever built. An id is a positive whole number the column can hold.
local MAX_OUTFIT_ID = 2147483647
local function outfitIdOf(payload)
	local id = type(payload) == 'table' and math.tointeger(payload.id) or nil
	if id == nil or id < 1 or id > MAX_OUTFIT_ID then return nil end
	return id
end

local function pushList(source, citizen)
	local listed = M.Storage.List(citizen)
	if not listed.ok then return refuse(source, 'shops.listFailed') end

	local rows = {}
	for index = 1, #listed.value do
		local row = listed.value[index]
		rows[index] = {
			id = tonumber(row.outfit_id),
			name = tostring(row.name),
			code = type(row.share_code) == 'string' and row.share_code or nil,
		}
	end
	TriggerClientEvent(M.Event.SAVED, source, { outfits = rows, max = tuning.maxOutfits })
end

--- "Write down what I am wearing, under this name."
local function onSave(source, payload)
	local citizen = citizenOf(source)
	if citizen == nil then return refuse(source, 'shops.noCharacter') end

	local name = type(payload) == 'table' and payload.name or nil
	name = type(name) == 'string' and OPX.Text.Bytes(name, tuning.maxNameBytes) or nil
	if name ~= nil then name = OPX.String.Trim(name) end
	if name == nil or name == '' then return refuse(source, 'shops.nameNeeded') end

	local counted = M.Storage.Count(citizen)
	if not counted.ok then return refuse(source, 'shops.listFailed') end
	if tonumber(counted.value or 0) >= tuning.maxOutfits then
		return refuse(source, 'shops.tooMany', { max = tuning.maxOutfits })
	end

	-- THE STORED RECORD AND NOT THE CLIENT'S. What a player is wearing is already
	-- authoritative on the server; taking the client's word for it would let
	-- anybody save a look they never wore.
	local worn = equipmentOf(storedClothing(source))
	if worn == nil then return refuse(source, 'shops.nothingWorn') end

	local saved = M.Storage.Save(citizen, name, json.encode({ equipment = worn }))
	if not saved.ok then return refuse(source, 'shops.saveFailed') end

	OPX.NotifyLocale(source, 'shops.saved', { name = name }, 'success')
	pushList(source, citizen)
end

--- "Put one of my saved looks on."
local function onLoad(source, payload)
	local citizen = citizenOf(source)
	if citizen == nil then return refuse(source, 'shops.noCharacter') end

	local outfitId = outfitIdOf(payload)
	if outfitId == nil then return refuse(source, 'shops.noSuchOutfit') end

	local found = M.Storage.Own(citizen, outfitId)
	if not found.ok or type(found.value) ~= 'table' then
		return refuse(source, 'shops.noSuchOutfit')
	end

	local wear = equipmentOf(OPX.Storage.Decode(found.value.look, nil))
	if wear == nil then return refuse(source, 'shops.outfitUnreadable') end
	dressIn(source, tostring(found.value.name), wear)
end

--- "Forget this saved look."
local function onDelete(source, payload)
	local citizen = citizenOf(source)
	if citizen == nil then return refuse(source, 'shops.noCharacter') end

	local outfitId = outfitIdOf(payload)
	if outfitId == nil then return refuse(source, 'shops.noSuchOutfit') end

	local removed = M.Storage.Delete(citizen, outfitId)
	if not removed.ok then return refuse(source, 'shops.deleteFailed') end
	pushList(source, citizen)
end

--- "Give me a code for this look so I can read it out."
--
-- MINTED UNTIL IT LANDS. The code is short by design -- it is read aloud -- so
-- collisions are possible and the unique index is what actually decides. A
-- refused insert is a retry, not an error, and after a handful of tries it
-- really is something else and says so.
local function onShare(source, payload)
	if not tuning.sharing then return refuse(source, 'shops.sharingOff') end
	local citizen = citizenOf(source)
	if citizen == nil then return refuse(source, 'shops.noCharacter') end

	local outfitId = outfitIdOf(payload)
	if outfitId == nil then return refuse(source, 'shops.noSuchOutfit') end

	local found = M.Storage.Own(citizen, outfitId)
	if not found.ok or type(found.value) ~= 'table' then
		return refuse(source, 'shops.noSuchOutfit')
	end
	-- Already shared: the same code comes back, because a look that changed its
	-- code every time somebody asked would make every code already read out into
	-- a wrong one.
	if type(found.value.share_code) == 'string' and found.value.share_code ~= '' then
		return TriggerClientEvent(M.Event.CODE, source,
			{ id = outfitId, code = found.value.share_code })
	end

	for _ = 1, 5 do
		local code = M.MintCode(tuning.codeLength, math.random)
		local set = M.Storage.SetCode(citizen, outfitId, code)
		if set.ok and tonumber(set.value or 0) > 0 then
			return TriggerClientEvent(M.Event.CODE, source, { id = outfitId, code = code })
		end
		if set.ok then return refuse(source, 'shops.noSuchOutfit') end
	end
	refuse(source, 'shops.codeFailed')
end

--- "Somebody read me this code."
local function onRedeem(source, payload)
	if not tuning.sharing then return refuse(source, 'shops.sharingOff') end

	local typed = type(payload) == 'table' and payload.code or nil
	local code = M.CleanCode(typed, tuning.codeLength)
	if code == nil then return refuse(source, 'shops.badCode') end

	-- ONLY INSIDE A SHOP'S FITTING ROOM, AT THAT SHOP'S PRICES (the owner's
	-- ruling, 2026-10). A code used to put the look on anywhere, through a free
	-- look grant: somebody else's purchase, worn for nothing, which made the
	-- share code a way round every counter in the city. Now the player has to
	-- stand at a shop, with that shop's priced room open, and the look goes on
	-- in the room like any other piece: the save that leaves it is billed by the
	-- room's own charge (`chargeFor`), slot by slot, at this shop's prices. A
	-- Cancel costs nothing and keeps nothing, as for every room.
	local shop, why = shopAt(source, type(payload) == 'table' and payload.shop or nil)
	if shop == nil then
		return refuse(source, why == 'no_such_shop' and 'shops.redeemAtShop' or ('shops.' .. why))
	end
	if appearance == nil or type(appearance.PricedRoom) ~= 'function'
		or appearance.PricedRoom(source) ~= roomOwner(shop) then
		return refuse(source, 'shops.redeemInRoom')
	end

	local found = M.Storage.ByCode(code)
	if not found.ok or type(found.value) ~= 'table' then
		return refuse(source, 'shops.noSuchCode')
	end

	local wear = equipmentOf(OPX.Storage.Decode(found.value.look, nil))
	if wear == nil then return refuse(source, 'shops.outfitUnreadable') end
	-- No grant of its own: the room's priced grant is what admits, and bills,
	-- the save.
	TriggerClientEvent(M.Event.PUT_ON, source, { look = tostring(found.value.name), wear = wear })
end

--- Reads the config and declares the table. Never yields.
-- @author dop42
function M.Init()
	resolve()
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Nothing is published yet: a shop is a place, not a service other modules call.
-- @author dop42
function M.Api()
end

--- Wires the doors.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	appearance = OPX.Api.Get('appearance')
	if character == nil or appearance == nil then
		Open77.log.error('[shops] no character or appearance contract: no shop can serve anybody')
		return
	end

	-- `source` is read through `tonumber` at the door of every handler, the way
	-- every other module here reads it: the platform delivers it as a string on
	-- some lifecycle paths, and a string id silently matches nothing.
	RegisterNetEvent(M.Event.OPEN, function(key)
		local src = tonumber(source)
		if src then onOpen(src, key) end
	end)
	RegisterNetEvent(M.Event.WEAR, function(payload)
		local src = tonumber(source)
		if src then onWear(src, payload) end
	end)

	-- EVERY ONE OF THESE READS THE DATABASE, and `OPX.Storage` yields, so each
	-- runs on its own thread. A net handler that yields holds the event pump.
	--
	-- AND EVERY ONE IS COOLED, because none of them was. Each press was a thread
	-- and one to three statements, so a client looping on any of these doors
	-- turned the shop into a database load generator -- and REDEEM, unthrottled,
	-- was an oracle a script could walk the code space with: every hit is
	-- somebody's saved look, put on for free. One window for the five doors that
	-- manage a player's own list, a longer one for guessing at somebody else's.
	local function door(event, key, everyMs, handler)
		RegisterNetEvent(event, function(payload)
			local src = tonumber(source)
			if not src then return end
			if OPX.Cooling(src, key, everyMs) then return refuse(src, 'error.tooFast') end
			CreateThread(function() handler(src, payload) end)
		end)
	end

	door(M.Event.SAVE, 'shops.outfits', OUTFIT_COOLDOWN_MS, onSave)
	door(M.Event.LIST, 'shops.list', OUTFIT_COOLDOWN_MS, function(src)
		local citizen = citizenOf(src)
		if citizen ~= nil then pushList(src, citizen) end
	end)
	door(M.Event.LOAD, 'shops.outfits', OUTFIT_COOLDOWN_MS, onLoad)
	door(M.Event.DELETE, 'shops.outfits', OUTFIT_COOLDOWN_MS, onDelete)
	door(M.Event.SHARE, 'shops.outfits', OUTFIT_COOLDOWN_MS, onShare)
	door(M.Event.REDEEM, 'shops.redeem', REDEEM_COOLDOWN_MS, onRedeem)

	-- A DELETED CHARACTER TAKES ITS SAVED LOOKS WITH IT. The foreign key above
	-- cascades, but a character delete here is soft, so the cascade never fires
	-- and this is what actually clears them -- the same note, for the same
	-- reason, as the appearance module's own purge.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			local purged = M.Storage.PurgeCharacter(citizenId)
			if purged ~= nil and not purged.ok then
				Open77.log.warn(('[shops] the saved looks of the deleted %s were not removed: %s')
					:format(citizenId, tostring(purged.detail or purged.error)))
			end
		end)

	local count = OPX.Table.Count(shops)
	Open77.log.info(('[shops] %d shop(s) and %d ready-made look(s); charging is %s')
		:format(count, OPX.Table.Count(looks),
			tuning.charge and 'on' or 'off'))
end

--- Nothing to flush: every write is made as it happens.
-- @author dop42
function M.Stop()
end
