--- What the screen asks for: validated, rate limited and answered.
-- @author dop42
--
-- One door in, `M.Event.REQUEST`, carrying a request id, an action name and a
-- payload; one door out, `M.Event.ANSWER`, carrying the id, whether it was
-- accepted, a code and data. `source` comes from the authenticated connection and
-- is the only value a client cannot forge; every field of the payload is a claim,
-- checked here and checked again by `Actions` and `Containers`.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Containers = M.Containers
local Players = M.Players
local World = M.World
local Actions = M.Actions
local KIND = M.KIND

M.Requests = {}
local Requests = M.Requests

local MAX_REQUEST_ID = 2147483647

-- The host's own bucket-move event; see `Requests.Wire`.
local HOST_BUCKET_CHANGE = 'onPlayerBucketChange'

-- Rate limit window per player -- when it started, how many arrived, how many
-- refusals have been answered -- and when each player's last hello was answered.
local windows = {}
local lastHello = {}

--- Whether a request fits the window, and whether to answer a refusal.
-- A refused request IS answered, so the client settles what it is waiting on
-- instead of holding a move until its own timeout. Past twice the allowance in
-- one window a flood stops costing an answer at all.
local function within(source)
	local allowance = OPX.Tune.Number('INVENTORY_RATE_REQUESTS', 1)
	local now = OPX.Now()
	local window = windows[source]
	if not window or now - window.started >= Options.RATE_WINDOW_MS then
		window = { started = now, count = 0, told = 0 }
		windows[source] = window
	end
	if window.count >= allowance then
		if window.told >= allowance * 2 then return false, false end
		window.told = window.told + 1
		return false, true
	end
	window.count = window.count + 1
	return true, false
end

--- Sends one request's answer back to the client that asked for it.
local function answer(source, requestId, ok, code, data)
	TriggerClientEvent(M.Event.ANSWER, source, requestId, ok == true, code or '', data or {})
end

--- Toasts a refusal and tells the client which request it belongs to.
local function refuse(source, code, operation)
	local key = Common.ErrorKey(code, 'inventory.error.')
	-- The refusal IS the toast; a second through `NotifyLocale` doubled it.
	OPX.Refuse(source, key, operation)
end

local function slotOf(value)
	return Common.Integer(value, 1, 65535)
end

--- An optional count off the wire: nil stays nil, anything else must be valid.
local function countOf(value)
	if value == nil then return true, nil end
	local count = Common.Integer(value, 1, Options.MAX_STACK)
	return count ~= nil, count
end

--- The bag, or the second container while it is still in reach.
-- A player acts on their own bag or on what they have open beside it, and on
-- nothing else. Out of reach the second container is closed rather than refused
-- quietly, so the screen stops showing something that is no longer there.
-- Yields: the bag may still be loading.
local function resolve(source, id)
	local bag = Players.Bag(source)
	if not bag then return nil end
	id = Common.Integer(id, -2147483647, 4294967295)
	if id == nil or id == bag.id then return bag end
	local view = Containers.Viewing(source)
	if not view or view.id ~= id then return nil end
	local container = Containers.Get(id)
	if not container then return nil end
	if not view.staff and not World.WithinReach(source, container) then
		Containers.CloseSecondary(source, true)
		return nil
	end
	return container
end

--- Closes the second container, settling an offline bag a staff search had open.
-- `tell` writes the close back to the screen, which is what the page's own Close
-- button needs: the page waits for that push and clears nothing by itself.
local function closeSecondary(source, tell)
	local view = Containers.Viewing(source)
	Containers.CloseSecondary(source, tell == true)
	if not view or not view.staff then return end
	local container = Containers.Get(view.id)
	if not container or container.kind ~= KIND.CHARACTER then return end
	Players.Settle(container)
end

-- Handlers by the action name that travels on the wire. Each may yield, so each
-- runs on its own thread; an unknown action is refused without costing a request.
local handlers = {}

--- Answers the bag, whatever is open beside it, and whether piles are on.
handlers.open = function(source)
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end

	local bag, reason = Players.Bag(source)
	-- Nothing held for this connection yet: ask the character contract once more
	-- rather than refusing a player whose load event this module has not seen.
	if not bag and reason == 'not_loaded' then bag, reason = Players.Attach(source) end
	if not bag then return false, reason or 'not_loaded' end

	local view = Containers.Viewing(source)
	local secondary = view and Containers.Get(view.id)
	if secondary and not view.staff and not World.WithinReach(source, secondary) then
		closeSecondary(source)
		secondary = nil
	end

	return true, nil, {
		primary = Containers.Describe(bag),
		secondary = secondary and Containers.Describe(secondary) or nil,
		drops = Options.DROPS,
	}
end

--- Closes the second container when the screen closes.
handlers.close = function(source)
	closeSecondary(source)
	return true
end

--- The page's own Close on the second container: the same operation, said back.
-- IT WAS `handlers.close`, which closes quietly because the whole screen is going
-- away. The page keeps the screen and waits for the server's `secondary` push to
-- clear the panel, so the trunk stayed drawn, closed on the server, and every
-- drag into it after that was refused as "That is no longer there".
handlers.closeSecondary = function(source)
	closeSecondary(source, true)
	return true
end

--- Toasts a refusal the player asked for by hand, and answers it.
-- The cooldown is the one code left quiet, as it is for a use: it answers a
-- burst, and a toast per click of a burst is the spam it exists to stop.
local function refused(source, ok, code, operation)
	if not ok and code ~= nil and code ~= 'too_fast' then refuse(source, code, operation) end
	return ok, code
end

--- Moves, stacks or swaps a slot between containers the player may reach.
handlers.move = function(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local fromSlot = slotOf(payload.fromSlot)
	local toValid = payload.toSlot == nil or slotOf(payload.toSlot) ~= nil
	local countValid, count = countOf(payload.count)
	if not fromSlot or not toValid or not countValid then return false, 'bad_request' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end
	local from = resolve(source, payload.from)
	local to = resolve(source, payload.to)
	-- EVERY REFUSAL FROM HERE ON IS SAID. A full trunk, a split with no room, a
	-- weapon being holstered on the way out: the page draws no reason of its own,
	-- so a move refused without a toast was a drag that snapped back in silence.
	if not from or not to then return refused(source, false, 'not_found', M.Operation.MOVE) end
	return refused(source, Containers.Move(from, fromSlot, to, slotOf(payload.toSlot), count),
		M.Operation.MOVE)
end

--- Splits part of a stack into the first free slot.
handlers.split = function(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local slot = slotOf(payload.slot)
	local countValid, count = countOf(payload.count)
	if not slot or not countValid or not count then return false, 'bad_request' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end
	local container = resolve(source, payload.container)
	if not container then return refused(source, false, 'not_found', M.Operation.MOVE) end
	return refused(source, Containers.Split(container, slot, count), M.Operation.MOVE)
end

--- Packs a container the player may reach, by weight or by name.
handlers.sort = function(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end
	local container = resolve(source, payload.container)
	if not container then return refused(source, false, 'not_found', M.Operation.MOVE) end
	return refused(source, Containers.Sort(container, payload.mode), M.Operation.MOVE)
end

--- Uses a bag slot, toasting any refusal except the cooldown.
handlers.use = function(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local ok, code = Actions.Use(source, payload.slot)
	-- The cooldown is not worth a toast: a held key would raise one per frame.
	if not ok and code ~= 'too_fast' then refuse(source, code, M.Operation.USE) end
	return ok, code
end

--- Drops a stack on the ground. The pile is found in the world, never named here.
handlers.drop = function(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local countValid, count = countOf(payload.count)
	if not countValid then return false, 'bad_request' end
	local pile, code = Actions.Drop(source, payload.slot, count, payload.yaw)
	-- The cooldown is said here, unlike a burst of moves: a drop is one click, and
	-- a click that does nothing is the silence this door exists to end.
	if not pile then
		refuse(source, code, M.Operation.DROP)
		return false, code
	end
	return true, nil
end

--- Hands a stack to a nearby player.
handlers.give = function(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local countValid, count = countOf(payload.count)
	if not countValid then return false, 'bad_request' end
	local ok, code = Actions.Give(source, payload.target, payload.slot, count)
	if not ok then refuse(source, code, M.Operation.GIVE) end
	return ok, code
end

--- Answers an opened container, or toasts and answers the refusal.
local function opened(source, container, code, operation)
	if not container then
		refuse(source, code, operation)
		return false, code
	end
	return true, nil, { secondary = Containers.Describe(container) }
end

--- Takes a pile into the bag without opening the screen, saying what stayed.
handlers.takeDrop = function(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local ok, code = Actions.TakeDrop(source, payload.id)
	-- A code with `ok` true means some stacks were left behind, which is still
	-- worth saying.
	if code then refuse(source, code, M.Operation.TAKE) end
	return ok, code
end

--- Opens a configured stash the player is standing at.
handlers.openStash = function(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local stash, code = Actions.OpenConfiguredStash(source, payload.name)
	return opened(source, stash, code, M.Operation.STASH)
end

--- Opens a vehicle's trunk, from outside the vehicle.
handlers.openTrunk = function(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local trunk, code = Actions.OpenVehicle(source, KIND.TRUNK, payload.vehicleId)
	return opened(source, trunk, code, M.Operation.VEHICLE)
end

--- Opens the seated vehicle's glovebox, silently when there is not one.
-- The open key asks for this first and falls back to the bag, so "not seated" and
-- "this vehicle has no glovebox" must not raise a toast on every press.
handlers.openGlovebox = function(source)
	if not World.Seat(source) then return false, 'not_seated' end
	local glovebox, code = Actions.OpenVehicle(source, KIND.GLOVEBOX)
	if not glovebox and code == 'no_storage' then return false, code end
	return opened(source, glovebox, code, M.Operation.VEHICLE)
end

--- Sends the players close enough to be handed something.
handlers.nearby = function(source)
	TriggerClientEvent(M.Event.NEARBY, source, Actions.Nearby(source))
	return true
end

--- Wires the request and hello doors.
-- @author dop42
function Requests.Wire()
	RegisterNetEvent(M.Event.REQUEST, function(requestId, action, payload)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		requestId = Common.Integer(requestId, 1, MAX_REQUEST_ID)
		if not requestId then return end

		-- THE WINDOW FIRST, then the verb. An unknown action was answered
		-- `bad_request` BEFORE the window was counted, so a client sending
		-- nothing but made-up verbs got one answer per packet, for ever, and
		-- never spent a request doing it -- the one shape of request the floor
		-- did not see. Every request now costs one, whatever it asks for.
		local allowed, tell = within(player)
		if not allowed then
			if tell then answer(player, requestId, false, 'too_fast') end
			return
		end

		local handler = type(action) == 'string' and handlers[action] or nil
		if not handler then return answer(player, requestId, false, 'bad_request') end

		CreateThread(function()
			local ok, code, data = handler(player, payload)
			answer(player, requestId, ok, code, data)
		end)
	end)

	-- The receiver's yes or no to a give. In the same window as every request:
	-- the answer is cheap, but a loop of them is still a loop.
	RegisterNetEvent(M.Event.GIVE_ANSWER, function(token, accepted)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(player) then return end
		local ok, code = Actions.AnswerGive(player, token, accepted == true)
		if not ok and code ~= 'give_gone' then refuse(player, code, M.Operation.GIVE) end
	end)
	OPX.Scheduler.Every('inventory:give-offers', 1000, Actions.SweepOffers)

	RegisterNetEvent(M.Event.HELLO, function()
		local player = tonumber(source) or 0
		if player <= 0 then return end
		local now = OPX.Now()
		if lastHello[player] and now - lastHello[player] < 2000 then return end
		lastHello[player] = now

		World.SendDrops(player)
		M.SendRuntimeItems(player)
		CreateThread(function()
			Players.Attach(player)
			local held = M.Weapons.Held(player)
			if held then M.Weapons.Announce(player, held) end
		end)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId) or 0
		windows[player] = nil
		lastHello[player] = nil
	end)

	-- A move between routing buckets, which the host raises under a name
	-- `OPX.Host` does not list (the appearance module reads the same one). Its
	-- payload is not documented, so only the player id is taken from it and the
	-- bucket is read from the server's own position.
	AddEventHandler(HOST_BUCKET_CHANGE, function(playerId)
		local player = tonumber(playerId) or 0
		if player <= 0 or not Options.DROPS then return end
		World.SendBucket(player)
	end)
end
