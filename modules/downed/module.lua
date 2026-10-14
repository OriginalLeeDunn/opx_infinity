--- Death and revive: who is down, and the two ways back up.
-- @author dop42
--
-- The server decides who is down. A player is down from the moment their life
-- phase is `dead`; a placement -- a kill and a respawn in one tick, the way a
-- character is moved -- goes straight to `respawnpending` and never opens the
-- screen. Every player's life state is read again each second, so a death that
-- happened while this module was stopped is caught, and a revive done by
-- anything at all closes it.
--
-- Nothing else in the runtime respawns a dead player: the platform leaves a body
-- dead until something revives or respawns it.
--
-- A player who is down gets one full-screen view with two choices -- wait for
-- help, which broadcasts a distress signal, or give up, which unlocks after a
-- delay and wakes them at the nearest medical center. Every rule behind give up
-- is checked on the server and never on the view.
--
-- The view itself is not here. The client half owns the state machine and hands
-- it to whatever draws it, over the seam marked in `client/main.lua`.

local M = OPX.Modules.Declare{
	id = 'downed',
	side = 'both',
	fatal = false,
	-- Every stored row is keyed on the citizen id, and only the character module
	-- knows which character a player has loaded.
	requires = { 'character' },
}

-- ── the Trauma Team ─────────────────────────────────────────────────────────
--
-- A distress signal pages the on-duty medics, and a medic standing over the
-- body treats it: `server/trauma.lua` decides every step, `client/trauma.lua`
-- draws the page, the row and the bar. See `TRAUMA` in `config/downed.lua`.

local NET = OPX.Channel.NET

M.TraumaEvent = {
	-- Server to a medic: somebody is down and asked for help.
	-- `{ patient, name, x, y, z, seconds, sprite }`.
	PAGE = OPX.Event(NET, 'downed', 'page'),
	-- Server to a medic: that page is over (the patient is up, or gone).
	UNPAGE = OPX.Event(NET, 'downed', 'unpage'),
	-- Server to a medic: the downed body within reach now, `{ patient, name }`,
	-- or `{}` when there is none. Sent only when it changes.
	NEAR = OPX.Event(NET, 'downed', 'near'),
	-- Medic to server: treat the body the row named, `{ patient }`.
	TREAT = OPX.Event(NET, 'downed', 'treat'),
	-- Server to a medic: the treatment is running, `{ patient, name, durationMs }`.
	RUN = OPX.Event(NET, 'downed', 'treatrun'),
	-- Medic to server: the bar ran out.
	DONE = OPX.Event(NET, 'downed', 'treatdone'),
	-- Medic to server: the bar was cut short, with the reason.
	ABORT = OPX.Event(NET, 'downed', 'treatabort'),
	-- Server to a medic: what came of it, `{ ok, code, name, reward }`.
	ANSWER = OPX.Event(NET, 'downed', 'treatanswer'),
	-- Server to a downed player: one line for their screen, `{ key, args }`.
	NOTICE = OPX.Event(NET, 'downed', 'notice'),
	-- Server to a client near where the Trauma Team's AV comes down: say
	-- whether this game draws it, `{ id, record, ms }` (`server/team.lua`).
	TEAM_WATCH = OPX.Event(NET, 'downed', 'teamwatch'),
	-- Client to server: what came of it, `{ id, state = 'streamed'|'stuck', ms }`.
	TEAM_SEEN = OPX.Event(NET, 'downed', 'teamseen'),
}

-- Every refusal a medic can be told, by the code `server/trauma.lua` returns. A
-- code outside this set reads as the generic sentence, never as a raw key.
M.TRAUMA_REFUSALS = {
	off = true, no_patient = true, self = true, not_medic = true, down = true, busy = true,
	cooldown = true, not_down = true, taken = true, no_position = true, too_far = true,
	too_soon = true, nothing_running = true, revive_refused = true, patient_up = true,
	medic_gone = true, cancelled = true, interrupted = true, stopped = true, no_bar = true,
}

--- The catalogue key for a treatment refusal code.
-- @param code any
-- @return string
function M.TraumaRefusalKey(code)
	if M.TRAUMA_REFUSALS[tostring(code)] then return 'medic.treat.refused.' .. tostring(code) end
	return 'medic.treat.refused.failed'
end

--- A number from config, finite and inside a band, or the fallback.
local function number(value, low, high, fallback)
	local read = tonumber(value)
	if read == nil or read ~= read or read < low or read > high then return fallback end
	return read
end

--- The Trauma Team settings, each inside a band. A missing or malformed block
--- is the defaults; `TRAUMA = false` or `enabled = false` is `off`.
-- @return table
function M.TraumaSettings()
	local declared = nil
	if type(M.Settings) == 'table' then declared = M.Settings.TRAUMA end
	local block = type(declared) == 'table' and declared or {}
	local page = type(block.PAGE) == 'table' and block.PAGE or {}
	local treat = type(block.TREAT) == 'table' and block.TREAT or {}
	local reward = type(block.REWARD) == 'table' and block.REWARD or {}
	local jobs, listed = {}, false
	for _, name in ipairs(type(block.JOBS) == 'table' and block.JOBS or {}) do
		if type(name) == 'string' and name ~= '' then
			jobs[name] = true
			listed = true
		end
	end
	if not listed and type(block.JOBS) ~= 'table' then jobs.trauma = true end
	local key = type(block.KEY) == 'table' and block.KEY or {}
	return {
		off = declared == false or block.enabled == false,
		jobs = jobs,
		key = {
			id = type(key.ID) == 'string' and key.ID ~= '' and key.ID or 'opx.downed.treat',
			name = type(key.NAME) == 'string' and key.NAME ~= '' and key.NAME or 'medic.key.treat',
			default = key.DEFAULT == false and false
				or (type(key.DEFAULT) == 'string' and key.DEFAULT ~= '' and key.DEFAULT or 'E'),
		},
		round = number(page.ROUND_METRES, 0.0, 100.0, 5.0),
		pinSeconds = math.floor(number(page.PIN_SECONDS, 0, 900, 300)),
		sprite = type(page.PIN_SPRITE) == 'string' and page.PIN_SPRITE ~= '' and page.PIN_SPRITE or 'objective',
		toastMs = math.floor(number(page.TOAST_MS, 0, 60000, 12000)),
		reach = number(treat.REACH_METRES, 1.0, 15.0, 4.0),
		treatMs = math.floor(number(treat.SECONDS, 1, 60, 6) * 1000),
		cooldownMs = math.floor(number(treat.COOLDOWN_MS, 0, 600000, 3000)),
		amount = math.floor(number(reward.AMOUNT, 0, 1000000, 150)),
		account = type(reward.ACCOUNT) == 'string' and reward.ACCOUNT ~= '' and reward.ACCOUNT or 'BANK',
		perPatientMs = math.floor(number(reward.PER_PATIENT_MS, 0, 86400000, 600000)),
	}
end

--- A `Character.*` or `Vehicle.*` record from config, or the fallback.
local function record(value, prefix, fallback)
	if type(value) == 'string' and value:sub(1, #prefix) == prefix and #value > #prefix
		and not value:find('%s') then
		return value
	end
	return fallback
end

--- The Trauma Team's own AV (`TRAUMA.TEAM` in `config/downed.lua`), each number
--- inside a band. A missing or malformed block is the defaults. The team is off
--- when the Trauma Team is, or when `TEAM = false` or `enabled = false`.
-- @return table
function M.TeamSettings()
	local declared = nil
	if type(M.Settings) == 'table' then declared = M.Settings.TRAUMA end
	local trauma = type(declared) == 'table' and declared or {}
	local raw = trauma.TEAM
	local block = type(raw) == 'table' and raw or {}
	local av = type(block.AV) == 'table' and block.AV or {}
	local guards = {}
	for _, name in ipairs(type(block.GUARDS) == 'table' and block.GUARDS or {}) do
		local guard = record(name, 'Character.', nil)
		if guard ~= nil and #guards < 3 then guards[#guards + 1] = guard end
	end
	if type(block.GUARDS) ~= 'table' then guards = { 'Character.q001_tt_soldier' } end
	-- The airframe, in the order it is tried (`AV.RECORDS`). A lone `AV.RECORD`
	-- (the first shape of this block) is a list of one.
	local records = {}
	if type(av.RECORDS) == 'table' then
		for _, name in ipairs(av.RECORDS) do
			local valid = record(name, 'Vehicle.', nil)
			if valid ~= nil and #records < 8 then records[#records + 1] = valid end
		end
	end
	if #records == 0 and av.RECORD ~= nil then
		local valid = record(av.RECORD, 'Vehicle.', nil)
		if valid ~= nil then records[1] = valid end
	end
	if #records == 0 then
		records = { 'Vehicle.q001_trauma_av', 'Vehicle.sq021_av_trauma', 'Vehicle.mws_pac_06_trauma_av' }
	end
	local headStart = block.MEDIC_HEAD_START_SECONDS
	return {
		off = declared == false or trauma.enabled == false or raw == false or block.enabled == false,
		delayMs = math.floor(number(block.DELAY_SECONDS, 0, 300, 8) * 1000),
		-- `false`: a patient an on-duty medic was paged for is never flown to.
		headStartMs = headStart == false and false
			or math.floor(number(headStart, 0, 1800, 45) * 1000),
		sceneMetres = number(block.SCENE_METRES, 5.0, 500.0, 60.0),
		maxRuns = math.floor(number(block.MAX_RUNS, 1, 8, 2)),
		-- The first of `records`, for the lines that name one.
		record = records[1],
		records = records,
		-- How long a client near the landing spot that has the hull registered
		-- waits for its game to draw it, and how near "near" is.
		watchMs = math.floor(number(av.WATCH_SECONDS, 3, 60, 12) * 1000),
		watchMetres = number(av.WATCH_METRES, 50.0, 2000.0, 400.0),
		approachMetres = number(av.APPROACH_METRES, 50.0, 2000.0, 260.0),
		approachAltitude = number(av.APPROACH_ALTITUDE, 10.0, 500.0, 80.0),
		hoverAltitude = number(av.HOVER_ALTITUDE, 5.0, 200.0, 22.0),
		landAltitude = number(av.LAND_ALTITUDE, 0.0, 20.0, 1.5),
		landOffset = number(av.LAND_OFFSET_METRES, 3.0, 60.0, 10.0),
		cruiseMs = math.floor(number(av.CRUISE_SECONDS, 1, 60, 6) * 1000),
		descentMs = math.floor(number(av.DESCENT_SECONDS, 1, 60, 4) * 1000),
		climbMs = math.floor(number(av.CLIMB_SECONDS, 1, 60, 4) * 1000),
		exitMs = math.floor(number(av.EXIT_SECONDS, 1, 60, 6) * 1000),
		exitMetres = number(av.EXIT_METRES, 50.0, 2000.0, 320.0),
		tickMs = math.floor(number(av.TICK_MS, 50, 1000, 100)),
		engineOnGround = av.ENGINE_ON_GROUND == true,
		holdMs = math.floor(number(block.HOLD_SECONDS, 10, 600, 90) * 1000),
		medic = record(block.MEDIC, 'Character.', 'Character.q001_tt_medic'),
		guards = guards,
		runSpeed = number(block.RUN_SPEED, 1.0, 10.0, 4.5),
		treatMs = math.floor(number(block.TREAT_SECONDS, 1, 60, 6) * 1000),
		boardMs = math.floor(number(block.BOARD_SECONDS, 0, 30, 3) * 1000),
	}
end
