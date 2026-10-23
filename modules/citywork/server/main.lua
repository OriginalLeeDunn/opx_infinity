--- Service orders use contracts for durable state, budgets and one-time payouts.
-- @author dop42
-- Inventory contains the proof, not the reward. All net payloads merely name
-- a trade/action; locations, grade, pay and task duration come from this VM.
local M = OPX.Modules.Get('citywork')
local built, character, inventory, contracts, progress
local pending, completing, enrolling, sequence, stopped = {}, {}, {}, 0, true
local TYPE_JOB = { shard_delivery = 'courier', relay_maintenance = 'technician' }
local function wall() return math.floor(Open77.time.unix()) end
local function dataOf(player)
	local loaded = character.GetPlayer(player)
	return loaded and loaded.PlayerData
end
local function near(player, point)
	if not point or OPX.Life.Down(player) then return false end
	local snapshot = Open77.players.get(player)
	if type(snapshot) ~= 'table' or snapshot.fresh ~= true or snapshot.ready ~= true or snapshot.bucket ~= point.bucket then return false end
	local at = snapshot.position
	if type(at) ~= 'table' then return false end
	local x, y, z = OPX.Math.Finite(at.x), OPX.Math.Finite(at.y), OPX.Math.Finite(at.z)
	if not x or not y or not z then return false end
	return (x - point.x)^2 + (y - point.y)^2 + (z - point.z)^2 <= built.reach^2
end
local function tell(player, code, success)
	local key = success and ('citywork.' .. code) or ('citywork.error.' .. tostring(code))
	if not OPX.Locale.Exists(key) then key = 'citywork.error.generic' end
	OPX.NotifyLocale(player, key, nil, success and 'success' or 'error')
end
local function eligible(record, player, atDispatch)
	local data = dataOf(player)
	local objective = record.objective
	local job = TYPE_JOB[record.type]
	if stopped or not job or not data or data.citizenId ~= objective.worker then return false, 'no_character' end
	if objective.professional and M.Model.Professional(data, job) == nil then return false, 'off_duty' end
	if atDispatch and not near(player, built.dispatch) then return false, 'too_far' end
	return true
end
local function activeFor(cid)
	local rows = contracts.List({ mercCid = cid })
	for _, row in ipairs(rows) do
		if TYPE_JOB[row.type] and (row.state == 'accepted' or row.state == 'in_progress'
			or row.state == 'proof' or row.state == 'settling') then return row end
	end
end
local function view(player)
	local data = dataOf(player)
	if not data then return end
	local active = activeFor(data.citizenId)
	local payload = { canEnrol = built and built.selfEnrol or false }
	if active then
		-- Get excludes private objectives; our registered type's tick rebuilds
		-- this index from the persisted record after a restart.
		local objective = M.Tasks[active.id]
		if objective then
			local point = built.routes[objective.route]
			payload.active = { id = active.id, job = TYPE_JOB[active.type], route = objective.route,
				pay = active.reward, point = point, state = active.state }
		end
	end
	TriggerClientEvent(M.Event.VIEW, player, payload)
end

-- This index is rebuilt by the objective's tick after a restart, and never
-- acts as completion proof. The persisted contract and tagged inventory do.
M.Tasks = {}
local function objectiveOf(raw)
	if type(raw) ~= 'table' or type(raw.route) ~= 'string' or not built.routes[raw.route] then return nil, 'bad_objective' end
	local parsed = OPX.CitizenId.Parse(raw.worker)
	if not parsed.ok then return nil, 'bad_objective' end
	return { route = raw.route, worker = parsed.value, professional = raw.professional == true }
end
local function registerType(job, kind)
	return contracts.RegisterObjectiveType(kind, {
		public = true,
		validate = objectiveOf,
		describe = function(objective)
			return locale('citywork.route.' .. objective.route), 'Night City services'
		end,
		waypoint = function(objective) return built.routes[objective.route] end,
		canStart = function(record, player) return eligible(record, player, true) end,
		start = function(record, player)
			local cid = record.mercCid
			local added = inventory.AddItem(cid, M.ITEM, 1, { contract = record.id, kind = kind })
			if not added.ok then return false, 'cannot_start' end
			if not eligible(record, player, true) then
				inventory.RemoveWhere(cid, M.ITEM, { contract = record.id })
				return false, 'no_character'
			end
			M.Tasks[record.id] = record.objective
			return true
		end,
		stop = function(record)
			M.Tasks[record.id] = nil
			local running = completing[record.id]
			completing[record.id] = nil
			if running and running.bar then progress.Stop(running.player, 'citywork', running.bar) end
			if record.mercCid then inventory.RemoveWhere(record.mercCid, M.ITEM, { contract = record.id }) end
			local loaded = record.mercCid and character.GetPlayerByCitizenId(record.mercCid)
			if loaded then TriggerClientEvent(M.Event.VIEW, loaded.PlayerData.source, {}) end
		end,
		tick = function(record)
			if record.state == 'in_progress' then M.Tasks[record.id] = record.objective end
		end,
	})
end

local function startWork(player, job, professional)
	if stopped or not built or not M.Types[job] then return tell(player, 'refused') end
	local data = dataOf(player)
	if not data or not near(player, built.dispatch) then return tell(player, 'too_far') end
	local cid, session = data.citizenId, OPX.Sessions[player]
	if pending[cid] then return tell(player, 'busy') end
	local pay = M.Model.Pay(built, data, job, professional == true)
	if not pay then return tell(player, 'off_duty') end
	pending[cid] = true
	local ran, failure = pcall(function()
		local rows = contracts.List()
		local open = 0
		for _, row in ipairs(rows) do
			if row.mercCid == cid then return tell(player, 'busy') end
			if TYPE_JOB[row.type] then open = open + 1 end
		end
		if open >= built.maxOpen then return tell(player, 'busy') end
		-- Count unresolved offers too: retries cannot fill the board with one
		-- citizen's unaccepted work orders after an interrupted accept.
		for id, objective in pairs(M.Tasks) do
			if not contracts.Get(id) then M.Tasks[id] = nil
			elseif objective.worker == cid then return tell(player, 'busy') end
		end
		sequence = sequence + 1
		local route = built.order[(sequence - 1) % #built.order + 1]
		local objective = { route = route, worker = cid, professional = professional == true }
		local posted = contracts.Post({ type = M.Types[job], funded = 'mint', poster = 'Night City services',
			title = locale('citywork.' .. job), brief = locale('citywork.brief.' .. job), reward = pay,
			cutPct = 0, minCred = 0, deadlineS = 1800, validate = 'auto', objective = objective })
		if not posted.ok then return tell(player, posted.error == 'mint_cap' and 'mint_cap' or 'generic') end
		local id = posted.value
		M.Tasks[id] = objective
		if stopped or dataOf(player) ~= data or OPX.Sessions[player] ~= session or not near(player, built.dispatch) then
			contracts.Cancel(id)
			return
		end
		local accepted = contracts.Accept(player, id)
		if not accepted.ok then
			contracts.Cancel(id)
			return tell(player, 'busy')
		end
		view(player)
	end)
	pending[cid] = nil
	if not ran then Open77.log.error('[citywork] request failed: ' .. tostring(failure)); tell(player, 'generic') end
end

local function completeWork(player)
	local data = dataOf(player)
	local active = data and activeFor(data.citizenId)
	if not active or active.state ~= 'in_progress' then return tell(player, 'refused') end
	local objective = M.Tasks[active.id]
	if not objective then return tell(player, 'busy') end
	local record = { type = active.type, objective = objective }
	if not eligible(record, player, false) then return tell(player, 'off_duty') end
	local point = built.routes[objective.route]
	if not near(player, point) then return tell(player, 'too_far') end
	local acceptTtl = math.tointeger(tonumber(OPX.Config.MODULES.contracts.ACCEPT_TTL_S)) or 1800
	if wall() < active.deadlineAt - acceptTtl + built.travel then return tell(player, 'too_early') end
	if completing[active.id] then return tell(player, 'busy') end
	local ticket = { player = player, cid = data.citizenId, session = OPX.Sessions[player], consumed = false }
	completing[active.id] = ticket
	local started = progress.Start(player, 'citywork', { label = locale(active.type == M.Types.courier and 'citywork.handover' or 'citywork.service'),
		durationMs = active.type == M.Types.courier and built.handover or built.service,
		cancelable = true, animation = {
			name = active.type == M.Types.courier and 'give' or 'repair', fallback = 'examine',
		} }, function(_, outcome)
		if completing[active.id] ~= ticket or ticket.consumed then return end
		if not outcome.completed then completing[active.id] = nil; return end
		ticket.consumed = true
		CreateThread(function()
			local ran, failure = pcall(function()
				local current = contracts.Get(active.id)
				if stopped or dataOf(player) ~= data or OPX.Sessions[player] ~= ticket.session
					or not current or current.state ~= 'in_progress' or not eligible(record, player, false)
					or not near(player, point) then return end
				local removed = inventory.RemoveWhere(ticket.cid, M.ITEM, { contract = active.id, kind = active.type })
				if not removed.ok or (tonumber(removed.value) or 0) < 1 then return tell(player, 'no_package') end
				-- The bag call may yield; a new occupant of the connection is never
				-- proof of this worker's attendance. Restore only the tagged item.
				if stopped or dataOf(player) ~= data or OPX.Sessions[player] ~= ticket.session
					or not eligible(record, player, false) or not near(player, point) then
					inventory.AddItem(ticket.cid, M.ITEM, 1, { contract = active.id, kind = active.type })
					return
				end
				local reported = contracts.ReportProof(active.id, { kind = active.type, route = objective.route, at = wall() })
				if not reported.ok then
					local remaining = contracts.Get(active.id)
					if remaining and remaining.state == 'in_progress' then
						inventory.AddItem(ticket.cid, M.ITEM, 1, { contract = active.id, kind = active.type })
					end
				end
				if dataOf(player) == data and OPX.Sessions[player] == ticket.session then
					if reported.ok then tell(player, 'done', true) else tell(player, 'generic') end
					view(player)
				end
			end)
			if completing[active.id] == ticket then completing[active.id] = nil end
			if not ran then Open77.log.error('[citywork] handover failed: ' .. tostring(failure)) end
		end)
	end)
	if not started.ok then completing[active.id] = nil; return tell(player, 'busy') end
	ticket.bar = started.value.id
end

local function enrol(player, job)
	if not built.selfEnrol or not M.Types[job] then return tell(player, 'refused') end
	local data = dataOf(player)
	if not data or not near(player, built.dispatch) then return tell(player, 'too_far') end
	local cid, session = data.citizenId, OPX.Sessions[player]
	if enrolling[cid] then return tell(player, 'busy') end
	enrolling[cid] = true
	local ran, failure = pcall(function()
		local membership = type(data.jobs) == 'table' and data.jobs[job] or nil
		if membership == nil and not (data.job and data.job.name == job) then
			local joined = character.AddPlayerToJob(cid, job, 0)
			if not joined.ok then return tell(player, 'refused') end
		end
		if dataOf(player) ~= data or OPX.Sessions[player] ~= session or not near(player, built.dispatch) then return end
		local activated = character.SetPlayerPrimaryJob(cid, job)
		if dataOf(player) == data and OPX.Sessions[player] == session then tell(player, activated.ok and 'enrolled' or 'refused', activated.ok) end
	end)
	enrolling[cid] = nil
	if not ran then Open77.log.error('[citywork] enrolment failed: ' .. tostring(failure)); tell(player, 'generic') end
end

function M.Init()
	built = M.Model.Build(OPX.Config.MODULES.citywork)
	pending, completing, enrolling, M.Tasks, sequence, stopped = {}, {}, {}, {}, 0, false
end
function M.Start()
	if not built then stopped = true; Open77.log.warn('[citywork] invalid service configuration'); return end
	character, inventory, contracts, progress = OPX.Api.Get('character'), OPX.Api.Get('inventory'), OPX.Api.Get('contracts'), OPX.Api.Get('progress')
	local registered = inventory.RegisterItem(M.ITEM, { label = locale('citywork.item'), weight = 600, stack = false, drop = false,
		model = 'electronics.monitor.device' }, 'citywork', 1)
	if not registered.ok then stopped = true; Open77.log.error('[citywork] service item refused'); return end
	for job, kind in pairs(M.Types) do
		if not registerType(job, kind).ok then stopped = true; Open77.log.error('[citywork] objective type refused: ' .. kind); return end
	end
	for _, ending in ipairs({ 'paid', 'failed', 'expired', 'cancelled' }) do
		AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'contracts', ending), function(_, payload)
			if type(payload) == 'table' and TYPE_JOB[payload.type] then M.Tasks[payload.id] = nil end
		end)
	end
	RegisterNetEvent(M.Event.REQUEST, function(payload)
		local player = math.tointeger(tonumber(source))
		if stopped or not player or player < 1 or type(payload) ~= 'table' or OPX.Cooling(player, 'citywork.request', 1000) then return end
		CreateThread(function()
			if payload.action == 'view' then view(player)
			elseif payload.action == 'start' then startWork(player, payload.job, payload.professional == true)
			elseif payload.action == 'complete' then completeWork(player)
			elseif payload.action == 'enrol' then enrol(player, payload.job) end
		end)
	end)
	if built.command then OPX.Command.Register(built.command, { help = 'citywork.help', cooldownMs = 1000 }, function(player)
		if player > 0 then view(player) end
	end) end
end
function M.Stop()
	stopped = true
	for id, ticket in pairs(completing) do
		completing[id] = nil
		if ticket.bar then progress.Stop(ticket.player, 'citywork', ticket.bar) end
	end
	-- Active gigs remain durable; their type is registered again on restart.
	if contracts then for _, kind in pairs(M.Types) do contracts.UnregisterObjectiveType(kind) end end
end
M.Server = { StartWork = startWork, Complete = completeWork, Enrol = enrol, View = view }
