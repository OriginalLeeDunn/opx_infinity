--- Service work exercises real manifest, contracts, progress and inventory handlers.
-- @author dop42
-- Only database-bound module storage is replaced by in-memory rows and a ledger.
local Host = dofile('tests/host.lua')
local function copy(value)
	if type(value) ~= 'table' then return value end
	local out = {}; for key, entry in pairs(value) do out[key] = copy(entry) end; return out
end
local function result(value) return { ok = true, value = value } end
local function database() return Host.Database({ scalar = function() return 1 end,
	update = function() return 1 end, query = function() return {} end,
	single = function() return nil end, insert = function() return 1 end,
	transaction = function() return true end }) end
local function fixtures(env, file)
	if file == 'modules/contracts/server/storage.lua' then
		local S, store = env.OPX.Modules.Get('contracts').Storage, { rows = {}, ledger = {}, nextId = 0 }
		S.Insert = function(record)
			store.nextId = store.nextId + 1
			local row = copy(record); row.id = store.nextId; store.rows[row.id] = row
			return result(row.id)
		end
		S.Move = function(record, from, rev)
			local old = store.rows[record.id]
			if not old or old.state ~= from or old.rev ~= rev then return result(false) end
			store.rows[record.id] = copy(record); return result(true)
		end
		S.Forget = function(id) store.rows[id] = nil; return result(true) end
		S.LoadOpen = function()
			local rows = {}
			for _, row in pairs(store.rows) do
				if env.OPX.Modules.Get('contracts').Access.IsOpen(row.state) then rows[#rows + 1] = copy(row) end
			end
			return result(rows)
		end
		S.Reserve = function(op)
			local row = store.ledger[op.id]
			if row then return result({ fresh = false, state = row.state, durable = row.durable_version == 1 }) end
			store.ledger[op.id] = copy(op); store.ledger[op.id].state = 'reserved'; store.ledger[op.id].durable_version = 1
			return result({ fresh = true, state = 'reserved', durable = true })
		end
		S.Settle = function(id, state)
			local row = store.ledger[id]
			if row and row.state == 'reserved' then row.state = state end
			return result(true)
		end
		S.Rearm = function(id)
			local row = store.ledger[id]
			if row and row.state == 'cancelled' and row.durable_version == 1 then row.state = 'reserved'; return result(true) end
			return result(false)
		end
		S.Pending = function()
			local pending = {}
			for id, row in pairs(store.ledger) do
				if row.state == 'reserved' then
					pending[#pending + 1] = { id = id, contractId = row.contractId, phase = row.phase,
						citizenId = row.citizenId, amount = row.amount, durable = row.durable_version == 1 }
				end
			end
			return result(pending)
		end
		S.OpInfo = function(id)
			local row = store.ledger[id]
			return result(row and { state = row.state, durable_version = row.durable_version or 0,
				amount = row.amount, contract_id = row.contractId, phase = row.phase, citizen_id = row.citizenId })
		end
		S.Committed = function(id) return result(store.ledger[id] and store.ledger[id].state == 'committed') end
		S.MintedLastHour = function()
			local total = 0
			for _, row in pairs(store.ledger) do if row.phase == 'mint' and row.state == 'committed' then total = total + row.amount end end
			return result(total)
		end
		S.History = function() return result(true) end
		env.cityworkStore = store
	elseif file == 'modules/inventory/server/storage.lua' then
		local S, ids, sequence = env.OPX.Modules.Get('inventory').Storage, {}, 0
		S.Read = function(kind, owner, slots, maxWeight)
			local key = kind .. ':' .. owner
			if not ids[key] then sequence = sequence + 1; ids[key] = sequence end
			return { id = ids[key], kind = kind, owner = owner, slots = slots, maxWeight = maxWeight, items = {} }
		end
	end
end
local function boot(side, configure)
	local env, control = Host.Environment(side, database())
	for _, file in ipairs(Host.LoadOrder('open77.lua', side)) do
		local chunk = assert(loadfile(file, 't', env)); assert(pcall(chunk), file)
		fixtures(env, file)
		if configure then configure(env, file) end
	end
	if side == 'server' then dofile('tests/money-store.lua').Install(env) end
	if side == 'client' then control.Fire('onClientResourceStart', 'opx_infinity') end
	control.Pump(300); control.ReadyPages()
	return env, control
end
local function run(env, control, fn)
	local done, answer = false, nil
	env.CreateThread(function() answer = table.pack(pcall(fn)); done = true end)
	for _ = 1, 80 do if done then assert(answer[1], answer[2]); return table.unpack(answer, 2, answer.n) end; control.Pump(1) end
	error('service action did not finish')
end
local env, control = boot('server')
local OPX = env.OPX
assert(OPX.Modules.IsRunning('citywork'), 'the real manifest did not start citywork')
local city, progressModule = OPX.Modules.Get('citywork'), OPX.Modules.Get('progress')
local contracts, inventory, character = OPX.Api.Get('contracts'), OPX.Api.Get('inventory'), OPX.Api.Get('character')
local config = OPX.Config.MODULES.citywork
local function stand(player, point, bucket)
	control.Stand(player, point)
	control.Bucket(player, bucket or point.bucket or 0)
end
local function characterAt(player, job, grade, duty)
	local C = OPX.Modules.Get('character')
	control.Admit(player, 'citywork-account-' .. player); control.Life(player, 'alive')
	local cid = OPX.CitizenId.Generate()
	local data = { source = player, userId = 'citywork-account-' .. player, citizenId = cid,
		charInfo = { firstName = 'Test', lastName = 'Worker' }, metadata = {}, money = { EDDIES = 0, BANK = 0 },
		job = { name = job or 'unemployed', onDuty = duty ~= false, grade = { level = grade or 0 } },
		jobs = { [job or 'unemployed'] = grade or 0 }, gang = { name = 'none', grade = { level = 0 } }, gangs = {} }
	local loaded = { PlayerData = data, Functions = { UpdatePlayerData = function() end } }
	C.Players[player] = loaded; C.Registry.byCitizenId[cid] = player; C.Registry.byUserId[data.userId] = player
	run(env, control, function() return OPX.Modules.Get('inventory').Players.Attach(player) end)
	stand(player, config.DISPATCH)
	return data
end
local function lastEvent(name, player)
	for i = #control.clientEvents, 1, -1 do
		local event = control.clientEvents[i]
		if event.name == name and event.source == player then return event[1] end
	end
end
local function active(cid)
	for _, row in ipairs(contracts.List({ mercCid = cid })) do if row.state == 'in_progress' then return row end end
end
local function packet(player, payload)
	env.source = player; control.netEvents[city.Event.REQUEST](payload); env.source = nil; control.Pump(20)
end
local function advance(ms)
	for _ = 1, math.ceil(ms / 500) do control.Advance(500); control.Pump(1) end
end
local function finishBar(player, bar)
	advance(bar.durationMs + 1000)
	env.source = player; control.netEvents[progressModule.Event.REPORT](bar.id, 'finished'); env.source = nil
	control.Pump(20)
end
local one = characterAt(71)
stand(71, config.DISPATCH, 99)
run(env, control, function() city.Server.StartWork(71, 'courier', false) end)
assert(not active(one.citizenId), 'dispatch in a different bucket created work')
stand(71, config.DISPATCH)
run(env, control, function() city.Server.StartWork(71, 'forged', false) end)
assert(not active(one.citizenId), 'an unknown trade created a service contract')
packet(71, { action = 'start', job = 'courier', professional = false, reward = 999999,
	route = 'forged', objective = { worker = 'attacker' } })
local first = assert(active(one.citizenId), 'a loaded freelancer could not start a shard delivery')
assert(first.reward == config.PAY.courier.freelance and env.cityworkStore.rows[first.id].funded == 'mint')
local task = assert(city.Tasks[first.id]); assert(config.ROUTES[task.route] and task.route ~= 'forged')
assert(run(env, control, function() return inventory.GetItemCount(71, city.ITEM) end).value == 1)
stand(71, config.ROUTES[task.route])
run(env, control, function() city.Server.Complete(71) end)
assert(lastEvent(progressModule.Event.START, 71) == nil, 'minimum travel time was ignored')
advance(config.MIN_TRAVEL_S * 1000 + 1000)
run(env, control, function() city.Server.Complete(71) end)
local bar = assert(lastEvent(progressModule.Event.START, 71), 'handover progress did not start')
env.source = 71; control.netEvents[progressModule.Event.REPORT](bar.id, 'finished'); env.source = nil
control.Pump(10)
assert(one.money.EDDIES == 0 and active(one.citizenId), 'a forged early progress report paid the worker')
assert(run(env, control, function() return inventory.GetItemCount(71, city.ITEM) end).value == 1)
run(env, control, function() city.Server.Complete(71) end)
bar = assert(lastEvent(progressModule.Event.START, 71))
run(env, control, function() city.Server.Complete(71) end)
assert(lastEvent(progressModule.Event.START, 71).id == bar.id, 'duplicate completion created a second progress')
finishBar(71, bar)
assert(one.money.EDDIES == config.PAY.courier.freelance, 'courier reward was not paid through contracts')
assert(env.cityworkStore.rows[first.id].state == 'paid')
assert(run(env, control, function() return inventory.GetItemCount(71, city.ITEM) end).value == 0)
finishBar(71, bar)
assert(one.money.EDDIES == config.PAY.courier.freelance, 'replayed completion paid twice')
assert(city.Tasks[first.id] == nil, 'completed service kept its stale work index')
print('citywork real courier, authority, travel and replay checks passed')

-- Professional pay requires the primary trade, duty and a valid server grade.
stand(71, config.DISPATCH)
run(env, control, function() city.Server.StartWork(71, 'technician', true) end)
assert(not active(one.citizenId), 'an unemployed freelancer received professional work')
run(env, control, function() city.Server.Enrol(71, 'technician') end)
assert(one.job.name == 'technician' and one.job.grade.level == 0 and one.jobs.technician == 0,
	'self enrolment did not add and select the real grade-zero job')
one.jobs.technician = 2; one.job.grade.level = 2
run(env, control, function() city.Server.Enrol(71, 'technician') end)
assert(one.jobs.technician == 2 and one.job.grade.level == 2, 'enrolment downgraded an existing specialist')
one.job.onDuty = false
run(env, control, function() city.Server.StartWork(71, 'technician', true) end)
assert(not active(one.citizenId), 'an off-duty technician received professional work')
one.job.onDuty = true
run(env, control, function() city.Server.StartWork(71, 'technician', true) end)
local technician = assert(active(one.citizenId))
assert(technician.reward == config.PAY.technician.professional + 2 * config.PAY.technician.perGrade)
local techTask = assert(city.Tasks[technician.id])
-- Rebuild only the module's volatile index; the contracts row and inventory stay.
run(env, control, function() city.Stop(); city.Init() end)
assert(city.Tasks[technician.id] == nil)
run(env, control, function() OPX.Modules.Get('contracts').Server.Sweep() end)
assert(city.Tasks[technician.id] and city.Tasks[technician.id].route == techTask.route,
	'the durable objective tick did not rebuild the index after module restart')
advance(config.MIN_TRAVEL_S * 1000 + 1000)
stand(71, config.ROUTES[techTask.route], 99)
local beforeBar = lastEvent(progressModule.Event.START, 71)
run(env, control, function() city.Server.Complete(71) end)
assert(lastEvent(progressModule.Event.START, 71) == beforeBar, 'another routing bucket could complete maintenance')
stand(71, config.DISPATCH)
run(env, control, function() city.Server.Complete(71) end)
assert(lastEvent(progressModule.Event.START, 71) == beforeBar, 'dispatch counted as the remote relay destination')
stand(71, config.ROUTES[techTask.route])
run(env, control, function() city.Server.Complete(71) end)
local service = assert(lastEvent(progressModule.Event.START, 71))
assert(service.id ~= beforeBar.id and service.durationMs == config.SERVICE_MS)
-- Losing duty during the genuine progress must leave proof and money untouched.
one.job.onDuty = false
local beforeMoney = one.money.EDDIES
finishBar(71, service)
assert(one.money.EDDIES == beforeMoney and active(one.citizenId), 'off-duty completion paid a professional')
assert(run(env, control, function() return inventory.GetItemCount(71, city.ITEM) end).value == 1)
one.job.onDuty = true
run(env, control, function() city.Server.Complete(71) end)
service = assert(lastEvent(progressModule.Event.START, 71))
finishBar(71, service)
assert(one.money.EDDIES == beforeMoney + technician.reward and env.cityworkStore.rows[technician.id].state == 'paid')
print('citywork real enrolment, professional maintenance, buckets and restart passed')

-- A disconnected/replaced session cannot finish an earlier worker's progress.
local two = characterAt(72)
run(env, control, function() city.Server.StartWork(72, 'technician', false) end)
local freelanceTech = assert(active(two.citizenId))
assert(freelanceTech.reward == config.PAY.technician.freelance)
local secondTask = city.Tasks[freelanceTech.id]
advance(config.MIN_TRAVEL_S * 1000 + 1000)
stand(72, config.ROUTES[secondTask.route])
run(env, control, function() city.Server.Complete(72) end)
local secondBar = assert(lastEvent(progressModule.Event.START, 72))
local savedSession = OPX.Sessions[72]
OPX.Sessions[72] = (savedSession or 0) + 1
finishBar(72, secondBar)
assert(two.money.EDDIES == 0 and active(two.citizenId), 'an old progress paid a replacement session')
OPX.Sessions[72] = savedSession
run(env, control, function() city.Server.Complete(72) end)
secondBar = assert(lastEvent(progressModule.Event.START, 72))
-- The tagged package is the proof: its disappearance costs no payout.
run(env, control, function() return inventory.RemoveWhere(two.citizenId, city.ITEM, { contract = freelanceTech.id }) end)
finishBar(72, secondBar)
assert(two.money.EDDIES == 0 and active(two.citizenId), 'a missing module/package still produced a reward')
assert(env.cityworkStore.rows[freelanceTech.id].state == 'in_progress')
print('citywork session replacement and missing inventory proof passed')

-- An absent hard dependency disables this module through the actual registry.
local noProgress = boot('server', function(sandbox, file)
	if file == 'config/progress.lua' then sandbox.OPX.Config.MODULES.progress.enabled = false end
end)
assert(not noProgress.OPX.Modules.IsRunning('citywork'), 'citywork ran with its required progress module disabled')
print('citywork missing hard dependency passed')
