--- The clinic, server side: the chart, the consent, the escrow, the knife, the bill.
-- @author dop42
--
-- ONE OPERATION, FIVE STEPS, EACH RE-READ FROM SCRATCH:
--
--   chart      the doc ALTs a patient sitting in a clinic chair; the server
--              checks the doc's job, duty and reach, reads the patient's body
--              (humanity, installed chrome) and what can go in -- the clinic
--              stash's new parts, the doc's bag, the patient's own bag -- and
--              sends the doc a priced menu
--   propose    the doc picks a row; the server re-derives the price, the
--              humanity, the risk and every refusal, and asks the PATIENT
--   consent    the patient accepts; everything is checked again, then the
--              money and the part are taken into escrow (money first, part
--              second) and a receipt is written
--   the bar    the doc works under a server-timed, cancelable bar; a cancel,
--              a disconnect or a patient who walked off gives everything back
--   operate    the dice; the native install (an async ticket, answered on
--              `onCyberwareOperationCompleted`) or the roleplay metadata; then
--              the bill is split (refund, the doc's cut, the till) and the
--              receipt closed
--
-- A CRASH IS RESUMED FROM THE RECEIPT at the next boot: a `reserved` one is
-- given back, a `submitted` one is replayed with the same native operation id
-- and expected revision when the patient next loads in.

local M = OPX.Modules.Get('ripperdoc')
local Model = M.Model
local Storage = M.Storage
local Native = M.Native
local Phase = M.Phase

local OWNER = 'ripperdoc'
local REQUEST_MS = 700
local MAX_OFFERS = 40

local S = nil
local character = nil

-- Read at every use, like `fuel` does: the contract is a table another module
-- owns, and a stale local would outlive its owner's restart.
local function inventory() return OPX.Api.Get('inventory') end

local ops, opOf, byTicket = {}, {}, {}
local resume = {}
local sweepJob = nil
local serial = 0

-- ── small reads ─────────────────────────────────────────────────────────────

local function pointOf(player)
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y), OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end

local function apart(a, b)
	if a == nil or b == nil or a.bucket ~= b.bucket then return math.huge end
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function dataOf(player)
	if character == nil or player == nil then return nil end
	local read, loaded = pcall(character.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	return loaded.PlayerData
end

local function sourceOf(citizenId)
	if character == nil or type(citizenId) ~= 'string' then return nil end
	local read, loaded = pcall(character.GetPlayerByCitizenId, citizenId)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	return math.tointeger(tonumber(loaded.PlayerData.source))
end

local function down(player)
	return OPX.Life ~= nil and OPX.Life.Down(player) == true
end

local function now() return OPX.Now() end

-- No wall clock on the server VM (`os` is sandboxed away): an operation id is
-- random enough to never meet another receipt, and the receipt row carries the
-- real timestamps.
local function newId()
	serial = serial % 0xffff + 1
	return ('rd-%06x%06x-%06x-%04x'):format(math.random(0, 0xffffff), math.random(0, 0xffffff),
		math.floor(OPX.Now()) % 0xffffff, serial)
end

local function newSerial()
	return ('NC-%04d-%04d'):format(math.random(0, 9999), math.random(0, 9999))
end

local function answer(player, ok, code, extra)
	if player == nil then return ok end
	local payload = type(extra) == 'table' and extra or {}
	payload.ok, payload.code = ok == true, code
	TriggerClientEvent(M.Event.ANSWER, player, payload)
	return ok
end

local function recipient(player, command)
	if player <= 0 then return function() return true end end
	local userId, session, data = OPX.UserIdOf(player), OPX.Sessions[player], dataOf(player)
	return function()
		if userId == nil or OPX.UserIdOf(player) ~= userId or OPX.Sessions[player] ~= session
			or dataOf(player) ~= data then return false end
		if command == nil then return true end
		local read, allowed = pcall(Open77.acl.isAllowed, player, 'command.' .. command)
		return read and allowed == true
	end
end

-- ── the gate ────────────────────────────────────────────────────────────────

local function snapshotOf(data)
	if data == nil then return nil end
	return { job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil, atMs = now() }
end

--- The doc's grade in the clinic's job, or nil when they hold none of its jobs.
local function gradeIn(clinic, data)
	if clinic.jobs == nil or data == nil then return 0 end
	local job = type(data.job) == 'table' and data.job or nil
	for name in pairs(clinic.jobs) do
		if job ~= nil and job.name == name then
			return math.tointeger(type(job.grade) == 'table' and OPX.Math.Finite(job.grade.level) or 0) or 0
		end
		if S.membership == 'any' and type(data.jobs) == 'table' and data.jobs[name] ~= nil then
			return math.tointeger(OPX.Math.Finite(data.jobs[name]) or 0) or 0
		end
	end
	return nil
end

local function gate(clinic, data, minimumGrade)
	local ok, code = OPX.JobGate.Evaluate({ jobs = clinic.jobs, onDuty = clinic.onDuty }, snapshotOf(data), now(),
		{ maxAgeMs = S.jobMaxAgeMs, membership = S.membership })
	if not ok then return false, code or 'job_required' end
	local grade = gradeIn(clinic, data) or 0
	if minimumGrade ~= nil and grade < minimumGrade then return false, 'grade_too_low' end
	return true, nil, grade
end

--- The doc, the patient, the clinic and the chair, or nil and a refusal.
local function locate(doc, patient)
	patient = math.tointeger(tonumber(patient))
	if patient == nil or patient < 1 then return nil, 'no_patient' end
	if patient == doc then return nil, 'self' end
	local docData, patientData = dataOf(doc), dataOf(patient)
	if docData == nil then return nil, 'no_character' end
	if patientData == nil then return nil, 'no_patient' end
	if down(doc) or down(patient) then return nil, 'player_down' end
	local here, there = pointOf(doc), pointOf(patient)
	if here == nil or there == nil then return nil, 'too_far' end
	local slack = OPX.Spots.ServerReach(0)
	local clinic = Model.ChairAt(S, there.x, there.y, there.z, there.bucket, slack)
	if clinic == nil then return nil, 'not_in_chair' end
	if apart(here, there) > OPX.Spots.ServerReach(S.docReach) then return nil, 'too_far' end
	local ok, code, grade = gate(clinic, docData)
	if not ok then return nil, code end
	return { doc = doc, patient = patient, clinic = clinic, grade = grade,
		docCid = docData.citizenId, patientCid = patientData.citizenId,
		docData = docData, patientData = patientData }
end

local function participants(ctx)
	return dataOf(ctx.doc) == ctx.docData and dataOf(ctx.patient) == ctx.patientData
end

-- ── the body ────────────────────────────────────────────────────────────────

--- A patient's humanity and installed list, online or not. Yields offline.
local function bodyOf(citizenId)
	local player = sourceOf(citizenId)
	if player ~= nil then
		local humanity = character.GetMetadata(player, M.HUMANITY_KEY)
		local installed = character.GetMetadata(player, M.CYBERWARE_KEY)
		return Model.Humanity(S, humanity), Model.Installed(installed), player
	end
	if type(character.ReadMetadata) ~= 'function' then return nil end
	local read = character.ReadMetadata(citizenId)
	if type(read) ~= 'table' or not read.ok or type(read.value) ~= 'table' then return nil end
	local metadata = type(read.value.metadata) == 'table' and read.value.metadata or {}
	return Model.Humanity(S, metadata[M.HUMANITY_KEY]), Model.Installed(metadata[M.CYBERWARE_KEY]), nil
end

local function writeBody(citizenId, humanity, installed)
	local player = sourceOf(citizenId)
	if player ~= nil then
		local a = character.SetMetadata(player, M.HUMANITY_KEY, humanity)
		local b = character.SetMetadata(player, M.CYBERWARE_KEY, installed)
		return a ~= false and b ~= false
	end
	if type(character.WriteMetadata) ~= 'function' then return false end
	local a = character.WriteMetadata(citizenId, M.HUMANITY_KEY, humanity)
	local b = character.WriteMetadata(citizenId, M.CYBERWARE_KEY, installed)
	return type(a) == 'table' and a.ok and type(b) == 'table' and b.ok
end

-- ── money and parts ─────────────────────────────────────────────────────────

local function pay(citizenId, method, amount, reason)
	if amount <= 0 then return true end
	if sourceOf(citizenId) ~= nil then
		local read, ok = pcall(character.AddMoney, citizenId, method, amount, reason)
		if read and ok == true then return true end
	end
	if type(character.AddMoneyOffline) ~= 'function' then return false end
	local added = character.AddMoneyOffline(citizenId, method, amount, reason)
	return type(added) == 'table' and added.ok == true
end

local function charge(player, method, amount, reason)
	if amount <= 0 then return true end
	local read, ok = pcall(character.RemoveMoney, player, method, amount, reason)
	return read and ok == true
end

local function balance(player, method)
	local read, value = pcall(character.GetMoney, player, method)
	return read and (OPX.Math.Finite(value) or 0) or 0
end

local function ok(result) return type(result) == 'table' and result.ok == true end

local function stockOf(clinic, chrome, tier, origin)
	if clinic.chest == nil then return 0 end
	local read, counted = pcall(inventory().CountInStash, clinic.chest.name, chrome.item, Model.NewPart(tier, origin))
	return read and ok(counted) and (math.tointeger(counted.value) or 0) or 0
end

local function bagChrome(holder)
	local read, bag = pcall(inventory().GetInventory, holder)
	local items = read and ok(bag) and type(bag.value) == 'table' and bag.value.items or nil
	local out = {}
	for _, entry in ipairs(type(items) == 'table' and items or {}) do
		for _, chrome in ipairs(S.chromeList) do
			if type(entry) == 'table' and entry.name == chrome.item then
				local meta = type(entry.metadata) == 'table' and entry.metadata or {}
				out[#out + 1] = { slot = entry.slot, chrome = chrome, meta = meta,
					tier = math.tointeger(OPX.Math.Finite(meta.tier)) or 1,
					origin = Model.ORIGINS[meta.origin] and meta.origin or 'legit',
					condition = OPX.Math.Finite(meta.condition) or 100 }
			end
		end
	end
	return out
end

--- Puts a part somewhere real: its own holder first, the clinic stash second.
local function givePart(op, holder, meta)
	local chrome = S.chrome[op.chrome]
	if chrome == nil then return false end
	local clinic = S.clinics[op.clinic]
	if holder ~= 'stash' then
		local target = holder == 'doc' and op.docCid or op.patientCid
		local added = inventory().AddItem(target, chrome.item, 1, meta)
		if ok(added) then return true end
	end
	if clinic ~= nil and clinic.chest ~= nil then
		local stashed = inventory().AddToStash(clinic.chest.name, chrome.item, 1, meta)
		if ok(stashed) then return true end
	end
	Open77.log.error(('[ripperdoc] a %s part of operation %s could not be put anywhere'):format(op.chrome, op.id))
	OPX.Audit.Log({ event = 'ripperdoc.partLost', severity = 'warn', message = op.id,
		data = { chrome = op.chrome, holder = holder, meta = meta } })
	return false
end

local function takePart(op)
	local chrome = S.chrome[op.chrome]
	local part = op.part
	if part.source == 'stash' then
		local clinic = S.clinics[op.clinic]
		if clinic == nil or clinic.chest == nil then return false end
		return ok(inventory().RemoveFromStash(clinic.chest.name, chrome.item, 1, part.meta))
	end
	local holder = part.source == 'doc' and op.docCid or op.patientCid
	local read, stack = pcall(inventory().GetSlot, holder, part.slot)
	stack = read and ok(stack) and stack.value or nil
	if type(stack) ~= 'table' or stack.name ~= chrome.item then return false end
	local meta = type(stack.metadata) == 'table' and stack.metadata or {}
	for _, field in ipairs({ 'tier', 'origin', 'condition', 'serial' }) do
		if meta[field] ~= part.meta[field] then return false end
	end
	return ok(inventory().RemoveFromSlot(holder, part.slot, 1, { name = stack.name, metadata = stack.metadata }))
end

-- ── the chart ───────────────────────────────────────────────────────────────

local function nativeRecord(patient)
	local cyberware = Native.Api()
	if cyberware == nil or patient == nil then return nil end
	local read, record = pcall(cyberware.current, patient)
	return read and type(record) == 'table' and record or nil
end

--- Every number of one install, and whether the body refuses it.
local function installQuote(ctx, humanity, installed, chrome, tier, origin, source, condition)
	local clinic = ctx.clinic
	if not Model.Allows(clinic, chrome, origin) then return nil, 'not_allowed' end
	if not chrome.tiers[tier] then return nil, 'bad_tier' end
	local fit, code, over = Model.CheckInstall(S, humanity, installed, chrome, tier)
	local tierRow = S.tiers[tier]
	if fit and ctx.grade < tierRow.grade then fit, code = false, 'grade_too_low' end
	local _, _, total = Model.Price(S, clinic, chrome, tier, 'install', source)
	return {
		total = total, humanity = Model.HumanityCost(S, chrome, tier),
		risk = Model.Risk(S, { clinic = clinic, chrome = chrome, tier = tier, action = 'install',
			grade = ctx.grade, origin = origin, condition = condition, overCapacity = over }),
		blocked = (not fit) and code or nil, over = over,
	}
end

local function removeQuote(ctx, entry)
	local chrome = S.chrome[entry.chrome]
	if chrome == nil then return nil, 'unknown_chrome' end
	local tier = math.tointeger(OPX.Math.Finite(entry.tier)) or 1
	local _, _, total = Model.Price(S, ctx.clinic, chrome, tier, 'remove', 'body')
	return {
		total = total,
		humanity = math.floor((OPX.Math.Finite(entry.humanity) or Model.HumanityCost(S, chrome, tier))
			* S.humanity.refundPct / 100),
		risk = Model.Risk(S, { clinic = ctx.clinic, chrome = chrome, tier = tier, action = 'remove',
			grade = ctx.grade, origin = entry.origin, condition = entry.condition }),
	}
end

--- The doc's menu: the body, what can go in and what can come out.
-- @author dop42
function M.Chart(doc, patient)
	if OPX.Cooling(doc, 'ripperdoc.request', REQUEST_MS) then return answer(doc, false, 'too_fast'), 'too_fast' end
	local ctx, why = locate(doc, patient)
	if ctx == nil then return answer(doc, false, why), why end
	local humanity, installed = bodyOf(ctx.patientCid)
	if humanity == nil then return answer(doc, false, 'no_patient'), 'no_patient' end
	local clinic = ctx.clinic
	local chart = {
		patient = ctx.patient, clinic = clinic.key, label = clinic.label,
		humanity = humanity, capacity = Model.CapacityUsed(S, installed), maxCapacity = S.maxCapacity,
		installed = {}, installs = {}, removals = {}, money = clinic.money,
		services = { install = clinic.services.install, remove = clinic.services.remove },
	}
	for _, entry in ipairs(installed) do
		local chrome = S.chrome[entry.chrome]
		local row = { chrome = entry.chrome, label = chrome and chrome.label or entry.chrome,
			tier = entry.tier, slot = entry.slot, serial = entry.serial, origin = entry.origin,
			condition = entry.condition }
		chart.installed[#chart.installed + 1] = row
		if clinic.services.remove then
			local quote, blocked = removeQuote(ctx, entry)
			local removal = { chrome = entry.chrome, label = row.label, tier = entry.tier, serial = entry.serial,
				slot = entry.slot, blocked = blocked }
			if quote ~= nil then
				removal.total, removal.humanity, removal.risk = quote.total, quote.humanity, quote.risk
			end
			chart.removals[#chart.removals + 1] = removal
		end
	end
	if clinic.services.install then
		local function offer(chrome, tier, origin, source, extra)
			if #chart.installs >= MAX_OFFERS then return end
			local quote = installQuote(ctx, humanity, installed, chrome, tier, origin, source,
				extra and extra.condition or 100)
			if quote == nil then return end
			local row = { chrome = chrome.key, label = chrome.label, tier = tier, origin = origin, source = source,
				total = quote.total, humanity = quote.humanity, risk = quote.risk, blocked = quote.blocked }
			for key, value in pairs(extra or {}) do row[key] = value end
			chart.installs[#chart.installs + 1] = row
		end
		for _, chrome in ipairs(S.chromeList) do
			for _, tier in ipairs(chrome.tierList) do
				for _, origin in ipairs({ 'legit', 'black' }) do
					if Model.Allows(clinic, chrome, origin) then
						local count = stockOf(clinic, chrome, tier, origin)
						if count > 0 then offer(chrome, tier, origin, 'stash', { count = count }) end
					end
				end
			end
		end
		for _, holder in ipairs({ 'doc', 'patient' }) do
			for _, held in ipairs(bagChrome(holder == 'doc' and doc or ctx.patient)) do
				offer(held.chrome, held.tier, held.origin, holder,
					{ slot = held.slot, condition = held.condition, serial = held.meta.serial })
			end
		end
	end
	if not participants(ctx) then return false, 'no_character' end
	TriggerClientEvent(M.Event.CHART_DATA, doc, chart)
	return true, chart
end

-- ── the proposal and the consent ────────────────────────────────────────────

local function drop(op)
	ops[op.id] = nil
	if op.doc ~= nil and opOf[op.doc] == op.id then opOf[op.doc] = nil end
	if op.patient ~= nil and opOf[op.patient] == op.id then opOf[op.patient] = nil end
end

local function word(value, maximum)
	return type(value) == 'string' and #value >= 1 and #value <= maximum and value:match('^[%w_%-]+$') and value or nil
end

--- Builds a fully priced operation from a doc's request, or a refusal.
local function plan(doc, payload)
	if type(payload) ~= 'table' then return nil, 'invalid' end
	local ctx, why = locate(doc, payload.patient)
	if ctx == nil then return nil, why end
	if opOf[doc] ~= nil or opOf[ctx.patient] ~= nil then return nil, 'busy' end
	local clinic = ctx.clinic
	local humanity, installed = bodyOf(ctx.patientCid)
	if humanity == nil then return nil, 'no_patient' end
	local op = { id = newId(), clinic = clinic.key, doc = doc, patient = ctx.patient,
		docCid = ctx.docCid, patientCid = ctx.patientCid, grade = ctx.grade, method = clinic.money,
		docData = ctx.docData, patientData = ctx.patientData }

	if payload.action == 'install' then
		if not clinic.services.install then return nil, 'service_closed' end
		local chrome = S.chrome[word(payload.chrome, 48) or '']
		if chrome == nil then return nil, 'unknown_chrome' end
		local source = payload.source
		local tier, origin, meta, slot
		if source == 'stash' then
			tier = math.tointeger(tonumber(payload.tier))
			origin = Model.ORIGINS[payload.origin] and payload.origin or nil
			if tier == nil or origin == nil then return nil, 'invalid' end
			if clinic.chest == nil then return nil, 'no_stash' end
			meta = Model.NewPart(tier, origin)
		elseif source == 'doc' or source == 'patient' then
			slot = math.tointeger(tonumber(payload.slot))
			if slot == nil or slot < 1 then return nil, 'invalid' end
			local holder = source == 'doc' and doc or ctx.patient
			local read, stack = pcall(inventory().GetSlot, holder, slot)
			stack = read and ok(stack) and stack.value or nil
			if type(stack) ~= 'table' or stack.name ~= chrome.item then return nil, 'no_part' end
			meta = {}
			for key, value in pairs(type(stack.metadata) == 'table' and stack.metadata or {}) do meta[key] = value end
			tier = math.tointeger(OPX.Math.Finite(meta.tier)) or 1
			origin = Model.ORIGINS[meta.origin] and meta.origin or 'legit'
		else
			return nil, 'invalid'
		end
		local quote, refused = installQuote(ctx, humanity, installed, chrome, tier, origin, source,
			OPX.Math.Finite(meta.condition) or 100)
		if quote == nil then return nil, refused end
		if quote.blocked then return nil, quote.blocked end
		if source == 'stash' and stockOf(clinic, chrome, tier, origin) < 1 then return nil, 'no_stock' end
		op.native = chrome.kind == 'native' and Native.Defined(chrome.key)
		if op.native then
			local record = nativeRecord(ctx.patient)
			if record == nil then
				if not S.native.fallbackRp then return nil, 'native_not_ready' end
				op.native = false
			elseif record[chrome.slot] ~= nil then
				return nil, 'slot_taken'
			end
		elseif chrome.kind == 'native' and not S.native.fallbackRp then
			return nil, 'native_not_ready'
		end
		op.action, op.chrome, op.tier, op.origin = 'install', chrome.key, tier, origin
		op.total, op.humanity, op.risk, op.over = quote.total, quote.humanity, quote.risk, quote.over
		op.part = { source = source, slot = slot, meta = meta, serial = meta.serial or newSerial() }
		op.condition = OPX.Math.Finite(meta.condition) or 100
	elseif payload.action == 'remove' then
		if not clinic.services.remove then return nil, 'service_closed' end
		local wanted = word(payload.serial, 32)
		local entry
		for _, row in ipairs(installed) do
			if (wanted ~= nil and row.serial == wanted) or (wanted == nil and row.slot == payload.slot) then
				entry = row
				break
			end
		end
		if entry == nil then return nil, 'not_installed' end
		local chrome = S.chrome[entry.chrome]
		if chrome == nil then return nil, 'unknown_chrome' end
		local quote, refused = removeQuote(ctx, entry)
		if quote == nil then return nil, refused end
		op.native = entry.native == true
		if op.native then
			local record = Native.Defined(chrome.key) and nativeRecord(ctx.patient) or nil
			if record == nil then return nil, 'native_not_ready' end
		end
		op.action, op.chrome, op.tier, op.origin = 'remove', chrome.key, math.tointeger(OPX.Math.Finite(entry.tier)) or 1,
			entry.origin
		op.total, op.humanity, op.risk = quote.total, quote.humanity, quote.risk
		op.part = { source = 'body', serial = entry.serial,
			meta = { tier = op.tier, origin = entry.origin, condition = entry.condition, serial = entry.serial } }
		op.condition = OPX.Math.Finite(entry.condition) or 100
	else
		return nil, 'invalid'
	end
	if not participants(ctx) then return nil, 'no_character' end
	if opOf[doc] ~= nil or opOf[ctx.patient] ~= nil then return nil, 'busy' end
	if balance(ctx.patient, op.method) < op.total then return nil, 'not_enough_money' end
	return op
end

--- The doc proposes; the patient is asked.
-- @author dop42
function M.Propose(doc, payload)
	if OPX.Cooling(doc, 'ripperdoc.request', REQUEST_MS) then return answer(doc, false, 'too_fast'), 'too_fast' end
	local op, why = plan(doc, payload)
	if op == nil then return answer(doc, false, why), why end
	op.state = 'invited'
	op.untilMs = now() + S.consentMs
	ops[op.id], opOf[op.doc], opOf[op.patient] = op, op.id, op.id
	local clinic = S.clinics[op.clinic]
	local chrome = S.chrome[op.chrome]
	TriggerClientEvent(M.Event.INVITE, op.patient, {
		id = op.id, clinic = clinic.label, action = op.action, chrome = chrome.label, tier = op.tier,
		price = op.total, method = op.method, humanity = op.humanity, risk = op.risk, ms = S.consentMs,
		origin = op.origin,
	})
	answer(doc, true, 'invited', { chrome = chrome.label, price = op.total })
	return true, op.id
end

local release, operate, commit

local function startBar(op)
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then return 'no_bar' end
	local chrome = S.chrome[op.chrome]
	local duration = op.action == 'install' and (chrome.installMs or S.installMs) or (chrome.removeMs or S.removeMs)
	local limit = math.tointeger(OPX.Config.MODULES.progress and OPX.Config.MODULES.progress.MAX_MS) or 60000
	duration = math.max(1000, math.min(duration, limit))
	local started = progress.Start(op.doc, OWNER, {
		label = locale(op.action == 'install' and 'ripperdoc.bar.install' or 'ripperdoc.bar.remove',
			{ chrome = chrome.label }),
		durationMs = duration,
		cancelable = true,
		animation = S.animation and { name = S.animation } or nil,
	}, function(_, outcome)
		if ops[op.id] ~= op or type(outcome) ~= 'table' or outcome.id ~= op.barId then return end
		CreateThread(function()
			if outcome.completed == true then
				operate(op)
			else
				release(op, outcome.ending == 'left' and 'doc_left' or 'cancelled')
			end
		end)
	end)
	if not ok(started) then return 'no_bar' end
	op.barId = started.value.id
	return nil
end

--- Escrow, receipt, bar. On a coroutine.
local function reserve(op)
	local ctx, why = locate(op.doc, op.patient)
	if ctx == nil or ctx.clinic.key ~= op.clinic or not participants(op) then
		drop(op)
		answer(op.doc, false, why or 'moved')
		return answer(op.patient, false, why or 'moved')
	end
	local reason = 'ripperdoc:' .. op.clinic
	if not charge(op.patientCid, op.method, op.total, reason) then
		drop(op)
		answer(op.doc, false, 'not_enough_money')
		return answer(op.patient, false, 'not_enough_money')
	end
	op.charged = true
	if op.action == 'install' and not takePart(op) then
		op.charged = false
		pay(op.patientCid, op.method, op.total, reason .. ':refund')
		drop(op)
		answer(op.doc, false, 'part_gone')
		return answer(op.patient, false, 'part_gone')
	end
	op.taken = op.action == 'install'
	op.state = Phase.RESERVED
	if not Storage.Insert(op) then return release(op, 'storage') end
	op.receipt = true
	if not participants(op) then return release(op, 'patient_left') end
	local code = startBar(op)
	if code ~= nil then return release(op, code) end
	answer(op.patient, true, 'operating', { chrome = S.chrome[op.chrome].label })
	OPX.Audit.Log({ event = 'ripperdoc.reserve', source = op.patient,
		message = ('%s %s T%d at %s for %d'):format(op.action, op.chrome, op.tier, op.clinic, op.total),
		data = { id = op.id, doc = op.docCid, patient = op.patientCid, total = op.total, method = op.method,
			source = op.part.source } })
end

--- The patient's answer.
-- @author dop42
function M.Consent(patient, id, accepted)
	if type(id) ~= 'string' or #id > 40 then return false end
	local op = ops[id]
	if op == nil or op.patient ~= patient or op.state ~= 'invited' then
		if accepted == true then answer(patient, false, 'expired') end
		return false
	end
	if not participants(op) then drop(op); return false end
	if now() >= op.untilMs then
		drop(op)
		answer(op.doc, false, 'expired')
		return answer(patient, false, 'expired')
	end
	if accepted ~= true then
		drop(op)
		answer(op.doc, false, 'declined')
		return answer(patient, true, 'you_declined')
	end
	op.state = 'reserving'
	CreateThread(function() reserve(op) end)
	return true
end

-- ── the end of an operation ─────────────────────────────────────────────────

--- Gives everything back: the whole bill, the part where it came from.
release = function(op, code)
	if op.closed then return end
	op.closed = true
	byTicket[op.ticket or false] = nil
	if op.charged ~= false and (op.charged or op.receipt) then
		if not pay(op.patientCid, op.method, op.total, 'ripperdoc:' .. op.clinic .. ':refund') then
			Open77.log.error(('[ripperdoc] the refund of %s (%d) failed'):format(op.id, op.total))
		end
	end
	if op.action == 'install' and (op.taken or op.receipt) then
		givePart(op, op.part.source, op.part.meta)
	end
	if op.receipt then Storage.Phase(op, Phase.CANCELLED, code) end
	drop(op)
	OPX.Audit.Log({ event = 'ripperdoc.release', message = ('%s: %s'):format(op.id, tostring(code)),
		data = { id = op.id, total = op.total, code = code } })
	answer(sourceOf(op.docCid), false, code)
	answer(sourceOf(op.patientCid), false, code)
end

local function injure(player, pct)
	local players = Open77.players
	if player == nil or type(players) ~= 'table' or type(players.getHealth) ~= 'function'
		or type(players.setHealth) ~= 'function' then
		return
	end
	local read, health = pcall(players.getHealth, player)
	if not read or type(health) ~= 'table' then return end
	local current, maximum = tonumber(health.health), tonumber(health.maxHealth)
	if current == nil or maximum == nil or maximum <= 0 then return end
	local wanted = math.max(1, maximum * pct / 100)
	if wanted < current then pcall(players.setHealth, player, wanted) end
end

--- Applies the outcome: the body, the part, the money, the receipt.
commit = function(op, outcome, applied)
	if op.closed then return end
	op.closed = true
	byTicket[op.ticket or false] = nil
	local chrome = S.chrome[op.chrome]
	local humanity, installed = bodyOf(op.patientCid)
	humanity, installed = humanity or S.humanity.start, installed or {}
	local damaged = outcome ~= nil and outcome.part == 'damaged'
	local lost = outcome ~= nil and outcome.part == 'lost'

	if op.action == 'install' then
		if applied then
			humanity = humanity - op.humanity
			installed[#installed + 1] = {
				chrome = op.chrome, tier = op.tier, slot = chrome.slot, serial = op.part.serial,
				origin = op.origin, condition = op.condition, clinic = op.clinic, doc = op.docCid,
				humanity = op.humanity, native = op.native == true,
			}
		elseif not lost then
			local meta = damaged and Model.Worn(op.part.meta, outcome.conditionLoss, 0) or op.part.meta
			givePart(op, op.part.source, meta)
		end
	elseif applied then
		local index
		for i, entry in ipairs(installed) do
			if entry.serial == op.part.serial then index = i end
		end
		if index ~= nil then table.remove(installed, index) end
		humanity = humanity + op.humanity
		if not lost then
			local wear = S.removalWear + (damaged and outcome.conditionLoss or 0)
			givePart(op, 'patient', Model.Worn(op.part.meta, wear, S.removalTierLoss))
		end
	end
	if not writeBody(op.patientCid, humanity, installed) then
		Open77.log.error(('[ripperdoc] the body of %s was not written after %s'):format(op.patientCid, op.id))
	end

	local refund, docCut, till = Model.Split(S, op.total, outcome and outcome.refundPct or 0)
	local reason = 'ripperdoc:' .. op.clinic
	pay(op.patientCid, op.method, refund, reason .. ':refund')
	pay(op.docCid, op.method, docCut, reason .. ':fee')

	local patient = sourceOf(op.patientCid)
	if outcome ~= nil and outcome.healthPct ~= nil then injure(patient, outcome.healthPct) end
	if op.receipt then Storage.Phase(op, Phase.COMMITTED, outcome and outcome.key or 'success') end
	drop(op)

	OPX.Audit.Log({ event = 'ripperdoc.operation', source = patient,
		message = ('%s %s T%d: %s'):format(op.action, op.chrome, op.tier, outcome and outcome.key or 'success'),
		data = { id = op.id, clinic = op.clinic, doc = op.docCid, patient = op.patientCid, total = op.total,
			refund = refund, doc_cut = docCut, till = till, tillMode = S.till, applied = applied,
			native = op.native == true, humanity = humanity } })
	OPX.Publish(M.Event.ON_OPERATED, patient, { id = op.id, clinic = op.clinic, action = op.action,
		chrome = op.chrome, tier = op.tier, outcome = outcome and outcome.key or 'success', applied = applied,
		doc = op.docCid, native = op.native == true })

	local code = applied and (op.action == 'install' and 'installed' or 'removed') or 'failed'
	local extra = { chrome = chrome and chrome.label or op.chrome, outcome = outcome and outcome.key or nil,
		refund = refund, humanity = humanity }
	answer(patient, applied, code, extra)
	answer(sourceOf(op.docCid), applied, code, { chrome = extra.chrome, outcome = extra.outcome, fee = docCut })
end

local function outcomeByKey(key)
	for _, row in ipairs(S.outcomes) do
		if row.key == key then return row end
	end
	return nil
end

--- Sends a native install or removal; the answer comes on the completion event.
local function submit(op, outcome)
	local cyberware = Native.Api()
	local chrome = S.chrome[op.chrome]
	local record = nativeRecord(op.patient)
	if cyberware == nil or record == nil then
		if op.action == 'install' and S.native.fallbackRp then
			op.native = false
			return commit(op, outcome, true)
		end
		return release(op, 'native_not_ready')
	end
	local id, why = cyberware.newOperationId()
	if type(id) ~= 'string' then
		Open77.log.warn('[ripperdoc] no native operation id: ' .. tostring(why))
		return release(op, 'native_refused')
	end
	op.nativeOp, op.revision = id, record.revision
	op.outcome = outcome and outcome.key or 'success'
	op.pendingOutcome = outcome
	op.state = Phase.SUBMITTED
	Storage.Phase(op, Phase.SUBMITTED, op.outcome)
	if not participants(op) then return release(op, 'patient_left') end
	local options = { expectedRevision = op.revision, operationId = op.nativeOp }
	local called, result, reason
	if op.action == 'install' then
		called, result, reason = pcall(cyberware.install, op.patient, chrome.native.id, Model.GradeId(op.tier), options)
	else
		options.slot = chrome.slot
		called, result, reason = pcall(cyberware.remove, op.patient, options)
	end
	if not called or type(result) ~= 'table' then
		Open77.log.warn(('[ripperdoc] the native %s of %s was refused: %s'):format(op.action, op.id,
			tostring(called and reason or result)))
		return release(op, 'native_refused')
	end
	if result.ticket == nil then return commit(op, outcome, true) end
	op.ticket = result.ticket
	op.submittedAt = now()
	byTicket[result.ticket] = op.id
end

--- The dice, one roll in [0, 1). A field so the suite can load them.
-- @author dop42
function M.Random() return math.random() end

--- The bar ran out: the dice, then the knife. On a coroutine.
operate = function(op)
	if op.closed then return end
	if not participants(op) then return release(op, 'patient_left') end
	local patient = sourceOf(op.patientCid)
	op.patient = patient
	local here, there = pointOf(op.doc), patient and pointOf(patient) or nil
	if patient == nil then return release(op, 'patient_left') end
	if apart(here, there) > OPX.Spots.ServerReach(S.docReach) then return release(op, 'moved') end
	local outcome = nil
	if M.Random() < op.risk then outcome = Model.PickOutcome(S, M.Random()) end
	local applied = outcome == nil or outcome.apply
	if applied and op.native then return submit(op, outcome) end
	return commit(op, outcome, applied)
end

--- The platform's answer to one of this module's tickets. Others are ignored.
-- @author dop42
function M.NativeCompleted(player, ticket, encoded)
	local id = byTicket[ticket]
	if id == nil then return end
	byTicket[ticket] = nil
	local op = ops[id]
	if op == nil then return end
	local result = type(encoded) == 'table' and encoded or nil
	if result == nil and type(encoded) == 'string' then
		local read, decoded = pcall(json.decode, encoded)
		result = read and type(decoded) == 'table' and decoded or {}
	end
	op.ticket = nil
	CreateThread(function()
		if result ~= nil and result.ok == true then
			commit(op, op.pendingOutcome, true)
		else
			Open77.log.warn(('[ripperdoc] the native %s of %s failed: %s'):format(op.action, op.id,
				tostring(result and result.error)))
			release(op, 'native_failed')
		end
	end)
end

-- ── crash recovery ──────────────────────────────────────────────────────────

local function fromReceipt(row)
	local part = type(row.part) == 'table' and row.part or {}
	return {
		id = row.id, clinic = row.clinic, docCid = row.docCid, patientCid = row.patientCid,
		action = row.action, chrome = row.chrome, tier = row.tier, total = row.total, method = row.method,
		part = { source = part.source, slot = part.slot, meta = type(part.meta) == 'table' and part.meta or {},
			serial = part.serial },
		origin = part.origin, condition = part.condition or 100, humanity = part.humanity or 0,
		native = row.phase == Phase.SUBMITTED, nativeOp = row.nativeOp, revision = row.revision,
		receipt = true, charged = true, taken = row.action == 'install',
		outcome = row.outcome,
	}
end

--- Replays one submitted receipt for a patient who is now loaded. On a coroutine.
local function replay(row, player)
	local op = fromReceipt(row)
	op.patient = player
	ops[op.id] = op
	local chrome = S.chrome[op.chrome]
	local cyberware = Native.Api()
	local record
	local original = dataOf(player)
	for _ = 1, 40 do
		if original == nil or original.citizenId ~= row.patientCid or dataOf(player) ~= original then break end
		record = nativeRecord(player)
		if record ~= nil then break end
		Wait(500)
	end
	if chrome == nil or chrome.native == nil or cyberware == nil or record == nil
		or dataOf(player) ~= original or original.citizenId ~= row.patientCid then
		Open77.log.warn(('[ripperdoc] the submitted operation %s could not be replayed yet'):format(op.id))
		ops[op.id] = nil
		resume[row.patientCid] = resume[row.patientCid] or {}
		table.insert(resume[row.patientCid], row)
		return
	end
	local outcome = outcomeByKey(row.outcome)
	op.pendingOutcome = outcome
	local options = { expectedRevision = op.revision, operationId = op.nativeOp }
	local called, result
	if op.action == 'install' then
		called, result = pcall(cyberware.install, player, chrome.native.id, Model.GradeId(op.tier), options)
	else
		options.slot = chrome.slot
		called, result = pcall(cyberware.remove, player, options)
	end
	if called and type(result) == 'table' then
		if result.ticket == nil then return commit(op, outcome, true) end
		op.ticket = result.ticket
		byTicket[result.ticket] = op.id
		return
	end
	local held = record[chrome.slot]
	local done = (op.action == 'install' and type(held) == 'table' and held.definition == chrome.native.id)
		or (op.action == 'remove' and held == nil)
	if done then return commit(op, outcome, true) end
	return release(op, 'native_failed')
end

local function recover()
	local rows = Storage.Open()
	local given, waiting = 0, 0
	for _, row in ipairs(rows) do
		if row.phase == Phase.RESERVED then
			local op = fromReceipt(row)
			op.native = false
			release(op, 'restart')
			given = given + 1
		else
			resume[row.patientCid] = resume[row.patientCid] or {}
			table.insert(resume[row.patientCid], row)
			waiting = waiting + 1
			local player = sourceOf(row.patientCid)
			if player ~= nil then
				resume[row.patientCid] = nil
				CreateThread(function() replay(row, player) end)
			end
		end
	end
	if given + waiting > 0 then
		Open77.log.info(('[ripperdoc] receipts: %d interrupted operation(s) given back, %d native one(s) to replay')
			:format(given, waiting))
	end
end

--- The recovery pass, exposed for the suite and for a staff re-run.
M.Recover = recover

-- ── the stash and the terminal ──────────────────────────────────────────────

function M.OpenStash(player, key)
	if OPX.Cooling(player, 'ripperdoc.stash', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local clinic = type(key) == 'string' and S.clinics[key] or nil
	if clinic == nil or clinic.chest == nil then return answer(player, false, 'no_stash'), 'no_stash' end
	local allowed, code = gate(clinic, dataOf(player), clinic.stockGrade)
	if not allowed then return answer(player, false, code), code end
	local chest = clinic.chest
	local opened = inventory().OpenStash(player, chest.name, { slots = chest.slots, maxWeight = chest.maxWeight,
		label = chest.label, position = { x = chest.x, y = chest.y, z = chest.z }, bucket = clinic.bucket })
	if not ok(opened) then
		local why = type(opened) == 'table' and tostring(opened.error) or 'unavailable'
		if not OPX.Locale.Exists('ripperdoc.error.' .. why) then why = 'unavailable' end
		return answer(player, false, why), why
	end
	OPX.Audit.Log({ event = 'ripperdoc.stash', source = player, message = chest.name,
		data = { clinic = clinic.key } })
	return true
end

--- Buys one catalogue row at a clinic terminal, into the clinic stash.
-- @author dop42
function M.Supply(player, key, index)
	if OPX.Cooling(player, 'ripperdoc.supply', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local clinic = type(key) == 'string' and S.clinics[key] or nil
	if clinic == nil or clinic.supply == nil then return answer(player, false, 'no_supply'), 'no_supply' end
	if clinic.chest == nil then return answer(player, false, 'no_stash'), 'no_stash' end
	index = math.tointeger(tonumber(index))
	local row
	for _, entry in ipairs(clinic.supply.catalog) do
		if entry.index == index then row = entry end
	end
	if row == nil then return answer(player, false, 'invalid'), 'invalid' end
	if down(player) then return answer(player, false, 'player_down'), 'player_down' end
	local at = pointOf(player)
	if at == nil or at.bucket ~= clinic.bucket
		or apart(at, { x = clinic.supply.x, y = clinic.supply.y, z = clinic.supply.z, bucket = clinic.bucket })
			> OPX.Spots.ServerReach(S.promptRadius) then
		return answer(player, false, 'not_at_terminal'), 'not_at_terminal'
	end
	local buyer = dataOf(player)
	if buyer == nil then return answer(player, false, 'no_character'), 'no_character' end
	local allowed, code = gate(clinic, buyer, row.grade)
	if not allowed then return answer(player, false, code), code end
	local chrome = S.chrome[row.chrome]
	local reason = 'ripperdoc:supply:' .. clinic.key
	if not charge(player, clinic.money, row.cost, reason) then
		return answer(player, false, 'not_enough_money'), 'not_enough_money'
	end
	local added = inventory().AddToStash(clinic.chest.name, chrome.item, 1, Model.NewPart(row.tier, row.origin))
	if not ok(added) then
		pay(buyer.citizenId, clinic.money, row.cost, reason .. ':refund')
		return answer(player, false, 'stash_full'), 'stash_full'
	end
	OPX.Audit.Log({ event = 'ripperdoc.supply', source = player,
		message = ('%s T%d (%s) for %d into %s'):format(row.chrome, row.tier, row.origin, row.cost, clinic.chest.name),
		data = { clinic = clinic.key, chrome = row.chrome, tier = row.tier, origin = row.origin, cost = row.cost } })
	return answer(player, true, 'supplied', { chrome = chrome.label, tier = row.tier, cost = row.cost })
end

-- ── housekeeping ────────────────────────────────────────────────────────────

local function sweep()
	local at = now()
	local expired = {}
	for id, op in pairs(ops) do
		if op.state == 'invited' and at > op.untilMs then expired[#expired + 1] = op end
		if op.state == Phase.SUBMITTED and op.submittedAt ~= nil and not op.toldPending
			and at - op.submittedAt > S.native.timeoutMs then
			op.toldPending = true
			answer(op.doc, false, 'native_pending')
			answer(op.patient, false, 'native_pending')
		end
	end
	for _, op in ipairs(expired) do
		drop(op)
		TriggerClientEvent(M.Event.UNINVITE, op.patient, op.id)
		answer(op.doc, false, 'expired')
	end
end

local function left(playerId)
	local player = math.tointeger(tonumber(playerId))
	local op = player ~= nil and ops[opOf[player] or ''] or nil
	if op == nil then return end
	if op.state == 'invited' then
		drop(op)
		if player == op.doc then
			TriggerClientEvent(M.Event.UNINVITE, op.patient, op.id)
		else
			answer(op.doc, false, 'patient_left')
		end
	end
	-- A reserved operation ends through its bar (the doc) or at the bar's end
	-- (the patient); a submitted one through the platform's answer.
end

local function onLoaded(source, data)
	local player = math.tointeger(tonumber(source))
	local cid = type(data) == 'table' and data.citizenId or nil
	if player == nil or cid == nil or resume[cid] == nil then return end
	local rows = resume[cid]
	resume[cid] = nil
	for _, row in ipairs(rows) do CreateThread(function() replay(row, player) end) end
end

local function report(source)
	local lines = {}
	for _, clinic in ipairs(S.clinicList) do
		lines[#lines + 1] = ('%s "%s" %s chairs=%d stash=%s terminal=%s'):format(clinic.key, clinic.label,
			clinic.licensed and 'licensed' or 'unlicensed', #clinic.chairs, clinic.chest and clinic.chest.name or '-',
			clinic.supply and (#clinic.supply.catalog .. ' rows') or '-')
	end
	for _, key in ipairs(S.placeholders) do lines[#lines + 1] = key .. ' DISABLED: not surveyed yet (0,0,0)' end
	for _, line in ipairs(S.problems) do lines[#lines + 1] = 'REFUSED: ' .. line end
	lines[#lines + 1] = ('%d clinic(s) open, %d chrome; %d operation(s) in flight'):format(#S.clinicList,
		#S.chromeList, OPX.Table.Count(ops))
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

local function humanityCommand(source, args, audience)
	if not audience() then return end
	local target = math.tointeger(tonumber(args[1]))
	local data = target and dataOf(target) or nil
	if data == nil then return OPX.CommandResult(source, false, 'usage: <player id> [humanity]') end
	local humanity, installed = bodyOf(data.citizenId)
	if not audience() then return end
	local value = OPX.Math.Finite(tonumber(args[2]))
	if value ~= nil then
		humanity = math.max(-1000, math.min(1000, value))
		writeBody(data.citizenId, humanity, installed)
		OPX.Audit.Log({ event = 'ripperdoc.humanity', source = source > 0 and source or nil,
			message = ('%s -> %s'):format(data.citizenId, tostring(humanity)) })
	end
	local names = {}
	for _, entry in ipairs(installed or {}) do names[#names + 1] = ('%s T%s'):format(entry.chrome, tostring(entry.tier)) end
	if not audience() then return end
	OPX.CommandResult(source, true, ('%s: humanity %s, capacity %s/%s, chrome: %s'):format(data.citizenId,
		tostring(humanity), tostring(Model.CapacityUsed(S, installed or {})), tostring(S.maxCapacity),
		#names > 0 and table.concat(names, ', ') or 'none'))
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Reads the config and contributes the receipts table. Never yields.
-- @author dop42
function M.Init()
	ops, opOf, byTicket, resume, serial = {}, {}, {}, {}, 0
	S = Model.Read(M.Settings)
	M.S = S
	OPX.Schema.Add(Storage.SCHEMA)
end

--- Publishes the read side and the two doors a creator may drive.
-- @author dop42
function M.Api()
	OPX.Api.Provide('ripperdoc', 1, {
		Body = function(citizenId)
			local humanity, installed = bodyOf(citizenId)
			if humanity == nil then return OPX.Result.Err('ripperdoc.noCharacter') end
			return OPX.Result.Ok({ humanity = humanity, cyberware = installed,
				capacity = Model.CapacityUsed(S, installed), maxCapacity = S.maxCapacity })
		end,
		Clinics = function() return S.clinicList end,
		Chrome = function() return S.chromeList end,
		Operation = function(player)
			local op = ops[opOf[player] or '']
			if op == nil then return nil end
			return { id = op.id, state = op.state, action = op.action, chrome = op.chrome, clinic = op.clinic }
		end,
	})
end

--- Registers the items, the native definitions, the doors and the recovery. On a coroutine.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	for _, line in ipairs(S.problems) do Open77.log.warn('[ripperdoc] config: ' .. line) end
	if #S.placeholders > 0 then
		Open77.log.info(('[ripperdoc] disabled until surveyed (0,0,0): %s'):format(table.concat(S.placeholders, ', ')))
	end
	if character == nil or inventory() == nil then
		Open77.log.error('[ripperdoc] no character or inventory contract: no clinic opens')
		return
	end

	-- THE PARTS ARE ITEMS ONLY WHERE A CLINIC IS OPEN. With every clinic still a
	-- 0,0,0 placeholder there is no chrome economy to carry, and a runtime item
	-- is something every client is sent on hello; once one clinic is surveyed,
	-- every chrome item is registered (a part outlives the clinic it came from).
	-- A stack already in a bag waits for its registration, it is not lost.
	if #S.clinicList > 0 then
		for _, chrome in ipairs(S.chromeList) do
			local registered = inventory().RegisterItem(chrome.item, {
				label = chrome.label, description = chrome.description, weight = chrome.weight,
				stack = false, category = 'cyberware', model = chrome.model,
			}, OWNER)
			if not ok(registered) then
				Open77.log.warn(('[ripperdoc] the item %s was refused: %s'):format(chrome.item,
					tostring(type(registered) == 'table' and registered.error)))
			end
		end
	end

	Native.Define(S)
	Native.Start(S, character)

	RegisterNetEvent(M.Event.CHART, function(patient)
		local player = tonumber(source) or 0
		if player <= 0 or type(patient) ~= 'number' then return end
		local audience = recipient(player)
		CreateThread(function() if audience() then M.Chart(math.tointeger(player), patient) end end)
	end)
	RegisterNetEvent(M.Event.PROPOSE, function(payload)
		local player = tonumber(source) or 0
		if player <= 0 or type(payload) ~= 'table' then return end
		local audience = recipient(player)
		CreateThread(function() if audience() then M.Propose(math.tointeger(player), payload) end end)
	end)
	RegisterNetEvent(M.Event.CONSENT, function(id, accepted)
		local player = tonumber(source) or 0
		if player <= 0 or type(id) ~= 'string' then return end
		M.Consent(math.tointeger(player), id, accepted == true)
	end)
	RegisterNetEvent(M.Event.STASH, function(key)
		local player = tonumber(source) or 0
		if player <= 0 or type(key) ~= 'string' or #key > 48 then return end
		local audience = recipient(player)
		CreateThread(function() if audience() then M.OpenStash(math.tointeger(player), key) end end)
	end)
	RegisterNetEvent(M.Event.SUPPLY, function(key, index)
		local player = tonumber(source) or 0
		if player <= 0 or type(key) ~= 'string' or #key > 48 then return end
		local audience = recipient(player)
		CreateThread(function() if audience() then M.Supply(math.tointeger(player), key, index) end end)
	end)
	AddEventHandler(M.NATIVE_COMPLETED, function(player, ticket, encoded)
		M.NativeCompleted(player, ticket, encoded)
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, left)
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'loaded'), onLoaded)

	OPX.Command.Register(M.Command.CLINICS, { restricted = true, help = 'ripperdoc.help.clinics' },
		function(source) report(source) end)
	OPX.Command.Register(M.Command.HUMANITY, { restricted = true, help = 'ripperdoc.help.humanity',
		params = {
			{ name = 'player', help = locale('ripperdoc.help.player') },
			{ name = 'value', optional = true, help = locale('ripperdoc.help.value') },
		} },
		function(source, args)
			local audience = recipient(source, M.Command.HUMANITY)
			CreateThread(function() humanityCommand(source, args, audience) end)
		end)

	sweepJob = OPX.Scheduler.Every('ripperdoc:sweep', 1000, sweep)
	CreateThread(recover)

	Open77.log.info(('[ripperdoc] ready: %d clinic(s), %d chrome'):format(#S.clinicList, #S.chromeList))
end

--- Gives back every operation still in escrow before the bar ends.
-- @author dop42
function M.Stop()
	if sweepJob ~= nil then pcall(OPX.Scheduler.Cancel, sweepJob) end
	sweepJob = nil
	-- Reserved and submitted operations keep their receipt: the next boot
	-- gives the first back and replays the second. Only invites are dropped.
	for _, op in pairs(ops) do
		if op.state == 'invited' then TriggerClientEvent(M.Event.UNINVITE, op.patient, op.id) end
	end
	ops, opOf, byTicket = {}, {}, {}
	Native.Stop()
	end
