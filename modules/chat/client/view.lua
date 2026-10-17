--- The other half of the seam: the module's state on one side, the page on the other.
-- @author dop42
--
-- `client/main.lua` owns the chat's state and draws nothing. It says everything
-- it has to say on `M.Event.VIEW` and takes everything back through
-- `M.FromView`. This file is the only thing that knows those two ends are a CEF
-- page, which is what lets the state half stay testable without one.
--
-- ONE CHANNEL, NOT ONE PER VERB. Every other view in this runtime takes a
-- channel per verb -- `opx:form:open`, `opx:form:close` -- and this one does not,
-- because the seam it bridges is already a single event carrying a `kind`.
-- Splitting it here would mean a switch in this file and a second switch on the
-- page, both of which would have to be kept in step with a list that lives in a
-- third place. The payload travels as it was published.
--
-- THE KEY IS OURS NOW. The chat module listens for `open77:chat:open`, which is
-- raised by the platform's `open77_chat` -- a resource this server does not load,
-- and the reason the box has never opened and never appeared in the pause menu's
-- shortcuts tab. Registering a mapping here and raising that same event is all
-- that was missing: the state half is not touched, and if `open77_chat` is ever
-- loaded again both keys reach the same handler.

local M = OPX.Modules.Get('chat')

M.View = {}
local View = M.View

-- The surface the page draws on. There is one surface; the name a caller passes
-- is the LAYER hint the page reads off the payload, so the log and the input
-- line travel under their own names and resolve to the same page.
local SURFACE = 'interactive'

-- What a published payload travels on, and what the page answers with.
local CHANNEL = 'chat:view'

-- The mapping id the pause menu lists. Namespaced and stable: a rebind is stored
-- under it, and renaming it loses every player's rebind.
local KEY_ID = 'opx.chat.open'

-- The key the host answered with at registration, or nil.
local bound = nil

-- What this module answers for on `focus:set`, and what it asks for when it does.
--
-- THE KEYBOARD IS NOT HANDED OVER BY ASKING THE PAGE. `focus:set` is a BROADCAST:
-- the page announces that its own stack changed, and every view module on this
-- surface answers for ITS OWN owner by calling `OPX.UI.AcquireFocus`. Nothing
-- else calls it, so an owner no module claims is an owner nobody acquires --
-- `OPX.Surface.Focus` is never applied and the game keeps the keyboard.
--
-- That is not hypothetical: it is what this file shipped without, and the box
-- opened over a keyboard the player could not type into.
--
-- `cursor = false`, like the form and unlike the menu. This is one text line; the
-- pointer has nothing to do here, and taking it would put a cursor on screen and
-- stop the player turning while they talk.
local FOCUS = {
	chat = { keyboard = true, cursor = false },
}

--- Declares the open key. A refusal costs one log line and nothing else.
-- Two answer shapes are documented for `RegisterKeyMapping` -- the key guide
-- answers `true, key` and the API reference answers the key alone -- and either
-- is a registration. `false` or nil with a reason is a refusal.
local function registerKey(key)
	if key == false or key == nil then return false end
	if type(RegisterKeyMapping) ~= 'function' then
		Open77.log.warn(('[chat] key mapping %s not registered: this client build has no ' ..
			'RegisterKeyMapping'):format(KEY_ID))
		return false
	end

	local function pressed()
		-- A key pressed while another surface holds the keyboard -- a form, the
		-- inventory, the pause menu -- does nothing, so that typing the open key
		-- into a text field does not raise the box behind it.
		if OPX.Lib.Input.IsCaptured() then return end
		-- The host's own name, raised by us. `client/main.lua` listens for it and
		-- has no idea who pressed what, which is the point.
		local ran, failure = pcall(TriggerEvent, M.Host.CHAT_KEY)
		if not ran then
			Open77.log.error(('[chat] key %s: %s'):format(KEY_ID, tostring(failure)))
		end
	end

	local called, ok, answer = pcall(RegisterKeyMapping, KEY_ID, locale('chat.key.open'), key, pressed)
	local effective = type(ok) == 'string' and ok ~= '' and ok or
		(ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
	if not called or (ok ~= true and effective == nil) then
		Open77.log.warn(('[chat] key mapping %s (%s) not registered: %s')
			:format(KEY_ID, tostring(key), tostring(called and answer or ok)))
		return false
	end
	bound = effective or key
	return true
end

-- Answers the surface-wide focus broadcast for this module's own owners.
--
-- THE BROADCAST NAMES THE WHOLE STACK'S TOP, NOT JUST "EMPTY OR NOT", and
-- reading only the empty case was the incomplete half of this idiom.
-- `ui/src/bridge/focus.ts` announces on EVERY change to the page's focus stack,
-- carrying the one owner now on top -- so a top that moved from one of OURS to
-- somebody else's arrives here as `focus = true` with an owner this module does
-- not know, and the old shape did nothing at all with that. The stale Lua entry
-- then sat above the module actually on screen and `applyFocus` applied ITS
-- wants: the chat line's `cursor = false` over the inventory's `cursor = true`,
-- with the inventory drawn and the cursor gone.
--
-- The answer is the same in all six copies: release every owner of mine that is
-- NOT the announced one, then acquire the announced one if it is mine. `form`,
-- `menu` and `panel` are saved from the worst of it by an explicit
-- `ReleaseFocus` on their close paths; `chat` and `downed` have none, so for
-- those two this handler is the only release there is.
local function onFocus(payload)
	if type(payload) ~= 'table' then return end
	local owner = payload.owner
	local held = (payload.focus == true and type(owner) == 'string') and owner or nil
	for name in pairs(FOCUS) do
		if name ~= held then OPX.UI.ReleaseFocus(name) end
	end
	local wants = held ~= nil and FOCUS[held] or nil
	if wants == nil then return end
	OPX.UI.AcquireFocus(held, wants)
end

--- Wires the page to the seam and claims the open key.
-- @author dop42
function View.Start()
	-- Before the seam: the page announces its focus during the same burst that
	-- opens the box, and an announcement with no handler is dropped, not queued.
	OPX.UI.On(SURFACE, 'focus:set', onFocus)

	-- On may synchronously replay a ready received before this module started.
	-- Its immediate config answer needs the seam attached before that replay.
	AddEventHandler(M.Event.VIEW, function(payload)
		if type(payload) ~= 'table' then return end
		OPX.UI.Send(payload.surface or SURFACE, CHANNEL, payload)
	end)

	-- The page to the state half. Every action the seam documents, and nothing
	-- else: an unknown action reaching `FromView` is ignored there, not here.
	for _, action in ipairs({ 'ready', 'submit', 'close', 'diag' }) do
		OPX.UI.On(SURFACE, 'chat:' .. action, function(payload)
			M.FromView(action, payload)
		end)
	end

	local keys = M.Settings.KEYS
	local key = type(keys) == 'table' and keys.OPEN or nil
	if not registerKey(key) then
		Open77.log.info('[chat] no open key: the box opens only if something raises ' ..
			M.Host.CHAT_KEY)
	end
end

--- Forgets the key this file bound. The mapping itself belongs to the host and
--- outlives the resource; only what we remember about it is dropped.
-- @author dop42
function View.Shutdown()
	bound = nil
	-- A focus held across a stop leaves the player unable to move, which is worse
	-- than any state this module could be leaving behind.
	for owner in pairs(FOCUS) do OPX.UI.ReleaseFocus(owner) end
end
