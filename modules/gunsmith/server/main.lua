--- Registers the benches, answers the gate and opens the chests.
-- @author dop42
--
-- THIS FILE IS SHORT ON PURPOSE. Almost everything an armoury does is done by
-- two other modules: `crafting` holds the orders and `inventory` holds the
-- chest. What is left is the one question neither of them can answer -- whether
-- this character may work here -- and the wiring that puts the question in front
-- of them.
--
-- THE GATE IS A CALLBACK AND NOT A TABLE, which is what keeps the crafting
-- module ignorant of jobs. `crafting` calls `canUse(player, recipeKey)` when it
-- draws a row and again when it takes an order; the answer is decided here, from
-- this module's own config and the character contract's own roster. A design
-- that had handed crafting a JOBS table instead would have put a job gate in a
-- module that a cook and a ripperdoc also have to use.
--
-- THE SNAPSHOT IS STAMPED NOW. On this side there is no snapshot to go stale:
-- the roster is read out of the same VM at the moment the question is asked, so
-- `Evaluate`'s age test always passes and the staleness bound is really only
-- meaningful to a client drawing a picture. It is stamped rather than skipped so
-- the two halves run the same function over the same shape.

local M = OPX.Modules.Get('gunsmith')

local Access = M.Access

-- The contracts, resolved at Start.
local crafting, inventory, character = nil, nil, nil

-- Bench keys this module registered, so `Stop` takes back exactly what it gave.
local registered = {}

-- Least time between two chest presses by one player.
local CHEST_COOLDOWN_MS = 750

--- The job fields of a loaded character, stamped now, or nil.
local function jobSnapshot(player)
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local read, loaded = pcall(character.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then
		return nil
	end
	local data = loaded.PlayerData
	return {
		job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		atMs = OPX.Now(),
	}
end

--- Whether a player may work one armoury, or one recipe at it.
--
-- THE SHAPE THE CRAFTING CONTRACT ASKS FOR: `(player, recipeKey)` answering
-- `true` or `false, code`. A nil recipe key is "may they open this bench at
-- all"; a key is "may they order this one". The code it answers is a locale
-- key under `crafting.` -- see `modules/gunsmith/locales.lua`, which registers
-- the four sentences there and says why they live in another module's namespace.
local function gateFor(key)
	return function(player, recipeKey)
		local now = OPX.Now()
		local snapshot = jobSnapshot(player)
		if recipeKey == nil then
			local armoury = Access.Armoury(key)
			if armoury == nil then return false, 'no_such_bench' end
			return Access.Evaluate(armoury, snapshot, now, nil)
		end
		return Access.MayMake(key, recipeKey, snapshot, now)
	end
end

--- Opens one armoury's chest beside the player's bag.
--
-- THE CHEST IS A STASH AND NOTHING HERE KNOWS WHAT IS IN IT. `OpenStash` is
-- documented to leave the "may this player open this" question to its caller --
-- "a job, a key, a code" -- and to check only the reach, which it does against
-- the position handed to it. So this function is the job half of that bargain
-- and the inventory module is the distance half, and neither duplicates the
-- other.
--- The chest key a refusal names back: one that names a chest, or ''. The
--- client's own argument went back whatever it was, at whatever size.
local function echo(key)
	return Access.Chest(key) ~= nil and key or ''
end

local function openChest(player, key)
	if inventory == nil then
		TriggerClientEvent(M.Event.REFUSED, player, echo(key), 'unavailable')
		return
	end

	local armoury = Access.Armoury(key)
	local chest = Access.Chest(key)
	if armoury == nil or chest == nil then
		TriggerClientEvent(M.Event.REFUSED, player, echo(key), 'no_such_chest')
		return
	end

	local allowed, refusal = Access.Evaluate(armoury, jobSnapshot(player), OPX.Now(), nil)
	if not allowed then
		TriggerClientEvent(M.Event.REFUSED, player, echo(key), refusal or 'not_for_you')
		return
	end

	local opened = inventory.OpenStash(player, chest.name, {
		slots = chest.slots,
		maxWeight = chest.maxWeight,
		label = chest.label,
		position = { x = chest.x, y = chest.y, z = chest.z },
		bucket = chest.bucket,
	})
	if type(opened) ~= 'table' or not opened.ok then
		-- `OpenStash` answers `too_far`, `not_ready`, `not_loaded` and its
		-- siblings; they are passed through as they came so the player is told the
		-- real reason rather than a rounded-off one.
		--
		-- BUT ONLY THE ONES THAT HAVE WORDS. The client toasts `gunsmith.<code>`
		-- as it stands, and `OpenStash` also passes up what a container load
		-- answers -- `storage`, `load_timeout` -- for which this module has no
		-- sentence: the player was shown the raw key `gunsmith.storage`. Anything
		-- without a catalogue entry is the armoury being unreachable, which is
		-- what it is from where the player stands; the real code goes to the log.
		local code = type(opened) == 'table' and tostring(opened.error) or 'unavailable'
		if not OPX.Locale.Exists('gunsmith.' .. code) then
			Open77.log.warn(('[gunsmith] the chest of %s was refused for player %d: %s')
				:format(key, player, code))
			code = 'unavailable'
		end
		TriggerClientEvent(M.Event.REFUSED, player, echo(key), code)
		return
	end

	OPX.Audit.Log({ event = 'gunsmith.chest', message = chest.name, source = player,
		data = { armoury = key, stash = chest.name } })
end

--- Nothing to build and nothing to contribute. Never yields.
-- @author dop42
function M.Init()
	registered = {}
	crafting, inventory, character = nil, nil, nil
end

--- Registers every armoury's bench, and wires the chest door. On a coroutine.
-- @author dop42
function M.Start()
	crafting = OPX.Api.Get('crafting')
	character = OPX.Api.Get('character')
	inventory = OPX.Api.Get('inventory')

	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[gunsmith] config: ' .. line)
	end

	if inventory == nil then
		Open77.log.warn('[gunsmith] no inventory contract: the benches work and no chest opens')
	end

	if crafting == nil or type(crafting.RegisterBench) ~= 'function' then
		Open77.log.error('[gunsmith] no crafting contract: no armoury has a bench')
		return
	end

	local armouries = Access.List()
	for index = 1, #armouries do
		local key = armouries[index].key
		local definition = Access.BenchDefinition(key, gateFor(key))
		if definition ~= nil then
			local benchKey = M.BENCH_PREFIX .. key
			local placed = crafting.RegisterBench(benchKey, definition)
			if placed.ok then
				registered[#registered + 1] = benchKey
			else
				-- Named rather than counted: an operator reading this has to know
				-- WHICH armoury is missing, and `crafting` has already said what
				-- was wrong with the recipes in its own lines above this one.
				Open77.log.error(('[gunsmith] %s was refused a bench: %s (%s)')
					:format(key, tostring(placed.error), tostring(placed.detail)))
			end
		end
	end

	Open77.log.info(('[gunsmith] %d of %d armouries have a bench')
		:format(#registered, #armouries))

	RegisterNetEvent(M.Event.CHEST, function(key)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if type(key) ~= 'string' then return end
		-- Cooled: every press is a thread, and the first one per chest a database
		-- load. A fairness window, not an authority -- the gate is asked in full.
		if OPX.Cooling(player, 'gunsmith.chest', CHEST_COOLDOWN_MS) then return end
		-- A stash read yields, and a net handler that yields holds the event pump.
		CreateThread(function() openChest(player, key) end)
	end)
end

--- Takes back exactly the benches this module registered.
-- By OWNER and not by key, because the contract's own door is the owner one and
-- a list of keys walked by hand would go out of step with it the first time a
-- registration failed halfway.
-- @author dop42
function M.Stop()
	if crafting ~= nil and type(crafting.UnregisterBenches) == 'function' then
		pcall(crafting.UnregisterBenches, 'gunsmith')
	end
	registered = {}
end
