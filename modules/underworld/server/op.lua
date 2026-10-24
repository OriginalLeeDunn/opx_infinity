--- Illegal actions validate, claim and run a cancellable progress bar.
-- @author dop42
-- No item or wallet value moves before completion. The completed operation
-- stages every input/output in one AtomicTrade receipt. Unknown replies retain
-- logical claims and replay that receipt; cancellation needs no compensation.
-- Legacy escrow lacks this proof and is quarantined for manual review.
local M = OPX.Modules.Get('underworld')
local Model = M.Model
local Storage = M.Storage

M.Op = {}
local Op = M.Op

-- op id -> op, player -> op, lock key -> op id.
local ops, byPlayer, locks = {}, {}, {}
-- The last results, by op id: a settle that arrives twice reads the first.
local results, resultOrder = {}, {}
local RESULTS_KEPT = 64

local serial, nonce = 0, 0
local watchJob = nil
-- Ops are refused until legacy escrow has been quarantined successfully.
local recovered = false

-- ── reading a player ────────────────────────────────────────────────────────

local function character() return OPX.Api.Get('character') end
local function inventory() return OPX.Api.Get('inventory') end

--- The loaded character of a connection: { citizenId, data } or nil.
-- @author dop42
function Op.Character(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, loaded = pcall(api.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	local citizenId = Storage.CitizenOf(loaded.PlayerData.citizenId)
	if citizenId == nil then return nil end
	return { citizenId = citizenId, data = loaded.PlayerData }
end

--- The groups of a loaded character, as the job gate reads them.
-- @author dop42
function Op.Snapshot(loaded)
	if loaded == nil then return nil end
	local data = loaded.data
	return { job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		gang = type(data.gang) == 'table' and data.gang or nil,
		gangs = type(data.gangs) == 'table' and data.gangs or nil,
		atMs = OPX.Now() }
end

--- A connection's position and bucket, or nil.
-- @author dop42
function Op.Point(player)
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y), OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end

--- Whether a player sits in a vehicle, by the host's seat ledger.
local function seated(player)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.getVehicleSeat) ~= 'function' then return false end
	local read, assignment = pcall(players.getVehicleSeat, player)
	return read and type(assignment) == 'table' and assignment.vehicleId ~= nil
end

--- Metres between a point and an anchor.
-- @author dop42
function Op.Distance(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Why a player cannot act at an anchor right now, or nil and where they stand.
-- @author dop42
-- @param player integer
-- @param anchor table|nil { x, y, z, bucket }; nil skips the reach
-- @param reach number|nil metres
-- @return string|nil code
-- @return table|nil point
function Op.Standing(player, anchor, reach)
	if OPX.Life.Down(player) then return 'player_down' end
	if seated(player) then return 'leave_vehicle' end
	local at = Op.Point(player)
	if at == nil then return 'no_position' end
	if anchor ~= nil then
		if at.bucket ~= (anchor.bucket or 0) then return 'too_far' end
		if Op.Distance(at, anchor) > OPX.Spots.ServerReach(reach or 2.5) then return 'too_far' end
	end
	return nil, at
end

-- ── the atomic trade ──────────────────────────────────────────────────────────────

--- Whether the connection still carries the same character.
local function sameCharacter(op)
	if op.departed then return false end
	local loaded = Op.Character(op.player)
	return loaded ~= nil and loaded.citizenId == op.citizenId and loaded.data == op.loaded.data
end

--- How many dirty eddies a list of items carries.
--- Checks inputs without removing them; the completed trade owns all writes.
local function reserve(op)
	-- Inputs remain owned until the completed progress commits an atomic trade.
	-- These are courtesy checks; the transaction checks the staged bag again.
	local bag, purse = inventory(), character()
	for _, entry in ipairs((op.spec.inputs or {}).items or {}) do
		local count = bag and bag.GetItemCount(op.citizenId, entry.name)
		if type(count) ~= 'table' or not count.ok or count.value < entry.count then
			return entry.name == M.Built.dirty.item and 'not_enough_dirty' or 'not_enough_items'
		end
	end
	for _, entry in ipairs((op.spec.inputs or {}).money or {}) do
		local amount = purse and purse.GetMoney(op.citizenId, entry.type)
		if type(amount) ~= 'number' or amount < entry.amount then return 'not_enough_money' end
	end
end

--- All inputs and outputs of a completed operation share one durable receipt.
function Op.Atomic(op, outputs, moneyType, delta, participant)
	local api, purse = inventory(), character()
	if not api or type(api.AtomicTrade) ~= 'function' or not purse then return OPX.Result.Err('unavailable') end
	if not op.moneyId then
		local id = Storage.NewEconomicId()
		if not id.ok then return id end
		op.moneyId = 'underworld:' .. id.value
	end
	local changes = {}
	for _, entry in ipairs((op.spec.inputs or {}).items or {}) do
		changes[#changes + 1] = { name = entry.name, count = -entry.count }
	end
	delta = delta or 0
	moneyType = moneyType or M.Built.dirty.cleanType
	for _, entry in ipairs((op.spec.inputs or {}).money or {}) do
		if entry.type ~= moneyType then return OPX.Result.Err('unavailable') end
		delta = delta - entry.amount
	end
	for _, entry in ipairs(outputs or {}) do changes[#changes + 1] = entry end
	-- A receipt may finish while the owner is offline. Reconcile it without
	-- requiring the character or their bag to be loaded a second time.
	if purse.IsMoneyPending(op.citizenId, op.moneyId) then return OPX.Result.Err('money.pending') end
	if not purse.IsMoneyPending(op.citizenId, op.moneyId) then
		local prior = purse.MoneyReceipt(op.moneyId)
		if not prior.ok then return OPX.Result.Err('money.pending') end
		if prior.value then
			local row = prior.value
			local action = delta == 0 and 'touch' or delta > 0 and 'add' or 'remove'
			if row.citizen_id ~= op.citizenId or row.money_type ~= moneyType or row.action ~= action
				or tonumber(row.amount) ~= math.abs(delta) then return OPX.Result.Err('money.opIdConflict') end
			return OPX.Result.Ok({ replay = true })
		end
	end
	return api.AtomicTrade(op.citizenId, moneyType, delta, changes, 'underworld:' .. op.kind, op.moneyId,
		participant and function() return participant end or nil)
end

-- ── the life of an op ───────────────────────────────────────────────────────

local function remember(op, value)
	results[op.id] = value
	resultOrder[#resultOrder + 1] = op.id
	if #resultOrder > RESULTS_KEPT then results[table.remove(resultOrder, 1)] = nil end
end

local function release(op)
	ops[op.id] = nil
	if byPlayer[op.player] == op then byPlayer[op.player] = nil end
	if op.spec.lock ~= nil and locks[op.spec.lock] == op.id then locks[op.spec.lock] = nil end
end

local function tell(op, ok, code, result)
	if type(op.spec.after) ~= 'function' or not sameCharacter(op) then return end
	local called, failure = pcall(op.spec.after, op, ok, code, result)
	if not called then Open77.log.warn(('[underworld] the %s answer raised: %s'):format(op.kind, tostring(failure))) end
end

--- Cancels before dispatch: no economic value moved, only the claim is released.
-- @author dop42
-- @param op table
-- @param reason string
function Op.Cancel(op, reason)
	if op.state == 'done' or op.state == 'cancelled' or op.state == 'pending' or op.state == 'committing' then return false end
	op.state = 'cancelled'
	release(op)
	if type(op.spec.release) == 'function' then pcall(op.spec.release, op) end

	remember(op, { ok = false, code = reason })
	tell(op, false, reason)
	return true
end

--- Commits the completed operation; unknown results retain its logical claim.
local function commit(op)
	op.state = 'committing'
	local called, ok, code, result = pcall(op.spec.commit, op)
	if not called or ok ~= true then
		if not called then
			Open77.log.warn(('[underworld] the %s commit raised: %s'):format(op.kind, tostring(ok)))
		end
		if (called and code == 'money.pending') or (not called and op.moneyId) then
			op.state = 'pending'
			if not op.recovering then
				op.recovering = true
				CreateThread(function()
					while op.state == 'pending' do
						Wait(1000)
						commit(op)
					end
				end)
			end
			return
		end
		-- Definite refusal: no inputs were consumed, so only the logical claim is released.
		release(op)
		if type(op.spec.release) == 'function' then pcall(op.spec.release, op) end
		op.state = 'cancelled'
		code = called and code or 'unavailable'
		remember(op, { ok = false, code = code })
		tell(op, false, code)
		return
	end
	op.state = 'done'
	release(op)
	remember(op, { ok = true, code = code, result = result })
	OPX.Audit.Log({ event = 'underworld.' .. op.kind, citizenId = op.citizenId, source = op.player,
		message = ('%s committed %s'):format(op.id, tostring(code)),
		data = { op = op.id, lock = op.spec.lock, result = type(result) == 'table' and result or nil } })
	OPX.Publish(M.Event.ON_COMMITTED, op.player, { kind = op.kind, citizenId = op.citizenId,
		op = op.id, result = type(result) == 'table' and OPX.Table.DeepCopy(result) or nil })
	tell(op, true, code, result)
end

--- What the progress module said about an op's bar.
-- @author dop42
-- @param opId string
-- @param outcome table
function Op.Settle(opId, outcome)
	local op = ops[opId]
	if op == nil then return results[opId] end
	if op.state ~= 'bar' or type(outcome) ~= 'table' or outcome.id ~= op.barId then return nil end
	op.state = 'settling'
	if outcome.completed ~= true then
		Op.Cancel(op, op.stopped or (outcome.ending == 'left' and 'left') or 'cancelled')
		return results[opId]
	end
	-- REVALIDATED: the bar was the client's, the world is the server's.
	local why = 'left'
	if sameCharacter(op) then why = Op.Standing(op.player, op.spec.anchor, op.spec.reach) end
	if why == nil and type(op.spec.check) == 'function' then why = op.spec.check(op, true) end
	if why ~= nil then
		Op.Cancel(op, why)
		return results[opId]
	end
	commit(op)
	return results[opId]
end

local function makeId(player)
	serial = serial % 0xFFFFFF + 1
	return ('%08x%06x%04x'):format(nonce, serial, Model.Hash(('%d:%d:%d'):format(player, serial, OPX.Now())) & 0xFFFF)
end

--- Begins an op. See the header for the order; answers once the bar is up.
-- @author dop42
-- @param player integer
-- @param spec table kind, lock, anchor, reach, check(op, again), claim(op),
--   release(op), inputs = { items = {{name,count}}, money = {{type,amount}} },
--   label, durationMs, animation, onStart(op), commit(op) -> ok, code, result,
--   after(op, ok, code, result)
-- @return boolean ok
-- @return string code
-- @return table|nil op
function Op.Begin(player, spec)
	if not recovered then return false, 'unavailable' end
	if spec.inputs and spec.durable ~= true then return false, 'unavailable' end
	if byPlayer[player] ~= nil then return false, 'busy' end
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then return false, 'no_bar' end
	local loaded = Op.Character(player)
	if loaded == nil then return false, 'no_character' end
	if spec.loaded ~= nil and spec.loaded.data ~= loaded.data then return false, 'left' end
	local why, at = Op.Standing(player, spec.anchor, spec.reach)
	if why ~= nil then return false, why end

	local op = { id = makeId(player), player = player, citizenId = loaded.citizenId, kind = spec.kind,
		spec = spec, at = at, loaded = loaded, state = 'claiming', startedAt = OPX.Now() }
	if spec.lock ~= nil and locks[spec.lock] ~= nil then return false, 'spot_busy' end
	if type(spec.check) == 'function' then
		why = spec.check(op, false)
		if why ~= nil then return false, why end
	end

	-- THE CLAIM. Nothing above this line yielded, nothing on it does.
	ops[op.id], byPlayer[player] = op, op
	if spec.lock ~= nil then locks[spec.lock] = op.id end
	if type(spec.claim) == 'function' then spec.claim(op) end

	op.state = 'reserving'
	why = reserve(op)
	if why ~= nil then
		op.escrow = nil
		Op.Cancel(op, why)
		return false, why
	end
	-- Left while the bag was being read: the cancel hands it all back.
	if op.state ~= 'reserving' or not sameCharacter(op) then
		if op.state == 'reserving' then Op.Cancel(op, 'left') end
		return false, 'left'
	end

	local started = progress.Start(player, M.OWNER, {
		label = spec.label, durationMs = spec.durationMs, cancelable = true,
		animation = type(spec.animation) == 'string' and spec.animation ~= '' and { name = spec.animation } or nil,
	}, function(_, outcome)
		CreateThread(function() Op.Settle(op.id, outcome) end)
	end)
	if type(started) ~= 'table' or not started.ok then
		Op.Cancel(op, type(started) == 'table' and started.error == 'progress_busy' and 'busy' or 'no_bar')
		return false, 'no_bar'
	end
	op.barId, op.state = started.value.id, 'bar'
	if type(spec.onStart) == 'function' then pcall(spec.onStart, op) end
	return true, 'started', op
end

--- One watch step: a running bar stops when its player can no longer act.
local function watch()
	local list = {}
	for _, op in pairs(ops) do
		if op.state == 'bar' then list[#list + 1] = op end
	end
	for _, op in ipairs(list) do
		local why = Op.Standing(op.player, op.spec.anchor, op.spec.reach)
		if why ~= nil and ops[op.id] == op and op.state == 'bar' then
			op.stopped = why
			local progress = OPX.Api.Get('progress')
			local stopped = progress ~= nil and progress.Stop(op.player, M.OWNER, op.barId) or nil
			-- A bar the progress module no longer had settles nothing: this does.
			if (type(stopped) ~= 'table' or not stopped.ok) and op.state == 'bar' then
				CreateThread(function() Op.Settle(op.id, { id = op.barId, completed = false, ending = 'stopped' }) end)
			end
		end
	end
end

--- The op a player is in, or nil.
-- @author dop42
function Op.Of(player) return byPlayer[player] end

--- Whether a lock is held.
-- @author dop42
function Op.Locked(key) return locks[key] ~= nil end

--- Quarantines old escrow without proven atomic debits. Yields once at start.
-- @author dop42
function Op.Recover()
	local rows = Storage.EscrowLeft()
	if rows == nil then return false end
	for _, row in ipairs(rows) do
		-- Old escrow had no atomic proof tying it to a saved item/wallet debit.
		-- Refunding it automatically could duplicate already-restored inventory.
		local marked = Storage.QuarantineEscrow(row.opId)
		if not marked.ok then return false end
		OPX.Audit.Log({ event = 'underworld.escrowQuarantined', severity = 'error',
			citizenId = row.citizenId, message = 'Legacy escrow requires manual review', data = { op = row.opId } })
	end
	recovered = true
	return true
end

--- Resets the state. Never yields.
-- @author dop42
function Op.Init()
	ops, byPlayer, locks, results, resultOrder = {}, {}, {}, {}, {}
	serial, recovered = 0, false
	nonce = Model.Hash(tostring({}) .. ':' .. tostring(OPX.Now()))
end

--- Starts the watch, and hears departures.
-- @author dop42
function Op.Start()
	watchJob = OPX.Scheduler.Every('underworld:ops', 500, watch)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(raw)
		local player = math.tointeger(tonumber(raw))
		local op = player ~= nil and byPlayer[player] or nil
		-- A bar settles `left` through the progress module; an op still
		-- reserving is cancelled where it resumes.
		if op ~= nil and op.state == 'reserving' then op.departed = true end
	end)
end

--- Stops logical operations; committed core transactions reconcile themselves.
function Op.Stop()
	if watchJob ~= nil then pcall(OPX.Scheduler.Cancel, watchJob) end
	watchJob = nil
	for _, op in pairs(ops) do
		op.state = 'cancelled'
	end
	ops, byPlayer, locks = {}, {}, {}
end
