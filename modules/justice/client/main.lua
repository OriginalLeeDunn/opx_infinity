--- Justice, client side: the eye rows, the desk, the record, the office, the consent.
-- @author dop42
--
-- THIS HALF DECIDES NOTHING. It draws a sphere on every surveyed City Hall
-- desk, two rows on other players (read a record; offer representation) and a
-- self row (the office) for the jobs that have one, and the menus and forms
-- the server's answers fill. Every price, state and refusal comes from the
-- server; the role checks here only hide rows that would be refused anyway.
--
-- THE BUILD IS LIGHT AND CHUNKED. The client kills a resume past ~10,000
-- instructions: the desks are read one per resume, and every menu built from
-- a server list yields between chunks of rows.

local M = OPX.Modules.Get('justice')
local Access = M.Access

local OWNER = 'justice'
local MENU_ID = 'justice.menu'
local INVITE_MENU = 'justice.invite'
local FORM_ID = 'justice.form'
local CHUNK = 8
-- The most rows one menu is opened with: the menu validates a whole list in
-- one resume, and forty rows cost it past the ~10,000 a resume may spend.
local MAX_ROWS = 30

local desks = {}
local roles = { police = {}, lawyer = {}, judge = {} }
local invite = nil
local menuHandle = nil

local function cfg() return type(M.Settings) == 'table' and M.Settings or {} end

local function money(amount) return OPX.Locale.Money(math.tointeger(amount) or 0) end

local function clean(value, maximum) return OPX.Text.Clean(value, maximum or 64) or '' end

--- "today", "3 d ago": the server sends its own clock with every list.
local function ago(at, now)
	at, now = math.tointeger(at), math.tointeger(now)
	if at == nil or now == nil or at <= 0 then return '' end
	local days = math.max(0, (now - at) // Access.DAY_S)
	if days == 0 then return locale('justice.when.today') end
	return locale('justice.when.days', { days = days })
end

local function left(expires, now)
	expires, now = math.tointeger(expires), math.tointeger(now)
	if expires == nil or expires == 0 then return locale('justice.licence.forever') end
	if now == nil then return '' end
	return locale('justice.licence.daysLeft', { days = math.max(0, (expires - now) // Access.DAY_S) })
end

-- ── the menu and form contracts ─────────────────────────────────────────────

local function closeMenu(handle)
	local api = OPX.Api.Get('menu')
	if handle ~= nil and api ~= nil and type(api.Close) == 'function' then pcall(api.Close, handle, 'caller') end
end

local function open(spec)
	local api = OPX.Api.Get('menu')
	if api == nil or type(api.Open) ~= 'function' then
		OPX.Toast.Locale('justice.error.no_menu', nil, 'error')
		return nil
	end
	local opened = api.Open(spec)
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('justice', ('the %s menu was refused: %s'):format(tostring(spec.id),
			tostring(type(opened) == 'table' and opened.error or opened)))
		return nil
	end
	return type(opened.value) == 'table' and opened.value.handle or nil
end

local function show(title, items, on)
	closeMenu(menuHandle)
	menuHandle = open({ owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor', closeOnSelect = true,
		title = clean(title, 64), items = items, on = on })
end

local function form(spec, submit)
	local api = OPX.Api.Get('form')
	if api == nil or type(api.Open) ~= 'function' then
		return OPX.Toast.Locale('justice.error.no_menu', nil, 'error')
	end
	closeMenu(menuHandle)
	menuHandle = nil
	local opened = api.Open({ owner = OWNER, id = FORM_ID, title = clean(spec.title, 64),
		description = spec.description, fields = spec.fields,
		on = function(answer)
			if type(answer) ~= 'table' or answer.action ~= 'submit' then return end
			submit(type(answer.values) == 'table' and answer.values or {})
		end })
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Toast.Locale('justice.error.no_menu', nil, 'error')
		OPX.Note('justice', ('the form was refused: %s'):format(tostring(type(opened) == 'table' and opened.error)))
	end
end

-- WHAT A ROW DOES STAYS HERE. A row's data carries a number into this table,
-- never a function: the menu keeps the data beside the row, and a function is
-- not data.
local actions = {}

local function act(fn)
	actions[#actions + 1] = fn
	return { act = #actions }
end

--- The `on` of every list menu: the selected row's data names a server request.
local function onSelect(payload)
	if type(payload) ~= 'table' or payload.action ~= 'select' or type(payload.data) ~= 'table' then return end
	local run = actions[math.tointeger(payload.data.act) or 0]
	if run ~= nil then run() end
end

--- A row that opens its own menu when picked, built then and not before: one
--- menu holds one list, so no single `menu.Open` validates a whole office.
local function later(title, build)
	return act(function()
		CreateThread(function()
			actions = {}
			local items = build()
			-- The rows and the menu's own validation of them, in two resumes.
			Wait(0)
			show(title, items, onSelect)
		end)
	end)
end

-- ── the answers ─────────────────────────────────────────────────────────────

local function onAnswer(payload)
	if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
	local ok = payload.ok == true
	local key = (ok and 'justice.answer.' or 'justice.error.') .. payload.code
	if not OPX.Locale.Exists(key) then key = ok and 'justice.answer.done' or 'justice.error.invalid' end
	OPX.Toast.Show({
		id = 'opx.justice.answer',
		kind = ok and 'success' or OPX.Result.Kind(payload.code, 'error'),
		title = locale('justice.title'),
		message = locale(key, {
			licence = clean(payload.licence), fee = money(payload.fee), serial = clean(payload.serial, 32),
			name = clean(payload.name), label = clean(payload.label, 96), citizen = clean(payload.citizen, 16),
			case = math.tointeger(payload.case) or 0, jail = math.tointeger(payload.jail) or 0,
		}),
		icon = 'shield',
		durationMs = 5000,
	})
end

-- ── a record, drawn ─────────────────────────────────────────────────────────

local function entryLabel(row)
	local label = clean(row.label, 72)
	if row.kind == 'warrant' then
		return locale(row.active and 'justice.record.warrantActive' or 'justice.record.warrantClosed', { label = label })
	end
	return label
end

local function entryDescription(row, now)
	local parts = { ago(row.at, now) }
	if (math.tointeger(row.fine) or 0) > 0 then
		parts[#parts + 1] = locale(row.paid and 'justice.record.finePaid' or 'justice.record.fineUnpaid',
			{ fee = money(row.fine) })
	end
	if (math.tointeger(row.jail) or 0) > 0 then
		parts[#parts + 1] = locale('justice.record.jail', { minutes = math.tointeger(row.jail) })
	end
	if (math.tointeger(row.bail) or 0) > 0 then parts[#parts + 1] = locale('justice.record.bail', { fee = money(row.bail) }) end
	if type(row.officerName) == 'string' then parts[#parts + 1] = clean(row.officerName, 32) end
	if row.expunged then parts[#parts + 1] = locale('justice.record.expunged')
	elseif row.expunge == 'pending' then parts[#parts + 1] = locale('justice.record.pending') end
	return clean(table.concat(parts, ' - '), 158)
end

--- Rows for a record; `extra(row)` may add data (the lawyer's request).
local function recordRows(rows, now, extra)
	local out = {}
	for index, row in ipairs(type(rows) == 'table' and rows or {}) do
		if index > MAX_ROWS then break end
		local item = { id = 'entry.' .. index, label = entryLabel(row), icon = row.kind == 'warrant' and 'warning' or 'list',
			value = row.felony and locale('justice.record.felony') or nil,
			description = entryDescription(row, now), disabled = true }
		if extra ~= nil then extra(row, item) end
		out[#out + 1] = item
		if index % CHUNK == 0 then Wait(0) end
	end
	if #out == 0 then out[1] = { id = 'entry.none', label = locale('justice.record.clean'), icon = 'shield', disabled = true } end
	return out
end

local function onRecord(payload)
	if type(payload) ~= 'table' or type(payload.citizenId) ~= 'string' then return end
	CreateThread(function()
		actions = {}
		local lawyer = payload.viewer == 'lawyer'
		local items = recordRows(payload.rows, payload.now, lawyer and function(row, item)
			if not row.expunged and not row.active and row.expunge ~= 'pending' then
				item.disabled = false
				item.description = clean(item.description .. ' - ' .. locale('justice.record.askExpunge'), 158)
				item.data = act(function() TriggerServerEvent(M.Event.EXPUNGE, row.id) end)
			end
		end or nil)
		local title = locale('justice.record.title', { name = clean(payload.name or payload.citizenId, 40),
			citizen = clean(payload.citizenId, 16) })
		Wait(0)
		show(title, items, onSelect)
	end)
end

-- ── the desk ────────────────────────────────────────────────────────────────

local function onDesk(payload)
	if type(payload) ~= 'table' or type(payload.key) ~= 'string' then return end
	CreateThread(function()
		actions = {}
		local key, now = payload.key, payload.now
		local licences = {}
		for index, row in ipairs(type(payload.licences) == 'table' and payload.licences or {}) do
			local state = row.state == 'valid' and locale('justice.licence.valid', { left = left(row.expires, now) })
				or locale(row.state == 'expired' and 'justice.licence.expired' or 'justice.licence.none')
			local kind = row.kind
			licences[#licences + 1] = {
				id = 'licence.' .. index, icon = 'tag', label = clean(row.label, 64), value = money(row.fee),
				description = clean(state .. (row.clean and (' - ' .. locale('justice.licence.clean')) or ''), 158),
				disabled = row.state == 'valid',
				data = act(function() TriggerServerEvent(M.Event.BUY, key, kind) end),
			}
			if index % CHUNK == 0 then Wait(0) end
		end
		if #licences == 0 then licences[1] = { id = 'licence.none', label = locale('justice.desk.noLicence'), disabled = true } end
		local warrants = {}
		for index, row in ipairs(type(payload.warrants) == 'table' and payload.warrants or {}) do
			local id, bail = row.id, math.tointeger(row.bail) or 0
			warrants[#warrants + 1] = {
				id = 'warrant.' .. index, icon = 'warning', label = clean(row.label, 64),
				value = bail > 0 and money(bail) or nil,
				description = locale(bail > 0 and 'justice.desk.payBail' or 'justice.desk.noBail'),
				disabled = bail <= 0,
				data = act(function() TriggerServerEvent(M.Event.BAIL, key, id) end),
			}
		end
		Wait(0)
		local items = {
			{ id = 'licences', icon = 'tag', label = locale('justice.desk.licences'), items = licences },
			{ id = 'record', icon = 'folder', label = locale('justice.desk.record'),
				data = later(locale('justice.desk.record'), function() return recordRows(payload.record, now) end) },
		}
		if #warrants > 0 then
			items[#items + 1] = { id = 'warrants', icon = 'warning', label = locale('justice.desk.warrants'), items = warrants }
		end
		local counsel = type(payload.counsel) == 'table' and payload.counsel or nil
		items[#items + 1] = counsel and {
			id = 'counsel', icon = 'talk', label = locale('justice.desk.counsel', { name = clean(counsel.name, 40) }),
			description = locale('justice.desk.dismiss'),
			data = act(function() TriggerServerEvent(M.Event.DISMISS, key) end),
		} or { id = 'counsel', icon = 'talk', label = locale('justice.desk.noCounsel'), disabled = true }
		show(payload.label or locale('justice.title'), items, onSelect)
	end)
end

-- ── the office ──────────────────────────────────────────────────────────────

local function citizenField(value)
	return { id = 'citizen', label = locale('justice.form.citizen'), required = true, maxLength = 16,
		placeholder = 'ABC-DEFG', value = value }
end

local function warrantForm(payload)
	form({ title = locale('justice.form.warrantTitle'), fields = {
		citizenField(),
		{ id = 'reason', label = locale('justice.form.reason'), required = true, maxLength = 96 },
		{ id = 'bail', label = locale('justice.form.bail'), charset = 'digits', maxLength = 9, placeholder = '0' },
	} }, function(values)
		TriggerServerEvent(M.Event.WARRANT, { citizenId = values.citizen, reason = values.reason,
			bail = values.bail ~= '' and values.bail or nil })
	end)
end

local function caseForm(payload)
	local options = {}
	for index, crime in ipairs(type(payload.crimes) == 'table' and payload.crimes or {}) do
		if index > 64 then break end
		options[#options + 1] = { label = clean(crime.label, 46), value = crime.code }
	end
	if #options == 0 then return OPX.Toast.Locale('justice.error.bad_code', nil, 'error') end
	form({ title = locale('justice.form.caseTitle'), fields = {
		citizenField(),
		{ id = 'code', label = locale('justice.form.charge'), options = options },
		{ id = 'summary', label = locale('justice.form.summary'), maxLength = 255 },
	} }, function(values)
		TriggerServerEvent(M.Event.CASE, { citizenId = values.citizen, code = values.code, summary = values.summary })
	end)
end

local function verdictForm(payload, case)
	local suggested
	for _, crime in ipairs(type(payload.crimes) == 'table' and payload.crimes or {}) do
		if crime.code == case.code then suggested = crime end
	end
	form({ title = locale('justice.form.verdictTitle', { case = math.tointeger(case.id) or 0 }),
		description = clean(case.summary, 158),
		fields = {
			{ id = 'verdict', label = locale('justice.form.verdict'), options = {
				{ label = locale('justice.verdict.guilty'), value = 'guilty' },
				{ label = locale('justice.verdict.acquitted'), value = 'acquitted' },
			} },
			{ id = 'fine', label = locale('justice.form.fine'), charset = 'digits', maxLength = 9,
				value = suggested and tostring(suggested.fine) or '0' },
			{ id = 'jail', label = locale('justice.form.jail'), charset = 'digits', maxLength = 5,
				value = suggested and tostring(suggested.jail) or '0' },
			{ id = 'notes', label = locale('justice.form.notes'), maxLength = 255 },
		} }, function(values)
		TriggerServerEvent(M.Event.VERDICT, { caseId = case.id, verdict = values.verdict,
			fine = values.fine ~= '' and values.fine or nil, jail = values.jail ~= '' and values.jail or nil,
			notes = values.notes })
	end)
end

local function bailForm(row)
	form({ title = locale('justice.form.bailTitle', { label = clean(row.label, 40) }), fields = {
		{ id = 'bail', label = locale('justice.form.bail'), charset = 'digits', maxLength = 9, required = true,
			value = tostring(math.tointeger(row.bail) or 0) },
	} }, function(values) TriggerServerEvent(M.Event.SET_BAIL, row.id, values.bail, false) end)
end

local function lookupForm()
	form({ title = locale('justice.form.lookupTitle'), fields = { citizenField() } },
		function(values) TriggerServerEvent(M.Event.RECORD, values.citizen) end)
end

local function revokeForm(payload)
	local options = {}
	for _, licence in ipairs(type(payload.licences) == 'table' and payload.licences or {}) do
		options[#options + 1] = { label = clean(licence.label, 46), value = licence.kind }
	end
	if #options == 0 then return OPX.Toast.Locale('justice.error.unknown_licence', nil, 'error') end
	form({ title = locale('justice.form.revokeTitle'), fields = {
		citizenField(),
		{ id = 'kind', label = locale('justice.form.licence'), options = options },
		{ id = 'reason', label = locale('justice.form.reason'), maxLength = 96 },
	} }, function(values)
		TriggerServerEvent(M.Event.REVOKE, { citizenId = values.citizen, kind = values.kind, reason = values.reason })
	end)
end

local function judgeOffice(payload)
	local now = payload.now
	local function ruling(row)
		local id = row.id
		return later(clean(('%s - %s'):format(tostring(row.citizenId), tostring(row.label)), 64), function()
			return {
				{ id = 'what', icon = 'folder', disabled = true, label = clean(row.label, 90),
					description = entryDescription(row, now) },
				{ id = 'approve', icon = 'plus', label = locale('justice.office.approve'),
					data = act(function() TriggerServerEvent(M.Event.RULE, id, true) end) },
				{ id = 'deny', icon = 'ban', label = locale('justice.office.deny'),
					data = act(function() TriggerServerEvent(M.Event.RULE, id, false) end) },
			}
		end)
	end
	local function warrant(row)
		local id = row.id
		return later(clean(('%s - %s'):format(tostring(row.citizenId), tostring(row.label)), 64), function()
			return {
				{ id = 'what', icon = 'warning', disabled = true, label = clean(row.label, 90),
					description = entryDescription(row, now) },
				{ id = 'bail', icon = 'money', label = locale('justice.office.setBail'),
					data = act(function() bailForm(row) end) },
				{ id = 'lift', icon = 'ban', label = locale('justice.office.lift'),
					data = act(function() TriggerServerEvent(M.Event.SET_BAIL, id, nil, true) end) },
			}
		end)
	end
	local function list(rows, make)
		local out = {}
		for index, row in ipairs(type(rows) == 'table' and rows or {}) do
			if index > MAX_ROWS then break end
			out[#out + 1] = make(index, row)
			if index % CHUNK == 0 then Wait(0) end
		end
		if #out == 0 then out[1] = { id = 'none', label = locale('justice.office.nothing'), disabled = true } end
		return out
	end
	show(locale('justice.office.bench'), {
		{ id = 'cases', icon = 'flag', label = locale('justice.office.docket'),
			data = later(locale('justice.office.docket'), function()
				return list(payload.cases, function(index, case)
					return { id = 'case.' .. index, icon = 'flag',
						label = clean(locale('justice.office.case', { case = math.tointeger(case.id) or 0,
							name = tostring(case.defendantName or case.defendant), code = tostring(case.code) }), 90),
						description = clean(case.summary, 158) ~= '' and clean(case.summary, 158) or ago(case.at, now),
						data = act(function() verdictForm(payload, case) end) }
				end)
			end) },
		{ id = 'open', icon = 'plus', label = locale('justice.office.openCase'),
			data = act(function() caseForm(payload) end) },
		{ id = 'pending', icon = 'folder', label = locale('justice.office.pending'),
			value = tostring(type(payload.pending) == 'table' and #payload.pending or 0),
			data = later(locale('justice.office.pending'), function()
				return list(payload.pending, function(index, row)
					return { id = 'pending.' .. index, icon = 'folder',
						label = clean(('%s - %s'):format(tostring(row.citizenId), tostring(row.label)), 90),
						description = entryDescription(row, now), data = ruling(row) }
				end)
			end) },
		{ id = 'warrants', icon = 'warning', label = locale('justice.office.warrants'),
			value = tostring(type(payload.warrants) == 'table' and #payload.warrants or 0),
			data = later(locale('justice.office.warrants'), function()
				return list(payload.warrants, function(index, row)
					return { id = 'warrant.' .. index, icon = 'warning',
						label = clean(('%s - %s'):format(tostring(row.citizenId), tostring(row.label)), 90),
						description = entryDescription(row, now), data = warrant(row) }
				end)
			end) },
		{ id = 'warrant', icon = 'lock', label = locale('justice.office.signWarrant'),
			data = act(function() warrantForm(payload) end) },
		{ id = 'lookup', icon = 'search', label = locale('justice.office.lookup'), data = act(lookupForm) },
		{ id = 'revoke', icon = 'ban', label = locale('justice.office.revoke'),
			data = act(function() revokeForm(payload) end) },
	}, onSelect)
end

local function lawyerOffice(payload)
	local clients = {}
	for index, row in ipairs(type(payload.clients) == 'table' and payload.clients or {}) do
		if index > MAX_ROWS then break end
		local cid = row.client
		clients[#clients + 1] = { id = 'client.' .. index, icon = 'person',
			label = clean(row.clientName or cid, 64), value = clean(cid, 16),
			description = locale('justice.office.since', { when = ago(row.since, payload.now) }),
			data = act(function() TriggerServerEvent(M.Event.RECORD, cid) end) }
		if index % CHUNK == 0 then Wait(0) end
	end
	if #clients == 0 then clients[1] = { id = 'client.none', label = locale('justice.office.noClients'), disabled = true } end
	Wait(0)
	show(locale('justice.office.file'), clients, onSelect)
end

local function onOffice(payload)
	if type(payload) ~= 'table' then return end
	CreateThread(function()
		actions = {}
		if payload.role == 'judge' then judgeOffice(payload) elseif payload.role == 'lawyer' then lawyerOffice(payload) end
	end)
end

-- ── the consent ─────────────────────────────────────────────────────────────

local function reply(accepted)
	if invite == nil then return end
	local id = invite.id
	closeMenu(invite.handle)
	invite = nil
	TriggerServerEvent(M.Event.CONSENT, id, accepted == true)
end

local function onInvite(payload)
	if type(payload) ~= 'table' or type(payload.id) ~= 'string' or #payload.id > 32 then return end
	if invite ~= nil then closeMenu(invite.handle) end
	invite = { id = payload.id }
	local what = locale('justice.invite.offer', { name = clean(payload.lawyer, 40) })
	if type(payload.replaces) == 'string' then
		what = what .. ' ' .. locale('justice.invite.replaces', { name = clean(payload.replaces, 40) })
	end
	OPX.Toast.Show({ id = 'opx.justice.invite', kind = 'info', title = locale('justice.title'), message = what,
		icon = 'talk', durationMs = math.tointeger(payload.ms) or 30000 })
	local handle = open({
		owner = OWNER, id = INVITE_MENU, steal = true, focus = 'cursor', closeOnSelect = true,
		title = locale('justice.invite.title'),
		items = {
			{ id = 'what', label = clean(what, 96), icon = 'talk', disabled = true },
			{ id = 'accept', label = locale('justice.invite.accept'), icon = 'shield', data = { accept = true } },
			{ id = 'decline', label = locale('justice.invite.decline'), icon = 'ban', data = { accept = false } },
		},
		on = function(menu)
			if type(menu) ~= 'table' or invite == nil then return end
			if menu.action == 'select' and type(menu.data) == 'table' then reply(menu.data.accept == true) end
		end,
	})
	if invite ~= nil then invite.handle = handle end
end

-- ── the eye ─────────────────────────────────────────────────────────────────

--- Whether the local character holds a role, as far as this half can tell.
local function holds(role)
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetJobData) ~= 'function' then return false end
	local read, job = pcall(api.GetJobData)
	if not read or type(job) ~= 'table' then return false end
	local spec = roles[role]
	local minimum = spec.jobs[job.name]
	if minimum == nil then return false end
	local grade = type(job.grade) == 'table' and OPX.Math.Finite(job.grade.level) or 0
	if grade < (OPX.Math.Finite(minimum) or math.huge) then return false end
	return not spec.onDuty or job.onDuty == true
end

local function targetOf(context)
	local target = type(context) == 'table' and context.target or nil
	local id = type(target) == 'table' and math.tointeger(target.playerId) or nil
	return id ~= nil and id > 0 and id or nil
end

local function nearestDesk(context)
	local at = type(context) == 'table' and context.position or nil
	if type(at) ~= 'table' or not (OPX.Math.IsFinite(at.x) and OPX.Math.IsFinite(at.y) and OPX.Math.IsFinite(at.z)) then
		return desks[1]
	end
	local best, gap = nil, math.huge
	for _, desk in ipairs(desks) do
		local dx, dy, dz = at.x - desk.x, at.y - desk.y, at.z - desk.z
		local away = dx * dx + dy * dy + dz * dz
		if away < gap then best, gap = desk, away end
	end
	return best
end

local function note(what, placed)
	if type(placed) ~= 'table' or not placed.ok then
		OPX.Note('justice', ('the %s rows were refused: %s'):format(what, tostring(type(placed) == 'table' and placed.error)))
	end
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil then
		OPX.Note('justice', 'no target contract: City Hall is there and unreachable')
		return
	end
	local reach = OPX.Math.Finite(cfg().LAWYER_REACH) or 3.0
	note('player', target.RegisterPlayers(OWNER, {
		{ id = 'justice.record', label = locale('justice.row.record'), icon = 'folder', order = 42, distance = reach,
			canInteract = function(context)
				return targetOf(context) ~= nil and (holds('police') or holds('judge') or holds('lawyer'))
			end,
			onSelect = function(context)
				local id = targetOf(context)
				if id ~= nil then TriggerServerEvent(M.Event.RECORD, id) end
				return id ~= nil
			end },
		{ id = 'justice.offer', label = locale('justice.row.offer'), icon = 'talk', order = 43, distance = reach,
			canInteract = function(context) return targetOf(context) ~= nil and holds('lawyer') end,
			onSelect = function(context)
				local id = targetOf(context)
				if id ~= nil then TriggerServerEvent(M.Event.OFFER, id) end
				return id ~= nil
			end },
	}))
	Wait(0)
	note('office', target.RegisterSelf(OWNER, { {
		id = 'justice.office', label = locale('justice.row.office'), icon = 'folder', order = 12,
		canInteract = function() return holds('lawyer') or holds('judge') end,
		onSelect = function() TriggerServerEvent(M.Event.OFFICE) return true end,
	} }))
	Wait(0)
	if #desks > 0 then
		local spheres = {}
		for _, desk in ipairs(desks) do
			spheres[#spheres + 1] = { x = desk.x, y = desk.y, z = desk.z, radius = desk.radius }
		end
		note('desk', target.RegisterSpheres(OWNER, spheres, {
			id = 'justice.desk', label = locale('justice.row.desk'), icon = 'tag', distance = 2.5, order = 20,
			onSelect = function(context)
				local desk = nearestDesk(context)
				if desk ~= nil then TriggerServerEvent(M.Event.DESK, desk.key) end
				return desk ~= nil
			end,
		}))
	end
end

local function roleOf(raw)
	local spec = { jobs = {}, onDuty = false }
	if type(raw) == 'table' then
		for name, minimum in pairs(type(raw.JOBS) == 'table' and raw.JOBS or {}) do
			if type(name) == 'string' then spec.jobs[name] = minimum end
		end
		spec.onDuty = raw.ON_DUTY == true
	end
	return spec
end

--- Walks the desks one per resume, keeping the surveyed ones.
local function build()
	desks = {}
	roles = { police = roleOf(cfg().POLICE), lawyer = roleOf(cfg().LAWYER), judge = roleOf(cfg().JUDGE) }
	local raw = type(cfg().CITY_HALLS) == 'table' and cfg().CITY_HALLS or {}
	local keys = {}
	for key in pairs(raw) do
		if Access.Key(key) then keys[#keys + 1] = key end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local desk = raw[key]
		local point = type(desk) == 'table' and desk.DESK or nil
		if type(point) == 'table' and not Access.IsPlaceholder(point) and OPX.Math.IsFinite(point.X)
			and OPX.Math.IsFinite(point.Y) and OPX.Math.IsFinite(point.Z) then
			local radius = OPX.Math.Finite(desk.RADIUS) or 2.0
			desks[#desks + 1] = { key = key, x = point.X, y = point.Y, z = point.Z,
				radius = math.max(0.5, math.min(10, radius)) }
		end
		Wait(0)
	end
end

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	desks, invite, menuHandle = {}, nil, nil
end

--- Wires the answers, then builds and registers on a thread.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.ANSWER, onAnswer)
	RegisterNetEvent(M.Event.DESK_DATA, onDesk)
	RegisterNetEvent(M.Event.RECORD_DATA, onRecord)
	RegisterNetEvent(M.Event.OFFICE_DATA, onOffice)
	RegisterNetEvent(M.Event.INVITE, onInvite)
	CreateThread(function()
		build()
		Wait(0)
		registerRows()
	end)
end

--- Closes what is open and takes the rows back.
-- @author dop42
function M.Stop()
	if invite ~= nil then closeMenu(invite.handle) end
	closeMenu(menuHandle)
	invite, menuHandle = nil, nil
	local target = OPX.Api.Get('target')
	if target ~= nil and type(target.Clear) == 'function' then pcall(target.Clear, OWNER) end
end
