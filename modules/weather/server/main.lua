--- Server wiring: the contract, sync requests, arrivals, the roll loop and the
--- boot banner.
-- @author dop42

local M = OPX.Modules.Get('weather')
local Authority = M.Authority
local Clock = M.Clock
local SYNC = M.SYNC

-- The only inbound event: a client asking for a snapshot. A client may ask, and
-- may never mutate.
local EVENT_REQUEST = OPX.Event(OPX.Channel.NET, 'weather', 'request')

-- Last sync request per player, for the request floor.
local lastRequestMs = {}

-- When the next heartbeat is due, on the monotonic clock.
local nextHeartbeatMs = 0

-- Seeds the random rolls from the wall clock and arms the heartbeat. Drawn on
-- the first turn of the loop, never at load: the monotonic clock still reads
-- zero there, it only moves in steps of a millisecond, and the module always
-- loads at the same point in the process's life -- a narrow band of nearly
-- identical seeds that replayed about the same weather after every restart.
local function seed()
	local base = M.UnixMs() or math.floor(OPX.Now())
	math.randomseed(base % 2147483647)
	nextHeartbeatMs = OPX.Now() + SYNC.HEARTBEAT_MS
end

-- Rolls when due and republishes on the heartbeat otherwise.
local function schedule()
	local atMs = OPX.Now()
	local published = Authority.Tick(atMs)
	if atMs >= nextHeartbeatMs then
		if not published then Authority.Publish('heartbeat') end
		nextHeartbeatMs = atMs + SYNC.HEARTBEAT_MS
	end
end

-- Answers a player's sync request with an addressed snapshot. `source` comes
-- from the authenticated connection, never from the payload.
local function onRequest(requestId)
	local player = tonumber(source) or 0
	if player <= 0 then return end

	requestId = tonumber(requestId)
	if not Clock.Whole(requestId, 1) then return end

	local atMs = OPX.Now()
	local previous = lastRequestMs[player]
	if previous ~= nil and atMs - previous < SYNC.MIN_REQUEST_MS then return end
	lastRequestMs[player] = atMs

	Authority.Publish('request', player, requestId)
end

--- Publishes the authority so that another module can drive it without reaching
--- into this one.
-- @author dop42
function M.Api()
	OPX.Api.Provide('weather', 1, {
		Ready = function() return Authority.ready == true end,
		Status = Authority.Status,
		StatusText = Authority.StatusText,
		Presets = Authority.Presets,
		SetTime = Authority.SetTime,
		SetTimeFrozen = Authority.SetTimeFrozen,
		SetDayLength = Authority.SetDayLength,
		SetWeather = Authority.SetWeather,
		SetWeatherFrozen = Authority.SetWeatherFrozen,
		Roll = Authority.Roll,
	})
end

--- Adopts the carried state, wires the events and starts the roll loop.
-- @author dop42
function M.Start()
	-- First, and before anything can publish: a snapshot built before the
	-- carried state is adopted would go out under a fresh epoch and every client
	-- would read the generation that follows as a change of authority.
	Authority.Restore()

	RegisterNetEvent(EVENT_REQUEST, onRequest)

	-- Sends the current sky to an admitted player: one event against the jump he
	-- would see while waiting for his own request or the next heartbeat. Reading
	-- state and addressing a payload to a player who has not passed the
	-- availability gate is safe; acting on his body is not.
	AddEventHandler(OPX.Host.PLAYER_CONNECTED, function(playerId)
		local player = math.floor(tonumber(playerId) or 0)
		if player <= 0 then return end
		Authority.Publish('joined', player)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		lastRequestMs[math.floor(tonumber(playerId) or 0)] = nil
	end)

	M.Commands.Register()
	M.Population.Start()

	-- The seed runs here, the rolls run on a job. Under pcall because this one is
	-- on the boot stack: a raise from a host read at seed time would take the
	-- module's whole `Start` with it, and a session with no weather authority is
	-- worse than one that starts on the configured sky.
	local seeded, why = pcall(seed)
	if not seeded then Open77.log.warn('weather:seed failed: ' .. tostring(why)) end

	OPX.Scheduler.Every('weather:schedule', SYNC.SCHEDULER_MS, schedule)

	if Authority.restored then
		Open77.log.info('authority resumed across a reload -- ' .. Authority.StatusText())
	else
		local hour, minute, second = Clock.ToHms(Authority.state.baseSeconds)
		Open77.log.info(('authority ready at %02d:%02d:%02d on %s -- reload keeps the sky, ' ..
			'restart returns it to configuration'):format(
			hour, minute, second, Authority.state.weather))
	end

	-- On a thread, not inline: a resource that starts after this one has not
	-- been launched yet at the moment this runs.
	CreateThread(function()
		local read, official = pcall(GetResourceState, 'open77_weather')
		official = read and tostring(official or ''):lower() or ''
		if official ~= 'running' and official ~= 'starting' then return end
		Open77.log.warn('open77_weather is running and is the package this module replaces')
		Open77.log.warn('  two authorities both hold world.environment: the clock is corrected twice')
		Open77.log.warn('  a second toward two different times, and the sky is whichever authority')
		Open77.log.warn('  rolled last. Drop one from resources.load in server.jsonc.')
	end)
end
