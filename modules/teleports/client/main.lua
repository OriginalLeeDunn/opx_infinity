--- Client half: the markers, the strip row, the key and the answer.
-- @author dop42
--
-- EVERYTHING DRAWN HERE IS A HINT. The marker says a shortcut is there, its
-- colour says whether the server thinks this character may take it, and the row
-- says which key to press. None of the three is a gate: the server re-derives
-- the destination, the job and the distance when the key is pressed, and a
-- client that flipped every `allowed` in its own copy would have recoloured some
-- markers and changed nothing else. See the head of `server/main.lua`.
--
-- THE LIST COMES FROM THE SERVER AND NEVER FROM `config/teleports.lua`
-- DIRECTLY, even though this half can read that file. The server filters it to
-- this player's own routing bucket and marks each entrance allowed or refused
-- against a character snapshot only it can read -- so a client reading the
-- config would draw markers in buckets it is not in and would have to invent its
-- own answer to the job gate, which is the second copy of a rule this whole
-- module was written to avoid.
--
-- Markers are engine primitives, so nothing is redrawn per frame: one is created
-- when an entrance comes into range and removed when it leaves. A marker whose
-- LOCK STATE changed is removed and remade, because the style is fixed at
-- creation -- the set's `variant` is the lock state, and a marker drawn for the
-- other one is remade.
--
-- The set is `OPX.Spots.Markers` (`lib/client/spots.lua`), which every spot
-- module shares: creation is guarded -- `Open77.markers` may not be installed at
-- all -- and capped per pass, and a raise cannot take the scan down.

local M = OPX.Modules.Get('teleports')
local Access = M.Access

M.Runtime = {}
local Runtime = M.Runtime

-- What the prompts contract records as this module's own.
local OWNER = 'teleports'
local GROUP = 'teleport'

-- The entrances as the server last sent them, by `key|leg`, and the markers
-- drawn for them. The lock state is the set's `variant`: a marker's style is
-- fixed when it is created, so one drawn red for an entrance the player may now
-- take is remade.
local entrances = {}
local markers = OPX.Spots.Markers.New({
	tag = 'teleports',
	look = function(entrance) return Access.Marker(not entrance.allowed) end,
	maxDistance = function() return Access.MaxDistance() end,
	variant = function(entrance) return entrance.allowed end,
})

-- The entrance the player is standing on, whether its row is up, and whether a
-- trip this client asked for is still unanswered.
local nearest, shown, asking = nil, false, false
-- The squared distance to `nearest` the last scan measured, for the key's claim.
local nearestSq = nil

-- When `asking` was set, and how long it may stay set without an answer: the
-- server's own `FLIGHT_MAX_MS`. A latch only an answer could open was a latch a
-- lost event or a restarted server module shut for the rest of the session.
local askedAtMs = 0
local ASK_LATCH_MS = 45000

-- Whether the key mapping answered.
local keyRegistered = false

-- Whether each failure has already been logged. A marker that cannot be drawn
-- and a row that cannot be posted are different problems, and whoever reads the
-- log wants to know which one they have.
local reportedStrip = false

-- Scheduler handles, so Stop can cancel them.
local scanJob, askJob = nil, nil

-- Every refusal code the server can send, mapped to the sentence a player reads.
-- A code with no entry falls through to the generic line, and the code goes to
-- the log: an unmapped refusal is a bug, but the player is not the one who can
-- fix it, and the line used to print the code itself at them.
local SENTENCES = {
	rate_limited = 'error.tooFast',
	in_flight = 'teleports.inFlight',
	no_such_teleport = 'teleports.noSuchTeleport',
	no_character = 'teleports.locked',
	job_stale = 'teleports.locked',
	job_required = 'teleports.locked',
	grade_too_low = 'teleports.locked',
	off_duty = 'teleports.locked',
	downed = 'teleports.downed',
	no_position = 'teleports.noPosition',
	wrong_bucket = 'teleports.tooFar',
	too_far = 'teleports.tooFar',
	unavailable = 'teleports.unavailable',
	-- The platform's own rejections, in its own spelling.
	player_in_vehicle = 'teleports.inVehicle',
	dismount_failed = 'teleports.inVehicle',
	player_not_alive = 'teleports.notAlive',
	player_not_ready = 'teleports.notReady',
	invalid_position = 'teleports.badDestination',
	settle_timeout = 'teleports.neverArrived',
	no_promise = 'teleports.unavailable',
	-- The server's own two catch-alls (`refused` for a gate it will not explain,
	-- `failed` for a move that did not happen), which used to reach the
	-- generic line as "That trip was refused: failed".
	refused = 'teleports.locked',
	failed = 'teleports.unavailable',
}

-- Reads the key declaration, with the shipped value as the fallback so a config
-- that lost its KEY block still names a key.
local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or { ID = 'opx.teleports.use', NAME = 'teleports.key.use', DEFAULT = 'E' }
end

-- The player's own position, or nil before there is a world to read.
-- `Open77.character.position()` answers THREE NUMBERS and not a table.
local function playerAt()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, x, y, z = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
		return nil
	end
	if x ~= x or y ~= y or z ~= z then return nil end
	return { x = x, y = y, z = z }
end

-- Whether another surface holds the keyboard; see `lib/client/spots.lua`.
local captured = OPX.Spots.Captured

--- Whether a timed action is running on this client.
-- @author dop42
--
-- A CRAFT IN FLIGHT STOPS THE KEY, AND THIS IS A COURTESY RATHER THAN A GATE --
-- said plainly because the distinction is the whole point of this module. The
-- SERVER cannot see a progress bar: it is a CEF surface on one machine, with no
-- replicated state behind it, so there is nothing for the authority to check and
-- a determined client simply would not run this function. What it buys is the
-- honest case: a player who starts a two-minute craft at a bench and then walks
-- onto a pad does not silently finish it two kilometres away, and the bar does
-- not keep counting over a fade. A craft that must survive a player leaving is
-- `modules/progress` and its owner's problem to bind to a place, not this
-- module's to police.
--
-- The same is true of an open MENU, which is covered by `captured()` above: a
-- surface holding the keyboard never sees the press at all, so typing `E` in
-- chat while standing on a pad does not send anybody anywhere.
-- @return boolean
local function busy()
	local api = OPX.Api.Get('progress')
	if api == nil or type(api.State) ~= 'function' then return false end
	local read, answer = pcall(api.State)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return false end
	return type(answer.value) == 'table' and answer.value.open == true
end

-- ── the strip ───────────────────────────────────────────────────────────────

-- Names the key the row is bound to, or nil when it is off or was refused -- a
-- row with no key to name says nothing, which is why `RegisterKeyMapping`'s
-- answer is kept rather than assumed.
local function keyLabel()
	return OPX.Spots.Key.Label(keyRegistered, keySettings())
end

-- Brings the strip in line with where the player is standing.
--
-- THE ROW IS POSTED FOR A LOCKED ENTRANCE TOO, and that is on purpose: a player
-- who walks onto a red marker and presses the key is told, in the operator's own
-- words, whose rooftop it is. A row that vanished would leave them pressing a
-- key that does nothing and guessing why -- which is how "the teleport is
-- broken" gets reported about a teleport that is working exactly as configured.
local function syncPrompt()
	-- The claim on the shared key is filed every scan, row or no row, and the
	-- row is drawn only when no other feature on that key would take the press.
	local wins = OPX.Spots.Key.Shows(keySettings().ID)
	local want = nearest ~= nil and keyLabel() ~= nil and not captured() and wins
	local label = nearest ~= nil and nearest.label or nil
	local locked = nearest ~= nil and not nearest.allowed
	local wanted = want and (label .. (locked and '\1locked' or '')) or nil
	if wanted == shown then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the key still works, and this is said once.
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[teleports] no prompts contract; the strip row is not shown')
		end
		shown = nil
		return
	end

	shown = wanted
	local ran, answer
	if want then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			-- Short on purpose: the strip never wraps a line.
			label = locale(locked and 'teleports.prompt.locked' or 'teleports.prompt',
				{ place = label }),
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	local failure = nil
	if not ran then
		failure = tostring(answer)
	elseif type(answer) ~= 'table' or answer.ok ~= true then
		failure = type(answer) == 'table' and tostring(answer.error or 'refused')
			or 'malformed_answer'
	end
	if failure ~= nil and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[teleports] the strip row was refused: ' .. failure)
	end
end

-- ── the verdicts ────────────────────────────────────────────────────────────

-- Raises the local decision event with a verdict.
local function publish(payload)
	TriggerEvent(M.Event.ON_DECISION, payload)
end

-- Shows one message as a replaced toast, or as a log line when no toast can be
-- raised. Every verdict shares the one id, so the last thing said replaces the
-- one before it rather than stacking.
local function say(kind, message)
	local raised = OPX.Toast.Show({
		id = 'opx.teleports.answer',
		kind = kind,
		title = locale('teleports.title'),
		message = message,
		durationMs = 5000,
	})
	if raised == nil then Open77.log.info('[teleports] ' .. tostring(message)) end
end

-- Turns one server refusal into a sentence. `reason` is the operator's own words
-- off `REASON` in config and is never translated: it is what makes a locked
-- teleport say WHY rather than say no.
local function refusalText(code, reason)
	if type(reason) == 'string' and reason ~= '' then
		return locale('teleports.lockedReason', { reason = reason })
	end
	local key = SENTENCES[code]
	if key ~= nil then return locale(key) end
	Open77.log.warn(('[teleports] a refusal with no sentence: %s'):format(tostring(code)))
	return locale('teleports.refused')
end

-- ── the door ────────────────────────────────────────────────────────────────

--- Asks the server to take the teleport the player is standing on.
-- Every refusal here is local and decides nothing: the server decides again, and
-- its answer is what a player is actually told.
-- @author dop42
-- @param origin string|nil the key, or a caller's name
-- @return table
function Runtime.Use(origin)
	local result = { source = origin or 'key' }
	if captured() then
		result.ok, result.error = false, 'error.noPermission'
	elseif nearest == nil then
		result.ok, result.error = false, 'teleports.noSuchTeleport'
		-- NOT A WORD, WHEN THE KEY IS WHAT ASKED. `E` is a contextual key and four
		-- modules in this resource declare it -- clothing, garages, dealership and
		-- this one -- so every press anywhere reaches all four and three of them
		-- find nothing. The other three already return in silence; this one fell
		-- through to the shared sentence below and shouted "there is no teleport
		-- here" across the whole city, including at a player who pressed the key
		-- for something else entirely. That is how it was reported: pressing the
		-- key for the phone and being told about teleports.
		--
		-- A CALLER THAT NAMED ITSELF STILL GETS THE SENTENCE. A menu row or a
		-- command asked this module in particular, and there "nothing happened" is
		-- the answer that leaves a player guessing. `publish` runs either way, so
		-- the module's own listeners and the tests see the refusal regardless.
		if (origin or 'key') == 'key' then
			publish(result)
			return result
		end
	elseif busy() then
		-- AFTER THE SPOT, NOT BEFORE IT. Asked first, this answered "you are
		-- busy" to every E pressed during any progress bar anywhere in the city
		-- -- the silence above never got its turn. Busy is only news to a player
		-- standing at a teleport.
		result.ok, result.error = false, 'teleports.busy'
	elseif asking and OPX.Now() - askedAtMs < ASK_LATCH_MS then
		-- The client's own half of the one-trip-at-a-time rule. The server keeps
		-- the real lock; this only stops a key held down from filling the request
		-- window with duplicates of a trip already under way.
		result.ok, result.error = false, 'teleports.inFlight'
	else
		result.key, result.leg = nearest.key, nearest.leg
		local sent, reason = TriggerServerEvent(M.Event.USE, nearest.key, nearest.leg)
		if sent == false then
			result.ok, result.error, result.reason = false, 'teleports.refused', tostring(reason)
		else
			asking = true
			askedAtMs = OPX.Now()
			result.ok = true
			publish(result)
			return result
		end
	end

	publish(result)
	say(OPX.Result.Kind(result.error, 'error'), locale(result.error, { reason = result.reason or '' }))
	return result
end

--- The entrance the player is standing on, or nil.
-- @author dop42
-- @return table|nil
function Runtime.Nearest()
	return nearest
end

--- Every entrance this client was told about.
-- @author dop42
-- @return table
function Runtime.Entrances()
	return entrances
end

--- What this client knows, for a diagnostic or a test.
-- @author dop42
-- @return table
function Runtime.Report()
	return {
		entrances = OPX.Table.Count(entrances),
		markers = markers.Count(),
		nearest = nearest and nearest.key or nil,
		leg = nearest and nearest.leg or nil,
		allowed = nearest and nearest.allowed or nil,
		shown = shown ~= nil and shown ~= false,
		asking = asking,
		key = keyLabel(),
	}
end

-- ── the scan ────────────────────────────────────────────────────────────────

-- One pass: where the player is, which entrance they are on, and what is drawn.
-- A pass with no entrances at all still reconciles, so a list that was cleared
-- takes its markers down with it.
local function scan()
	local at = playerAt()
	if at == nil then
		nearest = nil
		syncPrompt()
		markers.Reconcile(entrances, nil, nil)
		return
	end
	nearest, nearestSq = Access.Nearest(entrances, at.x, at.y, at.z)
	syncPrompt()
	markers.Reconcile(entrances, at.x, at.y)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears everything this half holds. Never yields.
-- @author dop42
function Runtime.Init()
	entrances = {}
	markers.Reset()
	nearest, shown, asking, keyRegistered = nil, nil, false, false
	reportedStrip = false
	scanJob, askJob = nil, nil
end

--- Declares the key and wires the two server events.
-- @author dop42
function Runtime.Start()
	-- The key, and the silent press: see `OPX.Spots.Key.Register`.
	keyRegistered = OPX.Spots.Key.Register({
		tag = 'teleports',
		declared = keySettings(),
		onPress = Runtime.Use,
		wants = function(x, y)
			if nearest == nil then return nil end
			return OPX.Spots.Key.Rank('SPOT'), OPX.Spots.Key.Reach(nearest, x, y, nearestSq)
		end,
	})

	-- The strip redraws a rebound key itself; this only re-reads whether the row
	-- should be up at all.
	AddEventHandler(OPX.Host.KEYBINDS_CHANGED, function()
		if shown ~= nil and keyLabel() == nil then shown = nil end
		syncPrompt()
	end)

	RegisterNetEvent(M.Event.SYNC, function(payload)
		local listed = type(payload) == 'table' and payload.entrances or nil
		if type(listed) ~= 'table' then return end
		local accepted = {}
		for index = 1, #listed do
			local entrance, why = Access.FromWire(listed[index])
			if entrance == nil then
				Open77.log.warn('[teleports] an entrance was refused: ' .. tostring(why))
			else
				-- Keyed by both, because a two-way teleport has two entrances under
				-- one key and a table keyed by the key alone would silently keep one.
				accepted[entrance.key .. '\1' .. entrance.leg] = entrance
			end
		end
		entrances = accepted
		-- A full pass, not just the markers: a list that arrives while the player
		-- is standing on an entrance must put its row up now rather than wait.
		scan()
	end)

	RegisterNetEvent(M.Event.ANSWER, function(key, leg, ok, code, reason)
		asking = false
		local verdict = { source = 'server', key = key, leg = leg, ok = ok == true,
			error = ok ~= true and code or nil }
		publish(verdict)
		if ok == true then
			-- `reason` carries the destination's label on a success, which is the
			-- one thing worth saying: the fade is over and the player is somewhere
			-- else, so the message names where.
			say('success', locale('teleports.arrived',
				{ place = type(reason) == 'string' and reason or '' }))
		else
			say(OPX.Result.Kind(code, 'error'), refusalText(code, reason))
		end
		-- A refusal that was about the GATE means the client's copy of `allowed`
		-- disagreed with the server's, so re-ask rather than wait out the poll.
		if ok ~= true and (code == 'job_required' or code == 'grade_too_low' or
			code == 'off_duty' or code == 'job_stale' or code == 'no_character') then
			pcall(TriggerServerEvent, M.Event.ASK)
		end
	end)

	-- Asked now so the first scan has a list, then on the poll so a change of
	-- routing bucket, of duty or of grade is picked up without a rejoin.
	local function ask()
		local sent, reason = TriggerServerEvent(M.Event.ASK)
		if sent == false then
			Open77.log.warn('[teleports] the teleport list could not be asked for: ' ..
				tostring(reason))
		end
	end
	ask()
	askJob = OPX.Scheduler.Every('teleports:ask', Access.POLL_MS > 0 and Access.POLL_MS or 15000,
		ask)

	-- A SCAN_MS the config got wrong reads as zero, which the scheduler would
	-- take as every pass. That is a boot error and the scan does not start,
	-- rather than running once a frame and eating the instruction budget.
	if Access.SCAN_MS <= 0 then
		Open77.log.error('[teleports] SCAN_MS is not a whole number of milliseconds above ' ..
			'zero; no marker will be drawn')
		return
	end
	scanJob = OPX.Scheduler.Every('teleports:scan', Access.SCAN_MS, scan)
	-- One pass now, so an entrance already in range does not wait a scan.
	scan()
end

--- Cancels the two jobs, takes the markers down and hands the strip back.
-- @author dop42
function Runtime.Shutdown()
	if scanJob ~= nil then
		OPX.Scheduler.Cancel(scanJob)
		scanJob = nil
	end
	if askJob ~= nil then
		OPX.Scheduler.Cancel(askJob)
		askJob = nil
	end
	markers.Clear()
	local api = OPX.Api.Get('prompts')
	if shown ~= nil and shown ~= false and api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	Runtime.Init()
end
