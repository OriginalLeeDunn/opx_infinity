--- Server half: repairs, the roadside kit, the board, the tow and the lot.
-- @author dop42
--
-- EVERY DECISION IS HERE. The client sends a wish -- fix this car, tow this
-- car, open the parts room, what of mine is impounded, list the calls -- and
-- each is judged again from scratch: who the sender is (job, grade, duty, from
-- the character roster, never from the payload), where they stand and where the
-- car stands (the host's positions, never theirs), what is broken (the host's
-- damage, never the client's), what is in the stash, the bag and the account.
--
-- A REPAIR IS THE WORLD-INTERACTION SHAPE on this resource's own economy, the
-- one `medical` and `underworld` follow: check before the work (job, bay, reach,
-- damage, parts, the customer's money), let the server's clock run the bar,
-- check AGAIN when it ends (the car may have driven off, the mechanic clocked
-- off, the stash been emptied), then commit -- parts out first, the customer's
-- money second, the engine repair third -- and give back what was taken when a
-- later step is refused. A bar that ends early has taken nothing.
--
-- THE TOW never writes a vehicle row: `vehicles.SetState` is the impound door,
-- and it refuses a car with somebody in it on its own.

local M = OPX.Modules.Get('mechanic')

local Model = M.Model
local Dispatch = M.Dispatch
local Event = M.Event
local Mode = M.Mode
local CallKind = M.CallKind
local Result = OPX.Result

local OWNER = M.OWNER

-- Metres a vehicle may roll during a bar before the work is called off.
local MOVE_TOLERANCE = 1.5
-- The most calls a board view carries.
local BOARD_ROWS = 32

local settings
-- player -> the job they are doing; vehicle id (text) -> the player on it.
local busy, working = {}, {}
-- player:kind -> last request time.
local lastRequest = {}
local registeredCommands = false

local function config()
	if settings == nil then settings = Model.Settings(OPX.Config.MODULES.mechanic) end
	return settings
end

-- ── the contracts ────────────────────────────────────────────────────────────

local function character() return OPX.Api.Get('character') end
local function inventory() return OPX.Api.Get('inventory') end
local function vehicles() return OPX.Api.Get('vehicles') end

-- ── reading the world ────────────────────────────────────────────────────────

local function positionOf(player)
	local read, at = pcall(Open77.players.position, player)
	if not read or type(at) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(at.x), OPX.Math.Finite(at.y), OPX.Math.Finite(at.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.floor(OPX.Math.Finite(at.bucket) or 0) }
end

local function playerIds()
	local read, players = pcall(Open77.players.all)
	local ids = {}
	for _, value in ipairs(read and type(players) == 'table' and players or {}) do
		local id = math.tointeger(tonumber(value))
		if id and id > 0 then ids[#ids + 1] = id end
	end
	return ids
end

local function gapSq(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- Whether two points are within a reach, the shared slack included, one bucket.
local function within(a, b, reach)
	if a == nil or b == nil or (a.bucket or 0) ~= (b.bucket or 0) then return false end
	local limit = OPX.Spots.ServerReach(reach)
	return gapSq(a, b) <= limit * limit
end

local function loaded(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, value = pcall(api.GetPlayer, player)
	if not read or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return value.PlayerData
end

local function citizenOf(player)
	local data = loaded(player)
	return data and type(data.citizenId) == 'string' and data.citizenId or nil
end

-- Whether a player is sitting in a vehicle, as the host's seat ledger says.
local function seated(player)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.getVehicleSeat) ~= 'function' then return false end
	local read, assignment = pcall(players.getVehicleSeat, player)
	return read and type(assignment) == 'table' and assignment.vehicleId ~= nil
end

-- One JOBS gate on one player, by the shared rule.
local function gate(player, jobs, onDuty, minGrade)
	local data = loaded(player)
	if data == nil then return false, 'no_character' end
	jobs = Model.Jobs(jobs, minGrade)
	if type(jobs) ~= 'table' or next(jobs) == nil then return false, 'job_required' end
	local now = OPX.Now()
	return OPX.JobGate.Evaluate({ jobs = jobs, onDuty = onDuty },
		{ job = data.job, jobs = data.jobs, atMs = now }, now,
		{ maxAgeMs = 0, membership = config().membership })
end

-- Whether a player works at one shop at a grade.
local function memberOf(player, shop, minGrade)
	return gate(player, shop.jobs, shop.onDuty, minGrade)
end

-- Whether a player works at any shop at a grade. Answers the closest refusal.
local function isMechanic(player, minGrade, requireDuty)
	local worst = 'not_mechanic'
	for _, key in ipairs(config().shopOrder) do
		local shop = config().shops[key]
		local ok, why
		if requireDuty then ok, why = gate(player, shop.jobs, true, minGrade)
		else ok, why = memberOf(player, shop, minGrade) end
		if ok then return true end
		if why == 'off_duty' or (why == 'grade_too_low' and worst ~= 'off_duty') then worst = why end
	end
	return false, worst
end

local function balanceOf(player, moneyType)
	local api = character()
	if api == nil or type(api.GetMoney) ~= 'function' then return 0 end
	local read, value = pcall(api.GetMoney, player, moneyType)
	return read and (math.tointeger(OPX.Math.Finite(value) or 0) or 0) or 0
end

local function charge(player, moneyType, amount, reason)
	if amount <= 0 then return true end
	local api = character()
	if api == nil or type(api.RemoveMoney) ~= 'function' then return false end
	local read, ok = pcall(api.RemoveMoney, player, moneyType, amount, reason)
	return read and ok == true
end

local function pay(player, moneyType, amount, reason)
	if amount <= 0 then return true end
	local api = character()
	if api == nil or type(api.AddMoney) ~= 'function' then return false end
	local read, ok = pcall(api.AddMoney, player, moneyType, amount, reason)
	return read and ok == true
end

--- Pays the character who earned or advanced the money, even after a slot change.
local function payCharacter(citizenId, moneyType, amount, reason)
	if amount <= 0 then return true end
	local api = character()
	if api ~= nil and type(api.GetPlayerByCitizenId) == 'function' then
		local read, player = pcall(api.GetPlayerByCitizenId, citizenId)
		if read and player ~= nil then return pay(citizenId, moneyType, amount, reason) end
	end
	if api ~= nil and type(api.AddMoneyOffline) == 'function' then
		local read, receipt = pcall(api.AddMoneyOffline, citizenId, moneyType, amount, reason)
		return read and type(receipt) == 'table' and receipt.ok == true
	end
	return pay(citizenId, moneyType, amount, reason)
end

-- ── vehicles ─────────────────────────────────────────────────────────────────

local function snapshotOf(id)
	local api = Open77.vehicles
	if id == nil or type(api) ~= 'table' or type(api.get) ~= 'function' then return nil end
	local read, snapshot = pcall(api.get, id)
	return read and type(snapshot) == 'table' and snapshot or nil
end

-- A snapshot's position and bucket, from `x/y/z` or `position`, or nil.
local function placeOf(snapshot)
	local x, y, z = OPX.Math.Finite(snapshot.x), OPX.Math.Finite(snapshot.y), OPX.Math.Finite(snapshot.z)
	if (x == nil or y == nil or z == nil) and type(snapshot.position) == 'table' then
		x, y, z = OPX.Math.Finite(snapshot.position.x), OPX.Math.Finite(snapshot.position.y),
			OPX.Math.Finite(snapshot.position.z)
	end
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(OPX.Math.Finite(snapshot.bucket)) or 0 }
end

-- The id hint a client sent, as text, or nil when absent or malformed.
local function hintOf(value)
	if math.type(value) == 'integer' then return tostring(value) end
	if type(value) ~= 'string' or #value < 1 or #value > 32 or value:find('%s') then return nil end
	return value
end

--- The nearest canonical vehicle to a point within a radius in one bucket, or
--- nil; only the hinted one when a hint is given. A walk over `vehicles.all`
--- as `fuel` does it: the server has no instruction budget.
local function nearestVehicle(at, radius, wanted, accept)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.all) ~= 'function' then return nil end
	local read, list = pcall(api.all)
	if not read or type(list) ~= 'table' then return nil end
	local best, bestGap
	local limit = OPX.Spots.ServerReach(radius)
	for index = 1, #list do
		local snapshot = list[index]
		if type(snapshot) == 'table' and snapshot.id ~= nil
			and (wanted == nil or tostring(snapshot.id) == wanted)
			and (accept == nil or accept(snapshot)) then
			local place = placeOf(snapshot)
			if place ~= nil and place.bucket == at.bucket then
				local gap = gapSq(at, place)
				if gap <= limit * limit and (bestGap == nil or gap < bestGap) then
					best, bestGap = snapshot, gap
				end
			end
		end
	end
	return best
end

local function healthOf(snapshot)
	local health = OPX.Math.Finite(snapshot.health)
	if health == nil and type(Open77.vehicles.getHealth) == 'function' then
		local read, value = pcall(Open77.vehicles.getHealth, snapshot.id)
		health = read and OPX.Math.Finite(value) or nil
	end
	return health
end

local function damageOf(snapshot)
	if type(Open77.vehicles.getDamage) ~= 'function' then return nil end
	local read, damage = pcall(Open77.vehicles.getDamage, snapshot.id)
	return read and type(damage) == 'table' and damage or nil
end

local function occupied(snapshot)
	local occupants = snapshot.occupants
	return type(occupants) == 'table' and #occupants > 0
end

-- The shop and bay a vehicle stands in, among the shops a player works at.
local function bayOf(player, place)
	for _, key in ipairs(config().shopOrder) do
		local shop = config().shops[key]
		if memberOf(player, shop, config().repair.minGrade) then
			for _, bay in ipairs(shop.bays) do
				if within(place, { x = bay.x, y = bay.y, z = bay.z, bucket = place.bucket }, bay.radius) then
					return shop, bay
				end
			end
		end
	end
	return nil
end

-- The player to bill for a repair: the car's owner when they stand near, else
-- the nearest other loaded player near the mechanic, else nil.
local function customerOf(mechanic, snapshot)
	local here = positionOf(mechanic)
	if here == nil then return nil end
	local reach = config().customerReach
	local api, owner = vehicles(), nil
	if api ~= nil and type(api.PlateOf) == 'function' then
		local read, _, citizenId = pcall(api.PlateOf, snapshot.id)
		local roster = character()
		if read and type(citizenId) == 'string' and roster ~= nil
			and type(roster.GetPlayerByCitizenId) == 'function' then
			local found, player = pcall(roster.GetPlayerByCitizenId, citizenId)
			if found and type(player) == 'table' and type(player.PlayerData) == 'table' then
				owner = math.tointeger(player.PlayerData.source)
			end
		end
	end
	if owner ~= nil and owner ~= mechanic and within(here, positionOf(owner), reach) then return owner end
	local best, bestGap
	for _, player in ipairs(playerIds()) do
		if player ~= mechanic and loaded(player) ~= nil then
			local there = positionOf(player)
			if within(here, there, reach) then
				local gap = gapSq(here, there)
				if bestGap == nil or gap < bestGap then best, bestGap = player, gap end
			end
		end
	end
	return best
end

-- ── items ────────────────────────────────────────────────────────────────────

local function carried(player, name)
	local api = inventory()
	if api == nil or type(api.GetItemCount) ~= 'function' then return 0 end
	local read, counted = pcall(api.GetItemCount, player, name)
	if not read or type(counted) ~= 'table' or not counted.ok then return 0 end
	return math.tointeger(counted.value) or 0
end

local function stocked(shop, name)
	local api = inventory()
	if shop == nil or api == nil or type(api.CountInStash) ~= 'function' then return 0 end
	local read, counted = pcall(api.CountInStash, shop.stashKey, name)
	if not read or type(counted) ~= 'table' or not counted.ok then return 0 end
	return math.tointeger(counted.value) or 0
end

-- Where `count` parts come from: the shop's stash first, the bag second, or nil.
local function partsSource(player, shop, count)
	if count <= 0 then return 'none' end
	local name = config().parts.name
	if stocked(shop, name) >= count then return 'stash' end
	if carried(player, name) >= count then return 'bag' end
	return nil
end

local function takeParts(player, shop, source, count)
	if source == 'none' then return true end
	local api = inventory()
	if api == nil then return false end
	local name = config().parts.name
	local read, removed
	if source == 'stash' then
		read, removed = pcall(api.RemoveFromStash, shop.stashKey, name, count)
	else
		read, removed = pcall(api.RemoveItem, player, name, count)
	end
	return read and type(removed) == 'table' and removed.ok == true
end

local function giveParts(player, shop, source, count)
	if source == 'none' then return end
	local api = inventory()
	if api == nil then return end
	local name = config().parts.name
	if source == 'stash' then
		pcall(api.AddToStash, shop.stashKey, name, count)
	else
		pcall(api.AddItem, player, name, count)
	end
end

-- ── answers ──────────────────────────────────────────────────────────────────

local function answer(player, ok, code, extra)
	local payload = type(extra) == 'table' and extra or {}
	payload.ok, payload.code = ok == true, code
	TriggerClientEvent(Event.ANSWER, player, payload)
	return ok
end

local function cooled(player, kind)
	local slot = player .. ':' .. kind
	local now = OPX.Now()
	if lastRequest[slot] ~= nil and now - lastRequest[slot] < config().requestMs then return true end
	lastRequest[slot] = now
	return false
end

local function audit(event, player, ok, message, data)
	OPX.Audit.Log({ event = event, severity = ok and 'info' or 'warn', source = player,
		message = message, data = data })
end

-- ── the bar ──────────────────────────────────────────────────────────────────

local function release(job)
	if busy[job.player] == job then busy[job.player] = nil end
	if working[job.vehicleKey] == job then working[job.vehicleKey] = nil end
end

local commit

-- Ends one job. Every way it can end comes through here exactly once.
local function finish(job, completed, ending)
	if job.done then return end
	job.done = true
	if ending == 'left' or loaded(job.player) ~= job.playerData then release(job); return end
	if not completed then release(job); return answer(job.player, false, 'interrupted') end
	-- On a thread: the commit reads and writes the bag, the stash, the account
	-- and the vehicle row, and every one of those may yield.
	CreateThread(function()
		if loaded(job.player) ~= job.playerData then release(job); return end
		local ok, failure = pcall(commit, job)
		release(job)
		if not ok then
			Open77.log.error(('[mechanic] the %s of player %d raised: %s'):format(job.kind, job.player,
				tostring(failure)))
			answer(job.player, false, 'unavailable')
		end
	end)
end

local function maxBarMs()
	local progress = OPX.Config.MODULES.progress
	return math.tointeger(progress and progress.MAX_MS) or 60000
end

-- Puts up the server-timed bar for a job. Answers nil, or the refusal code.
local function startBar(job, label, durationMs, animationName)
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then return 'no_bar' end
	job.playerData = job.playerData or loaded(job.player)
	if job.playerData == nil or loaded(job.player) ~= job.playerData then return 'no_character' end
	busy[job.player], working[job.vehicleKey] = job, job
	local started = progress.Start(job.player, OWNER, {
		label = locale(label),
		durationMs = math.min(durationMs, maxBarMs()),
		cancelable = true,
		animation = animationName and { name = animationName, fallback = 'examine' } or nil,
	}, function(_, outcome)
		finish(job, type(outcome) == 'table' and outcome.completed == true,
			type(outcome) == 'table' and outcome.ending or nil)
	end)
	if type(started) ~= 'table' or not started.ok then
		release(job)
		return type(started) == 'table' and started.error == 'progress_busy' and 'busy' or 'no_bar'
	end
	job.barId = type(started.value) == 'table' and started.value.id or nil
	return nil
end

-- What every job asks before anything else. Answers the player's point, or nil
-- and the code.
local function ready(player)
	if OPX.Life.Down(player) then return nil, 'player_down' end
	if loaded(player) == nil then return nil, 'no_character' end
	if busy[player] ~= nil then return nil, 'busy' end
	if seated(player) then return nil, 'leave_vehicle' end
	local at = positionOf(player)
	if at == nil then return nil, 'no_position' end
	return at
end

-- Whether the car of a job is still where the job left it, and the worker by it.
local function stillThere(job)
	if loaded(job.player) ~= job.playerData then return nil, 'no_character' end
	local snapshot = snapshotOf(job.vehicleId)
	if snapshot == nil then return nil, 'vehicle_gone' end
	local place = placeOf(snapshot)
	if place == nil then return nil, 'vehicle_gone' end
	local tolerance = MOVE_TOLERANCE
	if place.bucket ~= job.origin.bucket or gapSq(place, job.origin) > tolerance * tolerance then
		return nil, 'vehicle_moved'
	end
	if not within(positionOf(job.player), place, config().reach) then return nil, 'too_far' end
	return snapshot
end

-- ── repairs ──────────────────────────────────────────────────────────────────

-- The engine work. Answers true, or false when the platform refused it (a car
-- another resource owns).
local function fixFull(vehicleId)
	local api = Open77.vehicles
	local read, ok = pcall(api.repair, vehicleId, 'full')
	if not read or ok ~= true then return false end
	if type(api.setHealth) == 'function' then pcall(api.setHealth, vehicleId, 1.0) end
	return true
end

local function fixKit(vehicleId, health, scopes)
	local api = Open77.vehicles
	if type(api.setHealth) ~= 'function' then return false end
	local read, ok = pcall(api.setHealth, vehicleId, health)
	if not read or ok ~= true then return false end
	for _, scope in ipairs(scopes) do pcall(api.repair, vehicleId, scope) end
	return true
end

-- Bills a finished workshop repair whose money was not taken up front: through
-- `invoices`. Answers whether an invoice went out.
local function invoice(job)
	local invoices = OPX.Api.Get('invoices')
	if invoices == nil or type(invoices.Issue) ~= 'function' then return false end
	local read, issued = pcall(invoices.Issue, {
		issuer = job.player, target = job.customer, amount = job.quote.fee,
		reason = locale('mechanic.bill.reason', { shop = job.shop.label }),
		account = job.shop.account and { kind = 'job', key = job.shop.account } or nil,
		cutPct = config().billing.cutPct, source = 'mechanic',
	})
	return read and type(issued) == 'table' and issued.ok == true
end

-- Hands out money a customer paid directly: the cut to the mechanic, the share
-- to the shop's account, or everything to the mechanic without `accounts`.
-- Answers what the mechanic earned.
local function distribute(job, paid)
	local cut, share = Model.Split(paid, config().billing.cutPct)
	local moneyType = config().billing.moneyType
	local accounts = OPX.Api.Get('accounts')
	local reason = ('mechanic:%s:repair'):format(job.shop.key)
	if share > 0 and accounts ~= nil and type(accounts.Deposit) == 'function' and job.shop.account then
		local read, deposited = pcall(accounts.Deposit, 'job', job.shop.account, share, reason,
			('mechanic:repair:%d:%d'):format(job.player, OPX.Now()))
		if not (read and type(deposited) == 'table' and deposited.ok) then cut = cut + share end
	else
		cut = cut + share
	end
	payCharacter(job.playerData.citizenId, moneyType, cut, reason .. ':cut')
	return cut
end

local function commitShop(job)
	if not memberOf(job.player, job.shop, config().repair.minGrade) then
		return answer(job.player, false, 'not_mechanic')
	end
	local snapshot, why = stillThere(job)
	if snapshot == nil then return answer(job.player, false, why) end
	local count = job.quote.parts
	local worker = job.playerData.citizenId
	local source = partsSource(worker, job.shop, count)
	if source == nil or not takeParts(worker, job.shop, source, count) then
		return answer(job.player, false, 'no_parts', { count = count })
	end
	-- Bag and stash calls may resume after the worker changed character or moved.
	snapshot, why = stillThere(job)
	if snapshot == nil or OPX.Life.Down(job.player) or seated(job.player)
		or not memberOf(job.player, job.shop, config().repair.minGrade) then
		giveParts(worker, job.shop, source, count)
		return answer(job.player, false, why or 'interrupted')
	end
	local fee, billed = job.quote.fee, 'none'
	local customer = job.customer
	if customer ~= nil and loaded(customer) ~= job.customerData then customer = nil end
	-- The payer agreed to the work on this character. A slot reused during the
	-- bar must never become its invoice target or direct debit.
	job.customer = customer
	local invoices = OPX.Api.Get('invoices')
	-- WITHOUT INVOICES THE MONEY MOVES BEFORE THE CAR IS FIXED: the customer had
	-- the whole bar to empty their account, and a fix already done cannot be taken
	-- back.
	if customer ~= nil and fee > 0 and (invoices == nil or type(invoices.Issue) ~= 'function') then
		if not charge(job.customerData.citizenId, config().billing.moneyType, fee, ('mechanic:%s:repair'):format(job.shop.key)) then
			giveParts(worker, job.shop, source, count)
			return answer(job.player, false, 'customer_cannot_pay')
		end
		billed = 'paid'
	end
	-- Money hooks can yield too. Refund the original payer, never the reused slot.
	snapshot, why = stillThere(job)
	if snapshot == nil or OPX.Life.Down(job.player) or seated(job.player)
		or not memberOf(job.player, job.shop, config().repair.minGrade)
		or (customer ~= nil and loaded(customer) ~= job.customerData) then
		giveParts(worker, job.shop, source, count)
		if billed == 'paid' then
			payCharacter(job.customerData.citizenId, config().billing.moneyType, fee, 'mechanic:refund')
		end
		return answer(job.player, false, why or 'interrupted')
	end
	if not fixFull(job.vehicleId) then
		giveParts(worker, job.shop, source, count)
		if billed == 'paid' then
			payCharacter(job.customerData.citizenId, config().billing.moneyType, fee, 'mechanic:refund')
		end
		audit('mechanic.repair', job.player, false, 'the platform refused the repair of ' .. job.vehicleKey)
		return answer(job.player, false, 'not_ours')
	end
	local earned = 0
	if billed == 'paid' then
		earned = distribute(job, fee)
		OPX.NotifyLocale(customer, 'mechanic.customer.paid',
			{ shop = job.shop.label, amount = OPX.Locale.Money(fee, config().billing.moneyType) }, 'info')
	elseif customer ~= nil and fee > 0 then
		billed = invoice(job) and 'invoiced' or 'unbilled'
	end
	audit('mechanic.repair', job.player, true, ('%s at %s: %d%% for %d (%s), %d part(s) from %s'):format(
		job.vehicleKey, job.shop.key, job.missing, fee, billed, count, source),
		{ shop = job.shop.key, fee = fee, billed = billed, parts = count, source = source })
	OPX.Publish(Event.ON_REPAIRED, job.player, {
		mode = Mode.SHOP, shop = job.shop.key, vehicleId = job.vehicleKey, missing = job.missing,
		fee = fee, billed = billed, mechanic = citizenOf(job.player),
		customer = customer and citizenOf(customer) or nil,
	})
	answer(job.player, true, 'repaired', { fee = fee, billed = billed, earned = earned,
		moneyType = config().billing.moneyType })
end

local function commitKit(job)
	local snapshot, why = stillThere(job)
	if snapshot == nil then return answer(job.player, false, why) end
	local api = inventory()
	local name = config().kitItem.name
	local worker = job.playerData.citizenId
	if api == nil or carried(worker, name) < 1 then return answer(job.player, false, 'no_kit') end
	local read, removed = pcall(api.RemoveItem, worker, name, 1)
	if not read or type(removed) ~= 'table' or not removed.ok then return answer(job.player, false, 'no_kit') end
	snapshot, why = stillThere(job)
	if snapshot == nil or OPX.Life.Down(job.player) or seated(job.player) then
		pcall(api.AddItem, worker, name, 1)
		return answer(job.player, false, why or 'interrupted')
	end
	local target = Model.KitHealth(config(), healthOf(snapshot), job.mechanic)
	if not fixKit(job.vehicleId, target, config().kit.scopes) then
		pcall(api.AddItem, worker, name, 1)
		return answer(job.player, false, 'not_ours')
	end
	audit('mechanic.kit', job.player, true, ('%s patched to %.2f'):format(job.vehicleKey, target))
	OPX.Publish(Event.ON_REPAIRED, job.player, { mode = Mode.KIT, vehicleId = job.vehicleKey,
		missing = job.missing, health = target, mechanic = citizenOf(job.player) })
	answer(job.player, true, 'patched', { percent = math.floor(target * 100 + 0.5) })
end

--- Reads one nearby car for an on-duty mechanic; no owner or bag leaves the server.
local function onDiagnose(player, payload)
	local at, why = ready(player)
	if at == nil then return answer(player, false, why) end
	local permitted = false
	for _, key in ipairs(config().shopOrder) do
		if gate(player, config().shops[key].jobs, true, config().repair.minGrade) then
			permitted = true
			break
		end
	end
	if not permitted then return answer(player, false, 'not_mechanic') end
	local id = type(payload) == 'table' and hintOf(payload.vehicleId) or nil
	if id == nil then return answer(player, false, 'vehicle_far') end
	local vehicleId = math.tointeger(tonumber(id))
	if vehicleId == nil or vehicleId < 1 then return answer(player, false, 'vehicle_far') end
	local snapshot = snapshotOf(vehicleId)
	local place = snapshot and placeOf(snapshot) or nil
	if place == nil or not within(at, place, config().reach) then return answer(player, false, 'vehicle_far') end
	local report = Model.Diagnostic(healthOf(snapshot), damageOf(snapshot), snapshot)
	local quote = Model.Quote(config(), report.missing, maxBarMs())
	report.quote = report.missing > 0 and quote or { fee = 0, parts = 0, durationMs = 0 }
	report.moneyType = config().billing.moneyType
	report.inBay = bayOf(player, place) ~= nil
	TriggerClientEvent(Event.DIAGNOSTIC_VIEW, player, report)
end

-- Explicit state rather than a toggle: retries cannot reverse the request.
local function onHood(player, payload)
	local at, why = ready(player)
	if at == nil then return answer(player, false, why) end
	local permitted, refusal = isMechanic(player, config().repair.minGrade, true)
	if not permitted then return answer(player, false, refusal) end
	if type(payload) ~= 'table' or type(payload.opened) ~= 'boolean' then
		return answer(player, false, 'unavailable')
	end
	local id = hintOf(payload.vehicleId)
	local vehicleId = id and math.tointeger(tonumber(id))
	local snapshot = vehicleId and vehicleId > 0 and snapshotOf(vehicleId) or nil
	local place = snapshot and placeOf(snapshot)
	if not place or not within(at, place, config().reach) then return answer(player, false, 'vehicle_far') end
	if bayOf(player, place) == nil then return answer(player, false, 'not_in_bay') end
	if working[tostring(vehicleId)] then return answer(player, false, 'vehicle_busy') end
	if occupied(snapshot) then return answer(player, false, 'occupied') end
	local native = Open77.vehicles
	if type(native.setDoorOpen) ~= 'function' then return answer(player, false, 'unavailable') end
	-- Only the hood (documented index 5), never a client-selected door or mask.
	local ran, ok = pcall(native.setDoorOpen, vehicleId, 5, payload.opened)
	if not ran or ok ~= true then return answer(player, false, 'not_ours') end
	answer(player, true, payload.opened and 'hood_opened' or 'hood_closed')
end

local function onRepair(player, payload)
	if type(payload) ~= 'table' then payload = {} end
	local mode = payload.mode == Mode.KIT and Mode.KIT or Mode.SHOP
	local at, why = ready(player)
	if at == nil then return answer(player, false, why) end
	if mode == Mode.KIT and not config().kit.enabled then return answer(player, false, 'no_kit') end

	local snapshot = nearestVehicle(at, config().reach, hintOf(payload.vehicleId))
	if snapshot == nil then return answer(player, false, 'vehicle_far') end
	local vehicleKey = tostring(snapshot.id)
	if working[vehicleKey] ~= nil then return answer(player, false, 'vehicle_busy') end
	if occupied(snapshot) then return answer(player, false, 'occupied') end
	local place = placeOf(snapshot)
	local missing = Model.Missing(healthOf(snapshot), damageOf(snapshot))
	if missing <= 0 then return answer(player, false, 'not_damaged') end

	local job = { player = player, vehicleId = snapshot.id, vehicleKey = vehicleKey, origin = place,
		missing = missing, kind = mode, playerData = loaded(player) }
	if mode == Mode.KIT then
		if carried(player, config().kitItem.name) < 1 then return answer(player, false, 'no_kit') end
		job.mechanic = isMechanic(player, 0) == true
		local code = startBar(job, 'mechanic.bar.kit', config().kit.durationMs, config().kit.animation)
		if code ~= nil then return answer(player, false, code) end
		return answer(player, true, 'started')
	end

	local mechanic, refusal = isMechanic(player, config().repair.minGrade)
	if not mechanic then return answer(player, false, refusal) end
	local shop = bayOf(player, place)
	if shop == nil then return answer(player, false, 'not_in_bay') end
	local quote = Model.Quote(config(), missing, maxBarMs())
	if partsSource(player, shop, quote.parts) == nil then
		return answer(player, false, 'no_parts', { count = quote.parts })
	end
	local customer = customerOf(player, snapshot)
	if customer == nil and config().billing.noCustomer == 'refuse' then
		return answer(player, false, 'no_customer')
	end
	local invoices = OPX.Api.Get('invoices')
	if customer ~= nil and quote.fee > 0 and (invoices == nil or type(invoices.Issue) ~= 'function')
		and balanceOf(customer, config().billing.moneyType) < quote.fee then
		return answer(player, false, 'customer_cannot_pay', { fee = quote.fee,
			moneyType = config().billing.moneyType })
	end
	job.shop, job.quote, job.customer = shop, quote, customer
	job.customerData = customer and loaded(customer) or nil
	local code = startBar(job, 'mechanic.bar.repair', quote.durationMs, config().repair.animation)
	if code ~= nil then return answer(player, false, code) end
	answer(player, true, 'started', { fee = quote.fee, count = quote.parts })
end

-- ── the tow ──────────────────────────────────────────────────────────────────

local function mayImpound(player)
	return gate(player, config().impound.jobs, config().impound.onDuty, 0)
end

-- Whether a tow truck stands near a vehicle, when the config asks for one.
local function truckNear(place, vehicleKey)
	if next(config().impound.towRecords) == nil then return true end
	return nearestVehicle(place, config().impound.towReach, nil, function(snapshot)
		return tostring(snapshot.id) ~= vehicleKey and config().impound.towRecords[snapshot.record] == true
	end) ~= nil
end

local function plateOf(vehicleId)
	local api = vehicles()
	if api == nil or type(api.PlateOf) ~= 'function' then return nil end
	local read, plate, citizenId = pcall(api.PlateOf, vehicleId)
	if not read or type(plate) ~= 'string' then return nil end
	return plate, citizenId
end

local function commitImpound(job)
	if not mayImpound(job.player) then return answer(job.player, false, 'not_authorised') end
	local snapshot, why = stillThere(job)
	if snapshot == nil then return answer(job.player, false, why) end
	if occupied(snapshot) then return answer(job.player, false, 'occupied') end
	local plate, citizenId = plateOf(job.vehicleId)
	if plate ~= job.plate then return answer(job.player, false, 'not_registered') end
	local api = vehicles()
	local read, set = pcall(api.SetState, plate, 'impounded')
	if not read or type(set) ~= 'table' or not set.ok then
		local code = read and type(set) == 'table' and set.error == 'vehicle.occupied' and 'occupied'
			or 'impound_failed'
		audit('mechanic.impound', job.player, false, ('%s: %s'):format(plate,
			tostring(read and type(set) == 'table' and set.error or set)))
		return answer(job.player, false, code)
	end
	local earned = 0
	if config().impound.pay > 0 and payCharacter(job.playerData.citizenId, config().impound.payMoneyType, config().impound.pay,
		'mechanic:tow') then
		earned = config().impound.pay
	end
	local roster = character()
	if roster ~= nil and type(roster.GetPlayerByCitizenId) == 'function' and citizenId ~= nil then
		local found, owner = pcall(roster.GetPlayerByCitizenId, citizenId)
		if found and type(owner) == 'table' and type(owner.PlayerData) == 'table' then
			OPX.NotifyLocale(owner.PlayerData.source, 'mechanic.owner.impounded', { plate = plate }, 'warning')
		end
	end
	audit('mechanic.impound', job.player, true, plate .. ' impounded', { plate = plate, owner = citizenId })
	OPX.Publish(Event.ON_IMPOUNDED, job.player, { plate = plate, citizenId = citizenId,
		by = citizenOf(job.player) })
	answer(job.player, true, 'impounded', { plate = plate, earned = earned,
		moneyType = config().impound.payMoneyType })
end

local function onImpound(player, payload)
	if type(payload) ~= 'table' then payload = {} end
	if not config().impound.enabled then return answer(player, false, 'impound_off') end
	local api = vehicles()
	if api == nil or type(api.SetState) ~= 'function' then return answer(player, false, 'no_vehicles') end
	local allowed, why = mayImpound(player)
	if not allowed then return answer(player, false, why == 'off_duty' and 'off_duty' or 'not_authorised') end
	local at, refusal = ready(player)
	if at == nil then return answer(player, false, refusal) end
	local snapshot = nearestVehicle(at, config().reach, hintOf(payload.vehicleId))
	if snapshot == nil then return answer(player, false, 'vehicle_far') end
	local vehicleKey = tostring(snapshot.id)
	if working[vehicleKey] ~= nil then return answer(player, false, 'vehicle_busy') end
	if occupied(snapshot) then return answer(player, false, 'occupied') end
	local plate = plateOf(snapshot.id)
	if plate == nil then return answer(player, false, 'not_registered') end
	local place = placeOf(snapshot)
	if not truckNear(place, vehicleKey) then return answer(player, false, 'no_tow_truck') end
	local job = { player = player, vehicleId = snapshot.id, vehicleKey = vehicleKey, origin = place,
		plate = plate, kind = 'impound' }
	local code = startBar(job, 'mechanic.bar.impound', config().impound.durationMs, config().impound.animation)
	if code ~= nil then return answer(player, false, code) end
	answer(player, true, 'started', { plate = plate })
end

commit = function(job)
	if job.kind == Mode.SHOP then return commitShop(job) end
	if job.kind == Mode.KIT then return commitKit(job) end
	return commitImpound(job)
end

-- ── the stash and the lot ────────────────────────────────────────────────────

local function shopOf(payload)
	local key = type(payload) == 'table' and payload.shop or nil
	return type(key) == 'string' and config().shops[key] or nil
end

local function atPoint(player, spot)
	if spot == nil then return false end
	local here = positionOf(player)
	return here ~= nil and within(here, { x = spot.x, y = spot.y, z = spot.z, bucket = here.bucket }, spot.radius)
end

local function onStash(player, payload)
	local shop = shopOf(payload)
	if shop == nil or shop.stash == nil then return answer(player, false, 'no_such_shop') end
	local member, why = memberOf(player, shop, 0)
	if not member then return answer(player, false, why == 'off_duty' and 'off_duty' or 'not_mechanic') end
	if not atPoint(player, shop.stash) then return answer(player, false, 'too_far') end
	local api = inventory()
	if api == nil or type(api.OpenStash) ~= 'function' then return answer(player, false, 'no_inventory') end
	local here = positionOf(player)
	local read, opened = pcall(api.OpenStash, player, shop.stashKey, {
		slots = shop.stash.slots, maxWeight = shop.stash.maxWeight,
		label = shop.stash.label ~= '' and shop.stash.label or shop.label,
		position = { x = shop.stash.x, y = shop.stash.y, z = shop.stash.z }, bucket = here and here.bucket or 0,
	})
	if not read or type(opened) ~= 'table' or not opened.ok then return answer(player, false, 'unavailable') end
end

-- The impounded rows of one character, as the lot shows them.
local function impoundedOf(citizenId)
	local api = vehicles()
	if api == nil or type(api.List) ~= 'function' then return nil end
	local read, listed = pcall(api.List, citizenId)
	if not read or type(listed) ~= 'table' or not listed.ok then return nil end
	local rows = {}
	for _, row in ipairs(type(listed.value) == 'table' and listed.value or {}) do
		if type(row) == 'table' and row.state == M.IMPOUNDED and type(row.plate) == 'string' then
			rows[#rows + 1] = { plate = row.plate, name = OPX.Vehicle.DisplayName(row.record) }
		end
	end
	table.sort(rows, function(a, b) return a.plate < b.plate end)
	return rows
end

local function onLot(player, payload)
	local shop = shopOf(payload)
	if shop == nil or shop.lot == nil then return answer(player, false, 'no_such_shop') end
	if not atPoint(player, shop.lot) then return answer(player, false, 'too_far') end
	local citizenId = citizenOf(player)
	if citizenId == nil then return answer(player, false, 'no_character') end
	local data = loaded(player)
	local rows = impoundedOf(citizenId)
	if loaded(player) ~= data then return end
	if rows == nil then return answer(player, false, 'no_vehicles') end
	if #rows == 0 then return answer(player, false, 'nothing_impounded') end
	TriggerClientEvent(Event.LOT_VIEW, player, { shop = shop.key, label = shop.label, fee = shop.releaseFee,
		moneyType = shop.releaseMoneyType, vehicles = rows })
end

local function onRelease(player, payload)
	local shop = shopOf(payload)
	if shop == nil or shop.lot == nil then return answer(player, false, 'no_such_shop') end
	local plate = type(payload) == 'table' and payload.plate or nil
	if type(plate) ~= 'string' or #plate < 1 or #plate > 12 or not plate:match('^[%w%-]+$') then
		return answer(player, false, 'not_yours')
	end
	if not atPoint(player, shop.lot) then return answer(player, false, 'too_far') end
	local citizenId = citizenOf(player)
	if citizenId == nil then return answer(player, false, 'no_character') end
	local data = loaded(player)
	local api = vehicles()
	if api == nil or type(api.Get) ~= 'function' or type(api.SetState) ~= 'function' then
		return answer(player, false, 'no_vehicles')
	end
	local read, row = pcall(api.Get, plate)
	if loaded(player) ~= data then return end
	row = read and type(row) == 'table' and row.ok and row.value or nil
	if type(row) ~= 'table' or row.citizenId ~= citizenId or row.state ~= M.IMPOUNDED then
		return answer(player, false, 'not_yours')
	end
	local fee, moneyType = shop.releaseFee, shop.releaseMoneyType
	if balanceOf(player, moneyType) < fee then
		return answer(player, false, 'cannot_afford', { fee = fee, moneyType = moneyType })
	end
	local reason = ('mechanic:%s:release:%s'):format(shop.key, plate)
	if not charge(player, moneyType, fee, reason) then
		return answer(player, false, 'cannot_afford', { fee = fee, moneyType = moneyType })
	end
	local set
	read, set = pcall(api.SetState, plate, 'stored', shop.releaseGarage)
	if not read or type(set) ~= 'table' or not set.ok then
		pay(player, moneyType, fee, reason .. ':refund')
		audit('mechanic.release', player, false, ('%s: %s'):format(plate,
			tostring(read and type(set) == 'table' and set.error or set)))
		return answer(player, false, 'release_failed')
	end
	local accounts = OPX.Api.Get('accounts')
	local deposited = false
	if fee > 0 and shop.account and accounts ~= nil and type(accounts.Deposit) == 'function' then
		local ran, receipt = pcall(accounts.Deposit, 'job', shop.account, fee, reason,
			('mechanic:release:%s:%d'):format(plate, OPX.Now()))
		deposited = ran and type(receipt) == 'table' and receipt.ok == true
	end
	audit('mechanic.release', player, true, ('%s released at %s for %d%s'):format(plate, shop.key, fee,
		deposited and '' or ' (no shop account)'), { plate = plate, shop = shop.key, fee = fee, deposited = deposited })
	OPX.Publish(Event.ON_RELEASED, player, { plate = plate, citizenId = citizenId, shop = shop.key, fee = fee })
	answer(player, true, 'released', { plate = plate, fee = fee, moneyType = moneyType })
end

-- ── the board ────────────────────────────────────────────────────────────────

-- What a mechanic is shown of one call. No name: the server does not hand a
-- stranger's name to anybody.
local function viewOf(call, viewer)
	local here = positionOf(viewer)
	local gap = here and call.position and gapSq(here, call.position)
	return {
		id = call.id, kind = call.kind, note = call.note,
		x = call.position and call.position.x, y = call.position and call.position.y,
		z = call.position and call.position.z,
		distance = gap and math.floor(math.sqrt(gap)) or nil,
		ageS = math.floor((OPX.Now() - call.openedMs) / 1000),
		responders = Dispatch.Count(call), limit = config().dispatch.responders,
		mine = call.responders[viewer] ~= nil,
	}
end

local function responders()
	local out = {}
	for _, player in ipairs(playerIds()) do
		if isMechanic(player, config().dispatch.minGrade) then out[#out + 1] = player end
	end
	return out
end

local function announceClosed(call, why)
	for _, player in ipairs(responders()) do
		TriggerClientEvent(Event.CLOSED, player, { id = call.id, why = why })
	end
	OPX.Publish(Event.ON_CALL, call.caller, { state = 'closed', callId = call.id, kind = call.kind,
		why = why, citizenId = call.citizenId })
end

--- Opens (or refreshes) a call for one player. Answers how many mechanics were told.
-- @author dop42
-- @param player integer
-- @param kind string M.CallKind
-- @param note string|nil
-- @return integer|nil told, string|nil refusal
function M.Call(player, kind, note)
	if not config().dispatch.enabled then return nil, 'calls_off' end
	local citizenId = citizenOf(player)
	if citizenId == nil then return nil, 'no_character' end
	local at = positionOf(player)
	if at == nil then return nil, 'no_position' end
	kind = kind == CallKind.TOW and CallKind.TOW or CallKind.REPAIR
	local call, fresh = Dispatch.Open({ caller = player, citizenId = citizenId, kind = kind,
		note = Model.Note(config(), note), position = at, ttlMs = config().dispatch.ttlMs, nowMs = OPX.Now() })
	local told = 0
	for _, mechanic in ipairs(responders()) do
		if mechanic ~= player then
			TriggerClientEvent(Event.ALERT, mechanic, viewOf(call, mechanic))
			told = told + 1
		end
	end
	OPX.Publish(Event.ON_CALL, player, { state = fresh and 'opened' or 'refreshed', callId = call.id,
		kind = kind, citizenId = citizenId })
	OPX.NotifyLocale(player, told > 0 and 'mechanic.caller.called' or 'mechanic.caller.nobody', nil,
		told > 0 and 'info' or 'warning')
	return told
end

local function onBoard(player)
	local ok, why = isMechanic(player, config().dispatch.minGrade)
	if not ok then return answer(player, false, why) end
	local rows = {}
	for _, call in ipairs(Dispatch.List()) do
		if #rows >= BOARD_ROWS then break end
		rows[#rows + 1] = viewOf(call, player)
	end
	TriggerClientEvent(Event.BOARD_VIEW, player, { calls = rows })
end

local function onTake(player, payload)
	local call = Dispatch.Get(type(payload) == 'table' and payload.callId)
	if call == nil or call.caller == player then return answer(player, false, 'no_such_call') end
	local ok, why = isMechanic(player, config().dispatch.minGrade)
	if not ok then return answer(player, false, why) end
	local taken, refusal = Dispatch.Take(call.id, player, config().dispatch.responders, OPX.Now())
	if taken == nil then return answer(player, false, refusal) end
	local at = positionOf(call.caller) or call.position
	if at ~= nil then TriggerClientEvent(Event.WAYPOINT, player, { x = at.x, y = at.y, z = at.z }) end
	OPX.NotifyLocale(call.caller, 'mechanic.caller.enRoute', nil, 'success')
	OPX.Publish(Event.ON_CALL, call.caller, { state = 'taken', callId = call.id, kind = call.kind,
		responder = citizenOf(player), citizenId = call.citizenId })
	audit('mechanic.take', player, true, ('call %d'):format(call.id))
	answer(player, true, 'taken')
end

local function onDrop(player, payload)
	if not Dispatch.Drop(type(payload) == 'table' and payload.callId, player) then
		return answer(player, false, 'no_such_call')
	end
	answer(player, true, 'dropped')
end

local function onClose(player, payload)
	local call = Dispatch.Get(type(payload) == 'table' and payload.callId)
	if call == nil or call.responders[player] == nil then return answer(player, false, 'no_such_call') end
	Dispatch.Close(call.id)
	announceClosed(call, 'done')
	OPX.NotifyLocale(call.caller, 'mechanic.caller.done', nil, 'success')
	answer(player, true, 'closed')
end

-- ── items ────────────────────────────────────────────────────────────────────

local function onKitUsed(source, _)
	local player = math.tointeger(tonumber(source))
	if player ~= nil and player > 0 and not cooled(player, 'repair') then
		CreateThread(function() onRepair(player, { mode = Mode.KIT }) end)
	end
	-- The kit is consumed when the bar ends, not when it is used.
	return { ok = true, consume = 0 }
end

local function registerItems()
	local api = inventory()
	if api == nil or type(api.RegisterItem) ~= 'function' then
		Open77.log.warn('[mechanic] no inventory contract: no parts, no kit, and no workshop repair')
		return
	end
	local function register(item, definition)
		if type(api.GetItem) == 'function' then
			local read, known = pcall(api.GetItem, item.name)
			if read and known ~= nil then return true end
		end
		definition.label, definition.description, definition.weight = item.label, item.description, item.weight
		local read, done = pcall(api.RegisterItem, item.name, definition, OWNER)
		if not read or type(done) ~= 'table' or done.ok ~= true then
			Open77.log.warn(('[mechanic] the item %s could not be registered: %s'):format(item.name,
				tostring(read and type(done) == 'table' and done.error or done)))
			return false
		end
		return true
	end
	register(config().parts, { stack = true, category = 'tool', model = 'container.toolbox' })
	if config().kit.enabled and register(config().kitItem, { stack = true, category = 'tool',
		model = 'container.toolbox', use = { consume = 0, close = true } })
		and type(api.RegisterUsable) == 'function' then
		pcall(api.RegisterUsable, config().kitItem.name, onKitUsed, OWNER)
	end
end

-- ── commands ─────────────────────────────────────────────────────────────────

local function registerCommands()
	if registeredCommands then return end
	registeredCommands = true
	local names = config().commands
	local function caller(kind)
		return function(source, args)
			if source <= 0 then return OPX.CommandResult(source, false, 'the console stands nowhere') end
			local words = {}
			for index = 1, #args do words[#words + 1] = tostring(args[index]) end
			CreateThread(function()
				local told, why = M.Call(source, kind, table.concat(words, ' '))
				if told == nil then OPX.NotifyLocale(source, 'mechanic.error.' .. why, nil, 'error') end
			end)
		end
	end
	local note = { { name = 'note', optional = true, help = locale('mechanic.help.note') } }
	OPX.Command.Register(names.call, { restricted = false, help = 'mechanic.help.call', cooldownMs = 5000,
		params = note }, caller(CallKind.REPAIR))
	OPX.Command.Register(names.tow, { restricted = false, help = 'mechanic.help.tow', cooldownMs = 5000,
		params = note }, caller(CallKind.TOW))
	OPX.Command.Register(names.board, { restricted = false, help = 'mechanic.help.board', cooldownMs = 500 },
		function(source)
			if source <= 0 then return OPX.CommandResult(source, false, 'the console has no board') end
			CreateThread(function() onBoard(source) end)
		end)
end

-- ── the sweep ────────────────────────────────────────────────────────────────

local function sweep()
	for _, call in ipairs(Dispatch.Expire(OPX.Now())) do
		announceClosed(call, 'expired')
		OPX.NotifyLocale(call.caller, 'mechanic.caller.expired', nil, 'warning')
	end
end

local function departed(rawPlayer)
	local player = math.tointeger(tonumber(rawPlayer))
	if player == nil then return end
	local own = Dispatch.Forget(player)
	if own ~= nil then announceClosed(own, 'caller_left') end
	local job = busy[player]
	if job ~= nil then
		local progress = OPX.Api.Get('progress')
		if job.barId ~= nil and progress ~= nil and type(progress.Stop) == 'function' then
			pcall(progress.Stop, job.player, OWNER, job.barId)
		end
		finish(job, false, 'left')
	end
	local prefix = tostring(player) .. ':'
	for slot in pairs(lastRequest) do
		if slot:sub(1, #prefix) == prefix then lastRequest[slot] = nil end
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state.
-- @author dop42
function M.Init()
	settings = nil
	busy, working, lastRequest = {}, {}, {}
	Dispatch.Reset()
end

--- Publishes the server contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('mechanic', 1, {
		--- Opens a call for a player, as `/mechanic` or `/tow` would.
		Call = function(player, kind, note)
			local told, why = M.Call(math.tointeger(tonumber(player)) or -1, kind, note)
			if told == nil then return Result.Err(why) end
			return Result.Ok({ told = told })
		end,
		--- The open calls.
		Calls = function()
			local rows = {}
			for _, call in ipairs(Dispatch.List()) do
				rows[#rows + 1] = { id = call.id, kind = call.kind, caller = call.caller,
					responders = Dispatch.Count(call) }
			end
			return Result.Ok(rows)
		end,
		Shops = function() return Result.Ok(OPX.Table.DeepCopy(config().shopOrder)) end,
	})
end

--- Wires the requests, the items, the commands and the sweep.
-- @author dop42
function M.Start()
	local mistakes, unsurveyed = Model.Partition(Model.Problems(OPX.Config.MODULES.mechanic))
	for _, line in ipairs(mistakes) do Open77.log.warn('[mechanic] config: ' .. line) end
	for _, line in ipairs(unsurveyed) do Open77.log.info('[mechanic] config: ' .. line) end

	local function wire(name, kind, handler)
		RegisterNetEvent(name, function(payload)
			local player = math.tointeger(tonumber(source))
			if player == nil or player <= 0 then return end
			if cooled(player, kind) then return answer(player, false, 'rate_limited') end
			-- On a thread: the bag, the stash and the rows are read, and all may yield.
			local data = loaded(player)
			CreateThread(function()
				if data == nil or loaded(player) ~= data then return end
				handler(player, payload)
			end)
		end)
	end
	wire(Event.DIAGNOSE, 'diagnose', onDiagnose)
	wire(Event.HOOD, 'hood', onHood)
	wire(Event.REPAIR, 'repair', onRepair)
	wire(Event.IMPOUND, 'impound', onImpound)
	wire(Event.STASH, 'stash', onStash)
	wire(Event.LOT, 'lot', onLot)
	wire(Event.RELEASE, 'release', onRelease)
	wire(Event.BOARD, 'board', onBoard)
	wire(Event.TAKE, 'take', onTake)
	wire(Event.DROP, 'drop', onDrop)
	wire(Event.CLOSE, 'close', onClose)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)
	registerItems()
	registerCommands()
	OPX.Scheduler.Every('mechanic:sweep', config().scanMs, sweep)

	if vehicles() == nil then
		Open77.log.warn('[mechanic] no vehicles contract: no tow and no impound lot')
	end
	if OPX.Api.Get('invoices') == nil then
		Open77.log.info('[mechanic] no invoices contract: a workshop repair charges the customer directly')
	end
	if OPX.Api.Get('accounts') == nil then
		Open77.log.info('[mechanic] no accounts contract: the shop share goes to the mechanic, release fees to nobody')
	end
	Open77.log.info(('[mechanic] %d shop(s): %s'):format(#config().shopOrder,
		table.concat(config().shopOrder, ', ')))
end

--- Every job still running ends, not completed: nothing was taken yet.
-- @author dop42
function M.Stop()
	for _, job in pairs(busy) do job.done = true end
	busy, working = {}, {}
	local api = inventory()
	if api ~= nil and type(api.UnregisterUsable) == 'function' then
		pcall(api.UnregisterUsable, config().kitItem.name, OWNER)
	end
end

-- Exposed for the tests: the handlers, by name.
M.Server = {
	OnHood = onHood,
	OnDiagnose = onDiagnose, OnRepair = onRepair, OnImpound = onImpound, OnStash = onStash, OnLot = onLot, OnRelease = onRelease,
	OnBoard = onBoard, OnTake = onTake, OnDrop = onDrop, OnClose = onClose, Sweep = sweep,
	Departed = departed,
}
