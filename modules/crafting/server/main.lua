--- The benches, the doors a client knocks on, and the one place an order is paid for.
-- @author dop42
--
-- EVERYTHING A CLIENT SENDS IS A NAME AND NOTHING ELSE: a bench key, a recipe
-- key, an order id. No cost, no duration, no yield and no position crosses the
-- wire in that direction, because all four are read here from tables a client
-- cannot reach. The screen is a renderer; `shared/recipes.lua` builds what it
-- renders, on this side, from what the bag and the purse actually hold.
--
-- Wallet changes belong to character. AtomicTrade couples the materials,
-- fee and order row; collection couples the output and ready-order deletion.
-- Unknown database replies reconcile their receipt without compensation.

local M = OPX.Modules.Get('crafting')

local Recipes = M.Recipes
local Refusal = M.Refusal
local Result = OPX.Result

-- Bench key -> the normalised bench. Registered during `Start` by whichever
-- module owns the place, and never read before then.
local benches = {}

-- Player id -> { started, count }, the request window. Per PLAYER and not per
-- bench: a client looping on the door costs the same whichever key it names.
local windows = {}
local ordering = {}

-- Set by `Stop`, so a thread that wakes during the teardown does not write.
local stopped = false

-- ── the small helpers ───────────────────────────────────────────────────────

--- Counts one request in a player's window, refusing at the limit.
-- Refusing rather than counting on through the window: a client that keeps
-- knocking must not be able to push its own reset further away.
local function within(player)
	local limits = Recipes.Limits()
	if limits.requests <= 0 then return true end
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= limits.windowMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limits.requests then return false end
	window.count = window.count + 1
	return true
end

--- A player's server-side position and routing bucket, or nil.
-- Read through a pcall and proved finite: `Open77.players.position` answers nil
-- for a slot that has already gone, and a caller that indexed that answer would
-- raise inside a network handler.
--- The bench key a refusal names back to the client, or ''.
---
--- `tostring(benchKey)` WAS ECHOED, and the key is the client's own argument:
--- whatever it sent came back, a 48 KiB string as 48 KiB and a table as
--- `table: 0x...` -- an address in this VM's heap, handed to anybody who asked.
--- Only a key that could name a bench is worth naming back.
local function echo(benchKey)
	return Recipes.Key(benchKey) or ''
end

local function positionOf(player)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.position) ~= 'function' then return nil end
	local read, at = pcall(players.position, player)
	if not read or type(at) ~= 'table' then return nil end
	local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
	if not (OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)) then
		return nil
	end
	return { x = x, y = y, z = z, bucket = math.floor(tonumber(at.bucket) or 0) }
end

--- The citizen id of a loaded character, or nil.
-- An order is filed under this and never under the connection slot: a slot is
-- recycled between sessions and a character is not, which is the whole reason an
-- order survives the player disconnecting.
local function citizenOf(player)
	local character = M.Contracts.character
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local read, loaded = pcall(character.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then
		return nil
	end
	local citizenId = loaded.PlayerData.citizenId
	return type(citizenId) == 'string' and citizenId ~= '' and citizenId or nil
end

--- Whether a player is standing at a bench.
-- A bench with NO position is in reach from anywhere by construction: the
-- consumer proved the place some other way and this module has nothing to
-- measure. A bench WITH one is measured here and only here -- the client's own
-- idea of the distance decides what it draws and nothing else.
local function reachOk(player, bench)
	if bench.position == nil then return true, nil end
	local at = positionOf(player)
	if at == nil then return false, Refusal.NO_POSITION end
	if at.bucket ~= bench.position.bucket then return false, Refusal.TOO_FAR end
	local dx = at.x - bench.position.x
	local dy = at.y - bench.position.y
	local dz = at.z - bench.position.z
	-- With the server's slack (`REACH_SLACK`), for every bench -- the gunsmith's
	-- among them: the row was offered from where the client stood.
	if math.sqrt(dx * dx + dy * dy + dz * dz) > OPX.Spots.ServerReach(bench.reach) then
		return false, Refusal.TOO_FAR
	end
	return true, nil
end

--- The consumer's own gate, asked under a pcall.
--
-- UNDER A pcall BECAUSE IT IS SOMEBODY ELSE'S CODE. A consumer's gate reads a
-- job, a key, a licence -- whatever its trade is -- and a raise in it must cost
-- that one answer and not the door. A gate that raises is read as a REFUSAL:
-- fail-closed, because the gate is the only thing standing between a player and
-- a bench that is not theirs, and the same choice `modules/elevators` makes for
-- a floor that declares JOBS. The counterpart of that rule is also kept: a bench
-- that declares NO gate is open to everyone and stays open, so a broken read
-- can never shut a place nobody was gating.
local function gateOk(bench, player, recipeKey)
	if bench.canUse == nil then return true, nil end
	local asked, allowed, why = pcall(bench.canUse, player, recipeKey)
	if not asked then
		Open77.log.error(('[crafting] the %s gate on %s raised: %s')
			:format(bench.owner, bench.key, tostring(allowed)))
		return false, Refusal.NOT_FOR_YOU
	end
	if allowed == true then return true, nil end
	return false, type(why) == 'string' and why or Refusal.NOT_FOR_YOU
end

--- What the bag holds of every material this bench can ask for.
-- Yields. One call per distinct material, which is what `bench.materials` is for.
local function carried(player, bench)
	local inventory = M.Contracts.inventory
	local have = {}
	if inventory == nil or type(inventory.GetItemCount) ~= 'function' then return have end
	for index = 1, #bench.materials do
		local name = bench.materials[index]
		local counted = inventory.GetItemCount(player, name)
		have[name] = (type(counted) == 'table' and counted.ok) and
			(tonumber(counted.value) or 0) or 0
	end
	return have
end

--- Every balance this character keeps, by money type.
local function purse(player)
	local character = M.Contracts.character
	if character == nil or type(character.GetMoney) ~= 'function' then return {} end
	local read, money = pcall(character.GetMoney, player)
	if not read or type(money) ~= 'table' then return {} end
	return money
end

--- An item's display name, through the inventory CONTRACT and not its namespace.
-- `GetItem` answers the catalogue view a screen reads; a name the catalogue no
-- longer carries answers nil and is drawn as itself, which is the honest thing
-- to show for a recipe whose material has been deleted from under it.
local function labelOf(name)
	local inventory = M.Contracts.inventory
	if inventory == nil or type(inventory.GetItem) ~= 'function' then return name end
	local read, entry = pcall(inventory.GetItem, name)
	if not read or type(entry) ~= 'table' then return name end
	return type(entry.label) == 'string' and entry.label or name
end

-- ── registration ────────────────────────────────────────────────────────────

--- Registers a bench. Consumers call this from their own `Start`.
--
-- The key is namespaced by its owner by convention -- `gunsmith:arasaka` -- and
-- the convention is not enforced, because a key is a database column value and
-- changing the rule later would orphan every row written under the old one. What
-- IS enforced is that two registrations of one key is an error rather than a
-- silent replacement: two consumers fighting over one bench is a bug in one of
-- them, and the loser's recipes would simply never appear.
-- @author dop42
-- @param key string
-- @param definition table label, owner, position, reach, queue, recipes, canUse
-- @return Result the number of recipes the bench carries
local function registerBench(key, definition)
	local inventory = M.Contracts.inventory
	-- The catalogue is what says whether an item name is real, and it is reached
	-- through the contract. A runtime that somehow has no inventory contract
	-- validates the SHAPE of every recipe and not the NAMES in it, which is
	-- strictly better than refusing them all.
	local known = nil
	if inventory ~= nil and type(inventory.GetItem) == 'function' then
		known = function(name)
			local read, entry = pcall(inventory.GetItem, name)
			return read and type(entry) == 'table'
		end
	end

	local bench, problems = Recipes.Bench(key, definition, known)
	for index = 1, #problems do
		Open77.log.warn('[crafting] ' .. problems[index])
	end
	if bench == nil then return Result.Err('invalid_bench', problems[1]) end

	if benches[bench.key] ~= nil then
		return Result.Err('bench_taken', ('%s is already registered by %s')
			:format(bench.key, benches[bench.key].owner))
	end

	benches[bench.key] = bench
	return Result.Ok(#bench.recipes)
end

--- Drops every bench one owner registered. For a consumer's `Stop`.
-- @author dop42
-- @param owner string
-- @return Result integer how many went
local function unregisterBenches(owner)
	if type(owner) ~= 'string' then return Result.Err('bad_argument', 'owner') end
	local gone = 0
	for key, bench in pairs(benches) do
		if bench.owner == owner then
			benches[key] = nil
			gone = gone + 1
		end
	end
	return Result.Ok(gone)
end

--- Drops one bench, when the owner named is the one that registered it.
-- @author dop42
-- @param key string
-- @param owner string
-- @return Result boolean whether a bench went
local function unregisterBench(key, owner)
	local bench = benches[Recipes.Key(key) or '']
	if bench == nil then return Result.Ok(false) end
	if bench.owner ~= owner then return Result.Err('not_owner') end
	benches[bench.key] = nil
	return Result.Ok(true)
end

--- Every registered bench, for a diagnostic.
-- @author dop42
-- @return Result
local function benchList()
	local out = {}
	for key, bench in pairs(benches) do
		out[#out + 1] = { key = key, owner = bench.owner, label = bench.label,
			recipes = #bench.recipes, queue = bench.queue,
			anchored = bench.position ~= nil }
	end
	table.sort(out, function(left, right) return left.key < right.key end)
	return Result.Ok(out)
end

-- ── the three things a player can do ────────────────────────────────────────

--- The screen for one player at one bench. Yields.
-- @author dop42
-- @param player Source
-- @param benchKey any
-- @return Result the view, or a refusal code
local function view(player, benchKey)
	local bench = benches[Recipes.Key(benchKey) or '']
	if bench == nil then return Result.Err(Refusal.NO_SUCH_BENCH) end

	local citizenId = citizenOf(player)
	if citizenId == nil then return Result.Err(Refusal.NO_CHARACTER) end
	-- No screen from the floor: a bench list is a menu of things to press, and
	-- the answer is `screen`, so a list already up comes down with it.
	if OPX.Life.Down(player) then return Result.Err(Refusal.DOWNED) end

	local allowed, refusal = gateOk(bench, player, nil)
	if not allowed then return Result.Err(refusal) end

	local near, tooFar = reachOk(player, bench)
	if not near then return Result.Err(tooFar) end

	local shelf = M.Storage.Orders(citizenId, bench.key, bench.queue)
	if not shelf.ok then
		Open77.log.error(('[crafting] the shelf at %s could not be read: %s')
			:format(bench.key, tostring(shelf.detail)))
		return Result.Err(Refusal.UNAVAILABLE)
	end

	return Result.Ok(Recipes.View(bench, carried(player, bench), purse(player), shelf.value,
		labelOf, function(recipeKey) return gateOk(bench, player, recipeKey) end))
end

--- Places one order. Yields.
-- @author dop42
-- @param player Source
-- @param benchKey any
-- @param recipeKey any
-- @return Result { id, seconds }
local function orderOnce(player, benchKey, recipeKey)
	local bench = benches[Recipes.Key(benchKey) or '']
	if bench == nil then return Result.Err(Refusal.NO_SUCH_BENCH) end

	local recipe = bench.byKey[Recipes.Key(recipeKey) or '']
	if recipe == nil then return Result.Err(Refusal.NO_SUCH_RECIPE) end

	local citizenId = citizenOf(player)
	if citizenId == nil then return Result.Err(Refusal.NO_CHARACTER) end
	-- Not from the floor, for the order as for the screen: the down screen is
	-- the client's, and a client on it can still send the press.
	if OPX.Life.Down(player) then return Result.Err(Refusal.DOWNED) end

	-- The bench gate and the recipe gate are two questions and both are asked:
	-- a consumer may open a workshop to every employee and keep one recipe for
	-- the ranks that have earned it.
	local allowed, refusal = gateOk(bench, player, nil)
	if not allowed then return Result.Err(refusal) end
	allowed, refusal = gateOk(bench, player, recipe.key)
	if not allowed then return Result.Err(refusal) end

	local near, tooFar = reachOk(player, bench)
	if not near then return Result.Err(tooFar) end

	local shelf = M.Storage.Shelf(citizenId, bench.key)
	if not shelf.ok then
		Open77.log.error(('[crafting] the shelf at %s could not be counted: %s')
			:format(bench.key, tostring(shelf.detail)))
		return Result.Err(Refusal.UNAVAILABLE)
	end

	-- RE-DECIDED HERE, from this moment's bag and this moment's purse. The view
	-- the player is looking at was built when they opened the screen and they may
	-- have spent the materials since; the view is a picture and this is the
	-- decision.
	-- The shelf count yielded: the connection may hold another character now,
	-- and what is taken below is taken from whoever it holds.
	if citizenOf(player) ~= citizenId then return Result.Err(Refusal.NO_CHARACTER) end

	local have = carried(player, bench)
	-- Both the shelf and bag reads can yield. Decide again at the point where
	-- materials are taken, including identity, access and the physical bench.
	if citizenOf(player) ~= citizenId then return Result.Err(Refusal.NO_CHARACTER) end
	if OPX.Life.Down(player) then return Result.Err(Refusal.DOWNED) end
	allowed, refusal = gateOk(bench, player, nil)
	if not allowed then return Result.Err(refusal) end
	allowed, refusal = gateOk(bench, player, recipe.key)
	if not allowed then return Result.Err(refusal) end
	near, tooFar = reachOk(player, bench)
	if not near then return Result.Err(tooFar) end
	local money = purse(player)
	local may, why = Recipes.Allowed(recipe, have,
		money[recipe.money or ''], shelf.value.cooking, bench.queue)
	if not may then return Result.Err(why) end

	local inventory = M.Contracts.inventory
	if type(inventory.AtomicTrade) ~= 'function' then return Result.Err(Refusal.UNAVAILABLE) end
	local changes = {}
	for index = 1, #recipe.inputs do
		local input = recipe.inputs[index]
		changes[index] = { name = input.item, count = -input.count }
	end
	local seconds = Recipes.ReadyIn(shelf.value.tail, recipe.seconds)
	local token
	local paid = inventory.AtomicTrade(citizenId, recipe.money or 'EDDIES', -recipe.price,
		changes, 'crafting:' .. bench.key, nil, function(op)
			if citizenOf(player) ~= citizenId then return nil, Refusal.NO_CHARACTER end
			local eligible, code = gateOk(bench, player, recipe.key)
			if not eligible then return nil, code end
			eligible, code = reachOk(player, bench)
			if not eligible then return nil, code end
			token = op.id
			return function(attempt)
				return M.Storage.OrderStatements(attempt, bench.key, recipe.key, recipe.seconds, bench.queue)
			end
		end)
	if not paid.ok then
		local code = paid.error
		if code == 'money.insufficient' or code == 'money.vetoed' then code = Refusal.CANNOT_PAY
		elseif code == 'not_enough' or code == 'empty_slot' then code = Refusal.SHORT end
		return Result.Err(code or Refusal.UNAVAILABLE)
	end
	-- Failure of this read cannot refund an order already committed with its
	-- materials and fee. The next shelf refresh shows it with its real id.
	local placed = M.Storage.Placed(citizenId, token)
	if not placed.ok or not placed.value then return Result.Err(Refusal.UNAVAILABLE) end

	OPX.Audit.Log({ event = 'crafting.order', message = ('%s at %s'):format(recipe.key,
		bench.key), citizenId = citizenId, source = player,
		data = { bench = bench.key, recipe = recipe.key, seconds = seconds,
			price = recipe.price } })
	OPX.Publish(M.Event.ON_ORDERED, player, { citizenId = citizenId, bench = bench.key,
		recipe = recipe.key, item = recipe.output, count = recipe.count, seconds = seconds,
		price = recipe.price, money = recipe.money, order = placed.value })

	return Result.Ok({ id = placed.value, seconds = seconds })
end

--- Holds a character's bench queue until its tail and new deadline are committed.
local function order(player, benchKey, recipeKey)
	local citizenId, key = citizenOf(player), Recipes.Key(benchKey)
	if citizenId == nil or key == nil then return orderOnce(player, benchKey, recipeKey) end
	local identity = citizenId .. '\0' .. key
	if ordering[identity] then return Result.Err(Refusal.TOO_FAST) end
	ordering[identity] = true
	local called, result = pcall(orderOnce, player, benchKey, recipeKey)
	ordering[identity] = nil
	if not called then
		Open77.log.error(('[crafting] an order at %s raised: %s'):format(key, tostring(result)))
		return Result.Err(Refusal.UNAVAILABLE)
	end
	return result
end

--- Hands over one finished order. Yields.
-- @author dop42
-- @param player Source
-- @param orderId any
-- @return Result { bench, item, count }
local function collect(player, orderId)
	local id = Recipes.Integer(orderId, 1, 4294967295)
	if id == nil then return Result.Err(Refusal.NO_SUCH_ORDER) end

	local citizenId = citizenOf(player)
	if citizenId == nil then return Result.Err(Refusal.NO_CHARACTER) end
	if OPX.Life.Down(player) then return Result.Err(Refusal.DOWNED) end

	local found = M.Storage.Find(citizenId, id)
	if not found.ok then
		Open77.log.error(('[crafting] order %d could not be read: %s')
			:format(id, tostring(found.detail)))
		return Result.Err(Refusal.UNAVAILABLE)
	end
	if found.value == nil then return Result.Err(Refusal.NO_SUCH_ORDER) end

	local shelved = found.value
	if not Recipes.IsReady(shelved) then return Result.Err(Refusal.NOT_READY) end

	local bench = benches[shelved.bench]
	if bench == nil then return Result.Err(Refusal.NO_SUCH_BENCH) end
	local recipe = bench.byKey[shelved.recipe]
	if recipe == nil then
		-- The recipe was edited out of the config under a placed order. The row is
		-- left alone: there is nothing to hand over and deleting it would throw
		-- away the only record that the player is owed something.
		Open77.log.warn(('[crafting] order %d names %s, which %s no longer carries')
			:format(id, shelved.recipe, bench.key))
		return Result.Err(Refusal.NO_SUCH_RECIPE)
	end

	local near, tooFar = reachOk(player, bench)
	if not near then return Result.Err(tooFar) end

	local inventory = M.Contracts.inventory
	-- ASKED BEFORE THE CLAIM, so the ordinary refusal -- a full bag -- never
	-- touches the row at all and the order is still there to try again for.
	local fits = inventory.CanCarry(player, recipe.output, recipe.count)
	if type(fits) ~= 'table' or not fits.ok or fits.value ~= true then
		return Result.Err(Refusal.NO_ROOM)
	end

	if citizenOf(player) ~= citizenId then return Result.Err(Refusal.NO_CHARACTER) end
	if type(inventory.AtomicTrade) ~= 'function' then return Result.Err(Refusal.UNAVAILABLE) end
	local given = inventory.AtomicTrade(citizenId, recipe.money or 'EDDIES', 0,
		{ { name = recipe.output, count = recipe.count } }, 'crafting:collect:' .. id,
		'crafting:collect:' .. id, function()
			return function(attempt) return M.Storage.CollectionStatements(attempt, id) end
		end)
	if not given.ok then return Result.Err(given.error or Refusal.UNAVAILABLE) end

	OPX.Audit.Log({ event = 'crafting.collect', message = ('%dx %s from %s')
		:format(recipe.count, recipe.output, bench.key), citizenId = citizenId,
		source = player, data = { bench = bench.key, recipe = recipe.key, order = id } })

	OPX.Publish(M.Event.ON_COLLECTED, player, { citizenId = citizenId, bench = bench.key,
		recipe = recipe.key, item = recipe.output, count = recipe.count, order = id })

	return Result.Ok({ bench = bench.key, item = recipe.output, count = recipe.count })
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- Sends a player the screen, or the reason there is none.
--
-- Every door answers, refusals included: a screen waiting on its own timeout
-- tells the player nothing, and a refusal is the one thing they can act on.
--
-- `acted` is the refusal of the thing they just TRIED, and it is sent only when
-- the screen itself can still be built. Sent unconditionally it produced two
-- identical toasts for one press: an order refused `too_far` is followed by a
-- view that is refused `too_far` for the same reason, and the player is told
-- twice that they are not standing at the bench. When the place is unreachable,
-- that is the only thing worth saying.
local function answer(player, benchKey, acted)
	local built = view(player, benchKey)
	if not built.ok then
		-- `true`: the SCREEN itself was refused, whatever the reason. Without it
		-- the client could only guess from a list of codes, and the job gate's
		-- (off duty, demoted, fired) were not on it: the stale list stayed up and
		-- its five-second refresh toasted "You must be on duty" until closed.
		TriggerClientEvent(M.Event.REFUSED, player, echo(benchKey), built.error, true)
		return
	end
	if acted ~= nil then
		TriggerClientEvent(M.Event.REFUSED, player, echo(benchKey), acted)
	end
	TriggerClientEvent(M.Event.VIEW, player, built.value)
end

--- Builds the state and contributes the table. Never yields.
-- @author dop42
function M.Init()
	benches, windows, stopped = {}, {}, false
	ordering = {}
	-- Filled in `Start`: `Init` runs before any contract is published, so a read
	-- here would answer nil for the life of the resource.
	M.Contracts = {}
	OPX.Schema.Add(M.Storage.SCHEMA)
	OPX.Schema.AddColumns(M.Storage.COLUMNS)
	OPX.Schema.AddIndexes(M.Storage.INDEXES)
end

--- Publishes the contract. Nothing may read one before this phase ends.
-- @author dop42
function M.Api()
	OPX.Api.Provide('crafting', 1, {
		RegisterBench = registerBench,
		UnregisterBenches = unregisterBenches,
		UnregisterBench = unregisterBench,
		Benches = benchList,

		View = view,
		Order = order,
		Collect = collect,
	})
end

--- Wires the doors. On a coroutine.
-- @author dop42
function M.Start()
	M.Contracts.inventory = OPX.Api.Get('inventory')
	M.Contracts.character = OPX.Api.Get('character')

	-- Both are `requires`, so a runtime that reached this line has them. The
	-- guard is for the case the registry cannot cover: a contract published under
	-- the right name by something that is not the module it says it is.
	if M.Contracts.inventory == nil or M.Contracts.character == nil then
		Open77.log.error('[crafting] the inventory or character contract is missing; no bench ' ..
			'can take an order')
		return
	end

	RegisterNetEvent(M.Event.OPEN, function(benchKey)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(player) then
			TriggerClientEvent(M.Event.REFUSED, player, echo(benchKey), Refusal.TOO_FAST)
			return
		end
		CreateThread(function()
			if stopped then return end
			answer(player, benchKey)
		end)
	end)

	RegisterNetEvent(M.Event.ORDER, function(benchKey, recipeKey)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(player) then
			TriggerClientEvent(M.Event.REFUSED, player, echo(benchKey), Refusal.TOO_FAST)
			return
		end
		CreateThread(function()
			if stopped then return end
			local placed = order(player, benchKey, recipeKey)
			-- THE SCREEN IS REFRESHED EITHER WAY. An order that went through has
			-- changed the bag, the purse and the shelf; one that did not may
			-- still have been refused BECAUSE those moved under the picture the
			-- player was looking at, and sending them the same stale picture back
			-- is how a player ends up pressing a row that can never work.
			answer(player, benchKey, (not placed.ok) and placed.error or nil)
		end)
	end)

	RegisterNetEvent(M.Event.COLLECT, function(benchKey, orderId)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(player) then
			TriggerClientEvent(M.Event.REFUSED, player, echo(benchKey), Refusal.TOO_FAST)
			return
		end
		CreateThread(function()
			if stopped then return end
			local taken = collect(player, orderId)
			answer(player, benchKey, (not taken.ok) and taken.error or nil)
		end)
	end)

	-- A player id is recycled, and a window left behind would rate-limit the next
	-- holder of the slot before they had knocked once.
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		windows[tonumber(playerId) or -1] = nil
	end)
end

--- Stops answering. The orders are rows and go on cooking without us.
-- @author dop42
function M.Stop()
	stopped = true
	benches, windows = {}, {}
end
