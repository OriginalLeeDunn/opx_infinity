--- Server half: the refusal, the move, and whether the body actually arrived.
-- @author dop42
--
-- THIS FILE IS THE GATE. A client sends a KEY and a LEG -- two strings, nothing
-- else -- and every other fact in the decision is read here: the destination out
-- of this VM's own copy of `config/teleports.lua`, the job out of the character
-- contract, the position and the routing bucket out of the host. A client that
-- can name a coordinate is a client that teleports anywhere, so it never gets
-- to name one; a client that hides its own prompt has hidden a prompt and
-- passed nothing. `modules/elevators/server/main.lua` refuses a floor the same
-- way, and the resemblance is deliberate.
--
-- WHAT IS CHECKED, IN THIS ORDER, and the order is not arbitrary -- the cheap
-- refusals come first so a client hammering the event pays nothing:
--
--   1. the per-player request window     (a counter, no reads)
--   2. one trip at a time                (a table lookup)
--   3. the destination exists            (`Access.Lookup`: key, leg, and the
--                                         back leg of a one-way)
--   4. the job gate                      (the character contract, re-derived)
--   5. not downed                        (the downed contract, if present)
--   6. standing on the entrance          (the host's own position and bucket)
--   7. the platform can move a body      (the native is there)
--
-- WHAT THE PLATFORM GUARANTEES ABOUT ARRIVAL, because the whole shape of `move`
-- below follows from it. `Open77.players.teleport` answers a PROMISE. It changes
-- the bucket, fades, issues the move, and then watches the client: the body must
-- be within 4 m horizontally and 6 m vertically of the mark, grounded, and in no
-- fall state, for three consecutive frames. While the body is on the point but
-- sinking -- an unstreamed floor -- it re-issues the teleport every 250 ms for up
-- to seven seconds, which is what keeps Cyberpunk's own
-- `PlayerTeleportationIfFallsUnderWorld` failsafe from yanking the player
-- kilometres away to the save's spawn of record with nothing told to anybody.
--
-- IT DOES NOT GUARANTEE ARRIVAL, and cannot: there is no streaming query
-- anywhere in the engine surface Open77 can reach, so "is the destination
-- loaded?" is not a question that can be asked. The promise RESOLVES `settled`
-- (all three tests held) or `near` (on the point, never reported grounded --
-- an honest success with a weaker claim, a mark on a prop or a very slow
-- stream-in), and REJECTS with `settle_timeout` when the body never stood there
-- inside the budget. So this half awaits the promise instead of assuming, and a
-- rejection is reported to the player as a failed trip AND logged against the
-- destination key -- because a destination that reliably times out is a
-- destination with nothing under it, which is an operator's bug and not a
-- player's.

local M = OPX.Modules.Get('teleports')
local Access = M.Access
local Result = OPX.Result

-- The configured teleports, taken once at Init.
local points = {}

-- Per-player rate-limit windows, and the one trip a player may have in flight.
local requestWindows, logWindows = {}, {}
local inFlight = {}

-- Per-key trip bookkeeping for the diagnostic: taken, refused, and the arrivals
-- that never happened.
local trips = {}

-- Keys whose first `settle_timeout` has been logged. A timeout repeated once a
-- second by a player standing on a broken pad would bury the journal; the first
-- one is the one that says the coordinate is wrong.
local warnedSettle = {}

-- Age past which the sweep collects a rate-limit window, and how often it runs.
-- Far longer than the widest window asked for, so a present player's counter is
-- never lost underneath them.
local WINDOW_GC_MS = 60000
local SWEEP_MS = 60000

-- A trip that somehow never settles its own lock. The platform's own watch is
-- bounded by SETTLE_MS (30 s at the most), so anything still marked in flight
-- well past that is a coroutine that died rather than a trip still running, and
-- the lock must not outlive it: a player locked out of the module for the rest
-- of the session is worse than the double-request the lock exists to prevent.
local FLIGHT_MAX_MS = 45000

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

-- Whether the sweep should keep running.
local running = false

local coordinate, integer = Access.Coordinate, Access.Integer

-- Cleans and caps a wire value before it reaches a log line: a newline off the
-- wire would forge a whole journal entry.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

-- Counts one event in a player's window, refusing AT the limit rather than
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

-- The per-key counters, created on demand.
local function tally(key)
	local row = trips[key]
	if row == nil then
		row = { taken = 0, refused = 0, lost = 0 }
		trips[key] = row
	end
	return row
end

--- The job fields of a loaded character, read from the character contract.
-- Stamped now, because the server reads the roster in its own VM: there is no
-- snapshot to go stale here, and the gate's age test always passes. A read that
-- fails answers nil, which the gate turns into `no_character` for a LOCKED
-- entrance and into nothing at all for an open one -- a broken character read
-- must not wall off a shortcut that was never locked.
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

--- Whether this player is bleeding out.
-- @author dop42
--
-- REFUSED, AND THIS IS THE EDGE WITH THE LEAST OBVIOUS ANSWER. A downed body is
-- still alive as far as the platform is concerned, so `Open77.players.teleport`
-- would happily move it -- and moving it is the wrong thing twice over: it takes
-- a player out from under whoever is kneeling over them reviving, and it lets a
-- downed player crawl to safety through a shortcut their own module has
-- deliberately pinned them out of. `modules/downed` owns the body while it is
-- down; this module does not take it off them.
--
-- An absent contract reads as NOT down. The downed module is optional, and a
-- server without it must not have every teleport refuse.
-- @param player Source
-- @return boolean
local function isDown(player)
	local api = OPX.Api.Get('downed')
	if api == nil or type(api.IsDown) ~= 'function' then return false end
	local read, answer = pcall(api.IsDown, player)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return false end
	return type(answer.value) == 'table' and answer.value.down == true
end

-- The server-side teleport native, or nil on a host that predates it.
--
-- Looked up at the moment of use and never cached: the table belongs to the
-- native layer, and a reference kept across a resource reload would outlive the
-- layer that published it. `Open77.players.teleport` arrived in 2.31.13+op77.67;
-- an older host loses this module and nothing else, which is why the absence is
-- a refusal with a name rather than a raise inside a net handler.
local function teleportNative()
	local players = Open77.players
	if type(players) ~= 'table' or type(players.teleport) ~= 'function' then return nil end
	return players.teleport
end

--- Reads a connection's position and bucket, or nil.
-- @param player Source
-- @return table|nil x, y, z, bucket
local function pointOf(player)
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = coordinate(position.x), coordinate(position.y), coordinate(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = integer(position.bucket) or 0 }
end

-- ── the list a client draws from ────────────────────────────────────────────

--- The entrances of one bucket, each already judged for this player.
--
-- `allowed` AND `reason` ON THE WIRE ARE PRESENTATION AND NOTHING ELSE. They are
-- what lets the client grey a marker red and put the operator's own words under
-- the key, so a locked teleport says WHY instead of saying nothing. The server
-- re-derives both when the key is actually pressed, from a snapshot read at that
-- moment, and a client that flips `allowed` to true in its own copy has changed
-- the colour of a marker.
local function payloadFor(player, bucket)
	local snapshot = jobSnapshot(player)
	local now = OPX.Now()
	local hide = Access.HidesDenied()
	local list = Access.InBucket(points, bucket)
	local out = {}
	for index = 1, #list do
		local entrance = list[index]
		local allowed, refusal = Access.Evaluate(entrance, snapshot, now)
		if allowed or not hide then
			out[#out + 1] = {
				key = entrance.key,
				leg = entrance.leg,
				label = entrance.label,
				x = entrance.x, y = entrance.y, z = entrance.z,
				allowed = allowed,
				error = refusal,
				-- The operator's own words, sent only when they are the answer.
				reason = (not allowed) and entrance.reason or nil,
			}
		end
	end
	return out
end

--- Sends one player the entrances of their own bucket.
local function sync(player)
	player = tonumber(player)
	if player == nil or player <= 0 then return end
	local at = pointOf(player)
	if at == nil then return end
	TriggerClientEvent(M.Event.SYNC, player, { entrances = payloadFor(player, at.bucket) })
end

-- ── the trip ────────────────────────────────────────────────────────────────

--- Everything the server can prove before it asks the platform to move anybody.
-- Pure of the world except for the three reads it names, and every exit is a
-- code the client has a sentence for.
-- @param player Source
-- @param key any off the wire
-- @param leg any off the wire
-- @return table { ok, error, entrance }
local function vet(player, key, leg)
	local limit = OPX.Tune.Number('TP_REQUESTS_PER_WINDOW', 0)
	local spanMs = OPX.Tune.Number('TP_REQUEST_WINDOW_MS', 0)
	if not within(requestWindows, player, limit, spanMs) then
		return { ok = false, error = 'rate_limited' }
	end

	-- ONE TRIP AT A TIME. The platform's own watch reports `settle_superseded`
	-- when a second placement starts before the first finishes -- there is one
	-- body, so there is one session -- and a player who mashed the key would
	-- otherwise cancel their own arrival and be left wherever the first move had
	-- got to, which is exactly the inside-the-geometry case this module is
	-- supposed to prevent.
	local flight = inFlight[player]
	if flight ~= nil and OPX.Now() - flight.atMs < FLIGHT_MAX_MS then
		return { ok = false, error = 'in_flight' }
	end

	local entrance = Access.Lookup(points, type(key) == 'string' and key or nil, leg)
	if entrance == nil then return { ok = false, error = 'no_such_teleport' } end

	local allowed, refusal = Access.Evaluate(entrance, jobSnapshot(player), OPX.Now())
	if not allowed then
		return { ok = false, error = refusal or 'refused', entrance = entrance }
	end

	if isDown(player) then return { ok = false, error = 'downed', entrance = entrance } end

	local at = pointOf(player)
	if at == nil then return { ok = false, error = 'no_position', entrance = entrance } end
	local standing, why = Access.AtEntrance(entrance, at.x, at.y, at.z, at.bucket)
	if not standing then return { ok = false, error = why or 'too_far', entrance = entrance } end

	if teleportNative() == nil then
		return { ok = false, error = 'unavailable', entrance = entrance }
	end

	return { ok = true, entrance = entrance }
end

--- Moves the body and waits to hear that it got there. YIELDS: callers run it on
--- a thread of its own.
-- @author dop42
--
-- `:await()` NEEDS A MANAGED COROUTINE. Called from anything that is not a
-- scheduler task it answers `nil, "await_requires_scheduler_coroutine"` rather
-- than parking the VM -- and a net handler is not one. So every path into this
-- function goes through a `CreateThread`, and the one that did not would report
-- every trip as a failure while every body moved anyway.
-- @param player Source
-- @param entrance table
-- @return boolean, string the arrival state, or the reason it never arrived
local function move(player, entrance)
	local native = teleportNative()
	if native == nil then return false, 'unavailable' end

	local to = entrance.to
	local fade = math.floor(OPX.Tune.Number('TP_FADE_MS', 0))
	local sent, pending, refused = pcall(native, player,
		{ x = to.x, y = to.y, z = to.z },
		{
			heading = to.heading,
			-- The teleport's own bucket, which is also the one the player was
			-- already standing in -- `AtEntrance` refused anything else. Passed
			-- anyway because the native changes the bucket BEFORE the move, so no
			-- observer left behind in the origin bucket ever sees the destination.
			bucket = entrance.bucket,
			fade = fade > 0,
			fadeOutMs = fade,
			fadeInMs = fade,
			-- OFF BY DEFAULT, AND THE REFUSAL IS THE FEATURE. A player in a
			-- vehicle is refused by the platform rather than ejected, and that is
			-- the behaviour this module wants: `dismount = true` accepts LOSING
			-- the vehicle, which leaves somebody's car parked across the pad it
			-- was driven onto. An operator who wants a drive-on pad sets DISMOUNT
			-- on that point and accepts the abandoned car.
			dismount = entrance.dismount == true,
			timeoutMs = math.floor(OPX.Tune.Number('TP_SETTLE_MS', 0)),
		})
	if not sent then return false, tostring(pending) end
	if pending == nil then return false, tostring(refused or 'refused') end

	-- A HOST THAT ANSWERED SOMETHING THAT IS NOT A PROMISE. The native is
	-- documented to answer one or `nil, reason`, but this module must not raise
	-- inside its own thread on a build that disagrees -- the body has already
	-- been asked to move by then, and the only thing lost would be the answer.
	if type(pending) ~= 'table' or type(pending.await) ~= 'function' then
		return false, 'no_promise'
	end

	local waited, arrival, failure = pcall(pending.await, pending)
	if not waited then return false, tostring(arrival) end
	-- `:await()` answers the resolved value, or `nil, reason` for a rejection.
	if arrival == nil then return false, tostring(failure or 'settle_timeout') end
	local state = type(arrival) == 'table' and tostring(arrival.state or 'settled') or 'settled'
	return true, state
end

--- Answers one player's request, start to finish. Runs on its own thread.
local function serve(player, key, leg)
	local verdict = vet(player, key, leg)
	if not verdict.ok then
		if verdict.entrance ~= nil then
			local row = tally(verdict.entrance.key)
			row.refused = row.refused + 1
		end
		TriggerClientEvent(M.Event.ANSWER, player, safe(key), safe(leg), false, verdict.error,
			verdict.entrance and verdict.entrance.reason or nil)
		-- At most one line a second a player: a client can ask faster than a disk
		-- writes, and a refusal is the thing an attacker would spam.
		if within(logWindows, player, 1, 1000) then
			Open77.log.info(('[teleports] player %d refused %s %s: %s'):format(player, safe(key),
				safe(leg), tostring(verdict.error)))
		end
		return
	end

	local entrance = verdict.entrance
	local flight = { atMs = OPX.Now(), key = entrance.key }
	inFlight[player] = flight
	local ok, outcome = move(player, entrance)

	-- THE LOCK IS LET GO ONLY IF IT IS STILL THIS TRIP'S. The move awaits for up
	-- to seven seconds; a player who left meanwhile was forgotten, and the slot
	-- may already belong to somebody whose own trip holds the lock now. Clearing
	-- it blind released THEIR lock, and the answer below landed on THEIR screen.
	local ours = inFlight[player] == flight
	if ours then inFlight[player] = nil end

	local row = tally(entrance.key)
	if not ours then
		if ok then row.taken = row.taken + 1 else row.lost = row.lost + 1 end
		return
	end
	if ok then
		row.taken = row.taken + 1
		TriggerClientEvent(M.Event.ANSWER, player, entrance.key, entrance.leg, true, nil,
			entrance.label)
		Open77.log.info(('[teleports] player %d took %s (%s) to %s: %s'):format(player,
			entrance.key, entrance.leg, entrance.label, outcome))
		return
	end

	row.lost = row.lost + 1
	TriggerClientEvent(M.Event.ANSWER, player, entrance.key, entrance.leg, false, outcome, nil)

	-- THE DESTINATION IS THE SUSPECT, not the player. `settle_timeout` means the
	-- body never stood at the mark inside the budget, and the watch will already
	-- have re-issued the move every 250 ms for seven seconds trying -- so the
	-- overwhelmingly likely cause is that there is no floor at the EXIT an
	-- operator wrote. Said once per key, with the coordinate in the line, because
	-- that is what somebody has to go and look at.
	if outcome == 'settle_timeout' and not warnedSettle[entrance.key] then
		warnedSettle[entrance.key] = true
		Open77.log.warn(('[teleports] %s (%s) never arrived: the body did not stand at ' ..
			'%.2f,%.2f,%.2f inside the watch. Check there is floor there -- an EXIT over a ' ..
			'void or inside geometry times out every time'):format(entrance.key, entrance.leg,
			entrance.to.x, entrance.to.y, entrance.to.z))
	else
		Open77.log.warn(('[teleports] player %d did not arrive at %s (%s): %s'):format(player,
			entrance.key, entrance.leg, tostring(outcome)))
	end
end

-- ── the contract ────────────────────────────────────────────────────────────

--- Answers whether a player may take one entrance, deciding it on the server.
-- The gate alone: it does not measure the distance, because a caller asking
-- "may this person use the rooftop" is not asking "are they standing on it".
-- @author dop42
-- @param player Source
-- @param key string
-- @param leg string
-- @return Result
local function isAllowed(player, key, leg)
	local entrance = Access.Lookup(points, type(key) == 'string' and key or nil, leg)
	if entrance == nil then return Result.Err('no_such_teleport') end
	local allowed, refusal = Access.Evaluate(entrance, jobSnapshot(player), OPX.Now())
	if not allowed then return Result.Err(refusal or 'refused') end
	return Result.Ok({ key = entrance.key, leg = entrance.leg, label = entrance.label })
end

--- Answers the entrances one player would be shown in their own bucket.
-- @author dop42
-- @param player Source
-- @return Result
local function entrances(player)
	-- A PLAYER ID FROM 1 UP, checked before the host is asked: this is a
	-- published contract, and `Open77.players.position(0)` -- the console's
	-- source -- does not answer nil, it throws past `pcall` and stops the
	-- resource (devkit card `server:Open77.players.position`).
	player = math.tointeger(tonumber(player))
	if player == nil or player < 1 then return Result.Err('no_position') end
	local at = pointOf(player)
	if at == nil then return Result.Err('no_position') end
	return Result.Ok({ bucket = at.bucket, entrances = payloadFor(player, at.bucket) })
end

--- Answers what this server has configured and how its trips have gone.
-- @author dop42
-- @return Result
local function state()
	local listed = {}
	for key, point in pairs(points) do
		local row = trips[key]
		listed[key] = {
			label = point.label,
			bucket = point.bucket,
			twoWay = point.twoWay,
			gated = point.jobs ~= nil,
			taken = row and row.taken or 0,
			refused = row and row.refused or 0,
			lost = row and row.lost or 0,
		}
	end
	return Result.Ok({ points = listed, count = OPX.Table.Count(points) })
end

-- ── the diagnostic ──────────────────────────────────────────────────────────

-- Prints every teleport: both ends, the gate, and how its trips have gone.
local function report(source, args)
	local lines = {}
	for _, line in ipairs(Access.Problems()) do lines[#lines + 1] = 'config: ' .. line end

	local filter = args and args[1]
	local rows = {}
	for key, point in pairs(points) do
		if filter == nil or filter == key then
			local row = trips[key]
			local gate = '-'
			if point.jobs ~= nil then
				local named = {}
				for name, minimum in pairs(point.jobs) do
					named[#named + 1] = ('%s>=%s'):format(tostring(name), tostring(minimum))
				end
				table.sort(named)
				gate = table.concat(named, ',') .. (point.onDuty and ' on-duty' or '')
			end
			rows[#rows + 1] = ('%s %s bucket=%d %s entry=%.2f,%.2f,%.2f exit=%.2f,%.2f,%.2f ' ..
				'jobs=%s taken=%d refused=%d lost=%d'):format(
				key, point.label, point.bucket, point.twoWay and 'two-way' or 'one-way',
				point.entry.x, point.entry.y, point.entry.z,
				point.exit.x, point.exit.y, point.exit.z, gate,
				row and row.taken or 0, row and row.refused or 0, row and row.lost or 0)
		end
	end
	-- Sorted, because `pairs` order would reshuffle the report between runs.
	table.sort(rows)
	for index = 1, #rows do lines[#lines + 1] = rows[index] end
	lines[#lines + 1] = ('%d teleport(s), denied=%s membership=%s, platform teleport %s')
		:format(OPX.Table.Count(points), tostring(M.Settings.DENIED),
			tostring(M.Settings.MEMBERSHIP),
			teleportNative() ~= nil and 'available' or 'MISSING on this host')
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

-- Registers the ACL-gated diagnostic, when one is configured. It prints
-- positions and trip counts, which is operator information.
local function registerCommand()
	local name = M.Settings.COMMAND
	if type(name) ~= 'string' or name == '' then return end

	local keys = {}
	for key in pairs(points) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)

	-- Core renders a command's own help at send time but passes its parameters
	-- through as written, so the parameter help is resolved here.
	OPX.Command.Register(name, {
		restricted = true,
		help = 'teleports.help.where',
		params = { { name = 'key', optional = true,
			help = locale('teleports.help.whereKey',
				{ keys = #keys > 0 and table.concat(keys, ', ') or '-' }) } },
	}, function(source, args)
		report(source, args)
	end)
end

-- Forgets a departing player: their windows, and any lock their trip still
-- holds. The slot is recycled, so a lock left behind would be the next person's.
local function forget(rawPlayerId)
	local player = tonumber(rawPlayerId) or 0
	if player <= 0 then return end
	requestWindows[player] = nil
	logWindows[player] = nil
	inFlight[player] = nil
end

-- One sweep pass: collects the rate-limit windows, and releases a flight lock
-- whose thread died. `within` creates a window on demand, so a packet arriving
-- after a player left recreates the entry `forget` had just cleared and nothing
-- would ever clear it again.
local function sweepOnce()
	local at = OPX.Now()
	for _, windows in ipairs({ requestWindows, logWindows }) do
		for player, window in pairs(windows) do
			if at - (window.started or at) > WINDOW_GC_MS then windows[player] = nil end
		end
	end
	for player, flight in pairs(inFlight) do
		if at - (flight.atMs or at) > FLIGHT_MAX_MS then
			inFlight[player] = nil
			Open77.log.warn(('[teleports] player %d had a trip to %s still marked in flight ' ..
				'%d seconds on; the lock was released'):format(player, tostring(flight.key),
				math.floor(FLIGHT_MAX_MS / 1000)))
		end
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state and declares the operator numbers. Never yields.
-- @author dop42
function M.Init()
	points = Access.POINTS
	requestWindows, logWindows = {}, {}
	inFlight, trips, warnedSettle = {}, {}, {}

	OPX.Tune.Declare{
		TP_REQUEST_WINDOW_MS = { value = Access.FiniteNumber(M.Settings.REQUEST_WINDOW_MS) or 0,
			type = 'integer', min = 0, max = 600000 },
		TP_REQUESTS_PER_WINDOW = { value = Access.FiniteNumber(M.Settings.REQUESTS_PER_WINDOW) or 0,
			type = 'integer', min = 0, max = 1000 },
		TP_FADE_MS = { value = Access.FiniteNumber(M.Settings.FADE_MS) or 0,
			type = 'integer', min = 0, max = 5000 },
		-- The range is the arrival watch's own, not a preference: it refuses
		-- anything outside 1000..30000.
		TP_SETTLE_MS = { value = Access.FiniteNumber(M.Settings.SETTLE_MS) or 12000,
			type = 'integer', min = 1000, max = 30000 },
	}
end

--- Publishes the server half of the teleports contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('teleports', 1, {
		Entrances = entrances,
		IsAllowed = isAllowed,
		State = state,
	})
end

--- Wires the two doors, the diagnostic and the sweep.
-- @author dop42
function M.Start()
	-- Registered whether or not the native is there: an operator on such a host
	-- still has to be able to read back what the configuration says, and the
	-- last line of the report is what tells them the native is missing.
	registerCommand()

	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[teleports] config: ' .. line)
	end

	-- SAID AT START AND NOT AT THE FIRST REFUSAL. A host without the native
	-- refuses every trip with `unavailable`, which each player sees once and
	-- nobody correlates; this is the line in the boot block that says the whole
	-- module is inert and why.
	if teleportNative() == nil then
		Open77.log.error('[teleports] Open77.players.teleport is not on this host (it arrived ' ..
			'in 2.31.13+op77.67); markers will draw and every trip will be refused')
	end

	if OPX.Table.Count(points) == 0 then
		Open77.log.info('[teleports] no teleport is configured: every point in ' ..
			'config/teleports.lua is an example and ships switched off')
	end

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source) or 0
		if player <= 0 then return end
		-- A FLOOR, as every other door here has one: each ask is a character
		-- read, a bucket filter, a sort and a payload, and a client polls every
		-- POLL_MS (15 s). Faster than once a second is not a client polling.
		if OPX.Cooling(player, 'teleports.ask', 1000) then return end
		sync(player)
	end)

	RegisterNetEvent(M.Event.USE, function(key, leg)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		-- ON A THREAD, and it has to be: `move` awaits a promise, and `:await()`
		-- from anything that is not a managed coroutine answers
		-- `await_requires_scheduler_coroutine` instead of waiting. A net handler
		-- is not one.
		CreateThread(function()
			local served, failure = pcall(serve, player, key, leg)
			if not served then
				inFlight[player] = nil
				Open77.log.error('[teleports] a trip raised: ' .. tostring(failure))
				-- ANSWERED, because the client's latch opens only on an answer: a
				-- raise used to leave it shut, and every later press said "you are
				-- already on your way" until the player rejoined.
				TriggerClientEvent(M.Event.ANSWER, player, safe(key), safe(leg), false, 'failed', nil)
			end
		end)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, forget)

	running = true
	CreateThread(function()
		while running do
			Wait(SWEEP_MS)
			-- Guarded per pass: a raise from a host call in a bare thread would end
			-- the sweep for the life of the process.
			local swept, failure = pcall(sweepOnce)
			if not swept then
				Open77.log.error('[teleports] the sweep failed: ' .. tostring(failure))
			end
		end
	end)

	Open77.log.info(('[teleports] ready: %d point(s)'):format(OPX.Table.Count(points)))
end

--- Stops the sweep and drops every lock.
-- @author dop42
function M.Stop()
	running = false
	inFlight = {}
end
