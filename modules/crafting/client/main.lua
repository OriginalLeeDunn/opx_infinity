--- The crafting screen: a list of what can be made, and a shelf of what is cooking.
-- @author dop42
--
-- THIS HALF DRAWS AND NOTHING ELSE. Every row below -- its label, whether it is
-- greyed, the reason it is greyed, how long is left on an order -- arrives in
-- one payload the server built from the server's own tables. This file never
-- counts a bag, never reads a price and never decides that a craft is ready. A
-- client that did any of those would be a client whose screen disagrees with the
-- refusal it gets back, which is worse than a screen that says nothing.
--
-- THE SCREEN IS A `menu`, and that is the whole of the design language. The
-- resource already has one list widget, with a cursor, a breadcrumb, icons, a
-- status line and a greyed-row affordance; a second one built for crafting would
-- be a second thing to keep in step with the theme. What crafting adds is the
-- SHAPE of the list -- the shelf above the recipes, so the first thing a
-- returning player sees is the thing they came back for -- and the sentences.
--
-- WHY THE LIST IS REBUILT RATHER THAN ANIMATED. A cooking order's remaining time
-- is a number the server sent, so it is right at the moment it arrives and drifts
-- afterwards. `Update` keeps the cursor where the player left it, so a refresh
-- every few seconds costs them nothing and the countdown is never a local clock
-- inventing a readiness the database has not agreed to.

local M = OPX.Modules.Get('crafting')

local Recipes = M.Recipes
local Refusal = M.Refusal

-- The one name this module owns on the menu surface.
local OWNER = 'crafting'

-- The `menu` contract, resolved at Start. Nil on a runtime without it, which
-- makes every bench unreachable rather than broken.
local menu = nil

-- The `progress` contract, for the handover bar. Optional in every sense: a
-- runtime without it places the order at once.
local progress = nil

-- The bench the player is at, or nil. Set when the screen is asked for and
-- cleared when it closes, so a VIEW for a bench they have walked away from is
-- dropped rather than drawn over the one they are looking at.
local at = nil

-- The handle of the open menu, or nil.
local handle = nil

-- The repeating refresh, or nil.
local job = nil

-- Forward-declared, because `chose` closes the screen when the player presses
-- Escape and is written above the function that does it. A `local function`
-- further down would be a DIFFERENT name: the closure would have captured the
-- global `shut`, which is nil, and the close would have raised inside the menu
-- module's own dispatch rather than doing anything.
local shut

-- ── drawing ─────────────────────────────────────────────────────────────────

--- The materials line under a recipe: what it costs and what is held.
-- Held BEFORE needed -- `1/2 Scrap Metal` -- because the first number is the one
-- the player can change and the second is the one they cannot.
local function materialsOf(row)
	local parts = {}
	for index = 1, #row.inputs do
		local input = row.inputs[index]
		parts[index] = ('%d/%d %s'):format(input.held, input.need, input.label)
	end
	return table.concat(parts, '  ')
end

--- The right-hand column of a recipe row: how long, and what it costs to ask.
local function priceOf(row)
	local clock = Recipes.Clock(row.seconds)
	if row.price > 0 then
		return ('%s  %s'):format(clock, OPX.Locale.Money(row.price, row.money))
	end
	return clock
end

--- Why a row is greyed, in words, or nil when it is not.
-- Through the catalogue rather than printed raw: `short` is a machine name and
-- the player is owed a sentence. A code with no sentence behind it -- a bench
-- owner's own `canUse` answer -- reads as the generic one and goes to the log;
-- it used to be printed as `crafting.some_code` on the row.
-- The log line only on a refusal, never on a row: rows are redrawn every
-- frame the screen changes.
local function sentenceFor(code, logIt)
	local key = 'crafting.' .. tostring(code)
	if OPX.Locale.Exists(key) then return locale(key) end
	if logIt then
		Open77.log.warn(('[crafting] a refusal with no sentence: %s'):format(tostring(code)))
	end
	return locale('crafting.not_for_you')
end

local function refusalOf(row)
	if row.ok then return nil end
	if row.error == nil then return locale('crafting.not_for_you') end
	return sentenceFor(row.error)
end

--- The whole menu spec for a view.
local function itemsFor(payload)
	local items = {}

	-- THE SHELF FIRST, and it is first because of what a player is doing when
	-- they walk back to a bench: collecting. Putting the recipes above would put
	-- the one row they came for below a screen of rows they did not.
	if #payload.orders > 0 then
		items[#items + 1] = { separator = true,
			label = locale('crafting.shelf', { used = payload.cooking, queue = payload.queue }) }
		for index = 1, #payload.orders do
			local order = payload.orders[index]
			items[#items + 1] = {
				id = ('order_%d'):format(order.id),
				label = ('%d\u{00D7} %s'):format(order.count or 1, order.label),
				icon = order.ready and 'box' or 'clock',
				value = order.ready and locale('crafting.ready')
					or Recipes.Clock(order.remaining),
				description = order.ready and locale('crafting.collectHint')
					or locale('crafting.cookingHint'),
				disabled = not order.ready,
				data = { kind = 'collect', id = order.id },
			}
		end
	end

	items[#items + 1] = { separator = true, label = locale('crafting.recipes') }

	for index = 1, #payload.recipes do
		local row = payload.recipes[index]
		local reason = refusalOf(row)
		items[#items + 1] = {
			id = ('recipe_%d'):format(index),
			label = ('%d\u{00D7} %s'):format(row.count, row.outputLabel),
			icon = row.icon or 'tool',
			value = priceOf(row),
			-- The refusal REPLACES the materials line rather than joining it: a
			-- row refused for a job the player does not hold has nothing to say
			-- about scrap metal, and a row refused for materials says which in
			-- the line it replaces anyway.
			description = reason or materialsOf(row),
			disabled = not row.ok,
			data = { kind = 'order', key = row.key },
		}
	end

	if #payload.recipes == 0 then
		items[#items + 1] = { id = 'empty', label = locale('crafting.nothingHere'),
			icon = 'info', disabled = true }
	end

	return items
end

--- Places an order, with the handover bar over the moment it takes.
--
-- THE BAR IS NOT WAITED ON. It is a picture of handing materials over and the
-- request goes at the same moment; the answer comes back on `VIEW` or `REFUSED`
-- whenever the server has one. Waiting for the bar to finish first would make
-- every order a second and a bit slower for no gain, and would leave the player
-- holding a bar that a refusal has already made a lie.
local function place(benchKey, recipeKey)
	local limits = Recipes.Limits()
	if progress ~= nil and limits.handoverMs > 0 then
		-- The refusal is ignored on purpose: `progress_busy` means somebody else's
		-- bar is up, and an order is not worth refusing over a picture.
		progress.Start(OWNER, {
			label = locale('crafting.handing'),
			durationMs = limits.handoverMs,
		})
	end
	TriggerServerEvent(M.Event.ORDER, benchKey, recipeKey)
end

--- What a row the player chose means.
--
-- A CLOSE IS AN ANSWER TOO, and forgetting that was the first version's bug: the
-- player pressed Escape, the menu went, and the refresh job carried on asking the
-- server about a bench nobody was looking at for the rest of the session. The
-- handle is compared because a menu module may close a stale record -- ours went
-- long ago -- and taking the live screen down on that message would be closing a
-- menu somebody else had just opened.
local function chose(payload)
	if payload.action == 'close' then
		if handle ~= nil and payload.handle == handle then
			handle = nil
			shut(payload.reason)
		end
		return
	end
	if payload.action ~= 'select' then return end
	local data = type(payload.data) == 'table' and payload.data or nil
	if data == nil or at == nil then return end

	if data.kind == 'order' then
		place(at, data.key)
	elseif data.kind == 'collect' then
		TriggerServerEvent(M.Event.COLLECT, at, data.id)
	end
end

--- Takes the screen down and stops asking the server about it.
function shut(reason)
	if job ~= nil then
		OPX.Scheduler.Cancel(job)
		job = nil
	end
	if handle ~= nil and menu ~= nil then
		pcall(menu.Close, handle, reason or 'crafting')
		handle = nil
	end
	at = nil
	TriggerEvent(M.Event.ON_STATE, { open = false, reason = reason })
end

--- Draws or redraws the screen from a view the server sent.
local function draw(payload)
	if menu == nil then return end

	local spec = {
		owner = OWNER,
		id = 'crafting',
		title = payload.label,
		items = itemsFor(payload),
		status = locale('crafting.queueStatus',
			{ used = payload.cooking, queue = payload.queue }),
		on = chose,
	}

	if handle ~= nil then
		-- `Update` and not a fresh `Open`: it re-walks the navigation stack by row
		-- id, so a refresh five seconds into the player reading the list does not
		-- throw their cursor back to the top.
		local updated = menu.Update(handle, spec)
		if updated.ok then return end
		handle = nil
	end

	local opened = menu.Open(spec)
	if not opened.ok then
		Open77.log.warn(('[crafting] the screen was refused: %s'):format(tostring(opened.error)))
		shut('no_screen')
		return
	end
	handle = opened.value.handle

	-- ASKED FOR AGAIN ON A CLOCK, because the only thing on this screen that
	-- moves on its own is time. The interval is the config's and the job is
	-- cancelled the moment the screen goes, so a player who walked away is not
	-- still asking the server about a bench they cannot see.
	if job == nil then
		job = OPX.Scheduler.Every('crafting.refresh', Recipes.Limits().refreshMs, function()
			if at == nil or handle == nil then return end
			TriggerServerEvent(M.Event.OPEN, at)
		end)
	end

	TriggerEvent(M.Event.ON_STATE, { open = true, bench = payload.bench })
end

-- ── the contract ────────────────────────────────────────────────────────────

--- Asks the server for the screen at a bench.
--
-- Answers whether the ASK went, not whether the screen opened: the server
-- re-measures the distance, re-reads the gate and may refuse, and that answer
-- arrives on `REFUSED`. A consumer's target row calls this and does no more.
-- @author dop42
-- @param benchKey string
-- @return Result
local function Open(benchKey)
	local key = Recipes.Key(benchKey)
	if key == nil then return OPX.Result.Err('invalid_bench') end
	if menu == nil then return OPX.Result.Err('no_screen') end
	at = key
	TriggerServerEvent(M.Event.OPEN, key)
	return OPX.Result.Ok(true)
end

--- Closes the screen, if this module has one open.
-- @author dop42
-- @return Result
local function Close()
	shut('caller')
	return OPX.Result.Ok(true)
end

--- What this half is showing.
-- @author dop42
-- @return Result
local function State()
	return OPX.Result.Ok({ open = handle ~= nil, bench = at })
end

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	at, handle, job, menu, progress = nil, nil, nil, nil, nil
end

--- Publishes the client half of the contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('crafting', 1, {
		Open = Open,
		Close = Close,
		State = State,
	})
end

--- Wires the answers.
-- @author dop42
function M.Start()
	menu = OPX.Api.Get('menu')
	progress = OPX.Api.Get('progress')
	if menu == nil then
		Open77.log.warn('[crafting] no menu contract: a bench can be reached and not read')
	end

	RegisterNetEvent(M.Event.VIEW, function(payload)
		if type(payload) ~= 'table' then return end
		if type(payload.recipes) ~= 'table' or type(payload.orders) ~= 'table' then return end
		-- A LATE VIEW FOR A BENCH THEY HAVE LEFT IS DROPPED. The refresh and the
		-- answer to an order can both be in flight when the player walks off and
		-- opens another bench; drawing either would replace the screen they are
		-- reading with one about somewhere else.
		if at == nil or payload.bench ~= at then return end
		draw(payload)
	end)

	RegisterNetEvent(M.Event.REFUSED, function(benchKey, code, screen)
		if type(code) ~= 'string' then return end
		OPX.Toast.Show({ kind = 'error', message = sentenceFor(code, true) })

		-- A REFUSAL THAT MEANS THE SCREEN CANNOT EXIST TAKES IT DOWN; one that
		-- means a row cannot be pressed does not. Walking out of reach with the
		-- list open is the case that matters: the refresh that follows is refused
		-- `too_far`, and leaving the list up would leave a screen the player can
		-- still press rows on from across the street.
		if screen == true or code == Refusal.TOO_FAR or code == Refusal.NO_SUCH_BENCH
			or code == Refusal.NO_CHARACTER or code == Refusal.NOT_FOR_YOU
			or code == Refusal.NO_POSITION then
			shut(code)
		end
	end)

	-- THE CHARACTER LEAVING TAKES THE SCREEN. What is on it belongs to a
	-- character, and the next one to load is not owed a list of somebody else's
	-- orders.
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded'), function()
		shut('character')
	end)
end

--- Takes the screen down with the module.
-- @author dop42
function M.Stop()
	shut('stopped')
end
