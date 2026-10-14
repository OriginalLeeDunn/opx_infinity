--- The creator surface, client half: menus, forms, panels, toasts, bars, eye
--- rows, key hints and gestures another resource may put on THIS player's
--- screen, reads of the local player, and the public client events it may
--- subscribe to.
-- @author dop42
--
-- LAST IN THE CLIENT MANIFEST, for the reason its server twin gives: it wraps
-- contracts the modules publish, reads them at the moment of the call, and an
-- export registered at file scope is supported.
--
-- THE ANSWER IS THE SERVER HALF'S: one plain table, `{ ok = true, value }` or
-- `{ ok = false, error = <code> }`, and nothing raises.
--
-- THERE IS NO CALLBACK, AND THE ANSWER COMES BACK AS AN EVENT. A function
-- cannot cross into another resource -- the export marshaller refuses one -- so
-- a menu row chosen, a form answered or a bar that ran out cannot be handed
-- back the way an in-resource `on` is. And the client `TriggerEvent` reaches
-- this VM only (devkit card, `client TriggerEvent`: "every handler in this
-- resource's VM"), so it cannot be raised on the caller's bus from here either.
-- What CAN cross is a call into the caller's own export, so that is the reply:
--
--   exports('OnOpxEvent', function(event, payload) TriggerEvent(event, payload) end)
--
-- one line in the caller, after which every answer arrives on the caller's OWN
-- bus as an ordinary event -- `opx:on:menu:action`, `opx:on:form:answer`,
-- `opx:on:progress:done`, `opx:on:animations:result` -- with the payload the
-- module raises for its own callers. `CLIENT.EXPORTS.REPLY` names the default
-- export and a call may name its own with `reply`.
--
-- OWNERSHIP IS THE CALLER'S NAME, read from the host. Each module keys a menu,
-- a form, a bar and a gesture on an owner string; this file writes it as
-- `ext:<resource>`, so a creator can only close, update or stop what it opened
-- itself, and never takes over a screen another owner holds. When a caller
-- resource stops, whatever it left open here is taken down with it.

-- What a toast id a caller names may be: the resource-name alphabet.
local ID_PATTERN = '^[%w_%-%.]+$'

-- An export name a caller may ask its answers to be delivered to.
local REPLY_PATTERN = '^[%w_]+$'

-- What each caller has open, by handle, so a close names only its own.
local menus, forms = {}, {}

-- Pending gesture requests by request id, so a verdict reaches its caller.
local gestures = {}

-- Reply failures already said, by `caller \1 reason`.
local said = {}

-- The answer shapes, the caller gate and the allowlist test are shared with the
-- server surface: `core/shared/exports.lua`.
local Export = OPX.Export
local refuse, ok, answered = Export.Refuse, Export.Ok, Export.Answered
local admits, hasExports = Export.Admits, Export.Available

local function settings()
	local client = OPX.Config.CLIENT or {}
	return type(client.EXPORTS) == 'table' and client.EXPORTS or {}
end

--- The owner string a caller's screens are kept under.
local function ownerOf(caller)
	return 'ext:' .. caller
end

--- The resource behind an owner string, or nil when it is not a caller's.
local function callerOf(owner)
	return type(owner) == 'string' and owner:match('^ext:([%w_%-%.]+)$') or nil
end

--- The export a call's answers go to.
local function replyOf(value)
	if type(value) == 'string' and #value >= 1 and #value <= 64 and value:match(REPLY_PATTERN) then
		return value
	end
	local default = settings().REPLY
	return type(default) == 'string' and default ~= '' and default or 'OnOpxEvent'
end

--- Delivers one answer to the caller's own export, on its own thread.
--
-- The promise is KEPT UNTIL IT IS AWAITED: the devkit says a collected promise
-- releases its request and cancels a target task that has not run yet, so a
-- fire-and-forget call could lose the very answer it was carrying.
local function reply(caller, export, event, payload)
	CreateThread(function()
		local api = Open77.exports
		if type(api) ~= 'table' or type(api.call) ~= 'function' then return end
		local promise, reason = api.call(caller, export, event, payload)
		local failure = reason
		if promise then
			local _, awaited = promise:await()
			failure = awaited
		end
		if failure ~= nil then
			local key = caller .. '\1' .. tostring(failure)
			if not said[key] then
				said[key] = true
				Open77.log.warn(('[exports] %s did not take %s through its %s export: %s'):format(
					caller, event, export, tostring(failure)))
			end
		end
	end)
end

--- A copy of an answer with the owner's prefix taken back off, so the caller
--- reads its own name rather than this file's bookkeeping.
local function forCaller(payload, caller)
	local copy = OPX.Table.DeepCopy(payload)
	if type(copy) == 'table' and copy.owner ~= nil then copy.owner = caller end
	return copy
end

--- Publishes one export behind the caller gate.
local function publish(name, body)
	if not hasExports() then return end
	exports(name, function(...)
		local caller = Export.Caller()
		if caller == nil then return refuse('export.callerDenied') end
		if not admits(settings().CALLERS, caller) then return refuse('export.callerDenied') end

		local args = table.pack(...)
		local ran, answer = pcall(body, caller, table.unpack(args, 1, args.n))
		if not ran then
			Open77.log.error(('[exports] %s raised for %s: %s'):format(name, caller, tostring(answer)))
			return refuse('error.unavailable')
		end
		if type(answer) ~= 'table' then return refuse('error.unavailable') end
		return answer
	end)
end

--- A caller's spec, copied, with the fields only this file may set taken out.
local function specOf(spec)
	if type(spec) ~= 'table' then return nil end
	local copy = OPX.Table.DeepCopy(spec)
	copy.owner, copy.on, copy.steal, copy.reply = nil, nil, nil, nil
	return copy
end

-- ── menus ────────────────────────────────────────────────────────────────────

publish('OpenMenu', function(caller, spec)
	local menu = OPX.Api.Get('menu')
	if menu == nil then return refuse('error.unavailable') end
	local built = specOf(spec)
	if built == nil then return refuse('export.badArgument') end
	local export = replyOf(spec.reply)
	built.owner = ownerOf(caller)
	built.on = function(payload)
		if payload.action == 'close' and menus[payload.handle] == caller then
			menus[payload.handle] = nil
		end
		reply(caller, export, 'opx:on:menu:action', forCaller(payload, caller))
	end
	local opened = menu.Open(built)
	if opened.ok then menus[opened.value.handle] = caller end
	return answered(opened)
end)

publish('UpdateMenu', function(caller, handle, spec)
	local menu = OPX.Api.Get('menu')
	if menu == nil then return refuse('error.unavailable') end
	if menus[handle] ~= caller then return refuse('stale_handle') end
	local built = specOf(spec)
	if built == nil then return refuse('export.badArgument') end
	return answered(menu.Update(handle, built))
end)

publish('CloseMenu', function(caller, handle)
	local menu = OPX.Api.Get('menu')
	if menu == nil then return refuse('error.unavailable') end
	if menus[handle] ~= caller then return refuse('stale_handle') end
	return answered(menu.Close(handle, 'caller'))
end)

-- ── forms ────────────────────────────────────────────────────────────────────

publish('OpenForm', function(caller, spec)
	local form = OPX.Api.Get('form')
	if form == nil then return refuse('error.unavailable') end
	local built = specOf(spec)
	if built == nil then return refuse('export.badArgument') end
	local export = replyOf(spec.reply)
	built.owner = ownerOf(caller)
	built.on = function(payload)
		forms[payload.handle] = nil
		reply(caller, export, 'opx:on:form:answer', forCaller(payload, caller))
	end
	local opened = form.Open(built)
	if opened.ok then forms[opened.value.handle] = caller end
	return answered(opened)
end)

publish('CloseForm', function(caller, handle)
	local form = OPX.Api.Get('form')
	if form == nil then return refuse('error.unavailable') end
	if forms[handle] ~= caller then return refuse('stale_handle') end
	return answered(form.Close(handle))
end)

-- ── toasts ───────────────────────────────────────────────────────────────────

--- A toast id a caller may name, kept inside its own prefix.
local function toastId(caller, id)
	if id == nil then return nil end
	if type(id) ~= 'string' or #id < 1 or #id > 48 or not id:match(ID_PATTERN) then
		return false
	end
	return ownerOf(caller) .. ':' .. id
end

publish('ShowToast', function(caller, definition)
	if type(definition) ~= 'table' then return refuse('export.badArgument') end
	local id = toastId(caller, definition.id)
	if id == false then return refuse('export.badArgument') end
	local shown, why = OPX.Toast.Show({
		id = id,
		kind = definition.kind,
		title = definition.title ~= nil and OPX.Text.Clean(definition.title, 64, '...') or nil,
		message = type(definition.message) == 'string'
			and OPX.Text.Clean(definition.message, 240, '...') or nil,
		icon = definition.icon,
		durationMs = math.tointeger(tonumber(definition.durationMs)),
	})
	if shown == nil then return refuse(why or 'error.unavailable') end
	return ok(shown)
end)

publish('DismissToast', function(caller, id)
	local named = toastId(caller, id)
	if not named then return refuse('export.badArgument') end
	OPX.Toast.Dismiss(named)
	return ok(true)
end)

-- ── the progress bar ─────────────────────────────────────────────────────────

-- Which export each caller's bar answers on.
local barReply = {}

publish('StartProgress', function(caller, spec)
	local progress = OPX.Api.Get('progress')
	if progress == nil then return refuse('error.unavailable') end
	if type(spec) ~= 'table' then return refuse('export.badArgument') end
	local started = progress.Start(ownerOf(caller), {
		label = spec.label,
		durationMs = spec.durationMs,
		cancelable = spec.cancelable == true,
		animation = type(spec.animation) == 'table' and {
			name = spec.animation.name, variant = spec.animation.variant,
		} or nil,
	})
	if started.ok then barReply[caller] = replyOf(spec.reply) end
	return answered(started)
end)

publish('StopProgress', function(caller)
	local progress = OPX.Api.Get('progress')
	if progress == nil then return refuse('error.unavailable') end
	return answered(progress.Stop(ownerOf(caller)))
end)

-- ── gestures ─────────────────────────────────────────────────────────────────

publish('PlayAnimation', function(caller, name, options, replyTo)
	local animations = OPX.Api.Get('animations')
	if animations == nil then return refuse('error.unavailable') end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then return refuse('export.badArgument') end
	if options ~= nil and type(options) ~= 'table' then return refuse('export.badArgument') end
	local played = animations.Play(name, options, ownerOf(caller))
	if played.ok and type(played.value) == 'table' and played.value.requestId ~= nil then
		gestures[played.value.requestId] = { caller = caller, reply = replyOf(replyTo) }
	end
	return answered(played)
end)

publish('StopAnimation', function(caller)
	local animations = OPX.Api.Get('animations')
	if animations == nil then return refuse('error.unavailable') end
	return answered(animations.Stop(ownerOf(caller)))
end)

-- ── hearing opx from another client resource ─────────────────────────────────
-- The client `TriggerEvent` stays in its own VM, so `opx:on:character:money`
-- raised here never reaches another resource's `AddEventHandler`. `Subscribe`
-- is the bridge: the caller names an event, and every raise of it is delivered
-- through the caller's reply export -- the same `OnOpxEvent(event, payload)`
-- line the menus answer on -- until it unsubscribes or stops.
--
-- ONLY THE EVENTS BELOW, each with the ONE TABLE it is handed as: an event
-- with several arguments is folded into named fields, and a character's
-- PlayerData is handed without its free-form `metadata`, the same rule the
-- server bus keeps. Anything else is `export.notSubscribable`; this module's
-- `opx:in:*` wiring and its view events are never on offer.

--- A copy of a client PlayerData with the free-form metadata left out.
local function closedPlayer(data)
	if type(data) ~= 'table' then return {} end
	local copy = OPX.Table.DeepCopy(data)
	copy.metadata = nil
	return copy
end

--- The first argument copied, or an empty table.
local function firstTable(value)
	return type(value) == 'table' and OPX.Table.DeepCopy(value) or {}
end

local SUBSCRIBABLE = {
	['opx:on:character:loaded'] = closedPlayer,
	['opx:on:character:unloaded'] = function() return {} end,
	['opx:on:character:changed'] = closedPlayer,
	['opx:on:character:money'] = function(moneyType, amount, action, balance)
		return { moneyType = moneyType, amount = amount, action = action, balance = balance }
	end,
	['opx:on:character:job'] = firstTable,
	['opx:on:character:gang'] = firstTable,
	['opx:on:downed:changed'] = firstTable,
	['opx:on:inventory:changed'] = firstTable,
	['opx:on:inventory:used'] = firstTable,
	['opx:on:inventory:opened'] = function() return {} end,
	['opx:on:inventory:closed'] = function() return {} end,
	['opx:on:needs:changed'] = firstTable,
	['opx:on:progress:state'] = firstTable,
}

-- Who hears what: subscribers[event][caller] = the export it is delivered to.
local subscribers = {}

publish('Subscribe', function(caller, event, replyTo)
	if type(event) ~= 'string' or #event > 64 then return refuse('export.badArgument') end
	if SUBSCRIBABLE[event] == nil then return refuse('export.notSubscribable') end
	if replyTo ~= nil and (type(replyTo) ~= 'string' or not replyTo:match(REPLY_PATTERN)
		or #replyTo > 64) then
		return refuse('export.badArgument')
	end
	subscribers[event] = subscribers[event] or {}
	subscribers[event][caller] = replyOf(replyTo)
	return ok(true)
end)

publish('Unsubscribe', function(caller, event)
	if type(event) ~= 'string' or #event > 64 then return refuse('export.badArgument') end
	if SUBSCRIBABLE[event] == nil then return refuse('export.notSubscribable') end
	local heard = subscribers[event]
	local was = heard ~= nil and heard[caller] ~= nil
	if heard ~= nil then heard[caller] = nil end
	return ok(was)
end)

-- One handler per subscribable event, registered once; a raise nobody
-- subscribed to costs a table lookup.
for event, shape in pairs(SUBSCRIBABLE) do
	AddEventHandler(event, function(...)
		local heard = subscribers[event]
		if heard == nil or next(heard) == nil then return end
		local shaped, payload = pcall(shape, ...)
		if not shaped or type(payload) ~= 'table' then return end
		for caller, export in pairs(heard) do
			-- Each caller its own copy: one may not edit what the next reads.
			local copy = OPX.Table.DeepCopy(payload)
			-- A bar another resource drew is not this caller's to name: the
			-- owner is the caller's own name on its own bar, and left out on
			-- anybody else's, the rule `forCaller` keeps for the answers.
			if type(copy.owner) == 'string' and callerOf(copy.owner) ~= nil then
				copy.owner = callerOf(copy.owner) == caller and caller or nil
			end
			reply(caller, export, event, copy)
		end
	end)
end

-- ── a name a module already answers to ───────────────────────────────────────
-- The target, prompt and panel stores key a row on its OWNER'S NAME, and a
-- module of this runtime registers under its own id. A resource named like one
-- of them -- a `target` or an `inventory` resource -- would share that module's
-- rows: clear them, replace them, be swept with them. Refused instead.

--- Whether a caller's name is one a module of this runtime already uses.
local function takenName(caller)
	return OPX.Modules.Record(caller) ~= nil
end

-- ── the eye ──────────────────────────────────────────────────────────────────
-- ROWS ON THE TARGET EYE, OWNED BY THE CALLER. The owner is the caller's own
-- resource name, which is how the eye already tells a separate resource's row
-- from a module's: it reads that resource's generation, sweeps the rows when it
-- stops or reloads, and asks its callbacks over an export call in slices, never
-- inside one resume (`modules/target/client/main.lua`).
--
-- A CALLBACK IS AN EXPORT NAME OF THE CALLER'S. `onSelect = 'OnPick'` calls
-- `exports.<caller>:OnPick(context)`; `canInteract` and `checked` the same,
-- answering true or false. A function cannot cross the marshaller, and a
-- `{ resource, export }` pair naming any resource but the caller is refused:
-- one resource's row must never run another resource's code.

-- The callback fields of a row.
local TARGET_CALLBACKS = { 'onSelect', 'canInteract', 'checked' }

-- The register function for each kind, and whether it takes a list of where
-- (models, entities, spheres) before the rows.
local TARGET_KINDS = {
	any = { fn = 'Register' },
	players = { fn = 'RegisterPlayers' },
	self = { fn = 'RegisterSelf' },
	vehicles = { fn = 'RegisterVehicles' },
	npcs = { fn = 'RegisterNpcs' },
	props = { fn = 'RegisterProps' },
	doors = { fn = 'RegisterDoors' },
	world = { fn = 'RegisterWorld' },
	sky = { fn = 'RegisterSky' },
	models = { fn = 'RegisterModels', where = true },
	entities = { fn = 'RegisterEntities', where = true },
	spheres = { fn = 'RegisterSpheres', where = true },
}

--- A row, or a patch, with its callbacks held to the caller's own exports; nil
--- when one names anything else.
local function ownRow(caller, row)
	if type(row) ~= 'table' then return nil end
	local copy = OPX.Table.DeepCopy(row)
	copy.owner = nil
	for _, field in ipairs(TARGET_CALLBACKS) do
		local callback = copy[field]
		if callback ~= nil then
			if type(callback) == 'table' then
				if callback.resource ~= caller or type(callback.export) ~= 'string' then return nil end
				copy[field] = callback.export
			elseif type(callback) ~= 'string' then
				return nil
			end
		end
	end
	return copy
end

--- One row, or a list of them, each held to the caller's exports.
local function ownRows(caller, definitions)
	if type(definitions) ~= 'table' then return nil end
	if definitions.id ~= nil then return ownRow(caller, definitions) end
	local out = {}
	for index, row in ipairs(definitions) do
		out[index] = ownRow(caller, row)
		if out[index] == nil then return nil end
	end
	if #out == 0 then return nil end
	return out
end

publish('AddTarget', function(caller, kind, definitions, where)
	local target = OPX.Api.Get('target')
	if target == nil then return refuse('error.unavailable') end
	if takenName(caller) then return refuse('export.ownerTaken') end
	local entry = type(kind) == 'string' and TARGET_KINDS[kind] or nil
	if entry == nil then return refuse('export.badArgument') end
	local rows = ownRows(caller, definitions)
	if rows == nil then return refuse('export.badArgument') end
	if entry.where then
		if type(where) ~= 'table' then return refuse('export.badArgument') end
		return answered(target[entry.fn](caller, OPX.Table.DeepCopy(where), rows))
	end
	return answered(target[entry.fn](caller, rows))
end)

publish('UpdateTarget', function(caller, token, patch)
	local target = OPX.Api.Get('target')
	if target == nil then return refuse('error.unavailable') end
	if takenName(caller) then return refuse('export.ownerTaken') end
	if type(token) ~= 'string' then return refuse('export.badArgument') end
	local own = ownRow(caller, patch)
	if own == nil then return refuse('export.badArgument') end
	return answered(target.Update(caller, token, own))
end)

publish('RemoveTarget', function(caller, tokens)
	local target = OPX.Api.Get('target')
	if target == nil then return refuse('error.unavailable') end
	if takenName(caller) then return refuse('export.ownerTaken') end
	if type(tokens) == 'string' then return answered(target.Unregister(caller, tokens)) end
	if type(tokens) ~= 'table' or #tokens == 0 then return refuse('export.badArgument') end
	return answered(target.UnregisterMany(caller, OPX.Table.DeepCopy(tokens)))
end)

publish('ClearTargets', function(caller)
	local target = OPX.Api.Get('target')
	if target == nil then return refuse('error.unavailable') end
	if takenName(caller) then return refuse('export.ownerTaken') end
	return answered(target.Clear(caller))
end)

-- ── the key strip ────────────────────────────────────────────────────────────
-- Display only: a group of key hints the caller owns, validated whole by the
-- prompts module. Taken down when the caller stops, by the module's own sweep
-- and by the stop handler below.

publish('ShowPrompt', function(caller, id, spec)
	local prompts = OPX.Api.Get('prompts')
	if prompts == nil then return refuse('error.unavailable') end
	if takenName(caller) then return refuse('export.ownerTaken') end
	if type(spec) ~= 'table' then return refuse('export.badArgument') end
	return answered(prompts.Show(caller, id, OPX.Table.DeepCopy(spec)))
end)

publish('UpdatePrompt', function(caller, id, patch)
	local prompts = OPX.Api.Get('prompts')
	if prompts == nil then return refuse('error.unavailable') end
	if takenName(caller) then return refuse('export.ownerTaken') end
	if type(patch) ~= 'table' then return refuse('export.badArgument') end
	return answered(prompts.Update(caller, id, OPX.Table.DeepCopy(patch)))
end)

publish('HidePrompt', function(caller, id)
	local prompts = OPX.Api.Get('prompts')
	if prompts == nil then return refuse('error.unavailable') end
	if takenName(caller) then return refuse('export.ownerTaken') end
	return answered(prompts.Hide(caller, id))
end)

publish('HideAllPrompts', function(caller)
	local prompts = OPX.Api.Get('prompts')
	if prompts == nil then return refuse('error.unavailable') end
	if takenName(caller) then return refuse('export.ownerTaken') end
	return answered(prompts.HideAll(caller))
end)

-- ── the panel ────────────────────────────────────────────────────────────────
-- The side panel, opened like a menu: owned `ext:<caller>`, never over another
-- owner's panel, answered on `opx:on:panel:action` through the reply export.

-- Which panel each caller has open, by handle.
local panels = {}

publish('OpenPanel', function(caller, spec)
	local panel = OPX.Api.Get('panel')
	if panel == nil then return refuse('error.unavailable') end
	local built = specOf(spec)
	if built == nil then return refuse('export.badArgument') end
	local export = replyOf(spec.reply)
	built.owner = ownerOf(caller)
	built.on = function(payload)
		if payload.action == 'close' and panels[payload.handle] == caller then
			panels[payload.handle] = nil
		end
		reply(caller, export, 'opx:on:panel:action', forCaller(payload, caller))
	end
	local opened = panel.Open(built)
	if opened.ok then panels[opened.value.handle] = caller end
	return answered(opened)
end)

publish('UpdatePanel', function(caller, handle, patch)
	local panel = OPX.Api.Get('panel')
	if panel == nil then return refuse('error.unavailable') end
	if panels[handle] ~= caller then return refuse('stale_handle') end
	if type(patch) ~= 'table' then return refuse('export.badArgument') end
	return answered(panel.Update(handle, OPX.Table.DeepCopy(patch)))
end)

publish('AppendPanel', function(caller, handle, items, done)
	local panel = OPX.Api.Get('panel')
	if panel == nil then return refuse('error.unavailable') end
	if panels[handle] ~= caller then return refuse('stale_handle') end
	if type(items) ~= 'table' or (done ~= nil and type(done) ~= 'boolean') then
		return refuse('export.badArgument')
	end
	return answered(panel.Append(handle, OPX.Table.DeepCopy(items), done))
end)

publish('ClosePanel', function(caller, handle)
	local panel = OPX.Api.Get('panel')
	if panel == nil then return refuse('error.unavailable') end
	if panels[handle] ~= caller then return refuse('stale_handle') end
	return answered(panel.Close(handle, 'caller'))
end)

-- ── a crafting bench the caller registered ───────────────────────────────────
-- The bench is registered on the server (`RegisterCraftingBench`), under
-- `<caller>:<key>`; this opens its screen for the local player, which the
-- server answers after measuring the reach and asking the bench's job gate.

publish('OpenCraftingBench', function(caller, key)
	local crafting = OPX.Api.Get('crafting')
	if crafting == nil or crafting.Open == nil then return refuse('error.unavailable') end
	if type(key) ~= 'string' or #key < 1 or #key > 32 or not key:match('^[%w_%-%.]+$') then
		return refuse('export.badArgument')
	end
	return answered(crafting.Open(caller .. ':' .. key))
end)

-- ── what the local player is ─────────────────────────────────────────────────
-- Reads of THIS client's own state, from the mirrors the modules keep. Advice
-- for drawing a screen, never a gate: the server re-derives everything that
-- matters.

publish('GetPlayerData', function()
	local character = OPX.Api.Get('character')
	if character == nil then return refuse('error.unavailable') end
	if not character.IsLoggedIn() then return refuse('error.notLoggedIn') end
	return ok(closedPlayer(character.GetPlayerData()))
end)

publish('GetItemCount', function(_, name)
	local inventory = OPX.Api.Get('inventory')
	if inventory == nil then return refuse('error.unavailable') end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then return refuse('export.badArgument') end
	return ok(inventory.GetItemCount(name))
end)

publish('HasItem', function(_, name, count)
	local inventory = OPX.Api.Get('inventory')
	if inventory == nil then return refuse('error.unavailable') end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then return refuse('export.badArgument') end
	local wanted = count == nil and 1 or math.tointeger(count)
	if wanted == nil or wanted < 1 then return refuse('export.badArgument') end
	return ok(inventory.GetItemCount(name) >= wanted)
end)

publish('GetItem', function(_, name)
	local inventory = OPX.Api.Get('inventory')
	if inventory == nil then return refuse('error.unavailable') end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then return refuse('export.badArgument') end
	return ok(inventory.GetItem(name))
end)

publish('IsDown', function()
	local downed = OPX.Api.Get('downed')
	if downed == nil then return refuse('error.unavailable') end
	return answered(downed.IsDown())
end)

publish('GetNeeds', function()
	local needs = OPX.Api.Get('needs')
	if needs == nil then return refuse('error.unavailable') end
	return answered(needs.GetNeeds())
end)

-- ── the answers that arrive later ────────────────────────────────────────────

-- A bar is answered on its module's own bus, under the owner it was started
-- with, which is how a caller's bar is told from everybody else's.
AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'progress', 'done'), function(payload)
	if type(payload) ~= 'table' then return end
	local caller = callerOf(payload.owner)
	if caller == nil then return end
	local export = barReply[caller] or replyOf(nil)
	barReply[caller] = nil
	reply(caller, export, 'opx:on:progress:done', forCaller(payload, caller))
end)

-- A gesture's verdict follows its request by id.
AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'animations', 'result'), function(payload)
	if type(payload) ~= 'table' then return end
	local pending = payload.requestId ~= nil and gestures[payload.requestId] or nil
	if pending == nil then return end
	gestures[payload.requestId] = nil
	reply(pending.caller, pending.reply, 'opx:on:animations:result',
		forCaller(payload, pending.caller))
end)

-- A CALLER THAT STOPS TAKES ITS SCREENS WITH IT. Nobody is left to answer a
-- menu whose owner has gone, and a bar holding the player's movement for a
-- resource that no longer exists is a player who cannot walk.
AddEventHandler(OPX.Host.CLIENT_RESOURCE_STOP, function(name)
	if type(name) ~= 'string' or name == GetCurrentResourceName() then return end
	local menu, form = OPX.Api.Get('menu'), OPX.Api.Get('form')
	for handle, caller in pairs(menus) do
		if caller == name then
			menus[handle] = nil
			if menu ~= nil then menu.Close(handle, 'owner_stopped') end
		end
	end
	for handle, caller in pairs(forms) do
		if caller == name then
			forms[handle] = nil
			if form ~= nil then form.Close(handle) end
		end
	end
	local progress = OPX.Api.Get('progress')
	if progress ~= nil then progress.Stop(ownerOf(name)) end
	barReply[name] = nil
	local animations = OPX.Api.Get('animations')
	if animations ~= nil then animations.Stop(ownerOf(name)) end
	for id, pending in pairs(gestures) do
		if pending.caller == name then gestures[id] = nil end
	end
	-- Nobody left to deliver to: an export call into a stopped resource is a
	-- refusal per raise, and a later resource of that name never asked.
	for _, heard in pairs(subscribers) do heard[name] = nil end
	local panel = OPX.Api.Get('panel')
	for handle, caller in pairs(panels) do
		if caller == name then
			panels[handle] = nil
			if panel ~= nil then panel.Close(handle, 'owner_stopped') end
		end
	end
	-- The eye and the strip sweep a stopped owner on their own; this is the
	-- same, at once rather than on their next pass. Never for a module's name,
	-- which those stores keep their own rows under.
	if not takenName(name) then
		local target = OPX.Api.Get('target')
		if target ~= nil then target.Clear(name) end
		local prompts = OPX.Api.Get('prompts')
		if prompts ~= nil then prompts.HideAll(name) end
	end
end)

if not hasExports() then
	Open77.log.warn('[exports] this host has no `exports`: the creator surface is not published')
end
