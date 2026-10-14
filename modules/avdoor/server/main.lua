--- Server half: which aircraft door is open to which player, the mount itself,
--- and the relay that lets everybody near a player-flown MaxTac AV hear it.
-- @author XEROX710
--
-- ONE VERDICT, TWO DOORS. `M.Verdict` is the whole decision -- the hull, the
-- body, the distance, the speed, the authority and the seat -- and both the
-- scan (which decides whether a client draws a row) and the key (`BOARD`,
-- which seats) go through it, so the row and the seat can never disagree about
-- who may fly what. Every read is the server's own: the hull's canonical
-- transform, the asker's position and bucket from the host, the seat ledger,
-- the life state, the vehicles module's owner and job books, and whatever rule
-- the module that owns a hull registered.
--
-- THE SCAN IS HERE BECAUSE THE COORDINATES ARE HERE. A client snapshot of a
-- vehicle carries no world position (`wiki/vehicles.md`: "Client snapshots do
-- not include server ownership metadata such as `resource`, `bucket`, or world
-- coordinates"), so a client cannot tell which hull it is standing beside.
-- Every `SCAN_MS` this half lists the aircraft once, measures each player on
-- foot against the ones in their bucket, judges the nearest in reach, and
-- sends that client a `DOOR` only when its answer CHANGED.
--
-- WHO MAY FLY WHAT, in the order it is asked:
--   1. a rule another module registered for this hull (`Allow`) -- the MaxTac
--      insertion parks its aircraft here once its crew stepped out, and its
--      rule is the division's own duty rule;
--   2. the character the vehicles module says owns it (a hull a pad ISSUED);
--   3. a job aircraft: the character it was signed out to, or an ON-DUTY
--      holder of the job it belongs to -- a crew flies its own division's bird;
--   4. with `PASSENGERS`, anybody who did not pass 1-3, into a free PASSENGER
--      seat of an unlocked hull -- a rule or a book that refuses somebody the
--      controls does not refuse them a seat beside them, unless the rule says
--      `passengers = false`.
-- Anything else is refused by name.
--
-- THE DOORS. The seat's door (`DOORS`) is opened here, on the server, because
-- a door the server opens is canonical and replicated to every viewer -- the
-- platform's own exit opens the pilot door as a LOCAL actuation that a parked
-- owner is supposed to report, and the exit that opens it is the very thing
-- that drops that owner. A door this half opens it owes a closing: every open
-- door is in a ledger with the time it closes, and `Stop` closes what is left.
--
-- THE SOUNDS are sent to the listeners near the hull, who say what they did
-- with them; a listener the host refused is rescued through the platform's own
-- fan-out. Both halves of that talk go to the journal.
--
-- THE LANDING CALL (`server/callout.lua`) is the same pilot's report read a
-- second way: a MaxTac or Trauma Team AV coming down says so on its
-- loudspeaker until it is down. `M.Called` checks the asker is in that hull.

local M = OPX.Modules.Get('avdoor')

local Result = OPX.Result

-- The contracts, resolved in `Start`.
local character, book

-- Rules other modules registered, by the hull's id as text.
local registry = {}

-- When each hull last spoke each of its three sounds, so a hovering pilot
-- bobbing over the ground line is one horn, not one per bob.
local spoke = {}

-- The door each player was last told about, as `id|role` (or false for none),
-- so a scan only sends what changed.
local told = {}

-- Which records are aircraft, memoised: a record never changes its answer.
local aircraftRecords = {}

-- The doors this half opened and owes a closing, by `id|door`:
-- `{ id, door, since, closeAt, why, asserts, assertUntil, nextAssert, every }`.
local doorLedger = {}

-- Who sat where in each aircraft at the last occupancy event, by hull id as
-- text: `{ [seat] = { playerId, exiting } }`.
local occupancy = {}

-- Work owed for later, `{ at, run }`, drained by the one tending job.
local pending = {}

-- Players with a delayed boarding in flight, so one press is one boarding.
local boarding = {}

-- Hulls created a moment ago, by id as text: when (`OPX.Now()`) each was
-- created. Nobody boards one until `BOARD.SETTLE_MS` has passed (`M.Fresh`).
local fresh = {}

-- Sounds sent and not yet answered, by token: `{ id, event, which, duration,
-- bucket, at, sent = { [playerId] = true } }`.
local heardBy = {}
local soundSerial = 0

-- Causes already said in the log, so a missing native is one line and not one
-- per exit.
local warned = {}

-- The scan's scheduler handle, and the tending job's.
local scanJob = nil
local tendJob = nil
-- The landing calls' follow job (`server/callout.lua`), when CALLOUTS is on.
local calloutJob = nil
-- The landing pads' telling job (`server/pad.lua`), when PADS is on.
local padJob = nil

local function settings()
	return type(M.Settings) == 'table' and M.Settings or {}
end

--- The character a connection has loaded, or nil.
-- @param playerId number
-- @return table|nil PlayerData
local function dataOf(playerId)
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local read, player = pcall(character.GetPlayer, playerId)
	if not read or type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
	local data = player.PlayerData
	if type(data.citizenId) ~= 'string' or data.citizenId == '' then return nil end
	return data
end

--- A point as `{ x, y, z }` from a snapshot carrying `position` or flat x/y/z.
-- @param value any
-- @return table|nil
local function pointOf(value)
	if type(value) ~= 'table' then return nil end
	local at = type(value.position) == 'table' and value.position or value
	local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
	if x == nil or y == nil or z == nil or x ~= x or y ~= y or z ~= z then return nil end
	return { x = x, y = y, z = z }
end

--- Whether a record is an aircraft, memoised.
-- @param record any
-- @return boolean
local function aircraft(record)
	if type(record) ~= 'string' then return false end
	local known = aircraftRecords[record]
	if known == nil then
		known = M.IsAircraft(record)
		aircraftRecords[record] = known
	end
	return known
end

--- The canonical hull a client named, or nil.
--
-- AN ID IS COMPARED AS TEXT AS A LAST RESORT, the rule the vehicles module
-- already keeps (`Occupied`): the host's 64-bit ids can reach a client and come
-- back as a number or as a string, and one lookup per spelling is cheaper than
-- a door that silently answers "no aircraft" for the wrong spelling.
-- @param raw any
-- @return table|nil snapshot
-- @return any the id as the host knows it
local function hullOf(raw)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.get) ~= 'function' or raw == nil then return nil end
	local read, snapshot = pcall(api.get, raw)
	if read and type(snapshot) == 'table' then return snapshot, raw end
	local number = tonumber(raw)
	if number ~= nil then
		read, snapshot = pcall(api.get, number)
		if read and type(snapshot) == 'table' then return snapshot, number end
	end
	if type(api.all) == 'function' then
		local listed, all = pcall(api.all)
		if listed and type(all) == 'table' then
			local wanted = tostring(raw)
			for _, entry in ipairs(all) do
				if type(entry) == 'table' and tostring(entry.id) == wanted then
					local got, full = pcall(api.get, entry.id)
					if got and type(full) == 'table' then return full, entry.id end
					return entry, entry.id
				end
			end
		end
	end
	return nil
end

--- The seat a player holds, or nil.
local function seatOf(playerId)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.getPlayerSeat) ~= 'function' then return nil end
	local read, seat = pcall(api.getPlayerSeat, playerId)
	if read and type(seat) == 'table' and seat.vehicleId ~= nil then return seat end
	return nil
end

--- Where a player stands, as `{ x, y, z }` and their bucket, or nil.
-- @param playerId number
-- @return table|nil
-- @return number bucket
local function bodyOf(playerId)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.position) ~= 'function' then return nil, 0 end
	local read, at = pcall(players.position, playerId)
	if not read or type(at) ~= 'table' then return nil, 0 end
	return pointOf(at), tonumber(at.bucket) or 0
end

--- Whether a seat of a hull is free. Three answers, as the crew door reads it:
--- `false` is taken, and an unreadable ledger is offered and left to the mount.
local function seatFree(id, seat)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.seatFree) ~= 'function' then return true end
	local read, answer = pcall(api.seatFree, id, seat)
	if not read then return true end
	return answer ~= false
end

--- The owner the vehicles module's books name for a hull, trying the id the
--- way the host spelled it and, failing that, its other spelling.
-- @param id any
-- @return string|nil citizenId
local function ownerOf(id)
	if book == nil or type(book.PlateOf) ~= 'function' then return nil end
	for _, spelling in ipairs({ id, tonumber(id), tostring(id) }) do
		if spelling ~= nil then
			local read, _, owner = pcall(book.PlateOf, spelling)
			if read and owner ~= nil then return owner end
		end
	end
	return nil
end

--- Whether somebody who may not fly a hull may ride in it: `PASSENGERS` is on
--- and the hull is not locked.
-- @param id any the hull's id as the host knows it
-- @return string|nil `passenger`
local function passengerRole(id)
	if settings().PASSENGERS ~= true then return nil end
	local api = Open77.vehicles
	local locked = false
	if type(api) == 'table' and type(api.isLocked) == 'function' then
		local read, answer = pcall(api.isLocked, id)
		locked = read and answer == true
	end
	if locked then return nil end
	return 'passenger'
end

--- Who this player is to this hull: `pilot`, `passenger`, or nil and why.
--
-- THE CONTROLS AND THE SEATS ARE TWO QUESTIONS. Every branch that refuses a
-- body the controls falls through to `passengerRole`, so a rule, a job book or
-- an owner that says "not yours to fly" no longer says "and not yours to sit
-- in" -- which is what "other players can mount in av" was about. The reason
-- the FIRST refusal gave is the one reported when there is no seat either.
-- @param playerId number
-- @param data table PlayerData
-- @param id any the hull's id as the host knows it
-- @return string|nil role
-- @return string|nil reason
local function roleFor(playerId, data, id)
	local rule = registry[tostring(id)]
	if rule ~= nil then
		if type(rule.mayBoard) ~= 'function' then return 'pilot' end
		local read, allowed, why = pcall(rule.mayBoard, playerId, data)
		if read and allowed == true then return 'pilot' end
		local refusal = read and tostring(why or 'not_crew') or 'not_crew'
		-- A rule that RAISED is a bug, and a bug is not a reason to seat a
		-- stranger: only an answer of "no" falls through to a passenger seat, and
		-- only when the rule has not closed them (`passengers = false`).
		if read and rule.passengers ~= false then
			local role = passengerRole(id)
			if role ~= nil then return role end
		end
		return nil, refusal
	end

	local owner = ownerOf(id)
	if owner ~= nil and owner == data.citizenId then return 'pilot' end

	local refusal = 'not_yours'
	if book ~= nil and type(book.JobVehicles) == 'function' then
		local read, held = pcall(book.JobVehicles, nil)
		if read and type(held) == 'table' then
			for _, row in ipairs(held) do
				if tostring(row.id) == tostring(id) then
					if row.citizenId == data.citizenId then return 'pilot' end
					local job = data.job
					if type(row.job) == 'string' and type(job) == 'table' and job.name == row.job
						and job.onDuty == true then
						return 'pilot'
					end
					refusal = 'not_crew'
					break
				end
			end
		end
	end

	local role = passengerRole(id)
	if role ~= nil then return role end
	return nil, refusal
end

--- THE DECISION: may this player board this hull, and into which seat.
-- @param playerId number
-- @param raw any the hull as the client named it
-- @return table|nil `{ id, role, seat }`
-- @return string|nil the refusal code
function M.Verdict(playerId, raw)
	playerId = tonumber(playerId)
	if playerId == nil or playerId <= 0 then return nil, 'no_character' end
	local data = dataOf(playerId)
	if data == nil then return nil, 'no_character' end

	local snapshot, id = hullOf(raw)
	if snapshot == nil then return nil, 'no_aircraft' end
	if not aircraft(snapshot.record) then return nil, 'not_aircraft' end
	if snapshot.destroyed == true or snapshot.exploded == true then return nil, 'wrecked' end

	if seatOf(playerId) ~= nil then return nil, 'seated' end
	local players = Open77.players
	if type(players) == 'table' and type(players.isDead) == 'function' then
		local read, dead = pcall(players.isDead, playerId)
		if read and dead == true then return nil, 'down' end
	end

	local body, mine = bodyOf(playerId)
	if body == nil then return nil, 'no_position' end
	local hull = pointOf(snapshot)
	if hull == nil then return nil, 'no_aircraft' end
	local bucket = tonumber(snapshot.bucket)
	if bucket ~= nil and bucket ~= mine then return nil, 'no_aircraft' end

	local reach = M.Number(settings().REACH_METRES, 1.0, 50.0, 9.0)
	local dx, dy, dz = body.x - hull.x, body.y - hull.y, body.z - hull.z
	if dx * dx + dy * dy + dz * dz > reach * reach then return nil, 'too_far' end

	local rest = M.Number(settings().REST_SPEED, 0.0, 50.0, 2.0)
	local speed = tonumber(snapshot.speed) or 0.0
	if speed > rest then return nil, 'moving' end

	local role, why = roleFor(playerId, data, id)
	if role == nil then return nil, why or 'not_yours' end

	for _, seat in ipairs(M.SeatsFor(role)) do
		if seatFree(id, seat) then
			return { id = id, role = role, seat = seat }, nil
		end
	end
	return nil, 'no_seat'
end

--- Says a hull was created just now, so nobody boards it before it settled.
--
-- WHY A NEW HULL WAITS. The owner, 2026-10-03: "the maxtac av is not driving
-- when i drive it off it stays invisible". The pilot's client log of that
-- flight: the pad seated the pilot 0.3 s after the hull appeared, and for the
-- whole flight the hull the engine drew stayed where it had appeared while the
-- controls flew on -- `hullTrailM` 14-17 m, where a working flight trails by
-- centimetres -- so the pilot flew in nothing and the AV was left on the pad.
-- In those first moments the platform is still settling the projection: the AV
-- lift's drop onto the pad, the record's appearance swapped in, the observer
-- physics handed over. A body seated after that flies the hull it sees, so a
-- new hull is boarded no sooner than `BOARD.SETTLE_MS` after it was created --
-- by the pad (`garages`) and by the door key alike.
-- @param id any the hull, as the host knows it
-- @return number how long from now it settles, in milliseconds
function M.Fresh(id)
	if id == nil then return 0 end
	local settle = M.BoardSettings().settle
	if settle <= 0 then return 0 end
	local now = OPX.Now()
	-- The ledger only ever holds a few seconds of hulls: the settled ones go.
	for key, at in pairs(fresh) do
		if now - at >= settle then fresh[key] = nil end
	end
	fresh[tostring(id)] = now
	return settle
end

--- How long a hull still settles before a body may board it.
-- @param id any the hull, as the host knows it
-- @return number milliseconds, 0 for a settled or unknown hull
function M.SettleLeft(id)
	if id == nil then return 0 end
	local key = tostring(id)
	local at = fresh[key]
	if at == nil then return 0 end
	local left = at + M.BoardSettings().settle - OPX.Now()
	if left <= 0 then
		fresh[key] = nil
		return 0
	end
	return math.ceil(left)
end

--- Seats a player through the platform's own authoritative mount.
-- @param playerId number
-- @param raw any the hull as the client named it
-- @param options table|nil `{ door = true }` keeps the seat's door open for the
--   boarding hold; the pad's and the crew's own calls leave it alone
-- @return table a `Result`: `{ id, role, seat }`
function M.Board(playerId, raw, options)
	local verdict, why = M.Verdict(playerId, raw)
	if verdict == nil then return Result.Err(why or 'no_aircraft') end
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.warpPlayerIntoVehicle) ~= 'function' then
		return Result.Err('seat_refused', 'vehicles_api_unavailable')
	end
	local called, placed, refusal = pcall(api.warpPlayerIntoVehicle, playerId, verdict.id, verdict.seat, {
		-- The hull is in the player's own bucket -- the verdict checked it -- and
		-- moving them would be a routing change nobody asked for.
		moveBucket = false,
	})
	if not called or placed ~= true then
		local reason = tostring(called and refusal or placed)
		Open77.log.warn(('[avdoor] %d could not board %s in %s: %s')
			:format(playerId, tostring(verdict.id), verdict.seat, reason))
		return Result.Err('seat_refused', reason)
	end

	local rule = registry[tostring(verdict.id)]
	if rule ~= nil and type(rule.onBoard) == 'function' then
		-- The role goes with the seat: a rule that keeps a crew of its own is told
		-- about a body that only rides along, and decides what that is to it.
		local ran, failure = pcall(rule.onBoard, playerId, verdict.seat, verdict.role)
		if not ran then
			Open77.log.error(('[avdoor] the owner of %s could not be told %d boarded: %s')
				:format(tostring(verdict.id), playerId, tostring(failure)))
		end
	end
	-- The row comes down now rather than at the next scan: the body is in.
	told[playerId] = nil
	Open77.log.info(('[avdoor] %d boarded %s as %s in %s')
		:format(playerId, tostring(verdict.id), verdict.role, verdict.seat))
	-- The seat's door stays open for the hold and then closes (the tending job
	-- owns the closing), so the next body through the same side finds it open.
	if type(options) == 'table' and options.door == true then
		local door = M.DoorOf(verdict.seat)
		if door ~= nil then M.OpenDoor(verdict.id, door, M.BoardSettings().hold, 'board') end
	end
	return Result.Ok(verdict)
end

-- ── the doors ─────────────────────────────────────────────────────────────────

--- Sets a note in the log once per cause.
-- @param cause string
-- @param line string
local function warnOnce(cause, line)
	if warned[cause] then return end
	warned[cause] = true
	Open77.log.warn(line)
end

--- Work owed for `delayMs` from now, run by the tending job.
-- @param delayMs number
-- @param run function
local function later(delayMs, run)
	pending[#pending + 1] = { at = OPX.Now() + math.max(0, delayMs), run = run }
end

--- Opens one door of one hull and takes the closing on.
--
-- THE DOOR IS CANONICAL: `openDoor` writes the durable state and the platform
-- replicates it to every viewer, animating it live for the ones who see it
-- change and applying it at once for the ones who stream in later. What this
-- module opens it owes a closing, and the closing is in the ledger before the
-- call returns -- so no path leaves a door open for good.
-- @param id any the hull, as the host knows it
-- @param door string the platform's door name
-- @param holdMs number how long it stays open from now
-- @param why string `exit` or `board`, for the journal
-- @param options table|nil `{ reassertFor, every }` in ms: look again and
--   open it again if the platform's own exit shut it
-- @return boolean whether the host took the call
-- @return string|nil the reason it did not
function M.OpenDoor(id, door, holdMs, why, options)
	if type(door) ~= 'string' or M.DOOR_NAMES[door] ~= true then return false, 'no_door' end
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.openDoor) ~= 'function' then
		warnOnce('openDoor', '[avdoor] no Open77.vehicles.openDoor on this host: aircraft doors stay shut')
		return false, 'unavailable'
	end
	local called, opened, reason = pcall(api.openDoor, id, door)
	if not called or opened == false or opened == nil then
		local detail = tostring(called and reason or opened)
		Open77.log.warn(('[avdoor] the %s door of %s would not open (%s): %s')
			:format(door, tostring(id), tostring(why), detail))
		return false, detail
	end
	local now = OPX.Now()
	local key = tostring(id) .. '|' .. door
	local entry = doorLedger[key]
	if entry == nil then
		entry = { id = id, door = door, since = now, asserts = 0, closeFailures = 0 }
		doorLedger[key] = entry
	end
	entry.why = why
	entry.closeAt = math.max(entry.closeAt or 0, now + math.max(0, tonumber(holdMs) or 0))
	local for_ = type(options) == 'table' and tonumber(options.reassertFor) or nil
	if for_ ~= nil and for_ > 0 then
		entry.every = math.max(100, tonumber(options.every) or 400)
		entry.assertUntil = math.max(entry.assertUntil or 0, now + for_)
		entry.nextAssert = now + entry.every
	end
	return true
end

--- Closes one ledger door, or lets it go when the hull is gone. A close the
--- host refuses is tried again, three times, and then given up on aloud.
-- @param key string
-- @param entry table
-- @param now number
local function closeEntry(key, entry, now)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.closeDoor) ~= 'function' then
		warnOnce('closeDoor', '[avdoor] no Open77.vehicles.closeDoor on this host: doors this module opened stay open')
		doorLedger[key] = nil
		return
	end
	local called, closed, reason = pcall(api.closeDoor, entry.id, entry.door)
	if called and closed ~= false and closed ~= nil then
		doorLedger[key] = nil
		Open77.log.info(('[avdoor] the %s door of %s closed after %s, %.1fs open, %d re-open(s)')
			:format(entry.door, tostring(entry.id), tostring(entry.why),
				(now - entry.since) / 1000.0, entry.asserts))
		return
	end
	local detail = tostring(called and reason or closed)
	entry.closeFailures = entry.closeFailures + 1
	if detail == 'vehicle_not_found' or entry.closeFailures >= 3 then
		doorLedger[key] = nil
		Open77.log.warn(('[avdoor] the %s door of %s could not be closed (%s): let go after %d try(ies)')
			:format(entry.door, tostring(entry.id), detail, entry.closeFailures))
		return
	end
	entry.closeAt = now + 500
end

--- One pass of the tending job: the work that is due, then every open door.
-- Public for the suite.
function M.Tend()
	local now = OPX.Now()
	if #pending > 0 then
		local due, keep = {}, {}
		for _, item in ipairs(pending) do
			if item.at <= now then due[#due + 1] = item else keep[#keep + 1] = item end
		end
		pending = keep
		for _, item in ipairs(due) do
			local ran, failure = pcall(item.run)
			if not ran then Open77.log.error('[avdoor] a delayed step failed: ' .. tostring(failure)) end
		end
	end

	local api = Open77.vehicles
	for key, entry in pairs(doorLedger) do
		if entry.closeAt ~= nil and now >= entry.closeAt then
			closeEntry(key, entry, now)
		elseif entry.assertUntil ~= nil and now <= entry.assertUntil and now >= (entry.nextAssert or 0)
			and type(api) == 'table' and type(api.isDoorOpen) == 'function' then
			entry.nextAssert = now + (entry.every or 400)
			local read, open = pcall(api.isDoorOpen, entry.id, entry.door)
			if read and open == nil then
				-- The host does not know the hull any more: nothing to keep open.
				doorLedger[key] = nil
			elseif read and open == false then
				entry.asserts = entry.asserts + 1
				local called, again, reason = pcall(api.openDoor, entry.id, entry.door)
				Open77.log.info(('[avdoor] the %s door of %s had been shut again %.1fs after %s: opened it again (%s)')
					:format(entry.door, tostring(entry.id), (now - entry.since) / 1000.0,
						tostring(entry.why),
						(called and again ~= false and again ~= nil) and 'ok'
							or ('refused: ' .. tostring(called and reason or again))))
			end
		end
	end
end

--- Whether a door is on the ledger, and when it closes. For the suite and the
--- console.
-- @param id any
-- @param door string
-- @return table|nil `{ closeAt, asserts, why }`
function M.DoorState(id, door)
	local entry = doorLedger[tostring(id) .. '|' .. tostring(door)]
	if entry == nil then return nil end
	return { closeAt = entry.closeAt, asserts = entry.asserts, why = entry.why, since = entry.since }
end

--- What a seat's door does when the body in it steps out: it opens for
--- everybody, and closes after `DOOR_HOLD_MS`.
-- @param id any the hull
-- @param seat string the seat left
-- @param playerId any who left, for the journal
-- @param how string what the ledger said, for the journal
-- @return boolean whether a door was opened
function M.Exited(id, seat, playerId, how)
	local exit = M.ExitSettings()
	if exit.off then return false end
	local door = M.DoorOf(seat)
	if door == nil then return false end
	local opened, reason = M.OpenDoor(id, door, exit.doorHold, 'exit',
		{ reassertFor = exit.reassertFor, every = exit.reassertEvery })
	Open77.log.info(('[avdoor] player %s left %s of aircraft %s (%s): the %s door %s, closing in %.1fs')
		:format(tostring(playerId), tostring(seat), tostring(id), tostring(how), door,
			opened and 'is open' or ('would not open (' .. tostring(reason) .. ')'),
			exit.doorHold / 1000.0))
	return opened
end

--- The occupancy of an aircraft changed: whoever stepped out gets their door.
-- Runs on the platform's `onVehicleOccupancyChanged`. It reads the canonical
-- ledger and compares it with the last one it saw for that hull, so a seat
-- that emptied, a seat whose body began to leave (`exiting`) and a seat that
-- changed hands are all an exit -- and a hull that is not an aircraft costs
-- one memoised lookup.
-- @param raw any the hull's id, as the event delivers it (a string)
-- @return integer how many exits were seen
function M.Occupancy(raw)
	-- The id goes to the host as it was delivered (a decimal string): a 64-bit id
	-- put through `tonumber` loses its low bits above 2^53.
	local snapshot, id = hullOf(raw)
	if snapshot == nil then
		occupancy[tostring(raw)] = nil
		return 0
	end
	if not aircraft(snapshot.record) then return 0 end
	local key = tostring(id)
	local before = occupancy[key] or {}
	local now = {}
	for _, occupant in ipairs(type(snapshot.occupants) == 'table' and snapshot.occupants or {}) do
		local seat = type(occupant) == 'table' and M.SeatName(occupant.seat) or nil
		if seat ~= nil then
			now[seat] = { playerId = occupant.playerId, exiting = occupant.exiting == true }
		end
	end
	local exits = 0
	for seat, was in pairs(before) do
		local is = now[seat]
		local how = nil
		if is == nil then
			-- A seat that was already marked as leaving had its door opened then;
			-- the seat emptying is the same exit, not a second one.
			if not was.exiting then how = 'left' end
		elseif is.exiting and not was.exiting then
			how = 'exiting'
		elseif tostring(is.playerId) ~= tostring(was.playerId) then
			how = 'changed'
		end
		if how ~= nil then
			exits = exits + 1
			M.Exited(id, seat, was.playerId, how)
		end
	end
	occupancy[key] = now
	return exits
end

-- ── the scan ──────────────────────────────────────────────────────────────────

--- Every aircraft that exists, with where it stands and its bucket. `entry` is
--- the snapshot `all` answered, for the watch (`server/watch.lua`), which reads
--- its owner, epoch and seats without a second host call.
-- @return table[] `{ id, at, bucket, entry }`
local function aircraftNow()
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.all) ~= 'function' then return {} end
	local listed, all = pcall(api.all)
	if not listed or type(all) ~= 'table' then return {} end
	local hulls = {}
	for _, entry in ipairs(all) do
		if type(entry) == 'table' and entry.id ~= nil and aircraft(entry.record) then
			local at = pointOf(entry)
			if at ~= nil then
				hulls[#hulls + 1] = { id = entry.id, at = at, bucket = tonumber(entry.bucket) or 0, entry = entry }
			end
		end
	end
	return hulls
end

--- The nearest aircraft to a body, in its bucket, and how far it is.
-- @param body table `{ x, y, z }`
-- @param bucket number
-- @param hulls table[]
-- @return table|nil the hull
-- @return number metres
local function nearestTo(body, bucket, hulls)
	local found, best = nil, math.huge
	for _, hull in ipairs(hulls) do
		if hull.bucket == bucket then
			local dx, dy, dz = body.x - hull.at.x, body.y - hull.at.y, body.z - hull.at.z
			local metres = math.sqrt(dx * dx + dy * dy + dz * dz)
			if metres < best then found, best = hull, metres end
		end
	end
	return found, best
end

--- The door open to one player now: `{ id, role }`, or nil.
-- @param playerId number
-- @param hulls table[]
-- @return table|nil
local function doorFor(playerId, hulls)
	if #hulls == 0 or seatOf(playerId) ~= nil then return nil end
	local body, bucket = bodyOf(playerId)
	if body == nil then return nil end
	local hull, metres = nearestTo(body, bucket, hulls)
	local reach = M.Number(settings().REACH_METRES, 1.0, 50.0, 9.0)
	if hull == nil or metres > reach then return nil end
	local verdict = M.Verdict(playerId, hull.id)
	if verdict == nil then return nil end
	return { id = tostring(verdict.id), role = verdict.role }
end

--- Tells one client its door, when it changed.
-- @param playerId number
-- @param door table|nil
local function tell(playerId, door)
	local key = door ~= nil and (door.id .. '|' .. door.role) or false
	-- Never told is the same as told "no door": a player who never stood at
	-- an aircraft is sent nothing at all.
	if (told[playerId] or false) == key then return end
	told[playerId] = key
	TriggerClientEvent(M.Event.DOOR, playerId, door ~= nil
		and { open = true, id = door.id, role = door.role } or { open = false })
end

--- One pass over every player. Public for the suite and the console.
-- @return integer how many players have a door open to them
function M.Scan()
	local players = Open77.players
	if type(players) ~= 'table' or type(players.all) ~= 'function' then return 0 end
	local read, ids = pcall(players.all)
	if not read or type(ids) ~= 'table' then return 0 end
	local hulls = aircraftNow()
	-- The watch measures the same list against the last one (`server/watch.lua`):
	-- a canonical move no aircraft flies is a line in the journal.
	if M.Watch ~= nil then
		local watched, failure = pcall(M.Watch.Observe, hulls)
		if not watched then Open77.log.warn('[avdoor] the watch failed: ' .. tostring(failure)) end
	end
	local open, present = 0, {}
	for _, raw in ipairs(ids) do
		local playerId = tonumber(raw)
		if playerId ~= nil and playerId > 0 then
			present[playerId] = true
			local ran, door = pcall(doorFor, playerId, hulls)
			if not ran then
				Open77.log.warn(('[avdoor] the door read for %d failed: %s'):format(playerId, tostring(door)))
				door = nil
			end
			if door ~= nil then open = open + 1 end
			tell(playerId, door)
		end
	end
	-- A connection that left takes its memory with it: the next holder of the
	-- slot is told from scratch.
	for playerId in pairs(told) do
		if not present[playerId] then told[playerId] = nil end
	end
	return open
end

--- What the door nearest to a player says, in words, for `/opx.avdoor.why`.
-- @param playerId number
-- @return string
function M.Explain(playerId)
	playerId = tonumber(playerId)
	if playerId == nil or playerId <= 0 then return 'the console has no body to measure' end
	local hulls = aircraftNow()
	local body, bucket = bodyOf(playerId)
	if body == nil then return 'your position is unknown to the server' end
	local hull, metres = nearestTo(body, bucket, hulls)
	if hull == nil then
		return ('no aircraft exists in your bucket (%d aircraft on the server)'):format(#hulls)
	end
	local verdict, why = M.Verdict(playerId, hull.id)
	local snapshot = hullOf(hull.id)
	local record = type(snapshot) == 'table' and tostring(snapshot.record) or '?'
	if verdict ~= nil then
		return ('aircraft %s (%s) %.1f m away: the door is OPEN to you as %s, seat %s -- press %s')
			:format(tostring(hull.id), record, metres, verdict.role, verdict.seat,
				tostring(type(settings().KEY) == 'table' and settings().KEY.DEFAULT or 'F'))
	end
	return ('aircraft %s (%s) %.1f m away: the door is SHUT to you -- %s')
		:format(tostring(hull.id), record, metres, tostring(why))
end

-- ── the MaxTac AV's own voice ─────────────────────────────────────────────────

--- Whether two spellings of a platform id name the same hull. The host's 64-bit
--- ids reach Lua as an integer, a float or a decimal string depending on the
--- road they came by, and `tostring` spells a float `4294967297.0`.
-- @param a any
-- @param b any
-- @return boolean
local function sameHull(a, b)
	if a == nil or b == nil then return false end
	local x, y = M.DecimalId(a), M.DecimalId(b)
	if x ~= nil and y ~= nil then return x == y end
	return tostring(a) == tostring(b)
end

--- Gives one listener the sound through the platform's own fan-out: the
--- platform plays a Wwise event on a vehicle for the whole bucket, so every
--- OTHER player in the bucket is excluded and the one listener is all that is
--- left. Only ever called for a listener whose own client was refused by the
--- host, so a sound is never heard twice.
-- @param wait table the sound as `M.Speak` recorded it
-- @param listener number
-- @return boolean
-- @return string|nil reason
local function rescue(wait, listener)
	local effects = type(Open77) == 'table' and Open77.effects or nil
	if type(effects) ~= 'table' or type(effects.sound) ~= 'function' then
		warnOnce('effects', '[avdoor] no Open77.effects.sound on this host: a listener whose client '
			.. 'is refused stays silent')
		return false, 'unavailable'
	end
	local exclude = {}
	local read, ids = pcall(Open77.players.all)
	for _, raw in ipairs(read and type(ids) == 'table' and ids or {}) do
		local other = tonumber(raw)
		if other ~= nil and other ~= listener then
			local _, where = bodyOf(other)
			if where == wait.bucket then exclude[#exclude + 1] = other end
		end
	end
	-- The platform takes at most 32 exclusions: past that the sound cannot be
	-- addressed to one body, and it is better silent for one than doubled for
	-- thirty.
	if #exclude > 32 then return false, 'too_many_listeners' end
	soundSerial = soundSerial + 1
	local target = M.DecimalId(wait.id) or tostring(wait.id)
	local ran, ok, why = pcall(effects.sound, { kind = 'vehicle', id = target }, wait.event, {
		duration = wait.duration,
		actionId = ('opx-avdoor:%s:%s:%d'):format(target, tostring(wait.which), soundSerial),
		excludePlayers = #exclude > 0 and exclude or nil,
	})
	if not ran or ok == nil or ok == false then
		return false, tostring(ran and why or ok)
	end
	return true
end

--- Relays one flight sound from the pilot's client to everybody near the hull.
--
-- EVERY LISTENER IN RANGE IS SENT IT -- THE PILOT INCLUDED -- and each answers
-- (`M.Heard`). The pilot's client is the one that reads the flight; the others
-- only play what they are told, on the hull as their own client streams it.
-- @param playerId number the asker
-- @param payload table `{ id, which }`
-- @return integer how many were sent it
function M.Speak(playerId, payload)
	local sounds = settings().SOUNDS
	if type(sounds) ~= 'table' or type(payload) ~= 'table' then return 0 end
	local field = M.SOUNDS[tostring(payload.which)]
	if field == nil then return 0 end
	local event = sounds[field]
	if type(event) ~= 'string' or event == '' then return 0 end

	-- THE ASKER MUST BE IN THAT HULL: a sound is the flight's, and only a body
	-- aboard is flying it.
	local seat = seatOf(playerId)
	if seat == nil or not sameHull(seat.vehicleId, payload.id) then return 0 end
	local snapshot, id = hullOf(seat.vehicleId)
	if snapshot == nil or not M.IsAircraft(snapshot.record, sounds.RECORDS) then return 0 end

	local key = tostring(id) .. '\1' .. field
	local now = OPX.Now()
	local floor = M.Number(sounds.FLOOR_MS, 0, 600000, 6000)
	if spoke[key] ~= nil and now - spoke[key] < floor then return 0 end
	spoke[key] = now

	local hull = pointOf(snapshot)
	if hull == nil then return 0 end
	local range = M.Number(sounds.RANGE, 1.0, 2000.0, 220.0)
	local bucket = tonumber(snapshot.bucket) or 0
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return 0 end
	local duration = M.Number(sounds.DURATION_S, 0.05, 60.0, 8.0)

	soundSerial = soundSerial + 1
	local token = soundSerial
	local sent, names = {}, {}
	for _, raw in ipairs(ids) do
		local listener = tonumber(raw)
		local body, where = nil, nil
		if listener ~= nil then body, where = bodyOf(listener) end
		if body ~= nil and where == bucket then
			local dx, dy, dz = body.x - hull.x, body.y - hull.y, body.z - hull.z
			local metres = math.sqrt(dx * dx + dy * dy + dz * dz)
			if metres <= range then
				sent[listener] = true
				names[#names + 1] = ('%d (%.0f m)'):format(listener, metres)
				TriggerClientEvent(M.Event.PLAY, listener, {
					id = tostring(id), event = event, which = tostring(payload.which),
					duration = duration, token = token,
				})
			end
		end
	end
	heardBy[token] = { id = id, event = event, which = tostring(payload.which), duration = duration,
		bucket = bucket, at = now, sent = sent }
	-- A sound nobody answered inside half a minute is not going to be.
	for old, wait in pairs(heardBy) do
		if now - wait.at > 30000 then heardBy[old] = nil end
	end
	Open77.log.info(('[avdoor] %s: %s (%s) sent to %d listener(s): %s')
		:format(tostring(id), tostring(payload.which), event, #names, table.concat(names, ', ')))
	return #names
end

--- A listener's word on what its client did with a sound: journalled, and a
--- refusal by the host is rescued through the platform's fan-out.
-- @param playerId number the listener
-- @param payload table `{ token, ok, how, streamed, reason }`
-- @return boolean whether the answer was one this half was waiting for
function M.Heard(playerId, payload)
	if type(payload) ~= 'table' then return false end
	local token = tonumber(payload.token)
	local wait = token ~= nil and heardBy[token] or nil
	-- Only a listener that was SENT the sound may answer for it, and only once.
	if wait == nil or wait.sent[playerId] ~= true then return false end
	wait.sent[playerId] = 'answered'
	local how = type(payload.how) == 'string' and payload.how:sub(1, 40) or '?'
	local reason = type(payload.reason) == 'string' and payload.reason:sub(1, 80) or '?'
	if payload.ok == true then
		Open77.log.info(('[avdoor] player %d heard %s of %s: playing %s')
			:format(playerId, wait.event, tostring(wait.id), how))
		return true
	end
	local block = settings().SOUNDS
	local rescued = 'not rescued'
	-- A hull that is not streamed on that machine is a hull the platform's own
	-- fan-out would drop just the same; only a REFUSAL by the host is rescued.
	if payload.streamed ~= false and type(block) == 'table' and block.RESCUE ~= false then
		local ok, why = rescue(wait, playerId)
		rescued = ok and 'rescued through the platform\'s fan-out'
			or ('the platform\'s fan-out refused too: ' .. tostring(why))
	end
	Open77.log.warn(('[avdoor] player %d could not play %s of %s (%s): %s')
		:format(playerId, wait.event, tostring(wait.id), reason, rescued))
	return true
end

--- The landing call's half of a pilot's report (`CALLOUTS`): a descent starts
--- the hull's call, and a touchdown, a take-off or a landing called off ends it.
--
-- THE SAME CHECK AS THE SOUND: only a body seated in that hull speaks for its
-- flight, and only a hull whose record makes a call has one.
-- @param playerId number the asker
-- @param payload table `{ id, which }`
-- @return boolean|nil what `Start` or `Stop` answered, nil when nothing applied
-- @return string|nil why not
function M.Called(playerId, payload)
	if M.Callout == nil or type(payload) ~= 'table' then return nil end
	if type(settings().CALLOUTS) ~= 'table' then return nil, 'callouts_off' end
	local which = tostring(payload.which)
	if M.MOMENTS[which] ~= true then return nil, 'unknown_moment' end
	local seat = seatOf(playerId)
	if seat == nil or not sameHull(seat.vehicleId, payload.id) then return nil, 'not_aboard' end
	local snapshot, id = hullOf(seat.vehicleId)
	if snapshot == nil then return nil, 'no_hull' end
	local kind = M.CalloutKind(snapshot.record)
	if kind == nil then return nil, 'no_call_for_this_hull' end
	if which == 'descent' then
		return M.Callout.Start(id, kind, ('the descent player %d reported'):format(playerId))
	end
	return M.Callout.Stop(id, which)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Forgets everything the phases below keep: the tables, the serial and the
--- two scheduler handles. Shared by `Init` and `Stop` so a restart starts clean.
local function reset()
	registry, spoke, told, aircraftRecords = {}, {}, {}, {}
	doorLedger, occupancy, pending, boarding, heardBy, warned = {}, {}, {}, {}, {}, {}
	fresh = {}
	soundSerial = 0
	scanJob, tendJob, calloutJob, padJob = nil, nil, nil, nil
	if M.Watch ~= nil then M.Watch.Reset() end
	if M.Callout ~= nil then M.Callout.Reset() end
	if M.Pads ~= nil then M.Pads.Reset() end
end

function M.Init()
	reset()
end

--- The door other modules register their hulls through.
function M.Api()
	OPX.Api.Provide('avdoor', 1, {
		--- Puts a door on a hull this module would not otherwise know how to
		--- judge. `rule.mayBoard(playerId, data)` answers `true`, or `false` and
		--- a refusal code; `rule.onBoard(playerId, seat, role)` is told of a
		--- boarding, `role` being `pilot` or `passenger`. A `false` from
		--- `mayBoard` refuses the CONTROLS, not the seats beside them: the seats
		--- stay open to anybody unless the rule says `passengers = false`.
		-- @param id any
		-- @param rule table
		Allow = function(id, rule)
			if id == nil or type(rule) ~= 'table' then return false end
			registry[tostring(id)] = rule
			return true
		end,
		--- Takes a hull's registered door away.
		Forget = function(id)
			if id == nil then return false end
			local had = registry[tostring(id)] ~= nil
			registry[tostring(id)] = nil
			return had
		end,
		Verdict = function(playerId, id) return M.Verdict(playerId, id) end,
		Board = function(playerId, id) return M.Board(playerId, id) end,
		--- A hull was created just now: nobody boards it before it settled.
		-- @return number milliseconds until it has (see `M.Fresh`)
		Fresh = function(id) return M.Fresh(id) end,
		--- Milliseconds before a body may board the hull, 0 when it may now.
		SettleLeft = function(id) return M.SettleLeft(id) end,
		--- Starts the landing call on a hull (`CALLOUTS`): `kind` is a
		--- `CALLOUTS.KINDS` name, or nil for the one its record makes. The
		--- MaxTac insertion calls this from its approach.
		-- @return boolean|nil, string|nil
		-- `from` is `{ x, y, z, bucket }` for a hull the caller flies itself:
		-- the caller then moves the call with `Follow`, pose by pose.
		Callout = function(id, kind, why, from)
			if M.Callout == nil then return nil, 'unavailable' end
			return M.Callout.Start(id, kind, why, from)
		end,
		--- Moves a call started with `from` to where its caller put the hull.
		Follow = function(id, at)
			if M.Callout == nil then return false end
			return M.Callout.Follow(id, at)
		end,
		--- Ends a hull's landing call once the sentence being said is finished.
		Hush = function(id, why)
			if M.Callout == nil then return false end
			return M.Callout.Stop(id, why)
		end,
		--- Where an AV the caller flies may come down near a point: ground, at
		--- the point's level, flat under the hull, open to the sky (`LANDING`).
		--- BLOCKING: it asks the games, so the caller is a thread.
		-- @return table|nil `{ x, y, z, bearing, distance, probes }`, string|nil
		LandingSite = function(target, options)
			if M.Landing == nil then return nil, 'unavailable' end
			return M.Landing.Find(target, options)
		end,
		--- Whether `LandingSite` can be asked at all on this host.
		CanSurvey = function()
			return M.Landing ~= nil and M.Landing.Available()
		end,
		--- How long `LandingSite` may take, in milliseconds: `BUDGET_SECONDS`, and
		--- the one probe that may still be out when it runs out (`PROBE_MS`).
		SurveyBudgetMs = function()
			local cfg = M.Landing ~= nil and M.Landing.Settings() or nil
			return cfg ~= nil and (cfg.budgetMs + cfg.probeMs) or 0
		end,
		--- Puts the landing pad under a hull the caller flies (`PADS`): the red
		--- ring the client draws under an AV it flies itself. Answers `nil,
		--- 'platform'` for a record the client pads on its own.
		-- @param id any
		-- @param options table|nil `{ record, bucket, why }`
		Pad = function(id, options)
			if M.Pads == nil then return nil, 'unavailable' end
			return M.Pads.Start(id, options)
		end,
		--- Takes a hull's landing pad away.
		Unpad = function(id, why)
			if M.Pads == nil then return false end
			return M.Pads.Stop(id, why)
		end,
	})
end

function M.Start()
	character = OPX.Api.Get('character')
	book = OPX.Api.Get('vehicles')
	if character == nil then
		Open77.log.warn('[avdoor] no character contract: every aircraft door will refuse')
	end

	--- Tells the asker what the press came to.
	local function answer(player, boarded)
		local sent, failure = pcall(TriggerClientEvent, M.Event.BOARDED, player, {
			ok = boarded.ok == true,
			seat = boarded.ok and boarded.value.seat or nil,
			role = boarded.ok and boarded.value.role or nil,
			reason = boarded.ok ~= true and tostring(boarded.error) or nil,
			detail = boarded.ok ~= true and boarded.detail or nil,
		})
		if not sent then
			Open77.log.warn(('[avdoor] %d could not be told what the press came to: %s')
				:format(player, tostring(failure)))
		end
	end

	RegisterNetEvent(M.Event.BOARD, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 or type(payload) ~= 'table' then return end
		if boarding[player] or OPX.Cooling(player, 'avdoor.board', 700) then
			return TriggerClientEvent(M.Event.BOARDED, player, { ok = false, reason = 'busy' })
		end

		-- THE PRESS IS JUDGED NOW, and again when the body is seated: the door
		-- swings first, and a verdict that stopped being true in that half second
		-- (somebody else took the seat, the hull moved, the player was hurt) is
		-- caught by the second look.
		local verdict, why = M.Verdict(player, payload.id)
		if verdict == nil then
			return answer(player, Result.Err(why or 'no_aircraft'))
		end
		local board = M.BoardSettings()
		local door = M.DoorOf(verdict.seat)
		-- A HULL THAT APPEARED A MOMENT AGO is boarded once it has settled (see
		-- `M.Fresh`): the door opens on the press and the body steps in then.
		local settling = M.SettleLeft(verdict.id)
		local wait = math.max(board.delay, settling)
		if wait <= 0 or (door == nil and settling <= 0) then
			return answer(player, M.Board(player, verdict.id, { door = true }))
		end
		local options = { door = true }
		if door ~= nil then
			local opened, reason = M.OpenDoor(verdict.id, door, wait + board.hold, 'board')
			if not opened then
				-- A door the host will not swing is no reason to refuse the seat.
				Open77.log.warn(('[avdoor] %d boards %s without its %s door (%s)')
					:format(player, tostring(verdict.id), door, tostring(reason)))
				if settling <= 0 then return answer(player, M.Board(player, verdict.id)) end
				options = nil
			end
		end
		if settling > 0 then
			Open77.log.info(('[avdoor] %d boards %s in %d ms: the hull appeared a moment ago and '
				.. 'settles first'):format(player, tostring(verdict.id), wait))
		end
		boarding[player] = true
		later(wait, function()
			boarding[player] = nil
			answer(player, M.Board(player, verdict.id, options))
		end)
	end)

	-- A LISTENER'S ANSWER TO A SOUND. It carries no authority: the token names a
	-- sound this half sent that listener, and only that listener may answer it.
	RegisterNetEvent(M.Event.PLAYED, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 or type(payload) ~= 'table' then return end
		if OPX.Cooling(player, 'avdoor.played', 100) then return end
		M.Heard(player, payload)
	end)

	-- WHO STEPPED OUT OF WHICH SEAT, from the platform's own ledger. The door
	-- opens for everybody as the seat empties (see `M.Occupancy`).
	AddEventHandler(OPX.Host.VEHICLE_OCCUPANCY_CHANGED, function(id)
		local ran, failure = pcall(M.Occupancy, id)
		if not ran then
			Open77.log.error('[avdoor] an occupancy change could not be read: ' .. tostring(failure))
		end
	end)

	AddEventHandler(OPX.Host.VEHICLE_REMOVED, function(id)
		if id == nil then return end
		for key in pairs(occupancy) do
			if sameHull(key, id) then occupancy[key] = nil end
		end
		-- A hull taken out of the world takes its landing call with it.
		if M.Callout ~= nil and M.Callout.IsLive(id) then M.Callout.Kill(id, 'the hull was removed') end
		-- And its landing pad.
		if M.Pads ~= nil and M.Pads.Has(id) then M.Pads.Stop(id, 'the hull was removed') end
	end)

	RegisterNetEvent(M.Event.SOUND, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		if OPX.Cooling(player, 'avdoor.sound', 500) then return end
		M.Speak(player, payload)
		M.Called(player, payload)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local id = tonumber(playerId)
		if id ~= nil then
			told[id] = nil
			boarding[id] = nil
			if M.Watch ~= nil then M.Watch.Forget(id) end
			if M.Pads ~= nil then M.Pads.Forget(id) end
			if M.Callout ~= nil and type(M.Callout.Forget) == 'function' then M.Callout.Forget(id) end
			if M.Landing ~= nil and type(M.Landing.Forget) == 'function' then M.Landing.Forget(id) end
		end
	end)

	-- THE WATCH: every aircraft's change of hands, and every viewer's word about
	-- where it draws one (`server/watch.lua`).
	if M.Watch ~= nil and M.WatchSettings().off ~= true then M.Watch.Start() end

	if type(OPX.Command) == 'table' and type(OPX.Command.Register) == 'function' then
		local registered, failure = pcall(OPX.Command.Register, M.Command.WHY, {
			restricted = false,
			help = 'avdoor.help.why',
			cooldownMs = 1000,
		}, function(caller)
			OPX.CommandResult(caller, true, M.Explain(caller))
		end)
		if not registered then
			Open77.log.warn('[avdoor] /' .. M.Command.WHY .. ' not registered: ' .. tostring(failure))
		end
	end

	scanJob = OPX.Scheduler.Every('avdoor:scan',
		math.floor(M.Number(settings().SCAN_MS, 100, 5000, 500)), function()
			M.Scan()
		end)

	-- THE TENDING JOB: the delayed boardings and every door this half opened and
	-- owes a closing. A tenth of a second, the finest a door is looked at.
	tendJob = OPX.Scheduler.Every('avdoor:tend', 100, function()
		M.Tend()
	end)

	-- THE LANDING CALLS follow their hulls: the platform has no vehicle
	-- attachment for package audio, so the sound is moved with the hull.
	local calls = type(settings().CALLOUTS) == 'table' and settings().CALLOUTS or nil
	if calls ~= nil and M.Callout ~= nil then
		calloutJob = OPX.Scheduler.Every('avdoor:callout',
			math.floor(M.Number(calls.FOLLOW_MS, 50, 2000, 150)), function()
				M.Callout.Tend()
			end)
	end

	-- THE LANDING PADS: whoever comes near a hull the server flies is told to
	-- draw the pad under it (`server/pad.lua`).
	local pads = M.Pads ~= nil and M.Pads.Settings() or nil
	if pads ~= nil then
		padJob = OPX.Scheduler.Every('avdoor:pads', pads.tellMs, function()
			local ran, failure = pcall(M.Pads.Tend)
			if not ran then Open77.log.error('[avdoor] the landing pads pass failed: ' .. tostring(failure)) end
		end)
	end

	Open77.log.info(('[avdoor] ready: aircraft doors within %.1f m, measured every %d ms, %s')
		:format(M.Number(settings().REACH_METRES, 1.0, 50.0, 9.0),
			math.floor(M.Number(settings().SCAN_MS, 100, 5000, 500)),
			book ~= nil and 'owner and job books read' or 'NO vehicles contract: only registered hulls have a door'))
end

function M.Stop()
	if scanJob ~= nil then OPX.Scheduler.Cancel(scanJob) end
	if tendJob ~= nil then OPX.Scheduler.Cancel(tendJob) end
	if calloutJob ~= nil then OPX.Scheduler.Cancel(calloutJob) end
	if padJob ~= nil then OPX.Scheduler.Cancel(padJob) end
	-- Every landing call is released with it: a stopped module moves nothing.
	if M.Callout ~= nil then M.Callout.KillAll('the module stopped') end
	-- Every pad comes off every game that was drawing one.
	if M.Pads ~= nil then M.Pads.StopAll('the module stopped') end
	-- Every row this half drew comes down with it.
	for playerId, key in pairs(told) do
		if key ~= false then
			pcall(TriggerClientEvent, M.Event.DOOR, playerId, { open = false })
		end
	end
	-- Every door this half opened is closed with it: a stopped module has no
	-- closing job left to do it.
	local api = Open77 ~= nil and Open77.vehicles or nil
	if type(api) == 'table' and type(api.closeDoor) == 'function' then
		for _, entry in pairs(doorLedger) do
			pcall(api.closeDoor, entry.id, entry.door)
		end
	end
	reset()
end
