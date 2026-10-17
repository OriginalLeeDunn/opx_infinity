--- Server half, the chemistry: the items, the labs and their heat, taking a
--- drug, and a street deal between two players.
-- @author dop42
--
-- THE ITEMS ARE REGISTERED HERE, at start, through the inventory's
-- `RegisterItem` -- before the labs, because the crafting module checks every
-- recipe's names against the catalogue when a bench is registered and drops the
-- ones it does not know.
--
-- A LAB IS A CRAFTING BENCH and nothing more on the order side: the crafting
-- module already takes the materials first, files the order with a database
-- clock and hands it over once. What this file adds is the gate (the gang) and
-- the HEAT, read off the crafting module's public `ordered` event.
--
-- A DRUG is an inventory use handler: it runs with the slot held, the effect
-- lands, and the unit is consumed by the inventory after it (`consume = 1`).
--
-- A STREET DEAL is the platform's two-player coordinator (`give`, with its own
-- consent): this file only asks, and does the swap in `onPlayerInteraction
-- Completed` -- for ITS OWN interaction ids, because `modules/animations` hears
-- the same event for its emotes. The swap takes from both sides first and gives
-- to both sides after, and every partial failure is unwound.

local M = OPX.Modules.Get('underworld')
local Model = M.Model
local Storage = M.Storage
local Op = M.Op

M.Drugs = {}
local Drugs = M.Drugs

-- lab id -> heat 0..100
local heat = {}
-- player -> last drug use instant
local lastUse = {}
-- interaction id -> deal; actor -> interaction id
local deals, dealOf = {}, {}
local benches = {}
local jobs = {}
local wired = false

local function settings() return M.Settings end
local function inventory() return OPX.Api.Get('inventory') end
local function character() return OPX.Api.Get('character') end
local function built() return M.Built end

-- ── items ───────────────────────────────────────────────────────────────────

--- Registers every item of the config that the catalogue does not carry yet.
-- @author dop42
function Drugs.RegisterItems()
	local api = inventory()
	if api == nil or type(api.RegisterItem) ~= 'function' then return end
	local items = type(settings().ITEMS) == 'table' and settings().ITEMS or {}
	local names = {}
	for name in pairs(items) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local definition = type(items[name]) == 'table' and OPX.Table.DeepCopy(items[name]) or {}
		-- A drug is a use the server decides: the inventory consumes it after
		-- the handler answers.
		if built().drugs[name] ~= nil then definition.use = { consume = 1, close = true } end
		local registered = api.RegisterItem(name, definition, M.OWNER, 32)
		local why = type(registered) == 'table' and registered.error or registered
		if type(registered) ~= 'table' or not registered.ok then
			-- `item_taken`: config/inventory.lua carries it, and that row wins.
			local log = why == 'item_taken' and Open77.log.debug or Open77.log.warn
			log(('[underworld] the item %s was not registered: %s'):format(name, tostring(why)))
		end
	end
end

-- ── taking a drug ───────────────────────────────────────────────────────────

local function addiction()
	return type(settings().ADDICTION) == 'table' and settings().ADDICTION or {}
end

--- A character's addiction level now. Never yields.
-- @author dop42
function Drugs.Level(player)
	local api = character()
	if api == nil or type(api.GetMetadata) ~= 'function' then return 0 end
	local key = type(addiction().METADATA_KEY) == 'string' and addiction().METADATA_KEY or 'underworld_addiction'
	local read, value = pcall(api.GetMetadata, player, key)
	if not read or type(value) ~= 'table' then return 0 end
	-- The instant is this process's clock: a level written before a restart
	-- reads as written just now, and decays from there.
	local at = tonumber(value.at)
	if at == nil or at > OPX.Now() then at = OPX.Now() end
	return Model.Decay(value.level, at / 1000, OPX.Now() / 1000,
		Model.Bounded(addiction().DECAY_PER_HOUR, 0, 1000, 2))
end

local function setLevel(player, level)
	local api = character()
	if api == nil or type(api.SetMetadata) ~= 'function' then return end
	local key = type(addiction().METADATA_KEY) == 'string' and addiction().METADATA_KEY or 'underworld_addiction'
	pcall(api.SetMetadata, player, key, { level = math.floor(level * 100 + 0.5) / 100, at = OPX.Now() })
end

--- Armour for the high, added to what the player has, bounded.
local function addArmor(player, amount)
	if amount <= 0 then return end
	local players = Open77.players
	if type(players) ~= 'table' or type(players.setArmor) ~= 'function' then return end
	local current = 0
	if type(players.getHealth) == 'function' then
		local read, snapshot = pcall(players.getHealth, player)
		if read and type(snapshot) == 'table' then current = tonumber(snapshot.armor) or 0 end
	end
	local cap = Model.Bounded(addiction().ARMOR_CAP, 0, 1000, 60)
	if current >= cap then return end
	pcall(players.setArmor, player, math.min(cap, current + amount))
end

--- What using a drug does. The inventory's use handler; answers its verdict.
-- @author dop42
-- @param player integer
-- @param info table { name, slot, ... }
-- @return table { ok, consume } or { ok = false, error }
function Drugs.Use(player, info)
	local name = type(info) == 'table' and info.name or nil
	local drug = name and built().drugs[name] or nil
	if drug == nil then return { ok = false, error = 'use_refused' } end
	if OPX.Life.Down(player) then return { ok = false, error = 'dead' } end
	local cooldown = Model.Integer(addiction().USE_COOLDOWN_MS, 0, 600000) or 5000
	local now = OPX.Now()
	if lastUse[player] ~= nil and now - lastUse[player] < cooldown then
		M.Answer(player, false, 'too_soon')
		return { ok = false, error = 'too_fast' }
	end
	lastUse[player] = now

	if drug.effect ~= '' and type(Open77.effects) == 'table' and type(Open77.effects.screen) == 'function' then
		local called, ok, why = pcall(Open77.effects.screen, player, drug.effect,
			{ strength = drug.strength, duration = drug.seconds })
		if not called or ok ~= true then
			Open77.log.debug(('[underworld] screen effect %s refused: %s'):format(drug.effect,
				tostring(called and why or ok)))
		end
	end
	addArmor(player, drug.armor)

	local level = Drugs.Level(player) + drug.dose
	local overdose = Model.Bounded(addiction().OVERDOSE_AT, 1, 100000, 14)
	local warnAt = Model.Bounded(addiction().WARN_AT, 0, 100000, 8)
	local loaded = Op.Character(player)
	if level >= overdose then
		-- The body gives out; `downed` takes it from there. The counter drops to
		-- the warning line so the next hit is not instantly fatal again.
		setLevel(player, warnAt)
		local called, killed, why = pcall(Open77.players.kill, player,
			{ cause = 'script', weapon = 'opx:underworld:overdose' })
		if not called or killed == false then
			Open77.log.warn('[underworld] an overdose could not be applied: ' .. tostring(called and why or killed))
		end
		OPX.Audit.Log({ event = 'underworld.overdose', source = player, citizenId = loaded and loaded.citizenId,
			message = ('%s at %.1f'):format(name, level), data = { item = name, level = level } })
		M.Answer(player, false, 'overdose')
	else
		setLevel(player, level)
		if level >= warnAt then M.Answer(player, false, 'addiction_warn') end
	end
	return { ok = true, consume = 1 }
end

-- ── labs ────────────────────────────────────────────────────────────────────

--- A lab's heat now.
-- @author dop42
function Drugs.Heat(labId) return heat[labId] or 0 end

local function onOrdered(player, payload)
	if type(payload) ~= 'table' or type(payload.bench) ~= 'string' then return end
	if payload.bench:sub(1, #M.BENCH_PREFIX) ~= M.BENCH_PREFIX then return end
	local lab = built().labs.byId[payload.bench:sub(#M.BENCH_PREFIX + 1)]
	if lab == nil then return end
	heat[lab.id] = math.min(100, (heat[lab.id] or 0) + lab.perCycle)
	if heat[lab.id] < lab.floor then return end
	local alert = OPX.Table.DeepCopy(lab.alert)
	alert.chance = alert.chance * heat[lab.id] / 100
	M.Alert.Raise('lab', lab.label, lab, alert, ('lab:%s:%s:%s'):format(lab.id, tostring(payload.order),
		tostring(OPX.Now())))
end

local function cool()
	for id, value in pairs(heat) do
		local lab = built().labs.byId[id]
		local left = value - (lab and lab.decayPerMinute or 1)
		heat[id] = left > 0 and left or nil
	end
end

local function registerLabs()
	local crafting = OPX.Api.Get('crafting')
	if crafting == nil or type(crafting.RegisterBench) ~= 'function' then
		if #built().labs.list > 0 then Open77.log.warn('[underworld] no crafting contract: no lab cooks') end
		return
	end
	for _, lab in ipairs(built().labs.list) do
		local key = M.BENCH_PREFIX .. lab.id
		local placed = crafting.RegisterBench(key, {
			label = lab.label, owner = M.OWNER,
			position = { x = lab.x, y = lab.y, z = lab.z, bucket = lab.bucket },
			reach = lab.reach, queue = lab.queue, recipes = lab.recipes,
			canUse = function(player)
				local loaded = Op.Character(player)
				if loaded == nil then return false, 'no_character' end
				local passed = M.Allowed(lab, loaded)
				return passed, passed and nil or 'not_for_you'
			end,
		})
		if type(placed) == 'table' and placed.ok then
			benches[#benches + 1] = key
		else
			Open77.log.warn(('[underworld] lab %s was refused a bench: %s'):format(lab.id,
				tostring(type(placed) == 'table' and (placed.detail or placed.error) or placed)))
		end
	end
end

-- ── street deals ────────────────────────────────────────────────────────────

local function street() return built().street end

--- A player id off a payload, or nil.
local function playerOf(value)
	local id = math.tointeger(tonumber(value))
	if id == nil or id <= 0 or id > 2147483647 then return nil end
	return id
end

--- What a seller may offer the player in front of them. Yields.
-- @author dop42
function Drugs.DealMenu(player, payload)
	if M.Limited(player) then return M.Answer(player, false, 'too_fast') end
	if not street().enabled then return M.Answer(player, false, 'unavailable') end
	local target = playerOf(type(payload) == 'table' and payload.target or nil)
	if target == nil or target == player then return M.Answer(player, false, 'no_buyer') end
	local loaded = Op.Character(player)
	if loaded == nil then return M.Answer(player, false, 'no_character') end
	local bag, offers = inventory(), {}
	local names = {}
	for name in pairs(street().items) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local counted = bag.GetItemCount(player, name)
		local held = type(counted) == 'table' and counted.ok and tonumber(counted.value) or 0
		if held > 0 then
			local range = street().items[name]
			local prices = {}
			for _, price in ipairs(street().prices) do
				if price >= range.min and price <= range.max then prices[#prices + 1] = price end
			end
			local counts = {}
			for _, count in ipairs(street().counts) do
				if count <= held then counts[#counts + 1] = count end
			end
			if #prices > 0 and #counts > 0 then
				offers[#offers + 1] = { item = name, held = held, prices = prices, counts = counts }
			end
		end
	end
	local live = Op.Character(player)
	if live == nil or live.data ~= loaded.data then return false end
	if #offers == 0 then return M.Answer(player, false, 'nothing_to_sell') end
	TriggerClientEvent(M.Event.VIEW, player, { kind = 'deal', target = target, offers = offers,
		currency = street().currency })
	return true
end

local function coordinator()
	local native = Open77.playerInteractions
	return type(native) == 'table' and type(native.request) == 'function' and native or nil
end

--- Offers a deal to the player in front of the seller. Yields.
-- @author dop42
function Drugs.Offer(player, payload)
	if M.Limited(player) then return M.Answer(player, false, 'too_fast') end
	if not street().enabled then return M.Answer(player, false, 'unavailable') end
	payload = type(payload) == 'table' and payload or {}
	local target = playerOf(payload.target)
	local item = type(payload.item) == 'string' and street().items[payload.item] and payload.item or nil
	local count = Model.Integer(payload.count, 1, 1000)
	if target == nil or target == player or item == nil or count == nil then
		return M.Answer(player, false, 'bad_request')
	end
	local range = street().items[item]
	-- The TOTAL for the lot, inside the per-unit range times the count.
	local price = Model.Integer(payload.price, range.min * count, range.max * count)
	if price == nil then return M.Answer(player, false, 'bad_price') end
	if dealOf[player] ~= nil then return M.Answer(player, false, 'busy') end
	local seller = Op.Character(player)
	local buyer = Op.Character(target)
	if seller == nil then return M.Answer(player, false, 'no_character') end
	if buyer == nil then return M.Answer(player, false, 'no_buyer') end
	if Op.Of(player) ~= nil then return M.Answer(player, false, 'busy') end
	local counted = inventory().GetItemCount(player, item)
	if type(counted) ~= 'table' or not counted.ok or (tonumber(counted.value) or 0) < count then
		return M.Answer(player, false, 'not_enough_items')
	end
	local liveSeller, liveBuyer = Op.Character(player), Op.Character(target)
	if liveSeller == nil or liveBuyer == nil or liveSeller.data ~= seller.data or liveBuyer.data ~= buyer.data then return false end
	local native = coordinator()
	if native == nil then return M.Answer(player, false, 'unavailable') end
	local called, state, why = pcall(native.request, player, target, 'give', {
		durationMs = street().durationMs, inviteTimeoutMs = street().inviteMs,
		startDistance = street().startDistance, breakDistance = math.max(street().startDistance, 5),
		consent = true,
	})
	if not called or type(state) ~= 'table' or type(state.id) ~= 'string' then
		Open77.log.debug('[underworld] a deal was refused by the coordinator: ' .. tostring(called and why or state))
		return M.Answer(player, false, 'deal_refused')
	end
	deals[state.id] = { seller = player, buyer = target, sellerCitizen = seller.citizenId,
		buyerCitizen = buyer.citizenId, item = item, count = count, price = price, at = OPX.Now() }
	dealOf[player] = state.id
	M.Answer(player, true, 'deal_offered', { count = count, price = price })
	M.Answer(target, true, 'deal_invited', { count = count, price = price })
	return true
end

--- Takes from one side; answers whether it went.
local function take(target, name, count)
	local removed = inventory().RemoveItem(target, name, count)
	return type(removed) == 'table' and removed.ok == true
end

local function give(target, name, count)
	local added = inventory().AddItem(target, name, count)
	return type(added) == 'table' and added.ok == true
end

--- Takes or gives the price.
local function moveMoney(target, amount, out)
	if street().currency == 'clean' then
		local api = character()
		local fn = out and api.RemoveMoney or api.AddMoney
		local called, ok = pcall(fn, target, built().dirty.cleanType, amount, 'underworld:deal')
		return called and ok == true
	end
	if out then return take(target, built().dirty.item, amount) end
	return give(target, built().dirty.item, amount)
end

--- The swap, once the hand-over completed. Yields.
-- @author dop42
function Drugs.Complete(id)
	local deal = deals[id]
	deals[id] = nil
	if deal == nil then return false end
	if dealOf[deal.seller] == id then dealOf[deal.seller] = nil end
	local seller, buyer = Op.Character(deal.seller), Op.Character(deal.buyer)
	if seller == nil or buyer == nil or seller.citizenId ~= deal.sellerCitizen
		or buyer.citizenId ~= deal.buyerCitizen then
		return false
	end
	local function answer(target, success, code, params)
		local live = Op.Character(target)
		local expected = target == deal.seller and seller or buyer
		if live ~= nil and live.data == expected.data then M.Answer(target, success, code, params) end
	end
	-- Both sides give first; value is created on each side only after.
	if not take(deal.sellerCitizen, deal.item, deal.count) then
		answer(deal.seller, false, 'not_enough_items')
		answer(deal.buyer, false, 'deal_failed')
		return false
	end
	if not moveMoney(deal.buyerCitizen, deal.price, true) then
		give(deal.sellerCitizen, deal.item, deal.count)
		answer(deal.buyer, false, street().currency == 'clean' and 'not_enough_money' or 'not_enough_dirty')
		answer(deal.seller, false, 'buyer_short')
		return false
	end
	if not give(deal.buyerCitizen, deal.item, deal.count) then
		moveMoney(deal.buyerCitizen, deal.price, false)
		give(deal.sellerCitizen, deal.item, deal.count)
		answer(deal.buyer, false, 'cannot_carry')
		answer(deal.seller, false, 'deal_failed')
		return false
	end
	if not moveMoney(deal.sellerCitizen, deal.price, false) then
		-- The seller's bag refused the cash: it goes to their row instead.
		local refunded = Op.Refund(nil, deal.sellerCitizen, street().currency == 'clean'
			and { money = { { type = built().dirty.cleanType, amount = deal.price } } }
			or { items = { { name = built().dirty.item, count = deal.price } } })
		if #refunded > 0 then
			OPX.Audit.Log({ event = 'underworld.refundLost', severity = 'warn', citizenId = deal.sellerCitizen,
				message = 'deal ' .. id, data = { lost = table.concat(refunded, ', ') } })
		end
	end
	if street().currency ~= 'clean' then
		Storage.Ledger(deal.buyerCitizen, 'deal:paid', -deal.price)
		Storage.Ledger(deal.sellerCitizen, 'deal:received', deal.price)
	end
	OPX.Audit.Log({ event = 'underworld.deal', source = deal.seller, citizenId = deal.sellerCitizen,
		message = ('%dx %s to %s for %d'):format(deal.count, deal.item, deal.buyerCitizen, deal.price),
		data = { item = deal.item, count = deal.count, price = deal.price, buyer = deal.buyerCitizen } })
	OPX.Publish(M.Event.ON_COMMITTED, deal.seller, { kind = 'deal', citizenId = deal.sellerCitizen,
		buyer = deal.buyerCitizen, item = deal.item, count = deal.count, price = deal.price })
	answer(deal.seller, true, 'deal_done', { count = deal.count, price = deal.price })
	answer(deal.buyer, true, 'deal_bought', { count = deal.count, price = deal.price })
	local at = Op.Point(deal.seller)
	if at ~= nil then M.Alert.Raise('deal', locale('underworld.alert.deal'), at, street().alert, 'deal:' .. id) end
	return true
end

local function onCompleted(state)
	if type(state) ~= 'table' or type(state.id) ~= 'string' or deals[state.id] == nil then return end
	CreateThread(function() Drugs.Complete(state.id) end)
end

local function onCancelled(state)
	if type(state) ~= 'table' or type(state.id) ~= 'string' then return end
	local deal = deals[state.id]
	if deal == nil then return end
	deals[state.id] = nil
	if dealOf[deal.seller] == state.id then dealOf[deal.seller] = nil end
	M.Answer(deal.seller, false, 'deal_cancelled')
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Resets the state. Never yields.
-- @author dop42
function Drugs.Init()
	heat, lastUse, deals, dealOf, benches, jobs = {}, {}, {}, {}, {}, {}
end

--- Registers the items, the uses, the labs and the deal doors. On a coroutine.
-- @author dop42
function Drugs.Start()
	Drugs.RegisterItems()
	local api = inventory()
	if api ~= nil and type(api.RegisterUsable) == 'function' then
		for name in pairs(built().drugs) do
			local registered, why = api.RegisterUsable(name, Drugs.Use, M.OWNER)
			if not registered then
				Open77.log.warn(('[underworld] %s could not be made usable: %s'):format(name, tostring(why)))
			end
		end
	end
	registerLabs()
	jobs[#jobs + 1] = OPX.Scheduler.Every('underworld:heat', 60000, cool)

	-- Handlers are added once per process: a reload re-runs Start in the same
	-- VM only after a full stop, which drops them with the resource.
	if not wired then
		wired = true
		AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'crafting', 'ordered'), onOrdered)
		AddEventHandler('onPlayerInteractionCompleted', onCompleted)
		AddEventHandler('onPlayerInteractionCancelled', onCancelled)
		AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(raw)
			local player = math.tointeger(tonumber(raw))
			if player ~= nil then lastUse[player] = nil end
		end)
		for _, pair in ipairs({ { M.Event.DEAL_MENU, Drugs.DealMenu }, { M.Event.DEAL_OFFER, Drugs.Offer } }) do
			RegisterNetEvent(pair[1], function(payload)
				local player = tonumber(source)
				if player == nil or player <= 0 then return end
				CreateThread(function() pair[2](player, payload) end)
			end)
		end
	end
end

--- Takes the benches and the uses back.
-- @author dop42
function Drugs.Stop()
	for _, job in ipairs(jobs) do pcall(OPX.Scheduler.Cancel, job) end
	jobs = {}
	local crafting = OPX.Api.Get('crafting')
	if crafting ~= nil and type(crafting.UnregisterBenches) == 'function' then
		pcall(crafting.UnregisterBenches, M.OWNER)
	end
	local api = inventory()
	if api ~= nil and type(api.UnregisterUsables) == 'function' then pcall(api.UnregisterUsables, M.OWNER) end
	local native = coordinator()
	for id in pairs(deals) do
		if native ~= nil and type(native.cancel) == 'function' then pcall(native.cancel, id, 'resource_stopping') end
	end
	deals, dealOf = {}, {}
end
