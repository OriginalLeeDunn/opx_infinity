--- Client half: the board and the form on screen, the NPC rows, the waypoint.
-- @author dop42
--
-- NOTHING HERE DECIDES. The server sends the board already filtered for this
-- player, the form's choices already bounded for their grade, and the gig they
-- are working with its waypoint; this half draws them with `menu` and `form`,
-- puts two rows on the target eye (a fixer NPC opens the board, a drop-off NPC
-- takes the package) and sends back what the player chose. Every request is
-- re-judged on the server.
--
-- THE CLIENT BUDGET. A board is at most BOARD_LIMIT gigs in three short lists,
-- built once per open; the eye rows are two, registered once, filtered by a
-- table lookup on the NPC id the server pushed. No loop runs every frame.

local M = OPX.Modules.Get('contracts')

local OWNER = 'contracts'
local MENU_ID = 'contracts.board'
local FORM_ID = 'contracts.post'

-- NPC id (decimal string) -> { kind, key, label }, pushed whole by the server.
local npcs = {}
-- The gig this player is working, as the server last said, or nil.
local active = nil
-- Whether this module put the current waypoint there.
local waypointSet = false
local tokens = {}
local target, menu, form = nil, nil, nil

local function money(amount, currency) return OPX.Locale.Money(amount, currency) end

-- ── the waypoint ────────────────────────────────────────────────────────────

local function setWaypoint(point)
	local blips = Open77.blips
	if type(blips) ~= 'table' or type(blips.setWaypoint) ~= 'function' or type(point) ~= 'table' then
		return
	end
	local ok, placed, why = pcall(blips.setWaypoint, { x = point.x, y = point.y, z = point.z })
	if ok and placed then
		waypointSet = true
	else
		OPX.Note('contracts', ('the waypoint was refused: %s'):format(tostring(ok and why or placed)))
	end
end

local function clearWaypoint()
	if not waypointSet then return end
	waypointSet = false
	local blips = Open77.blips
	if type(blips) == 'table' and type(blips.clearWaypoint) == 'function' then
		pcall(blips.clearWaypoint)
	end
end

-- ── the eye ─────────────────────────────────────────────────────────────────

local function npcOf(context)
	if type(context) ~= 'table' or type(context.target) ~= 'table' then return nil, nil end
	local id = math.tointeger(context.target.npcId)
	if id == nil then return nil, nil end
	local key = ('%d'):format(id)
	return npcs[key], key
end

local function registerRows()
	if target == nil then return end
	local board = target.RegisterNpcs(OWNER, {
		id = 'contracts.board',
		label = locale('contracts.row.board'),
		icon = 'folder',
		distance = 3.0,
		canInteract = function(context)
			local npc = npcOf(context)
			return npc ~= nil and npc.kind == 'fixer'
		end,
		onSelect = function() TriggerServerEvent(M.Event.BOARD) end,
		order = 4,
	})
	if board.ok then tokens[#tokens + 1] = board.value.token end
	local drop = target.RegisterNpcs(OWNER, {
		id = 'contracts.deliver',
		label = locale('contracts.row.deliver'),
		icon = 'box',
		distance = 3.0,
		canInteract = function(context)
			local npc = npcOf(context)
			return npc ~= nil and npc.kind == 'dropoff' and active ~= nil
				and active.type == 'deliver_item'
		end,
		onSelect = function(context)
			local _, key = npcOf(context)
			if key ~= nil then TriggerServerEvent(M.Event.DELIVER, { npc = key }) end
		end,
		order = 4,
	})
	if drop.ok then tokens[#tokens + 1] = drop.value.token end
	if not board.ok or not drop.ok then
		OPX.Note('contracts', ('an eye row was refused: %s'):format(tostring(board.error or drop.error)))
	end
end

-- ── the board ───────────────────────────────────────────────────────────────

local function act(verb, id) return { verb = verb, id = id } end

--- One gig as a submenu: its details, then what this player may do with it.
local function gigRow(prefix, gig, currency, actions)
	-- TWO READ-ONLY ROWS AND THE ACTIONS, no more: a board of BOARD_LIMIT gigs
	-- has to fit the menu's 200-row ceiling with room for the rest.
	local where = gig.district or gig.target
	local items = {
		{ id = prefix .. '.fixer', label = gig.poster or '?',
			value = locale('contracts.type.' .. tostring(gig.type)), icon = 'person', disabled = true,
			description = where and locale('contracts.board.whereIs', { place = where }) or nil },
		{ id = prefix .. '.pay', label = locale('contracts.board.pay'),
			value = money(gig.pay, currency), icon = 'money', disabled = true,
			description = locale('contracts.board.split', { reward = money(gig.reward, currency),
				cut = gig.cutPct }) },
	}
	if gig.state ~= nil and gig.state ~= 'posted' then
		items[#items + 1] = { id = prefix .. '.state', label = locale('contracts.board.state'),
			value = locale('contracts.state.' .. tostring(gig.state)), disabled = true }
	end
	for _, row in ipairs(actions) do items[#items + 1] = row end
	return {
		id = prefix, label = gig.title, value = money(gig.pay, currency),
		description = gig.brief, icon = 'tag', items = items,
	}
end

local function onMenu(payload)
	local data = type(payload) == 'table' and payload.data or nil
	if type(data) ~= 'table' or type(data.verb) ~= 'string' then return end
	if data.verb == 'form' then
		TriggerServerEvent(M.Event.FORM)
	else
		TriggerServerEvent(M.Event.ACT, { verb = data.verb, id = data.id })
	end
end

-- Gigs built per resume before the board yields a frame, and the most of each
-- side list a board draws: the menu holds 200 rows, and the open gigs come first.
local PER_RESUME = 4
local SIDE_LIST = 6

--- Builds the board ON A THREAD, a few gigs a resume, and opens it paced
--- (`yield = true`): thirty gigs in one go cost several times the budget a
--- client resume may spend, and an overrun is killed without a word.
local function buildBoard(board)
	local currency = board.currency
	local items = {
		{ id = 'cred', label = locale('contracts.board.cred', { cred = board.cred or 0,
			tier = board.tier or '?' }), icon = 'star', disabled = true,
			value = locale('contracts.board.record', { done = board.done or 0,
				failed = board.failed or 0 }),
			description = board.nextCred and locale('contracts.board.next',
				{ cred = board.nextCred }) or nil },
	}

	local mine = board.mine
	if type(mine) == 'table' then
		local actions = {}
		if mine.type == 'deliver_item' and mine.state == 'in_progress' then
			actions[#actions + 1] = { id = 'mine.deliver', label = locale('contracts.act.deliver'),
				icon = 'box', data = act('deliver', mine.id), close = true }
		end
		if mine.type == 'manual' and mine.state == 'in_progress' then
			actions[#actions + 1] = { id = 'mine.report', label = locale('contracts.act.report'),
				icon = 'flag', data = act('report', mine.id), close = true }
		end
		actions[#actions + 1] = { id = 'mine.waypoint', label = locale('contracts.act.waypoint'),
			icon = 'map', data = act('waypoint', mine.id), close = true }
		if mine.state ~= 'proof' then
			actions[#actions + 1] = { id = 'mine.abandon', label = locale('contracts.act.abandon'),
				icon = 'trash', data = act('abandon', mine.id), close = true, confirm = true }
		end
		local row = gigRow('mine', mine, currency, actions)
		row.label = locale('contracts.board.mine', { title = mine.title })
		row.value = locale('contracts.board.minutes', { minutes = math.ceil((mine.secondsLeft or 0) / 60) })
		row.icon = 'clock'
		items[#items + 1] = row
	end

	if board.isTaker then
		local gigs = {}
		for index, gig in ipairs(board.rows or {}) do
			if index % PER_RESUME == 0 then Wait(0) end
			local prefix = 'gig.' .. tostring(gig.id)
			gigs[index] = gigRow(prefix, gig, currency, {
				{ id = prefix .. '.accept', label = locale('contracts.act.accept'), icon = 'interact',
					data = act('accept', gig.id), close = true },
			})
		end
		if #gigs == 0 then
			gigs[1] = { id = 'gigs.empty', label = locale('contracts.board.empty'), disabled = true }
		end
		items[#items + 1] = { id = 'gigs', label = locale('contracts.board.open'), icon = 'list',
			value = tostring(#(board.rows or {})), items = gigs }
	end

	if board.isPoster then
		items[#items + 1] = { id = 'post', label = locale('contracts.board.post'), icon = 'plus',
			data = { verb = 'form' }, close = true }
		local posted = {}
		for index, gig in ipairs(board.posted or {}) do
			if index > SIDE_LIST then break end
			if index % PER_RESUME == 0 then Wait(0) end
			local prefix = 'post.' .. tostring(gig.id)
			local actions = {}
			if gig.state == 'posted' then
				actions[1] = { id = prefix .. '.cancel', label = locale('contracts.act.cancel'),
					icon = 'trash', data = act('cancel', gig.id), close = true, confirm = true }
			end
			posted[index] = gigRow(prefix, gig, currency, actions)
			posted[index].value = locale('contracts.state.' .. tostring(gig.state))
		end
		if #posted > 0 then
			items[#items + 1] = { id = 'posted', label = locale('contracts.board.posted'),
				icon = 'folder', value = tostring(#posted), items = posted }
		end
	end

	local review = {}
	for index, gig in ipairs(board.review or {}) do
		if index > SIDE_LIST then break end
		if index % PER_RESUME == 0 then Wait(0) end
		local prefix = 'review.' .. tostring(gig.id)
		review[index] = gigRow(prefix, gig, currency, {
			{ id = prefix .. '.validate', label = locale('contracts.act.validate'), icon = 'money',
				data = act('validate', gig.id), close = true, confirm = true },
			{ id = prefix .. '.reject', label = locale('contracts.act.reject'), icon = 'ban',
				data = act('reject', gig.id), close = true, confirm = true },
		})
	end
	if #review > 0 then
		items[#items + 1] = { id = 'review', label = locale('contracts.board.review'),
			icon = 'eye', value = tostring(#review), items = review }
	end

	local opened = menu.Open({
		owner = OWNER, id = MENU_ID, steal = true,
		title = locale('contracts.board.title'),
		items = items,
		on = onMenu,
		yield = true,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Toast.Locale('contracts.noScreen', nil, 'error')
		OPX.Note('contracts', ('the board was refused: %s'):format(
			tostring(type(opened) == 'table' and opened.error or opened)))
	end
end

local function showBoard(board)
	if menu == nil or type(board) ~= 'table' then
		return OPX.Toast.Locale('contracts.noScreen', nil, 'error')
	end
	CreateThread(function() buildBoard(board) end)
end

-- ── the form ────────────────────────────────────────────────────────────────

local function duration(seconds)
	if seconds % 3600 == 0 then return locale('contracts.form.hours', { hours = seconds // 3600 }) end
	return locale('contracts.form.minutes', { minutes = math.ceil(seconds / 60) })
end

local function showForm(choices)
	if form == nil or type(choices) ~= 'table' then
		return OPX.Toast.Locale('contracts.noScreen', nil, 'error')
	end
	local typeOptions = {}
	for _, name in ipairs(choices.types or {}) do
		typeOptions[#typeOptions + 1] = { label = locale('contracts.type.' .. name), value = name }
	end
	local targetOptions = {}
	for _, row in ipairs(choices.targets or {}) do
		local label = row.kind == 'none' and locale('contracts.target.none')
			or (row.district and ('%s (%s)'):format(row.label, row.district) or row.label)
		targetOptions[#targetOptions + 1] = { label = OPX.Text.Clean(label, 48), value = row.value }
	end
	if #typeOptions == 0 or #targetOptions == 0 then
		return OPX.Toast.Locale('contracts.refused.no_targets', nil, 'error')
	end
	local cutOptions, cutSelected = {}, 1
	local cut = choices.cut or {}
	for pct = cut.low or 0, cut.high or 0, math.max(1, cut.step or 5) do
		cutOptions[#cutOptions + 1] = { label = ('%d%%'):format(pct), value = pct }
		if pct <= (cut.default or 0) then cutSelected = #cutOptions end
		if #cutOptions >= 64 then break end
	end
	if #cutOptions == 0 then cutOptions[1] = { label = ('%d%%'):format(cut.low or 0), value = cut.low or 0 } end
	local deadlineOptions, deadlineSelected = {}, 1
	for index, seconds in ipairs(choices.deadlines or {}) do
		deadlineOptions[index] = { label = duration(seconds), value = seconds }
		if seconds == choices.deadline then deadlineSelected = index end
	end
	if #deadlineOptions == 0 then deadlineOptions[1] = { label = duration(3600), value = 3600 } end
	local tierOptions = {}
	for index, tier in ipairs(choices.tiers or {}) do
		tierOptions[index] = { label = OPX.Text.Clean(('%s (%d+)'):format(tier.label, tier.min), 48),
			value = index }
	end
	local reward = choices.reward or {}
	local opened = form.Open({
		owner = OWNER, id = FORM_ID,
		title = locale('contracts.form.title'),
		description = locale('contracts.form.description', {
			min = money(reward.min or 0, choices.currency), max = money(reward.max or 0, choices.currency),
			fee = money(choices.fee or 0, choices.currency) }),
		fields = {
			{ id = 'type', label = locale('contracts.form.type'), options = typeOptions },
			{ id = 'target', label = locale('contracts.form.target'), options = targetOptions },
			{ id = 'title', label = locale('contracts.form.titleField'), required = true,
				maxLength = choices.titleMax or 64 },
			{ id = 'brief', label = locale('contracts.form.brief'),
				maxLength = math.max(1, choices.briefMax or 160) },
			{ id = 'reward', label = locale('contracts.form.reward'), required = true,
				charset = 'digits', maxLength = 9, placeholder = tostring(reward.min or '') },
			{ id = 'cut', label = locale('contracts.form.cut'), options = cutOptions,
				selected = cutSelected },
			{ id = 'deadline', label = locale('contracts.form.deadline'), options = deadlineOptions,
				selected = deadlineSelected },
			{ id = 'tier', label = locale('contracts.form.tier'), options = tierOptions },
		},
		on = function(answer)
			if type(answer) ~= 'table' or answer.action ~= 'submit' then return end
			local values = type(answer.values) == 'table' and answer.values or {}
			TriggerServerEvent(M.Event.POST, {
				type = values.type, target = values.target, title = values.title,
				brief = values.brief, reward = values.reward, cut = values.cut,
				deadline = values.deadline, tier = values.tier,
			})
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Toast.Locale('contracts.noScreen', nil, 'error')
		OPX.Note('contracts', ('the form was refused: %s'):format(
			tostring(type(opened) == 'table' and opened.error or opened)))
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Reads the contracts it draws with, registers the rows and says hello.
-- @author dop42
function M.Start()
	target, menu, form = OPX.Api.Get('target'), OPX.Api.Get('menu'), OPX.Api.Get('form')
	registerRows()

	RegisterNetEvent(M.Event.NPCS, function(list)
		if type(list) ~= 'table' then return end
		local fresh = {}
		for index = 1, math.min(#list, 256) do
			local row = list[index]
			if type(row) == 'table' and type(row.npc) == 'string' then
				fresh[row.npc] = { kind = row.kind, key = row.key, label = row.label }
			end
		end
		npcs = fresh
	end)

	RegisterNetEvent(M.Event.ACTIVE, function(payload)
		local before = active
		active = type(payload) == 'table' and payload or nil
		if active == nil then
			clearWaypoint()
			return
		end
		local fresh = before == nil or before.id ~= active.id
		if type(active.waypoint) == 'table' then setWaypoint(active.waypoint) end
		if fresh and active.target ~= nil then
			OPX.Toast.Locale('contracts.go', { place = active.target }, 'info')
		end
	end)

	RegisterNetEvent(M.Event.SHOW_BOARD, showBoard)
	RegisterNetEvent(M.Event.SHOW_FORM, showForm)

	AddEventHandler(OPX.Modules.Get('character').Event.ON_LOADED, function()
		TriggerServerEvent(M.Event.HELLO)
	end)
	TriggerServerEvent(M.Event.HELLO)
end

--- Takes the rows and the waypoint back.
-- @author dop42
function M.Stop()
	if target ~= nil then
		for _, token in ipairs(tokens) do pcall(target.Unregister, OWNER, token) end
	end
	tokens = {}
	clearWaypoint()
	active, npcs = nil, {}
end
