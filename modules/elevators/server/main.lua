--- Server half: adoption, floor requests, the sweep and the diagnostic.
-- @author dop42
--
-- The server does not see native lifts; a client does. A client reports one, and
-- the server picks the elevator, the bucket and the floor count itself. The
-- bucket is the ELEVATOR's and never the reporting player's: otherwise the first
-- passer-by would pin the lift into their own bucket for the life of the
-- process, invisible to everyone outside it.
--
-- Every value off the wire goes through `safe` before it reaches a format
-- string: a newline would forge a whole log line.

local M = OPX.Modules.Get('elevators')
local Access = M.Access

-- Elevator key to what this module adopted; the host stays the authority.
local owned = {}

-- Elevator key to the players told its id, so a release reaches all of them.
local told = {}

-- Per-player rate-limit windows: sightings, requests and log lines.
local sightWindows, requestWindows, logWindows = {}, {}, {}

-- Elevator keys whose floor-count mismatch has been logged, and whether the
-- malformed engine hash rejection has been. Said once each: a format
-- disagreement on the wire would otherwise only ever show as `not_adopted`.
local warnedCount, warnedEntity = {}, false

-- Sightings one player may report per second.
local SIGHTS_PER_SECOND = 12

-- Age past which a never-used adoption is released, and past which the sweep
-- collects a rate-limit window.
local UNUSED_MS = 600000
local WINDOW_GC_MS = 60000

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

-- Whether the sweep should keep running.
local running = false

local coordinate, integer = Access.Coordinate, Access.Integer

-- Compares two opaque engine identifiers as lower-cased strings.
local function sameEntity(left, right)
	return tostring(left or ''):lower() == tostring(right or ''):lower()
end

-- Cleans and caps a wire value before it reaches a log line.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

-- Counts one event in a player's window, refusing at the limit rather than
-- counting on through the rest of it.
local function within(windows, player, limit, spanMs)
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= spanMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limit then return false end
	window.count = window.count + 1
	return true
end

--- The job fields of a loaded character, read from the character contract.
-- Stamped now, because the server reads the roster in its own VM: there is no
-- snapshot to go stale here, and `Evaluate`'s age test always passes.
-- @author dop42
-- @param player Source
-- @return table|nil
local function jobSnapshot(player)
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, loaded = pcall(api.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	local data = loaded.PlayerData
	return {
		job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		atMs = OPX.Now(),
	}
end

-- The host's flag constants, read at the moment of use and never cached: the
-- table belongs to the native layer, and a reference kept across a resource
-- reload would outlive the layer that published it. Nil when the build has no
-- usable `flags` table, which every caller below reads as "this lift cannot be
-- gated" and refuses on.
--
-- `Open77.elevators.flags` -- powered 1, locked 2, interactionAllowed 4,
-- doorsClosed 8 -- is documented in the op77.76 elevator guide and named by the
-- `setFlags` card, but a constant TABLE is not a native, so the devkit's native
-- catalogue has no entry for it and cannot confirm it. Unverified is not absent.
-- What must not happen either way is the thing this replaces: indexing it blind
-- inside a network handler, where a missing table is a raise that takes the
-- handler down mid-adoption and leaves the lift adopted and ungated.
local function flagBits()
	local lifts = Open77.elevators
	local flags = type(lifts) == 'table' and lifts.flags or nil
	if type(flags) ~= 'table' then return nil end
	local locked, powered = tonumber(flags.locked), tonumber(flags.powered)
	if locked == nil or powered == nil then return nil end
	return locked, powered
end

-- Sets the host's locked flag on one lift, keeping the others: `powered` stays
-- as the host put it. The elevator authority then refuses a request a client
-- sends directly.
--
-- `setFlags` REPLACES the mask rather than merging into it, which is why the
-- snapshot is read first: writing a bare `locked` would clear `powered` and
-- leave a dead cabin the server could still schedule trips on.
--- Gives an adopted lift back, reading whether the host really took it back.
--- Both rollback paths below used a bare `pcall` and discarded the answer. A
--- refused release is the worst outcome of the three: this module forgets the
--- lift while the host still records it as adopted, so nothing here can drive
--- it, release it or adopt it again, and the shaft is dead until the resource
--- restarts. It cannot be undone from here, so it is named.
local function releaseAdoption(id, why)
	local called, released, reason = pcall(Open77.elevators.remove, id)
	if not called or released == false then
		Open77.log.error(('[elevators] lift %s could not be given back after %s (%s); ' ..
			'the host still holds it and nothing here can drive it')
			:format(tostring(id), tostring(why), tostring(called and reason or released)))
		return false
	end
	return true
end

local function applyLock(id)
	local locked = flagBits()
	if locked == nil then return false end
	local lift = Open77.elevators.get(id)
	if lift == nil then return false end
	local flags = (lift.flags or 0) | locked
	if flags == lift.flags then return true end
	return Open77.elevators.setFlags(id, flags) == true
end

-- The only path to `goTo`, for a request and for recalling a cabin a departing
-- rider left in motion. A raise becomes a refusal rather than leaving a network
-- handler without an answer.
local function moveCabin(id, index)
	local travelMs = OPX.Tune.Number('ELEV_TRAVEL_MS', 0)
	local called, moved = pcall(Open77.elevators.goTo, id, index, { travelMs = travelMs })
	return called and moved ~= nil and moved ~= false
end

-- Whether a host-reported lift stands at a configured elevator. The host nests
-- the position under `position` in one shape and flattens it in the other.
local function atElevator(key, lift)
	local position = lift.position or lift
	local x, y = coordinate(position.x), coordinate(position.y)
	if x == nil or y == nil then return false end
	local flat = Access.FlatDistanceSquared(key, x, y)
	return flat ~= nil and flat <= Access.MATCH_RADIUS_SQ
end

-- Takes ownership of a sighted native lift, or re-claims one this module held
-- before a restart. A re-claim carries `atMs` for the same reason a fresh
-- adoption does: without it `at - at` never passes the sweep's threshold, and a
-- key re-claimed after a restart -- exactly the case where the hash came off the
-- wire unverified -- would never heal.
local function adopt(key, entity, x, y, z, bucket, floorCount, activeFloor)
	local adopted = Open77.elevators.all(bucket)
	local adoptedCount = type(adopted) == 'table' and #adopted or 0
	for index = 1, adoptedCount do
		local existing = adopted[index]
		if sameEntity(existing.engineEntity, entity) then
			-- The hash came off the wire, so the lift must stand at the key's own
			-- position: another elevator's hash would otherwise point this key at
			-- that cabin.
			if not atElevator(key, existing) then
				return { ok = false, error = 'wrong_place' }
			end
			for otherKey, record in pairs(owned) do
				if otherKey ~= key and record.id == existing.id then
					return { ok = false, error = 'already_owned', reason = otherKey }
				end
			end
			-- Re-locked because the flag did not survive the restart and `adopt`
			-- does not run again.
			--
			-- AND THE RE-CLAIM IS ABANDONED WHEN THE LOCK WILL NOT TAKE, where it
			-- used to be kept with a warning beside it. `all(bucket)` reports every
			-- adopted lift in the bucket and not only this module's, so the lift
			-- matched here may belong to `open77_elevators` -- which is exactly the
			-- conflict the module header describes -- and `setFlags` on another
			-- owner's cabin is refused. Binding it anyway produced the worst of the
			-- three outcomes: a shaft this module advertises a job-gated panel for,
			-- that the other owner leaves unlocked, and that therefore rides to any
			-- floor off the vanilla button. Refusing leaves the panel shut and the
			-- warning is the sighting log line a floor below.
			if not applyLock(existing.id) then
				return { ok = false, error = 'not_locked' }
			end
			owned[key] = { id = existing.id, floorCount = existing.floorCount, atMs = OPX.Now() }
			return { ok = true, id = existing.id, already = true }
		end
	end

	-- LOCKED BY THE ADOPTION ITSELF, and not by the `setFlags` that follows it.
	--
	-- `Open77.elevators.adopt` defaults a lift it takes over to `powered` plus
	-- `interactionAllowed`, which is a cabin that ACCEPTS PLAYER REQUESTS -- and
	-- the platform converts a press of the vanilla in-cabin floor button into
	-- exactly such a request before the game's own local movement runs. So every
	-- millisecond between the adopt and the lock was a window in which anyone
	-- standing in the cabin rode to a job-gated floor by pressing the button
	-- Cyberpunk already draws, with this module never asked and the whole JOBS
	-- block in `config/elevators.lua` reduced to advice about which buttons the
	-- panel greys out. Handing the mask to `adopt` closes the window rather than
	-- narrowing it.
	--
	-- `powered | locked` and not `locked` alone: an unpowered lift is refused the
	-- server's own scheduled trips too, and this module is the only thing that is
	-- supposed to be able to move the cabin. It is the idiom the `setFlags` card
	-- gives for precisely this -- keep it powered, make it not usable.
	--
	-- `interactionAllowed` is deliberately NOT set. `locked` is what refuses a
	-- request, and dropping the bit that invites one as well means a build that
	-- reads the two flags in the other order still ends up refusing.
	local locked, powered = flagBits()
	if locked == nil then
		-- Refused rather than adopted bare. An adoption with no reachable lock is
		-- an ungated cabin wearing this module's name, which is strictly worse
		-- than the untouched vanilla lift standing there now.
		return { ok = false, error = 'no_flag_constants' }
	end

	local ok, id, reason = pcall(Open77.elevators.adopt, {
		engineEntity = entity,
		position = { x = x, y = y, z = z },
		bucket = bucket,
		floorCount = floorCount,
		initialFloor = activeFloor,
		flags = powered | locked,
	})
	if not ok then return { ok = false, error = 'adopt_raised', reason = tostring(id) } end
	if id == nil then return { ok = false, error = 'adopt_refused', reason = tostring(reason) } end

	-- WHERE THE LIFT ACTUALLY IS, asked of the host rather than taken from the
	-- client. The hash and the position both came off the wire, and
	-- `Open77.elevators.adopt` validates neither -- its only refusals are
	-- `elevators_unavailable` and a permission. So a client could pair one lift's
	-- hash with another lift's coordinates and have this key adopt, and lock, the
	-- wrong cabin. The re-claim branch above has always checked this; a first
	-- adoption never did.
	--
	-- Released rather than kept: an adoption pointing at the wrong cabin is worse
	-- than none, because `applyLock` would then freeze a lift nobody asked about.
	--
	-- ONLY WHEN THE HOST ANSWERS. A `get` that says nothing is not a disagreement
	-- and must not undo a legitimate adoption -- `applyLock` below already treats
	-- the same silence as a line rather than a rollback. A forged hash cannot use
	-- that door: it names a lift that DOES exist, somewhere else.
	local settled = Open77.elevators.get(id)
	if type(settled) == 'table' and not atElevator(key, settled) then
		releaseAdoption(id, 'wrong_place')
		return { ok = false, error = 'wrong_place' }
	end

	-- The mask went in with the adoption above, so this READS BACK whether it took
	-- rather than being the thing that applies it. `flags` is a field a host that
	-- predates it ignores in silence, and the answer to "did the lift come up
	-- locked" is not something this module may assume from its own request.
	--
	-- A rollback and not a line, which is the change from the warning that used to
	-- stand here. An adopted lift that is not locked is the one state worse than
	-- no adoption: this module has taken the cabin, told the client its id and
	-- drawn a panel that greys floors, while the lift underneath rides anywhere
	-- off the vanilla button. Releasing it gives the shaft back to Cyberpunk --
	-- a working lift that gates nothing, which is what it is either way, minus the
	-- false assurance.
	if not applyLock(id) then
		releaseAdoption(id, 'not_locked')
		return { ok = false, error = 'not_locked' }
	end

	owned[key] = { id = id, floorCount = floorCount, atMs = OPX.Now() }
	return { ok = true, id = id }
end

-- Validates a client's lift sighting and adopts or binds the elevator.
local function onSighted(player, entity, x, y, z, floorCount, activeFloor)
	if not within(sightWindows, player, SIGHTS_PER_SECOND, 1000) then return end

	if type(entity) ~= 'string' or
		entity:match('^0[xX]%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$') == nil then
		if not warnedEntity then
			warnedEntity = true
			Open77.log.warn(('[elevators] sighting rejected: first argument is not an engine hash ' ..
				'(%s); the client and this handler disagree about the wire format'):format(safe(entity)))
		end
		return
	end
	x, y, z = coordinate(x), coordinate(y), coordinate(z)
	floorCount, activeFloor = integer(floorCount), integer(activeFloor)
	if x == nil or y == nil or z == nil or floorCount == nil or activeFloor == nil then return end
	if floorCount < 1 or floorCount > 1025 or activeFloor < 0 or activeFloor >= floorCount then
		return
	end

	local position = Open77.players.position(player)
	if position == nil then return end
	local px, py, pz = coordinate(position.x), coordinate(position.y), coordinate(position.z)
	if px == nil or py == nil or pz == nil then return end
	local dx, dy, dz = x - px, y - py, z - pz
	if dx * dx + dy * dy + dz * dz > Access.SCAN_RADIUS_SQ then return end

	local key, elevator = Access.Locate(x, y, z, entity)
	if key == nil then return end

	local bucket = integer(elevator.BUCKET) or 0
	if position.bucket ~= bucket then return end

	-- The configured count becomes the ceiling every index is checked against.
	local declared = integer(elevator.FLOOR_COUNT)
	if declared ~= nil and declared >= 1 then
		if declared ~= floorCount and not warnedCount[key] then
			warnedCount[key] = true
			Open77.log.warn(('[elevators] %s reported %d floors, config declares %d; using the ' ..
				'config'):format(key, floorCount, declared))
		end
		floorCount = declared
		if activeFloor >= floorCount then activeFloor = 0 end
	end

	local record = owned[key]
	if record == nil then
		local result = adopt(key, entity, x, y, z, bucket, floorCount, activeFloor)
		if not result.ok then
			-- At most one line a second a player: a client reports faster than a
			-- disk writes.
			if within(logWindows, player, 1, 1000) then
				Open77.log.warn(('[elevators] %s not adopted: %s (%s)'):format(key, result.error,
					tostring(result.reason)))
			end
			return
		end
		Open77.log.info(('[elevators] %s adopted as elevator %s in bucket %s'):format(key,
			tostring(result.id), tostring(bucket)))
		record = owned[key]
	end
	told[key] = told[key] or {}
	told[key][player] = true
	-- The count is re-read from the record, which `adopt` settled between the
	-- config and the host: a fresh adoption and an already-adopted lift end in
	-- the same answer.
	TriggerClientEvent(M.Event.BOUND, player, key, record.id, record.floorCount)
end

-- Whether a player is down right now, read from the contract at the moment of
-- use. Without the contract nobody is down.
local function isDown(player)
	local api = OPX.Api.Get('downed')
	if api == nil or type(api.IsDown) ~= 'function' then return false end
	local read, answer = pcall(api.IsDown, player)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return false end
	return type(answer.value) == 'table' and answer.value.down == true
end

-- Drops an adoption and tells every player handed its id.
local function release(key)
	owned[key] = nil
	local audience = told[key]
	if audience == nil then return end
	for player in pairs(audience) do
		TriggerClientEvent(M.Event.RELEASED, player, key)
	end
	told[key] = nil
end

-- Checks everything the server can prove, then moves the cabin.
local function request(player, key, index)
	local limit = OPX.Tune.Number('ELEV_REQUESTS_PER_WINDOW', 0)
	local spanMs = OPX.Tune.Number('ELEV_REQUEST_WINDOW_MS', 0)
	if not within(requestWindows, player, limit, spanMs) then
		return { ok = false, error = 'rate_limited' }
	end

	local elevator = Access.Elevator(key)
	if elevator == nil then return { ok = false, error = 'no_such_elevator' } end
	index = integer(index)
	local floor = Access.Floor(key, index)
	if floor == nil then return { ok = false, error = 'no_such_floor' } end

	-- The job gate, re-derived here and not taken from the client: the client's
	-- own check only decides what its panel draws.
	local allowed, refusal = Access.Evaluate(floor, jobSnapshot(player), OPX.Now())
	if not allowed then return { ok = false, error = refusal } end

	-- AND THE DOWN SCREEN, which only the client's panel consulted: a client
	-- sending REQUEST itself called and rode a cabin while bleeding out on the
	-- floor. `teleports` refuses the same case on its server half.
	if isDown(player) then return { ok = false, error = 'downed' } end

	local record = owned[key]
	if record == nil then return { ok = false, error = 'not_adopted' } end
	local lift = Open77.elevators.get(record.id)
	if lift == nil then
		-- Released, not merely forgotten: a client holding the dead id would
		-- never report the lift again.
		release(key)
		return { ok = false, error = 'not_adopted' }
	end
	local floorCount = integer(lift.floorCount)
	if floorCount == nil or index >= floorCount then
		return { ok = false, error = 'floor_out_of_range' }
	end

	local position = Open77.players.position(player)
	if position == nil then return { ok = false, error = 'no_position' } end
	if position.bucket ~= lift.bucket then return { ok = false, error = 'wrong_bucket' } end
	local px, py = coordinate(position.x), coordinate(position.y)
	if px == nil or py == nil then return { ok = false, error = 'no_position' } end
	local reach = Access.FlatDistanceSquared(key, px, py)
	-- With the server's slack, as every place: see `REACH_SLACK`.
	if reach == nil or reach > OPX.Spots.ServerReachSq(Access.USE_RADIUS) then
		return { ok = false, error = 'too_far' }
	end

	if not moveCabin(record.id, index) then return { ok = false, error = 'move_rejected' } end
	record.usedAtMs = OPX.Now()
	record.rider = player
	record.rideEndsAtMs = record.usedAtMs + OPX.Tune.Number('ELEV_TRAVEL_MS', 0)
	return { ok = true, id = record.id, floor = index }
end

--- Answers whether a player may take a floor, deciding it on the server.
-- @author dop42
-- @param player Source
-- @param key string
-- @param index integer
-- @return Result
local function isFloorAllowed(player, key, index)
	local floor = Access.Floor(key, Access.Integer(index))
	if floor == nil then return OPX.Result.Err('no_such_floor') end
	local allowed, refusal = Access.Evaluate(floor, jobSnapshot(player), OPX.Now())
	if not allowed then return OPX.Result.Err(refusal or 'refused') end
	return OPX.Result.Ok({ elevator = key, floor = floor.INDEX, label = floor.LABEL })
end

--- Answers the floor list one player would be shown at an elevator.
-- @author dop42
-- @param player Source
-- @param key string
-- @return Result
local function floors(player, key)
	if Access.Elevator(key) == nil then return OPX.Result.Err('no_such_elevator') end
	return OPX.Result.Ok({
		elevator = key,
		floors = Access.List(key, jobSnapshot(player), OPX.Now()),
	})
end

--- Answers what this server has adopted, by elevator key.
-- @author dop42
-- @return Result
local function state()
	local adopted = {}
	for key, record in pairs(owned) do
		adopted[key] = { id = record.id, floorCount = record.floorCount,
			used = record.usedAtMs ~= nil }
	end
	return OPX.Result.Ok({ adopted = adopted })
end

-- Forgets a departing player.
--
-- A CABIN IN MOTION IS LEFT TO ARRIVE. It used to be recalled to floor 0 when
-- the player who last asked for a floor left mid-travel, which took every other
-- passenger away from the floor they were riding to. Now it finishes the trip
-- it was given with whoever is in it, and an empty cabin simply stays where it
-- stops: a floor nobody answers is the floor the rider chose, and the next
-- caller moves it.
local function forget(playerId, reason)
	local player = tonumber(playerId) or 0
	if player <= 0 then return end
	sightWindows[player] = nil
	requestWindows[player] = nil
	logWindows[player] = nil
	for _, players in pairs(told) do players[player] = nil end

	for key, record in pairs(owned) do
		if record.rider == player then
			record.rider = nil
			if (record.rideEndsAtMs or 0) > OPX.Now() then
				Open77.log.info(('[elevators] %s: rider %d left mid-travel (%s); the cabin ' ..
					'carries on'):format(key, player, tostring(reason)))
			end
		end
	end
end

-- One sweep pass: releases an adoption that never moved a cabin, and collects
-- the rate-limit windows. `within` creates a window on demand, so a packet that
-- arrives after a player left recreates the entry `forget` had just cleared and
-- nothing would ever clear it again; WINDOW_GC_MS is far longer than the widest
-- window asked for, so a present player's counter is never lost.
local function sweepOnce()
	local at = OPX.Now()
	for key, record in pairs(owned) do
		if record.usedAtMs == nil and at - (record.atMs or at) > UNUSED_MS then
			-- GIVEN BACK TO THE HOST, not only forgotten here. `release` clears this
			-- module's record and nothing else, so the lift stayed adopted and
			-- locked on the host; the client never re-reports a lift the host
			-- calls managed, so nothing re-bound it, and every request answered
			-- `not_adopted` -- a shaft dead until the resource restarted, which is
			-- the opposite of the healing this sweep is for. Unmanaged again, the
			-- lift is re-sighted and re-adopted, locked, by the next passer-by.
			releaseAdoption(record.id, 'ten minutes unused')
			release(key)

			Open77.log.warn(('[elevators] %s released: adopted %d minutes ago and never used')
				:format(key, math.floor(UNUSED_MS / 60000)))
		end
	end
	for _, windows in ipairs({ sightWindows, requestWindows, logWindows }) do
		for player, window in pairs(windows) do
			if at - (window.started or at) > WINDOW_GC_MS then windows[player] = nil end
		end
	end
end

-- Prints every elevator's position, floors and adoption state.
local function report(source, args)
	local lines = {}
	local problems = Access.Problems()
	for index = 1, #problems do lines[index] = 'config: ' .. problems[index] end
	local filter = args and args[1]
	local rows = {}
	-- Reachable on a host with no elevator API at all, where there is nothing to
	-- read back but the configuration.
	local lifts = type(Open77.elevators) == 'table' and Open77.elevators or nil
	for key, elevator in pairs(Access.ELEVATORS) do
		if (filter == nil or filter == key) and type(elevator) == 'table' then
			local record = owned[key]
			local lift = record and lifts and lifts.get(record.id) or nil
			rows[#rows + 1] = ('%s %s pos=%.2f,%.2f,%.2f floors=%d/%d id=%s %s'):format(
				key, tostring(elevator.LABEL), coordinate(elevator.X) or 0.0,
				coordinate(elevator.Y) or 0.0, coordinate(elevator.Z) or 0.0,
				type(elevator.FLOORS) == 'table' and #elevator.FLOORS or 0,
				integer(elevator.FLOOR_COUNT) or 0,
				record and tostring(record.id) or '-',
				lift and ('phase=%s floor=%s flags=%s'):format(tostring(lift.phase),
					tostring(lift.activeFloor), tostring(lift.flags)) or 'not adopted')
		end
	end
	-- Sorted, because `pairs` order would reshuffle the report between runs.
	table.sort(rows)
	for index = 1, #rows do lines[#lines + 1] = rows[index] end
	lines[#lines + 1] = ('denied=%s membership=%s'):format(tostring(M.Settings.DENIED_FLOORS),
		tostring(M.Settings.MEMBERSHIP))
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

-- Registers the ACL-gated diagnostic, when one is configured. It prints
-- positions and adoption state, which is operator information.
local function registerCommand()
	local name = M.Settings.COMMAND
	if type(name) ~= 'string' or name == '' then return end

	local keys = {}
	for key in pairs(Access.ELEVATORS) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)

	-- Core renders a command's own help at send time but passes its parameters
	-- through as written, so the parameter help is resolved here.
	OPX.Command.Register(name, {
		restricted = true,
		help = 'elevators.help.where',
		params = { { name = 'key', optional = true,
			help = locale('elevators.help.whereKey',
				{ keys = #keys > 0 and table.concat(keys, ', ') or '-' }) } },
	}, function(source, args)
		report(source, args)
	end)
end

--- Builds the adoption state and declares the operator numbers.
-- @author dop42
function M.Init()
	owned, told = {}, {}
	sightWindows, requestWindows, logWindows = {}, {}, {}
	warnedCount, warnedEntity = {}, false

	OPX.Tune.Declare{
		ELEV_TRAVEL_MS = { value = Access.FiniteNumber(M.Settings.TRAVEL_MS) or 0,
			type = 'integer', min = 0, max = 120000 },
		ELEV_REQUEST_WINDOW_MS = { value = Access.FiniteNumber(M.Settings.REQUEST_WINDOW_MS) or 0,
			type = 'integer', min = 0, max = 600000 },
		ELEV_REQUESTS_PER_WINDOW = { value = Access.FiniteNumber(M.Settings.REQUESTS_PER_WINDOW) or 0,
			type = 'integer', min = 0, max = 1000 },
	}
end

--- Publishes the server half of the elevators contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('elevators', 1, {
		Floors = floors,
		IsFloorAllowed = isFloorAllowed,
		State = state,
	})
end

--- Wires the sightings, the requests, the diagnostic and the sweep.
-- @author dop42
function M.Start()
	-- Registered whether or not the native API is there: an operator on such a
	-- host still has to be able to read back what the configuration says.
	registerCommand()

	if type(Open77.elevators) ~= 'table' then
		Open77.log.error('[elevators] native elevator API unavailable; no elevator will be adopted')
		return
	end

	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[elevators] config: ' .. line)
	end

	RegisterNetEvent(M.Event.SIGHTED, function(entity, x, y, z, floorCount, activeFloor)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		onSighted(player, entity, x, y, z, floorCount, activeFloor)
	end)

	RegisterNetEvent(M.Event.REQUEST, function(key, index)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		local result = request(player, key, index)
		-- The limit governs the cabin, not the answer: a request past it is still
		-- answered, so the player sees why nothing moved.
		TriggerClientEvent(M.Event.ANSWER, player, safe(key), integer(index),
			result.ok, result.error)
		if not result.ok and within(logWindows, player, 1, 1000) then
			Open77.log.info(('[elevators] player %d refused %s floor %s: %s'):format(player,
				safe(key), safe(index), tostring(result.error)))
		end
	end)

	AddEventHandler(M.ELEVATOR_REMOVED, function(id, _, reason)
		for key, record in pairs(owned) do
			if record.id == tonumber(id) then
				release(key)
				Open77.log.info(('[elevators] %s released: %s'):format(key, tostring(reason)))
				return
			end
		end
	end)

	-- The departure of an ADMITTED player. A connection refused at the gate
	-- raises a different event this module has no reason to hear.
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, forget)

	running = true
	CreateThread(function()
		while running do
			Wait(60000)
			-- Guarded per pass: a raise from a host call in a bare thread would end
			-- the sweep for the life of the process.
			local swept, failure = pcall(sweepOnce)
			if not swept then
				Open77.log.error('[elevators] the adoption sweep failed: ' .. tostring(failure))
			end
		end
	end)

	-- On a thread and not at load: a resource listed after this one is still
	-- `discovered` here.
	CreateThread(function()
		Wait(0)
		local read, resourceState = pcall(GetResourceState, M.OFFICIAL)
		local official = read and tostring(resourceState or ''):lower() or ''
		if official ~= 'running' and official ~= 'starting' then return end
		Open77.log.warn(('[elevators] %s is running; a lift adopted by one is refused to the other')
			:format(M.OFFICIAL))
		Open77.log.warn('  (the platform rejects a different owner), so whichever starts first owns')
		Open77.log.warn('  the cabin. Drop one from resources.load in server.jsonc.')
	end)

	Open77.log.info('[elevators] ready')
end

--- Stops the sweep and releases every adoption.
-- @author dop42
function M.Stop()
	running = false
	for key in pairs(owned) do release(key) end
end
