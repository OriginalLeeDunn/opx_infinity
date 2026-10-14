--- Client half: the character link, the scan and floor requests.
-- @author dop42
--
-- THE JOB CHECK HERE IS A HINT. It decides what the panel draws and refuses
-- early, and nothing more; the server re-derives the same decision from the
-- character roster in its own VM before it moves a cabin.
--
-- Range is measured across the ground against the DECLARED position, exactly as
-- the server measures it. When the host cannot give the player's position -- before
-- the world is ready, or a NaN -- the client falls back on the host's 3D distance
-- to the CABIN, which measures something else: it can then offer the panel up to
-- MATCH_RADIUS further out than the server accepts, and refuse it on a floor the
-- cabin is not at. The server's answer is the one that counts.

local M = OPX.Modules.Get('elevators')
local Access = M.Access
local State = M.State

M.Runtime = {}
local Runtime = M.Runtime

-- Milliseconds between two reports of one unadopted lift.
local SIGHT_RETRY_MS = 5000

-- Milliseconds between two reports of a lift the host already calls MANAGED
-- that this client was never bound to. Slower, because the likeliest answer is
-- "another owner holds it" and the server says so in its journal each time.
local MANAGED_RETRY_MS = 30000

-- Elevator key to when its lift was last reported.
local sighted = {}

-- Scheduler handles, so Stop can cancel them.
local scanJob, pullJob = nil, nil

-- Whether the missing elevator API was already logged.
local warnedApi = false

-- Raises the local decision event with a verdict.
local function publish(payload)
	TriggerEvent(M.Event.ON_DECISION, payload)
end

--- Re-reads the character from the character contract.
-- A contract that answers nothing is a character that is not there, and the gate
-- closes at once rather than waiting for the snapshot to age out.
-- @author dop42
local function pull()
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetPlayerData) ~= 'function' then
		State.Forget()
		return
	end
	local read, data = pcall(api.GetPlayerData)
	if not read or type(data) ~= 'table' or data.citizenId == nil then
		State.Forget()
		return
	end
	State.Adopt(data, OPX.Now())
end

-- Reads the player's own horizontal position, or nil.
local function playerXY()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then
		return nil, nil
	end
	local read, x, y = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then
		return nil, nil
	end
	return x, y
end

-- Records configured lifts in range and reports the unadopted ones. Topology
-- arrives asynchronously: a lift whose inspection has not answered yet waits for
-- the next scan. The `id` on a `nearby` entry is the server's and only exists
-- once the lift is managed.
local function scan()
	if type(Open77.elevators) ~= 'table' then return end
	local at = OPX.Now()
	-- Clamped to the 1..300 metres the native takes; `Problems` names a value
	-- outside it, and this keeps the scan working while it is fixed.
	local radius = math.max(1, math.min(300, tonumber(M.Settings.SCAN_RADIUS) or 40))
	local nearby = Open77.elevators.nearby(radius)
	if type(nearby) ~= 'table' then return end
	local playerX, playerY = playerXY()
	for index = 1, #nearby do
		local lift = nearby[index]
		local position = lift.position or {}
		local key = Access.Locate(position.x, position.y, position.z, lift.engineEntity)
		if key ~= nil then
			State.Sighted(key, lift, at, playerX, playerY)
			local ready = lift.floorCount ~= nil and lift.floorCount > 0 and
				lift.activeFloor ~= nil and lift.activeFloor >= 0
			-- A MANAGED LIFT THIS CLIENT WAS NEVER BOUND TO IS REPORTED TOO. Only
			-- unmanaged lifts used to be, so the server's re-claim branch -- a lift
			-- this module adopted before a restart, still adopted and locked on the
			-- host -- could never be reached: the shaft stayed locked and every
			-- floor request answered `not_adopted`. The server decides whether it
			-- is ours (it re-locks it) or another owner's (it refuses).
			local wait = lift.managed and MANAGED_RETRY_MS or SIGHT_RETRY_MS
			local due = sighted[key] == nil or at - sighted[key] >= wait
			if ready and State.bound[key] == nil and due then
				sighted[key] = at
				local accepted, reason = TriggerServerEvent(M.Event.SIGHTED,
					lift.engineEntity, position.x, position.y, position.z,
					lift.floorCount, lift.activeFloor)
				if not accepted then
					Open77.log.warn(('[elevators] sighting of %s was not sent: %s')
						:format(key, tostring(reason)))
				end
			end
		end
	end
end

--- Answers the Open77 id of a configured elevator, or nil.
-- This module's own binding wins over a scan: `nearby` also reports lifts other
-- owners have adopted.
-- @author dop42
-- @param key string
-- @return integer|nil
function Runtime.ElevatorId(key)
	local bound = State.bound[key]
	if bound ~= nil then return bound.id end
	local seen = State.seen[key]
	if seen ~= nil and seen.managed then return seen.id end
	return nil
end

--- Answers the elevator the player is standing at, or nil.
-- @author dop42
-- @return string|nil
function Runtime.Nearest()
	return State.Nearest(OPX.Now())
end

--- Answers the floor list for this player at an elevator.
-- @author dop42
-- @param key string|nil
-- @return table
function Runtime.Floors(key)
	key = key or Runtime.Nearest()
	if key == nil then return { ok = false, error = 'no_elevator_nearby' } end
	if Access.Elevator(key) == nil then return { ok = false, error = 'no_such_elevator' } end
	return { ok = true, elevator = key, floors = Access.List(key, State.snapshot, OPX.Now()) }
end

--- Decides locally whether this player may take a floor. A hint; see the header.
-- @author dop42
-- @param key string|nil
-- @param index integer
-- @return table
function Runtime.Check(key, index)
	key = key or Runtime.Nearest()
	if key == nil then return { ok = false, error = 'no_elevator_nearby' } end
	local elevator = Access.Elevator(key)
	if elevator == nil then return { ok = false, error = 'no_such_elevator', elevator = key } end
	local floor = Access.Floor(key, index)
	if floor == nil then
		return { ok = false, error = 'no_such_floor', elevator = key, floor = index }
	end
	local ok, failure = Access.Evaluate(floor, State.snapshot, OPX.Now())
	return {
		ok = ok,
		error = failure,
		elevator = key,
		floor = index,
		label = floor.LABEL,
		reason = (not ok) and floor.REASON or nil,
	}
end

--- Checks a floor locally, then sends the request to the server.
-- Without an id -- seen but not yet adopted -- the request is refused
-- `not_adopted` without leaving.
-- @author dop42
-- @param key string|nil
-- @param index integer
-- @param origin string|nil panel, or the caller's name
-- @return table
function Runtime.Use(key, index, origin)
	key = key or Runtime.Nearest()
	local result = Runtime.Check(key, index)
	result.source = origin or 'contract'
	if not result.ok then
		publish(result)
		return result
	end

	local id = Runtime.ElevatorId(key)
	if id == nil then
		result = { ok = false, error = 'not_adopted', elevator = key, floor = index,
			source = result.source }
		publish(result)
		return result
	end

	local accepted, reason = TriggerServerEvent(M.Event.REQUEST, key, index)
	if not accepted then
		result = { ok = false, error = tostring(reason or 'not_sent'), elevator = key,
			floor = index, source = result.source }
		publish(result)
		return result
	end
	result.queued = true
	return result
end

--- Answers the client state summary at the current time.
-- @author dop42
-- @return table
function Runtime.Report()
	return State.Report(OPX.Now())
end

--- Builds the client state.
-- @author dop42
function Runtime.Init()
	State.Reset()
	sighted, scanJob, pullJob, warnedApi = {}, nil, nil, false
end

--- Wires the server's answers and starts the scan and character polling.
-- @author dop42
function Runtime.Start()
	RegisterNetEvent(M.Event.BOUND, function(key, id)
		if type(key) ~= 'string' or Access.Elevator(key) == nil then return end
		State.bound[key] = { id = id }
		sighted[key] = nil
	end)

	RegisterNetEvent(M.Event.ANSWER, function(key, index, ok, failure)
		publish({
			elevator = key,
			floor = index,
			ok = ok == true,
			error = ok ~= true and tostring(failure or 'refused') or nil,
			source = 'server',
		})
		if ok ~= true then
			Open77.log.info(('[elevators] %s floor %s refused: %s')
				:format(tostring(key), tostring(index), tostring(failure)))
		end
	end)

	-- A released binding makes the next scan report the lift again.
	RegisterNetEvent(M.Event.RELEASED, function(key)
		if type(key) ~= 'string' then return end
		State.bound[key] = nil
		sighted[key] = nil
	end)

	-- Read once now, so a character already loaded gates the first panel. A
	-- POLL_MS the config got wrong reads as zero, which the scheduler would take
	-- as every pass, so it falls back to its own default and Problems says so.
	pull()
	pullJob = OPX.Scheduler.Every('elevators:character',
		Access.POLL_MS > 0 and Access.POLL_MS or 15000, pull)

	-- The character poll runs whether or not there is a lift to scan: the floor
	-- list and the gate answer without one.
	if type(Open77.elevators) ~= 'table' then
		if not warnedApi then
			warnedApi = true
			Open77.log.error('[elevators] native elevator API unavailable; nothing will be scanned')
		end
		return
	end
	-- A value under a whole millisecond is an error at boot and the scan does not
	-- start at all, rather than running empty or once a frame.
	if Access.SCAN_MS <= 0 then
		Open77.log.error('[elevators] SCAN_MS is not a whole number of milliseconds above zero; ' ..
			'nothing will be scanned')
		return
	end
	scanJob = OPX.Scheduler.Every('elevators:scan', Access.SCAN_MS, scan)
end

--- Cancels the scan and the character poll and forgets everything seen.
-- @author dop42
function Runtime.Shutdown()
	if scanJob ~= nil then
		OPX.Scheduler.Cancel(scanJob)
		scanJob = nil
	end
	if pullJob ~= nil then
		OPX.Scheduler.Cancel(pullJob)
		pullJob = nil
	end
	State.Reset()
	sighted = {}
end
