--- Mirrors the service's playback states and poses streamed bodies to match.
-- @author dop42
--
-- The presenter decides nothing: the service is the only producer of a playback
-- state. Without the presentation natives the mirror stays empty and the `State`
-- contract function answers `presentation_unavailable`.
--
-- `validState` bounds a profile and a clip without looking them up in the
-- catalogue: a profile this catalogue does not carry is still the service's to
-- replicate, and the natives validate it.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common
local Opt = M.Opt

M.Presenter = {}
local Presenter = M.Presenter

-- Presenter tick. A snapshot is asked for every SYNC_MS, a paged one abandoned
-- after BATCH_MS unless the worker is still taking its pages, and a playback this client released stays unposed HOLD_MS
-- while the finished state travels.
local TICK_MS = 100
local SYNC_MS = 5000
local HOLD_MS = 5000
local BATCH_MS = 10000

-- Change events raised per tick at most: arriving in a loaded bucket would
-- otherwise raise hundreds in one resume.
local DRAIN = 32

local MAX_BUCKET = 4294967295
local MAX_ID = Common.MAX_INTEGER

local integer, text = Common.Integer, Common.Text

-- Service incarnation mirrored, and the last committed snapshot revision.
local epoch, floor = nil, -1

-- Active state per player, and the newest revision seen.
local mirror, seen = {}, {}

-- What is posed per player: entity, signature, profile, clip.
local posedBy = {}

-- Entity and signature the natives refused, retried when either changes.
local failed = {}

-- Playbacks this client released, left unposed until a deadline.
local held = {}

-- Changes waiting to be raised; false means no longer playing.
local changes = {}

-- The paged snapshot being assembled, and the last context read.
local batch, context = nil, nil

-- This generation's request id prefix, and the last serial used.
local nonce, serial = nil, 0

-- When the next snapshot request and presenter decision are due.
local nextSyncMs, nextLookMs = 0, 0

-- Whether this client poses bodies; nil before the first decision.
local presenting = nil

-- The scheduler handle of the tick, so Stop can cancel it.
local tickJob = nil

-- Read at the moment of use: at load the host may not have installed the API.
local function api()
	local native = Open77.animations
	return type(native) == 'table' and native or nil
end

--- Whether this client has the presentation natives at all.
-- @author dop42
-- @return boolean
function Presenter.Available()
	local native = api()
	return native ~= nil and type(native._context) == 'function' and
		type(native._playProfile) == 'function' and type(native.stop) == 'function'
end

-- Answers the next request id carrying this generation's nonce. Every client
-- shares `open77:animations:result`, so only an id carrying the nonce is ours.
local function wireId()
	serial = serial + 1
	return nonce .. ':' .. serial
end

-- Whether a state's steps are a bounded, well-formed sequence.
local function validSteps(steps)
	if type(steps) ~= 'table' then return false end
	local count = #steps
	if count < 1 or count > 16 then return false end
	local keys = 0
	for key in pairs(steps) do
		if integer(key, 1, count) == nil then return false end
		keys = keys + 1
	end
	if keys ~= count then return false end
	for index = 1, count do
		local step = steps[index]
		if type(step) ~= 'table' or not text(step.profile, 64) or not text(step.clip, 128) or
			integer(step.durationMs, 0, M.SERVICE_MAX_MS) == nil then
			return false
		end
	end
	return true
end

-- Whether a value is a well-formed playback state off the wire.
local function validState(s)
	if type(s) ~= 'table' then return false end
	if not text(s.epoch, 64) or not text(s.playbackId, 64) then return false end
	if integer(s.revision, 0, MAX_ID) == nil or integer(s.playerId, 1, MAX_ID) == nil then
		return false
	end
	if type(s.active) ~= 'boolean' or integer(s.bucket, 0, MAX_BUCKET) == nil then return false end
	if not validSteps(s.steps) then return false end
	return integer(s.step, 0, #s.steps - 1) ~= nil and integer(s.cycle, 0, MAX_ID) ~= nil
end

-- Answers what a listener is told about one player's playback. The raw state,
-- which has the service's shape, is never handed out.
local function describe(playerId, s)
	if not s or not s.active then return { playerId = playerId, active = false } end
	local step = s.steps[s.step + 1]
	local entry = Catalogue.Entry(step.profile)
	return {
		playerId = playerId,
		active = true,
		playbackId = s.playbackId,
		animation = step.profile,
		clip = step.clip,
		variant = entry and Catalogue.VariantOf(entry.name, step.clip) or nil,
		known = entry ~= nil,
		step = s.step + 1,
		steps = #s.steps,
		cycle = s.cycle,
	}
end

-- Stops posing one player's body.
local function undraw(playerId)
	local posed = posedBy[playerId]
	if posed == nil then return end
	posedBy[playerId] = nil
	local native = api()
	if native ~= nil then pcall(native.stop, posed.entity) end
end

local function undrawAll()
	for playerId in pairs(posedBy) do undraw(playerId) end
end

-- Takes one validated state into the mirror, ordered by revision. A live state
-- at or below the last snapshot is older than what that snapshot said.
local function accept(s, fromSnapshot)
	local playerId = s.playerId
	if seen[playerId] ~= nil and seen[playerId] >= s.revision then return false end
	if not fromSnapshot and s.revision <= floor then return false end
	seen[playerId] = s.revision

	local old = mirror[playerId]
	if old == nil or old.playbackId ~= s.playbackId then failed[playerId] = nil end
	if s.active then
		mirror[playerId] = s
	else
		mirror[playerId], failed[playerId], held[playerId] = nil, nil, nil
		undraw(playerId)
	end
	changes[playerId] = s.active and s or false
	return true
end

-- Live states that landed while a commit was part-way through, and whether one
-- is: the commit walks the mirror across yields, so a state arriving meanwhile
-- waits for it and is taken after, as it was when the commit ran in one piece.
local deferred, committing = {}, false
local MAX_DEFERRED = 1024

-- Takes one validated live state into the mirror.
local function take(s)
	if epoch ~= nil and s.epoch ~= epoch then return end
	if context ~= nil and s.active and s.bucket ~= context.bucket then return end
	epoch = epoch or s.epoch
	accept(s, false)
end

-- Takes one live state from the service's wire.
local function onState(s)
	if not validState(s) then return end
	if committing then
		if #deferred < MAX_DEFERRED then deferred[#deferred + 1] = s end
		return
	end
	take(s)
end

-- WORK ON THE SNAPSHOT WORKER IS PACED BY WEIGHT, NOT BY STATE COUNT. It
-- yielded every 16 states, which held a page of one-step states near 5,700
-- instructions a resume and let a page of sixteen-step states, or the commit of
-- a 128-page bucket, run straight past the client's budget. Each piece of work
-- now charges what it costs, in units of about 25 instructions -- a state
-- checked ten plus four a step, a state merged, scanned or committed one or
-- two -- and the worker yields before the tab would pass PACE_UNITS, about
-- 2,500 instructions. Outside a coroutine (no CreateThread) nothing yields.
-- A reset while the worker sleeps moves `era` on; the page in hand belongs to
-- the world before and is dropped where it stands.
local PACE_UNITS = 100
local owed, era, pageEra = 0, 0, 0

-- Yields on the snapshot worker, and nowhere else. A worker that breathes is
-- alive however long its snapshot takes.
local workingSince = 0
local function breathe()
	owed, workingSince = 0, OPX.Now()
	if type(Wait) == 'function' and coroutine.isyieldable() then Wait(0) end
end

-- Charges `units` of work, about to be done, to the worker's current resume,
-- yielding first when they would take it past PACE_UNITS; false once a reset
-- has made the page in hand stale.
local function pace(units)
	if owed + units > PACE_UNITS then breathe() end
	owed = owed + units
	return pageEra == era
end

-- What checking one state off the wire is worth: a base, plus its steps.
local function weightOf(s)
	local steps = type(s) == 'table' and s.steps or nil
	if type(steps) ~= 'table' then return 10 end
	local count = #steps
	return 10 + 4 * (count > 16 and 16 or count)
end

-- Replaces the mirror with a complete snapshot; absence in one means an end.
-- Only a complete snapshot may move the mirror to another incarnation of the
-- service: a different epoch means it restarted and nothing it said before holds.
local function apply(snapshotEpoch, revision, states)
	if epoch ~= nil and epoch ~= snapshotEpoch then
		for playerId in pairs(mirror) do
			changes[playerId] = false
			if not pace(1) then return end
		end
		undrawAll()
		mirror, seen, failed, held, floor = {}, {}, {}, {}, -1
	end
	epoch = snapshotEpoch

	for playerId, old in pairs(mirror) do
		if states[playerId] == nil and old.revision <= revision then
			mirror[playerId], failed[playerId], held[playerId] = nil, nil, nil
			undraw(playerId)
			changes[playerId] = false
		end
		if not pace(1) then return end
	end
	for _, s in pairs(states) do
		accept(s, true)
		if not pace(2) then return end
	end

	if revision > floor then floor = revision end
	for playerId, known in pairs(seen) do
		if mirror[playerId] == nil and known <= floor then seen[playerId] = nil end
		if not pace(1) then return end
	end
end

-- Commits, holding live states back until the mirror is consistent again.
local function commit(snapshotEpoch, revision, states)
	committing = true
	local ran, failure = pcall(apply, snapshotEpoch, revision, states)
	committing = false
	local waiting = deferred
	deferred = {}
	if not ran then error(failure, 0) end
	-- Already checked on arrival, and taken against the context of now, as on
	-- arrival; a newer state landing meanwhile wins by revision.
	for index = 1, #waiting do
		take(waiting[index])
		pace(2)
	end
end

-- Takes one snapshot page, committing once every page has arrived. One assembly
-- at a time: the service sends its pages in order on a single channel.
local function takePage(page)
	pageEra = era
	if type(page) ~= 'table' or not text(page.epoch, 64) then return end
	local revision = integer(page.revision, 0, MAX_ID)
	local bucket = integer(page.bucket, 0, MAX_BUCKET)
	if revision == nil or bucket == nil then return end
	if context ~= nil and bucket ~= context.bucket then return end
	if epoch == page.epoch and revision < floor then return end

	local states = page.states
	if type(states) ~= 'table' or #states > 64 then return end
	local slice = {}
	for index = 1, #states do
		local s = states[index]
		if not pace(weightOf(s)) then return end
		if not validState(s) or s.epoch ~= page.epoch or s.bucket ~= bucket or not s.active or
			s.revision > revision or slice[s.playerId] ~= nil then
			return
		end
		slice[s.playerId] = s
	end

	local total, part = 1, 1
	if page.total ~= nil then
		total = integer(page.total, 1, 128)
		part = total and integer(page.slice, 1, total)
		if total == nil or part == nil or not text(page.snapshotId, 64) then return end
	end
	if total == 1 then return commit(page.epoch, revision, slice) end

	if batch == nil or batch.id ~= page.snapshotId then
		batch = { id = page.snapshotId, epoch = page.epoch, revision = revision, bucket = bucket,
			total = total, parts = {}, arrived = 0, atMs = OPX.Now() }
	end
	if batch.epoch ~= page.epoch or batch.revision ~= revision or batch.bucket ~= bucket or
		batch.total ~= total then
		batch = nil
		return
	end
	if batch.parts[part] == nil then batch.arrived = batch.arrived + 1 end
	batch.parts[part] = slice
	if batch.arrived < total then return end

	-- The merge and the commit start a resume of their own, and pace it.
	local assembled = batch
	batch = nil
	breathe()
	if pageEra ~= era then return end
	local merged = {}
	for index = 1, total do
		for playerId, s in pairs(assembled.parts[index]) do
			if merged[playerId] ~= nil then return end
			merged[playerId] = s
			if not pace(1) then return end
		end
	end
	commit(page.epoch, revision, merged)
end

-- THE SNAPSHOT IS VALIDATED AND COMMITTED OFF THE NET HANDLER. A page carries
-- up to 64 states, each checked field by field with up to 16 steps, and the last
-- page merged every page and committed the whole bucket -- all inside the net
-- event's one resume: thousands of instructions a page, and a budget kill there
-- left `batch` half-built until the ten-second abandon. The handler now only
-- queues the page; one worker thread takes the pages in order, yielding every
-- few states and before the commit.
local pages, working = {}, false
local MAX_PAGES = 128
local WORKER_STALE_MS = 5000

-- Whether the worker is alive and has work in hand. A paged snapshot is not
-- abandoned while it is: its pages are waiting on the worker, not missing.
local function busy()
	return working and OPX.Now() - workingSince < WORKER_STALE_MS
end

local function onSnapshot(page)
	if type(page) ~= 'table' then return end
	if type(CreateThread) ~= 'function' then return takePage(page) end
	if #pages >= MAX_PAGES then return end
	pages[#pages + 1] = page
	-- A worker the budget killed never clears `working`; one silent this long is
	-- presumed dead and replaced.
	if busy() then return end
	working, workingSince = true, OPX.Now()
	CreateThread(function()
		while #pages > 0 do
			workingSince = OPX.Now()
			local ran, failure = pcall(takePage, table.remove(pages, 1))
			if not ran then
				Open77.log.warn(('[animations] a snapshot page raised: %s'):format(tostring(failure)))
			end
		end
		working = false
	end)
end

-- Answers a player's body entity on this client, or nil. The local player is
-- entity 0 to the natives.
local function entityOf(playerId)
	if playerId == context.playerId then return 0 end
	local players = context.players
	if type(players) ~= 'table' then return nil end
	local entity = players[playerId]
	if entity == nil then entity = players[tostring(playerId)] end
	return entity
end

-- Records a refused pose, raises the failure and tells the hook.
local function fail(playerId, s, entity, signature, reason)
	failed[playerId] = { entity = entity, signature = signature }
	undraw(playerId)
	local code = Common.Code(reason) or 'presentation_failed'
	TriggerEvent(M.Event.ON_FAILED, { playerId = playerId, playbackId = s.playbackId,
		reason = code })
	if playerId == context.playerId then
		Open77.log.warn(('[animations] own playback %s could not be posed: %s')
			:format(s.playbackId, code))
		Presenter.OnOwnFailed(s.playbackId, code)
	else
		Open77.log.debug(('[animations] player %d playback could not be posed: %s')
			:format(playerId, code))
	end
end

-- Poses one streamed body to match its mirrored state.
local function pose(native, playerId, s, entity, atMs)
	local hold = held[playerId]
	if hold ~= nil and (hold.playbackId ~= s.playbackId or atMs >= hold.untilMs) then
		held[playerId], hold = nil, nil
	end
	if hold ~= nil then return end
	local step = s.steps[s.step + 1]
	local signature = s.playbackId .. ':' .. s.cycle .. ':' .. s.step
	local failure = failed[playerId]
	if failure ~= nil and (failure.signature ~= signature or failure.entity ~= entity) then
		failed[playerId], failure = nil, nil
	end
	if failure ~= nil then return end
	local posed = posedBy[playerId]
	if posed == nil or posed.signature ~= signature then
		local restart = posed ~= nil and posed.profile == step.profile and posed.clip == step.clip
		local called, played, reason = pcall(native._playProfile, entity, step.profile,
			step.clip, restart)
		if called and played then
			posedBy[playerId] = { entity = entity, signature = signature,
				profile = step.profile, clip = step.clip }
		else
			fail(playerId, s, entity, signature, called and reason or 'play_raised')
		end
	elseif type(native._profileStatus) == 'function' then
		local called, status = pcall(native._profileStatus, entity)
		if called and status ~= 'ok' and status ~= 'device_pending' then
			fail(playerId, s, entity, signature, status)
		end
	end
end

-- Poses every streamed body to match the mirror. The same clip again is a
-- restart, so a looping cycle does not blend into itself; `device_pending` is a
-- prop or workspot still streaming, not a failure.
--
-- THE TICK WALKS THE STREAMED BODIES, NOT THE MIRROR. Only a body this client
-- streams can be posed, and the mirror holds the whole bucket: walked every
-- tick it cost some 35 instructions a mirrored player, past the client budget
-- from about a hundred players up. A key the context carries twice (as a
-- number and as a string) is posed once, under the entity `entityOf` answers.
local function present(atMs)
	local native = api()
	for playerId, posed in pairs(posedBy) do
		if mirror[playerId] == nil or entityOf(playerId) ~= posed.entity then undraw(playerId) end
	end

	local own = context.playerId
	if mirror[own] ~= nil then pose(native, own, mirror[own], 0, atMs) end
	local players = context.players
	if type(players) ~= 'table' then return end
	for key, entity in pairs(players) do
		local number = tonumber(key)
		local playerId = number ~= nil and math.tointeger(number) or nil
		local s = playerId ~= nil and playerId ~= own and mirror[playerId] or nil
		if s ~= nil and entityOf(playerId) == entity then pose(native, playerId, s, entity, atMs) end
	end
end

-- Decides, once a second rather than every tick, whether this client poses.
local function decide(atMs)
	if atMs < nextLookMs then return end
	nextLookMs = atMs + 1000
	local wanted
	if Opt.PRESENTER == 'always' then
		wanted = true
	elseif Opt.PRESENTER == 'never' then
		wanted = false
	else
		local state = tostring(GetResourceState(M.OFFICIAL) or ''):lower()
		wanted = state ~= 'running' and state ~= 'starting'
	end
	if wanted ~= presenting then
		presenting = wanted
		if wanted then
			Open77.log.info('[animations] posing bodies on this client (PRESENTER ' ..
				Opt.PRESENTER .. ')')
		else
			undrawAll()
			Open77.log.info(('[animations] leaving bodies to %s (PRESENTER %s)')
				:format(M.OFFICIAL, Opt.PRESENTER))
		end
	end
end

-- Forgets every mirrored state, ending each one for listeners.
local function reset()
	undrawAll()
	for playerId in pairs(mirror) do changes[playerId] = false end
	epoch, floor, batch = nil, -1, nil
	mirror, seen, failed, held, deferred = {}, {}, {}, {}, {}
	nextSyncMs, era = 0, era + 1
end

-- Raises up to DRAIN pending change events.
local function drain()
	local raised = 0
	for playerId, s in pairs(changes) do
		changes[playerId] = nil
		local payload = describe(playerId, s)
		TriggerEvent(M.Event.ON_CHANGED, payload)
		if context ~= nil and playerId == context.playerId then
			Presenter.OnOwnChanged(payload)
		end
		raised = raised + 1
		if raised >= DRAIN then break end
	end
end

-- Reads the context, syncs, drains changes and poses bodies. Another
-- generation, bucket or player, or a context that stops being ready, means
-- every mirrored state belongs to the world before.
local function tick()
	local native = api()
	if native == nil then return end
	local atMs = OPX.Now()
	local read, raw = pcall(native._context)
	if not read or type(raw) ~= 'table' then return end
	local current = {
		generation = raw.generation,
		bucket = tonumber(raw.bucket),
		playerId = tonumber(raw.playerId),
		ready = raw.ready == true,
		players = raw.players,
	}
	if context ~= nil and (context.generation ~= current.generation or
		context.bucket ~= current.bucket or context.playerId ~= current.playerId or
		(context.ready and not current.ready)) then
		reset()
	end
	context = current
	if not current.ready or current.playerId == nil then return end

	if atMs >= nextSyncMs then
		nextSyncMs = atMs + SYNC_MS
		TriggerServerEvent(M.Wire.SYNC, wireId())
	end
	if batch ~= nil and atMs - batch.atMs > BATCH_MS and not busy() then batch = nil end

	drain()
	decide(atMs)
	if presenting then present(atMs) end
end

-- This client's own player id, or nil before the world.
local function ownId()
	return context and context.ready and context.playerId or nil
end

--- Answers a player's playback as mirrored, the local player by default.
-- @author dop42
-- @param playerId integer|nil
-- @return table
function Presenter.State(playerId)
	playerId = playerId or ownId()
	if playerId == nil then return { active = false } end
	return describe(playerId, mirror[playerId])
end

--- Whether this client is posing bodies right now.
-- @author dop42
-- @return boolean
function Presenter.Presenting()
	return presenting == true
end

--- Releases the local player's playback over the service's wire.
-- @author dop42
-- @return boolean
function Presenter.ReleaseOwn()
	local own = ownId()
	local s = own and mirror[own] or nil
	if s == nil or nonce == nil then return false end
	held[own] = { playbackId = s.playbackId, untilMs = OPX.Now() + HOLD_MS }
	undraw(own)
	TriggerServerEvent(M.Wire.STOP, wireId(), s.playbackId)
	return true
end

--- Called with the local player's change; replaced by client/main.lua.
-- @author dop42
-- @param _ table
function Presenter.OnOwnChanged(_) end

--- Called when the local player's body could not be posed; replaced likewise.
-- @author dop42
-- @param _ string
-- @param _reason string
function Presenter.OnOwnFailed(_, _reason) end

--- Builds the empty mirror.
-- @author dop42
function Presenter.Init()
	epoch, floor, batch, context = nil, -1, nil, nil
	mirror, seen, posedBy, failed, held, changes = {}, {}, {}, {}, {}, {}
	nonce, serial = nil, 0
	nextSyncMs, nextLookMs, presenting, tickJob = 0, 0, nil, nil
end

--- Wires the service's channels and registers the tick.
-- @author dop42
function Presenter.Start()
	if not Presenter.Available() then
		Open77.log.warn('[animations] presentation natives unavailable; no body is posed here ' ..
			'and the State contract answers everyone as idle')
		return
	end

	-- The host refuses these names from anything but the server, so a
	-- neighbouring resource cannot forge a state; every value is checked anyway.
	RegisterNetEvent(M.Wire.STATE, onState)
	RegisterNetEvent(M.Wire.SNAPSHOT, onSnapshot)
	RegisterNetEvent(M.Wire.RESULT, function(result)
		if nonce == nil or type(result) ~= 'table' or type(result.requestId) ~= 'string' then
			return
		end
		if result.requestId:sub(1, #nonce + 1) ~= nonce .. ':' then return end
		-- `stale_playback` means the playback had already ended, which is what
		-- was asked for.
		if result.ok == false and result.error ~= 'stale_playback' then
			Open77.log.info('[animations] release refused: ' .. tostring(Common.Code(result.error)))
		end
	end)

	local read, generation = pcall(Open77.resource.generation)
	nonce = ('opx:%s:%d'):format(read and tostring(generation) or '0', OPX.Now())

	tickJob = OPX.Scheduler.Every('animations:presenter', TICK_MS, tick)
end

--- Hands every posed body back rather than leaving it frozen with nothing to
--- drive it.
-- @author dop42
function Presenter.Shutdown()
	if tickJob ~= nil then
		OPX.Scheduler.Cancel(tickJob)
		tickJob = nil
	end
	if Presenter.Available() then undrawAll() end
end
