--- One WebUI page: create it, talk to it, and know when it is not there.
-- @author dop42
--
-- Every surface on this platform follows the same boot sequence:
--
--   create -> the page loads -> the page emits `<id>:ready` -> Lua sends its
--   config -> normal traffic
--
-- A page must report ready before anything is sent to it: a send made earlier
-- is dropped, not queued, so `Send` answers false until `ready` arrives.
--
-- The CEF console does not reach the client log. A page therefore reports its
-- own exceptions on `<id>:diag`, and the handler wired here forwards them to
-- `Open77.log`: that channel is the only way a page-side failure is ever seen.
--
-- The WebUI bridge swallows an exception thrown inside an `Open77.on` handler,
-- so every handler registered here runs under a pcall that logs. Without it a
-- handler that raises fails silently and the page just stops responding.

OPX.Surface = {}

-- The five layers the host accepts. `system` is the only one that needs a
-- permission (`webui.system`). This was hardcoded to 'hud' on the evidence that
-- no other value appeared anywhere in the old tree -- which was true and was the
-- wrong conclusion: the layers exist and the caller gets to pick. The runtime's own
-- surface still asks for `hud`, because it carries the HUD and every view at once
-- and `hud` is the only value the shipped resources are known to use.
local LAYERS = { hud = true, menu = true, modal = true, system = true, debug = true }
local DEFAULT_LAYER = 'hud'

local DEFAULT_WIDTH = 1920
local DEFAULT_HEIGHT = 1080
local DEFAULT_FPS = 30
local DEFAULT_Z_INDEX = 700

-- How many payloads are held for a channel that has no handler yet. A view emits
-- its `<module>:ready` ONCE and never again, so one is normally the whole of it;
-- the chat emits two, one per layer. The cap is what keeps a channel nobody ever
-- registers on from growing for the life of the page.
local MAX_LATCHED = 8

-- Channels the operator has already been told the host refuses, so `Send` puts
-- one note in the journal per channel rather than one per call. See `Send`.
local reportedRefusal = {}

--- Holds a payload that arrived on a channel nothing listens to yet.
--
-- The page is built while the modules are still starting, and a module registers
-- its page handlers in `Start` -- which costs a FRAME per module, by design; see
-- the `Wait(0)` in `core/shared/lifecycle.lua` and the budget it resets. A page
-- whose assets are warm in the CEF cache mounts inside that window, which is
-- exactly what a reconnection is, and a character switch ends the session.
--
-- So `<module>:ready` reached a channel whose handler was three modules away and
-- was DROPPED. The module then waited for a handshake that had already been and
-- gone -- no HUD, no prompt strip, an inventory that opens on nothing -- for the
-- rest of the session, because the page reports ready once.
local function latch(surface, channel, payload)
	local held = surface.latched[channel]
	if held == nil then
		held = {}
		surface.latched[channel] = held
	end
	if #held >= MAX_LATCHED then
		if not held.full then
			held.full = true
			Open77.log.warn(('[surface %s] %s:%s held %d payloads and nothing ever ' ..
				'registered on it'):format(surface.id, surface.id, channel, MAX_LATCHED))
		end
		return
	end
	held[#held + 1] = payload
end

--- Registers the one page listener for a channel, if it has none yet.
-- One listener per channel, dispatching through `handlers`, is what makes a
-- handler replaceable and keeps a raised handler from disappearing.
-- @param surface table
-- @param channel string
-- @return boolean
local function wire(surface, channel)
	if surface.wired[channel] then return true end
	local full = surface.id .. ':' .. channel
	local page = surface.page

	local listening, failure = pcall(page.on, page, full, function(payload)
		-- Set here, not in a caller's own ready handler: the flag must be true
		-- before that handler runs, or its first Send is dropped.
		if channel == 'ready' then surface.ready = true end

		-- Every handler on the channel, not just the last one registered. A
		-- channel like `focus:set` is a broadcast that several modules listen
		-- to, and replacing on registration meant only the last module to load
		-- ever heard it -- silently, since nothing reads a handler it did not
		-- install. Iterated over a snapshot: a handler may remove itself.
		-- Held rather than dropped while the channel has nobody on it, and
		-- replayed to the first handler that registers. See `latch`.
		local listeners = surface.handlers[channel]
		if listeners == nil or #listeners == 0 then
			latch(surface, channel, payload)
			return
		end
		-- A REAL SNAPSHOT, which the comment above always promised and the loop
		-- did not take: it walked the live list. A handler that removed itself
		-- -- the remover `On` answers exists for exactly that, and a one-shot
		-- `ready` listener is the obvious caller -- shifted the tail down one, so
		-- the NEXT listener on the channel was skipped for that payload, and the
		-- last index then held nil, which `pcall` reported as `attempt to call a
		-- nil value` against a handler nobody had written. On `focus:set`, the
		-- broadcast several modules share, the skipped one was a module that
		-- never heard the page drop its focus.
		local walking, count = {}, #listeners
		for index = 1, count do walking[index] = listeners[index] end
		for index = 1, count do
			local ran, raised = pcall(walking[index], payload)
			if not ran then
				Open77.log.error(('[surface %s] %s raised: %s')
					:format(surface.id, full, tostring(raised)))
			end
		end
	end)

	if not listening then
		Open77.log.error(('[surface %s] %s not wired: %s'):format(surface.id, full, tostring(failure)))
		return false
	end
	surface.wired[channel] = true
	return true
end

--- Adds a handler to `<id>:<channel>`. Several may listen to one channel, so
--- this appends rather than replaces; a nil handler clears the channel instead.
--- Answers a function that removes just this handler.
-- @author dop42
-- @param surface table
-- @param channel string without the `<id>:` prefix
-- @param handler fun(payload: any)|nil nil clears every handler on the channel
-- @return function|boolean the remover, or false
function OPX.Surface.On(surface, channel, handler)
	if type(surface) ~= 'table' or surface.page == nil then return false end
	if type(channel) ~= 'string' or channel == '' then return false end
	if not wire(surface, channel) then return false end

	if handler == nil then
		surface.handlers[channel] = nil
		return true
	end

	local listeners = surface.handlers[channel]
	if listeners == nil then
		listeners = {}
		surface.handlers[channel] = listeners
	end
	listeners[#listeners + 1] = handler

	-- Whatever arrived before anyone was listening, in the order it arrived.
	--
	-- TO THE FIRST HANDLER ONLY. The later ones on a broadcast channel were not
	-- there when it was emitted, and replaying to each in turn would hand the
	-- same payload out as many times as the channel ends up with listeners.
	-- Cleared before the loop, so a handler that registers another from inside
	-- its own replay cannot be given the same payloads twice.
	local held = surface.latched[channel]
	if held ~= nil and #listeners == 1 then
		surface.latched[channel] = nil
		local full = surface.id .. ':' .. channel
		for index = 1, #held do
			local ran, raised = pcall(handler, held[index])
			if not ran then
				Open77.log.error(('[surface %s] %s raised on a held payload: %s')
					:format(surface.id, full, tostring(raised)))
			end
		end
	end

	return function()
		for index = #listeners, 1, -1 do
			if listeners[index] == handler then table.remove(listeners, index) end
		end
	end
end

--- Creates a WebUI page and wires its ready and diagnostic channels.
-- A nil answer is what a caller turns into its own `no_surface`: there is
-- nothing to draw on, and every export of that resource must refuse.
-- @author dop42
-- @param spec table id, entry, zIndex, fps, width, height, transparent, visible
-- @return table|nil the surface
-- @return string|nil the failure
function OPX.Surface.Create(spec)
	if type(spec) ~= 'table' then return nil, 'bad_spec' end
	if type(spec.id) ~= 'string' or spec.id == '' then return nil, 'bad_spec' end
	if type(spec.entry) ~= 'string' or spec.entry == '' then return nil, 'bad_spec' end

	-- Read at call time, not at load: a client build without the plugin has no
	-- WebUI global, and a resource that only sometimes draws must still load.
	local webui = WebUI
	if type(webui) ~= 'table' or type(webui.create) ~= 'function' then
		return nil, 'no_webui'
	end

	local created, page, reason = pcall(webui.create, {
		entry = spec.entry,
		layer = LAYERS[spec.layer] and spec.layer or DEFAULT_LAYER,
		width = spec.width or DEFAULT_WIDTH,
		height = spec.height or DEFAULT_HEIGHT,
		fps = spec.fps or DEFAULT_FPS,
		zIndex = spec.zIndex or DEFAULT_Z_INDEX,
		transparent = spec.transparent ~= false,
		visible = spec.visible ~= false,
	})
	if not created then return nil, tostring(page) end
	if page == nil then return nil, tostring(reason or 'no_surface') end

	local surface = {
		id = spec.id,
		page = page,
		ready = false,
		-- True once the page is gone: Send and Focus then answer false for
		-- good, and a caller reading it answers `no_surface`.
		failed = false,
		handlers = {},
		wired = {},
		-- `<id>:<channel>` by channel, filled by `Send` as it meets each one.
		names = {},
		-- Payloads that arrived on a wired channel before anything registered on
		-- it. A channel that was never wired never reaches this table -- the host
		-- has no listener to call and the payload is gone before this file sees
		-- it -- which is why the channels a view emits at mount are wired up
		-- front, in `core/client/ui.lua`.
		latched = {},
	}

	wire(surface, 'ready')
	OPX.Surface.On(surface, 'diag', function(payload)
		if type(payload) ~= 'table' then return end
		Open77.log.info(('[surface %s] page: %s'):format(surface.id, tostring(payload.text or '')))
	end)

	return surface
end

--- Sends a payload to the page on `<id>:<channel>`.
-- @author dop42
-- @param surface table
-- @param channel string without the `<id>:` prefix
-- @param payload table|nil
-- @return boolean false while the page is not ready, or gone
-- @return boolean true when the HOST refused the payload -- see below
function OPX.Surface.Send(surface, channel, payload)
	if type(surface) ~= 'table' or surface.failed or not surface.ready then return false end
	if surface.page == nil then return false end
	-- The prefixed name is built once per channel, not once per send: the HUD
	-- streams vitals at 33 ms, so a concatenation here was a fresh string every
	-- other frame for the life of the session, for a name that never changes.
	local full = surface.names[channel]
	if full == nil then
		full = surface.id .. ':' .. channel
		surface.names[channel] = full
	end
	local called, answer = pcall(surface.page.send, surface.page, full, payload or {})
	if not called then
		Open77.log.error(('[surface %s] %s not sent: %s'):format(surface.id, full, tostring(answer)))
		return false
	end

	-- THE ANSWER IS SAID OUT LOUD, AND NOT ACTED ON. `WebUI.Page.send` returns a
	-- boolean and refuses with `invalid_webui_event_payload`: the event name and
	-- the payload are both bounded, so a table too large or not serialisable is
	-- REJECTED, not truncated -- and the pcall above succeeds either way. A payload
	-- the host refused was indistinguishable from one the page drew, which is the
	-- worst shape a bug can have on a seam, and this line is what tells them apart.
	--
	-- IT DOES NOT CHANGE THE FIRST ANSWER THIS FUNCTION GIVES. Returning false there
	-- looks obviously right and is not: callers read that result and branch on it --
	-- the inventory parks its open payload in `pendingOpen` and waits for a handshake
	-- that has already been and gone -- so a refusal that used to be invisible would
	-- become a screen that takes the keyboard and never draws. Making every caller
	-- handle a new failure is a separate change, one caller at a time.
	--
	-- THE SECOND RETURN IS THAT CHANGE, FOR A CALLER THAT IS READY FOR IT. One that
	-- reads a single value is untouched, because Lua drops the rest; one that reads
	-- two learns what the journal line was only ever telling a human. `modules/panel`
	-- is the first, and it had to be: a refused batch of clothes was reported to the
	-- fitting room as delivered, so the room sat on 'Reading the catalogue' for good
	-- with nothing wrong anywhere a player or a caller could see.
	--
	-- Only an explicit false is a refusal: a build that answers nothing at all has
	-- still sent it.
	if answer == false then
		Open77.log.warn(('[surface %s] %s refused by the host: the payload is too large ' ..
			'or not serialisable'):format(surface.id, full))
		-- AND IN THE SERVER'S JOURNAL, ONCE. The warning above goes to a log file
		-- on the PLAYER's machine -- which is the one place nobody diagnosing this
		-- can read -- so the single refusal this whole seam exists to make visible
		-- was visible to nobody. One note per channel per session: a channel the
		-- host refuses once it will refuse every time, so the first says all of
		-- it, and `OPX.Note` spends a net event per call.
		if not reportedRefusal[full] then
			reportedRefusal[full] = true
			OPX.Note('surface', ('%s was refused by the host: the payload is too large or '
				.. 'not serialisable'):format(full))
		end
		return true, true
	end
	return true, false
end

--- Gives the page the keyboard, the cursor, both or neither.
-- @author dop42
-- @param surface table
-- @param keyboard boolean
-- @param cursor boolean
-- @return boolean
function OPX.Surface.Focus(surface, keyboard, cursor)
	if type(surface) ~= 'table' or surface.failed or surface.page == nil then return false end
	local focused, taken = pcall(surface.page.setFocus, surface.page, keyboard == true, cursor == true)
	if not focused then
		Open77.log.error(('[surface %s] focus refused: %s'):format(surface.id, tostring(taken)))
		return false
	end
	-- Only an explicit false is a refusal: a build that answers nothing at all
	-- has still taken the focus.
	return taken ~= false
end

--- Shows or hides the page without destroying it. Hiding is what an overlay does
--- between uses; destroying is for a surface that will not be needed again, since
--- a CEF page is expensive to build and is never replaced in place.
-- @author dop42
-- @param surface table
-- @param visible boolean
-- @return boolean
function OPX.Surface.Visible(surface, visible)
	if type(surface) ~= 'table' or surface.failed or surface.page == nil then return false end
	local page = surface.page
	-- WRITTEN OUT RATHER THAN `visible and page.show or page.hide`, which is the
	-- and/or trap doing real damage. When `visible` is true and the host's page
	-- has no `show` -- an older build, a surface kind that does not support it --
	-- the first half answers nil, the `or` takes over, and the page is HIDDEN in
	-- answer to a request to show it. A missing method should fail the call, not
	-- silently perform its opposite.
	local method = visible and page.show or nil
	if not visible then method = page.hide end
	if type(method) ~= 'function' then return false end
	return (pcall(method, page))
end

-- `HasFocus(surface)` was here and nothing called it: focus is decided by
-- `core/client/ui.lua`'s stack and corrected by the page's own `focus:set`,
-- which is the answer this would have polled for.

--- Registers the host listener for a channel with no handler behind it yet.
--
-- The one thing the latch cannot do for itself. A channel that was never wired
-- has no listener on the host side at all, so a payload for it is gone before
-- this file is reached: latching only ever covers a channel something has
-- already asked for. Wiring a channel AHEAD of the module that owns it is what
-- turns a lost `<module>:ready` into a held one.
-- @author dop42
-- @param surface table
-- @param channel string without the `<id>:` prefix
-- @return boolean
function OPX.Surface.Wire(surface, channel)
	if type(surface) ~= 'table' or surface.failed or surface.page == nil then return false end
	if type(channel) ~= 'string' or channel == '' then return false end
	return wire(surface, channel)
end

--- Destroys the page and marks the surface gone.
-- @author dop42
-- @param surface table
function OPX.Surface.Destroy(surface)
	if type(surface) ~= 'table' then return end
	surface.ready = false
	surface.failed = true
	surface.latched = {}
	local page = surface.page
	surface.page = nil
	if page ~= nil then pcall(page.destroy, page) end
end
