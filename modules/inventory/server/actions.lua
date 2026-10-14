--- Using, handing over, dropping, opening and who is nearby -- all checked again.
-- @author dop42
--
-- Nothing the screen believes is taken on trust here. Every entry point re-reads
-- the slot, the count, the readiness gate, whether the player is alive, their
-- position and their routing bucket, whatever the client already knew.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Catalog = M.Catalog
local Containers = M.Containers
local Players = M.Players
local World = M.World
local KIND = M.KIND

M.Actions = {}
local Actions = M.Actions

-- The handler another module wants called when an item is used, by item name.
local usables = {}

-- When each player's last accepted use was, for the cooldown.
local lastUse = {}

-- Until when each player is still eating or drinking the last thing they used:
-- the end of its animation, on the server's clock.
--
-- THE COOLDOWN IS 750 MS AND A BITE IS 3 SECONDS. A hotbar key pressed four
-- times inside one burrito ate four of them -- each use consumed the item and
-- moved the needs at once, the progress bar refused the second gesture as busy,
-- and the player saw one animation and lost the stack. A use whose item plays a
-- timed gesture now holds the next one off until the gesture is over.
local busyUntil = {}

--- Registers the function to call when an item is used.
-- The last registration wins, and replacing one somebody else holds is a warning:
-- two modules fighting over one item is a bug in one of them, and only the
-- winner's handler would ever run.
-- @author dop42
-- @param name string an item name in the catalogue
-- @param handler fun(source: Source, info: table): table
-- @param owner string|nil who is registering, for the log line only
-- @return boolean
-- @return string|nil
function Actions.RegisterUsable(name, handler, owner)
	if not Catalog.Get(name) then return false, 'unknown_item' end
	if type(handler) ~= 'function' then return false, 'bad_request' end
	local previous = usables[name]
	if previous and previous.owner ~= owner then
		Open77.log.warn(('[inventory] %s now handles the use of %s, taking it from %s')
			:format(tostring(owner), name, tostring(previous.owner)))
	end
	usables[name] = { handler = handler, owner = owner }
	return true, nil
end

--- Removes an item's use handler, when the caller is the one that registered it.
-- @author dop42
-- @param name string
-- @param owner string|nil
-- @return boolean
function Actions.UnregisterUsable(name, owner)
	local current = usables[name]
	if not current or current.owner ~= owner then return false end
	usables[name] = nil
	return true
end

--- Who handles the use of an item, or nil.
-- @author dop42
-- @param name string
-- @return string|nil the owner given at registration
function Actions.UsableOwner(name)
	local current = usables[name]
	return current and current.owner or nil
end

--- Removes every use handler one owner registered. For an owner that stopped.
-- @author dop42
-- @param owner string
-- @return integer how many went
function Actions.UnregisterOwner(owner)
	local gone = 0
	for name, current in pairs(usables) do
		if current.owner == owner then
			usables[name] = nil
			gone = gone + 1
		end
	end
	return gone
end

--- Asks a use handler whether the use goes ahead, inside its deadline.
--
-- The handler runs on a thread of its own and NOT under a pcall: it may reach the
-- database, a yield is not safe across a pcall boundary in this runtime, and a
-- handler that raises would take the request thread with it. On its own thread a
-- raise simply means `done` is never set, so the deadline answers
-- `handler_timeout` and the request is refused like any other.
local function ask(entry, source, info)
	local done, answer = false, nil
	CreateThread(function()
		answer = entry.handler(source, info)
		done = true
	end)

	local deadline = OPX.Now() + Options.USE_HANDLER_MS
	while not done and OPX.Now() < deadline do Wait(25) end
	if not done then
		Open77.log.warn(('[inventory] the use handler for %s took longer than %d ms or raised')
			:format(tostring(info.name), Options.USE_HANDLER_MS))
		return nil, 'handler_timeout'
	end

	if type(answer) ~= 'table' then return nil, 'handler_failed' end
	if answer.ok ~= true then
		return nil, Common.Word(answer.error, 64, '^[%w_%.%-]+$') or 'use_refused'
	end
	return answer, nil
end

--- Heals a player by a share of their maximum health, through the host.
-- THE MEDICAL ITEMS DID NOTHING. They carried `USE = { CONSUME = 1 }` and no
-- handler, so a use destroyed one and healed nobody. The heal is the server's,
-- read and written through `Open77.players.getHealth` / `setHealth`, and it is
-- refused -- before anything is consumed -- for a player who is down (none of
-- these revives) or already at full health.
-- @param source Source
-- @param percent number
-- @return boolean
-- @return string|nil
local function heal(source, percent)
	local downed = OPX.Api.Get('downed')
	if downed ~= nil and type(downed.IsDown) == 'function' then
		local read, answer = pcall(downed.IsDown, source)
		if read and type(answer) == 'table' and answer.ok and type(answer.value) == 'table'
			and answer.value.down == true then
			return false, 'dead'
		end
	end
	local players = Open77.players
	if type(players) ~= 'table' or type(players.getHealth) ~= 'function'
		or type(players.setHealth) ~= 'function' then
		return false, 'use_refused'
	end
	local read, health = pcall(players.getHealth, source)
	if not read or type(health) ~= 'table' then return false, 'use_refused' end
	local current, maximum = tonumber(health.health), tonumber(health.maxHealth)
	if current == nil or maximum == nil or maximum <= 0 then return false, 'use_refused' end
	if current >= maximum then return false, 'full_health' end
	local wanted = math.min(maximum, current + maximum * percent / 100)
	local called, ok = pcall(players.setHealth, source, wanted)
	if not called or ok ~= true then return false, 'use_refused' end
	return true
end

--- Uses the item in a bag slot: draws a weapon, loads rounds, or consumes.
-- @author dop42
-- @param source Source
-- @param slot any
-- @return boolean
-- @return string|nil
function Actions.Use(source, slot)
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return false, 'bad_request' end

	local now = OPX.Now()
	if now - (lastUse[source] or -math.huge) < OPX.Tune.Number('INVENTORY_USE_COOLDOWN_MS', 0) then
		return false, 'too_fast'
	end
	if now < (busyUntil[source] or -math.huge) then return false, 'too_fast' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end
	-- HANDS FULL. Somebody carrying a hauling crate cannot draw a weapon or use
	-- an item; asked of the contract by name, so a server without hauling is
	-- unaffected.
	local hauling = OPX.Api.Get('hauling')
	if hauling ~= nil and type(hauling.IsCarrying) == 'function' and hauling.IsCarrying(source) then
		return false, 'hands_full'
	end

	local bag, reason = Players.Bag(source)
	if not bag then return false, reason end
	local entry = bag.items[slot]
	if not entry then return false, 'empty_slot' end
	local item = Catalog.Get(entry.name)
	if not item then return false, 'not_usable' end

	if item.weapon then
		lastUse[source] = now
		local drawn, why = M.Weapons.Use(source, bag, slot, item)
		-- A DRAWN WEAPON CLOSES THE SCREEN, as food does. It returned before the
		-- `used` event, so the inventory stayed over the gun the player had just
		-- asked to hold. Only a draw: putting one away leaves the screen up.
		if drawn and M.Weapons.Held(source) ~= nil then
			TriggerClientEvent(M.Event.USED, source, {
				name = entry.name,
				slot = slot,
				label = Catalog.Label(entry.name),
				close = true,
				weapon = true,
			})
		end
		return drawn, why
	end
	if item.ammo then
		lastUse[source] = now
		return M.Weapons.Reload(source, bag, slot)
	end

	local handler = usables[entry.name]
	if not item.usable and not handler then return false, 'not_usable' end
	lastUse[source] = now

	local use = item.use or {}
	local consume = use.consume or 0
	local healing = Options.HEALING[entry.name]
	if healing ~= nil and not handler then
		-- The slot is held across the host calls, as it is for a handler: the
		-- heal lands first and the unit it costs is taken after it.
		if not Containers.Hold(bag, slot) then return false, 'in_use' end
		local healed, why = heal(source, healing)
		Containers.Release(bag, slot)
		if not healed then return false, why end
	end
	if handler then
		-- THE SLOT IS HELD FOR AS LONG AS THE HANDLER RUNS, because the handler
		-- yields -- `ask` waits on it in 25 ms steps at the very least -- and the
		-- consume comes after it. Unheld, the stack could be dragged away, handed
		-- over, dropped, split or used a second time in that window: the handler
		-- applied its effect and the consume found nothing to take. See
		-- `Containers.Hold` for what a held slot refuses.
		if not Containers.Hold(bag, slot) then return false, 'in_use' end
		local answer, refusal = ask(handler, source, {
			name = entry.name,
			slot = slot,
			count = entry.count,
			metadata = Common.Copy(entry.metadata),
			label = Catalog.Label(entry.name),
			citizenId = Players.Citizen(source),
		})
		Containers.Release(bag, slot)
		if not answer then return false, refusal end
		if answer.consume ~= nil then
			consume = Common.Integer(answer.consume, 0, Options.MAX_STACK) or consume
		end
	end

	if consume > 0 then
		-- Nothing could MOVE the stack while the slot was held, so it is normally
		-- exactly where it was. A path that names the slot itself
		-- (`TakeFromSlot`, a staff clear) may still have changed it, and then the
		-- units go by name and metadata instead.
		local consumed
		if bag.items[slot] == entry and entry.count >= consume then
			consumed = Containers.TakeFromSlot(bag, slot, consume)
		else
			consumed = Containers.Remove(bag, entry.name, consume, entry.metadata)
		end
		if not consumed then return false, 'not_enough' end
	end

	-- THE NEEDS MOVE HERE, ON THE SERVER, and only after the unit is gone. The
	-- client used to add `use.status` to its own copy and push it, which is the
	-- door the owner closed (2026-10): a client could have "eaten" anything. The
	-- contract is optional -- with none the item is still consumed and only what
	-- it would have moved is lost -- and a need the operator has not declared
	-- costs the move, not the use.
	if type(use.status) == 'table' and next(use.status) ~= nil then
		local needs = OPX.Api.Get('needs')
		if needs ~= nil and type(needs.AddNeeds) == 'function' then
			local moved = needs.AddNeeds(source, use.status, 'use')
			if type(moved) == 'table' and moved.ok ~= true then
				Open77.log.debug(('[inventory] the needs of a use were refused: %s')
					:format(tostring(moved.error)))
			end
		end
	end

	local gesture = type(use.animation) == 'table' and tonumber(use.animation.durationMs) or nil
	if gesture and gesture > 0 then busyUntil[source] = now + gesture end

	TriggerClientEvent(M.Event.USED, source, {
		name = entry.name,
		slot = slot,
		label = Catalog.Label(entry.name),
		close = use.close ~= false,
		status = use.status,
		animation = use.animation,
	})
	-- AFTER THE FACT, and that is the whole contract: an item used is an item
	-- that was already consumed. A resource that wants to DECIDE a use is a
	-- `RegisterUsable` handler inside this resource; the bus cannot answer back.
	OPX.Publish(M.Event.ON_USED, source, {
		citizenId = Players.Citizen(source),
		name = entry.name,
		slot = slot,
		consumed = consume,
		metadata = Common.Copy(entry.metadata),
	})
	return true, nil
end

-- ── giving: an offer, and the receiver's yes ───────────────────────────────
--
-- A GIVE ASKS FIRST (the owner's ruling, 2026-10). It used to move the stack on
-- the giver's press alone: anybody in reach could fill a stranger's bag with
-- whatever they liked -- contraband before a search, a hundred stones, a dead
-- weight that pins them under their limit. Now the press raises an OFFER, the
-- receiver is asked -- the item and the count, and where the giver stands, never
-- who -- and nothing moves until they say yes. The yes is checked again from
-- scratch: both still able to act, still in reach, the same stack still in the
-- giver's slot, and room in the receiver's bag.

-- How long an offer stands, and the floor between two offers from one giver.
local GIVE_TTL_MS = 15000
local GIVE_FLOOR_MS = 3000

-- token -> the offer; and the one token each player is giving and being given.
local offers, offerFrom, offerTo = {}, {}, {}
local offerSeq = 0

--- The largest token a client may name back.
local MAX_TOKEN = 2147483647

--- Forgets an offer on both sides.
local function dropOffer(offer)
	offers[offer.token] = nil
	if offerFrom[offer.from] == offer.token then offerFrom[offer.from] = nil end
	if offerTo[offer.to] == offer.token then offerTo[offer.to] = nil end
end

-- A player's facing in degrees, or nil on a host that cannot say. Read off the
-- rich player snapshot, the way the staff position capture reads it.
local function headingOf(source)
	local api = Open77.players
	if type(api) ~= 'table' or type(api.get) ~= 'function' then return nil end
	local read, snapshot = pcall(api.get, source)
	if not read or type(snapshot) ~= 'table' then return nil end
	local yaw = tonumber(snapshot.heading) or tonumber(snapshot.yaw)
	if not OPX.Math.IsFinite(yaw) then return nil end
	return yaw
end

-- Which side of `here`, facing `yaw`, `there` stands: 'ahead', 'behind', 'left'
-- or 'right' -- the #91 wording the give list and the give offer both use -- or
-- nil without a facing. A yaw of 0 faces +Y and turns towards -X (see
-- `World.Ahead`), so forward is (-sin, cos) and right is (cos, sin).
local function sideOf(here, there, yaw)
	if yaw == nil then return nil end
	local radians = math.rad(yaw)
	local dx, dy = there.x - here.x, there.y - here.y
	local along = -math.sin(radians) * dx + math.cos(radians) * dy
	local across = math.cos(radians) * dx + math.sin(radians) * dy
	if math.abs(along) >= math.abs(across) then return along >= 0 and 'ahead' or 'behind' end
	return across >= 0 and 'right' or 'left'
end

--- Raises an offer of a stack from one player's bag to a nearby player.
--- Nothing moves: the receiver answers through `Actions.AnswerGive`.
-- @author dop42
-- @param source Source
-- @param target any
-- @param slot any
-- @param count any
-- @return boolean
-- @return string|nil
function Actions.Give(source, target, slot, count)
	target = Common.Integer(target, 1, 2147483647)
	slot = Common.Integer(slot, 1, 65535)
	if not target or not slot or target == source then return false, 'bad_request' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end

	local here, there = World.Position(source), World.Position(target)
	if not World.InReach(here, there) then return false, 'too_far' end
	if not Players.GateOpen(target) then return false, 'not_ready' end

	local from, reason = Players.Bag(source)
	if not from then return false, reason end
	local to = Players.Bag(target)
	if not to then return false, 'target_unavailable' end

	local entry = from.items[slot]
	if not entry then return false, 'empty_slot' end
	count = count == nil and entry.count or Common.Integer(count, 1, entry.count)
	if not count then return false, 'bad_count' end

	-- One offer out per giver and one in per receiver: a second press is not a
	-- second card on somebody's screen, and nobody is buried under offers.
	if offerFrom[source] ~= nil then return false, 'give_pending' end
	if offerTo[target] ~= nil then return false, 'give_busy' end
	if OPX.Cooling(source, 'inventory.giveOffer', GIVE_FLOOR_MS) then return false, 'too_fast' end
	if not Containers.CanCarry(to, entry.name, count, entry.metadata) then return false, 'no_room' end

	offerSeq = offerSeq % MAX_TOKEN + 1
	local now = OPX.Now()
	local offer = {
		token = offerSeq, from = source, to = target, slot = slot, entry = entry,
		name = entry.name, count = count, expiresAt = now + GIVE_TTL_MS,
	}
	offers[offer.token], offerFrom[source], offerTo[target] = offer, offer.token, offer.token

	local label = Catalog.Label(entry.name)
	if entry.name == Options.CURRENCY_ITEM and Options.CURRENCY_MONEY_TYPE ~= nil then
		label = OPX.Locale.Money(count, Options.CURRENCY_MONEY_TYPE)
	end
	local gap = World.Distance(there, here)
	TriggerClientEvent(M.Event.GIVE_OFFER, target, offer.token, {
		item = label,
		count = count,
		-- Where the GIVER stands, seen from the receiver: the receiver's facing.
		side = sideOf(there, here, headingOf(target)),
		distance = math.floor(gap * 10 + 0.5) / 10,
		expiresInMs = GIVE_TTL_MS,
	})
	OPX.NotifyLocale(source, 'inventory.notify.giveOffered', { count = count, item = label }, 'info')
	return true, nil
end

--- The receiver's answer to an offer. Only the receiver it was made to may
--- answer it, and a yes is checked again before anything moves.
-- @author dop42
-- @param source Source the answering receiver
-- @param token any
-- @param accepted any
-- @return boolean
-- @return string|nil
function Actions.AnswerGive(source, token, accepted)
	token = Common.Integer(token, 1, MAX_TOKEN)
	local offer = token and offers[token] or nil
	if offer == nil or offer.to ~= source then return false, 'give_gone' end
	dropOffer(offer)

	local giver, label = offer.from, Catalog.Label(offer.name)
	local said = { count = offer.count, item = label }
	if OPX.Now() > offer.expiresAt then
		OPX.NotifyLocale(giver, 'inventory.notify.giveExpired', said, 'info')
		return false, 'give_gone'
	end
	if accepted ~= true then
		OPX.NotifyLocale(giver, 'inventory.notify.giveDeclined', said, 'info')
		return true, nil
	end

	local function fail(code)
		OPX.NotifyLocale(giver, 'inventory.notify.giveFailed', said, 'warning')
		return false, code
	end
	if not Players.MayAct(giver) or not Players.MayAct(source) then return fail('not_ready') end
	if not World.InReach(World.Position(giver), World.Position(source)) then return fail('too_far') end
	local from = Players.Bag(giver)
	local to = Players.Bag(source)
	if not from or not to then return fail('target_unavailable') end
	local entry = from.items[offer.slot]
	if entry ~= offer.entry or entry.count < offer.count then return fail('give_changed') end
	if not Containers.CanCarry(to, entry.name, offer.count, entry.metadata) then return fail('no_room') end

	local moved, refusal = Containers.Move(from, offer.slot, to, nil, offer.count)
	if not moved then return fail(refusal) end

	if offer.name == Options.CURRENCY_ITEM and Options.CURRENCY_MONEY_TYPE ~= nil then
		local amount = OPX.Locale.Money(offer.count, Options.CURRENCY_MONEY_TYPE)
		OPX.NotifyLocale(giver, 'inventory.notify.gaveMoney', { amount = amount }, 'success')
		OPX.NotifyLocale(source, 'inventory.notify.receivedMoney', { amount = amount }, 'info')
		return true, nil
	end
	OPX.NotifyLocale(giver, 'inventory.notify.gave', said, 'success')
	OPX.NotifyLocale(source, 'inventory.notify.received', said, 'info')
	return true, nil
end

--- Withdraws every offer past its deadline, telling both sides.
-- @author dop42
function Actions.SweepOffers()
	local now = OPX.Now()
	for _, offer in pairs(offers) do
		if now > offer.expiresAt then
			dropOffer(offer)
			TriggerClientEvent(M.Event.GIVE_WITHDRAWN, offer.to, offer.token)
			OPX.NotifyLocale(offer.from, 'inventory.notify.giveExpired',
				{ count = offer.count, item = Catalog.Label(offer.name) }, 'info')
		end
	end
end

--- Withdraws whatever a departing player was giving or being given.
local function forgetOffers(source)
	for _, token in ipairs({ offerFrom[source], offerTo[source] }) do
		local offer = offers[token]
		if offer ~= nil then
			dropOffer(offer)
			if offer.from == source then
				TriggerClientEvent(M.Event.GIVE_WITHDRAWN, offer.to, offer.token)
			end
		end
	end
end

--- Drops a stack onto the nearest pile that will take it, or onto a new one.
-- @author dop42
-- @param source Source
-- @param slot any
-- @param count any
-- @param yaw any the client's heading; it only turns the pile to fall in front
-- @return table|nil the pile
-- @return string|nil
function Actions.Drop(source, slot, count, yaw)
	if not Options.DROPS then return nil, 'drops_disabled' end
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return nil, 'bad_request' end
	local may, refusal = Players.MayAct(source)
	if not may then return nil, refusal end

	local bag, reason = Players.Bag(source)
	if not bag then return nil, reason end
	local entry = bag.items[slot]
	if not entry then return nil, 'empty_slot' end
	count = count == nil and entry.count or Common.Integer(count, 1, entry.count)
	if not count then return nil, 'bad_count' end

	-- WHAT MAY NOT BE LEFT ON THE FLOOR, and it is checked here rather than on
	-- the screen because the screen is a suggestion. A pile is memory-only: it is
	-- swept after `DROPS.LIFETIME_MINUTES` and nothing about it survives a
	-- restart. For a stack of eddies -- a bearer note drawn against a balance --
	-- that is not a lost item, it is a balance deleted, with no row, no audit line
	-- and nothing for staff to settle from. See `DROP` in shared/catalog.lua.
	local item = Catalog.Get(entry.name)
	if item and item.droppable == false then return nil, 'no_drop' end

	if World.Seat(source) then return nil, 'in_vehicle' end
	local position = World.Position(source)
	if not position then return nil, 'no_position' end
	position = World.Ahead(position, yaw)

	local pile = World.NearestDrop(position, Options.DROP_DISTANCE)
	if pile and not Containers.CanCarry(pile, entry.name, count, entry.metadata) then pile = nil end
	if not pile then
		local citizenId = Players.Citizen(source)
		-- The door toasts the refusal (`requests.lua`); toasting it here too was
		-- the same sentence twice. The cooldown is its own reason: it said "too
		-- many piles" to a player who had made one a second ago.
		local may, why = false, 'drop_limit'
		if citizenId then may, why = World.MayCreateDrop(source, citizenId) end
		if not may then return nil, why or 'drop_limit' end
		pile = World.CreateDrop(source, citizenId, position, entry.name)
	end

	local moved, refusal = Containers.Move(bag, slot, pile, nil, count)
	if not moved then
		-- A pile made for this drop and never filled goes again at once.
		World.CheckEmptyDrop(pile)
		return nil, refusal
	end
	return pile, nil
end

--- Moves every stack of a pile in reach into the bag, leaving what does not fit.
-- @author dop42
-- @param source Source
-- @param id any
-- @return boolean
-- @return string|nil
function Actions.TakeDrop(source, id)
	-- A pile's id is always negative: it is a memory-only container.
	id = Common.Integer(id, -2147483647, -1)
	if not id or not World.Drop(id) then return false, 'not_found' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end
	if World.Seat(source) then return false, 'in_vehicle' end
	local pile = Containers.Get(id)
	if not pile then return false, 'not_found' end
	if not World.WithinReach(source, pile) then return false, 'too_far' end
	local bag, reason = Players.Bag(source)
	if not bag then return false, reason end

	local slots = {}
	for slot in pairs(pile.items) do slots[#slots + 1] = slot end
	table.sort(slots)

	local taken, refusal = 0, nil
	for index = 1, #slots do
		-- The last stack out empties the pile, which removes it and its container.
		local moved, code = Containers.Move(pile, slots[index], bag, nil, nil)
		if moved then taken = taken + 1 else refusal = refusal or code end
	end
	if taken == 0 then return false, refusal or 'not_found' end
	return true, refusal
end

--- Opens a configured stash beside the bag, when the player is standing at it.
-- @author dop42
-- @param source Source
-- @param name any
-- @return table|nil
-- @return string|nil
function Actions.OpenConfiguredStash(source, name)
	local stash = type(name) == 'string' and Options.STASHES[name] or nil
	if not stash then return nil, 'not_found' end
	local may, refusal = Players.MayAct(source)
	if not may then return nil, refusal end
	local anchor = { x = stash.position.x, y = stash.position.y, z = stash.position.z,
		bucket = stash.bucket }
	if not World.InReach(World.Position(source), anchor) then return nil, 'too_far' end

	local container, reason = World.Stash(stash.name, stash, anchor, Catalog.Rendered(stash.label))
	if not container then return nil, reason end
	Containers.View(source, container)
	return container, nil
end

--- Opens a vehicle's trunk, or the seat's glovebox, beside the bag.
-- A glovebox is always the one of the vehicle the player is sitting in, whatever
-- the client named. A trunk's id arrives as a DECIMAL STRING: a vehicle id carries
-- a generation and can pass 2^53, where a JSON number stops being exact.
-- @author dop42
-- @param source Source
-- @param kind string trunk or glovebox
-- @param vehicleId any
-- @return table|nil
-- @return string|nil
function Actions.OpenVehicle(source, kind, vehicleId)
	local may, refusal = Players.MayAct(source)
	if not may then return nil, refusal end
	if kind == KIND.GLOVEBOX then
		vehicleId = World.Seat(source)
		if not vehicleId then return nil, 'not_seated' end
	else
		if type(vehicleId) == 'string' and vehicleId:match('^%d+$') and #vehicleId <= 19 then
			vehicleId = math.tointeger(tonumber(vehicleId))
		end
		vehicleId = Common.Integer(vehicleId, 1, math.maxinteger)
		if not vehicleId then return nil, 'bad_request' end
		if World.Seat(source) == vehicleId then return nil, 'seated' end
		-- A LOCKED VEHICLE KEEPS ITS BOOT SHUT, asked before anything is loaded
		-- so the refusal names the lock rather than the reach it also fails.
		-- The lock is the host's own bit, never a client's word; see
		-- `World.TrunkLocked`.
		if World.TrunkLocked(vehicleId) then return nil, 'locked' end
	end

	local container, reason = World.VehicleContainer(vehicleId, kind)
	if not container then return nil, reason end

	-- A BOOT THAT BELONGS TO SOMEBODY ANSWERS TO THEM. Reach and "not sitting in
	-- it" were the only checks, so a stranger could empty a parked owned car.
	-- The lock above is the second rule now -- a key holder who unlocked the car
	-- has opened it to whoever is standing there -- and this one still stands
	-- beside it, because an unlocked owned car is not an invitation. Off by
	-- configuration for a server that wants theft.
	--
	-- The glovebox is exempt: it opens only while SEATED, and somebody sitting in
	-- the car has already been let into it.
	if kind ~= KIND.GLOVEBOX and Options.TRUNK_OWNER_ONLY and container.ownerCitizenId then
		if container.ownerCitizenId ~= Players.Citizen(source) then
			return nil, 'not_yours'
		end
	end

	if not World.WithinReach(source, container) then return nil, 'too_far' end
	Containers.View(source, container)
	return container, nil
end

--- The players in reach, nearest first: id, rounded distance and which side of
--- the giver they stand on. NEVER A NAME.
-- @author dop42
--
-- THE OWNER'S DECISION, and it reverses a change that shipped for one release:
-- in roleplay a character's name is something you learn by meeting them, and a
-- give list that printed it told every stranger within arm's reach who they
-- were. So the server does not put a name in this answer at all -- not hidden
-- on the page, absent from the wire. What tells two people apart instead is
-- where they stand ("To your left · 1.2 m"), with the short id beside it.
-- @param source Source
-- @return table[]
function Actions.Nearby(source)
	local out = {}
	if Options.NEARBY_MAX <= 0 then return out end
	local here = World.Position(source)
	if not here then return out end
	local yaw = headingOf(source)

	local players = Players.List()
	for index = 1, #players do
		local other = players[index].source
		if other ~= source then
			local there = World.Position(other)
			if there and there.bucket == here.bucket then
				local gap = World.Distance(here, there)
				if gap <= Options.REACH then
					out[#out + 1] = { id = other, distance = math.floor(gap * 10 + 0.5) / 10,
						side = sideOf(here, there, yaw) }
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.distance < b.distance end)
	for index = #out, Options.NEARBY_MAX + 1, -1 do out[index] = nil end
	return out
end

--- Forgets a departed player's use and pile cooldowns.
-- @author dop42
-- @param source Source
function Actions.Forget(source)
	forgetOffers(source)
	lastUse[source] = nil
	busyUntil[source] = nil
	World.Forget(source)
end
