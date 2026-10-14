--- The server's door onto one player's bar, and the verdict on how it ended.
-- @author dop42
--
-- THE BAR IS THE CLIENT'S AND THE VERDICT IS THE SERVER'S. Only the client can
-- draw a bar and hold the player still, so a server caller sends one there --
-- `opx:net:progress:start`, numbered -- and the client answers how it ended.
-- That answer is a client event, which is to say attacker-controlled, and it is
-- believed about exactly one thing: WHICH way it ended. Whether it ended
-- `finished` is decided here, by this half's own clock, against the duration
-- this half sent:
--
--   * `finished` sooner than the duration (less `EARLY_MS` of frame slack) is a
--     client that skipped the wait. It is answered `rejected`, not completed,
--     and written to the security journal.
--   * nothing at all by the duration plus `GRACE_MS` is `no_answer`, not
--     completed: a client that never reports never completes anything.
--   * the player leaving is `left`.
--
-- The latency only ever makes an honest report LATER than the clock, so the
-- slack is for the two clocks' ticks, not for the network.
--
-- ONE BAR PER PLAYER, the client's own rule said again here, so a second caller
-- is refused `progress_busy` up front rather than sent a bar the client refuses.
--
-- THE OUTCOME IS ANNOUNCED TWICE: to the caller that started it, if it handed a
-- function (a module in this VM), and on the public bus as
-- `opx:on:progress:finished` for everyone else -- which is how a separate
-- resource that called the `StartProgress` export hears it, by its own `id`.

local M = OPX.Modules.Get('progress')

local Result = OPX.Result
local Ending = M.Ending

-- Milliseconds a `finished` may arrive ahead of the server's clock: the client
-- decides on a 100 ms tick and the two clocks started a send apart.
local EARLY_MS = 150

-- Milliseconds past the duration the server waits for a report.
local GRACE_MS = 5000

-- What a client may report, beyond `finished`.
local REPORTED = {
	[Ending.STOPPED] = true,
	[Ending.CANCELLED] = true,
	[Ending.INTERRUPTED] = true,
	refused = true,
}

-- The bar each player has up for the server: `{ id, owner, startedAt,
-- durationMs, cancelable, on }`.
local bars = {}

local nextId = 0
local stopped = false

--- The duration bounds the client holds a bar to.
local function bounds()
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	local floor = math.tointeger(tonumber(settings.MIN_MS))
	local ceiling = math.tointeger(tonumber(settings.MAX_MS))
	return (floor ~= nil and floor >= 100 and floor <= 60000) and floor or 250,
		(ceiling ~= nil and ceiling >= 1000 and ceiling <= 600000) and ceiling or 60000
end

--- Whether a value is an owner name.
local function validOwner(value)
	return type(value) == 'string' and #value >= 1 and #value <= 64
		and value:match('^[%w_:%-%.]+$') ~= nil
end

--- Ends a player's bar with a verdict, once, and says so.
local function settle(source, bar, ending, completed)
	if bars[source] ~= bar then return end
	bars[source] = nil
	local payload = {
		id = bar.id,
		owner = bar.owner,
		ending = ending,
		completed = completed == true,
		elapsedMs = math.max(0, math.floor(OPX.Now() - bar.startedAt)),
	}
	if bar.on ~= nil then
		local ran, failure = pcall(bar.on, source, OPX.Table.DeepCopy(payload))
		if not ran then
			Open77.log.error(('[progress] the %s callback raised: %s')
				:format(bar.owner, tostring(failure)))
		end
	end
	OPX.Publish(M.Event.ON_FINISHED, source, payload)
end

--- Puts a bar up on one player's screen and answers its id; the outcome comes
--- later, to `on` and on `opx:on:progress:finished`.
-- @author dop42
-- @param source Source a connected player
-- @param owner string the caller's own name, carried back in the outcome
-- @param spec table { label, durationMs, cancelable, animation = { name, variant } }
-- @param on fun(source: Source, outcome: table)|nil
-- @return Result { id, durationMs }
local function start(source, owner, spec, on)
	local player = math.tointeger(tonumber(source))
	if player == nil or player < 1 or OPX.UserIdOf(player) == nil then
		return Result.Err('invalid_player')
	end
	if not validOwner(owner) then return Result.Err('invalid_caller') end
	if type(spec) ~= 'table' then return Result.Err('invalid_spec') end
	if on ~= nil and type(on) ~= 'function' then return Result.Err('invalid_spec') end
	if stopped then return Result.Err('error.unavailable') end
	if bars[player] ~= nil then return Result.Err('progress_busy') end

	local low, high = bounds()
	local duration = math.tointeger(spec.durationMs)
	if duration == nil or duration < low or duration > high then
		return Result.Err('invalid_duration')
	end
	local label = type(spec.label) == 'string' and OPX.Text.Clean(spec.label, 64, '...') or nil
	if label == nil or label == '' then return Result.Err('invalid_label') end
	local animation
	if spec.animation ~= nil then
		local named = type(spec.animation) == 'table' and spec.animation.name or nil
		if type(named) ~= 'string' or #named < 1 or #named > 32 or not named:match('^[%w_]+$') then
			return Result.Err('invalid_spec')
		end
		animation = { name = named, variant = math.tointeger(spec.animation.variant) }
	end

	nextId = nextId % 2147483646 + 1
	local bar = {
		id = nextId,
		owner = owner,
		startedAt = OPX.Now(),
		durationMs = duration,
		cancelable = spec.cancelable == true,
		on = on,
	}
	bars[player] = bar
	TriggerClientEvent(M.Event.START, player, {
		id = bar.id,
		label = label,
		durationMs = duration,
		cancelable = bar.cancelable,
		animation = animation,
	})
	-- The deadline is a thread of its own and not a loop over every bar: one
	-- thread per bar, which ends the moment the verdict is in.
	local deadline = bar.startedAt + duration + GRACE_MS
	CreateThread(function()
		while bars[player] == bar and OPX.Now() < deadline do Wait(500) end
		settle(player, bar, 'no_answer', false)
	end)
	return Result.Ok({ id = bar.id, durationMs = duration })
end

--- Takes down a bar this owner put up. With an id, only that bar.
-- @author dop42
-- @param source Source
-- @param owner string
-- @param id integer|nil
-- @return Result
local function stop(source, owner, id)
	local player = math.tointeger(tonumber(source))
	local bar = player ~= nil and bars[player] or nil
	if bar == nil then return Result.Err('progress_not_active') end
	if bar.owner ~= owner or (id ~= nil and bar.id ~= id) then return Result.Err('not_owner') end
	TriggerClientEvent(M.Event.CANCEL, player, bar.id)
	settle(player, bar, Ending.STOPPED, false)
	return Result.Ok(true)
end

--- The bar the server has up on one player, or nil.
-- @author dop42
-- @param source Source
-- @return Result { id, owner, remainingMs }|nil
local function state(source)
	local bar = bars[math.tointeger(tonumber(source)) or -1]
	if bar == nil then return Result.Ok(nil) end
	return Result.Ok({ id = bar.id, owner = bar.owner,
		remainingMs = math.max(0, bar.durationMs - math.floor(OPX.Now() - bar.startedAt)) })
end

--- What a client says about the bar it was sent.
local function report(player, id, ending)
	local bar = bars[player]
	if bar == nil or math.tointeger(id) ~= bar.id or type(ending) ~= 'string' then return end
	if ending == Ending.FINISHED then
		local elapsed = OPX.Now() - bar.startedAt
		if elapsed + EARLY_MS < bar.durationMs then
			OPX.Audit.Security('progress.early',
				('player %d finished %s\'s bar after %d of %d ms'):format(player, bar.owner,
					math.floor(elapsed), bar.durationMs),
				{ owner = bar.owner, id = bar.id }, player)
			return settle(player, bar, 'rejected', false)
		end
		return settle(player, bar, Ending.FINISHED, true)
	end
	if REPORTED[ending] then return settle(player, bar, ending, false) end
end

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	bars, stopped = {}, false
end

--- Publishes the three operations addressed at one player.
-- @author dop42
function M.Api()
	OPX.Api.Provide('progress', 1, {
		Start = start,
		Stop = stop,
		State = state,
	})
end

--- Hears the reports and the departures.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.REPORT, function(id, ending)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		report(player, id, ending)
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = math.tointeger(tonumber(playerId))
		local bar = player ~= nil and bars[player] or nil
		if bar ~= nil then settle(player, bar, 'left', false) end
	end)
end

--- Every bar still up ends, not completed.
-- @author dop42
function M.Stop()
	stopped = true
	for player, bar in pairs(bars) do settle(player, bar, Ending.INTERRUPTED, false) end
end
