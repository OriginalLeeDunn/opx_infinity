--- The shop floor: a row on the eye, and the bill that follows a fitting.
-- @author dop42
--
-- THIS HALF ASKS. It does not decide, and it does not bill. It puts a row where
-- a shop stands and asks the server to open the room; the room's clothing save
-- is what the server charges, diffing it against the stored record itself
-- before it is written. Every question -- the distance, the slots that moved,
-- the price, the money, the job -- is answered on the server, from its own
-- tables. See `server/main.lua`.

local M = OPX.Modules.Get('shops')

-- The eye, resolved in Start. Absent on a runtime without it, which makes the
-- shops unreachable rather than broken.
local target = nil

-- The `appearance` contract, for borrowing the puppet. A CONTRACT and not the
-- module namespace: this half needs `BeginClothingPreview` and nothing else,
-- and reaching past the contract for the rest would tie a shop to how the
-- fitting room happens to be written today.
local wardrobe = nil

-- The name `appearance` publishes its decisions on, rebuilt rather than reached
-- for. Every module here rebuilds another's event names the same way -- see the
-- character-delete handler in `server/main.lua` -- because a bare string is a
-- typo waiting to happen and an import is a dependency that does not exist.
local ON_DECISION = OPX.Event(OPX.Channel.LOCAL, 'appearance', 'decision')

-- The shop the player is currently being served at, or nil. Set when the room
-- is asked for and cleared when it closes: the uniforms strip and the WEAR
-- request name it, and a room opened for any other reason -- the join offer, a
-- staff member -- is not a room at this shop.
local serving = nil

-- The open room's prices by slot, its currency, and the priced uniforms picked
-- in it, for the line that says what Save will cost (see `bill`).
local roomPrices, roomCurrency, picked = {}, nil, {}
local priceRoom

-- The ready-made looks the server said this player may take here.
local offered = {}

-- What the eye owns, so it can be taken down on stop.
local OWNER = 'shops'
local ROW = 'shops.fitting'

-- The list and the form, resolved in Start. Both optional: a runtime without
-- them keeps the shop floor and loses the outfit screens, which is a missing
-- feature and not a broken shop -- the same bargain `target` is on.
local menu, form = nil, nil

-- Whether a fitting room is open right now, and the saved outfits the server
-- last sent. `roomOpen` is TRACKED RATHER THAN ASKED because the answer decides
-- which of two completely different paths an outfit takes on: through the room's
-- draft when one is open, and through a fresh puppet borrow when none is.
local roomOpen, saved = false, {}

-- A name the player typed for a save that cannot be sent yet, or nil.
--
-- WHY A SAVE HAS TO WAIT. The server writes down what the character IS wearing,
-- read from its own stored record -- `onSave` says why, and it is right: a
-- client that named the garments could name a restricted uniform's record and
-- load it back later past every gate. But inside an open fitting room the stored
-- record is still what the player walked in wearing, so a save sent then would
-- write down the OLD look under the new name, silently, and the player would
-- find the wrong outfit in their list days later. So the name is held and sent
-- when `clothingSaved` says the new look has actually landed.
local pendingSave = nil

-- The ids of the category buttons this module offers the fitting room. Short,
-- because they are namespaced by the room before they reach the page and
-- unwrapped before they come back.
local GROUP_LOOKS, GROUP_OUTFITS = 'looks', 'outfits'
local GROUP_SAVE, GROUP_CODE = 'save', 'code'

-- The ids the two screens carry, and the handles they were opened under.
--
-- THE HANDLE IS NOT OPTIONAL. Both contracts refuse a `Close` with no handle --
-- `handle_required` -- so "close whatever we have up" has to be written down as
-- the handle we were given, or the close is a call that answers a refusal
-- nobody reads and leaves the screen exactly where it was.
local MENU_ID, FORM_ID = 'shops.outfits', 'shops.outfit'
local menuHandle, formHandle = nil, nil

--- The shops, read from config on this side too.
--
-- THE SAME LIST, READ TWICE, and that is correct rather than duplicated state:
-- the config is a `shared_script`, so both halves read the same file, and the
-- client needs the positions to draw anything at all. What it must never do is
-- read the PRICES for anything other than showing them -- and it does not read
-- them at all, because the server states the bill.
local function shopList()
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	local declared = type(settings.SHOPS) == 'table' and settings.SHOPS or {}

	local out = {}
	for key, raw in pairs(declared) do
		local x, y, z = tonumber(raw.X), tonumber(raw.Y), tonumber(raw.Z)
		if type(key) == 'string' and x ~= nil and y ~= nil and z ~= nil then
			out[#out + 1] = { key = key, x = x, y = y, z = z,
				label = type(raw.LABEL) == 'string' and raw.LABEL or key }
		end
	end
	-- Sorted by key so the list is the same list on every boot. It used to be
	-- sorted so that a SPHERE INDEX would mean the same shop twice -- an index the
	-- eye never sends, which is the bug `onSelect` below now records. The order is
	-- kept anyway, because it is what makes two shops standing on top of each
	-- other resolve the same way every time instead of by `pairs` order.
	table.sort(out, function(left, right) return left.key < right.key end)
	return out
end

--- Metres a shop serves from, mirrored from the server's own reach.
local function reach()
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	local metres = tonumber(settings.REACH)
	if metres == nil or metres < 0.5 or metres > 50.0 then return 3.0 end
	return metres
end

-- ── the floor ───────────────────────────────────────────────────────────────

--- Puts one row on every shop position.
local function placeRows()
	if target == nil then return end

	local shops = shopList()
	if #shops == 0 then return end

	local spheres = {}
	for index = 1, #shops do
		local shop = shops[index]
		spheres[index] = { x = shop.x, y = shop.y, z = shop.z, radius = reach() }
	end

	local placed = target.RegisterSpheres(OWNER, spheres, {
		id = ROW,
		label = locale('shops.row'),
		icon = 'person',
		distance = reach(),
		order = 20,
		onSelect = function(context)
			-- THE EYE NEVER ANSWERED WITH A SPHERE INDEX, and this row spent its
			-- whole life reading one. `contextAt` in `modules/target/client/main.lua`
			-- builds `screen`, `playerDistance`, `position`, `target` and `kind`, and
			-- `commit` adds `option = { id, owner, token, data }` -- there is no
			-- `index` anywhere in it and never was. So `payload.index` was nil, the
			-- lookup answered nil, and every press on a shop row returned silently:
			-- no room, no toast, no log line. Registering the spheres in sorted key
			-- order was bookkeeping for an answer that does not exist.
			--
			-- THE POSITION IS THE ANSWER, which is the idiom `inventory`'s pile row
			-- already uses (`World.TakePile`): the eye says WHERE on the world it
			-- landed, and the module matches that against the things it put there.
			-- A shop is a sphere of `reach()` metres, so the nearest shop within
			-- that radius of the hit is the shop the player pressed -- and when two
			-- shops overlap, the nearer one is the one under the crosshair.
			local at = type(context) == 'table' and context.position or nil
			if type(at) ~= 'table' then return end
			if not (OPX.Math.IsFinite(at.x) and OPX.Math.IsFinite(at.y)
				and OPX.Math.IsFinite(at.z)) then
				return
			end

			local best, bestGap = nil, reach()
			for index = 1, #shops do
				local shop = shops[index]
				local dx, dy, dz = at.x - shop.x, at.y - shop.y, at.z - shop.z
				local away = math.sqrt(dx * dx + dy * dy + dz * dz)
				if away <= bestGap then best, bestGap = shop, away end
			end
			if best == nil then return end
			serving = best.key
			TriggerServerEvent(M.Event.OPEN, best.key)
		end,
	})

	if not placed.ok then
		Open77.log.warn(('[shops] the shop rows were refused: %s'):format(tostring(placed.error)))
	end
end

-- ── what comes back ─────────────────────────────────────────────────────────

--- Puts a partial look on, slot by slot, through the fitting room's own door.
--
-- THROUGH THE CONTRACT, NOT THROUGH THE MODULE. `appearance` publishes
-- `BeginClothingPreview` / `EndClothingPreview` for exactly this, and reaching
-- into its `Clothing` table instead would be this module learning another's
-- internals -- the thing `config/entry.lua` writes the rule about. The borrow
-- also gives the two guarantees a shop needs and could not build: while it is
-- held nothing is saved and no look is published, and ending it with `keep`
-- hands the save to the half that owns it.
local function putOn(wear)
	if type(wear) ~= 'table' then return end
	if wardrobe == nil then return OPX.Toast.Locale('shops.cannotDress', nil, 'error') end

	local borrowed = wardrobe.BeginClothingPreview(OWNER)
	if not borrowed.ok then
		return OPX.Toast.Locale('shops.cannotDress', { reason = tostring(borrowed.error) },
			'error')
	end

	local worn = type(borrowed.value) == 'table' and borrowed.value.clothing or nil
	local equipment = type(worn) == 'table' and type(worn.equipment) == 'table'
		and worn.equipment or nil
	if equipment == nil then
		wardrobe.EndClothingPreview(OWNER, false)
		return OPX.Toast.Locale('shops.cannotDress', nil, 'error')
	end

	-- A PARTIAL RECORD OVER WHAT IS ALREADY ON, which is what makes a uniform a
	-- jacket and trousers rather than a whole silhouette. The slots the look does
	-- not name keep whatever the player had.
	local slots, records = {}, {}
	for index = 1, #M.SLOTS do
		local slot = M.SLOTS[index]
		local wanted = wear[slot]
		if wanted == nil then wanted = equipment[slot] end
		if wanted == nil then wanted = false end
		slots[slot] = wanted
		if type(wanted) == 'string' then records[#records + 1] = wanted end
	end

	-- `allowRestricted`, like the fitting room: a record the character is being
	-- handed is not this module's to second-guess. Sequential and able to apply
	-- part of a set before failing, which is why the borrow is ended either way
	-- -- a half-applied look still has to be given back.
	local called, ok, reason = pcall(Open77.equipment.apply, slots,
		{ allowRestricted = true })
	if not called or not ok then
		wardrobe.EndClothingPreview(OWNER, false)
		return OPX.Toast.Locale('shops.cannotDress',
			{ reason = tostring(called and reason or ok) }, 'error')
	end

	wardrobe.EndClothingPreview(OWNER, true, records)
end

-- ── the outfit screens ──────────────────────────────────────────────────────
-- NOTHING BELOW IS NEW MACHINERY. The saved-outfit table, the per-character
-- limit, the job gate and the share codes were all already written -- in
-- `module.lua`, `server/main.lua` and `server/storage.lua` -- and every one of
-- their net events already existed. What was missing was any way for a player to
-- REACH them: no client in this resource ever sent `SAVE`, `LIST`, `LOAD`,
-- `DELETE`, `SHARE` or `REDEEM`, so a finished feature sat behind no door. This
-- section is the door, and it is deliberately thin: a category strip on the
-- fitting-room screen, a list, and two one-field forms.

--- The OUTFITS block of the shop settings, never nil.
-- READ ON THIS SIDE TOO, and legitimately: `config/shops.lua` is a shared
-- script, so both halves read the same file. What the client uses it for is the
-- SHAPE of a form -- how long a code is, whether to offer sharing at all -- and
-- never the decision, which the server takes again from the same numbers.
local function outfitConfig()
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	return type(settings.OUTFITS) == 'table' and settings.OUTFITS or {}
end

--- How many characters a share code is, mirrored from the server's own bound.
local function codeLength()
	local wanted = tonumber(outfitConfig().CODE_LENGTH)
	if wanted == nil or wanted < 4 or wanted > 16 then return 8 end
	return math.floor(wanted)
end

--- Whether this server mints and takes share codes at all.
local function sharing()
	return outfitConfig().SHARING ~= false
end

--- Offers the open fitting room the categories this player may reach from it.
--
-- THE GATE IS WHICH BUTTONS EXIST, not which ones refuse when pressed. That is
-- the same rule `looksFor` states on the server -- "a uniform nobody may wear is
-- not a row somebody has to be refused at" -- applied one screen further out.
-- So:
--
--   Uniforms   only at a shop, and only when the SERVER sent at least one look
--              for this player. The job gate is already applied by then, so an
--              empty list means "your job entitles you to nothing here" and the
--              category is simply not there.
--   Outfit code only when sharing is on.
--   My outfits / Save outfit are always offered: a saved look is the player's
--              own bookmark, it costs nothing, and the server's own comment says
--              loading one does not need a shop.
local function offerGroups()
	if wardrobe == nil or not roomOpen then return end

	local rows = {}
	if serving ~= nil and #offered > 0 then
		rows[#rows + 1] = { id = GROUP_LOOKS, label = locale('shops.group.looks') }
	end
	rows[#rows + 1] = { id = GROUP_OUTFITS, label = locale('shops.group.outfits') }
	rows[#rows + 1] = { id = GROUP_SAVE, label = locale('shops.group.save') }
	if sharing() then
		rows[#rows + 1] = { id = GROUP_CODE, label = locale('shops.group.code') }
	end

	local told = wardrobe.OfferWardrobeGroups(OWNER, rows)
	if not told.ok then
		Open77.log.warn(('[shops] the fitting room refused the category strip: %s')
			:format(tostring(told.error)))
	end
end

--- What Save will cost, as the room's status line says it.
--
-- THE ROOM SHOWED NO PRICES. The first amount a player saw was "Paid X" after
-- Save. This answers the room's pricer with the bill the server will make:
-- every moved slot at this shop's price, except the slots wearing a uniform
-- picked here, which are billed once at the uniform's own price. Display only:
-- the server bills from its own tables and its own diff.
local function bill(slots, draft)
	local total, prepaid = 0, {}
	for _, look in ipairs(picked) do
		local worn = false
		for slot, record in pairs(look.wear) do
			if record ~= false and type(draft) == 'table' and draft[slot] == record then
				prepaid[slot], worn = true, true
			end
		end
		if worn then total = total + look.cost end
	end
	for _, slot in ipairs(slots) do
		if not prepaid[slot] then
			local price = tonumber(roomPrices[slot])
			if price ~= nil and price > 0 then total = total + math.floor(price) end
		end
	end
	if total <= 0 then return nil end
	return locale('shops.room.total', { total = OPX.Locale.Money(total, roomCurrency) })
end

--- Hands the open room its pricer, once there is a room and a price list.
priceRoom = function()
	if not roomOpen or wardrobe == nil or type(wardrobe.PriceWardrobe) ~= 'function' then return end
	pcall(wardrobe.PriceWardrobe, OWNER, bill)
end

--- Puts a look on, whichever of the two ways is the right one right now.
--
-- THE FORK THAT MAKES THE WHOLE FEATURE WORK. With a fitting room open the
-- puppet is lent to `appearance`, so `putOn`'s `BeginClothingPreview` is refused
-- and loading an outfit from the clothing screen did nothing whatsoever -- no
-- toast, no log line, no clothes. `DressWardrobe` goes in through the room's
-- draft instead, which moves the sliders, keeps Cancel working, and puts the
-- moved slots on `wardrobeClosed` so the shop bills them like any other change.
local function dress(wear)
	if type(wear) ~= 'table' then return end
	if not roomOpen or wardrobe == nil then return putOn(wear) end

	local dressed = wardrobe.DressWardrobe(wear)
	if not dressed.ok then
		OPX.Toast.Locale('shops.dressFailed',
			{ reason = tostring(dressed.error):gsub('_', ' ') }, 'error')
	end
end

--- Takes down whichever outfit screens this module put up.
local function closeScreens()
	if menu ~= nil and menuHandle ~= nil then pcall(menu.Close, menuHandle, 'caller') end
	if form ~= nil and formHandle ~= nil then pcall(form.Close, formHandle) end
	menuHandle, formHandle = nil, nil
end

-- The id the empty-state row carries. Named rather than inline because it is the
-- one row in this file a press must do nothing with, and `showOutfits`'s handler
-- reads `data` to decide -- a row with no `data` falls out of every branch there.
local EMPTY_ROW = 'empty'

--- A list that is never empty: the caller's rows, or one row saying there are none.
--
-- WHY THIS EXISTS, AND WHY THE COMMENT IT RESTORES WAS RIGHT ALL ALONG.
-- `showOutfits` has always said, directly above the list it builds, that "an
-- empty list is still a list... a menu that refused to open would look like the
-- button was broken rather than like the shelf was empty" -- and then handed
-- `menu.Open` a list of length zero, which `normalizeItems` refuses outright
-- (`empty_menu`). `showMenu` turned that refusal into `shops.noSurface` -- "That
-- screen is not available right now." -- so a player who had saved no outfits
-- pressed My outfits and was told the screen did not exist. The `status` line the
-- caller wrote for exactly this case never drew, because the menu was refused
-- before it could carry one. The comment and the code disagreed, and the
-- disagreement WAS the bug.
--
-- A DISABLED ACTION ROW AND NOT A SEPARATOR, which is the second half of the
-- fix. `normalizeItems` refuses a level of nothing but separators too
-- (`only_separators`) because the cursor would have nowhere to stand; it says in
-- the same breath that "a level of nothing but disabled rows is a real menu". So
-- the placeholder is a real row that cannot be chosen: it draws, it dims, and
-- `cursorIndex` parks the cursor on it without it ever reporting a press.
local function orEmpty(items, text)
	if #items > 0 then return items end
	return { { id = EMPTY_ROW, label = text, disabled = true } }
end

--- Draws one list, reporting a refusal rather than failing silently.
local function showMenu(spec)
	if menu == nil then return OPX.Toast.Locale('shops.noSurface', nil, 'error') end
	spec.owner = OWNER
	spec.id = MENU_ID
	-- `steal`, because the only menu this could be taking over is one of ours: a
	-- player who pressed My outfits, read a code and pressed it again should get
	-- the list, not `menu_busy`.
	spec.steal = true
	local drawn = menu.Open(spec)
	if not drawn.ok then
		menuHandle = nil
		OPX.Toast.Locale('shops.noSurface', nil, 'error')
		Open77.log.warn(('[shops] the outfit list was refused: %s')
			:format(tostring(drawn.error)))
		-- AND WHERE THE OPERATOR CAN READ IT. `Open77.log.warn` writes to the
		-- PLAYER's machine, which is precisely why `empty_menu` went unfound: the
		-- only record of the refusal was on the one computer nobody running the
		-- server can look at, and what reached the operator was a player saying a
		-- button says the screen is not available. A refusal that ends in a toast
		-- the player cannot act on is a refusal the operator has to hear about.
		return OPX.Note('shops', ('the outfit list was refused: %s')
			:format(tostring(drawn.error)))
	end
	menuHandle = type(drawn.value) == 'table' and drawn.value.handle or nil
end

--- Draws one form, reporting a refusal rather than failing silently.
local function showForm(spec)
	if form == nil then return OPX.Toast.Locale('shops.noSurface', nil, 'error') end
	spec.owner = OWNER
	spec.id = FORM_ID
	-- The form has no `steal`, so anything already up has to go first -- and it
	-- can only be ours: nothing else on this screen opens one.
	if menu ~= nil and menuHandle ~= nil then
		pcall(menu.Close, menuHandle, 'caller')
		menuHandle = nil
	end
	local drawn = form.Open(spec)
	if not drawn.ok then
		formHandle = nil
		OPX.Toast.Locale('shops.noSurface', nil, 'error')
		Open77.log.warn(('[shops] the outfit form was refused: %s')
			:format(tostring(drawn.error)))
		return OPX.Note('shops', ('the outfit form was refused: %s')
			:format(tostring(drawn.error)))
	end
	formHandle = type(drawn.value) == 'table' and drawn.value.handle or nil
end

--- The ready-made looks this shop carries for this player.
local function showLooks()
	local items = {}
	for index = 1, #offered do
		local look = offered[index]
		items[index] = {
			id = 'look.' .. tostring(look.id),
			label = tostring(look.label or look.id),
			-- The cost is stated because it is CHARGED: unlike a saved outfit,
			-- a ready-made look is a purchase and the server takes the money before
			-- it sends the garments.
			value = tonumber(look.cost) and tonumber(look.cost) > 0
				and OPX.Locale.Money(look.cost) or nil,
			data = { verb = 'wear', look = look.id },
			close = true,
		}
	end
	-- THE SAME SHAPE AS `showOutfits`, AND IT FAILED THE SAME WAY. The Uniforms
	-- category is only offered when the server sent at least one look, so this
	-- list is normally non-empty -- but `offered` is cleared on `wardrobeClosed`
	-- and the strip is republished from two racing places, so a press that lands
	-- between the two built a list of nothing and was answered with "that screen
	-- is not available". A counter configured with no ready-made looks at all
	-- reaches it the same way.
	showMenu{ title = locale('shops.looks.title'),
		items = orEmpty(items, locale('shops.looks.empty')), focus = 'cursor',
		status = #items == 0 and locale('shops.looks.empty') or nil,
		on = function(payload)
			local data = type(payload) == 'table' and payload.data or nil
			if type(data) ~= 'table' or data.verb ~= 'wear' then return end
			TriggerServerEvent(M.Event.WEAR, { shop = serving, look = data.look })
		end }
end

--- The player's own saved outfits, each with the three things they can do to one.
local function showOutfits()
	local items = {}
	for index = 1, #saved do
		local outfit = saved[index]
		local rows = {
			{ id = 'wear', label = locale('shops.outfits.wear'),
				data = { verb = 'load', id = outfit.id }, close = true },
		}
		if sharing() then
			rows[#rows + 1] = { id = 'share', label = locale('shops.outfits.share'),
				data = { verb = 'share', id = outfit.id } }
		end
		-- CONFIRMED, because a deleted outfit is gone for good and this row sat one
		-- arrow key under Wear. The menu's own `confirm` builds the two rows, the
		-- one that keeps the outfit first.
		rows[#rows + 1] = { id = 'delete', label = locale('shops.outfits.delete'),
			data = { verb = 'delete', id = outfit.id },
			confirm = { no = locale('shops.outfits.keep'),
				yes = locale('shops.outfits.deleteConfirm', { name = tostring(outfit.name) }) } }

		items[index] = {
			id = 'outfit.' .. tostring(outfit.id),
			label = tostring(outfit.name),
			-- A code already minted is shown on the row rather than behind the
			-- share button: the player asked for it so they could read it out, and
			-- making them press through to it again every time is the one thing a
			-- code is not for.
			value = type(outfit.code) == 'string' and outfit.code or nil,
			items = rows,
		}
	end

	showMenu{
		title = locale('shops.outfits.title'), focus = 'cursor',
		-- AN EMPTY LIST IS STILL A LIST. A player who has saved nothing pressed the
		-- button on purpose, and a menu that refused to open would look like the
		-- button was broken rather than like the shelf was empty.
		--
		-- AND NOW THE CODE SAYS SO TOO. `orEmpty` is what makes the sentence above
		-- true: it puts one dimmed row where the outfits would be, so the menu has
		-- a list to open and the shelf is visibly empty. Handing `items` straight
		-- through was the bug -- `menu.Open` refused the zero-length list with
		-- `empty_menu` and the player was told the screen did not exist.
		items = orEmpty(items, locale('shops.outfits.empty')),
		status = #items == 0 and locale('shops.outfits.empty') or nil,
		on = function(payload)
			local data = type(payload) == 'table' and payload.data or nil
			if type(data) ~= 'table' then return end
			if data.verb == 'load' then
				TriggerServerEvent(M.Event.LOAD, { id = data.id })
			elseif data.verb == 'share' then
				TriggerServerEvent(M.Event.SHARE, { id = data.id })
			elseif data.verb == 'delete' then
				TriggerServerEvent(M.Event.DELETE, { id = data.id })
			end
		end,
	}
end

--- Asks for a name, then saves what the character is wearing under it.
local function askSave()
	showForm{
		title = locale('shops.save.title'),
		fields = { { id = 'name', label = locale('shops.save.field'), required = true,
			maxLength = tonumber(outfitConfig().MAX_NAME_BYTES) or 48 } },
		on = function(payload)
			if type(payload) ~= 'table' or payload.action ~= 'submit' then return end
			local name = type(payload.values) == 'table' and payload.values.name or nil
			name = type(name) == 'string' and OPX.String.Trim(name) or ''
			if name == '' then return end

			-- HELD, NOT SENT, while a room is open. See `pendingSave`: the server
			-- writes down the STORED look, and inside a fitting room that is still
			-- the one walked in with.
			if roomOpen then
				pendingSave = name
				return OPX.Toast.Locale('shops.save.queued', { name = name }, 'info')
			end
			TriggerServerEvent(M.Event.SAVE, { name = name })
		end,
	}
end

--- Asks for a code somebody read out, and wears whatever answers it.
local function askCode()
	local length = codeLength()
	showForm{
		title = locale('shops.code.title'),
		description = locale('shops.code.hint', { length = length }),
		fields = { { id = 'code', label = locale('shops.code.field'), required = true,
			-- LONGER THAN A CODE ON PURPOSE. `M.CleanCode` forgives dashes, spaces
			-- and case -- because somebody WILL read one out with the dashes in the
			-- wrong places -- and a field cut to exactly eight characters would eat
			-- the forgiveness before the parser ever saw the text.
			maxLength = length * 2 } },
		on = function(payload)
			if type(payload) ~= 'table' or payload.action ~= 'submit' then return end
			local typed = type(payload.values) == 'table' and payload.values.code or nil
			if type(typed) ~= 'string' then return end
			-- CLEANED HERE AND AGAIN ON THE SERVER, and the double is the point: this
			-- one is so an obvious typo is answered on the spot instead of after a
			-- round trip, and the server's is the one that decides.
			local code = M.CleanCode(typed, length)
			if code == nil then return OPX.Toast.Locale('shops.badCode', nil, 'error') end
			-- With the shop whose room this is: a code is worn only inside a
			-- shop's room and billed at its prices, and the server checks both.
			if serving == nil then return OPX.Toast.Locale('shops.redeemAtShop', nil, 'error') end
			TriggerServerEvent(M.Event.REDEEM, { code = code, shop = serving })
		end,
	}
end

-- What each category button does. Keyed by the id this module offered, which is
-- what the fitting room hands back after unwrapping its own namespace.
local GROUPS = {
	[GROUP_LOOKS] = showLooks,
	[GROUP_OUTFITS] = function()
		-- ASKED FOR EVERY TIME RATHER THAN CACHED. The list is short, it changes
		-- whenever a save or a delete lands, and a stale one would offer a
		-- Put-it-on for an outfit that is no longer there.
		TriggerServerEvent(M.Event.LIST)
		showOutfits()
	end,
	[GROUP_SAVE] = askSave,
	[GROUP_CODE] = askCode,
}

--- Wires the doors.
-- @author dop42
function M.Start()
	wardrobe = OPX.Api.Get('appearance')
	target = OPX.Api.Get('target')
	menu = OPX.Api.Get('menu')
	form = OPX.Api.Get('form')
	if menu == nil or form == nil then
		Open77.log.warn('[shops] no list or no form contract: the outfit screens are off')
	end
	if target == nil then
		Open77.log.warn('[shops] no target contract: the shops are on the map but unreachable')
	else
		placeRows()
	end

	-- THE ROOM'S DECISIONS. No bill is raised here any more: the server charges
	-- the clothing save itself. `serving` is cleared when the room closes.
	AddEventHandler(ON_DECISION, function(decision)
		if type(decision) ~= 'table' then return end
		local event = decision.event

		-- THE STRIP IS OFFERED WHEN THE ROOM OPENS, and offered again when the
		-- server's look list lands, because the two race: `onOpen` sends `LOOKS`
		-- and then asks `appearance` to open the room, and which of those reaches
		-- this client first is not something either side promises.
		if event == 'wardrobeOpened' and decision.ok ~= false then
			roomOpen = true
			priceRoom()
			return offerGroups()
		end

		-- A PRESSED CATEGORY, reported by the room after it has unwrapped its own
		-- namespace. Checked against the offering module's name because the room
		-- publishes every module's presses on the one bus.
		if event == 'wardrobeGroup' then
			if decision.owner ~= OWNER then return end
			local run = GROUPS[decision.group]
			if run then run() end
			return
		end

		-- THE QUEUED SAVE, LANDING. `clothingSaved` is raised once the new look has
		-- actually been written, which is the first moment the server's own record
		-- of what this character wears agrees with what the player just chose --
		-- and that record is what `onSave` writes down.
		if event == 'clothingSaved' then
			local name = pendingSave
			pendingSave = nil
			if name ~= nil and decision.ok ~= false then
				TriggerServerEvent(M.Event.SAVE, { name = name })
			end
			return
		end

		if event ~= 'wardrobeClosed' then return end

		roomOpen = false
		closeScreens()
		-- A CANCELLED ROOM DROPS THE QUEUED SAVE. The player named a look they
		-- then decided not to keep; writing the one they walked in with down under
		-- that name is exactly the confusion the queue exists to avoid. And it is
		-- SAID: the player was told "it will be saved when you finish here".
		--
		-- A ROOM LEFT BY SAVE WITH NOTHING CHANGED IS NOT A CANCEL. It closes
		-- `kept = false` too, because keeping what was never changed writes
		-- nothing, so no `clothingSaved` ever comes -- and "save the look I am
		-- wearing" silently saved nothing. The stored look IS what is worn then,
		-- so it is written down now.
		if decision.kept ~= true and pendingSave ~= nil then
			local name = pendingSave
			pendingSave = nil
			if decision.asked == true then
				TriggerServerEvent(M.Event.SAVE, { name = name })
			else
				OPX.Toast.Locale('shops.save.dropped', { name = name }, 'info')
			end
		end

		serving, offered, saved = nil, {}, {}
		roomPrices, picked = {}, {}
	end)

	RegisterNetEvent(M.Event.LOOKS, function(payload)
		offered = type(payload) == 'table' and type(payload.looks) == 'table'
			and payload.looks or {}
		roomPrices = type(payload) == 'table' and type(payload.prices) == 'table' and payload.prices or {}
		roomCurrency = type(payload) == 'table' and type(payload.currency) == 'string'
			and payload.currency or nil
		picked = {}
		-- No pricer to hand here: it reads these tables when it is asked, and
		-- `offerGroups` below republishes the room.
		-- Offered again: this may have arrived after the room opened, and the
		-- Uniforms category exists only when this list is not empty.
		offerGroups()
	end)

	RegisterNetEvent(M.Event.PUT_ON, function(payload)
		if type(payload) ~= 'table' then return end
		-- A uniform picked in the room is billed at its own price on Save; the
		-- room's line counts it so, for the slots that are wearing it.
		if roomOpen and type(payload.wear) == 'table' then
			for _, look in ipairs(offered) do
				if look.id == payload.look and (tonumber(look.cost) or 0) > 0 then
					picked[#picked + 1] = { wear = payload.wear, cost = tonumber(look.cost) }
				end
			end
		end
		dress(payload.wear)
	end)

	RegisterNetEvent(M.Event.SAVED, function(payload)
		saved = type(payload) == 'table' and type(payload.outfits) == 'table'
			and payload.outfits or {}
		TriggerEvent(M.Event.ON_STATE, { saved = saved })
		-- REDRAWN AND NOT JUST STORED. This arrives after a save, a delete and the
		-- `LIST` the category button sends -- and in all three cases the list on
		-- screen is the one that just went out of date.
		if menu ~= nil and menuHandle ~= nil then
			local held = menu.State()
			local state = held.ok and held.value or nil
			if type(state) == 'table' and state.open == true and state.owner == OWNER then
				showOutfits()
			end
		end
	end)

	RegisterNetEvent(M.Event.CODE, function(payload)
		if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
		TriggerEvent(M.Event.ON_STATE, { code = payload.code, id = payload.id })
		-- SHOWN AS A TOAST AND NOT ONLY ON THE ROW. A code exists to be read out
		-- loud to somebody else, so the moment it is minted is the moment it has to
		-- be legible -- not two presses back inside a list.
		OPX.Toast.Locale('shops.outfits.shared', { code = payload.code }, 'success')
		-- And written onto the row, so it survives the toast fading.
		local id = tonumber(payload.id)
		for index = 1, #saved do
			if tonumber(saved[index].id) == id then saved[index].code = payload.code end
		end
	end)
end

--- Takes the rows down.
-- @author dop42
function M.Stop()
	if target ~= nil then pcall(target.Clear, OWNER) end
	-- THE SCREENS GO TOO. A list or a form left up by a stopped module is a page
	-- holding the player's cursor with nothing behind it to answer a press.
	closeScreens()
	serving, offered, saved = nil, {}, {}
	roomOpen, pendingSave = false, nil
	menuHandle, formHandle = nil, nil
end
