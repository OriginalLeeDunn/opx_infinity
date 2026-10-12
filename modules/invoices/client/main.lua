--- Client half: the "Send a bill" row, the bill form, the prompt and the tab.
-- @author dop42
--
-- NOTHING HERE DECIDES. The row is drawn for a character whose own job the
-- config lists (a hint read off the local character, never a gate), the form
-- sends what was typed, the prompt sends what was chosen, and the server judges
-- every one of them again: job, grade, duty, reach, amount, the bill itself.
--
-- THE CLIENT BUDGET. One eye row, registered once on a thread; the prompt and
-- the tab are menus built from a payload the server bounded (MAX_UNPAID). No
-- loop runs every frame.

local M = OPX.Modules.Get('invoices')
local Event = M.Event

local OWNER = 'invoices'
local MENU_ASK, MENU_LIST, FORM_BILL = 'invoices.ask', 'invoices.list', 'invoices.bill'

local settings
local token = nil
local askHandle, askId = nil, nil
local target, menu, form = nil, nil, nil

local function config()
	if settings == nil then settings = M.Model.Settings(M.Settings) end
	return settings
end

local function money(amount, moneyType)
	return OPX.Locale.Money(math.tointeger(amount) or 0, moneyType or config().moneyType)
end

local function toast(key, params, kind) OPX.Toast.Locale(key, params, kind or 'info', 'money') end

-- The billing entry of the local character's job, or nil. A hint only.
local function myEntry()
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetJobData) ~= 'function' then return nil end
	local read, job = pcall(api.GetJobData)
	if not read or type(job) ~= 'table' then return nil end
	return (M.Model.Biller(config(), job, nil, OPX.Now()))
end

local function targetOf(context)
	local hit = type(context) == 'table' and context.target or nil
	if type(hit) ~= 'table' then return nil end
	local id = math.tointeger(tonumber(hit.playerId))
	return id and id > 0 and id or nil
end

-- ── the form ────────────────────────────────────────────────────────────────

local function openForm(player)
	local entry = myEntry()
	if entry == nil then return toast('invoices.refused.not_allowed', nil, 'error') end
	if form == nil or type(form.Open) ~= 'function' then
		return toast('invoices.noScreen', nil, 'error')
	end
	local opened = form.Open({
		owner = OWNER, id = FORM_BILL,
		title = locale('invoices.form.title', { company = entry.label }),
		description = locale('invoices.form.description', { max = money(entry.maxAmount),
			cut = entry.account and entry.cutPct or 100 }),
		fields = {
			{ id = 'amount', label = locale('invoices.form.amount'), required = true,
				charset = 'digits', maxLength = 9 },
			{ id = 'reason', label = locale('invoices.form.reason'), required = true,
				maxLength = config().reasonMax },
		},
		on = function(answer)
			if type(answer) ~= 'table' or answer.action ~= 'submit' then return end
			local values = type(answer.values) == 'table' and answer.values or {}
			TriggerServerEvent(Event.ISSUE, { target = player, amount = values.amount,
				reason = values.reason })
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('invoices', ('the bill form was refused: %s'):format(
			tostring(type(opened) == 'table' and opened.error or opened)))
	end
end

-- ── the prompt ──────────────────────────────────────────────────────────────

local function openMenu(id, title, items, on, paced)
	if menu == nil or type(menu.Open) ~= 'function' then
		toast('invoices.noScreen', nil, 'error')
		return nil
	end
	local opened = menu.Open({
		owner = OWNER, id = id, steal = true, focus = 'cursor', title = title, items = items, yield = paced == true,
		on = function(payload)
			local data = type(payload) == 'table' and payload.data or nil
			if type(data) == 'table' then on(data) end
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('invoices', ('the %s menu was refused: %s'):format(id,
			tostring(type(opened) == 'table' and opened.error or opened)))
		return nil
	end
	return type(opened.value) == 'table' and opened.value.handle or nil
end

local function onAsk(payload)
	if type(payload) ~= 'table' or math.tointeger(payload.id) == nil then return end
	local id = math.tointeger(payload.id)
	local amount = money(payload.amount, payload.moneyType)
	local from = tostring(payload.company or payload.issuer or '?')
	local reply = function(choice) TriggerServerEvent(Event.ACT, { verb = 'respond', id = id, choice = choice }) end
	toast('invoices.target.incoming', { company = from, amount = amount })
	askHandle = openMenu(MENU_ASK, locale('invoices.ask.title', { company = from }), {
		{ id = 'what', icon = 'info', disabled = true, label = tostring(payload.reason or ''),
			value = amount,
			description = locale('invoices.ask.from', { issuer = tostring(payload.issuer or '?'),
				seconds = math.tointeger(payload.ttlS) or 0 }) },
		{ id = 'pay', icon = 'money', label = locale('invoices.ask.pay'), value = amount,
			description = payload.fallbackType and locale('invoices.ask.fallback') or nil,
			data = { choice = 'pay' }, close = true },
		{ id = 'later', icon = 'clock', label = locale('invoices.ask.later'),
			data = { choice = 'later' }, close = true },
		{ id = 'refuse', icon = 'ban', label = locale('invoices.ask.refuse'),
			data = { choice = 'refuse' }, close = true },
	}, function(data) reply(data.choice) end)
	askId = askHandle and id or nil
end

local function onAskClosed(payload)
	local id = type(payload) == 'table' and math.tointeger(payload.id) or nil
	if id == nil or id ~= askId or askHandle == nil then return end
	if menu ~= nil and type(menu.Close) == 'function' then pcall(menu.Close, askHandle, 'answered') end
	askHandle, askId = nil, nil
end

-- ── the tab ─────────────────────────────────────────────────────────────────

-- Built on a thread, a yield after each half and the menu checked paced: a full
-- tab is two money formats a row, which is where one resume would overrun.
local function buildList(payload)
	local owed = type(payload.owed) == 'table' and payload.owed or {}
	local issued = type(payload.issued) == 'table' and payload.issued or {}
	local items = {}
	items[#items + 1] = { id = 'owed', icon = 'list', disabled = true,
		label = locale('invoices.list.owed', { count = #owed }) }
	for index = 1, math.min(#owed, 20) do
		local bill = owed[index]
		if type(bill) == 'table' and math.tointeger(bill.id) then
			items[#items + 1] = { id = 'pay.' .. bill.id, icon = 'money',
				label = ('#%d %s'):format(bill.id, tostring(bill.company or bill.issuer or '')),
				value = money(bill.amount, payload.moneyType),
				description = locale('invoices.list.payHint', { reason = tostring(bill.reason or '') }),
				data = { verb = 'pay', id = bill.id }, close = true }
		end
	end
	Wait(0)
	if #issued > 0 then
		items[#items + 1] = { id = 'issued', icon = 'folder', disabled = true,
			label = locale('invoices.list.issued', { count = #issued }) }
		for index = 1, math.min(#issued, 20) do
			local bill = issued[index]
			if type(bill) == 'table' and math.tointeger(bill.id) then
				items[#items + 1] = { id = 'cancel.' .. bill.id, icon = 'trash',
					label = ('#%d %s'):format(bill.id, tostring(bill.target or '')),
					value = money(bill.amount, payload.moneyType),
					description = locale('invoices.list.cancelHint', { reason = tostring(bill.reason or '') }),
					data = { verb = 'cancel', id = bill.id }, close = true }
			end
		end
	end
	openMenu(MENU_LIST, locale('invoices.list.title'), items, function(data)
		if data.verb == 'pay' then
			TriggerServerEvent(Event.ACT, { verb = 'pay', id = data.id })
		elseif data.verb == 'cancel' then
			TriggerServerEvent(Event.ACT, { verb = 'cancel', id = data.id })
		end
	end, true)
end

local function onList(payload)
	if type(payload) ~= 'table' then return end
	CreateThread(function() buildList(payload) end)
end

-- ── the eye ─────────────────────────────────────────────────────────────────

local function registerRow()
	if target == nil or type(target.RegisterPlayers) ~= 'function' then
		OPX.Note('invoices', 'no target contract: no bill row on the eye; /opx.bill still works')
		return
	end
	local placed = target.RegisterPlayers(OWNER, {
		id = 'invoices.bill', label = locale('invoices.row.bill'), icon = 'money', order = 40,
		distance = math.min(3.0, config().reach),
		canInteract = function(context) return targetOf(context) ~= nil and myEntry() ~= nil end,
		onSelect = function(context)
			local id = targetOf(context)
			if id == nil then return false end
			openForm(id)
			return true
		end,
	})
	if type(placed) == 'table' and placed.ok then
		token = type(placed.value) == 'table' and placed.value.token or nil
	else
		OPX.Note('invoices', ('the bill row was refused: %s'):format(tostring(type(placed) == 'table'
			and placed.error or placed)))
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Reads the contracts it draws with and registers the row.
-- @author dop42
function M.Start()
	target, menu, form = OPX.Api.Get('target'), OPX.Api.Get('menu'), OPX.Api.Get('form')
	RegisterNetEvent(Event.ASK, onAsk)
	RegisterNetEvent(Event.ASK_CLOSED, onAskClosed)
	RegisterNetEvent(Event.SHOW_LIST, onList)
	CreateThread(function()
		Wait(0)
		registerRow()
	end)
end

--- Takes the row back.
-- @author dop42
function M.Stop()
	if target ~= nil and token ~= nil then pcall(target.Unregister, OWNER, token) end
	token, askHandle, askId = nil, nil, nil
end
