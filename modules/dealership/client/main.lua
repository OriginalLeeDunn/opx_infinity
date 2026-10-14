--- Client half: the markers, the strip row, the key, and the list you buy from.
-- @author XEROX710
--
-- WHAT IS DRAWN HERE IS A HINT, and the list doubly so. The nearest dealer, the
-- radius, the stock and the price all decide only what this player is OFFERED;
-- the server re-derives the distance, the bucket, whether that dealer sells that
-- model and whether the money is there before anything is charged or created.
--
-- The dealers come from the server and never from `config/dealership.lua`
-- directly: captured dealers live in the database, and the server filters the
-- list to this player's own routing bucket. The prices come from the server for
-- the same reason -- it owns the currency table, and a client that formatted its
-- own would be a second answer to a question with one.
--
-- THE LIST IS THE `menu` MODULE'S, one flat screen at a time, with this file
-- holding its own stack -- the pattern the emote picker established. The whole
-- tree in one spec goes past the host's 1024-value bound, and a catalogue is
-- whatever an operator made it: two screens of forty rows each is a shop, and a
-- shop that silently stopped opening because the stock list grew is not.
--
-- The destination choice is read from the GARAGES contract, not resent by this
-- module: which garages exist, and where they are, is that module's answer, and
-- asking for a copy would be asking for a copy to keep in step.
--
-- The heading a capture records is read HERE and not on the server: a chat
-- command has no facing, and `Open77.character.yaw` is the only place a facing
-- exists. It is the one field this half contributes, and it only turns a
-- vehicle that is handed over where it was bought.

local M = OPX.Modules.Get('dealership')
local Access = M.Access

M.Runtime = {}
local Runtime = M.Runtime

-- What the prompts contract records as this module's own.
local OWNER = 'dealership'
local GROUP = 'dealer'

-- The id the menu is opened under, and the same id comes back on every payload.
-- Stable, because a payload names it.
local SPEC_ID = 'dealership'

-- The dealer list as the server last sent it, and the markers drawn for it.
local spots = {}
local markers = OPX.Spots.Markers.New({
	tag = 'dealership',
	look = function(spot) return Access.Marker(spot.kind) end,
	maxDistance = function() return Access.MaxDistance() end,
})

-- What each kind of dealer sells, as the server sent it: `{ garage = {},
-- avpad = {} }` of `{ key, label, class, price, text }`.
local stock = { garage = {}, avpad = {} }

-- The dealer the player is standing on, whether its row is up, and the locale
-- key that row is naming. THE LABEL IS STATE, not a function of the boolean:
-- there are two kinds with two different strings, so a sync that compared only
-- "is a row up" would leave "Browse vehicles" standing over an AV pad the player
-- walked onto straight from a car dealer, without `nearest` ever passing nil.
local nearest, shown, shownLabel = nil, false, nil
-- The squared distance to `nearest` the last scan measured, for the key's claim.
local nearestSq = nil

-- Whether the key mapping answered.
local keyRegistered = false

-- The open menu's handle, and the screen stack this file owns, or nil/empty.
local handle, stack = nil, {}

-- THE OFFER THIS PLAYER HAS BEEN MADE, or nil. It is the only screen in this
-- module somebody else opens, so it is held outside the stack: the stack is what
-- the player navigated to and this is what arrived.
local offer = nil

-- Whether that offer is WAITING behind a list of the player's own. An offer
-- used to take down whatever dealership menu was open and replace it, so a key
-- press meant for the player's own row could land on "Buy it" instead. It now
-- waits, said in a toast, and opens when that list closes.
local offerWaiting = false

-- Whether this player is standing inside a dealer's ZONE, and the dealer it is.
-- Being in one is what grows the "sell a vehicle" row on every other player.
local zone = nil

-- Whether the eye's rows are registered now, so the registration runs on a
-- CHANGE and not once a scan: `target.RegisterPlayers` is a whole-registry
-- write, and doing it twice a second would be a write per scan for ever.
local zoneRows = false

-- Said once when the eye refuses the row, for the same reason the marker and the
-- strip each have their own flag.
local reportedTarget = false

-- Whether each failure was already logged. A marker that cannot be drawn and a
-- row that cannot be posted are different problems and a player reading the log
-- wants to know which one they have.
local reportedStrip, reportedMenu = false, false

-- Scheduler handles, so Stop can cancel them.
local scanJob, askJob = nil, nil

-- ── config and the player ───────────────────────────────────────────────────

-- Reads the key declaration, with the shipped value as the fallback so a config
-- that lost its KEY block still names a key.
local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or { ID = 'opx.dealership.use', NAME = 'dealership.key.use', DEFAULT = 'E' }
end

-- Reads the menu geometry declaration, with the shipped panel as the fallback so a
-- config that lost its MENU block still opens a large centred list rather than a
-- strip down the corner. The menu module clamps every value it is handed.
local function menuSettings()
	local declared = type(M.Settings.MENU) == 'table' and M.Settings.MENU or nil
	return declared or { ANCHOR = 'center', WIDTH = 708, HEIGHT = 708, MAX_HEIGHT_VH = 88, VISIBLE_ROWS = 15 }
end

-- The player's ground position, and whether another surface holds the
-- keyboard: the readings every spot module makes, in `lib/client/spots.lua`.
local playerXY, captured = OPX.Spots.PlayerXY, OPX.Spots.Captured

-- ── the strip ───────────────────────────────────────────────────────────────

-- Names the key the row is bound to, or nil when it is off or was refused -- a
-- row with no key to name says nothing.
local function keyLabel()
	return OPX.Spots.Key.Label(keyRegistered, keySettings())
end

-- What the key is about to open, as a locale key: a car dealer and an AV pad are
-- the same gesture but two different lists, so the row has to name the one it is
-- standing over.
local function promptLabel()
	if nearest == nil then return nil end
	return 'dealership.prompt.' .. nearest.kind
end

-- Brings the strip in line with where the player is standing AND with which kind
-- of dealer that is: comparing only "is a row up" would keep a car dealer's
-- label over an adjacent AV pad, because both want a row.
local function syncPrompt()
	-- The claim on the shared key is filed every scan, row or no row, and the
	-- row is drawn only when no other feature on that key would take the press.
	local wins = OPX.Spots.Key.Shows(keySettings().ID)
	local want = nearest ~= nil and keyLabel() ~= nil and not captured() and handle == nil and wins
	local label = want and promptLabel() or nil
	if want == shown and label == shownLabel then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the key still opens the list, and this is
		-- said once.
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[dealership] no prompts contract; the strip row is not shown')
		end
		shown, shownLabel = false, nil
		return
	end

	shown, shownLabel = want, label
	local ran, answer
	if want then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			-- Short on purpose: the strip never wraps a line. A dealer that sells
			-- AVs says so, because what is behind the key is a different list.
			label = locale(label),
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	local failure = nil
	if not ran then
		failure = tostring(answer)
	elseif type(answer) ~= 'table' or answer.ok ~= true then
		failure = type(answer) == 'table' and tostring(answer.error or 'refused') or 'malformed_answer'
	end
	if failure ~= nil and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[dealership] the strip row was refused: ' .. failure)
	end
end

-- ── the verdicts ────────────────────────────────────────────────────────────

-- Raises the local decision event with a verdict.
local function publish(payload)
	TriggerEvent(M.Event.ON_DECISION, payload)
end

-- Shows one message as a replaced toast, or as a log line when no toast can be
-- raised. Refusals and purchases share the one id, so the last thing said
-- replaces the one before it rather than stacking.
local function say(kind, message)
	local raised = OPX.Toast.Show({
		id = 'opx.dealership.answer',
		kind = kind,
		title = locale('dealership.title'),
		message = message,
		durationMs = 5000,
	})
	if raised == nil then Open77.log.info('[dealership] ' .. tostring(message)) end
end

-- ── the list ────────────────────────────────────────────────────────────────

-- The row handler the menu calls back on. Declared here and assigned below,
-- because the menu contract wants the callback at open time and `draw` is the
-- one that hands it over.
local onRow

-- The menu contract, or nil.
local function menuApi()
	local api = OPX.Api.Get('menu')
	if api == nil or type(api.Open) ~= 'function' or type(api.Close) ~= 'function' then
		if not reportedMenu then
			reportedMenu = true
			Open77.log.info('[dealership] no menu contract: the list cannot be drawn, and ' ..
				'/opx.dealership.buy still sells a vehicle')
		end
		return nil
	end
	return api
end

-- The rows of one screen, and what it is titled. Nil when the screen cannot be
-- built at all, which is how a dealer with nothing to sell says so.
local function screenFor(current)
	if current.screen == 'root' then
		local dealer = nearest
		local rows = type(dealer) == 'table' and stock[dealer.kind] or nil
		if type(rows) ~= 'table' or #rows == 0 then return nil end

		local items = {}
		local lastClass = nil
		for index = 1, #rows do
			local row = rows[index]
			-- A separator per class, on the line where the class changes: the
			-- list is sorted by class, so one pass is enough.
			if row.class ~= lastClass and row.class ~= '' then
				lastClass = row.class
				items[#items + 1] = { separator = true, label = row.class }
			end
			items[#items + 1] = {
				id = row.key,
				label = row.label,
				value = row.text,
				-- A row that leads to the destination choice, not a row that
				-- buys: the arrow column has to say so.
				submenu = true,
				data = { entry = row.key },
			}
		end
		items[#items + 1] = { separator = true, label = '' }
		items[#items + 1] = { id = 'close', label = locale('dealership.close'), close = true }
		return locale('dealership.menu.title', { dealer = tostring(dealer.label) }), items
	end

	-- THE SALESPERSON'S OWN LIST. The same catalogue as the root, and
	-- deliberately not a second one: what a dealer sells does not change because
	-- somebody else is paying. What changes is what a row DOES -- it offers,
	-- rather than buying -- and there is no delivery screen under it, because the
	-- buyer is standing in the showroom and drives it out of here.
	if current.screen == 'sell' then
		local arg = type(current.arg) == 'table' and current.arg or {}
		local dealer = zone
		local rows = type(dealer) == 'table' and stock[dealer.kind] or nil
		if type(rows) ~= 'table' or #rows == 0 or arg.buyer == nil then return nil end

		local items = {}
		local lastClass = nil
		for index = 1, #rows do
			local row = rows[index]
			if row.class ~= lastClass and row.class ~= '' then
				lastClass = row.class
				items[#items + 1] = { separator = true, label = row.class }
			end
			items[#items + 1] = {
				id = row.key,
				label = row.label,
				value = row.text,
				data = { offer = row.key, buyer = arg.buyer },
			}
		end
		items[#items + 1] = { separator = true, label = '' }
		items[#items + 1] = { id = 'close', label = locale('dealership.close'), close = true }
		-- The buyer's server id, never a name: `arg.name` was the eye's
		-- `displayName`, the account gamertag. Never a name to a stranger.
		return locale('dealership.menu.sell', { id = tostring(arg.buyer) }), items,
			{ status = locale('dealership.menu.sellHint') }
	end

	-- THE BUYER'S OWN CONFIRMATION, and the whole reason a sale is two round
	-- trips instead of one. Two rows and no default: neither of them is one the
	-- cursor lands on by accident, and closing the screen answers nothing at all
	-- -- the offer then expires on the server's own clock and the seller is told
	-- so, which is a better outcome than a buyer who bought a car by pressing
	-- escape.
	if current.screen == 'offer' then
		if type(offer) ~= 'table' then return nil end
		return locale('dealership.menu.offer', { model = tostring(offer.model) }), {
			-- YES LEADS TO THE GARAGE CHOICE, the same second screen a counter
			-- sale has: which garage the car is filed under is the buyer's to say.
			{ id = 'yes', label = locale('dealership.offerAccept'), value = tostring(offer.text),
				submenu = true, data = { decide = true } },
			{ id = 'no', label = locale('dealership.offerDecline'), data = { decide = false } },
		}, { status = locale('dealership.menu.offerHint', { price = tostring(offer.text) }) }
	end

	-- THE BUYER'S GARAGE, under a salesperson's offer. The counter's own
	-- destination screen in every way that matters -- one row per garage of the
	-- dealer's kind, or the server's default when there is none -- and each row
	-- is the YES, carrying where it goes.
	if current.screen == 'offerDeliver' then
		if type(offer) ~= 'table' then return nil end
		local arg = type(current.arg) == 'table' and current.arg or {}
		local items = {}
		local places = type(arg.places) == 'table' and arg.places or {}
		for index = 1, #places do
			local place = places[index]
			items[#items + 1] = {
				id = place.key,
				label = place.label,
				value = locale('dealership.deliverHere'),
				data = { decide = true, dest = place.key },
			}
		end
		if #items == 0 then
			items[1] = {
				id = 'default',
				label = locale('dealership.dest.none'),
				value = locale('dealership.deliverHere'),
				data = { decide = true, dest = '' },
			}
		end
		items[#items + 1] = { separator = true, label = '' }
		items[#items + 1] = { id = 'back', label = locale('dealership.back'), back = true }
		return locale('dealership.menu.deliver', { model = tostring(offer.model) }), items, {
			status = locale('dealership.menu.pay', { price = tostring(offer.text) }),
		}
	end

	if current.screen == 'deliver' then
		local arg = type(current.arg) == 'table' and current.arg or {}
		local row = nil
		local rows = type(nearest) == 'table' and stock[nearest.kind] or nil
		for index = 1, type(rows) == 'table' and #rows or 0 do
			if rows[index].key == arg.entry then row = rows[index] end
		end
		if row == nil then return nil end

		local items = {}
		local places = type(arg.places) == 'table' and arg.places or {}
		for index = 1, #places do
			local place = places[index]
			items[#items + 1] = {
				id = place.key,
				label = place.label,
				value = locale('dealership.deliverHere'),
				data = { entry = row.key, dest = place.key },
			}
		end
		if #items == 0 then
			-- Nothing of this category the player may file it under. The row is
			-- still a real choice -- it buys and lets the server's own default
			-- garage take it -- and it says which one that is.
			items[1] = {
				id = 'default',
				label = locale('dealership.dest.none'),
				value = locale('dealership.deliverHere'),
				data = { entry = row.key, dest = '' },
			}
		end
		items[#items + 1] = { separator = true, label = '' }
		items[#items + 1] = { id = 'back', label = locale('dealership.back'), back = true }
		return locale('dealership.menu.deliver', { model = row.label }), items, {
			status = locale('dealership.menu.pay', { price = row.text }),
		}
	end

	return nil
end

-- Closes the open menu, if any, without anything else.
local function closeMenu()
	local closing = handle
	handle, stack = nil, {}
	local api = OPX.Api.Get('menu')
	if closing ~= nil and api ~= nil and type(api.Close) == 'function' then
		pcall(api.Close, closing, 'dealership')
	end
	return closing ~= nil
end

-- Whether the screen up is the offer itself, or the garage step under it.
local function offerOnScreen()
	local top = stack[#stack]
	return handle ~= nil and top ~= nil and (top.screen == 'offer' or top.screen == 'offerDeliver')
end

local draw

-- Puts the offer this player was made on the screen.
local function showOffer()
	offerWaiting = false
	closeMenu()
	stack = { { screen = 'offer' } }
	if not draw() then
		offer = nil
		say('error', locale('dealership.noList'))
	end
	syncPrompt()
end

-- Takes the menu down for a reason of this file's own. An offer that was waiting
-- behind it comes up now.
local function takeDown()
	local closed = closeMenu()
	if offerWaiting and type(offer) == 'table' then
		showOffer()
		return closed
	end
	syncPrompt()
	return closed
end

-- Draws the screen on top of the stack, or updates the one already up.
-- `inPlace` is the navigation redraw: the destination screen is added under the
-- model the player picked, and reopening would throw them back to the top of the
-- list if the menu were reopened rather than updated.
draw = function(inPlace)
	local current = stack[#stack]
	if current == nil then return false end

	local title, items, extra = screenFor(current)
	if title == nil then
		-- The screen cannot be built: the dealer's stock went away under an open
		-- list. Said plainly rather than left as a menu of nothing.
		takeDown()
		say('error', locale('dealership.nothingForSale'))
		return false
	end
	extra = extra or {}

	local api = menuApi()
	if api == nil then
		takeDown()
		return false
	end

	if inPlace then
		if handle == nil then return false end
		local patched = api.Update(handle, { title = title, items = items, status = extra.status })
		if patched ~= nil and patched.ok then return true end
		-- The handle went stale under us: fall through and ask for the menu.
		handle = nil
	end

	-- THE SIZE IS OURS, NOT THE MENU MODULE'S. Everything else hangs off an edge; a
	-- dealership is a shop counter, so it opens centred and large, and the module
	-- takes what it is given rather than the other way round.
	local where = menuSettings()
	local opened = api.Open({
		owner = OWNER,
		id = SPEC_ID,
		title = title,
		on = onRow,
		cursor = current.cursor,
		anchor = where.ANCHOR,
		width = where.WIDTH,
		-- The height and the width are asked for together: a square panel, whatever
		-- the level holds. Without it a three-row screen draws a bar.
		height = where.HEIGHT,
		maxHeight = where.MAX_HEIGHT_VH,
		rows = where.VISIBLE_ROWS,
		items = items,
		status = extra.status,
	})
	if opened == nil or opened.ok ~= true then
		local failure = type(opened) == 'table' and tostring(opened.error or 'refused') or 'refused'
		if not reportedMenu then
			reportedMenu = true
			Open77.log.warn(('[dealership] the list did not open: %s'):format(failure))
		end
		takeDown()
		return false
	end
	handle = opened.value.handle
	return true
end

-- Navigates to a screen under the current one.
local function push(screen, arg)
	stack[#stack + 1] = { screen = screen, arg = arg }
	if draw() then return true end
	stack[#stack] = nil
	return false
end

-- Steps back one screen, closing the list at the top of the stack.
local function pop()
	if #stack <= 1 then return takeDown() end
	stack[#stack] = nil
	return draw()
end

-- The garages a bought vehicle of this kind may be filed under, by key.
-- Read from the garages contract every time a destination screen is opened: it
-- is that module's answer, and a copy would be a copy to keep in step.
--
-- `Garages` AND NOT `Spots`. A garage is a key with several locations now, and
-- `Spots` answers the drawn MARKERS -- so asking it here listed the same garage
-- once per door and filed the bought car under a door, which is a car that comes
-- out of exactly one location and nowhere else.
local function placesFor(kind)
	local api = OPX.Api.Get('garages')
	if api == nil or type(api.Garages) ~= 'function' then return {} end
	local read, answer = pcall(api.Garages)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return {} end
	local listed = type(answer.value) == 'table' and answer.value.garages or nil
	if type(listed) ~= 'table' then return {} end

	local places = {}
	for key, built in pairs(listed) do
		if type(built) == 'table' and built.kind == kind then
			places[#places + 1] = { key = key, label = tostring(built.label or key) }
		end
	end
	table.sort(places, function(left, right) return left.key < right.key end)
	return places
end

-- Sends the purchase this file has already decided to offer.
local function buy(entryKey, destKey)
	local dealer = nearest
	if dealer == nil then
		local verdict = { ok = false, error = 'dealership.noSuchSpot', source = 'client' }
		publish(verdict)
		say('error', locale(verdict.error))
		return verdict
	end
	if type(entryKey) ~= 'string' or entryKey == '' then
		local verdict = { ok = false, error = 'error.badRequest', source = 'client' }
		publish(verdict)
		return verdict
	end

	-- Taken down BEFORE the request, so the key opens rather than closes and a
	-- refusal toast is not raised underneath an open menu.
	takeDown()
	local sent, reason = TriggerServerEvent(M.Event.BUY, dealer.key, entryKey, destKey)
	if not sent then
		local verdict = { ok = false, error = tostring(reason or 'not_sent'), source = 'client' }
		publish(verdict)
		say('error', locale('dealership.refused'))
		return verdict
	end

	local verdict = { ok = true, queued = true, dealer = dealer.key, entry = entryKey,
		garage = type(destKey) == 'string' and destKey ~= '' and destKey or nil,
		source = 'key' }
	publish(verdict)
	return verdict
end

-- Navigates, buys or finishes for a row the menu raised. The shape is checked
-- because the menu also raises every action on its own public bus.
onRow = function(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= SPEC_ID then return end

	if payload.action == 'close' then
		-- A close for a screen this file has already replaced can land after the
		-- new handle; it is not ours to act on.
		if payload.reason == 'reopened' or payload.handle ~= handle then return end
		handle = nil
		-- Back on a one-level screen would close it; step up instead.
		if payload.reason == 'back' and #stack > 1 then return pop() end
		stack = {}
		-- The offer that waited behind the player's own list opens now.
		if offerWaiting and type(offer) == 'table' then return showOffer() end
		return syncPrompt()
	end
	if payload.action ~= 'select' or captured() then return end

	local data = payload.data
	local current = stack[#stack]
	if type(data) ~= 'table' or current == nil then return end
	current.cursor = payload.itemId

	if current.screen == 'root' then
		if type(data.entry) ~= 'string' then return end
		local places = placesFor(type(nearest) == 'table' and nearest.kind or '')
		return push('deliver', { entry = data.entry, places = places })
	end

	-- A ROW ON THE SELL SCREEN OFFERS AND NEVER BUYS. Nothing is charged to
	-- anybody by this press: the server records an offer and the buyer's own
	-- client is what confirms it.
	if current.screen == 'sell' then
		if type(data.offer) ~= 'string' or data.buyer == nil then return end
		takeDown()
		local sent, reason = TriggerServerEvent(M.Event.OFFER, data.buyer, data.offer)
		if not sent then
			publish({ ok = false, error = tostring(reason or 'not_sent'), source = 'client' })
			return say('error', locale('dealership.refused'))
		end
		return publish({ ok = true, queued = true, entry = data.offer, buyer = data.buyer,
			source = 'sell' })
	end

	if current.screen == 'offer' then
		if type(data.decide) ~= 'boolean' then return end
		if data.decide == false or type(offer) ~= 'table' then return Runtime.Decide(false) end
		local kind = offer.kind or (type(zone) == 'table' and zone.kind) or ''
		return push('offerDeliver', { places = placesFor(kind) })
	end

	if current.screen == 'offerDeliver' then
		if data.decide ~= true then return end
		return Runtime.Decide(true, type(data.dest) == 'string' and data.dest or nil)
	end

	if current.screen == 'deliver' then
		-- The destination row is the confirmation: it names the place the
		-- vehicle is filed under, and the price has been on the status line for
		-- as long as the screen has been up.
		return buy(data.entry, type(data.dest) == 'string' and data.dest or nil)
	end
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- Opens the list for the dealer the player is standing on, or closes it.
-- @author XEROX710
-- @param origin string|nil the key or a caller's name
-- @return table
function Runtime.Open(origin)
	local result = { source = origin or 'key' }
	if captured() then
		result.ok, result.error = false, 'error.noPermission'
		publish(result)
		return result
	end

	-- The same key closes what it opened. Asked of this file's own handle rather
	-- than of the menu's state, because the menu is shared: another module's menu
	-- is not this one's to close.
	if handle ~= nil then
		takeDown()
		result.ok, result.closed = true, true
		publish(result)
		return result
	end

	if nearest == nil then
		result.ok, result.error = false, 'dealership.noSuchSpot'
		publish(result)
		return result
	end
	if type(stock[nearest.kind]) ~= 'table' or #stock[nearest.kind] == 0 then
		result.ok, result.error = false, 'dealership.nothingForSale'
		publish(result)
		say('error', locale(result.error))
		return result
	end

	stack = { { screen = 'root' } }
	if not draw() then
		result.ok, result.error = false, 'dealership.noList'
		publish(result)
		return result
	end
	syncPrompt()
	result.ok, result.dealer = true, nearest.key
	publish(result)
	return result
end

--- Opens the salesperson's list for one player the eye picked.
-- @author XEROX710
--
-- EVERY REFUSAL HERE IS LOCAL AND CHANGES NOTHING. The server re-derives that
-- this client is in a zone, that the buyer is in the same one, that the seller
-- has a company to bank into and that the buyer has the money, before it so much
-- as records an offer.
-- @param buyer integer the player id the eye resolved
-- @return table
function Runtime.Sell(buyer)
	local result = { source = 'target' }
	buyer = tonumber(buyer)
	if buyer == nil then
		result.ok, result.error = false, 'error.badRequest'
		publish(result)
		return result
	end
	if zone == nil then
		result.ok, result.error = false, 'dealership.notInZone'
		publish(result)
		say('error', locale(result.error))
		return result
	end
	if type(stock[zone.kind]) ~= 'table' or #stock[zone.kind] == 0 then
		result.ok, result.error = false, 'dealership.nothingForSale'
		publish(result)
		say('error', locale(result.error))
		return result
	end

	takeDown()
	stack = { { screen = 'sell', arg = { buyer = buyer } } }
	if not draw() then
		result.ok, result.error = false, 'dealership.noList'
		publish(result)
		return result
	end
	syncPrompt()
	result.ok, result.buyer = true, buyer
	publish(result)
	return result
end

--- Answers the offer this player was made: yes or no.
-- @author XEROX710
-- @param yes boolean
-- @param destKey string|nil the garage to file it under; the server's default
--   when omitted
-- @return table
function Runtime.Decide(yes, destKey)
	local live = offer
	offer = nil
	takeDown()
	if type(live) ~= 'table' then return { ok = false, error = 'dealership.noOffer' } end
	-- THE OFFER'S OWN NAME GOES BACK WITH THE ANSWER. A second offer replaces
	-- the first, and a confirm already in flight for the first would otherwise
	-- buy the second -- a different car, at a different price, that this player
	-- never saw.
	if type(destKey) ~= 'string' or destKey == '' or yes ~= true then destKey = nil end
	local sent, reason = TriggerServerEvent(M.Event.DECIDE, live.token, yes == true, destKey)
	if not sent then
		publish({ ok = false, error = tostring(reason or 'not_sent'), source = 'client' })
		return { ok = false, error = 'not_sent' }
	end
	publish({ ok = true, queued = true, entry = live.entry, accepted = yes == true,
		source = 'offer' })
	return { ok = true, queued = true }
end

--- Closes the list this file opened.
-- @author XEROX710
-- @return table
function Runtime.Close()
	if not takeDown() then return { ok = false, error = 'not_open' } end
	return { ok = true }
end

--- Whether this file's own list is up.
-- @author XEROX710
-- @return boolean
function Runtime.IsOpen()
	return handle ~= nil
end

--- The dealer the player is standing on, or nil.
-- @author XEROX710
-- @return table|nil
function Runtime.Nearest()
	return nearest
end

--- Every dealer this client was told about, by key.
-- @author XEROX710
-- @return table
function Runtime.Spots()
	return spots
end

--- What this client knows, for a diagnostic or a test.
-- @author XEROX710
-- @return table
function Runtime.Report()
	local count = OPX.Table.Count(spots)
	local drawn = markers.Count()
	local current = stack[#stack]
	return {
		spots = count,
		markers = drawn,
		nearest = nearest and nearest.key or nil,
		shown = shown,
		-- Which kind the row is naming, so a diagnostic can tell a row that never
		-- went up from one that went up naming the other kind.
		label = shownLabel,
		key = keyLabel(),
		open = handle ~= nil,
		screen = current and current.screen or nil,
		-- Which showroom the player is standing IN, as opposed to which counter
		-- they are standing ON: a diagnostic that saw only `nearest` could not
		-- tell an eye with no row from a player who had left the room.
		zone = zone and zone.key or nil,
		selling = zoneRows,
		offered = offer and offer.entry or nil,
		listed = nearest ~= nil and type(stock[nearest.kind]) == 'table'
			and #stock[nearest.kind] or 0,
	}
end

-- ── the zone, and the row it grows on other players ─────────────────────────

-- The one row this module puts on the eye. Registered while the player is inside
-- a dealer's zone and taken off the moment they leave, so a salesperson has it
-- on the showroom floor and nowhere else.
--
-- `distance` is the eye's own reach to the BODY it is pointed at -- how far the
-- ray may travel to find the customer -- and has nothing to do with ZONE_RADIUS,
-- which is how far the SALESPERSON may be from the counter. Three metres is
-- conversation distance, which is what selling a car to somebody is.
local function sellRow()
	return {
		id = 'sell',
		label = locale('dealership.target.sell'),
		icon = 'vehicle',
		distance = 3.0,
		onSelect = function(context)
			local target = type(context) == 'table' and context.target or nil
			local id = type(target) == 'table' and math.tointeger(target.playerId) or nil
			if id == nil or id < 1 then return false end
			local answer = Runtime.Sell(id)
			return answer.ok == true
		end,
	}
end

-- Puts the row on the eye, or takes it off, to match `zone`.
--
-- ON A THREAD OF ITS OWN, WITH A YIELD BEFORE THE REGISTRATION, and that is not
-- decoration: a registration built and submitted inside the resume that also ran
-- a scan pass has been how this codebase lost rows in silence four times --
-- `modules/admin/client/target.lua` `register()` is the worked example and says
-- so at length. The coroutine unwinds with no error and no log, and what is left
-- is an eye that has some of the rows somebody asked for. One row is one batch,
-- so the yield is the whole of the ceremony here.
--
-- Called only when `zone` CHANGES, because `RegisterPlayers` is a whole-registry
-- write for this owner and doing it twice a second would be a write per scan for
-- ever.
local function syncTarget()
	local api = OPX.Api.Get('target')
	if api == nil or type(api.RegisterPlayers) ~= 'function' then
		if zone ~= nil and not reportedTarget then
			reportedTarget = true
			Open77.log.info('[dealership] no target contract: the showroom grows no ' ..
				'"sell a vehicle" row, and the list still sells to whoever opens it')
		end
		return
	end
	local wanted = zone ~= nil
	if wanted == zoneRows then return end
	zoneRows = wanted

	CreateThread(function()
		Wait(0)
		local answer
		if wanted then
			answer = api.RegisterPlayers(OWNER, { sellRow() })
		else
			answer = api.Clear(OWNER)
		end
		if type(answer) ~= 'table' or answer.ok ~= true then
			-- The flag goes back, so the next pass through the zone tries again
			-- rather than believing a row is there that never was.
			zoneRows = not wanted
			if not reportedTarget then
				reportedTarget = true
				Open77.log.warn(('[dealership] the showroom row was refused: %s')
					:format(type(answer) == 'table' and tostring(answer.error) or 'no answer'))
			end
		end
	end)
end

-- ── the scan ────────────────────────────────────────────────────────────────

-- One pass: where the player is, which dealer they are on, whether they are in a
-- showroom at all, and what is drawn.
local function scan()
	local x, y = playerXY()
	if x == nil then
		nearest = nil
		if zone ~= nil then
			zone = nil
			syncTarget()
		end
		syncPrompt()
		return
	end
	nearest, nearestSq = Access.Nearest(spots, x, y)

	-- TWO RADII OVER ONE LIST. `nearest` is standing ON the marker, which is what
	-- buys; `zone` is being IN THE ROOM, which is what sells. The wider read is a
	-- second pass over the same table rather than a second table to keep in step.
	local inside = Access.Nearest(spots, x, y, Access.ZONE_RADIUS_SQ)
	local wasIn = zone ~= nil and zone.key or nil
	zone = inside
	if (inside ~= nil and inside.key or nil) ~= wasIn then syncTarget() end

	syncPrompt()
	markers.Reconcile(spots, x, y)
end

-- ── the placement round-trip ────────────────────────────────────────────────
-- `Runtime.Place` and `Runtime.Unplace` stood here and asked the server to dress
-- or strip a showroom floor. They went with the server path they spoke to: the
-- floor is `PREVIEW.POINTS` in `config/dealership.lua` now, and the one field
-- this half ever contributed -- the operator's own facing, which a chat line has
-- no way of knowing -- is what `/opx.admin.self.pos` reads and copies into the
-- config row.

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears everything this half holds. Never yields.
-- @author XEROX710
function Runtime.Init()
	spots = {}
	markers.Reset()
	stock = { [M.KIND.GARAGE] = {}, [M.KIND.AVPAD] = {} }
	nearest, shown, shownLabel, keyRegistered = nil, false, nil, false
	handle, stack = nil, {}
	offer, offerWaiting, zone, zoneRows = nil, false, nil, false
	reportedStrip, reportedMenu, reportedTarget = false, false, false
	scanJob, askJob = nil, nil
end

--- Declares the key and wires the four server events.
-- @author XEROX710
function Runtime.Start()
	-- The key, and the silent press: see `OPX.Spots.Key.Register`.
	keyRegistered = OPX.Spots.Key.Register({
		tag = 'dealership',
		declared = keySettings(),
		onPress = Runtime.Open,
		-- An open list first, which this key closes; then the dealer it stands at.
		wants = function(x, y)
			if handle ~= nil then return OPX.Spots.Key.Rank('OPEN') end
			if nearest == nil then return nil end
			return OPX.Spots.Key.Rank('SPOT'), OPX.Spots.Key.Reach(nearest, x, y, nearestSq)
		end,
	})

	-- The strip redraws a rebound key itself; this only re-reads whether the row
	-- should be up at all.
	AddEventHandler(OPX.Host.KEYBINDS_CHANGED, function()
		if shown and keyLabel() == nil then shown = false end
		syncPrompt()
	end)

	RegisterNetEvent(M.Event.SYNC, function(payload)
		local listed = type(payload) == 'table' and payload.spots or nil
		if type(listed) ~= 'table' then return end
		local accepted = {}
		for index = 1, #listed do
			local spot, why = Access.FromWire(listed[index])
			if spot == nil then
				Open77.log.warn('[dealership] a dealer was refused: ' .. tostring(why))
			else
				accepted[spot.key] = spot
			end
		end
		spots = accepted

		-- A dealer the player is standing on that has gone takes an open list
		-- down with it: the list is that dealer's, and it is not there any more.
		if nearest ~= nil and spots[nearest.key] == nil and handle ~= nil then
			takeDown()
		end
		-- A full pass, not just the markers: a list that arrives while the
		-- player is standing on a dealer must put its row up now rather than
		-- wait for the next scan.
		scan()
	end)

	RegisterNetEvent(M.Event.STOCK, function(payload)
		local kinds = type(payload) == 'table' and payload.kinds or nil
		if type(kinds) ~= 'table' then return end
		local accepted = { [M.KIND.GARAGE] = {}, [M.KIND.AVPAD] = {} }
		for kind in pairs(accepted) do
			local listed = kinds[kind]
			for index = 1, type(listed) == 'table' and #listed or 0 do
				local row, why = Access.FromWireRow(listed[index])
				if row == nil then
					Open77.log.warn('[dealership] a stock row was refused: ' .. tostring(why))
				else
					accepted[kind][#accepted[kind] + 1] = row
				end
			end
		end
		stock = accepted

		-- An open list is redrawn against the new stock: a row that is sold out
		-- or repriced must not stay on screen as it was.
		if handle ~= nil then draw(true) end
	end)

	RegisterNetEvent(M.Event.ANSWER, function(ok, failure, entry, value)
		local verdict = {
			ok = ok == true,
			error = ok ~= true and tostring(failure or 'dealership.refused') or nil,
			entry = type(entry) == 'string' and entry or nil,
			source = 'server',
		}
		if ok == true and type(value) == 'table' then
			verdict.plate = value.plate
			verdict.model = value.model
			verdict.dealer = value.dealer
			verdict.garage = value.garage
			verdict.price = value.price
		end
		-- NO TOAST FROM HERE. Every refusal that reaches this handler was
		-- already toasted by the server (`OPX.NotifyLocale` beside the ANSWER),
		-- so a second one from here showed each refusal twice.
		publish(verdict)
	end)

	-- THE OFFER A SALESPERSON MADE, and the one screen in this module that the
	-- player did not open themselves. It is a menu and not a toast: a toast
	-- cannot be answered, and the whole point of this round trip is that the
	-- money does not move until the buyer says so.
	RegisterNetEvent(M.Event.OFFERED, function(payload)
		if type(payload) ~= 'table' or type(payload.entry) ~= 'string' then return end
		offer = payload
		-- NOT OVER THE PLAYER'S OWN LIST. A replacement offer may replace the
		-- offer screen; anything else the player opened is theirs, and the offer
		-- waits behind it rather than taking its place under their finger.
		if handle ~= nil and not offerOnScreen() then
			offerWaiting = true
			return say('info', locale('dealership.offerWaiting',
				{ model = tostring(payload.model or '?') }))
		end
		showOffer()
	end)

	-- An offer that ended without this player's answer: it ran out, or the seller
	-- left. The screen asking them to buy comes down -- pressing it only ever
	-- answered `noOffer` -- unless the offer named is one already replaced.
	RegisterNetEvent(M.Event.WITHDRAWN, function(payload)
		if type(payload) ~= 'table' or type(offer) ~= 'table' then return end
		if payload.token ~= offer.token then return end
		offer, offerWaiting = nil, false
		if offerOnScreen() then takeDown() end
		say('error', locale(type(payload.error) == 'string' and payload.error or 'dealership.noOffer'))
		publish({ ok = false, error = payload.error, source = 'offer', withdrawn = true })
	end)

	-- What became of an offer, told to the SELLER. The buyer already knows: they
	-- answered it.
	RegisterNetEvent(M.Event.SETTLED, function(payload)
		if type(payload) ~= 'table' then return end
		local verdict = {
			ok = payload.ok == true,
			error = payload.ok ~= true and tostring(payload.error or 'dealership.refused') or nil,
			entry = type(payload.entry) == 'string' and payload.entry or nil,
			commission = payload.cut,
			banked = payload.company,
			source = 'sale',
		}
		publish(verdict)
		if not verdict.ok then say('error', locale(verdict.error)) end
	end)

	-- Asked now so the first scan has a list, then on the poll so a change of
	-- routing bucket is picked up without a rejoin.
	local function ask()
		local sent, reason = TriggerServerEvent(M.Event.ASK)
		if not sent then
			Open77.log.warn('[dealership] the dealer list could not be asked for: ' .. tostring(reason))
		end
	end
	ask()
	askJob = OPX.Scheduler.Every('dealership:ask', Access.POLL_MS > 0 and Access.POLL_MS or 15000, ask)

	-- A SCAN_MS the config got wrong reads as zero, which the scheduler would
	-- take as every pass. That is a boot error and the scan does not start,
	-- rather than running once a frame.
	if Access.SCAN_MS <= 0 then
		Open77.log.error('[dealership] SCAN_MS is not a whole number of milliseconds above zero; ' ..
			'no marker will be drawn')
		return
	end
	scanJob = OPX.Scheduler.Every('dealership:scan', Access.SCAN_MS, scan)
	-- One pass now, so a dealer already in range does not wait a scan to appear.
	scan()
end

--- Cancels the two jobs, closes the list, takes the markers down and hands the
--- strip back.
-- @author XEROX710
function Runtime.Shutdown()
	if scanJob ~= nil then
		OPX.Scheduler.Cancel(scanJob)
		scanJob = nil
	end
	if askJob ~= nil then
		OPX.Scheduler.Cancel(askJob)
		askJob = nil
	end
	takeDown()
	markers.Clear()
	-- The eye's row goes with everything else. A row left behind by a stopped
	-- owner is a row that opens a list nothing is listening for.
	local eye = OPX.Api.Get('target')
	if zoneRows and eye ~= nil and type(eye.Clear) == 'function' then
		pcall(eye.Clear, OWNER)
	end
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	Runtime.Init()
end
