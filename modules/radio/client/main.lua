--- Client half: the radio menu, the talk key, and the route this machine's
--- microphone takes while it is held.
-- @author dop42
--
-- NONE OF IT DECIDES. The menu is drawn from the last STATE the server sent and
-- every row is a request the server re-checks; the talk key asks for the right
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

local OWNER = 'radio'
local MENU_ID = 'radio.menu'
local AIR_TOAST = 'opx.radio.air'
-- How often a granted transmission re-asserts its route, for another resource
-- (the platform's voice key) that re-states the intent under it.
local REASSERT_MS = 250

local state = nil
local menuHandle = nil
-- Whether the talk key is down, and whether the server granted it.
local held, granted = false, false
local intent = 'all'
local talkKey = nil

-- ── the microphone ──────────────────────────────────────────────────────────

local function transmit(on)
	local api = Open77.voice
	if type(api) ~= 'table' or type(api.setTransmitting) ~= 'function' then return false end
	local read, ok = pcall(api.setTransmitting, on == true, on and intent or 'proximity')
	return read and ok ~= false
end

--- Re-asserts the route while the key is held and granted.
local function holdRoute()
	CreateThread(function()
		while held and granted do
			Wait(REASSERT_MS)
			if held and granted then transmit(true) end
		end
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
	TriggerServerEvent(M.Event.TALK, { on = false })
	if wasGranted then transmit(false) end
	pcall(OPX.Toast.Dismiss, AIR_TOAST)
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
		local channel = type(payload.channel) == 'string' and OPX.Text.Clean(payload.channel, 16) or ''
		OPX.Toast.Show({ id = AIR_TOAST, kind = 'info', icon = 'talk', durationMs = 1500,
			message = locale('radio.air.on', { channel = channel }) })
		return
	end
	local wasGranted = granted
	granted = false
	if wasGranted then transmit(false) end
	pcall(OPX.Toast.Dismiss, AIR_TOAST)
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

-- ── the menu ────────────────────────────────────────────────────────────────

local function closeMenu()
	local menu = OPX.Api.Get('menu')
	if menuHandle ~= nil and menu ~= nil and type(menu.Close) == 'function' then
		pcall(menu.Close, menuHandle, 'caller')
	end
	menuHandle = nil
end

local function request(verb, channel, on)
	TriggerServerEvent(M.Event.REQUEST, { verb = verb, channel = channel, on = on })
end

local function statusOf(row)
	if not row.joined then return locale('radio.status.off') end
	if row.active then return locale('radio.status.active') end
	if row.muted then return locale('radio.status.muted') end
	return locale('radio.status.listening')
end

--- The menu spec for the last state the server sent.
-- @author dop42
-- @return table
function M.Spec()
	local items = {
		{ id = 'power', label = locale('radio.menu.power'), icon = 'bolt', toggle = state.power == true,
			onLabel = locale('radio.menu.on'), offLabel = locale('radio.menu.off'), data = { verb = 'power' } },
	}
	if state.needsHandset and not state.handset then
		items[#items + 1] = { id = 'handset', label = locale('radio.menu.noHandset'), icon = 'warning', disabled = true }
	end
	items[#items + 1] = { id = 'sep', separator = true, label = locale('radio.menu.channels') }
	local rows = type(state.channels) == 'table' and state.channels or {}
	for index = 1, math.min(#rows, 32) do
		local row = rows[index]
		if type(row) == 'table' and Model.Key(row.key) then
			local label = OPX.Text.Clean(tostring(row.label), 64) or row.key
			local sub = {
				row.joined
					and { id = 'leave', label = locale('radio.menu.leave'), icon = 'minus',
						data = { verb = 'leave', channel = row.key } }
					or { id = 'join', label = locale('radio.menu.join'), icon = 'plus',
						data = { verb = 'join', channel = row.key }, disabled = state.power ~= true },
				{ id = 'select', label = locale('radio.menu.select'), icon = 'talk',
					data = { verb = 'select', channel = row.key }, disabled = not row.joined or row.active == true },
				{ id = 'mute', label = locale('radio.menu.mute'), icon = 'hidden', toggle = row.muted == true,
					onLabel = locale('radio.menu.on'), offLabel = locale('radio.menu.off'),
					data = { verb = 'mute', channel = row.key }, disabled = not row.joined },
			}
			items[#items + 1] = { id = ('c%d'):format(index), label = label, icon = row.active and 'talk' or 'list',
				value = statusOf(row), title = label, items = sub }
		end
	end
	if #rows == 0 then
		items[#items + 1] = { id = 'none', label = locale('radio.menu.none'), icon = 'ban', disabled = true }
	end
	items[#items + 1] = { id = 'close', label = locale('radio.menu.close'), icon = 'back', close = true }
	return {
		owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor',
		title = locale('radio.title'), items = items,
		on = function(payload)
			if type(payload) ~= 'table' then return end
			if payload.action == 'close' then
				menuHandle = nil
				return
			end
			local data = type(payload.data) == 'table' and payload.data or nil
			if data == nil or type(data.verb) ~= 'string' then return end
			if payload.action == 'change' and (data.verb == 'power' or data.verb == 'mute') then
				request(data.verb, data.channel, payload.value == true)
			elseif payload.action == 'select' and (data.verb == 'join' or data.verb == 'leave'
				or data.verb == 'select') then
				request(data.verb, data.channel)
			end
		end,
	}
end

--- Opens (or redraws) the radio menu from the last state.
-- @author dop42
-- @return boolean
function M.OpenMenu()
	-- ALWAYS ASKED, never drawn from memory: the sweep moves memberships without
	-- telling a client whose radio did not change, so the last state may be old.
	-- The answer comes back with `open` and lands in `showMenu`.
	request('ask')
	return true
end

--- Draws the radio menu from the last state the server sent.
local function showMenu()
	if state == nil then return false end
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then
		OPX.Toast.Locale('radio.error.no_menu', nil, 'error')
		return false
	end
	local opened = menu.Open(M.Spec())
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('radio', ('the radio menu was refused: %s')
			:format(tostring(type(opened) == 'table' and opened.error or opened)))
		return false
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
	return true
end

local function redraw()
	local menu = OPX.Api.Get('menu')
	if menuHandle == nil or menu == nil or type(menu.Update) ~= 'function' then return end
	local updated = menu.Update(menuHandle, M.Spec())
	if type(updated) ~= 'table' or not updated.ok then menuHandle = nil end
end

local function onState(payload)
	if type(payload) ~= 'table' then return end
	payload.channels = type(payload.channels) == 'table' and payload.channels or {}
	state = payload
	if payload.open == true then return showMenu() end
	redraw()
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	state, menuHandle, held, granted = nil, nil, false, false
end

--- Publishes the client half: the state as last sent, and the menu.
-- @author dop42
function M.Api()
	OPX.Api.Provide('radio', 1, {
		--- The radio as the server last described it, or nil.
		State = function() return state end,
		OpenMenu = M.OpenMenu,
		--- Whether the talk key is down and granted.
		Talking = function() return held and granted end,
	})
end

--- Listens to the server and registers the talk key, on a thread.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.STATE, onState)
	RegisterNetEvent(M.Event.KEYED, onKeyed)
	-- The two fields this half needs, read by hand: the whole `Model.Build`
	-- walks every channel's gates, which is the server's work and not worth a
	-- client resume.
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	intent = settings.TALK_INTENT == 'channels' and 'channels' or 'all'
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

--- Hands the menu, the key and the microphone back.
-- @author dop42
function M.Stop()
	closeMenu()
	if held and granted then transmit(false) end
	held, granted = false, false
	pcall(OPX.Toast.Dismiss, AIR_TOAST)
	state = nil
end
