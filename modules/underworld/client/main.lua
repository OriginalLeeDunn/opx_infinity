--- Client half: the eye's rows, the menus, the answers and an officer's alarms.
-- @author dop42
--
-- THIS HALF POINTS AND ASKS, nothing else (the rule `modules/gunsmith/client`
-- states). A row on a till sends "rob this till"; a row on a dealer sends "open
-- this stall"; a menu row sends "buy line 2, three of them, dirty". The server
-- re-reads everything, decides, and answers with a locale key that this half
-- turns into a toast. Prices shown in a menu are the server's own numbers, sent
-- with the stall; nothing here is believed.
--
-- THE BUDGET. Registering a sphere row costs the eye ~2,000 instructions, so
-- every registration below is its own resume (`Wait(0)` between them) on a
-- thread of its own, the way `modules/fuel/client/main.lua` builds.

local M = OPX.Modules.Get('underworld')
local Model = M.Model

local OWNER = M.OWNER
local MENU_ID = 'underworld.menu'

local target = nil
local built = nil
-- npc key -> { dealer, label }
local dealers = {}
-- blip id -> expiry instant
local pins = {}
local pinJob = nil

local function money(amount) return OPX.Locale.Money(math.floor(tonumber(amount) or 0)) end

--- An item's label, from the catalogue the inventory keeps on this client.
local function itemLabel(name)
	local inventory = OPX.Api.Get('inventory')
	if inventory ~= nil and type(inventory.GetItem) == 'function' then
		local read, entry = pcall(inventory.GetItem, name)
		if read and type(entry) == 'table' and type(entry.label) == 'string' then return entry.label end
	end
	return tostring(name)
end

-- ── answers ─────────────────────────────────────────────────────────────────

local function onAnswer(payload)
	if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
	local ok = payload.ok == true
	local key = (ok and 'underworld.answer.' or 'underworld.error.') .. payload.code
	if not OPX.Locale.Exists(key) then key = ok and 'underworld.answer.done' or 'underworld.error.unavailable' end
	local raw = type(payload.params) == 'table' and payload.params or {}
	local params = {}
	for name, value in pairs(raw) do
		if type(name) == 'string' and (type(value) == 'number' or type(value) == 'string') then
			params[name] = value
		end
	end
	for _, name in ipairs({ 'price', 'paid', 'amount', 'clean', 'max' }) do
		if tonumber(params[name]) ~= nil then params[name] = money(params[name]) end
	end
	if type(params.item) == 'string' then params.item = itemLabel(params.item) end
	-- A bar started says nothing: the bar is already saying it.
	if ok and payload.code == 'started' then return end
	OPX.Toast.Show({
		id = 'opx.underworld.answer',
		kind = ok and 'success' or OPX.Result.Kind(payload.code, 'error'),
		title = locale('underworld.title'),
		message = locale(key, params),
		icon = 'money',
		durationMs = 5000,
	})
end

-- ── menus ───────────────────────────────────────────────────────────────────

local function openMenu(title, items, on)
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then
		return OPX.Toast.Locale('underworld.error.no_menu', nil, 'error')
	end
	local opened = menu.Open({ owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor',
		title = title, items = items,
		on = function(payload)
			local data = type(payload) == 'table' and payload.data or nil
			if type(data) == 'table' then on(data) end
		end })
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('underworld', ('a menu was refused: %s'):format(tostring(type(opened) == 'table'
			and opened.error or opened)))
	end
end

local function dealerMenu(view)
	local items = {}
	for _, line in ipairs(type(view.stock) == 'table' and view.stock or {}) do
		local pays = {}
		for _, count in ipairs({ 1, 5 }) do
			if count <= (tonumber(line.qty) or 0) then
				pays[#pays + 1] = { id = ('dirty.%d.%d'):format(line.index, count),
					label = locale('underworld.menu.payDirty', { count = count }),
					value = money(line.dirty * count), icon = 'money', close = true,
					data = { verb = 'buy', index = line.index, count = count, pay = 'dirty' } }
				if line.clean ~= nil then
					pays[#pays + 1] = { id = ('clean.%d.%d'):format(line.index, count),
						label = locale('underworld.menu.payClean', { count = count }),
						value = money(line.clean * count), icon = 'money', close = true,
						data = { verb = 'buy', index = line.index, count = count, pay = 'clean' } }
				end
			end
		end
		items[#items + 1] = { id = 'buy.' .. line.index, label = itemLabel(line.item), icon = 'box',
			value = (tonumber(line.qty) or 0) > 0 and locale('underworld.menu.inStock', { qty = line.qty })
				or locale('underworld.menu.soldOut'),
			items = #pays > 0 and pays or nil, disabled = #pays == 0 or nil }
	end
	for _, line in ipairs(type(view.buys) == 'table' and view.buys or {}) do
		local held = tonumber(line.held) or 0
		local sells = {}
		for _, count in ipairs({ 1, 5, held }) do
			if count > 0 and count <= held and (count ~= held or (held ~= 1 and held ~= 5)) then
				sells[#sells + 1] = { id = ('sell.%d.%d'):format(line.index, count),
					label = locale('underworld.menu.sellCount', { count = count }),
					value = money(line.price * count), icon = 'money', close = true,
					data = { verb = 'sell', index = line.index, count = count } }
			end
		end
		items[#items + 1] = { id = 'fence.' .. line.index,
			label = locale('underworld.menu.fence', { item = itemLabel(line.item) }), icon = 'money',
			value = money(line.price), items = #sells > 0 and sells or nil, disabled = #sells == 0 or nil }
	end
	openMenu(tostring(view.label or ''), items, function(data)
		if data.verb == 'buy' then
			TriggerServerEvent(M.Event.BUY, { dealer = view.dealer, index = data.index, count = data.count,
				pay = data.pay })
		elseif data.verb == 'sell' then
			TriggerServerEvent(M.Event.SELL, { dealer = view.dealer, index = data.index, count = data.count })
		end
	end)
end

local function frontMenu(view)
	local items = {}
	for _, amount in ipairs(type(view.amounts) == 'table' and view.amounts or {}) do
		items[#items + 1] = { id = 'launder.' .. amount, label = locale('underworld.menu.launder',
			{ amount = money(amount) }), value = money(math.floor(amount * (tonumber(view.rate) or 0) / 100)),
			icon = 'money', close = true, data = { verb = 'launder', amount = amount } }
	end
	local ready = 0
	for _, batch in ipairs(type(view.batches) == 'table' and view.batches or {}) do
		if (tonumber(batch.minutes) or 1) <= 0 then ready = ready + (tonumber(batch.clean) or 0) end
		items[#items + 1] = { id = 'batch.' .. #items, label = locale('underworld.menu.batch',
			{ clean = money(batch.clean) }), icon = 'clock',
			value = (tonumber(batch.minutes) or 0) <= 0 and locale('underworld.menu.ready')
				or locale('underworld.menu.minutes', { minutes = batch.minutes }), disabled = true }
	end
	items[#items + 1] = { id = 'collect', label = locale('underworld.menu.collect'), icon = 'money',
		value = money(ready), close = true, data = { verb = 'collect' }, disabled = ready <= 0 or nil }
	local title = locale('underworld.menu.frontTitle', { label = tostring(view.label or ''),
		rate = tonumber(view.rate) or 0, left = money(view.left) })
	openMenu(title, items, function(data)
		if data.verb == 'launder' then
			TriggerServerEvent(M.Event.LAUNDER, { front = view.front, amount = data.amount })
		elseif data.verb == 'collect' then
			TriggerServerEvent(M.Event.COLLECT, { front = view.front })
		end
	end)
end

local function dealOfferMenu(view)
	local items = {}
	for _, offer in ipairs(type(view.offers) == 'table' and view.offers or {}) do
		local rows = {}
		for _, count in ipairs(type(offer.counts) == 'table' and offer.counts or {}) do
			for _, price in ipairs(type(offer.prices) == 'table' and offer.prices or {}) do
				rows[#rows + 1] = { id = ('%s.%d.%d'):format(offer.item, count, price),
					label = locale('underworld.menu.offer', { count = count, price = money(price) }),
					value = money(price * count), icon = 'money', close = true,
					data = { item = offer.item, count = count, price = price * count } }
			end
		end
		items[#items + 1] = { id = 'offer.' .. tostring(offer.item), label = itemLabel(offer.item),
			value = locale('underworld.menu.held', { held = offer.held }), icon = 'box', items = rows }
	end
	openMenu(locale('underworld.menu.dealTitle'), items, function(data)
		TriggerServerEvent(M.Event.DEAL_OFFER, { target = view.target, item = data.item, count = data.count,
			price = data.price })
	end)
end

local function onView(view)
	if type(view) ~= 'table' then return end
	if view.kind == 'dealer' then return dealerMenu(view) end
	if view.kind == 'front' then return frontMenu(view) end
	if view.kind == 'deal' then return dealOfferMenu(view) end
end

-- ── an officer's alarm ──────────────────────────────────────────────────────

local function onAlert(payload)
	if type(payload) ~= 'table' then return end
	local label = type(payload.label) == 'string' and payload.label or ''
	local kind = type(payload.kind) == 'string' and payload.kind or 'crime'
	local x, y, z = OPX.Math.Finite(payload.x), OPX.Math.Finite(payload.y), OPX.Math.Finite(payload.z)
	OPX.Toast.Show({ id = 'opx.underworld.alert', kind = 'warning', title = locale('underworld.alert.title'),
		message = locale(x and 'underworld.alert.located' or 'underworld.alert.unlocated',
			{ label = label, what = locale(OPX.Locale.Exists('underworld.alert.' .. kind)
				and ('underworld.alert.' .. kind) or 'underworld.alert.crime') }),
		icon = 'warning', durationMs = 8000 })
	if x == nil or type(Open77.blips) ~= 'table' or type(Open77.blips.create) ~= 'function' then return end
	local read, id = pcall(Open77.blips.create, { position = { x = x, y = y, z = z or 0 },
		title = label, description = locale('underworld.alert.title'), active = true, routable = true })
	if read and type(id) == 'string' then
		pins[id] = OPX.Now() + (Model.Integer(payload.seconds, 5, 3600) or 90) * 1000
	end
end

local function sweepPins()
	local now = OPX.Now()
	for id, expiry in pairs(pins) do
		if now >= expiry then
			pins[id] = nil
			if type(Open77.blips) == 'table' and type(Open77.blips.remove) == 'function' then
				pcall(Open77.blips.remove, id)
			end
		end
	end
end

-- ── the eye ─────────────────────────────────────────────────────────────────

--- The entry of a list nearest to where the eye landed, within a radius.
local function nearest(context, list)
	local at = type(context) == 'table' and context.position or nil
	if type(at) ~= 'table' or not (OPX.Math.IsFinite(at.x) and OPX.Math.IsFinite(at.y)
		and OPX.Math.IsFinite(at.z)) then
		return nil
	end
	local best, bestGap = nil, math.huge
	for _, entry in ipairs(list) do
		local dx, dy, dz = at.x - entry.x, at.y - entry.y, at.z - entry.z
		local gap = math.sqrt(dx * dx + dy * dy + dz * dz)
		if gap <= entry.reach + 1 and gap < bestGap then best, bestGap = entry, gap end
	end
	return best
end

local function dealerOf(context)
	if type(context) ~= 'table' or type(context.target) ~= 'table' then return nil end
	local id = math.tointeger(context.target.npcId)
	if id == nil then return nil end
	local key = ('%d'):format(id)
	return dealers[key] ~= nil and key or nil
end

local function spheres(list)
	local out = {}
	for _, entry in ipairs(list) do
		out[#out + 1] = { x = entry.x, y = entry.y, z = entry.z, radius = math.min(10, entry.reach) }
	end
	return out
end

local function noted(result, what)
	if type(result) ~= 'table' or not result.ok then
		OPX.Note('underworld', ('the %s rows were refused: %s'):format(what,
			tostring(type(result) == 'table' and result.error or result)))
	end
end

local function registerRows()
	if target == nil then return end
	noted(target.RegisterNpcs(OWNER, {
		id = 'underworld.dealer', label = locale('underworld.row.dealer'), icon = 'talk', distance = 3.0,
		order = 6,
		canInteract = function(context) return dealerOf(context) ~= nil end,
		onSelect = function(context)
			local key = dealerOf(context)
			if key ~= nil then TriggerServerEvent(M.Event.DEALER, { npc = key }) end
		end,
	}), 'dealer')
	Wait(0)
	local street = built.street
	if street.enabled then
		noted(target.RegisterPlayers(OWNER, {
			id = 'underworld.deal', label = locale('underworld.row.deal'), icon = 'money',
			distance = street.startDistance, order = 30,
			onSelect = function(context)
				local subject = type(context) == 'table' and context.target or nil
				local id = type(subject) == 'table' and math.tointeger(tonumber(subject.playerId)) or nil
				if id ~= nil then TriggerServerEvent(M.Event.DEAL_MENU, { target = id }) end
			end,
		}), 'deal')
		Wait(0)
	end
	local kinds = {
		{ list = built.stores.list, id = 'underworld.rob', label = 'underworld.row.rob', icon = 'weapon',
			send = function(entry) TriggerServerEvent(M.Event.ROB, { store = entry.id }) end },
		{ list = built.fronts.list, id = 'underworld.front', label = 'underworld.row.front', icon = 'money',
			send = function(entry) TriggerServerEvent(M.Event.FRONT, { front = entry.id }) end },
		{ list = built.labs.list, id = 'underworld.lab', label = 'underworld.row.lab', icon = 'tool',
			send = function(entry)
				local crafting = OPX.Api.Get('crafting')
				if crafting == nil then return OPX.Toast.Locale('underworld.error.unavailable', nil, 'error') end
				crafting.Open(M.BENCH_PREFIX .. entry.id)
			end },
	}
	for _, kind in ipairs(kinds) do
		if #kind.list > 0 then
			noted(target.RegisterSpheres(OWNER, spheres(kind.list), {
				id = kind.id, label = locale(kind.label), icon = kind.icon, distance = built.reach, order = 20,
				onSelect = function(context)
					local entry = nearest(context, kind.list)
					if entry ~= nil then kind.send(entry) end
				end,
			}), kind.id)
			Wait(0)
		end
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	target, dealers, pins = nil, {}, {}
	built = nil
end

--- The surveyed points of one config list: id, position, reach. A few per resume.
--
-- NOT `Model.Build`, ON PURPOSE. The full read validates every field and costs
-- ~1,000 instructions per entry (5,500 for the four shipped stores once
-- surveyed); the eye only needs where to put a sphere, and the server checks
-- everything else when the row is pressed. The 0, 0, 0 rule is the model's own
-- (`Model.PointOf`), so a placeholder has no sphere here either.
local function spotsOf(list, reach)
	local out = {}
	for index, row in ipairs(type(list) == 'table' and list or {}) do
		if type(row) == 'table' and type(row.ID) == 'string' and row.ID:match(Model.ID) then
			local point = Model.PointOf(row)
			if point ~= nil then
				out[#out + 1] = { id = row.ID, x = point.x, y = point.y, z = point.z,
					reach = Model.Bounded(row.REACH, 0.5, 20, reach) }
			end
		end
		if index % 4 == 0 then Wait(0) end
	end
	return { list = out }
end

--- What the eye needs from the config, read over several resumes.
local function buildParts()
	local settings = type(M.Settings) == 'table' and M.Settings or {}
	local reach = Model.Bounded(settings.REACH, 0.5, 20, 2.5)
	local street = type(settings.STREET) == 'table' and settings.STREET or {}
	local whole = { reach = reach, street = {
		enabled = street.ENABLED ~= false and type(street.ITEMS) == 'table' and next(street.ITEMS) ~= nil,
		startDistance = Model.Bounded(street.START_DISTANCE, 0.25, 10, 2.5),
	} }
	whole.stores = spotsOf(type(settings.ROBBERIES) == 'table' and settings.ROBBERIES.STORES, reach)
	Wait(0)
	whole.fronts = spotsOf(type(settings.LAUNDERING) == 'table' and settings.LAUNDERING.FRONTS, reach)
	Wait(0)
	whole.labs = spotsOf(settings.LABS, reach)
	Wait(0)
	return whole
end

--- Wires the answers and puts the rows on the world.
-- @author dop42
function M.Start()
	target = OPX.Api.Get('target')
	RegisterNetEvent(M.Event.ANSWER, onAnswer)
	RegisterNetEvent(M.Event.VIEW, onView)
	RegisterNetEvent(M.Event.ALERT, onAlert)
	RegisterNetEvent(M.Event.DEALERS, function(list)
		if type(list) ~= 'table' then return end
		local fresh = {}
		for _, row in ipairs(list) do
			if type(row) == 'table' and type(row.npc) == 'string' and row.npc:match('^%d+$') then
				fresh[row.npc] = { dealer = tostring(row.dealer or ''), label = tostring(row.label or '') }
			end
		end
		dealers = fresh
	end)
	if target == nil then
		Open77.log.warn('[underworld] no target contract: nothing illegal can be reached from the eye')
	end
	pinJob = OPX.Scheduler.Every('underworld:pins', 5000, sweepPins)
	CreateThread(function()
		Wait(0)
		built = buildParts()
		M.Built = built
		registerRows()
		TriggerServerEvent(M.Event.HELLO)
	end)
end

--- Takes the rows and the pins down.
-- @author dop42
function M.Stop()
	if target ~= nil and type(target.Clear) == 'function' then pcall(target.Clear, OWNER) end
	if pinJob ~= nil and OPX.Scheduler.Cancel then pcall(OPX.Scheduler.Cancel, pinJob) end
	for id in pairs(pins) do
		if type(Open77.blips) == 'table' and type(Open77.blips.remove) == 'function' then pcall(Open77.blips.remove, id) end
	end
	pins = {}
end
