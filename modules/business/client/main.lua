--- Client half: the HR terminal on screen, the office rows, the contract offer.
-- @author dop42
--
-- NOTHING HERE DECIDES. The server sends the terminal already judged -- which
-- employee this boss may fire, promote, demote or clock, whether the treasury
-- is theirs to move -- and this half draws it with `menu` and `form`, puts an
-- ALT row on every surveyed office and one on players (recruit), and sends back
-- the verb the boss chose. Every request is judged again on the server; the
-- client-side checks below only decide which rows are worth showing.
--
-- THE CLIENT BUDGET. The office rows are registered on a thread a few spheres
-- at a time; a terminal is built on a thread, a few employees per resume, and
-- opened paced (`yield = true`); a menu holds 200 rows, so the roster is cut to
-- what fits and the rest is counted on one row.

local M = OPX.Modules.Get('business')
local Access, Verb = M.Access, M.Verb

local OWNER = 'business'
local MENU_ID = 'business.terminal'
local NEARBY_ID = 'business.nearby'
local OFFER_ID = 'business.offer'
local CHOOSE_ID = 'business.choose'
local FORM_ID = 'business.amount'

-- Spheres per eye row, and employees built per resume.
local SPHERES_PER_ROW = 8
local PER_RESUME = 4
-- The rows a terminal may spend, under the menu's ceiling of 200.
local ROW_BUDGET = 180

local target, menu, form = nil, nil, nil
-- The offer on screen: `{ id, handle }`, or nil.
local offer = nil

local function money(amount) return OPX.Locale.Money(amount, Access.POCKET) end

local function playerData()
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetPlayerData) ~= 'function' then return nil end
	local ok, data = pcall(api.GetPlayerData)
	return ok and type(data) == 'table' and data or nil
end

--- The groups this player may open the terminal for, as the server would judge
--- them from the same snapshot. A filter for rows, never a permission.
local function desks() return Access.Desks(playerData()) end

local function hasDesk(kind, key)
	for _, desk in ipairs(desks()) do
		if desk.kind == kind and desk.key == key then return true end
	end
	return false
end

local function hiringDesks()
	local out = {}
	for _, desk in ipairs(desks()) do
		if Access.MayHire(desk.kind, desk.key, desk.level) then out[#out + 1] = desk end
	end
	return out
end

local function act(verb, kind, key, extra)
	local payload = { verb = verb, kind = kind, key = key }
	for name, value in pairs(extra or {}) do payload[name] = value end
	TriggerServerEvent(M.Event.ACT, payload)
end

local function opened(answer, what)
	if type(answer) == 'table' and answer.ok then return answer.value end
	OPX.Toast.Locale('business.noScreen', nil, 'error')
	OPX.Note('business', ('the %s was refused: %s'):format(what,
		tostring(type(answer) == 'table' and answer.error or answer)))
	return nil
end

-- ── the amount form ─────────────────────────────────────────────────────────

local function askAmount(verb, kind, key, label)
	if form == nil then return OPX.Toast.Locale('business.noScreen', nil, 'error') end
	opened(form.Open({
		owner = OWNER, id = FORM_ID,
		title = locale(verb == Verb.DEPOSIT and 'business.form.deposit' or 'business.form.withdraw'),
		description = locale('business.form.description', { label = label,
			max = money(Access.MAX_AMOUNT) }),
		fields = {
			{ id = 'amount', label = locale('business.form.amount'), required = true,
				charset = 'digits', maxLength = 9 },
		},
		on = function(answer)
			if type(answer) ~= 'table' or answer.action ~= 'submit' then return end
			local values = type(answer.values) == 'table' and answer.values or {}
			act(verb, kind, key, { amount = values.amount })
		end,
	}), 'form')
end

-- ── the terminal ────────────────────────────────────────────────────────────

local function onMenu(payload)
	local data = type(payload) == 'table' and payload.data or nil
	if type(data) ~= 'table' or type(data.verb) ~= 'string' then return end
	if data.verb == 'askDeposit' then return askAmount(Verb.DEPOSIT, data.kind, data.key, data.label) end
	if data.verb == 'askWithdraw' then return askAmount(Verb.WITHDRAW, data.kind, data.key, data.label) end
	act(data.verb, data.kind, data.key, { citizenId = data.citizenId, target = data.target })
end

--- One employee as a sub-screen: who, and what this boss may do to them.
local function employeeRow(prefix, desk, row)
	local base = { kind = desk.kind, key = desk.key, citizenId = row.citizenId }
	local function verb(name)
		local copy = { verb = name }
		for field, value in pairs(base) do copy[field] = value end
		return copy
	end
	local status = row.online and (row.onDuty and locale('business.menu.onDuty')
		or locale('business.menu.online')) or locale('business.menu.offline')
	local items = {
		{ id = prefix .. '.status', label = locale('business.menu.status'), value = status,
			icon = 'info', disabled = true },
	}
	if row.promote then
		items[#items + 1] = { id = prefix .. '.promote', label = locale('business.act.promote'),
			icon = 'plus', data = verb(Verb.PROMOTE), close = true }
	end
	if row.demote then
		items[#items + 1] = { id = prefix .. '.demote', label = locale('business.act.demote'),
			icon = 'minus', data = verb(Verb.DEMOTE), close = true }
	end
	if row.duty then
		items[#items + 1] = { id = prefix .. '.duty', label = locale(row.onDuty and 'business.act.clockOut'
			or 'business.act.clockIn'), icon = 'clock', data = verb(Verb.DUTY), close = true }
	end
	if row.fire then
		items[#items + 1] = { id = prefix .. '.fire', label = locale('business.act.fire'), icon = 'trash',
			data = verb(Verb.FIRE), close = true, confirm = true }
	end
	local label = row.self and locale('business.menu.you', { name = row.name }) or row.name
	return { id = prefix, label = OPX.Text.Clean(label, 48), value = row.gradeName,
		icon = row.online and 'person' or 'hidden', description = status, items = items }, #items + 2
end

--- One desk's rows, spending at most `budget`. Answers the rows and the cost.
local function deskItems(prefix, desk, budget)
	local items, spent = {}, 0
	local function add(row, cost) items[#items + 1] = row spent = spent + (cost or 1) end
	local id = { kind = desk.kind, key = desk.key, label = desk.label }

	add({ id = prefix .. '.who', label = locale('business.menu.who'), value = desk.gradeName,
		icon = 'person', disabled = true,
		description = locale('business.menu.whoHint', { label = desk.label }) })

	if desk.balance ~= nil then
		add({ id = prefix .. '.balance', label = locale('business.menu.balance'),
			value = money(desk.balance), icon = 'money', disabled = true })
		if desk.bankAuth then
			add({ id = prefix .. '.deposit', label = locale('business.act.deposit'), icon = 'plus',
				data = { verb = 'askDeposit', kind = id.kind, key = id.key, label = id.label }, close = true })
			add({ id = prefix .. '.withdraw', label = locale('business.act.withdraw'), icon = 'minus',
				data = { verb = 'askWithdraw', kind = id.kind, key = id.key, label = id.label }, close = true })
		end
		local lines = {}
		for index, line in ipairs(type(desk.history) == 'table' and desk.history or {}) do
			lines[index] = { id = ('%s.h.%d'):format(prefix, index),
				label = (line.amount >= 0 and '+' or '-') .. money(math.abs(line.amount)),
				value = OPX.Text.Clean(line.reason, 32), disabled = true }
		end
		if #lines > 0 then
			add({ id = prefix .. '.history', label = locale('business.menu.history'), icon = 'list',
				value = tostring(#lines), items = lines }, #lines + 1)
		end
	end

	local staff = {}
	local cost = 1
	local employees = type(desk.employees) == 'table' and desk.employees or {}
	for index, row in ipairs(employees) do
		if index % PER_RESUME == 0 then Wait(0) end
		local entry, rows = employeeRow(('%s.e.%d'):format(prefix, index), desk, row)
		if spent + cost + rows > budget - 3 then
			staff[#staff + 1] = { id = prefix .. '.more', label = locale('business.menu.more',
				{ count = #employees - index + 1 }), disabled = true }
			cost = cost + 1
			break
		end
		staff[#staff + 1] = entry
		cost = cost + rows
	end
	local hidden = (desk.count or #employees) - #employees
	if hidden > 0 then
		staff[#staff + 1] = { id = prefix .. '.hidden', label = locale('business.menu.more',
			{ count = hidden }), disabled = true }
		cost = cost + 1
	end
	if #staff == 0 then
		staff[1] = { id = prefix .. '.none', label = locale('business.menu.nobody'), disabled = true }
	end
	local headcount = desk.max ~= nil and desk.max > 0
		and ('%d/%d'):format(desk.count or #employees, desk.max) or tostring(desk.count or #employees)
	add({ id = prefix .. '.staff', label = locale('business.menu.staff'), icon = 'folder',
		value = headcount, items = staff }, cost)

	if desk.mayHire then
		add({ id = prefix .. '.recruit', label = locale('business.act.recruit'), icon = 'interact',
			description = locale('business.menu.recruitHint'),
			data = { verb = Verb.NEARBY, kind = id.kind, key = id.key }, close = true })
	end
	return items, spent
end

local function buildTerminal(payload)
	local list = type(payload.desks) == 'table' and payload.desks or {}
	if #list == 0 then return end
	local items
	local title = locale('business.menu.title')
	if #list == 1 then
		items = deskItems('d1', list[1], ROW_BUDGET)
		title = locale('business.menu.titleOf', { label = list[1].label })
	else
		items = {}
		local share = ROW_BUDGET // #list
		for index, desk in ipairs(list) do
			local rows = deskItems('d' .. index, desk, share)
			items[#items + 1] = { id = 'd' .. index, label = desk.label, value = desk.gradeName,
				icon = desk.kind == 'gang' and 'flag' or 'server', items = rows }
		end
	end
	opened(menu.Open({
		owner = OWNER, id = MENU_ID, steal = true,
		title = title,
		items = items,
		on = onMenu,
		yield = true,
	}), 'terminal')
end

local function showTerminal(payload)
	if menu == nil or type(payload) ~= 'table' then
		return OPX.Toast.Locale('business.noScreen', nil, 'error')
	end
	CreateThread(function() buildTerminal(payload) end)
end

local function showNearby(payload)
	if menu == nil or type(payload) ~= 'table' then return end
	local items = {}
	for index, row in ipairs(type(payload.rows) == 'table' and payload.rows or {}) do
		if index > 12 then break end
		local id = math.tointeger(tonumber(row.target))
		if id ~= nil then
			items[#items + 1] = { id = 'n' .. index, label = locale('business.nearby.row', { id = id }),
				value = locale('business.nearby.metres', { metres = tostring(row.metres) }), icon = 'person',
				data = { verb = Verb.HIRE, kind = payload.kind, key = payload.key, target = id }, close = true }
		end
	end
	if #items == 0 then
		items[1] = { id = 'none', label = locale('business.nearby.nobody'), disabled = true }
	end
	opened(menu.Open({ owner = OWNER, id = NEARBY_ID, steal = true,
		title = locale('business.nearby.title'), items = items, on = onMenu }), 'nearby list')
end

-- ── the offer, on the recruit's screen ──────────────────────────────────────

local function showOffer(payload)
	if type(payload) ~= 'table' then return end
	local id = math.tointeger(tonumber(payload.id))
	if id == nil then return end
	if payload.closed then
		if offer ~= nil and offer.id == id then
			if menu ~= nil and offer.handle ~= nil then pcall(menu.Close, offer.handle, 'lapsed') end
			offer = nil
		end
		return
	end
	OPX.Toast.Locale('business.offer.incoming', { label = OPX.Text.Clean(payload.label, 48),
		grade = OPX.Text.Clean(payload.grade, 32) }, 'info')
	if menu == nil then return OPX.Toast.Locale('business.noScreen', nil, 'error') end
	local shown = opened(menu.Open({
		owner = OWNER, id = OFFER_ID, steal = true,
		title = locale('business.offer.title'),
		items = {
			{ id = 'who', label = OPX.Text.Clean(payload.label, 48), value = OPX.Text.Clean(payload.grade, 32),
				icon = 'server', disabled = true,
				description = locale('business.offer.from', { boss = OPX.Text.Clean(payload.boss, 48),
					seconds = math.tointeger(payload.ttl) or 0 }) },
			{ id = 'yes', label = locale('business.offer.accept'), icon = 'interact',
				data = { answer = true }, close = true },
			{ id = 'no', label = locale('business.offer.decline'), icon = 'ban',
				data = { answer = false }, close = true },
		},
		on = function(answer)
			local data = type(answer) == 'table' and answer.data or nil
			if type(data) ~= 'table' or type(data.answer) ~= 'boolean' then return end
			offer = nil
			TriggerServerEvent(M.Event.ANSWER, { id = id, accept = data.answer })
		end,
	}), 'offer')
	offer = { id = id, handle = shown and shown.handle or nil }
end

-- ── the eye ─────────────────────────────────────────────────────────────────

local function targetOf(context)
	local hit = type(context) == 'table' and context.target or nil
	if type(hit) ~= 'table' then return nil end
	local id = math.tointeger(tonumber(hit.playerId))
	return id and id > 0 and id or nil
end

local function recruit(id)
	local list = hiringDesks()
	if #list == 0 then return false end
	if #list == 1 or menu == nil then
		act(Verb.HIRE, list[1].kind, list[1].key, { target = id })
		return true
	end
	local items = {}
	for index, desk in ipairs(list) do
		items[index] = { id = 'c' .. index, label = Access.Label(desk.kind, desk.key), icon = 'interact',
			data = { verb = Verb.HIRE, kind = desk.kind, key = desk.key, target = id }, close = true }
	end
	opened(menu.Open({ owner = OWNER, id = CHOOSE_ID, steal = true,
		title = locale('business.act.recruit'), items = items, on = onMenu }), 'choice')
	return true
end

--- The recruit row on players, and one row per group over its offices. On a
--- thread: a server with many surveyed offices is many spheres.
local function registerRows()
	if target == nil then
		OPX.Note('business', 'no target contract: no office or recruit rows; /opx.boss still works')
		return
	end
	local placed = target.RegisterPlayers(OWNER, { {
		id = 'business.recruit', label = locale('business.row.recruit'), icon = 'interact', order = 40,
		distance = Access.HIRE_RADIUS,
		canInteract = function(context) return targetOf(context) ~= nil and #hiringDesks() > 0 end,
		onSelect = function(context)
			local id = targetOf(context)
			if id == nil then return false end
			return recruit(id)
		end,
	} })
	if type(placed) ~= 'table' or not placed.ok then
		OPX.Note('business', ('the recruit row was refused: %s'):format(tostring(type(placed) == 'table'
			and placed.error or placed)))
	end

	local groups, order = {}, {}
	for _, entry in ipairs(Access.AllOffices()) do
		local name = entry.kind .. ':' .. entry.key
		if groups[name] == nil then
			groups[name] = { kind = entry.kind, key = entry.key, offices = {} }
			order[#order + 1] = name
		end
		table.insert(groups[name].offices, entry.office)
	end
	for _, name in ipairs(order) do
		local group = groups[name]
		local offices = group.offices
		for first = 1, #offices, SPHERES_PER_ROW do
			Wait(0)
			local spheres = {}
			local last = math.min(#offices, first + SPHERES_PER_ROW - 1)
			for index = first, last do
				local office = offices[index]
				spheres[#spheres + 1] = { x = office.x, y = office.y, z = office.z, radius = office.radius }
			end
			local kind, key = group.kind, group.key
			local rows = target.RegisterSpheres(OWNER, spheres, {
				id = ('business.office.%s.%s.%d'):format(kind, key, first),
				label = locale('business.row.office', { label = Access.Label(kind, key) }),
				icon = 'server', order = 30, distance = offices[first].radius,
				canInteract = function() return hasDesk(kind, key) end,
				onSelect = function(context)
					-- The nearest office of this row; the server measures it again.
					local best, bestGap = offices[first].index, nil
					local hit = type(context) == 'table' and context.position or nil
					if type(hit) == 'table' then
						for index = first, last do
							local office = offices[index]
							local gap = (office.x - hit.x) ^ 2 + (office.y - hit.y) ^ 2 + (office.z - hit.z) ^ 2
							if bestGap == nil or gap < bestGap then best, bestGap = office.index, gap end
						end
					end
					TriggerServerEvent(M.Event.OPEN, { kind = kind, key = key, office = best })
					return true
				end,
			})
			if type(rows) ~= 'table' or not rows.ok then
				OPX.Note('business', ('the %s office rows were refused: %s'):format(name,
					tostring(type(rows) == 'table' and rows.error or rows)))
			end
		end
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Resets the state.
-- @author dop42
function M.Init()
	offer = nil
end

--- Reads the contracts it draws with, registers the rows and the listeners.
-- @author dop42
function M.Start()
	target, menu, form = OPX.Api.Get('target'), OPX.Api.Get('menu'), OPX.Api.Get('form')
	RegisterNetEvent(M.Event.SHOW, showTerminal)
	RegisterNetEvent(M.Event.NEARBY, showNearby)
	RegisterNetEvent(M.Event.OFFER, showOffer)
	CreateThread(registerRows)
end

--- Takes the rows back.
-- @author dop42
function M.Stop()
	if target ~= nil then pcall(target.Clear, OWNER) end
	offer = nil
end
