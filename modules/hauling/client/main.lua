--- Client half: three target rows, three bars, and no loop of its own.
-- @author dop42
--
-- A ROW ONLY EVER ASKS. The server finds the crate again from its own registry
-- and its own reading of where the player is standing; nothing drawn here is
-- believed by anything.
--
-- ============================================================================
-- THERE IS NO PERIODIC JOB IN THIS FILE, AND THAT IS THE DESIGN
-- ============================================================================
--
-- `core/client/scheduler.lua`'s header spells out why it matters. The platform
-- gives Lua 2000 microseconds a frame DIVIDED BY THE NUMBER OF RUNNING
-- RESOURCES, floor 50. This runtime is ONE resource, so all twenty-odd modules
-- share one slice and the scheduler runs at most four jobs per resume. A loop
-- that raises the instruction budget does not crash and does not log -- it
-- unwinds out of the coroutine body and IS NEVER RESUMED AGAIN, for the session.
-- A hauling job that quietly stopped offering rows halfway through an evening is
-- almost always that.
--
-- So the rows are registered ONCE, in `Start`, and never touched again. The three
-- `canInteract` predicates are table lookups against what the server pushed. No
-- sort, no scan, no distance pass -- and in particular not `nearbyDrops`'
-- sort-every-pass from `modules/inventory/client/world.lua:91-102`, which is fine
-- at one player's inventory scale and is not fine at a multi-site job's.
--
-- PROXIMITY IS THE SERVER'S JOB. It is free there -- one read of a position it
-- already holds -- and it is authoritative, which the client's answer could never
-- be. The rows draw; the server decides.
--
-- ============================================================================
-- WHICH ROW THE CRATE IS DRAWN UNDER, AND WHY THIS ONE
-- ============================================================================
--
-- `TARGET_KIND = 'prop'` is the default and what this ships as. The screen ray
-- reports what it hit as `context.target`, and the op77.76 card for
-- `Open77.camera.screenRaycast` says in as many words that `target` distinguishes
-- "canonical playerId, vehicleId, npcId and propId; propId is a decimal string".
-- `canonical` is the platform's own word for a server-owned entity -- the same
-- word its NPC and vehicle pages use -- and a server-owned prop's id IS a decimal
-- string. `modules/target/shared/model.lua:20-21` already lists `prop` as a kind
-- and `:164-165` already validates a `propId` as a decimal string, and
-- `registerProps` has been sitting in `modules/target/client/main.lua:725-734`
-- the whole time. So: ONE row, registered once, `canInteract` a lookup in a table
-- the server keeps up to date. Constant work per pick and no job at all.
--
-- WHAT IS NOT PROVEN is that the engine's physical pick returns a hit on a server
-- prop's collider at all -- that cannot be settled without standing in front of
-- one, and this repository has no way to do that. `TARGET_KIND = 'world'` is the
-- fallback if it turns out not to: one `RegisterWorld` row whose predicate
-- matches the HIT POINT against the crate positions the server pushed. Still one
-- row, still no job, and the player aims at the ground beside the crate rather
-- than at the crate.
--
-- `RegisterSpheres` is the design this deliberately does NOT use. It is a
-- per-pass proximity computation with `MAX_LIST = 32` spheres to a row, so a busy
-- site needs several rows re-registered on every single pickup -- which is
-- exactly the churn the budget above cannot afford.

local M = OPX.Modules.Get('hauling')
local Access, Step, Where = M.Access, M.Step, M.Where

-- The name this module registers its target rows under. The module id, which the
-- target registry reads as an owner that is always live.
local OWNER = 'hauling'

-- Every crate the server has told this client about, by prop id.
local crates = {}

-- Crates arriving in parts, gathered until the part marked `done`.
local incoming = nil

-- The crate this client is holding, as the server last said. NEVER inferred from
-- a successful request: the answer to every request carries it, so a refusal
-- corrects a client that had drifted.
local carrying = nil

-- The seller NPCs, by id as a decimal string. Pushed by the server whole.
local sellers = {}


-- The tokens the target rows were registered under, so `Stop` can take them back.
local tokens = {}

-- The contracts this half uses, read once in `Start`.
local target, progress = nil, nil

-- Whether a bar this module started is up, and what it was for. One at a time,
-- because the server only tracks one step per player.
local bar = nil

--- Whether a value is a decimal-string prop id, which is the only shape the
--- platform ever hands one out in. `tonumber` is never applied to one: they are
--- 64-bit and would not survive it.
local function propId(value)
	if type(value) ~= 'string' then return nil end
	if value:match('^[1-9]%d*$') == nil then return nil end
	return value
end

--- The squared distance between a hit point and a crate's own point.
local function gapSquared(at, crate)
	if type(at) ~= 'table' then return nil end
	local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
	if x == nil or y == nil or z == nil then return nil end
	local dx, dy, dz = x - crate.x, y - crate.y, z - crate.z
	return dx * dx + dy * dy + dz * dz
end

--- The crate a pick landed on, in whichever mode this client is running.
--
-- In `prop` mode this is a single table lookup and costs nothing. In `world` mode
-- it walks the crate list ONCE, on a pick -- which is a keypress and not a frame,
-- so it is the one place a scan is affordable.
local function picked(context, wanted)
	if type(context) ~= 'table' then return nil end

	if Access.TARGET_KIND == 'prop' then
		local hit = type(context.target) == 'table' and context.target or nil
		if hit == nil then return nil end
		local id = propId(hit.propId)
		if id == nil then return nil end
		local crate = crates[id]
		if crate == nil or crate.where ~= wanted then return nil end
		return crate
	end

	local at = context.position
	local best, bestGap = nil, Access.REACH_SQ
	for _, crate in pairs(crates) do
		if crate.where == wanted then
			local gap = gapSquared(at, crate)
			if gap ~= nil and gap <= bestGap then best, bestGap = crate, gap end
		end
	end
	return best
end

--- Asks the server to begin a step. It may refuse; the answer says so.
local function ask(step, subject)
	TriggerServerEvent(M.Event.BEGIN, step, subject)
end

--- Whether this client may be offered a pickup on what the ray hit.
local function canPickUp(context)
	if carrying ~= nil then return false end
	return picked(context, Where.GROUND) ~= nil
end

--- The seller NPC the ray hit, as the decimal string the server keyed it by.
local function seller(context)
	if type(context) ~= 'table' or type(context.target) ~= 'table' then return nil end
	local id = math.tointeger(context.target.npcId)
	if id == nil then return nil end
	local key = ('%d'):format(id)
	if sellers[key] == nil then return nil end
	return key
end

--- Whether this client may be offered a sale on what the ray hit.
-- What there is to sell is the server's to count -- the bag and every trunk
-- parked at the drop-off -- so an empty-handed player is offered the row and
-- told `no_crates`, which is the right failure.
local function canSell(context)
	if carrying ~= nil then return false end
	return seller(context) ~= nil
end

--- Whether this client may be offered a load on the vehicle it is looking at.
local function canLoad(context)
	if carrying == nil then return false end
	if type(context) ~= 'table' or type(context.target) ~= 'table' then return false end
	return math.tointeger(context.target.vehicleId) ~= nil
end

local function onPickUp(context)
	local crate = picked(context, Where.GROUND)
	if crate == nil then return end
	ask(Step.PICKUP, crate.id)
end

local function onSell(context)
	local key = seller(context)
	if key == nil then return end
	ask(Step.DELIVER, key)
end

local function onLoad(context)
	if type(context) ~= 'table' or type(context.target) ~= 'table' then return end
	-- A DECIMAL STRING ON THE WIRE. The id was sent as the number the eye
	-- answered, and a vehicle id carries a generation that can pass 2^53, where a
	-- JSON number stops being exact: the server would be asked to load into a
	-- different vehicle id than the one the player was looking at. Sent the way
	-- `modules/vehiclekeys` and the trunk screen send theirs.
	local vehicleId = math.tointeger(context.target.vehicleId)
	if vehicleId == nil or vehicleId < 1 then return end
	ask(Step.LOAD, ('%d'):format(vehicleId))
end

--- Registers the rows, once.
--
-- ONE CALL PER SHAPE AND NEVER AGAIN. The id-set changes constantly -- every
-- pickup, every delivery, every refill pass -- and NOT ONE of those changes
-- re-registers anything, because the rows do not name crates: they name a kind,
-- and the predicate reads the table. That is the whole reason this design was
-- worth answering the target-eye question for.
local function registerRows()
	if target == nil then return end

	local crateRows = {
		{
			id = 'hauling.pickup',
			label = locale('hauling.row.pickup'),
			description = locale('hauling.row.pickupHint'),
			icon = 'box',
			distance = Access.REACH,
			canInteract = canPickUp,
			onSelect = onPickUp,
			-- The thing itself: a crate on the floor is what the player walked up to.
			order = 5,
		},
	}

	local rows = Access.TARGET_KIND == 'world'
		and target.RegisterWorld(OWNER, crateRows)
		or target.RegisterProps(OWNER, crateRows)
	if rows.ok and type(rows.value.tokens) == 'table' then
		for _, token in ipairs(rows.value.tokens) do tokens[#tokens + 1] = token end
	else
		OPX.Note('hauling', ('the crate rows were refused: %s')
			:format(tostring(rows.error)))
	end

	local load = target.RegisterVehicles(OWNER, {
		id = 'hauling.load',
		label = locale('hauling.row.load'),
		icon = 'vehicle',
		distance = Access.VEHICLE_REACH,
		canInteract = canLoad,
		onSelect = onLoad,
		order = 4,
	})
	if load.ok then
		tokens[#tokens + 1] = load.value.token
	else
		OPX.Note('hauling', ('the load row was refused: %s'):format(tostring(load.error)))
	end

	local sell = target.RegisterNpcs(OWNER, {
		id = 'hauling.sell',
		label = locale('hauling.row.sell'),
		icon = 'money',
		distance = Access.VEHICLE_REACH,
		canInteract = canSell,
		onSelect = onSell,
		order = 4,
	})
	if sell.ok then
		tokens[#tokens + 1] = sell.value.token
	else
		OPX.Note('hauling', ('the sell row was refused: %s'):format(tostring(sell.error)))
	end
end

-- ── hands full ──────────────────────────────────────────────────────────────
--
-- The owner: "si ont porte le truc on puisse pas frapper n'y utiliser un item
-- inv". The server holsters the weapon at pickup and the inventory refuses item
-- use; this stops the weapon coming back out. `Attack` (firing) is marked
-- INFERRED by the platform and `Melee` is not blockable at all on 2.31, so a
-- bare-handed swing is the one thing left and nothing here can refuse it.
local HANDS_FULL = { 'Attack', 'WeaponWheel' }
local handsBlocked = false

-- THE PLAYER CONTROLS, which reach what `Open77.input` cannot. The owner: "tu
-- peux pas bloquer le fait qu'on puisse taper pendant qu'on porte une caisse ?"
-- `Melee` is not blockable as an input on 2.31, but `allowWeapons(false)` is the
-- game's own no-weapons restriction, and aim and shoot go with it. Released one
-- by one with `true` and NEVER with `resetControls`, which would hand back every
-- control block this resource holds -- the eye's, the downed screen's.
local CONTROLS = { 'allowWeapons', 'allowShoot', 'allowAim' }

--- Applies or releases the player controls, logging a refusal once.
local controlsNoted = false
local function holdControls(on)
	local players = Open77.players
	if type(players) ~= 'table' then return end
	for _, name in ipairs(CONTROLS) do
		if type(players[name]) == 'function' then
			local called, ok, why = pcall(players[name], not on)
			if on and (not called or ok ~= true) and not controlsNoted then
				controlsNoted = true
				OPX.Note('hauling', ('%s(false) was refused while carrying: %s')
					:format(name, tostring(called and why or ok)))
			end
		end
	end
end

--- Claims or releases the two actions and the controls, only on a change.
local function blockHands(on)
	if handsBlocked == on then return end
	handsBlocked = on
	holdControls(on)
	local input = Open77.input
	if type(input) ~= 'table' or type(input.setActionBlocked) ~= 'function' then return end
	for _, action in ipairs(HANDS_FULL) do
		local called, ok, why = pcall(input.setActionBlocked, action, on)
		if on and (not called or ok ~= true) then
			OPX.Note('hauling', ('%s could not be blocked while carrying: %s')
				:format(action, tostring(called and why or ok)))
		end
	end
end

--- Puts one crate into the local list, or takes it out.
local function keep(row)
	if type(row) ~= 'table' then return end
	local id = propId(row.id)
	if id == nil then return end
	crates[id] = { id = id, site = tostring(row.site or ''),
		x = tonumber(row.x) or 0.0, y = tonumber(row.y) or 0.0, z = tonumber(row.z) or 0.0,
		bucket = tonumber(row.bucket) or 0, where = tostring(row.where or Where.GROUND) }
end

--- Takes the bar down, whatever is holding it up.
local function dropBar()
	if bar == nil or progress == nil then return end
	bar = nil
	pcall(progress.Stop, OWNER, nil)
end

--- The key actually bound to the drop, as the host answered it.
local dropKey = nil

--- The crate the drop hint was last timed for, so it is timed once a carry.
local liftedFor = nil

-- Whether X may put the crate down now: only once the lift has played out, and
-- never while a bar (the load into a vehicle) is running.
local dropReady = false

--- Puts the carried crate down. The server decides; this only asks.
-- The owner: "pendant qu'on carry ont peux faire x pour la drop".
local function onDropKey()
	-- A key typed into a text field is not a key pressed in the world, and a
	-- press another feature on X owns is not this one's. Asked FIRST, before the
	-- crate is, because the contest is decided by whichever mapping asks first.
	if OPX.Spots.Captured() or not OPX.Spots.Key.Owns('hauling_drop') then return end
	-- The owner: "pendant qu'on load dans la voiture le joueur peux plus faire x".
	if carrying == nil or not dropReady or bar ~= nil then return end
	local yaw, groundZ = nil, nil
	local character = Open77.character
	if type(character) == 'table' and type(character.yaw) == 'function' then
		local read, value = pcall(character.yaw)
		if read and type(value) == 'number' then yaw = value end
	end
	-- THE FLOOR WHERE IT WILL LAND. The server has no physics and put the crate at
	-- the player's own height, which is not the floor. Cast from just above the
	-- player's head, not from the sky, so a roof or a balcony over them is not the
	-- ground. `Open77.character.position()` answers three numbers.
	if yaw ~= nil and type(character) == 'table' and type(character.position) == 'function'
		and type(Open77.world) == 'table' and type(Open77.world.groundZ) == 'function' then
		local read, x, y, z = pcall(character.position)
		if read and type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
			local radians = math.rad(yaw)
			local dx = x - math.sin(radians) * Access.DROP_DISTANCE
			local dy = y + math.cos(radians) * Access.DROP_DISTANCE
			local cast, ground = pcall(Open77.world.groundZ, dx, dy, z + 1.0)
			if cast and type(ground) == 'number' then groundZ = ground end
		end
	end
	TriggerServerEvent(M.Event.DROP, { yaw = yaw, z = groundZ })
end

--- Binds the drop key, once. A refusal costs the key and nothing else.
local function registerDropKey()
	if type(RegisterKeyMapping) ~= 'function' then
		return OPX.Note('hauling', 'this host has no RegisterKeyMapping: a crate cannot be put down')
	end
	-- `hauling_drop`, NOT `opx.hauling.drop`, AND IT STAYS THAT WAY. It is the
	-- one mapping id outside the `opx.<module>.<verb>` pattern, but a player's
	-- rebind is stored under the id: renaming it would silently put every
	-- rebound drop key back on X. The owner's call, 2026-10.
	local called, ok, answer = pcall(RegisterKeyMapping, 'hauling_drop',
		locale('hauling.key.drop'), Access.DROP_KEY, onDropKey)
	if not called or (ok ~= true and type(ok) ~= 'string') then
		return OPX.Note('hauling', ('the drop key was refused: %s')
			:format(tostring(called and answer or ok)))
	end
	dropKey = type(ok) == 'string' and ok ~= '' and ok
		or (type(answer) == 'string' and answer ~= '' and answer) or Access.DROP_KEY
	-- X is shared with the progress cancel, a call's decline and hang-up and the
	-- emote stop. A crate in the arms holds the press for its whole carry --
	-- during the lift too, where the drop itself still waits -- so the same X
	-- neither ends the call nor stops the carry pose under the crate.
	OPX.Spots.Key.Contend({ tag = 'hauling', id = 'hauling_drop', default = Access.DROP_KEY,
		wants = function()
			if carrying ~= nil then return OPX.Spots.Key.Rank('CARRY') end
			return nil
		end })
end

--- Wires the rows, the wire and the bar. No job is registered here on purpose.
-- @author dop42
function M.Start()
	target = OPX.Api.Get('target')
	progress = OPX.Api.Get('progress')

	if target == nil then
		-- The eye IS the entry to this job -- there is no command and no key. Without
		-- it there is nothing to draw and nothing to press, and saying so once is
		-- better than a client that looks like it is working.
		OPX.Note('hauling', 'the target eye is not available, so there is no way into this job')
		return
	end

	registerRows()
	registerDropKey()

	-- THE EYE HANDS BACK EVERY CONTROL THIS RESOURCE HOLDS when it closes -- its
	-- `controls(false)` is `Open77.players.resetControls()` -- and a player can open
	-- it with a crate in their arms. So the controls are put back after it.
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'target', 'closed'), function()
		if handsBlocked then holdControls(true) end
	end)


	RegisterNetEvent(M.Event.SNAPSHOT, function(part)
		if type(part) ~= 'table' then return end
		if part.first then incoming = {} end
		if incoming == nil then return end
		if type(part.crates) == 'table' then
			for _, row in ipairs(part.crates) do incoming[#incoming + 1] = row end
		end
		if not part.done then return end
		-- SWAPPED WHOLE, and only once the last part has landed. A list rebuilt
		-- part by part is a list that is briefly missing most of its crates, and a
		-- pick during that window would offer nothing on a crate that is right there.
		crates = {}
		for _, row in ipairs(incoming) do keep(row) end
		incoming = nil
	end)

	RegisterNetEvent(M.Event.CRATE, function(row)
		keep(row)
	end)

	RegisterNetEvent(M.Event.SELLERS, function(list)
		if type(list) ~= 'table' then return end
		local fresh = {}
		for _, row in ipairs(list) do
			if type(row) == 'table' and type(row.npc) == 'string' and row.npc:match('^%d+$') then
				fresh[row.npc] = { site = tostring(row.site or ''), dropoff = tostring(row.dropoff or '') }
			end
		end
		sellers = fresh
	end)

	RegisterNetEvent(M.Event.GONE, function(id)
		local key = propId(id)
		if key ~= nil then crates[key] = nil end
	end)

	RegisterNetEvent(M.Event.ANSWER, function(ok, reason, held)
		carrying = propId(held) or nil
		blockHands(carrying ~= nil)
		-- AFTER THE LIFT, NOT AT THE PICKUP. The owner: "la notification qui dit X
		-- pour drop faut qu'elle soit apres le load du carry de l'objet". The key
		-- goes live at the same moment, so the hint never offers a press that the
		-- lift would swallow.
		-- AND AFTER THE LIFT MEANS AFTER THE CRATE IS CARRIED. `held` comes back
		-- from the BEGIN of a pickup too -- the claim is theirs for the length of
		-- the kneel -- so timing the hint from the first id it named put "Press
		-- X to put the crate down" up two and a half seconds into a four-second
		-- bar, for a crate still on the floor and one a cancel would never give
		-- them. The server announces the crate CARRIED before it answers the
		-- finish, so the list already says so when this runs.
		local lifted = carrying ~= nil and crates[carrying] ~= nil
			and crates[carrying].where == Where.CARRIED
		if carrying == nil then
			dropReady = false
			liftedFor = nil
		elseif not lifted then
			dropReady = false
		elseif liftedFor ~= carrying then
			liftedFor = carrying
			dropReady = false
			local held = carrying
			CreateThread(function()
				Wait(M.LIFT_MS)
				if carrying ~= held then return end
				dropReady = true
				if dropKey ~= nil then
					-- The key it is bound to NOW: a player who rebound the drop
					-- was told the default they had moved it away from.
					OPX.Toast.Locale('hauling.hint.drop',
						{ key = OPX.Lib.Input.KeyFor('hauling_drop') or dropKey }, 'info', 'box')
				end
			end)
		end
		if not ok then
			dropBar()
			-- Every verdict goes on the public bus, refusals included: a HUD or a
			-- third party that wants to say something about a refused pickup reads
			-- this and does not have to guess from a toast.
			TriggerEvent(M.Event.ON_DECISION, { ok = false, reason = reason,
				carrying = carrying })
			if type(reason) == 'string' and reason ~= '' then
				-- THE KEY IS CHECKED BEFORE IT IS SHOWN. `locale` answers the KEY
				-- ITSELF for a string nobody wrote, which is the right behaviour for a
				-- log line and is `hauling.refused.invalid_attachment_bone` on a
				-- player's screen. Several refusals here come straight from the host --
				-- the `Open77.props.attach` reason set is eleven codes long and grows
				-- with the platform -- so there will never be a key for all of them.
				local key = 'hauling.refused.' .. reason
				if not OPX.Locale.Exists(key) then key = 'hauling.refused.generic' end
				OPX.Toast.Locale(key, nil, 'error', 'box')
			end
			return
		end
		TriggerEvent(M.Event.ON_DECISION, { ok = true, carrying = carrying })
	end)

	RegisterNetEvent(M.Event.RUN, function(spec)
		if type(spec) ~= 'table' or progress == nil then return end
		local durationMs = tonumber(spec.durationMs)
		if durationMs == nil or durationMs <= 0 then return end
		bar = tostring(spec.step)
		-- THE BAR IS PRESENTATION AND THE SERVER HOLDS THE CLOCK. This client counts
		-- down and then reports; the server refuses a report that arrived sooner
		-- than its own stamp allows, so shortening this bar buys nothing.
		local shown = progress.Start(OWNER, {
			label = locale('hauling.bar.' .. tostring(spec.step)),
			durationMs = durationMs,
			cancelable = true,
		})
		if type(shown) == 'table' and shown.ok ~= true then
			bar = nil
			TriggerServerEvent(M.Event.ABORT, 'no_bar')
			OPX.Note('hauling', ('the bar was refused: %s'):format(tostring(shown.error)))
		end
	end)

	-- The bar's own outcome. Only `finished` means the action happened; every
	-- other ending is the action NOT happening and must reach the server as an
	-- abort, or the claim sits there until the reap pass takes it.
	AddEventHandler(OPX.Modules.Get('progress').Event.ON_DONE, function(outcome)
		if type(outcome) ~= 'table' or outcome.owner ~= OWNER then return end
		if bar == nil then return end
		bar = nil
		if outcome.finished then
			TriggerServerEvent(M.Event.FINISH)
		else
			TriggerServerEvent(M.Event.ABORT, tostring(outcome.ending))
		end
	end)

	-- A character arriving is the moment this client needs the crate list: the
	-- first hello in `Start` is before there is anybody in the world, and a player
	-- who swaps character keeps this VM and would otherwise keep the old list.
	AddEventHandler(OPX.Modules.Get('character').Event.ON_LOADED, function()
		TriggerServerEvent(M.Event.HELLO)
	end)

	TriggerServerEvent(M.Event.HELLO)
end

--- Takes the rows back and drops any bar this module put up.
-- @author dop42
function M.Stop()
	dropBar()
	if target ~= nil then
		for _, token in ipairs(tokens) do pcall(target.Unregister, OWNER, token) end
	end
	tokens = {}
	blockHands(false)
	dropReady = false
	crates = {}
	sellers = {}
	carrying = nil
end
