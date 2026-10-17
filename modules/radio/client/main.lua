--- Client half: the handset on screen, the talk key, and the route this
--- machine's microphone takes while it is held.
-- @author dop42
--
-- NONE OF IT DECIDES. The handset is drawn from the last STATE the server sent and
-- every press on it is a request the server re-checks; the talk key asks for the right
-- to speak and only routes the microphone into the channels once the server
-- says it granted it (`KEYED`). A crafted client that routes into a channel
-- anyway reaches nobody: the platform drops a frame on a membership that may
-- not speak, and every membership here is listen-only until the server lifts
-- it.
--
-- THE MICROPHONE IS OPENED ONLY WHILE THE KEY IS HELD, and handed back to
-- proximity on release. `modules/calls/client/main.lua` re-asserts `all` during
-- a holocall on its own clock; the two agree, because a radio channel is only
-- speakable while this key is down.

local M = OPX.Modules.Get('radio')
local Model = M.Model

local AIR_TOAST = 'opx.radio.air'
-- How often a granted transmission re-asserts its route, for another resource
-- (the platform's voice key) that re-states the intent under it.
local REASSERT_MS = 250

local state = nil
-- Draws the handset again; defined with the view below, called by the key.
local redrawView
-- Whether the talk key is down, and whether the server granted it.
local held, granted = false, false
local intent = 'all'
local talkKey = nil
local routeJob = nil

-- ── the microphone ──────────────────────────────────────────────────────────

local function transmit(on)
	local api = Open77.voice
	if type(api) ~= 'table' or type(api.setTransmitting) ~= 'function' then return false end
	local read, ok = pcall(api.setTransmitting, on == true, on and intent or 'proximity')
	return read and ok ~= false
end

local function stopRoute()
	if routeJob ~= nil then OPX.Scheduler.Cancel(routeJob) end
	routeJob = nil
end

--- Re-asserts the route once per interval, even after duplicate grants or a
--- release and re-press while the previous transmission was asleep.
local function holdRoute()
	if routeJob ~= nil then return end
	routeJob = OPX.Scheduler.Every('radio.route', REASSERT_MS, function()
		if held and granted then transmit(true) else stopRoute() end
	end)
end

local function onPressed()
	if held then return end
	held, granted = true, false
	TriggerServerEvent(M.Event.TALK, { on = true })
end

local function onReleased()
	if not held then return end
	local wasGranted = granted
	held, granted = false, false
	stopRoute()
	TriggerServerEvent(M.Event.TALK, { on = false })
	if wasGranted then transmit(false) end
	pcall(OPX.Toast.Dismiss, AIR_TOAST)
	if wasGranted then redrawView() end
end

local function onKeyed(payload)
	if type(payload) ~= 'table' then return end
	if payload.on == true then
		-- A grant for a key already let go is handed straight back.
		if not held then
			TriggerServerEvent(M.Event.TALK, { on = false })
			return
		end
		granted = true
		transmit(true)
		holdRoute()
		redrawView()
		local channel = type(payload.channel) == 'string' and OPX.Text.Clean(payload.channel, 16) or ''
		OPX.Toast.Show({ id = AIR_TOAST, kind = 'info', icon = 'talk', durationMs = 1500,
			message = locale('radio.air.on', { channel = channel }) })
		return
	end
	local wasGranted = granted
	granted = false
	stopRoute()
	if wasGranted then transmit(false) end
	pcall(OPX.Toast.Dismiss, AIR_TOAST)
	if wasGranted then redrawView() end
	local code = type(payload.code) == 'string' and payload.code or nil
	if code ~= nil then
		local key = 'radio.air.' .. code
		if OPX.Locale.Exists(key) then OPX.Toast.Locale(key, nil, 'warning') end
	end
end

local function registerKey()
	if talkKey == false or talkKey == nil then return end
	if type(RegisterKeyMapping) ~= 'function' then
		return OPX.Note('radio', 'this client build has no RegisterKeyMapping: the radio cannot be keyed')
	end
	-- THE POSITIONAL FORM WITH A RELEASE CALLBACK IS HOLD MODE (docs
	-- keybindings#press-and-hold): the key-up edge is the release.
	local called, ok, answer = pcall(RegisterKeyMapping, talkKey.id, locale(talkKey.name), talkKey.default,
		onPressed, onReleased)
	if not called or (ok ~= true and type(ok) ~= 'string') then
		OPX.Note('radio', ('the talk key %s was refused: %s'):format(tostring(talkKey.default),
			tostring(called and answer or ok)))
	end
end

-- ── the handset on screen ───────────────────────────────────────────────────
--
-- THE OWNER: "pour le script radio enfois de le faire en menu fait un vrais
-- style de radio mais holograpique qui pop a droite de l'ecran". The menu rows
-- are gone; the page draws a handset -- screen, channel knob, side key -- as a
-- projection on the right edge (`ui/src/modules/radio/RadioHolo.vue`), and
-- every press on it comes back here as the same request the menu sent.
--
-- FOCUS FOLLOWS THE SCREEN, as on the holocall (`modules/calls/client/view.lua`):
-- taken when the handset opens, given back the moment it closes, so a radio
-- left on screen never leaves a player who cannot move.

local SURFACE = 'interactive'
local CHANNEL = 'radio:holo'
local FOCUS = 'radio'
-- Whether the handset is on screen.
local shown = false
-- Where the projection sits: one of `OPX.Anchors.ALL`, settled in Start.
local anchor = 'right'

local function request(verb, channel, on)
	TriggerServerEvent(M.Event.REQUEST, { verb = verb, channel = channel, on = on })
end

--- The rows as the page may draw them: the operator's words, trimmed.
local function rowsOf()
	local rows, out = type(state) == 'table' and state.channels or {}, {}
	for index = 1, math.min(#rows, 32) do
		local row = rows[index]
		if type(row) == 'table' and Model.Key(row.key) then
			out[#out + 1] = {
				key = row.key,
				label = OPX.Text.Clean(tostring(row.label), 64) or row.key,
				short = OPX.Text.Clean(tostring(row.short or row.key), 16) or row.key,
				joined = row.joined == true,
				muted = row.muted == true,
				active = row.active == true,
				auto = row.auto == true,
			}
		end
	end
	return out
end

--- Sends the handset to the page, and takes or gives back focus with it.
local function push()
	local radio = type(state) == 'table' and state or {}
	OPX.UI.Send(SURFACE, CHANNEL, {
		open = shown,
		anchor = anchor,
		power = radio.power == true,
		handset = radio.handset ~= false,
		needsHandset = radio.needsHandset == true,
		talkKey = radio.talkKey ~= false,
		tx = held and granted,
		channels = rowsOf(),
	})
	if shown then
		OPX.UI.AcquireFocus(FOCUS, { keyboard = true, cursor = true })
	else
		OPX.UI.ReleaseFocus(FOCUS)
	end
end

redrawView = function()
	if shown then push() end
end

local function closeView()
	if not shown then return end
	shown = false
	push()
end

--- Opens the handset. ALWAYS ASKED, never drawn from memory: the sweep moves
--- memberships without telling a client whose radio did not change, so the
--- last state may be old. The answer comes back with `open` and lands in
--- `onState`.
-- @author dop42
-- @return boolean
function M.OpenMenu()
	request('ask')
	return true
end

local function onState(payload)
	if type(payload) ~= 'table' then return end
	payload.channels = type(payload.channels) == 'table' and payload.channels or {}
	state = payload
	if payload.open == true then shown = true end
	if shown then push() end
end

-- Every action the page may send, and what it becomes. A verb the server does
-- not know is refused there; `ask` is not the page's to send.
local PAGE_VERBS = { join = true, leave = true, select = true, mute = true, power = true }

local function fromView(action, payload)
	if action == 'ready' then
		-- The page mounted (or remounted): draw what is known, open or not.
		if state ~= nil then push() end
	elseif action == 'close' then
		closeView()
	elseif action == 'request' then
		if not shown or type(payload) ~= 'table' or not PAGE_VERBS[payload.verb] then return end
		local channel = payload.channel
		if channel ~= nil and not Model.Key(channel) then return end
		local on = payload.on
		if on ~= nil and type(on) ~= 'boolean' then return end
		request(payload.verb, channel, on)
	elseif action == 'talk' then
		-- The side key on the handset: the same hold the keyboard key is, and
		-- the server grants it on the same terms.
		if type(payload) ~= 'table' then return end
		if payload.on == true and shown then onPressed() else onReleased() end
	end
end

local function wireView()
	for _, action in ipairs({ 'ready', 'close', 'request', 'talk' }) do
		OPX.UI.On(SURFACE, 'radio:' .. action, function(payload)
			fromView(action, payload)
		end)
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	state, held, granted, shown = nil, false, false, false
end

--- Publishes the client half: the state as last sent, and the handset.
-- @author dop42
function M.Api()
	OPX.Api.Provide('radio', 1, {
		--- The radio as the server last described it, or nil.
		State = function() return state end,
		--- Opens the handset on screen (the name the menu had, kept for callers).
		OpenMenu = M.OpenMenu,
		CloseMenu = function() closeView() return true end,
		--- Whether the talk key is down and granted.
		Talking = function() return held and granted end,
	})
end

--- Listens to the server and registers the talk key, on a thread.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.STATE, onState)
	RegisterNetEvent(M.Event.KEYED, onKeyed)
	wireView()
	-- The two fields this half needs, read by hand: the whole `Model.Build`
	-- walks every channel's gates, which is the server's work and not worth a
	-- client resume.
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	intent = settings.TALK_INTENT == 'channels' and 'channels' or 'all'
	anchor = OPX.Anchors.Resolve(settings.ANCHOR, 'right', 'radio.ANCHOR')
	local key = settings.TALK_KEY
	if key == false then
		talkKey = false
	elseif type(key) == 'table' and type(key.ID) == 'string' and type(key.NAME) == 'string'
		and type(key.DEFAULT) == 'string' then
		talkKey = { id = key.ID, name = key.NAME, default = key.DEFAULT }
	else
		talkKey = { id = 'opx.radio.talk', name = 'radio.key.talk', default = 'CAPSLOCK' }
	end
	CreateThread(function()
		Wait(0)
		registerKey()
	end)
end

--- Hands the screen, the key and the microphone back.
-- @author dop42
function M.Stop()
	stopRoute()
	closeView()
	if held and granted then transmit(false) end
	held, granted = false, false
	pcall(OPX.Toast.Dismiss, AIR_TOAST)
	state = nil
end
