--- The authority: clock, weather schedule, carried state and every mutation.
-- @author dop42
--
-- Without a single authority every client runs its own sky. The server holds one
-- second-of-day at an anchor, the anchor itself on the host's monotonic clock, a
-- rate, a preset name, two freezes and two revisions, and publishes a whole
-- snapshot on every mutation. `weatherRevision` only moves when the preset
-- changes, so a client can skip a redundant `setWeather`.

local M = OPX.Modules.Get('weather')
local Clock = M.Clock

M.Authority = {}
local Authority = M.Authority

-- Server to client event carrying a whole snapshot.
local EVENT_SYNC = OPX.Event(OPX.Channel.NET, 'weather', 'sync')

-- Preset rows in config order, and by lowercase name or preset.
local order, index = {}, {}

-- The live authoritative state every mutation writes; Init fills it.
local state = {}

-- Which incarnation of the authority this is.
local authorityEpoch = 0

-- Whether the clock has an anchor on the monotonic clock.
local anchored = false

-- A finite configured number, or the fallback. Configuration reaches `%d` and
-- `math.random` below, and neither survives a NaN or an infinity.
local function number(value, fallback)
	value = tonumber(value)
	if not Clock.Finite(value) then return fallback end
	return value
end

-- Resolves a name or engine preset to its row, without case.
local function findPreset(value)
	if type(value) ~= 'string' then return nil end
	return index[value:lower()]
end

--- Answers the usable preset rows in config order.
-- @author dop42
-- @return table[]
function Authority.Presets()
	return order
end

-- Carried state fields that must be finite numbers.
local CARRIED_NUMBERS = {
	'revision', 'weatherRevision', 'baseSeconds', 'anchorMs', 'rate',
	'weatherChangedAtMs', 'transitionSeconds', 'nextRollAtMs',
}

-- The namespace this module carries under. `Open77.state` holds ONE value per
-- resource -- not a key-value store -- and this module is not the only writer
-- in it: `modules/admin/server/world.lua` carries the destinations an operator
-- placed in game. Writing the blob whole, which is what this did, meant
-- whichever wrote last destroyed the other's state, silently, on a runtime
-- where both write often. `OPX.Carry` is the one blob divided up.
local CARRY = 'weather'

-- Hands the live state to the host for the next reload. Nothing is saved before
-- the anchor is placed: an anchor of zero would restart the day at the anchor on
-- the next reload.
local function saveState()
	if not anchored then return end
	local carried = {
		PROTOCOL = M.PROTOCOL,
		authorityEpoch = authorityEpoch,
		timeFrozen = state.timeFrozen,
		weatherFrozen = state.weatherFrozen,
		weather = state.weather,
	}
	for position = 1, #CARRIED_NUMBERS do
		local field = CARRIED_NUMBERS[position]
		carried[field] = state[field]
	end
	OPX.Carry.Save(CARRY, carried)
end

-- Adopts the previous generation's carried state, or refuses it whole. The
-- carried state is untrusted input written by an earlier version of this code,
-- which may have accepted wider bounds than the wire does now, so a single bad
-- field drops all of it rather than half of it. A carried anchor stays an
-- anchor: the host's monotonic clock belongs to the process, not to this VM.
local function restoreState()
	local carried = OPX.Carry.Load(CARRY)
	if type(carried) ~= 'table' then return false end

	if carried.PROTOCOL ~= M.PROTOCOL then
		Open77.log.warn(('carried state ignored: protocol %s is not %s')
			:format(tostring(carried.PROTOCOL), tostring(M.PROTOCOL)))
		return false
	end

	local weather = findPreset(carried.weather)
	if weather == nil then
		Open77.log.warn(("carried state ignored: preset '%s' is no longer configured")
			:format(tostring(carried.weather)))
		return false
	end

	for position = 1, #CARRIED_NUMBERS do
		local field = CARRIED_NUMBERS[position]
		if not Clock.Finite(carried[field]) then
			Open77.log.warn(("carried state ignored: field '%s' is not a finite number")
				:format(field))
			return false
		end
	end
	if not Clock.Whole(carried.authorityEpoch, 0) then return false end
	if not Clock.Whole(carried.revision, 1) or not Clock.Whole(carried.weatherRevision, 1) then return false end
	if carried.rate <= 0 or carried.rate > Clock.MAX_RATE then return false end
	if carried.transitionSeconds < 0
		or carried.transitionSeconds > M.MAX_TRANSITION_SECONDS then
		return false
	end

	for position = 1, #CARRIED_NUMBERS do
		local field = CARRIED_NUMBERS[position]
		state[field] = carried[field]
	end
	state.baseSeconds = Clock.Normalize(state.baseSeconds)
	state.weather = weather.NAME
	state.timeFrozen = carried.timeFrozen == true
	state.weatherFrozen = carried.weatherFrozen == true
	authorityEpoch = carried.authorityEpoch
	anchored = true
	return true
end

-- Anchors the clock and stamps the epoch on first use. Never at load and never
-- in Init: the monotonic clock still reads near zero there, and a snapshot built
-- before the anchor would go out under epoch 0 and make the next one look like a
-- change of authority.
local function ensureAnchored()
	if anchored then return end
	local atMs = OPX.Now()
	state.anchorMs = atMs
	state.weatherChangedAtMs = atMs
	state.nextRollAtMs = atMs + M.INITIAL_WEATHER_SECONDS * 1000
	authorityEpoch = M.UnixMs() or (atMs * 1000)
	anchored = true
	saveState()
end

--- Adopts the previous generation's carried state, answering whether it did.
-- Called from `Start`, not `Init`: it reads the host's carried state, and `Init`
-- may make no host call that can fail.
-- @author dop42
-- @return boolean
function Authority.Restore()
	Authority.restored = restoreState()
	return Authority.restored
end

-- Answers the second-of-day the authority is on.
local function secondsNow(atMs)
	ensureAnchored()
	return Clock.At(state.baseSeconds, state.anchorMs, state.rate, state.timeFrozen,
		atMs or OPX.Now())
end

-- Builds the whole authoritative state as it goes on the wire.
local function snapshot(atMs, reason)
	ensureAnchored()
	local definition = findPreset(state.weather)
	local elapsedMs = math.max(0, atMs - state.weatherChangedAtMs)
	return {
		protocol = M.PROTOCOL,
		authorityEpoch = authorityEpoch,
		revision = state.revision,
		weatherRevision = state.weatherRevision,
		secondsOfDay = secondsNow(atMs),
		rate = state.rate,
		timeFrozen = state.timeFrozen,
		weather = state.weather,
		weatherPreset = definition and definition.PRESET or '',
		weatherPriority = M.WEATHER_PRIORITY,
		weatherFrozen = state.weatherFrozen,
		transitionSeconds = state.transitionSeconds,
		weatherTransitionRemainingMs = math.max(0, state.transitionSeconds * 1000 - elapsedMs),
		-- Absent, not zero, while the schedule is held: the client reads the
		-- absence as the answer.
		nextRollInMs = (not state.weatherFrozen) and math.max(0, state.nextRollAtMs - atMs) or nil,
		reason = reason,
	}
end

--- Sends a snapshot to one player, or every client when nil.
-- @author dop42
-- @param reason string
-- @param target integer|nil
-- @param requestId integer|nil
function Authority.Publish(reason, target, requestId)
	TriggerClientEvent(EVENT_SYNC, target or -1, snapshot(OPX.Now(), reason), requestId)
end

-- Moves the anchor to now without moving the clock.
local function rebase(atMs)
	state.baseSeconds = secondsNow(atMs)
	state.anchorMs = atMs
end

-- Bumps the revision, saves the carried state and publishes.
local function commit(reason)
	state.revision = state.revision + 1
	saveState()
	Authority.Publish(reason)
end

--- Sets the authoritative time of day.
-- @author dop42
--
-- CHECKED HERE, NOT ONLY BY THE COMMAND. This is a published contract and
-- trusted its argument as "already validated": a caller handing it a string or
-- a NaN wrote it into the clock, every snapshot built from it raised in
-- `Clock.At`, heartbeats and joins stopped, and the bad value was saved into
-- the carried state for the next start to inherit. It answers a Result now,
-- as `SetDayLength` and `SetWeather` do.
-- @param seconds number Second-of-day.
-- @param reason string
-- @return Result
function Authority.SetTime(seconds, reason)
	seconds = tonumber(seconds)
	if not Clock.Finite(seconds) then return OPX.Result.Err('invalid_time') end
	ensureAnchored()
	state.baseSeconds = Clock.Normalize(seconds)
	state.anchorMs = OPX.Now()
	commit(reason)
	return OPX.Result.Ok()
end

--- Holds or releases the authoritative clock.
-- @author dop42
-- @param frozen any Only true freezes.
-- @param reason string
function Authority.SetTimeFrozen(frozen, reason)
	ensureAnchored()
	rebase(OPX.Now())
	state.timeFrozen = frozen == true
	commit(reason)
end

--- Changes how many real minutes a game day takes.
-- @author dop42
-- @param minutes any
-- @param reason string
-- @return Result
function Authority.SetDayLength(minutes, reason)
	local rate, failure = Clock.RateFromDayLength(minutes)
	if rate == nil then return OPX.Result.Err(failure) end
	ensureAnchored()
	rebase(OPX.Now())
	state.rate = rate
	commit(reason)
	return OPX.Result.Ok()
end

-- Draws when the next roll is due, at the moment the preset starts.
local function scheduleRoll(definition, atMs)
	state.nextRollAtMs = atMs + math.random(definition.MIN_SECONDS, definition.MAX_SECONDS) * 1000
end

--- Crosses to a preset named by name or engine preset.
-- @author dop42
-- @param value any
-- @param transitionSeconds any|nil Nil takes the preset's own.
-- @param reason string
-- @return Result
function Authority.SetWeather(value, transitionSeconds, reason)
	if not Authority.ready then return OPX.Result.Err('no_presets') end
	local definition = findPreset(value)
	if definition == nil then return OPX.Result.Err('unknown_preset') end

	local transition = definition.TRANSITION_SECONDS
	if transitionSeconds ~= nil then
		transition = tonumber(transitionSeconds)
		if not Clock.Finite(transition) or transition < 0 or transition > M.MAX_TRANSITION_SECONDS then
			return OPX.Result.Err('invalid_transition')
		end
	end

	ensureAnchored()
	local atMs = OPX.Now()
	state.weather = definition.NAME
	state.weatherChangedAtMs = atMs
	state.transitionSeconds = transition
	scheduleRoll(definition, atMs)
	state.weatherRevision = state.weatherRevision + 1
	commit(reason)
	return OPX.Result.Ok()
end

--- Holds or releases the roll schedule, not the engine lock.
-- Releasing rearms the countdown: an expired timer would turn "resume" into
-- "next".
-- @author dop42
-- @param frozen any Only true freezes.
-- @param reason string
function Authority.SetWeatherFrozen(frozen, reason)
	ensureAnchored()
	state.weatherFrozen = frozen == true
	if not state.weatherFrozen then
		local definition = findPreset(state.weather)
		if definition then scheduleRoll(definition, OPX.Now()) end
	end
	commit(reason)
end

-- Picks the next preset by weight, excluding the one showing. When there is
-- nothing else to draw, staying put is the answer.
local function chooseNext()
	local candidates, total, count = {}, 0, 0
	for position = 1, #order do
		local definition = order[position]
		if definition.NAME ~= state.weather and definition.WEIGHT > 0 then
			total = total + definition.WEIGHT
			count = count + 1
			candidates[count] = { definition = definition, ceiling = total }
		end
	end
	if total <= 0 then return findPreset(state.weather) end

	local point = math.random() * total
	for position = 1, count do
		local candidate = candidates[position]
		if point < candidate.ceiling then return candidate.definition end
	end
	return candidates[#candidates].definition
end

--- Rolls the weighted table now, whatever the schedule says.
-- @author dop42
-- @param reason string
-- @return Result
function Authority.Roll(reason)
	local definition = chooseNext()
	if definition == nil then return OPX.Result.Err('no_presets') end
	return Authority.SetWeather(definition.NAME, nil, reason)
end

--- Rolls when one is due and answers whether it published, so that the
--- heartbeat does not double a roll.
-- @author dop42
-- @param atMs number
-- @return boolean
function Authority.Tick(atMs)
	if not Authority.ready then return false end
	ensureAnchored()
	if state.weatherFrozen or atMs < state.nextRollAtMs then return false end
	return Authority.Roll('weather_scheduled').ok == true
end

--- Resolves everything a status line needs in one place, so that a new field
--- reaches the operator's line and the player's line together.
-- @author dop42
-- @return table
function Authority.Status()
	local hour, minute, second = Clock.ToHms(secondsNow())
	return {
		hour = hour,
		minute = minute,
		second = second,
		dayLengthMinutes = Clock.DAY_SECONDS / state.rate / 60,
		timeFrozen = state.timeFrozen,
		weather = state.weather,
		weatherFrozen = state.weatherFrozen,
		nextRollInSeconds = state.weatherFrozen and nil
			or math.max(0, math.floor((state.nextRollAtMs - OPX.Now()) / 1000)),
		revision = state.revision,
	}
end

--- Renders the status as one English line for the operator.
-- @author dop42
-- @return string
function Authority.StatusText()
	local status = Authority.Status()
	return ('weather: %02d:%02d:%02d  day=%dmin%s  weather=%s%s  rev=%d%s'):format(
		status.hour, status.minute, status.second,
		math.floor(status.dayLengthMinutes + 0.5),
		status.timeFrozen and ' (clock held)' or '',
		status.weather,
		status.weatherFrozen and ' (schedule held)'
			or (' (next roll in %ds)'):format(status.nextRollInSeconds or 0),
		status.revision,
		Authority.ready and '' or '  DEGRADED: no usable preset in the weather config')
end

--- Builds the preset table and the boot state from configuration.
-- @author dop42
function M.Init()
	local Config = M.Settings

	local configured = Config.WEATHER
	for position = 1, type(configured) == 'table' and #configured or 0 do
		local row = configured[position]
		local usable = type(row) == 'table'
		local name = usable and type(row.NAME) == 'string' and row.NAME or nil
		local preset = usable and type(row.PRESET) == 'string' and row.PRESET or nil
		if name == nil or preset == nil then
			Open77.log.warn(('weather row %d ignored: NAME and PRESET must be strings')
				:format(position))
		else
			local minimum = math.max(1, math.floor(number(row.MIN_SECONDS, 300)))
			local maximum = math.max(minimum, math.floor(number(row.MAX_SECONDS, minimum)))
			local definition = {
				NAME = name,
				PRESET = preset,
				WEIGHT = math.max(0, number(row.WEIGHT, 0)),
				MIN_SECONDS = minimum,
				MAX_SECONDS = maximum,
				-- Bounded here, not only on the wire: an unbounded row would put
				-- every snapshot carrying it outside what the client accepts.
				TRANSITION_SECONDS = OPX.Math.Clamp(number(row.TRANSITION_SECONDS, 20),
					0, M.MAX_TRANSITION_SECONDS),
			}
			order[#order + 1] = definition
			index[name:lower()] = definition
			index[preset:lower()] = definition
		end
	end

	--- Whether any usable preset row exists.
	Authority.ready = #order > 0

	local startTime = Config.START_TIME or {}
	local bootSeconds = Clock.FromHms(startTime.HOUR, startTime.MINUTE, startTime.SECOND)
		or Clock.FromHms(12, 0, 0)

	local bootRate, rateFailure = Clock.RateFromDayLength(Config.DAY_LENGTH_MINUTES)
	if bootRate == nil then
		bootRate = 8.0
		Open77.log.warn(("DAY_LENGTH_MINUTES '%s' refused (%s); starting on 180")
			:format(tostring(Config.DAY_LENGTH_MINUTES), tostring(rateFailure)))
	end

	local initialWeather = findPreset(Config.INITIAL_WEATHER)
	local bootWeather = initialWeather or order[1]
	if Authority.ready and initialWeather == nil then
		Open77.log.warn(("INITIAL_WEATHER '%s' is not in the table; starting on '%s'")
			:format(tostring(Config.INITIAL_WEATHER), bootWeather.NAME))
	end

	state.revision = 1
	state.weatherRevision = 1
	state.baseSeconds = bootSeconds
	state.anchorMs = 0
	state.rate = bootRate
	state.timeFrozen = Config.TIME_FROZEN == true
	state.weather = bootWeather and bootWeather.NAME or ''
	state.weatherFrozen = Config.WEATHER_FROZEN == true
	state.weatherChangedAtMs = 0
	state.transitionSeconds = 0
	state.nextRollAtMs = 0

	--- The live authoritative state, for the boot banner.
	Authority.state = state
end
