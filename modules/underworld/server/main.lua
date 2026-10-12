--- Server half: dirty money, alarms, the black market, robberies, laundering,
--- the staff commands and the contract.
-- @author dop42
--
-- EVERY REQUEST ARRIVES THE SAME WAY: the rate window, a loaded character, the
-- entry named (re-read from the config the server built, never from the
-- payload), the gate, the reach -- and then `M.Op.Begin`, which owns the order
-- of everything after (see `server/op.lua`). Every answer is a locale key under
-- `underworld.` sent to the player who asked and to nobody else.
--
-- WHERE THE DIRTY MONEY COMES FROM is `Dirty.Mint` alone: a robbery's till and
-- a fence's payout both go through it, under the MINT_CAPS ceiling, with a
-- ledger line. The only ways it leaves are a dealer's price and a front's
-- deposit, both as op inputs -- out of the bag first, and the escrow line in the
-- ledger says so.
--
-- Labs, drugs and street deals are `server/drugs.lua`, started from here.

local M = OPX.Modules.Get('underworld')
local Model = M.Model
local Storage = M.Storage
local Op = M.Op
local Command = M.Command

M.Dirty, M.Alert = {}, {}
local Dirty, Alert = M.Dirty, M.Alert

-- The built config, and what it refused.
local built, problems, placeholders = nil, {}, {}

-- player -> { startedAt, count }: the request window.
local windows = {}
-- citizen -> kind -> { { at, amount } }: what was minted in the cap window.
local minted = {}
-- dealer id -> { entry, spot, npc, key, rotatedAt, absent }
local dealers = {}
-- npc key -> dealer id
local dealerByNpc = {}
-- store id -> { charges, lastAt, clerk, clerkKey, clerkDeadAt }
local stores = {}
-- npc key -> store id
local storeByClerk = {}
-- citizen -> last robbery instant
local robbedAt = {}
-- citizen -> dirty eddies reserved for a deposit not yet filed
local pendingLaunder = {}
-- player -> true while a collect is running
local collecting = {}
-- players that asked for the dealer list, so a change reaches them.
local told = {}

local jobs = {}

local function settings() return M.Settings end
local function character() return OPX.Api.Get('character') end
local function inventory() return OPX.Api.Get('inventory') end

-- ── answers and windows ─────────────────────────────────────────────────────

--- Sends one answer to the player who asked. Never to anybody else.
-- @author dop42
-- @param player integer
-- @param ok boolean
-- @param code string a key under `underworld.answer.` (ok) or `underworld.error.`
-- @param params table|nil strings and numbers for the sentence
-- @return boolean ok
function M.Answer(player, ok, code, params)
	if type(player) ~= 'number' or player <= 0 then return ok end
	TriggerClientEvent(M.Event.ANSWER, player, { ok = ok == true, code = code, params = params })
	return ok
end
local answer = M.Answer

--- Whether a player has spent their request window.
-- @author dop42
function M.Limited(player)
	local limit = type(settings().RATE_LIMIT) == 'table' and settings().RATE_LIMIT or {}
	local span = Model.Integer(limit.WINDOW_MS, 100, 600000) or 10000
	local most = Model.Integer(limit.REQUESTS, 1, 1000) or 8
	local now = OPX.Now()
	local window = windows[player]
	if window == nil or now - window.startedAt >= span then
		windows[player] = { startedAt = now, count = 1 }
		return false
	end
	window.count = window.count + 1
	return window.count > most
end

--- A loaded character, or nil after answering why not.
local function loadedOr(player)
	local loaded = Op.Character(player)
	if loaded == nil then answer(player, false, 'no_character') end
	return loaded
end

--- Whether a loaded character passes an entry's gate.
-- @author dop42
function M.Allowed(entry, loaded)
	return Model.Gate(entry, Op.Snapshot(loaded), OPX.Now(), settings())
end

--- A whole number off a payload, inside a range, or nil.
local function wanted(value, low, high)
	if math.type(value) ~= 'integer' and type(value) ~= 'number' then return nil end
	return Model.Integer(value, low, high)
end

--- An entry ID off a payload, or nil.
local function idOf(value)
	if type(value) ~= 'string' or #value > Model.ID_MAX or not value:match(Model.ID) then return nil end
	return value
end

-- ── dirty money ─────────────────────────────────────────────────────────────

--- The item a dirty eddie is.
-- @author dop42
function Dirty.Item() return built.dirty.item end

--- Makes dirty eddies for a crime, under the mint cap. Yields.
-- @author dop42
-- @param player integer
-- @param citizenId string
-- @param amount integer what the crime would pay
-- @param kind string the MINT_CAPS key: robbery, fence, corner
-- @param source string for the ledger, e.g. `robbery:kabuki_247`
-- @param at table|nil where
-- @return integer what was paid (0: nothing)
-- @return string|nil why not all of it: mint_cap, cannot_carry
function Dirty.Mint(player, citizenId, amount, kind, source, at)
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return 0, nil end
	local caps = type(settings().MINT_CAPS) == 'table' and settings().MINT_CAPS or {}
	local windowMs = math.floor(Model.Bounded(caps.WINDOW_MINUTES, 1, 100000, 60) * 60000)
	minted[citizenId] = minted[citizenId] or {}
	local list = minted[citizenId][kind] or {}
	minted[citizenId][kind] = list
	local left = Model.CapLeft(list, OPX.Now(), windowMs, caps[kind])
	local why = nil
	if amount > left then amount, why = math.floor(left), 'mint_cap' end
	if amount <= 0 then return 0, 'mint_cap' end

	local paid = false
	if built.dirty.mode == 'clean' then
		local api = character()
		local called, ok = pcall(api.AddMoney, player, built.dirty.cleanType, amount, 'underworld:' .. source)
		paid = called and ok == true
	else
		local added = inventory().AddItem(player, built.dirty.item, amount)
		paid = type(added) == 'table' and added.ok == true
	end
	if not paid then return 0, 'cannot_carry' end
	list[#list + 1] = { at = OPX.Now(), amount = amount }
	if built.dirty.mode ~= 'clean' then Storage.Ledger(citizenId, source, amount, at) end
	OPX.Publish(M.Event.ON_DIRTY, player, { citizenId = citizenId, amount = amount, source = source })
	return amount, why
end

-- ── alarms ──────────────────────────────────────────────────────────────────

--- The police on duty: their connections.
-- @author dop42
-- @return integer[]
function M.Police()
	local police = type(settings().POLICE) == 'table' and settings().POLICE or {}
	local api = character()
	local out, seen = {}, {}
	if api == nil or type(api.GetPlayersByJob) ~= 'function' then return out end
	for name, minimum in pairs(type(police.JOBS) == 'table' and police.JOBS or {}) do
		local read, list = pcall(api.GetPlayersByJob, name, police.ON_DUTY ~= false)
		for _, loaded in ipairs(read and type(list) == 'table' and list or {}) do
			local data = type(loaded) == 'table' and loaded.PlayerData or nil
			local level = data and type(data.job) == 'table' and type(data.job.grade) == 'table'
				and tonumber(data.job.grade.level) or 0
			local source = data and math.tointeger(data.source) or nil
			if source ~= nil and not seen[source] and level >= (tonumber(minimum) or 0) then
				seen[source] = true
				out[#out + 1] = source
			end
		end
	end
	table.sort(out)
	return out
end

--- How many police are on duty: a `police` module's count when there is one.
-- @author dop42
function M.PoliceCount()
	local police = OPX.Api.Get('police')
	if police ~= nil and type(police.OnDutyCount) == 'function' then
		local read, count = pcall(police.OnDutyCount)
		if read and tonumber(count) ~= nil then return math.floor(tonumber(count)) end
	end
	return #M.Police()
end

--- Rolls an alarm and, if it goes off, delivers it after its delay.
-- @author dop42
-- @param kind string robbery, clerk, lab, deal
-- @param label string what the officer reads
-- @param at table { x, y, z }
-- @param alert table a built ALERT block
-- @param seed string the op id or another unique word
-- @param force boolean|nil true: skip the chance roll (a dead clerk)
-- @return boolean whether one was scheduled
function Alert.Raise(kind, label, at, alert, seed, force)
	if type(at) ~= 'table' or type(alert) ~= 'table' then return false end
	if not force and not Model.Chance(seed, 'alarm', alert.chance) then return false end
	local delay = force and 0 or Model.Roll(seed, 'delay', alert.delayMin, alert.delayMax)
	local witnessed = Model.Chance(seed, 'witness', alert.witness)
	local x, y = Model.Blur(at.x, at.y, alert.blur, seed)
	local payload = { kind = kind, label = label, witnessed = witnessed,
		x = witnessed and x or nil, y = witnessed and y or nil, z = witnessed and at.z or nil,
		radius = alert.blur }
	CreateThread(function()
		if delay > 0 then Wait(delay) end
		Alert.Deliver(payload)
	end)
	return true
end

--- Hands an alarm to the police module, or to the officers on duty.
-- @author dop42
function Alert.Deliver(payload)
	OPX.Publish(M.Event.ON_ALERT, nil, payload)
	local police = OPX.Api.Get('police')
	if police ~= nil and type(police.Report) == 'function' then
		local read, failure = pcall(police.Report, { crime = payload.kind, label = payload.label,
			position = payload.x and { x = payload.x, y = payload.y, z = payload.z } or nil,
			radius = payload.radius, source = 'underworld' })
		if read then return end
		Open77.log.warn('[underworld] the police module refused an alarm: ' .. tostring(failure))
	end
	local seconds = Model.Integer(type(settings().POLICE) == 'table' and settings().POLICE.BLIP_SECONDS,
		5, 3600) or 90
	payload.seconds = seconds
	for _, officer in ipairs(M.Police()) do TriggerClientEvent(M.Event.ALERT, officer, payload) end
end

-- ── NPCs ────────────────────────────────────────────────────────────────────

local function npcKey(id)
	return math.type(id) == 'integer' and ('%d'):format(id) or tostring(id)
end

--- Creates a server NPC, or nil.
local function spawnNpc(record, at, yaw, bucket, mortal)
	local npcs = Open77.npcs
	if type(npcs) ~= 'table' or type(npcs.create) ~= 'function' then return nil end
	local damage = type(npcs.damage) == 'table' and npcs.damage or {}
	local called, id, why = pcall(npcs.create, {
		record = record, position = { x = at.x, y = at.y, z = at.z }, yaw = yaw, bucket = bucket,
		aiMode = type(npcs.ai) == 'table' and npcs.ai.tasks or nil,
		damagePolicy = mortal and damage.mortal or damage.immortal,
		-- A mortal clerk is priced by the platform's own hit model, so a shot
		-- lands without this module keeping a damage table.
		behavior = { combatEnabled = false, voiceEnabled = true, hitPricing = mortal and 'platform' or nil },
		despawnWhenUnobserved = false,
	})
	if not called or id == nil then
		Open77.log.warn(('[underworld] no NPC %s: %s'):format(tostring(record), tostring(called and why or id)))
		return nil
	end
	return id
end

local function removeNpc(id)
	if id ~= nil and type(Open77.npcs) == 'table' and type(Open77.npcs.remove) == 'function' then
		pcall(Open77.npcs.remove, id)
	end
end

--- A bark from an NPC's own voiceset, if it has one. Never matters if not.
local function speak(id, line)
	if id ~= nil and type(Open77.npcs) == 'table' and type(Open77.npcs.speak) == 'function' then
		pcall(Open77.npcs.speak, id, line)
	end
end

-- ── the black market ────────────────────────────────────────────────────────

local function dealerList()
	local list = {}
	for id, state in pairs(dealers) do
		if state.key ~= nil then list[#list + 1] = { npc = state.key, dealer = id, label = state.entry.label } end
	end
	table.sort(list, function(a, b) return a.dealer < b.dealer end)
	return list
end

local function announceDealers()
	local list = dealerList()
	for player in pairs(told) do TriggerClientEvent(M.Event.DEALERS, player, list) end
end

--- The hour of the game clock, or nil when there is none to read.
local function gameHour()
	local weather = OPX.Api.Get('weather')
	if weather == nil or type(weather.Status) ~= 'function' then return nil end
	local read, status = pcall(weather.Status)
	return read and type(status) == 'table' and tonumber(status.hour) or nil
end

--- One pass over the dealers: present or not, rotated, restocked; and the
--- clerks: a dead one stands back up once its till would have regrown.
local function dealerStep()
	local now, hour, changed = OPX.Now(), gameHour(), false
	for _, state in pairs(dealers) do
		local entry = state.entry
		local present = Model.InHours(hour, entry.hours)
		local rotate = present and state.npc ~= nil and entry.rotateMs > 0 and #entry.spots > 1
			and now - state.rotatedAt >= entry.rotateMs
		if state.npc ~= nil and (not present or rotate) then
			dealerByNpc[state.key] = nil
			removeNpc(state.npc)
			state.npc, state.key, changed = nil, nil, true
			if rotate then state.spot = state.spot % #entry.spots + 1 end
		end
		if present and state.npc == nil and not state.refused then
			local spot = entry.spots[state.spot]
			state.npc = spawnNpc(entry.record, spot, spot.yaw, entry.bucket, false)
			if state.npc ~= nil then
				state.key = npcKey(state.npc)
				dealerByNpc[state.key] = entry.id
				state.rotatedAt, changed = now, true
			else
				state.refused = true
			end
		end
		for _, line in ipairs(state.stock) do
			if line.qty < line.max and line.restockMs > 0 then
				line.restockAt = line.restockAt or (now + line.restockMs)
				if now >= line.restockAt then
					line.qty = line.qty + 1
					line.restockAt = line.qty < line.max and (now + line.restockMs) or nil
				end
			end
		end
	end
	for id, state in pairs(stores) do
		local entry = built.stores.byId[id]
		if entry.clerk ~= nil and state.clerkDeadAt ~= nil and now - state.clerkDeadAt >= entry.regrowMs then
			removeNpc(state.clerk)
			if state.clerkKey then storeByClerk[state.clerkKey] = nil end
			state.clerk = spawnNpc(entry.clerk.record, entry.clerk, entry.clerk.yaw, entry.bucket, true)
			state.clerkKey = state.clerk and npcKey(state.clerk) or nil
			if state.clerkKey then storeByClerk[state.clerkKey] = id end
			state.clerkDeadAt = nil
		end
	end
	if changed then announceDealers() end
end

--- The dealer whose NPC a client named, with its anchor, or nil.
local function dealerOf(value)
	local id = nil
	if type(value) == 'string' and #value <= 24 and value:match('^%d+$') then id = dealerByNpc[value] end
	if id == nil then id = idOf(value) end
	local state = id and dealers[id] or nil
	if state == nil or state.npc == nil then return nil end
	return state, state.entry.spots[state.spot]
end

--- What a dealer's stall shows this player. Yields (bag counts).
local function stallView(player, state)
	local entry, bag = state.entry, inventory()
	local premium = Model.Bounded(settings().BLACKMARKET and settings().BLACKMARKET.CLEAN_PREMIUM, 1, 100, 1.4)
	local stock, buys = {}, {}
	for index, line in ipairs(state.stock) do
		stock[#stock + 1] = { index = index, item = line.item, qty = line.qty,
			dirty = Model.Price(line.price, entry.priceMod, 1, false, premium),
			clean = not line.dirtyOnly and Model.Price(line.price, entry.priceMod, 1, true, premium) or nil }
	end
	for index, line in ipairs(entry.buys) do
		local counted = bag.GetItemCount(player, line.item)
		buys[#buys + 1] = { index = index, item = line.item,
			price = math.floor(line.price * entry.priceMod),
			held = type(counted) == 'table' and counted.ok and tonumber(counted.value) or 0 }
	end
	return { kind = 'dealer', dealer = entry.id, label = entry.label, stock = stock, buys = buys }
end

--- Opens a dealer's stall for a player.
-- @author dop42
function M.OpenDealer(player, payload)
	if M.Limited(player) then return answer(player, false, 'too_fast') end
	local state, spot = dealerOf(type(payload) == 'table' and payload.npc or nil)
	if state == nil then return answer(player, false, 'no_dealer') end
	local loaded = loadedOr(player)
	if loaded == nil then return false end
	local passed, why = M.Allowed(state.entry, loaded)
	if not passed then return answer(player, false, why) end
	local code = Op.Standing(player, spot, state.entry.reach)
	if code ~= nil then return answer(player, false, code) end
	speak(state.npc, 'greeting')
	TriggerClientEvent(M.Event.VIEW, player, stallView(player, state))
	return true
end

local function premium()
	return Model.Bounded(settings().BLACKMARKET and settings().BLACKMARKET.CLEAN_PREMIUM, 1, 100, 1.4)
end

local function dealSpec(player, state, spot, loaded)
	local market = type(settings().BLACKMARKET) == 'table' and settings().BLACKMARKET or {}
	return {
		loaded = loaded, anchor = spot, reach = state.entry.reach,
		label = locale('underworld.bar.deal'),
		durationMs = Model.Integer(market.DEAL_MS, 250, 60000) or 3000,
		animation = type(market.ANIMATION) == 'string' and market.ANIMATION or '',
	}
end

--- Buys one stock line from a dealer. Yields.
-- @author dop42
function M.Buy(player, payload)
	if M.Limited(player) then return answer(player, false, 'too_fast') end
	payload = type(payload) == 'table' and payload or {}
	local state, spot = dealerOf(payload.dealer)
	if state == nil then return answer(player, false, 'no_dealer') end
	local index = wanted(payload.index, 1, #state.stock)
	local count = wanted(payload.count, 1, 1000)
	local clean = payload.pay == 'clean'
	if index == nil or count == nil or (payload.pay ~= 'dirty' and payload.pay ~= 'clean') then
		return answer(player, false, 'bad_request')
	end
	local line = state.stock[index]
	if clean and line.dirtyOnly then return answer(player, false, 'dirty_only') end
	local loaded = loadedOr(player)
	if loaded == nil then return false end
	local passed, why = M.Allowed(state.entry, loaded)
	if not passed then return answer(player, false, why) end
	local carry = inventory().CanCarry(player, line.item, count)
	if type(carry) ~= 'table' or not carry.ok or carry.value ~= true then
		return answer(player, false, 'cannot_carry')
	end
	local price = Model.Price(line.price, state.entry.priceMod, count, clean, premium())
	local spec = dealSpec(player, state, spot, loaded)
	spec.kind = 'buy'
	spec.check = function(_, again)
		if not again and line.qty < count then return 'sold_out' end
		if state.npc == nil then return 'no_dealer' end
		return nil
	end
	spec.claim = function() line.qty = line.qty - count end
	spec.release = function() line.qty = math.min(line.max, line.qty + count) end
	spec.inputs = clean and { money = { { type = built.dirty.cleanType, amount = price } } }
		or { items = { { name = built.dirty.item, count = price } } }
	spec.commit = function(op)
		local added = inventory().AddItem(op.player, line.item, count)
		if type(added) ~= 'table' or not added.ok then return false, 'cannot_carry' end
		return true, 'bought', { item = line.item, count = count, price = price, clean = clean,
			dealer = state.entry.id }
	end
	spec.after = function(op, ok, code, result)
		answer(op.player, ok, code, ok and { count = count, price = price, item = line.item } or nil)
	end
	local ok, code = Op.Begin(player, spec)
	-- `started` is the bar going up: the client says nothing, the bar does.
	return answer(player, ok, ok and 'started' or code)
end

--- Sells goods to a dealer, for dirty eddies. Yields.
-- @author dop42
function M.Sell(player, payload)
	if M.Limited(player) then return answer(player, false, 'too_fast') end
	payload = type(payload) == 'table' and payload or {}
	local state, spot = dealerOf(payload.dealer)
	if state == nil then return answer(player, false, 'no_dealer') end
	local index = wanted(payload.index, 1, #state.entry.buys)
	local count = wanted(payload.count, 1, 1000)
	if index == nil or count == nil then return answer(player, false, 'bad_request') end
	local line = state.entry.buys[index]
	local loaded = loadedOr(player)
	if loaded == nil then return false end
	local passed, why = M.Allowed(state.entry, loaded)
	if not passed then return answer(player, false, why) end
	local price = math.floor(line.price * state.entry.priceMod) * count
	local spec = dealSpec(player, state, spot, loaded)
	spec.kind = 'fence'
	spec.check = function() return state.npc == nil and 'no_dealer' or nil end
	spec.inputs = { items = { { name = line.item, count = count } } }
	spec.commit = function(op)
		local paid, short = Dirty.Mint(op.player, op.citizenId, price, 'fence', 'fence:' .. state.entry.id, op.at)
		if paid <= 0 then return false, short or 'unavailable' end
		return true, short == 'mint_cap' and 'sold_capped' or 'sold', { item = line.item, count = count, paid = paid }
	end
	spec.after = function(op, ok, code, result)
		answer(op.player, ok, code, ok and { count = count, paid = result.paid, item = line.item } or nil)
	end
	local ok, code = Op.Begin(player, spec)
	-- `started` is the bar going up: the client says nothing, the bar does.
	return answer(player, ok, ok and 'started' or code)
end

-- ── store robberies ─────────────────────────────────────────────────────────

--- A till's charges now, regrown. Never yields.
local function chargesOf(id)
	local entry, state = built.stores.byId[id], stores[id]
	local charges, lastAt = Model.Regrow(state.charges, entry.max, entry.regrowMs, state.lastAt, OPX.Now())
	state.charges, state.lastAt = charges, lastAt
	return charges
end

local function saveTill(id)
	local state = stores[id]
	Storage.SaveRegister(id, state.charges, (OPX.Now() - state.lastAt) / 1000)
end

--- Robs a till. Yields.
-- @author dop42
function M.Rob(player, payload)
	if M.Limited(player) then return answer(player, false, 'too_fast') end
	local id = idOf(type(payload) == 'table' and payload.store or nil)
	local entry = id and built.stores.byId[id] or nil
	if entry == nil or stores[id] == nil then return answer(player, false, 'no_store') end
	local loaded = loadedOr(player)
	if loaded == nil then return false end
	local last = robbedAt[loaded.citizenId]
	if last ~= nil and OPX.Now() - last < entry.cooldownMs then
		return answer(player, false, 'cooldown',
			{ minutes = math.ceil((entry.cooldownMs - (OPX.Now() - last)) / 60000) })
	end
	local robberies = type(settings().ROBBERIES) == 'table' and settings().ROBBERIES or {}
	local state = stores[id]
	local spec = {
		kind = 'robbery', loaded = loaded, lock = 'store:' .. id, reach = entry.reach,
		anchor = { x = entry.x, y = entry.y, z = entry.z, bucket = entry.bucket },
		label = locale('underworld.bar.rob'), durationMs = entry.durationMs,
		animation = type(robberies.ANIMATION) == 'string' and robberies.ANIMATION or '',
	}
	spec.check = function(op, again)
		if again then return nil end
		if M.PoliceCount() < entry.minPolice then return 'not_enough_police' end
		if entry.requireWeapon then
			local read, held = pcall(inventory().GetHeldWeapon, op.player)
			if not read or type(held) ~= 'table' then return 'need_weapon' end
		end
		if chargesOf(id) < 1 then return 'register_empty' end
		return nil
	end
	spec.claim = function()
		state.charges = state.charges - 1
		saveTill(id)
	end
	spec.release = function()
		state.charges = math.min(entry.max, state.charges + 1)
		saveTill(id)
	end
	spec.onStart = function(op)
		speak(state.clerk, 'fear_beg')
		Alert.Raise('robbery', entry.label, entry, entry.alert, op.id)
	end
	spec.commit = function(op)
		local amount = Model.Roll(op.id, 'reward', entry.rewardMin, entry.rewardMax)
		local paid, short = Dirty.Mint(op.player, op.citizenId, amount, 'robbery', 'robbery:' .. id, op.at)
		if paid <= 0 then return false, short or 'unavailable' end
		robbedAt[op.citizenId] = OPX.Now()
		return true, short == 'mint_cap' and 'robbed_capped' or 'robbed', { store = id, paid = paid }
	end
	spec.after = function(op, ok, code, result)
		answer(op.player, ok, code, ok and { paid = result.paid } or nil)
	end
	local ok, code = Op.Begin(player, spec)
	-- `started` is the bar going up: the client says nothing, the bar does.
	return answer(player, ok, ok and 'started' or code)
end

--- A clerk shot dead: the alarm goes off at once, and the store is closed
--- until the clerk would have been replaced.
local function onNpcDied(npcId)
	local id = storeByClerk[npcKey(npcId)]
	if id == nil then return end
	local entry, state = built.stores.byId[id], stores[id]
	if state.clerkDeadAt ~= nil then return end
	state.clerkDeadAt = OPX.Now()
	state.charges, state.lastAt = 0, OPX.Now()
	saveTill(id)
	Alert.Raise('homicide', entry.label, entry, entry.alert, 'clerk:' .. id .. ':' .. tostring(OPX.Now()), true)
end

-- ── laundering ──────────────────────────────────────────────────────────────

local function frontOf(value)
	local id = idOf(value)
	return id and built.fronts.byId[id] or nil
end

local function frontAnchor(entry)
	return { x = entry.x, y = entry.y, z = entry.z, bucket = entry.bucket }
end

--- Everything a front checks before it talks: answers the loaded character.
local function atFront(player, entry)
	if entry == nil then return nil, 'no_front' end
	local loaded = Op.Character(player)
	if loaded == nil then return nil, 'no_character' end
	local passed, why = M.Allowed(entry, loaded)
	if not passed then return nil, why end
	local code = Op.Standing(player, frontAnchor(entry), entry.reach)
	if code ~= nil then return nil, code end
	return loaded
end

--- The counter of a front: what is cooking, what is left today. Yields.
-- @author dop42
function M.OpenFront(player, payload)
	if M.Limited(player) then return answer(player, false, 'too_fast') end
	local entry = frontOf(type(payload) == 'table' and payload.front or nil)
	local loaded, why = atFront(player, entry)
	if loaded == nil then return answer(player, false, why) end
	local deposited = Storage.DepositedToday(loaded.citizenId)
	local batches = Storage.Batches(loaded.citizenId, entry.id)
	if deposited == nil or batches == nil then return answer(player, false, 'unavailable') end
	local left = math.max(0, entry.dailyCap - deposited - (pendingLaunder[loaded.citizenId] or 0))
	local counted = inventory().GetItemCount(player, built.dirty.item)
	local held = type(counted) == 'table' and counted.ok and tonumber(counted.value) or 0
	local amounts = {}
	for _, amount in ipairs(built.launderAmounts) do
		if amount <= entry.perTxMax and amount <= left and amount <= held then amounts[#amounts + 1] = amount end
	end
	local all = math.min(entry.perTxMax, left, held)
	if all > 0 and amounts[#amounts] ~= all then amounts[#amounts + 1] = all end
	local rows = {}
	for _, batch in ipairs(batches) do
		rows[#rows + 1] = { clean = batch.clean, minutes = math.max(0, math.ceil(batch.remaining / 60)) }
	end
	TriggerClientEvent(M.Event.VIEW, player, { kind = 'front', front = entry.id, label = entry.label,
		rate = math.floor(entry.rate * 100 + 0.5), left = left, held = held, amounts = amounts, batches = rows })
	return true
end

--- Hands dirty eddies over to a front. Yields.
-- @author dop42
function M.Launder(player, payload)
	if M.Limited(player) then return answer(player, false, 'too_fast') end
	payload = type(payload) == 'table' and payload or {}
	local entry = frontOf(payload.front)
	local loaded, why = atFront(player, entry)
	if loaded == nil then return answer(player, false, why) end
	local amount = wanted(payload.amount, 1, entry.perTxMax)
	if amount == nil then return answer(player, false, 'bad_amount', { max = entry.perTxMax }) end
	local deposited = Storage.DepositedToday(loaded.citizenId)
	if deposited == nil then return answer(player, false, 'unavailable') end
	local citizen = loaded.citizenId
	local laundering = type(settings().LAUNDERING) == 'table' and settings().LAUNDERING or {}
	local clean = Model.Clean(amount, entry.rate)
	local spec = {
		kind = 'launder', loaded = loaded, anchor = frontAnchor(entry), reach = entry.reach,
		label = locale('underworld.bar.launder'),
		durationMs = Model.Integer(laundering.DEPOSIT_MS, 250, 60000) or 4000,
		animation = type(laundering.ANIMATION) == 'string' and laundering.ANIMATION or '',
		inputs = { items = { { name = built.dirty.item, count = amount } } },
	}
	spec.check = function(op, again)
		if again then return nil end
		if deposited + (pendingLaunder[citizen] or 0) + amount > entry.dailyCap then return 'daily_cap' end
		return nil
	end
	spec.claim = function() pendingLaunder[citizen] = (pendingLaunder[citizen] or 0) + amount end
	local function unclaim()
		local left = (pendingLaunder[citizen] or 0) - amount
		pendingLaunder[citizen] = left > 0 and left or nil
	end
	spec.release = unclaim
	spec.commit = function(op)
		local filed = Storage.InsertBatch(citizen, entry.id, amount, clean, entry.payout,
			math.floor(entry.batchMs / 1000))
		if not filed then return false, 'unavailable' end
		unclaim()
		return true, 'deposited', { front = entry.id, dirty = amount, clean = clean }
	end
	spec.after = function(op, ok, code)
		answer(op.player, ok, code, ok and { amount = amount, clean = clean,
			minutes = math.ceil(entry.batchMs / 60000) } or nil)
	end
	local ok, code = Op.Begin(player, spec)
	-- `started` is the bar going up: the client says nothing, the bar does.
	return answer(player, ok, ok and 'started' or code)
end

--- Collects every ready batch at a front. Yields.
-- @author dop42
function M.Collect(player, payload)
	if M.Limited(player) then return answer(player, false, 'too_fast') end
	if collecting[player] then return answer(player, false, 'busy') end
	local entry = frontOf(type(payload) == 'table' and payload.front or nil)
	local loaded, why = atFront(player, entry)
	if loaded == nil then return answer(player, false, why) end
	collecting[player] = true
	local total = 0
	local ok, failure = pcall(function()
		local batches = Storage.Batches(loaded.citizenId, entry.id) or {}
		for _, batch in ipairs(batches) do
			if batch.remaining <= 0 and Storage.Collect(batch.id, loaded.citizenId) then
				-- Marked collected FIRST, paid SECOND: a payout refused puts the
				-- mark back rather than paying a batch twice.
				local called, paid = pcall(character().AddMoney, player, batch.payout, batch.clean,
					'underworld:launder:' .. entry.id)
				if called and paid == true then
					total = total + batch.clean
					OPX.Audit.Log({ event = 'underworld.collect', citizenId = loaded.citizenId, source = player,
						message = ('batch %d at %s: %d %s'):format(batch.id, entry.id, batch.clean, batch.payout),
						data = { batch = batch.id, front = entry.id, clean = batch.clean } })
				else
					Storage.Uncollect(batch.id)
				end
			end
		end
	end)
	collecting[player] = nil
	if not ok then
		Open77.log.warn('[underworld] a collect raised: ' .. tostring(failure))
		return answer(player, false, 'unavailable')
	end
	if total <= 0 then return answer(player, false, 'nothing_ready') end
	return answer(player, true, 'collected', { amount = total })
end

-- ── staff ───────────────────────────────────────────────────────────────────

local function report(source)
	local lines = {}
	for _, kind in ipairs({ 'dealers', 'stores', 'fronts', 'labs' }) do
		for _, entry in ipairs(built[kind].list) do
			local extra = ''
			if kind == 'stores' and stores[entry.id] then
				extra = (' till=%d/%d'):format(chargesOf(entry.id), entry.max)
			elseif kind == 'dealers' and dealers[entry.id] then
				extra = dealers[entry.id].npc and (' at spot %d'):format(dealers[entry.id].spot) or ' absent'
			elseif kind == 'labs' and M.Drugs and M.Drugs.Heat then
				extra = (' heat=%d'):format(math.floor(M.Drugs.Heat(entry.id)))
			end
			local x, y, z = entry.x, entry.y, entry.z
			if kind == 'dealers' then x, y, z = entry.spots[1].x, entry.spots[1].y, entry.spots[1].z end
			lines[#lines + 1] = ('%s %s "%s" %.1f,%.1f,%.1f%s'):format(entry.kind, entry.id, entry.label, x, y, z, extra)
		end
	end
	for _, where in ipairs(placeholders) do lines[#lines + 1] = where .. ' DISABLED: not surveyed yet' end
	for _, line in ipairs(problems) do lines[#lines + 1] = 'REFUSED: ' .. line end
	lines[#lines + 1] = ('%d police on duty'):format(M.PoliceCount())
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

local CAPTURE_KINDS = { store = true, front = true, lab = true, dealer = true, clerk = true }

local function capture(source, args)
	if source <= 0 then return OPX.CommandResult(source, false, 'the console stands nowhere') end
	local kind, id = args[1], args[2]
	if type(kind) ~= 'string' or not CAPTURE_KINDS[kind] or idOf(id) == nil then
		return OPX.CommandResult(source, false, 'usage: capture <store|front|lab|dealer|clerk> <id>')
	end
	local at = Op.Point(source)
	if at == nil then return OPX.CommandResult(source, false, 'your position could not be read') end
	local line
	if kind == 'dealer' then
		line = ('%s SPOTS += { X = %.2f, Y = %.2f, Z = %.2f, YAW = 0.0 },'):format(id, at.x, at.y, at.z)
	elseif kind == 'clerk' then
		line = ('%s CLERK = { RECORD = ..., X = %.2f, Y = %.2f, Z = %.2f, YAW = 0.0 },'):format(id, at.x, at.y, at.z)
	else
		line = ('%s %s: X = %.2f, Y = %.2f, Z = %.2f, BUCKET = %d,'):format(kind, id, at.x, at.y, at.z, at.bucket)
	end
	OPX.Audit.Log({ event = 'underworld.capture', message = line, source = source })
	OPX.CommandResult(source, true, 'paste into config/underworld.lua, then restart:\n  ' .. line)
end

local function registerCommands()
	OPX.Command.Register(Command.LEDGER, { restricted = true, help = 'underworld.help.ledger',
		params = { { name = 'citizenId', help = locale('underworld.help.citizen') } } },
		function(source, args)
			local citizen = Storage.CitizenOf(args[1])
			if citizen == nil then return OPX.CommandResult(source, false, 'usage: ledger <citizenId>') end
			CreateThread(function()
				local rows, sum = Storage.LedgerOf(citizen)
				if rows == nil then return OPX.CommandResult(source, false, 'the ledger could not be read') end
				local lines = { ('%s holds %d dirty eddies by the ledger'):format(citizen, math.floor(sum)) }
				for _, row in ipairs(rows) do
					lines[#lines + 1] = ('%s %+d %s'):format(tostring(row.ts), math.floor(tonumber(row.amount) or 0),
						tostring(row.source))
				end
				OPX.CommandResult(source, true, table.concat(lines, '\n'))
			end)
		end)
	OPX.Command.Register(Command.SITES, { restricted = true, help = 'underworld.help.sites' },
		function(source) report(source) end)
	OPX.Command.Register(Command.CAPTURE, { restricted = true, help = 'underworld.help.capture',
		params = {
			{ name = 'kind', help = locale('underworld.help.kind') },
			{ name = 'id', help = locale('underworld.help.id') },
		} },
		function(source, args) capture(source, args) end)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state. Never yields.
-- @author dop42
function M.Init()
	built, problems, placeholders = Model.Build(M.Settings)
	M.Built = built
	windows, minted, dealers, dealerByNpc, stores, storeByClerk = {}, {}, {}, {}, {}, {}
	robbedAt, pendingLaunder, collecting, told, jobs = {}, {}, {}, {}, {}
	for _, entry in ipairs(built.dealers.list) do
		local stock = {}
		for index, line in ipairs(entry.stock) do stock[index] = OPX.Table.DeepCopy(line) end
		dealers[entry.id] = { entry = entry, spot = 1, stock = stock, rotatedAt = 0 }
	end
	for _, entry in ipairs(built.stores.list) do
		stores[entry.id] = { charges = entry.max, lastAt = OPX.Now() }
	end
	Op.Init()
	if M.Drugs and M.Drugs.Init then M.Drugs.Init() end
	OPX.Schema.Add(Storage.SCHEMA)
end

--- Publishes the server contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('underworld', 1, {
		--- The item a dirty eddie is.
		DirtyItem = Dirty.Item,
		--- Pays dirty eddies for a crime another resource runs, under the cap.
		--- `(player, amount, kind, source)` -> paid, why. Yields.
		MintDirty = function(player, amount, kind, source)
			local loaded = Op.Character(player)
			if loaded == nil then return 0, 'no_character' end
			return Dirty.Mint(player, loaded.citizenId, amount, tostring(kind or 'corner'),
				'ext:' .. tostring(source or 'unknown'), Op.Point(player))
		end,
		--- Raises an alarm the way a robbery does.
		Alert = function(kind, label, at, alert, seed)
			return Alert.Raise(tostring(kind), tostring(label), at, Model.AlertOf(alert, settings().ALERT),
				tostring(seed or OPX.Now()))
		end,
		PoliceCount = M.PoliceCount,
		--- A till's charges now.
		Charges = function(storeId)
			return stores[storeId] ~= nil and chargesOf(storeId) or nil
		end,
		--- Begins a valued action with the op helper (see server/op.lua).
		BeginOp = Op.Begin,
		Heat = function(labId) return M.Drugs and M.Drugs.Heat and M.Drugs.Heat(labId) or nil end,
	})
end

local function onNet(name, handler, threaded)
	RegisterNetEvent(name, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		if threaded then
			-- A bag or a database read yields, and a net handler that yields
			-- holds the event pump.
			CreateThread(function() handler(player, payload) end)
		else
			handler(player, payload)
		end
	end)
end

--- Wires the doors, the NPCs and the loops. On a coroutine.
-- @author dop42
function M.Start()
	for _, line in ipairs(problems) do Open77.log.warn('[underworld] config: ' .. line) end
	if #placeholders > 0 then
		Open77.log.info(('[underworld] %d entr(ies) disabled until surveyed (/opx.underworld.capture): %s')
			:format(#placeholders, table.concat(placeholders, ', ')))
	end

	if M.Drugs and M.Drugs.Start then M.Drugs.Start() end

	-- The tills as the last run left them, then the escrow it left open.
	CreateThread(function()
		local saved = Storage.Registers()
		for id, row in pairs(saved) do
			local entry, state = built.stores.byId[id], stores[id]
			if entry ~= nil and state ~= nil and tonumber(row.charges) ~= nil then
				state.charges = math.max(0, math.min(entry.max, math.floor(row.charges)))
				state.lastAt = OPX.Now() - row.age * 1000
			end
		end
		Op.Recover()
	end)

	for _, entry in ipairs(built.stores.list) do
		if entry.clerk ~= nil then
			local state = stores[entry.id]
			state.clerk = spawnNpc(entry.clerk.record, entry.clerk, entry.clerk.yaw, entry.bucket, true)
			state.clerkKey = state.clerk and npcKey(state.clerk) or nil
			if state.clerkKey then storeByClerk[state.clerkKey] = entry.id end
		end
	end

	onNet(M.Event.HELLO, function(player)
		if M.Limited(player) then return end
		told[player] = true
		TriggerClientEvent(M.Event.DEALERS, player, dealerList())
	end)
	onNet(M.Event.DEALER, M.OpenDealer, true)
	onNet(M.Event.BUY, M.Buy, true)
	onNet(M.Event.SELL, M.Sell, true)
	onNet(M.Event.ROB, M.Rob, true)
	onNet(M.Event.FRONT, M.OpenFront, true)
	onNet(M.Event.LAUNDER, M.Launder, true)
	onNet(M.Event.COLLECT, M.Collect, true)

	AddEventHandler('onNpcDied', function(npcId) onNpcDied(npcId) end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(raw)
		local player = math.tointeger(tonumber(raw))
		if player == nil then return end
		windows[player], told[player], collecting[player] = nil, nil, nil
	end)

	Op.Start()
	registerCommands()
	jobs[#jobs + 1] = OPX.Scheduler.Every('underworld:dealers', 15000, dealerStep)
	dealerStep()
end

--- Takes every NPC out of the world and lets the ops go.
-- @author dop42
function M.Stop()
	for _, job in ipairs(jobs) do pcall(OPX.Scheduler.Cancel, job) end
	jobs = {}
	Op.Stop()
	if M.Drugs and M.Drugs.Stop then M.Drugs.Stop() end
	for _, state in pairs(dealers) do removeNpc(state.npc); state.npc, state.key = nil, nil end
	for _, state in pairs(stores) do removeNpc(state.clerk); state.clerk = nil end
	dealerByNpc, storeByClerk = {}, {}
end
