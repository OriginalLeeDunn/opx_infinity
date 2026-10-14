--- The benches, the doors a client knocks on, and the one place an order is paid for.
-- @author dop42
--
-- EVERYTHING A CLIENT SENDS IS A NAME AND NOTHING ELSE: a bench key, a recipe
-- key, an order id. No cost, no duration, no yield and no position crosses the
-- wire in that direction, because all four are read here from tables a client
-- cannot reach. The screen is a renderer; `shared/recipes.lua` builds what it
-- renders, on this side, from what the bag and the purse actually hold.
--
-- THE MONEY IS THE CHARACTER MODULE'S AND STAYS THERE. `RemoveMoney` and
-- `AddMoney` through the contract, with a reason string, and no balance of any
-- kind is kept here -- a second ledger is how a framework loses the first one.
--
-- WHAT IS NOT ATOMIC, SAID OUT LOUD. Placing an order touches three things that
-- are not in one transaction: the bag, the purse and this module's table. The
-- order below is chosen so the compensation is always possible -- materials
-- first, because putting a stack straight back into the bag it just left cannot
-- fail for room; then the fee, which is one call with one inverse; then the row.
-- A failure at any step undoes the steps before it, in reverse, and the failure
-- of an UNDO is the one thing loud enough to be an `error` line naming exactly
-- what the player is owed.

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

--- Puts materials back after something later in the sequence refused.
-- A stack that has just left this bag fits back into it, so a failure here is
-- not a case to handle but a case to SHOUT about: the player is owed items the
-- server could not give back, and that line is the only trace of it.
--
-- TO THE CHARACTER, NOT THE CONNECTION. The refusal that sends things back can
-- come after `Storage.Place` yielded, and by then the player may have left (the
-- bag already unloaded, without the inputs) or switched character in the world
-- (and the inputs went to the other one). The inventory contract takes a
-- citizen id, online or not, and gives back to the bag they came out of.
local function restore(citizenId, taken)
	local inventory = M.Contracts.inventory
	for index = #taken, 1, -1 do
		local back = inventory.AddItem(citizenId, taken[index].item, taken[index].count)
		if type(back) ~= 'table' or not back.ok then
			Open77.log.error(('[crafting] %dx %s could not be returned to %s: %s')
				:format(taken[index].count, taken[index].item, citizenId,
					type(back) == 'table' and tostring(back.error) or 'no answer'))
		end
	end
end

--- Gives a price back to the character that paid it, here or not. Yields.
-- `AddMoney` by connection answered `error.notLoggedIn` for a player who had
-- left during the order, and the answer was never read: the money was simply
-- gone. `AddMoneyOffline` pays a loaded character in memory and an absent one
-- in its row, under the character module's ledger.
local function refund(player, citizenId, recipe, bench)
	local character = M.Contracts.character
	local reason = ('crafting:refund:%s'):format(bench.key)
	local paid, code
	if type(character.AddMoneyOffline) == 'function' then
		local answer = character.AddMoneyOffline(citizenId, recipe.money, recipe.price, reason)
		paid = type(answer) == 'table' and answer.ok == true
		code = type(answer) == 'table' and answer.error or nil
	else
		paid, code = character.AddMoney(player, recipe.money, recipe.price, reason)
	end
	if not paid then
		Open77.log.error(('[crafting] %d %s could not be refunded to %s at %s: %s')
			:format(recipe.price, tostring(recipe.money), citizenId, bench.key, tostring(code)))
	end
end

-- A placement's own name: a tag drawn once per boot (so a restart never reuses
-- one) and a counter. 6 + 6 hex digits and a decimal, well inside the column.
local bootTag = ('%06x%s'):format(math.random(0, 0xFFFFFF),
	(tostring({}):match('(%x%x%x%x%x%x)$') or ''))
local nextToken = 0

--- How long `order` keeps asking whether a failed placement went in after all.
local PLACED_TRIES = 3
local PLACED_RETRY_MS = 500

--- Whether a placement whose answer was a failure is in the table anyway. Yields.
-- @return integer|nil the order id when it is, false when it is not, nil when
-- the database could not say
local function placedAnyway(citizenId, token)
	for attempt = 1, PLACED_TRIES do
		local found = M.Storage.Placed(citizenId, token)
		if found.ok then return found.value or false end
		if attempt < PLACED_TRIES then Wait(PLACED_RETRY_MS) end
	end
	return nil
end

--- Places one order. Yields.
-- @author dop42
-- @param player Source
-- @param benchKey any
-- @param recipeKey any
-- @return Result { id, seconds }
local function order(player, benchKey, recipeKey)
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

	local money = purse(player)
	local may, why = Recipes.Allowed(recipe, carried(player, bench),
		money[recipe.money or ''], shelf.value.cooking, bench.queue)
	if not may then return Result.Err(why) end

	local inventory = M.Contracts.inventory
	local taken = {}
	for index = 1, #recipe.inputs do
		local input = recipe.inputs[index]
		local removed = inventory.RemoveItem(player, input.item, input.count)
		if type(removed) ~= 'table' or not removed.ok then
			restore(citizenId, taken)
			return Result.Err(Refusal.SHORT)
		end
		taken[#taken + 1] = input
	end

	if recipe.price > 0 then
		local paid, refusalKey = M.Contracts.character.RemoveMoney(player, recipe.money,
			recipe.price, ('crafting:%s'):format(bench.key))
		if not paid then
			restore(citizenId, taken)
			Open77.log.info(('[crafting] player %d could not pay %d %s at %s: %s')
				:format(player, recipe.price, recipe.money, bench.key, tostring(refusalKey)))
			return Result.Err(Refusal.CANNOT_PAY)
		end
	end

	local seconds = Recipes.ReadyIn(shelf.value.tail, recipe.seconds)
	nextToken = nextToken + 1
	local token = ('%s-%d'):format(bootTag, nextToken)
	local placed = M.Storage.Place(citizenId, bench.key, recipe.key, seconds, bench.queue, token)
	if not placed.ok then
		-- AN ANSWER LOST IS NOT A ROW MISSING. The insert may have committed and
		-- only its answer failed to come back; refunding then handed back the
		-- materials and the price of an order that was cooking all the same.
		local found = placedAnyway(citizenId, token)
		if found then
			Open77.log.warn(('[crafting] the order at %s answered %s but was filed as %d; ' ..
				'it stands'):format(bench.key, tostring(placed.detail), found))
			placed = Result.Ok(found)
		elseif found == nil then
			-- Neither answer: refunding could pay twice and keeping could lose it.
			-- Kept, and said with everything needed to settle it by hand.
			Open77.log.error(('[crafting] the order %s of %s at %s (%s) could not be filed ' ..
				'or found (%s); NOTHING WAS REFUNDED. If no order with that token exists, ' ..
				'refund %d %s and the materials by hand'):format(token, citizenId, bench.key,
					recipe.key, tostring(placed.detail), recipe.price, tostring(recipe.money)))
			return Result.Err(Refusal.UNAVAILABLE)
		end
	end
	if placed.ok and placed.value == nil then
		-- THE SHELF FILLED BETWEEN THE CHECK ABOVE AND THE ROW: another order of
		-- this character's landed first. Nothing was promised, so everything
		-- taken goes back, exactly as for a row that could not be written.
		restore(citizenId, taken)
		if recipe.price > 0 then refund(player, citizenId, recipe, bench) end
		return Result.Err(Refusal.QUEUE_FULL)
	end
	if not placed.ok then
		-- THE ROW IS LAST FOR EXACTLY THIS CASE. Everything before it has an
		-- inverse and every inverse is run here; nothing has been promised to the
		-- player yet, so the order simply did not happen.
		restore(citizenId, taken)
		if recipe.price > 0 then refund(player, citizenId, recipe, bench) end
		Open77.log.error(('[crafting] the order at %s could not be filed: %s')
			:format(bench.key, tostring(placed.detail)))
		return Result.Err(Refusal.UNAVAILABLE)
	end

	OPX.Audit.Log({ event = 'crafting.order', message = ('%s at %s'):format(recipe.key,
		bench.key), citizenId = citizenId, source = player,
		data = { bench = bench.key, recipe = recipe.key, seconds = seconds,
			price = recipe.price } })
	OPX.Publish(M.Event.ON_ORDERED, player, { citizenId = citizenId, bench = bench.key,
		recipe = recipe.key, item = recipe.output, count = recipe.count, seconds = seconds,
		price = recipe.price, money = recipe.money, order = placed.value })

	return Result.Ok({ id = placed.value, seconds = seconds })
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

	local claimed = M.Storage.Claim(citizenId, id)
	if not claimed.ok then
		Open77.log.error(('[crafting] order %d could not be claimed: %s')
			:format(id, tostring(claimed.detail)))
		return Result.Err(Refusal.UNAVAILABLE)
	end
	-- Somebody else took it between the read and the DELETE, or the deadline had
	-- not actually passed by the database's clock. Either way this caller is not
	-- the one handing it over.
	if claimed.value ~= true then return Result.Err(Refusal.NO_SUCH_ORDER) end

	-- To the character the order is filed under: the claim yielded, and a
	-- connection that switched character meanwhile is somebody else's bag now.
	local given = inventory.AddItem(citizenId, recipe.output, recipe.count)
	if type(given) ~= 'table' or not given.ok then
		local back = M.Storage.Reshelve(citizenId, bench.key, recipe.key)
		if not back.ok then
			Open77.log.error(('[crafting] %dx %s was claimed for %s and could neither be given ' ..
				'nor re-shelved: %s'):format(recipe.count, recipe.output, citizenId,
				tostring(back.detail)))
		end
		return Result.Err(Refusal.NO_ROOM)
	end

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
