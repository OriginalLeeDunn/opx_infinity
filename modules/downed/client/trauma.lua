--- Client half of the Trauma Team, the medic's side: the page, the pin, the row
--- over a downed body, the key and the bar.
-- @author XEROX710
--
-- THE SERVER DECIDES, THIS HALF DRAWS. Who is paged, which body is within reach
-- and whether a treatment may start or has finished are `server/trauma.lua`'s
-- reads: this half pins the page on the map, shows the row the server named
-- (`NEAR`), sends the key's press, and runs the bar the server started (`RUN`)
-- -- a bar whose clock the server keeps, so a shortened one buys nothing. The
-- downed player's own side (the count of medics paged, the "a medic is working
-- on you" line) is `client/main.lua`'s.

local M = OPX.Modules.Get('downed')

M.TraumaClient = {}
local C = M.TraumaClient
local Event = M.TraumaEvent

local OWNER = 'downed'
local GROUP = 'treat'

-- The pins this client put on its map, by patient: `{ id, deadline }`.
local pins = {}

-- The body the server last said is within reach, `{ patient, name }`, or nil.
local near = nil

-- The row as drawn, and whether the key answered.
local shown, shownLabel = false, nil
local keyRegistered = false
local reportedStrip = false

-- The patient whose treatment bar is up, or nil.
local running = nil

-- The one scheduler job: expired pins come down, the row follows the menus.
local job = nil

local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

--- Whether the local player is down: a downed medic treats nobody.
local function localDown()
	local contract = OPX.Api.Get('downed')
	if contract == nil or type(contract.IsDown) ~= 'function' then return false end
	local read, answer = pcall(contract.IsDown)
	return read and type(answer) == 'table' and answer.ok == true and type(answer.value) == 'table'
		and answer.value.down == true
end

local function keyLabel()
	if not keyRegistered then return nil end
	local cfg = M.TraumaSettings()
	if OPX.Lib ~= nil and OPX.Lib.Input ~= nil and type(OPX.Lib.Input.KeyFor) == 'function' then
		return OPX.Lib.Input.KeyFor(cfg.key.id) or cfg.key.default
	end
	return cfg.key.default
end

--- Brings the strip in line with the server's word. The common pass costs
--- nothing: no body in reach and no row is an early return.
local function syncRow()
	if near == nil and not shown then return end
	local want = near ~= nil and keyRegistered and running == nil and not captured() and not localDown()
	local label = want and locale('medic.row.treat', { name = near.name or '?' }) or nil
	if want == shown and label == shownLabel then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		if want and not reportedStrip then
			reportedStrip = true
			Open77.log.info('[downed] no prompts contract; the treat row is not shown (/opx.treat still works)')
		end
		shown, shownLabel = false, nil
		return
	end
	shown, shownLabel = want, label
	local ran, result
	if want then
		ran, result = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = M.TraumaSettings().key.id },
			label = label,
		} } })
	else
		ran, result = pcall(api.Hide, OWNER, GROUP)
	end
	local failure = nil
	if not ran then
		failure = tostring(result)
	elseif type(result) ~= 'table' or result.ok ~= true then
		failure = type(result) == 'table' and tostring(result.error or 'refused') or 'malformed_answer'
	end
	if failure ~= nil and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[downed] the treat row was refused: ' .. failure)
	end
	if want then
		Open77.log.info(('[downed] %s is down within reach: press %s to treat')
			:format(tostring(near.name), tostring(keyLabel())))
	end
end

--- The key: treat the body whose row is up.
-- @return table `{ ok, code }`
function C.Treat()
	if captured() then return { ok = false, code = 'captured' } end
	if near == nil or not shown then return { ok = false, code = 'no_patient' } end
	TriggerServerEvent(Event.TREAT, { patient = near.patient })
	Open77.log.info(('[downed] treat asked for %s (%s)'):format(tostring(near.patient), tostring(near.name)))
	return { ok = true }
end

--- Takes one pin off the map.
local function unpin(patient)
	local pin = pins[patient]
	pins[patient] = nil
	if pin == nil then return end
	local blips = Open77 and Open77.blips
	if type(blips) == 'table' and type(blips.remove) == 'function' and pin.id ~= nil then
		pcall(blips.remove, pin.id)
	end
end

--- A page: a loud toast and a pin on this medic's map.
local function onPage(payload)
	if type(payload) ~= 'table' then return end
	local patient = tonumber(payload.patient)
	local x, y, z = tonumber(payload.x), tonumber(payload.y), tonumber(payload.z) or 0.0
	if patient == nil or x == nil or y == nil then return end
	local cfg = M.TraumaSettings()
	local name = type(payload.name) == 'string' and payload.name:sub(1, 48) or '?'
	Open77.log.info(('[downed] trauma page: %s is down at %.0f, %.0f'):format(name, x, y))

	OPX.Toast.Show({
		id = 'opx.downed.page.' .. tostring(patient),
		kind = 'error',
		title = locale('medic.page.title'),
		message = locale('medic.page.body', { name = name, x = math.floor(x), y = math.floor(y) }),
		durationMs = cfg.toastMs > 0 and cfg.toastMs or nil,
	})

	unpin(patient)
	local seconds = tonumber(payload.seconds) or 0
	local blips = Open77 and Open77.blips
	if seconds <= 0 or type(blips) ~= 'table' or type(blips.create) ~= 'function' then return end
	local read, id, why = pcall(blips.create, {
		position = { x = x, y = y, z = z },
		sprite = type(payload.sprite) == 'string' and payload.sprite or 'objective',
		title = locale('medic.page.pin', { name = name }),
		description = locale('medic.page.title'),
		active = true,
		visibleThroughWalls = false,
	})
	if not read or type(id) ~= 'string' or id == '' then
		Open77.log.warn(('[downed] the page for %s was not pinned: %s'):format(name, tostring(read and why or id)))
		return
	end
	pins[patient] = { id = id, deadline = OPX.Now() + math.floor(math.min(seconds, 900) * 1000) }
end

--- The bar the server started.
local function onRun(payload)
	if type(payload) ~= 'table' then return end
	local patient = tonumber(payload.patient)
	local durationMs = tonumber(payload.durationMs)
	if patient == nil or durationMs == nil or durationMs <= 0 then return end
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then
		TriggerServerEvent(Event.ABORT, 'no_bar')
		return
	end
	local shownBar = progress.Start(OWNER, {
		label = locale('medic.treat.bar', { name = type(payload.name) == 'string' and payload.name or '?' }),
		durationMs = durationMs,
		cancelable = true,
	})
	if type(shownBar) == 'table' and shownBar.ok ~= true then
		Open77.log.warn(('[downed] the treatment bar was refused: %s'):format(tostring(shownBar.error)))
		TriggerServerEvent(Event.ABORT, 'no_bar')
		return
	end
	running = patient
	syncRow()
end

--- What came of a treatment.
local function onAnswer(payload)
	if type(payload) ~= 'table' then return end
	if running ~= nil then
		running = nil
		if payload.ok ~= true then
			local progress = OPX.Api.Get('progress')
			if progress ~= nil and type(progress.Stop) == 'function' then pcall(progress.Stop, OWNER, nil) end
		end
	end
	local name = type(payload.name) == 'string' and payload.name or '?'
	if payload.ok == true then
		local reward = tonumber(payload.reward) or 0
		if reward > 0 then
			OPX.Toast.Locale('medic.treat.paid', { name = name, amount = reward,
				account = tostring(payload.account or '') }, 'success')
		else
			OPX.Toast.Locale('medic.treat.done', { name = name }, 'success')
		end
		Open77.log.info(('[downed] revived %s%s'):format(name, reward > 0 and (' (+' .. reward .. ')') or ''))
	else
		OPX.Toast.Locale(M.TraumaRefusalKey(payload.code), { name = name }, 'error')
		Open77.log.info(('[downed] treatment refused or stopped: %s'):format(tostring(payload.code)))
	end
	syncRow()
end

--- One pass: expired pins come down, and the row follows the menus.
local function tick()
	local now = OPX.Now()
	for patient, pin in pairs(pins) do
		if now >= pin.deadline then unpin(patient) end
	end
	syncRow()
end

--- Watches the Trauma Team's AV come in, and tells the server whether this game
--- drew it (`server/team.lua`). The bot lab, 2026-10-07: "i hear tramua team but
--- i dont see av" -- its record named an entity template the game does not have,
--- and the spawn this client registered never finished. Three answers:
---   * drawn: `streamed`;
---   * registered here and not drawn `ms` after the create arrived: `stuck`,
---     and the server flies the next record;
---   * the create never reached this game, or the hull went away (swapped or
---     gone): nothing, because there is nothing this game can say about it.
-- @param key string the hull's id, as the server spelled it
-- @param ms number how long a registered hull may take to be drawn
local function watchHull(key, ms)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.get) ~= 'function' then return end
	-- A decimal id is the platform's number; anything else is passed as spelled.
	local id = key:match('^%d+$') and tonumber(key) or key
	local started, since = OPX.Now(), nil
	while true do
		local read, car = pcall(api.get, id)
		local now = OPX.Now()
		if read and type(car) == 'table' then
			if car.streamed == true then
				TriggerServerEvent(Event.TEAM_SEEN, { id = key, state = 'streamed', ms = now - (since or started) })
				return
			end
			since = since or now
			if now - since >= ms then
				Open77.log.warn(('[downed] trauma team: this game registered the AV %s (%s) %.0fs ago and has '
					.. 'not drawn it'):format(key, tostring(car.record), (now - since) / 1000.0))
				TriggerServerEvent(Event.TEAM_SEEN, { id = key, state = 'stuck', ms = now - since })
				return
			end
		elseif since ~= nil then
			return
		elseif now - started >= ms + 30000 then
			return
		end
		Wait(250)
	end
end

--- What this half knows, for a diagnostic or a test.
function C.Status()
	local count = 0
	for _ in pairs(pins) do count = count + 1 end
	return { near = near and near.patient or nil, shown = shown, label = shownLabel,
		running = running, pins = count, key = keyLabel() }
end

--- Forgets everything held. Shared by `Init` and `Stop`.
function C.Reset()
	pins, near, shown, shownLabel, running, job = {}, nil, false, nil, nil, nil
	keyRegistered, reportedStrip = false, false
end

--- Wires the page, the row, the key and the bar.
function C.Start()
	local cfg = M.TraumaSettings()
	if cfg.off then return end

	if cfg.key.default ~= false and type(RegisterKeyMapping) == 'function' then
		local called, ok, answer = pcall(RegisterKeyMapping, cfg.key.id, locale(cfg.key.name),
			cfg.key.default, function()
				if captured() then return end
				local ran, failure = pcall(C.Treat)
				if not ran then
					Open77.log.error(('[downed] key %s: %s'):format(cfg.key.id, tostring(failure)))
				end
			end)
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		if not called or (ok ~= true and effective == nil) then
			Open77.log.warn(('[downed] key mapping %s (%s) not registered: %s')
				:format(cfg.key.id, tostring(cfg.key.default), tostring(called and answer or ok)))
		else
			keyRegistered = true
		end
	end

	RegisterNetEvent(Event.PAGE, onPage)
	RegisterNetEvent(Event.UNPAGE, function(patient)
		local id = tonumber(patient)
		if id == nil then return end
		unpin(id)
		pcall(OPX.Toast.Dismiss, 'opx.downed.page.' .. tostring(id))
	end)
	RegisterNetEvent(Event.NEAR, function(payload)
		local patient = type(payload) == 'table' and tonumber(payload.patient) or nil
		if patient == nil then
			near = nil
		else
			near = { patient = patient,
				name = type(payload.name) == 'string' and payload.name:sub(1, 48) or '?' }
		end
		syncRow()
	end)
	RegisterNetEvent(Event.RUN, onRun)
	RegisterNetEvent(Event.ANSWER, onAnswer)
	-- Whether this game draws the Trauma Team's AV, when the server asks.
	RegisterNetEvent(Event.TEAM_WATCH, function(payload)
		if type(payload) ~= 'table' or payload.id == nil then return end
		local key = tostring(payload.id)
		if #key > 32 then return end
		local ms = math.floor(math.max(2000, math.min(60000, tonumber(payload.ms) or 12000)))
		CreateThread(function()
			local ran, failure = pcall(watchHull, key, ms)
			if not ran then Open77.log.warn('[downed] trauma team: the AV watch failed: ' .. tostring(failure)) end
		end)
	end)

	-- The bar's own outcome. Only `finished` means the treatment happened; every
	-- other ending is it NOT happening and must reach the server as an abort, or
	-- the patient is told a medic is working on them for as long as the pass
	-- takes to notice.
	--
	-- GUARDED: `progress` is a module the operator can turn off or that can fail
	-- to load, and indexing its `Event` unguarded raised here and took the whole
	-- Trauma Team half down with it. Without it there is no bar to finish
	-- (`Start` above refuses to run one), so there is nothing to listen for.
	local progressModule = OPX.Modules.Get('progress')
	local doneEvent = type(progressModule) == 'table' and type(progressModule.Event) == 'table'
		and progressModule.Event.ON_DONE or nil
	if doneEvent ~= nil then
		AddEventHandler(doneEvent, function(outcome)
			if type(outcome) ~= 'table' or outcome.owner ~= OWNER then return end
			if running == nil then return end
			running = nil
			if outcome.finished then
				TriggerServerEvent(Event.DONE)
			else
				TriggerServerEvent(Event.ABORT, tostring(outcome.ending))
			end
			syncRow()
		end)
	else
		Open77.log.warn('[downed] trauma: the progress module is not loaded; treatment bars cannot run')
	end

	job = OPX.Scheduler.Every('downed:trauma', 1000, tick)
end

--- Takes the row, the bar and every pin down.
function C.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	for patient in pairs(pins) do unpin(patient) end
	local api = OPX.Api.Get('prompts')
	if shown and api ~= nil and type(api.Hide) == 'function' then pcall(api.Hide, OWNER, GROUP) end
	if running ~= nil then
		local progress = OPX.Api.Get('progress')
		if progress ~= nil and type(progress.Stop) == 'function' then pcall(progress.Stop, OWNER, nil) end
		TriggerServerEvent(Event.ABORT, 'stopped')
	end
	C.Reset()
end
