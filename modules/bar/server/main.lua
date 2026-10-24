--- Server half: the counter, the stash, the supplier, serving, drunk, staff.
-- @author dop42
--
-- EVERY REQUEST ARRIVES THE SAME WAY: the cooldown, a loaded character, the
-- venue named (re-read from the `S` the server built, never from the payload),
-- the gate (jobs or gangs, on duty), the reach -- and only then does anything
-- move. Every answer is a locale key under `bar.` sent to the player who asked.
--
-- THE ORDER OF EVERY MOVE: what is given up goes first (stash ingredients, the
-- buyer's money, the bartender's drink, the customer's money), what is created
-- goes last (the drink, the stock, the customer's drink, the payout), and each
-- partial failure is unwound on the spot. Money events are audited.
--
-- SERVING is the platform's two-player coordinator (`give`, consent on): this
-- file asks, and settles in `onPlayerInteractionCompleted` for ITS OWN
-- interaction ids only -- `modules/animations` and `modules/underworld` hear
-- the same event for theirs.

local M = OPX.Modules.Get('bar')
local Model = M.Model

local S = nil
local character = nil

-- player -> { venue, recipe, citizenId, barId }: the mix running.
local mixing = {}
-- interaction id -> serve; bartender -> interaction id
local serves, serveOf = {}, {}
-- player -> { level, at }
local drunk = {}
local wired = false

local function inventory() return OPX.Api.Get('inventory') end
local function ok(result) return type(result) == 'table' and result.ok == true end

-- ── small reads ─────────────────────────────────────────────────────────────

--- Sends one answer to the player who asked. Never to anybody else.
-- @author dop42
function M.Answer(player, success, code, params)
	if type(player) ~= 'number' or player <= 0 then return success end
	TriggerClientEvent(M.Event.ANSWER, player, { ok = success == true, code = code, params = params })
	return success
end
local answer = M.Answer

local function dataOf(player)
	if character == nil or player == nil then return nil end
	local read, loaded = pcall(character.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	if type(loaded.PlayerData.citizenId) ~= 'string' then return nil end
	return loaded.PlayerData
end

local function pointOf(player)
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y), OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end

local function apart(a, b)
	if a == nil or b == nil or (a.bucket or 0) ~= (b.bucket or 0) then return math.huge end
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function down(player) return OPX.Life ~= nil and OPX.Life.Down(player) == true end

local function playerOf(value)
	local id = math.tointeger(tonumber(value))
	if id == nil or id <= 0 or id > 2147483647 then return nil end
	return id
end

local function venueOf(id)
	if type(id) ~= 'string' or #id > Model.ID_MAX then return nil end
	return S.venues[id]
end

local function itemLabel(name)
	local item = S.items[name]
	return item ~= nil and item.label or tostring(name)
end

-- ── the gate ────────────────────────────────────────────────────────────────

local function snapshotOf(data)
	return { job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		gang = type(data.gang) == 'table' and data.gang or nil,
		gangs = type(data.gangs) == 'table' and data.gangs or nil,
		atMs = OPX.Now() }
end

--- The character's grade at a venue: the best of its jobs and gangs they hold.
local function gradeAt(venue, data)
	local best = nil
	local function consider(list, held, memberships)
		if list == nil then return end
		for name in pairs(list) do
			local level = nil
			if type(held) == 'table' and held.name == name then
				level = type(held.grade) == 'table' and OPX.Math.Finite(held.grade.level) or 0
			elseif S.membership == 'any' and type(memberships) == 'table' then
				level = OPX.Math.Finite(memberships[name])
			end
			if level ~= nil and (best == nil or level > best) then best = level end
		end
	end
	consider(venue.jobs, data.job, data.jobs)
	consider(venue.gangs, data.gang, data.gangs)
	return best
end

--- Whether a character may work a venue, and at least at a grade.
-- @author dop42
-- @return boolean, string|nil code
function M.Allowed(venue, data, minimumGrade)
	if data == nil then return false, 'no_character' end
	local passed, code = OPX.JobGate.EvaluateGroups({ jobs = venue.jobs, gangs = venue.gangs, onDuty = venue.onDuty },
		snapshotOf(data), OPX.Now(), { maxAgeMs = S.jobMaxAgeMs, membership = S.membership })
	if not passed then return false, code or 'job_required' end
	if minimumGrade ~= nil and (gradeAt(venue, data) or 0) < minimumGrade then return false, 'grade_too_low' end
	return true, nil
end

--- Why a player cannot act at a point of a venue now, or nil.
local function standing(player, venue, spot, reach)
	if down(player) then return 'player_down' end
	if spot == nil then return 'unavailable' end
	local at = pointOf(player)
	if at == nil then return 'no_position' end
	if apart(at, { x = spot.x, y = spot.y, z = spot.z, bucket = venue.bucket })
		> OPX.Spots.ServerReach(reach or S.reach) then
		return 'too_far'
	end
	return nil
end

--- Revalidates a captured actor after inventory reads and save fences yield.
local function authority(player, data, session, venue, spot, minimumGrade)
	if dataOf(player) ~= data or OPX.Sessions[player] ~= session then return 'left' end
	local allowed, why = M.Allowed(venue, data, minimumGrade)
	if not allowed then return why end
	return standing(player, venue, spot)
end

--- The venue a bartender works and stands in, for serving, or nil and a code.
local function venueServedFrom(player, data)
	local at = pointOf(player)
	if at == nil then return nil, 'no_position' end
	local worst = 'not_at_venue'
	for _, venue in ipairs(S.venueList) do
		local spot = venue.counter
		if apart(at, { x = spot.x, y = spot.y, z = spot.z, bucket = venue.bucket }) <= S.serveRadius then
			local passed, code = M.Allowed(venue, data)
			if passed then return venue end
			worst = code or worst
		end
	end
	return nil, worst
end

-- ── stock ───────────────────────────────────────────────────────────────────

local function stockOf(venue, item)
	local read, counted = pcall(inventory().CountInStash, venue.stash.name, item)
	return read and ok(counted) and (math.tointeger(counted.value) or 0) or 0
end

local function haveFor(venue, recipe)
	local have = {}
	for _, input in ipairs(recipe.inputs) do have[input.item] = stockOf(venue, input.item) end
	return have
end

local function bagCount(player, item)
	local read, counted = pcall(inventory().GetItemCount, player, item)
	return read and ok(counted) and (math.tointeger(counted.value) or 0) or 0
end

local function onMenu(venue, key)
	for _, entry in ipairs(venue.menu) do
		if entry == key then return S.recipes[key] end
	end
	return nil
end

-- ── the counter ─────────────────────────────────────────────────────────────

--- Sends the counter's screen: each recipe, what it takes and what is in stock.
-- @author dop42
function M.Counter(player, venueId)
	if OPX.Cooling(player, 'bar.counter', S.requestMs) then return answer(player, false, 'too_fast'), 'too_fast' end
	local venue = venueOf(venueId)
	if venue == nil then return answer(player, false, 'no_venue'), 'no_venue' end
	local passed, code = M.Allowed(venue, dataOf(player))
	if not passed then return answer(player, false, code), code end
	local why = standing(player, venue, venue.counter)
	if why ~= nil then return answer(player, false, why), why end
	local rows = {}
	for _, key in ipairs(venue.menu) do
		local recipe = S.recipes[key]
		local have = haveFor(venue, recipe)
		local inputs = {}
		for _, input in ipairs(recipe.inputs) do
			inputs[#inputs + 1] = { label = itemLabel(input.item), need = input.count, have = have[input.item] or 0 }
		end
		rows[#rows + 1] = { key = key, label = itemLabel(recipe.item), count = recipe.count, ms = recipe.ms,
			price = venue.prices[recipe.item], inputs = inputs, ready = #Model.Missing(recipe, have) == 0 }
	end
	TriggerClientEvent(M.Event.VIEW, player, { kind = 'counter', venue = venue.id, label = venue.label, rows = rows })
	return true, rows
end

local settleMix

--- Starts a mix: checks, then a bar the server times; nothing moves until it ends.
-- @author dop42
-- @return boolean, string code
function M.Mix(player, venueId, key)
	if OPX.Cooling(player, 'bar.mix', S.requestMs) then return answer(player, false, 'too_fast'), 'too_fast' end
	if mixing[player] ~= nil then return answer(player, false, 'busy'), 'busy' end
	local venue = venueOf(venueId)
	if venue == nil then return answer(player, false, 'no_venue'), 'no_venue' end
	local recipe = type(key) == 'string' and onMenu(venue, key) or nil
	if recipe == nil then return answer(player, false, 'no_recipe'), 'no_recipe' end
	local data = dataOf(player)
	local passed, code = M.Allowed(venue, data)
	if not passed then return answer(player, false, code), code end
	local why = standing(player, venue, venue.counter)
	if why ~= nil then return answer(player, false, why), why end
	if #Model.Missing(recipe, haveFor(venue, recipe)) > 0 then return answer(player, false, 'short'), 'short' end
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then return answer(player, false, 'no_bar'), 'no_bar' end
	-- Claimed before the bar call: a second request in the same frame is busy.
	local op = { venue = venue.id, recipe = recipe.key, citizenId = data.citizenId, player = player,
		data = data, session = OPX.EnsureSession(player) }
	mixing[player] = op
	local started = progress.Start(player, M.OWNER, {
		label = locale('bar.bar.mix', { item = itemLabel(recipe.item) }),
		durationMs = recipe.ms, cancelable = true,
		animation = S.animation ~= nil and { name = S.animation } or nil,
	}, function(_, outcome)
		CreateThread(function() settleMix(op, outcome) end)
	end)
	if not ok(started) then
		if mixing[player] == op then mixing[player] = nil end
		local busy = type(started) == 'table' and started.error == 'progress_busy'
		return answer(player, false, busy and 'busy' or 'no_bar'), busy and 'busy' or 'no_bar'
	end
	op.barId = type(started.value) == 'table' and started.value.id or nil
	return answer(player, true, 'mixing', { item = itemLabel(recipe.item) }), 'mixing'
end

--- Ends a mix: revalidates, then takes the ingredients and makes the drink.
settleMix = function(op, outcome)
	local player = op.player
	if mixing[player] ~= op then return false end
	mixing[player] = nil
	if type(outcome) ~= 'table' or outcome.completed ~= true then
		return answer(player, false, 'mix_cancelled'), 'mix_cancelled'
	end
	local venue, recipe = S.venues[op.venue], S.recipes[op.recipe]
	local data = dataOf(player)
	if venue == nil or recipe == nil or data == nil or data.citizenId ~= op.citizenId then return false, 'left' end
	local passed, code = M.Allowed(venue, data)
	if not passed then return answer(player, false, code), code end
	local why = standing(player, venue, venue.counter)
	if why ~= nil then return answer(player, false, why), why end

	local api = inventory()
	if not api or type(api.AtomicTrade) ~= 'function' then return answer(player, false, 'unavailable'), 'unavailable' end
	local fits = api.CanCarry and api.CanCarry(op.citizenId, recipe.item, recipe.count)
	local where = ok(fits) and fits.value == true and 'bag' or 'stash'
	local function mix()
		local changes = {}
		for _, input in ipairs(recipe.inputs) do
			changes[#changes + 1] = { name = input.item, count = -input.count, stash = venue.stash.name }
		end
		changes[#changes + 1] = { name = recipe.item, count = recipe.count, stash = where == 'stash' and venue.stash.name or nil }
		return api.AtomicTrade(op.citizenId, S.money, 0, changes, 'bar:mix:' .. venue.id .. ':' .. recipe.key, nil, function(context)
			local why = authority(player, op.data, op.session, venue, venue.counter)
			if why then return nil, why end
			context.publish = function()
				OPX.Publish(M.Event.ON_MIXED, player, { citizenId = op.citizenId, venue = venue.id, recipe = recipe.key,
					item = recipe.item, count = recipe.count, where = where })
				local live = dataOf(player)
				if live and live.citizenId == op.citizenId then
					answer(player, true, where == 'stash' and 'mixed_to_stash' or 'mixed', { item = itemLabel(recipe.item), count = recipe.count })
				end
			end
			return function() return {} end
		end)
	end
	local made = mix()
	if not made.ok and where == 'bag' and (made.error == 'no_room' or made.error == 'too_heavy') then where = 'stash'; made = mix() end
	if not made.ok then
		if made.error == 'left' then return false, 'left' end
		local code = made.error == 'money.pending' and 'payment_pending' or made.error == 'not_enough' and 'short'
			or OPX.Locale.Exists('bar.error.' .. tostring(made.error)) and made.error or 'no_room'
		return answer(player, false, code), code
	end
	return true, where == 'stash' and 'mixed_to_stash' or 'mixed'

end

-- ── the stash and the supplier ──────────────────────────────────────────────

--- Opens a venue's stash beside the staff member's bag.
-- @author dop42
function M.OpenStash(player, venueId)
	if OPX.Cooling(player, 'bar.stash', S.requestMs) then return answer(player, false, 'too_fast'), 'too_fast' end
	local venue = venueOf(venueId)
	if venue == nil then return answer(player, false, 'no_venue'), 'no_venue' end
	local passed, code = M.Allowed(venue, dataOf(player))
	if not passed then return answer(player, false, code), code end
	local stash = venue.stash
	local opened = inventory().OpenStash(player, stash.name, { slots = stash.slots, maxWeight = stash.maxWeight,
		label = stash.label, position = { x = stash.x, y = stash.y, z = stash.z }, bucket = venue.bucket })
	if not ok(opened) then
		local why = type(opened) == 'table' and tostring(opened.error) or 'unavailable'
		if not OPX.Locale.Exists('bar.error.' .. why) then why = 'unavailable' end
		return answer(player, false, why), why
	end
	OPX.Audit.Log({ event = 'bar.stash', source = player, message = stash.name, data = { venue = venue.id } })
	return true
end

local function accounts()
	local api = OPX.Api.Get('accounts')
	return api ~= nil and type(api.Deposit) == 'function' and type(api.Withdraw) == 'function' and api or nil
end

local function fundsFor(venue)
	if S.funds == 'account' and venue.account ~= nil and accounts() ~= nil then return 'account' end
	return 'personal'
end

--- Sends the supplier's catalogue.
-- @author dop42
function M.SupplyView(player, venueId)
	if OPX.Cooling(player, 'bar.supply', S.requestMs) then return answer(player, false, 'too_fast'), 'too_fast' end
	local venue = venueOf(venueId)
	if venue == nil or venue.supply == nil then return answer(player, false, 'no_supply'), 'no_supply' end
	local passed, code = M.Allowed(venue, dataOf(player), venue.supplyGrade)
	if not passed then return answer(player, false, code), code end
	local why = standing(player, venue, venue.supply)
	if why ~= nil then return answer(player, false, why), why end
	local rows = {}
	for _, row in ipairs(venue.supply.catalog) do
		rows[#rows + 1] = { index = row.index, label = itemLabel(row.item), price = row.price, count = row.count,
			stock = stockOf(venue, row.item) }
	end
	TriggerClientEvent(M.Event.VIEW, player, { kind = 'supply', venue = venue.id, label = venue.label,
		funds = fundsFor(venue), rows = rows })
	return true, rows
end

--- Buys one catalogue row into the venue stash: money first, stock second.
-- @author dop42
function M.Buy(player, venueId, index)
	if OPX.Cooling(player, 'bar.buy', S.requestMs) then return answer(player, false, 'too_fast'), 'too_fast' end
	local venue = venueOf(venueId)
	if venue == nil or venue.supply == nil then return answer(player, false, 'no_supply'), 'no_supply' end
	index = math.tointeger(tonumber(index))
	local row
	for _, entry in ipairs(venue.supply.catalog) do
		if entry.index == index then row = entry end
	end
	if row == nil then return answer(player, false, 'bad_request'), 'bad_request' end
	local data = dataOf(player)
	local session = OPX.EnsureSession(player)
	local passed, code = M.Allowed(venue, data, venue.supplyGrade)
	if not passed then return answer(player, false, code), code end
	local why = standing(player, venue, venue.supply)
	if why ~= nil then return answer(player, false, why), why end

	local reason = ('bar:supply:%s:%s'):format(venue.id, row.item)
	local funds, api = fundsFor(venue), inventory()
	if not api or type(api.AtomicTrade) ~= 'function' then return answer(player, false, 'unavailable'), 'unavailable' end
	local bought = api.AtomicTrade(data.citizenId, 'BANK', funds == 'account' and 0 or -row.price,
		{ { name = row.item, count = row.count, stash = venue.stash.name } }, reason, nil, function(op)
			local why = authority(player, data, session, venue, venue.supply, venue.supplyGrade)
			if why then return nil, why end
			local builder
			if row.price > 0 and funds == 'account' then
				local treasury = accounts()
				if not treasury or type(treasury.PrepareTrade) ~= 'function' then return nil, 'error.unavailable' end
				local why
				builder, why = treasury.PrepareTrade(op, venue.account.kind, venue.account.key, row.price, false)
				if not builder then return nil, why end
			end
			op.publish = function()
				OPX.Audit.Log({ event = 'bar.supply', source = player, citizenId = data.citizenId,
					message = ('%dx %s for %d into %s (%s)'):format(row.count, row.item, row.price, venue.stash.name, funds),
					data = { venue = venue.id, item = row.item, count = row.count, price = row.price, funds = funds } })
				OPX.Publish(M.Event.ON_BOUGHT, player, { citizenId = data.citizenId, venue = venue.id, item = row.item, count = row.count, price = row.price })
				local live = dataOf(player)
				if live and live.citizenId == data.citizenId then answer(player, true, 'bought', { item = itemLabel(row.item), count = row.count, price = row.price }) end
			end
			return builder or function() return {} end
		end)
	if not bought.ok then
		if bought.error == 'left' then return false, 'left' end
		local code = bought.error == 'money.pending' and 'payment_pending' or bought.error == 'insufficient_funds' and 'venue_broke'
			or bought.error == 'money.insufficient' and 'not_enough_money'
			or OPX.Locale.Exists('bar.error.' .. tostring(bought.error)) and bought.error or 'stash_full'
		return answer(player, false, code), code
	end
	return true, 'bought'

end

-- ── serving ─────────────────────────────────────────────────────────────────

local function coordinator()
	local native = Open77.playerInteractions
	return type(native) == 'table' and type(native.request) == 'function' and native or nil
end

--- Checks a bartender, a customer and a venue for a serve. Never yields.
local function serveContext(player, target)
	target = playerOf(target)
	if target == nil or target == player then return nil, 'no_customer' end
	local data = dataOf(player)
	if data == nil then return nil, 'no_character' end
	local customer = dataOf(target)
	if customer == nil then return nil, 'no_customer' end
	if down(player) or down(target) then return nil, 'player_down' end
	local venue, code = venueServedFrom(player, data)
	if venue == nil then return nil, code end
	if apart(pointOf(player), pointOf(target)) > OPX.Spots.ServerReach(S.serveReach) then return nil, 'too_far' end
	return { venue = venue, target = target, data = data, customer = customer }
end

--- What a bartender may serve the customer in front of them.
-- @author dop42
function M.ServeMenu(player, target)
	if OPX.Cooling(player, 'bar.serveMenu', S.requestMs) then return answer(player, false, 'too_fast'), 'too_fast' end
	local context, code = serveContext(player, target)
	if context == nil then return answer(player, false, code), code end
	local venue, rows = context.venue, {}
	for _, item in ipairs(venue.sells) do
		local held = bagCount(player, item)
		if held > 0 then
			rows[#rows + 1] = { item = item, label = itemLabel(item), price = venue.prices[item], held = held }
		end
	end
	if #rows == 0 then return answer(player, false, 'nothing_to_serve'), 'nothing_to_serve' end
	TriggerClientEvent(M.Event.VIEW, player, { kind = 'serve', venue = venue.id, label = venue.label,
		target = context.target, rows = rows })
	return true, rows
end

--- Offers one drink to the customer: the coordinator's `give`, with consent.
-- @author dop42
function M.Serve(player, target, item)
	if OPX.Cooling(player, 'bar.serve', S.requestMs) then return answer(player, false, 'too_fast'), 'too_fast' end
	if serveOf[player] ~= nil then return answer(player, false, 'busy'), 'busy' end
	local context, code = serveContext(player, target)
	if context == nil then return answer(player, false, code), code end
	local venue = context.venue
	local price = type(item) == 'string' and venue.prices[item] or nil
	if price == nil then return answer(player, false, 'not_on_menu'), 'not_on_menu' end
	if bagCount(player, item) < 1 then return answer(player, false, 'not_enough_items'), 'not_enough_items' end
	local native = coordinator()
	if native == nil then return answer(player, false, 'unavailable'), 'unavailable' end
	local called, state, why = pcall(native.request, player, context.target, 'give', {
		durationMs = S.serve.durationMs, inviteTimeoutMs = S.serve.inviteMs,
		startDistance = S.serve.startDistance, breakDistance = S.serve.breakDistance, consent = true,
	})
	if not called or type(state) ~= 'table' or type(state.id) ~= 'string' then
		Open77.log.debug('[bar] a serve was refused by the coordinator: ' .. tostring(called and why or state))
		return answer(player, false, 'serve_refused'), 'serve_refused'
	end
	serves[state.id] = { id = state.id, bartender = player, customer = context.target,
		bartenderCid = context.data.citizenId, customerCid = context.customer.citizenId,
		bartenderSession = OPX.EnsureSession(player), customerSession = OPX.EnsureSession(context.target),
		bartenderData = context.data, customerData = context.customer,
		venue = venue.id, item = item, price = price, at = OPX.Now() }
	serveOf[player] = state.id
	local params = { item = itemLabel(item), price = price, venue = venue.label }
	answer(context.target, true, 'serve_invited', params)
	return answer(player, true, 'serve_offered', params), 'serve_offered'
end

local function invoices()
	local api = OPX.Api.Get('invoices')
	return api ~= nil and type(api.Issue) == 'function' and api or nil
end

--- The swap, once the hand-over completed. Yields.
-- @author dop42
function M.Complete(id)
	local serve = serves[id]
	serves[id] = nil
	if serve == nil then return false end
	if serveOf[serve.bartender] == id then serveOf[serve.bartender] = nil end
	local bartender, customer = dataOf(serve.bartender), dataOf(serve.customer)
	local venue = S.venues[serve.venue]
	if bartender == nil or customer == nil or venue == nil or bartender ~= serve.bartenderData or customer ~= serve.customerData or bartender.citizenId ~= serve.bartenderCid
		or customer.citizenId ~= serve.customerCid or OPX.Sessions[serve.bartender] ~= serve.bartenderSession
		or OPX.Sessions[serve.customer] ~= serve.customerSession then
		return false, 'left'
	end
	local passed, code = M.Allowed(venue, bartender)
	if not passed then return answer(serve.bartender, false, code), code end

	local params = { item = itemLabel(serve.item), price = serve.price, venue = venue.label }
	local api, prepared = invoices(), nil
	local useInvoice = serve.price > 0 and api ~= nil and S.billing ~= 'direct'
	if useInvoice then
		if type(api.PrepareServiceBill) ~= 'function' then return answer(serve.bartender, false, 'unavailable'), 'unavailable' end
		local bill = api.PrepareServiceBill({ issuer = serve.bartender, target = serve.customer, amount = serve.price,
			reason = ('%s - %s'):format(venue.label, itemLabel(serve.item)),
			account = venue.account ~= nil and { kind = venue.account.kind, key = venue.account.key } or nil,
			cutPct = S.staffCut, source = 'bar' })
		if bill.ok then prepared = bill.value
		elseif S.billing == 'auto' then useInvoice = false
		else return answer(serve.bartender, false, 'unavailable'), 'unavailable' end
	end
	local staff, house = Model.Split(serve.price, S.staffCut)
	local treasury = accounts()
	if not treasury or not venue.account then staff, house = serve.price, 0 end
	local billing = useInvoice and 'invoice' or serve.price > 0 and 'direct' or 'free'
	local inv = inventory()
	if not inv or type(inv.AtomicPeerTrade) ~= 'function' then return answer(serve.bartender, false, 'unavailable'), 'unavailable' end
	local traded = inv.AtomicPeerTrade(serve.bartenderCid, serve.customerCid, S.money, useInvoice and 0 or serve.price,
		{ { name = serve.item, count = 1 } }, 'bar:' .. venue.id .. ':' .. serve.item, 'bar:' .. serve.id,
		{ credit = useInvoice and 0 or staff, participant = function(op)
			local why = authority(serve.bartender, bartender, serve.bartenderSession, venue, venue.counter)
			if why then return nil, why end
			if bartender.citizenId ~= serve.bartenderCid or customer.citizenId ~= serve.customerCid
				or dataOf(serve.customer) ~= customer or OPX.Sessions[serve.customer] ~= serve.customerSession then return nil, 'left' end
			if down(serve.customer) then return nil, 'player_down' end
			if apart(pointOf(serve.bartender), pointOf(serve.customer)) > OPX.Spots.ServerReach(S.serve.breakDistance) then return nil, 'too_far' end
			local extraBuild
			if prepared then extraBuild, why = prepared.Participant(op)
			elseif house > 0 then
				if type(treasury.PrepareTrade) ~= 'function' then return nil, 'error.unavailable' end
				extraBuild, why = treasury.PrepareTrade(op, venue.account.kind, venue.account.key, house, true)
			end
			if why then return nil, why end
			local publish = op.publish
			op.publish = function()
				if publish then pcall(publish) end
				local invoiceId = prepared and prepared.id
				OPX.Audit.Log({ event = 'bar.serve', source = serve.bartender, citizenId = serve.bartenderCid,
					message = ('%s to %s for %d (%s)'):format(serve.item, serve.customerCid, serve.price, billing),
					data = { venue = venue.id, item = serve.item, price = serve.price, billing = billing,
						staff = useInvoice and 0 or staff, house = useInvoice and 0 or house, invoice = invoiceId } })
				OPX.Publish(M.Event.ON_SERVED, serve.bartender, { venue = venue.id, item = serve.item, price = serve.price,
					bartender = serve.bartenderCid, customer = serve.customerCid, billing = billing, invoice = invoiceId })
				local b, c = dataOf(serve.bartender), dataOf(serve.customer)
				if c and c.citizenId == serve.customerCid then answer(serve.customer, true, useInvoice and 'received_invoiced' or 'received', params) end
				if b and b.citizenId == serve.bartenderCid then answer(serve.bartender, true,
					useInvoice and 'served_invoiced' or billing == 'free' and 'served_free' or 'served', params) end
			end
			return extraBuild or function() return {} end
		end })
	if not traded.ok then
		if traded.error == 'left' then return false, 'left' end
		local code = traded.error == 'money.pending' and 'payment_pending' or traded.error == 'money.insufficient' and 'customer_short'
			or traded.error == 'not_enough' and 'not_enough_items'
			or OPX.Locale.Exists('bar.error.' .. tostring(traded.error)) and traded.error or 'serve_failed'
		answer(serve.customer, false, code == 'customer_short' and 'not_enough_money' or code, params)
		return answer(serve.bartender, false, code, params), code
	end
	return true, useInvoice and 'served_invoiced' or billing == 'free' and 'served_free' or 'served'

end

local function onCompleted(state)
	if type(state) ~= 'table' or type(state.id) ~= 'string' or serves[state.id] == nil then return end
	CreateThread(function() M.Complete(state.id) end)
end

local function onCancelled(state)
	if type(state) ~= 'table' or type(state.id) ~= 'string' then return end
	local serve = serves[state.id]
	if serve == nil then return end
	serves[state.id] = nil
	if serveOf[serve.bartender] == state.id then serveOf[serve.bartender] = nil end
	answer(serve.bartender, false, 'serve_cancelled')
end

-- ── drunk ───────────────────────────────────────────────────────────────────

--- A player's drunk level now.
-- @author dop42
function M.DrunkLevel(player)
	local held = drunk[player]
	if held == nil then return 0 end
	return Model.Sober(held.level, OPX.Now() - held.at, S.drunk.decayPerMinute)
end

--- Adds a drink's alcohol and plays the screen effect on the drinker alone.
-- @author dop42
-- @return number the new level
function M.Drink(player, alcohol)
	local level = M.DrunkLevel(player) + alcohol
	drunk[player] = { level = level, at = OPX.Now() }
	local strength, seconds = Model.Effect(S.drunk, level)
	local effects = Open77.effects
	if S.drunk.effect ~= nil and seconds > 0 and type(effects) == 'table' and type(effects.screen) == 'function' then
		local called, played, why = pcall(effects.screen, player, S.drunk.effect,
			{ strength = strength, duration = seconds })
		if not called or played ~= true then
			Open77.log.debug(('[bar] the drunk screen was refused: %s'):format(tostring(called and why or played)))
		end
	end
	if level >= S.drunk.fullAt then answer(player, false, 'wasted') end
	return level
end

local function onUsed(source, payload)
	local player = playerOf(source)
	local name = type(payload) == 'table' and payload.name or nil
	local item = type(name) == 'string' and S.items[name] or nil
	if player == nil or item == nil or item.alcohol <= 0 then return end
	M.Drink(player, item.alcohol)
end

-- ── staff ───────────────────────────────────────────────────────────────────

local function report(source)
	local lines = {}
	for _, venue in ipairs(S.venueList) do
		lines[#lines + 1] = ('%s "%s" menu=%d supply=%s stash=%s account=%s'):format(venue.id, venue.label,
			#venue.menu, venue.supply and (#venue.supply.catalog .. ' rows') or '-', venue.stash.name,
			venue.account and (venue.account.kind .. ':' .. venue.account.key) or '-')
	end
	for _, key in ipairs(S.placeholders) do lines[#lines + 1] = key .. ' DISABLED: not surveyed yet (0,0,0)' end
	for _, line in ipairs(S.problems) do lines[#lines + 1] = 'REFUSED: ' .. line end
	lines[#lines + 1] = ('%d venue(s) open, %d item(s), %d recipe(s); billing %s (invoices %s, accounts %s)')
		:format(#S.venueList, #S.itemList, #S.recipeList, S.billing, invoices() and 'on' or 'off',
			accounts() and 'on' or 'off')
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Reads the config. Never yields.
-- @author dop42
function M.Init()
	mixing, serves, serveOf, drunk = {}, {}, {}, {}
	S = Model.Read(M.Settings)
	M.S = S
end

--- Publishes the read side.
-- @author dop42
function M.Api()
	OPX.Api.Provide('bar', 1, {
		Venues = function() return S.venueList end,
		Items = function() return S.itemList end,
		DrunkLevel = M.DrunkLevel,
	})
end

--- Registers the items, then the doors. On a coroutine.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	for _, line in ipairs(S.problems) do Open77.log.warn('[bar] config: ' .. line) end
	if #S.placeholders > 0 then
		Open77.log.info(('[bar] disabled until surveyed (0,0,0): %s'):format(table.concat(S.placeholders, ', ')))
	end
	local api = inventory()
	if character == nil or api == nil then
		Open77.log.error('[bar] no character or inventory contract: no venue opens')
		return
	end
	-- Every item, whether a venue is open or not: a drink outlives the bar it
	-- came from, and a stack already in a bag waits for its registration.
	for _, item in ipairs(S.itemList) do
		local registered = api.RegisterItem(item.name, Model.Definition(item), M.OWNER, 64)
		if not ok(registered) then
			local why = type(registered) == 'table' and registered.error or registered
			local log = why == 'item_taken' and Open77.log.debug or Open77.log.warn
			log(('[bar] the item %s was not registered: %s'):format(item.name, tostring(why)))
		end
	end
	if OPX.Api.Get('invoices') == nil then
		Open77.log.info('[bar] no invoices contract: customers are charged at the hand-over')
	end
	if OPX.Api.Get('accounts') == nil then
		Open77.log.info('[bar] no accounts contract: the house share goes to the bartender, stock is paid from BANK')
	end

	if not wired then
		wired = true
		local function door(event, fn, check)
			RegisterNetEvent(event, function(a, b)
				local player = playerOf(source)
				if player == nil or not check(a, b) then return end
				local user, session = OPX.UserIdOf(player), OPX.Sessions[player]
				local data = dataOf(player)
				local citizenId = data and data.citizenId
				CreateThread(function()
					local current = dataOf(player)
					if user == nil or citizenId == nil or OPX.UserIdOf(player) ~= user or
						OPX.Sessions[player] ~= session or current == nil or current.citizenId ~= citizenId then return end
					fn(player, a, b)
				end)
			end)
		end
		local function venueArg(a) return type(a) == 'string' and #a <= Model.ID_MAX end
		door(M.Event.COUNTER, M.Counter, venueArg)
		door(M.Event.MIX, M.Mix, function(a, b) return venueArg(a) and type(b) == 'string' and #b <= 48 end)
		door(M.Event.STASH, M.OpenStash, venueArg)
		door(M.Event.SUPPLY, M.SupplyView, venueArg)
		door(M.Event.BUY, M.Buy, function(a, b) return venueArg(a) and math.type(b) == 'integer' end)
		door(M.Event.SERVE_MENU, M.ServeMenu, function(a) return math.type(a) == 'integer' end)
		door(M.Event.SERVE, M.Serve, function(a, b) return math.type(a) == 'integer' and type(b) == 'string'
			and #b <= 48 end)
		AddEventHandler('onPlayerInteractionCompleted', onCompleted)
		AddEventHandler('onPlayerInteractionCancelled', onCancelled)
		AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'inventory', 'used'), onUsed)
		AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(raw)
			local player = playerOf(raw)
			if player == nil then return end
			drunk[player] = nil
			mixing[player] = nil
		end)
		OPX.Command.Register(M.Command.VENUES, { restricted = true, help = 'bar.help.venues' },
			function(source) report(source) end)
	end
	Open77.log.info(('[bar] ready: %d venue(s), %d item(s), %d recipe(s)'):format(#S.venueList, #S.itemList,
		#S.recipeList))
end

--- Cancels the serves in flight; a running mix ends with its bar.
-- @author dop42
function M.Stop()
	local native = coordinator()
	for id in pairs(serves) do
		if native ~= nil and type(native.cancel) == 'function' then pcall(native.cancel, id, 'resource_stopping') end
	end
	serves, serveOf, mixing = {}, {}, {}
end
