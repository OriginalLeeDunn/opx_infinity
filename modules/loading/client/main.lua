--- The read, the decision and the two places it is told: the page and the bus.
-- @author dop42
--
-- ONE JOB, AND IT IS CHEAP ON PURPOSE. The scheduler runs `pass` every
-- `POLL_MS`; a pass makes one host call and, when the `revision` it answers is
-- the one already acted on, returns. That is every pass but a handful per load,
-- so the standing cost of this module is one native read five times a second.
-- No thread of its own, no `while true`, nothing that can walk past the
-- per-resume instruction budget the header of `core/client/scheduler.lua`
-- warns about.
--
-- THE READER IS LOOKED UP ON EVERY PASS, NEVER CACHED. A client too old to have
-- it answers `unavailable` on the first pass, says so once in its own log and
-- the job is cancelled -- a module that can never learn anything stops asking.
-- `isLoading` alone (no table) is accepted as a poorer reader: it can hide the
-- views, and it can cover a load, but it cannot draw progress.
--
-- A READ THAT FAILS IS A LOAD THAT IS NOT UP. The two wrong answers are not the
-- same size: views shown over a loading screen for one pass are a blemish, and
-- views hidden for the rest of the session because a read stopped answering
-- are a HUD that is gone. So a refusal clears everything this module asked for.
-- `permission_denied` is permanent and also stops the job, with one line in
-- the operator's journal -- it is a client permission, so the player's log is
-- the only other place it would ever appear.

local M = OPX.Modules.Get('loading')

M.Runtime = {}
local Runtime = M.Runtime

local Result = OPX.Result

local TAG = 'loading'

-- The page channels. `OPX.UI.Send` prefixes the surface id. `loading:ready` is
-- wired by `core/client/ui.lua` for every declared module and emitted by
-- `ui/src/boot/createSurface.ts`, because the hide is bound at the surface and
-- not in any view.
local SURFACE = 'overlay'
local CHANNEL_STATE = 'loading:state'
local CHANNEL_READY = 'loading:ready'

-- Distinct transient refusals logged per session. A reader that fails every
-- pass for a new reason each time is not worth a file full of them.
local MAX_REASONS = 4

local job = nil

-- Which reader answered last: 'state', 'flag', or nil before the first pass.
local mode = nil

-- The revision last acted on. Reset to nil to force the next pass through.
local revision = nil

-- The cycle being watched: its id and when this module first saw it active.
local cycleId, startedAt = nil, nil

-- The cycle that was already up the first time this module looked, which is
-- the join. `true` when the reader has no ids to tell cycles apart by.
local joinCycle = nil
local looked = false

-- What was decided, and what the page and the bus were last told.
local decided = nil
local sentSignature = nil
local announced = { active = false, cover = false }

local reasons, reasonCount = {}, 0
local refusedForGood = false

--- A name for the bay: plain text, trimmed, at most 32 characters, or ''.
-- Anything else -- a table, a control character, a name longer than the mark
-- can hold -- is the cover's own name, not an error on a player's screen.
local function bayText(value)
	if type(value) ~= 'string' then return '' end
	local trimmed = value:match('^%s*(.-)%s*$')
	if trimmed:find('%c') then return '' end
	-- Characters where the sandbox has `utf8` (the form module reads it the same
	-- way), bytes where it does not: the stricter of the two, never an error.
	-- Text that is not UTF-8 at all is not a name the page could draw.
	local length = #trimmed
	if utf8 then
		length = utf8.len(trimmed)
		if length == nil then return '' end
	end
	if length > 32 then return '' end
	return trimmed
end

--- Reads the settings once, with the shipped values for anything unusable.
local function tuning()
	local settings = type(M.Settings) == 'table' and M.Settings
		or OPX.Config.MODULES.loading or {}
	local cover = type(settings.COVER) == 'table' and settings.COVER or {}
	local delay = tonumber(cover.DELAY_MS)
	local poll = tonumber(settings.POLL_MS)
	return {
		hide = settings.HIDE_HUD ~= false,
		cover = cover.ENABLED ~= false,
		video = cover.VIDEO ~= false,
		name = bayText(cover.NAME),
		subtitle = bayText(cover.SUBTITLE),
		-- `x >= 0` is false for NaN, so a NaN falls through to the default.
		delay = (delay ~= nil and delay >= 0 and delay <= 5000) and math.floor(delay) or 250,
		poll = (poll ~= nil and poll >= 50 and poll <= 2000) and math.floor(poll) or 200,
	}
end

--- The reader this client has, and which kind it is, or nil.
local function reader()
	local screen = type(Open77) == 'table' and Open77.screen or nil
	if type(screen) ~= 'table' then return nil end
	if type(screen.loadingState) == 'function' then return 'state', screen.loadingState end
	if type(screen.isLoading) == 'function' then return 'flag', screen.isLoading end
	return nil
end

--- A fraction in 0..1, or nil for anything that is not a finite number.
local function fraction(value)
	local number = tonumber(value)
	if number == nil or number ~= number then return nil end
	if number < 0 then return 0 end
	if number > 1 then return 1 end
	return number
end

--- One read, normalised. Nothing the host answers is believed past its type.
-- @return table|nil snapshot
-- @return string|nil why there is none
-- @return string|nil which reader answered
local function read()
	local kind, fn = reader()
	if kind == nil then return nil, 'unavailable' end

	local ok, value, reason = pcall(fn)
	if not ok then return nil, tostring(value), kind end

	if kind == 'flag' then
		if type(value) ~= 'boolean' then return nil, tostring(reason or 'no_answer'), kind end
		return { active = value, kind = 'unknown', progressKnown = false }, nil, kind
	end

	if type(value) ~= 'table' then return nil, tostring(reason or 'no_answer'), kind end
	local progress = fraction(value.progress)
	return {
		active = value.active == true,
		id = value.id ~= nil and tostring(value.id) or nil,
		revision = tonumber(value.revision),
		kind = (type(value.kind) == 'string' and M.Kinds[value.kind]) and value.kind or 'unknown',
		-- KNOWN MEANS A NUMBER CAME WITH IT. A flag saying "known" over a nil is
		-- a bar with nothing to fill it, so it is read as unknown.
		progressKnown = value.progressKnown == true and progress ~= nil,
		progress = progress,
		elapsedMs = tonumber(value.elapsedMs),
	}, nil, kind
end

--- Tells the page, once per change. A send the host did not take is forgotten,
--- so the next pass sends it again.
local function draw(force)
	local view = decided or { hide = false, cover = false }
	local payload = {
		hide = view.hide == true,
		cover = view.cover == true,
		video = view.video == true,
		name = view.name or '',
		subtitle = view.subtitle or '',
		kind = view.kind or 'unknown',
		progressKnown = view.cover == true and view.progressKnown == true,
		-- Thousandths: finer than any bar can draw, and coarse enough that a
		-- fraction jittering in its last digits is not a send per pass.
		progress = view.progress ~= nil and math.floor(view.progress * 1000 + 0.5) / 1000 or 0,
	}
	local signature = ('%s|%s|%s|%s|%s|%s|%s|%s'):format(tostring(payload.hide),
		tostring(payload.cover), tostring(payload.video), payload.kind,
		tostring(payload.progressKnown), tostring(payload.progress), payload.name, payload.subtitle)
	if not force and signature == sentSignature then return end

	local sent, refused = OPX.UI.Send(SURFACE, CHANNEL_STATE, payload)
	if sent and not refused then
		sentSignature = signature
	else
		-- Not drawn: the next pass must not take the cheap exit over it.
		sentSignature, revision = nil, nil
	end
end

--- Tells the bus when a load starts or ends, or the cover comes or goes.
local function announce(snapshot)
	local view = decided or {}
	local active, cover = view.active == true, view.cover == true
	if announced.active == active and announced.cover == cover then return end
	announced = { active = active, cover = cover }
	TriggerEvent(M.Event.ON_STATE, {
		active = active,
		cover = cover,
		kind = view.kind or 'unknown',
		id = snapshot and snapshot.id or nil,
	})
end

--- Decides from one snapshot -- or from none, which is a load that is not up.
-- @param snapshot table|nil
local function settle(snapshot)
	local settings = tuning()
	local now = OPX.Now()
	local active = snapshot ~= nil and snapshot.active == true

	-- THE FIRST LOOK NAMES THE JOIN. Whatever is up when this module first sees
	-- the screen started before any of our Lua did, and that is the connection.
	if snapshot ~= nil and not looked then
		looked = true
		if active then joinCycle = snapshot.id or true end
	end

	local join = false
	if not active then
		cycleId, startedAt = nil, nil
		-- Over once it has ended. Every load after it is a load in play.
		joinCycle = nil
	else
		if startedAt == nil or (snapshot.id ~= nil and snapshot.id ~= cycleId) then
			cycleId, startedAt = snapshot.id, now
		end
		join = joinCycle ~= nil and (joinCycle == true or joinCycle == snapshot.id)
	end

	local eligible = active and settings.cover and not join
		and not M.Connection[snapshot.kind]
	local elapsed = 0
	if active then
		elapsed = math.max(snapshot.elapsedMs or 0, now - (startedAt or now))
	end
	local cover = eligible and elapsed >= settings.delay

	decided = {
		active = active,
		hide = active and settings.hide,
		cover = cover,
		-- Still counting towards the delay: the cheap exit must not skip it.
		waiting = eligible and not cover,
		video = settings.video,
		name = settings.name,
		subtitle = settings.subtitle,
		kind = active and snapshot.kind or 'unknown',
		progressKnown = cover and snapshot.progressKnown == true,
		progress = cover and snapshot.progress or nil,
	}

	draw(false)
	announce(snapshot)
end

--- Stops asking. The views get back whatever they had.
local function retire()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	settle(nil)
end

--- A read that answered nothing. Clears what was asked for, and says why once.
local function refused(why)
	why = tostring(why or 'no_answer')

	if why == 'unavailable' then
		-- An older client. Normal, expected and permanent: one line, here.
		Open77.log.info(('[%s] this client has no Open77.screen.loadingState; '
			.. 'the views keep their own visibility during loads'):format(TAG))
		return retire()
	end

	if why:find('permission_denied', 1, true) ~= nil then
		if not refusedForGood then
			refusedForGood = true
			Open77.log.error(('[%s] the loading state was refused: %s'):format(TAG, why))
			OPX.Note(TAG, ('the loading state was refused on this client (%s): '
				.. 'declare %s in open77.lua'):format(why, M.PERMISSION))
		end
		return retire()
	end

	if reasons[why] == nil and reasonCount < MAX_REASONS then
		reasons[why] = true
		reasonCount = reasonCount + 1
		Open77.log.warn(('[%s] the loading state could not be read: %s'):format(TAG, why))
	end
	revision = nil
	settle(nil)
end

--- One pass of the job.
local function pass()
	local snapshot, why, kind = read()
	if snapshot == nil then return refused(why) end

	if mode ~= kind then
		mode = kind
		Open77.log.info(('[%s] reading the native loading lifecycle through %s'):format(TAG,
			kind == 'state' and 'loadingState' or 'isLoading (no progress, no kind)'))
	end

	-- THE CHEAP EXIT, and it is the pass almost every time: the platform says
	-- nothing has moved, and nothing here is waiting on a clock.
	if snapshot.revision ~= nil and snapshot.revision == revision
		and not (decided ~= nil and decided.waiting) then
		return
	end
	revision = snapshot.revision
	settle(snapshot)
end

--- What the module last decided, for a test or a caller that reads instead of
--- listening.
-- @author dop42
-- @return table
function Runtime.Snapshot()
	local view = decided or {}
	return {
		available = job ~= nil,
		mode = mode,
		active = view.active == true,
		hide = view.hide == true,
		cover = view.cover == true,
		kind = view.kind or 'unknown',
		progressKnown = view.progressKnown == true,
		progress = view.progress,
	}
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Forgets everything held. Never yields and reaches no other module.
-- @author dop42
function M.Init()
	job, mode, revision = nil, nil, nil
	cycleId, startedAt = nil, nil
	joinCycle, looked = nil, false
	decided, sentSignature = nil, nil
	announced = { active = false, cover = false }
	reasons, reasonCount, refusedForGood = {}, 0, false
end

--- Publishes the read-only state.
-- @author dop42
function M.Api()
	OPX.Api.Provide('loading', 1, {
		--- Whether a native load is up, and whether OPX is covering it.
		State = function() return Result.Ok(Runtime.Snapshot()) end,
	})
end

--- Wires the page and starts the one job.
-- @author dop42
function M.Start()
	OPX.UI.On(SURFACE, CHANNEL_READY, function()
		-- A new DOM holds nothing this module told the old one.
		draw(true)
	end)

	job = OPX.Scheduler.Every('loading.watch', tuning().poll, pass)
end

--- Stops the job and gives every view back.
-- @author dop42
function M.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	decided = nil
	draw(true)
	announce(nil)
end
