--- Toasts, drawn on the overlay.
-- @author dop42
--
-- This used to be a resource of its own that everything else reached through an
-- export, which is why twelve resources carried a copy of the three-level export
-- call just to raise a notice. In one runtime it is a call.
--
-- The page owns the timing: a toast carries its lifetime and the page animates
-- it down and asks to be told when it has gone. Lua keeps only what it needs to
-- address a toast that is still up.

OPX.Toast = OPX.Toast or {}

local NOTIFY = OPX.Event(OPX.Channel.NET, 'runtime', 'notify')
local ANSWER = OPX.Event(OPX.Channel.NET, 'runtime', 'commandAnswer')

local KINDS = { info = true, success = true, warning = true, error = true }
local DEFAULT_MS = 5000

--- The glyphs a toast may carry: `OPX.Glyphs`, and not a list of its own.
--
-- THIS LINE USED TO BE THE COPY THAT DRIFTED FURTHEST. It held fourteen names
-- under a comment saying core may not read a module's namespace, so the lists
-- are kept in step by hand -- and by the time anyone counted, the page drew 45,
-- `Model.ICONS` named 47 and this named 14. The premise was true and the
-- conclusion was wrong: core may not read a MODULE, but a module can read CORE,
-- so the set belongs here, one level down, in `core/shared/glyphs.lua`.
--
-- Nothing had broken, and that is worth saying plainly rather than dressing the
-- fix up: no caller in this resource passes a toast an icon, so the thirty-one
-- names missing from this table could not refuse anything. It was a trap set for
-- whoever first wrote `icon = 'warning'`.
OPX.Toast.ICONS = OPX.Glyphs
local ICONS = OPX.Toast.ICONS

local live = {}
local nextId = 0
local hidden = false

-- Stands for "this key was not on the toast" in `Update`'s rollback. A private
-- table, so no value a caller could ever put in a patch can collide with it.
local ABSENT = {}

--- Whether a value is a glyph this runtime will draw. `nil` and `''` are both
--- "no glyph": a Lua patch cannot carry nil, so `''` is how an update takes one
--- back off a toast that is already up.
local function drawableIcon(value)
	if value == nil or value == '' then return true end
	return type(value) == 'string' and ICONS[value] == true
end

--- A stinger clip name, as the page will accept one: a BARE FILE NAME.
--
-- NO SLASH, NO `..`, NO DRIVE, NO SCHEME, and that is a boundary rather than a
-- tidiness rule. The page resolves a name against its own `audio/` directory and
-- nothing else is reachable from it, so a name able to climb out would be a name
-- able to make every client in the city fetch from anywhere this server named --
-- from a number a client is handed at join. `nil` and `''` are both "no clip":
-- a config cannot carry a nil, so `''` is how one of the two is turned off.
local CLIP_NAME = '^[%w_%-]+%.%w+$'

--- The stinger a toast may carry, normalised, or nil when it carries none.
--
-- A BAD NAME IS DROPPED, NOT REFUSED, which is the opposite of how a glyph name
-- is treated one function up -- and deliberately so. A glyph is chosen by the
-- same code that wrote the sentence it sits beside, so a typo there is the
-- author's to hear about; a stinger is a PRESENTATION setting in a config file,
-- and a server that mistyped a file name must still get its announcement to
-- every player. The cost of dropping one is a silent toast; the cost of refusing
-- the toast is a message nobody receives.
--
-- The volume is clamped rather than refused for the same reason, and a value that
-- is not a number at all -- a NaN, a table, nil -- becomes full volume.
local function stingerOf(value, from)
	if value == nil then return nil end
	if type(value) ~= 'table' then
		Open77.log.warn(('[notify] %s sent a stinger that is not a table; playing none'):format(from))
		return nil
	end

	local function clip(name, which)
		if name == nil or name == '' then return '' end
		if type(name) == 'string' and name:match(CLIP_NAME) then return name end
		Open77.log.warn(('[notify] %s named stinger %s %q, which is not a bare file name; ' ..
			'playing none'):format(from, which, tostring(name)))
		return ''
	end

	local open = clip(value.OPEN or value.open, 'open')
	local close = clip(value.CLOSE or value.close, 'close')
	if open == '' and close == '' then return nil end

	local volume = tonumber(value.VOLUME or value.volume)
	-- NaN is the one number that survives `tonumber` and fails every comparison.
	if volume == nil or volume ~= volume then volume = 1 end
	if volume < 0 then volume = 0 elseif volume > 1 then volume = 1 end

	return { open = open, close = close, volume = volume }
end

--- The icon of a payload that crossed the WIRE, which is a different bargain
--- from an icon a caller in this process passed. A developer's typo is refused
--- where they can see the return value; a server's typo must not cost a player
--- the refusal it was attached to, so the glyph is dropped and logged and the
--- words still arrive.
local function wireIcon(value, from)
	if drawableIcon(value) then return value end
	Open77.log.warn(('[notify] %s sent icon %q, which is not in the set; drawing none')
		:format(from, tostring(value)))
	return nil
end

--- Raises a toast and answers its id. `id` may be supplied to replace a toast
--- already on screen rather than stacking another under it -- a player who runs
--- the same command twice should see one answer, not a pile.
---
--- `icon` is a name from `OPX.Glyphs` and is REFUSED rather than dropped when it
--- is not one, exactly as the menu refuses an item naming a glyph it does not
--- have: a caller who misspelt `vehcile` wants to hear about it now, not to
--- wonder later why one toast in ten has no picture. This holds because the set
--- IS the page's set -- a name outside it is a typo and not a stale copy, which
--- is the whole reason `OPX.Glyphs` exists.
---
--- THE RULE, NOT THE ROLL-CALL: every caller reads the pair and does something
--- with a `nil`. This paragraph used to NAME the callers -- six that checked,
--- three that discarded, "so the sentence above is true again" -- and it was
--- wrong within a day of being written: two more checking callers appeared
--- (`modules/teleports`, `modules/admin/client/announce.lua`) and the two net
--- handlers at the foot of THIS file were discarding the whole time, which is
--- every server-originated refusal and every command answer. Its own closing
--- line said claims about call sites go stale; it was describing itself.
---
--- So the invariant is stated once and enforced once, and no list is kept. What
--- a discarded `nil` costs is not the glyph refusal -- a caller who misspells
--- `vehcile` finds out in testing -- it is `surface_unavailable` and
--- `payload_refused`, which mean the player was told NOTHING and nobody knows.
--- The handlers below relay that to the server's journal rather than to a log
--- file on the player's machine, because from the server a client whose overlay
--- never came up is indistinguishable from a quiet one.
---
--- THERE IS NO DEFAULT GLYPH PER KIND. The set above names domains -- a door, a
--- lock, money -- and holds no tick and no warning mark, so a default would have
--- to draw a padlock on `error.tooFast`. The kind already reaches the player as
--- the frame, the tone and the toast's own kind tag; a glyph that guessed would
--- be the one thing on the surface saying something untrue.
-- `stinger` is what plays around the message rather than with it: `open` runs
-- first and holds the toast back until it ends, `close` runs once the toast has
-- gone. It is the one field here a CONFIG supplies, so a name that does not fit
-- the rule is dropped and logged rather than refused -- see `stingerOf`.
-- @author dop42
-- @param definition table kind, title, message, icon, durationMs, id, stinger
-- @return string|nil
-- @return string|nil why it was refused
function OPX.Toast.Show(definition)
	if type(definition) ~= 'table' then return nil, 'toast_must_be_a_table' end

	local message = definition.message
	if type(message) ~= 'string' or message == '' then return nil, 'invalid_toast_message' end

	if not drawableIcon(definition.icon) then return nil, 'invalid_toast_icon' end

	local id = definition.id
	if type(id) ~= 'string' or id == '' then
		nextId = nextId + 1
		id = ('t%d'):format(nextId)
	end

	local toast = {
		id = id,
		kind = KINDS[definition.kind] and definition.kind or 'info',
		title = definition.title,
		message = message,
		icon = definition.icon,
		durationMs = tonumber(definition.durationMs) or DEFAULT_MS,
		stinger = stingerOf(definition.stinger, 'a toast'),
	}

	-- What this id addressed before, so a refused REPLACEMENT leaves the toast
	-- that is still on screen addressable. It was dropped with the refused one,
	-- and every later `Update` or `Dismiss` of an id the page still drew answered
	-- `no_such_toast`.
	local previous = live[id]
	live[id] = toast
	-- BOTH ANSWERS ARE READ. `OPX.Surface.Send` returns `(sent, refused)`: the
	-- second is true when the host took the call but REJECTED the payload as too
	-- large or not serialisable, which a pcall cannot see and which used to be
	-- invisible here. `live[id]` then held a toast the page had never drawn, and
	-- every later `Update` and `Dismiss` addressed something that was not there.
	-- `modules/panel` learned this the expensive way -- a refused batch of
	-- clothes was reported to the fitting room as delivered and the room sat on
	-- "Reading the catalogue" for good.
	local sent, refused = OPX.UI.Send('overlay', 'notify:show', toast)
	if not sent or refused then
		live[id] = previous
		return nil, refused and 'payload_refused' or 'surface_unavailable'
	end
	return id
end

--- Raises a toast whose text comes from the catalogue. Every refusal code in
--- this runtime is a catalogue key, so this is the path a refusal takes.
-- @author dop42
-- @param key string
-- @param params table|nil
-- @param kind string|nil
-- @param icon string|nil a name from OPX.Toast.ICONS
-- @return string|nil
-- @return string|nil why it was refused
function OPX.Toast.Locale(key, params, kind, icon)
	-- The situation's kind for an error or a warning: see `OPX.Result.Kind`.
	if kind == 'error' or kind == 'warning' then kind = OPX.Result.Kind(key, kind) end
	return OPX.Toast.Show({ kind = kind, message = locale(key, params), icon = icon })
end

--- Takes a toast off screen early.
-- @author dop42
-- @param id string
function OPX.Toast.Dismiss(id)
	if live[id] == nil then return end
	live[id] = nil
	OPX.UI.Send('overlay', 'notify:dismiss', { id = id })
end

--- Rewrites a toast that is still up. Answers false for one that has gone, so a
--- caller updating a progress line stops rather than raising a fresh toast.
-- @author dop42
-- @param id string
-- @param patch table
-- @return boolean
-- @return string|nil why it was refused
function OPX.Toast.Update(id, patch)
	local toast = live[id]
	-- BOTH VALUES, as the `@return` above has always promised. This answered a
	-- bare `false`, so the one caller that distinguished "gone" from "refused"
	-- could not.
	if toast == nil then return false, 'no_such_toast' end
	if type(patch) ~= 'table' then return false, 'patch_must_be_a_table' end

	-- The same gate as `Show`, because this is the other door into the same
	-- payload: a patch reaching the page unchecked would carry a glyph name the
	-- page has no path for straight past the one place that validates it. `''`
	-- takes a glyph back off, which is the only way a patch can, a Lua table
	-- being unable to carry a nil.
	if not drawableIcon(patch.icon) then return false, 'invalid_toast_icon' end

	-- THE PRIOR VALUES, SO A REFUSED PATCH CAN BE PUT BACK. The comment below
	-- named this failure and nothing undid it: Lua's copy went ahead of the
	-- page's, `Toast.Attach`'s `notify:ready` handler replays `live` on the next
	-- page mount, and the player then finally saw text that had already been
	-- refused once -- out of order, and for a progress line, out of date.
	--
	-- `ABSENT` stands in for "this key was not there", because a Lua table cannot
	-- hold a nil and the rollback has to be able to REMOVE a key the patch added.
	-- A sentinel and not `false`: `false` is a value a field could legitimately
	-- hold, and the rollback would then delete it instead of restoring it.
	local prior = {}
	for key in pairs(patch) do
		if key ~= 'id' then
			local was = toast[key]
			prior[key] = was == nil and ABSENT or was
		end
	end

	for key, value in pairs(patch) do
		if key == 'id' then
			-- The id is the handle, not a field: a patch renaming a toast would
			-- leave Lua holding one it can no longer address.
		elseif key == 'stinger' then
			-- Through the same validator as `Show`, for the same reason the icon
			-- above is: this is the other door into the payload the page reads, and
			-- a patch is how a live call changes a toast it already raised.
			toast.stinger = stingerOf(value, 'a toast update')
		else
			toast[key] = value
		end
	end

	-- Both answers, for the reason spelled out in `Show`: a patch the host
	-- refused leaves Lua believing the page is showing the new text.
	local sent, refused = OPX.UI.Send('overlay', 'notify:update', toast)
	if not sent or refused then
		-- WRITTEN OUT, NOT `was ~= ABSENT and was or nil`. That is the and/or trap
		-- `ABSENT` was introduced to avoid: a prior value of `false` made the
		-- `and` answer false and the `or` answer nil, so the rollback DELETED a
		-- field it was meant to restore -- exactly the case the sentinel's own
		-- comment names as the reason it is not `false`.
		for key, was in pairs(prior) do
			if was == ABSENT then toast[key] = nil else toast[key] = was end
		end
		return false, refused and 'payload_refused' or 'surface_unavailable'
	end
	return true
end

--- Clears everything on screen.
-- @author dop42
function OPX.Toast.Clear()
	live = {}
	OPX.UI.Send('overlay', 'notify:clear', {})
end

--- Takes the stacks off screen, keeping every toast, and puts them back.
---
--- The player being down is the only thing that does this, and the module that
--- owns that state calls it: core cannot listen for `opx:on:downed:changed`
--- without depending on a module. The flag is held so a page that remounts is
--- told again -- a view that came back up would otherwise draw toasts over a
--- death screen.
-- @author dop42
-- @param down boolean
function OPX.Toast.SetDown(down)
	hidden = down == true
	OPX.UI.Send('overlay', 'notify:down', { down = hidden })
end

-- Whether the operator has already been told that toasts are not reaching this
-- player. ONE note per session on purpose: a refused toast is a structural
-- failure -- the overlay never came up, or the page rejected the payload -- so
-- the first one says everything the next two hundred would, and `OPX.Note`
-- spends a net event per call against a budget of sixty for the whole session.
local reportedUndrawn = false

--- Reports a toast the page never drew, to the SERVER's journal and not only to
--- a log file on the player's machine.
---
--- This is the pair the two handlers below used to discard, which made them the
--- only callers of `Toast.Show` that did. It matters more here than anywhere
--- else: these two carry every server-originated refusal and every command
--- answer, so a player whose overlay is refusing them is a player who is told
--- nothing at all, and from the server that is indistinguishable from a player
--- who simply never did anything wrong.
local function undrawn(what, why)
	Open77.log.warn(('[notify] %s was not drawn: %s'):format(what, tostring(why)))
	if reportedUndrawn then return end
	reportedUndrawn = true
	OPX.Note('notify', ('%s was not drawn (%s): no toast is reaching this player')
		:format(what, tostring(why)))
end

--- Wires the server's two answer channels and the page's own expiry report.
-- @author dop42
function OPX.Toast.Attach()
	-- The page tells us when a toast finished its own countdown, so Lua's table
	-- does not grow for the session with toasts that are long gone.
	OPX.UI.On('overlay', 'notify:gone', function(payload)
		if type(payload.id) == 'string' then live[payload.id] = nil end
	end)

	-- The view's own handshake, raised from its mount -- which is NOT once per
	-- session. The page is built before the modules are, and a page whose assets
	-- are warm in the CEF cache mounts inside the boot window; a reconnection is
	-- exactly that, and a character switch ends the session. So this can arrive
	-- before this handler exists, which is what `lib/client/surface.lua` latches
	-- payloads for, and it can arrive with toasts already live.
	--
	-- Everything the page cannot know for itself is (re)stated here: its
	-- geometry, whether the player is down, and the toasts Lua still holds. A
	-- replayed toast restarts its countdown on the page, which is the honest
	-- answer: the page owns the clock and this one is new.
	OPX.UI.On('overlay', 'notify:ready', function()
		local settings = (OPX.Config.CLIENT and OPX.Config.CLIENT.TOASTS) or {}
		OPX.UI.Send('overlay', 'notify:config', {
			position = settings.position,
			width = settings.width,
		})
		if hidden then OPX.UI.Send('overlay', 'notify:down', { down = true }) end
		for _, toast in pairs(live) do OPX.UI.Send('overlay', 'notify:show', toast) end
	end)

	-- A GLYPH TRAVELS THIS FAR, and no further. Both of these are tables and
	-- argument lists this runtime owns on both ends, so `OPX.Refuse` and
	-- `OPX.CommandNotice` may name one and it reaches the page. What CANNOT carry
	-- one is `OPX.Notify`: that hands the toast to the platform's own
	-- `open77_notifications` package, whose `icon` is a short TEXT badge -- a
	-- glyph name sent there would draw the word "lock" in a box.
	RegisterNetEvent(NOTIFY, function(payload)
		if type(payload) ~= 'table' then return end
		-- The code is always a catalogue key: the server guarantees it through
		-- RefusalKey, so rendering it raw is never a leak of an internal code.
		local code = payload.code
		if type(code) ~= 'string' then return end
		-- The params are the server's (`refusalParams`, core/server/answer.lua),
		-- re-checked here: only strings and numbers reach the sentence.
		local params = nil
		if type(payload.params) == 'table' then
			params = {}
			for key, value in pairs(payload.params) do
				if type(key) == 'string' and (type(value) == 'string' or type(value) == 'number') then
					params[key] = value
				end
			end
		end
		local raised, why = OPX.Toast.Show({
			kind = payload.kind or 'error',
			message = locale(code, params),
			icon = wireIcon(payload.icon, 'a refusal'),
		})
		if raised == nil then undrawn('a server refusal', why) end
	end)

	RegisterNetEvent(ANSWER, function(_, kind, message, toasted, icon)
		-- `toasted` means the action already raised this toast itself. Without
		-- the flag a command that notifies on success would answer twice.
		if toasted == true then return end
		if type(message) ~= 'string' or message == '' then return end
		local raised, why = OPX.Toast.Show({
			kind = kind,
			message = message,
			icon = wireIcon(icon, 'a command answer'),
			id = 'opx.command',
		})
		if raised == nil then undrawn('a command answer', why) end
	end)
end
