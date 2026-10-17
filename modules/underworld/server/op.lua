--- One helper for every valued illegal action: reserve, a server bar, commit or
--- cancel -- each exactly once.
-- @author dop42
--
-- THE SHAPE, and the order is the design (the platform's world-interaction
-- pattern, and `modules/hauling/server/claim.lua`'s rule about yields):
--
--   1. VALIDATE, with nothing yielding: a loaded character, alive, on foot, not
--      already in an op, standing within reach of the anchor in its bucket, and
--      the caller's own business rules (`spec.check`) -- a host read is a plain
--      call, never a database round trip.
--   2. CLAIM, table arithmetic only: the player's op slot, the spot's lock
--      (`spec.lock`, one robbery per till), and the caller's own shared state
--      (`spec.claim`: a stock unit, a till charge). Two requests in one tick
--      cannot both pass this, because nothing between the read in 1 and the
--      write here can yield.
--   3. RESERVE, which yields: the inputs leave the bag and the purse NOW, before
--      the bar, into an escrow row. A bag that no longer holds them refuses the
--      op here and nothing has happened. The escrow row is what a crash leaves
--      behind, and `Op.Recover` refunds it at the next start.
--   4. A BAR THE SERVER TIMES (`modules/progress`): the client's "finished" is
--      believed only after the server's own clock, and the cancel key is X.
--      While it runs, a watch step stops it when the player moves off, goes
--      down, gets in a vehicle or changes bucket; a disconnect ends it `left`.
--   5. REVALIDATE, then COMMIT ONCE: the inputs are destroyed for good (the
--      escrow is closed) and only then is the value created (`spec.commit`).
--      A commit that cannot create its value hands the inputs back. The result
--      is kept by op id, so a second settle of the same op changes nothing.
--   6. OR CANCEL ONCE: the escrow goes back where it came from -- the bag, or
--      the character's row if they left -- and the claim is released.
--
-- A LEDGER LINE PER MOVEMENT OF DIRTY MONEY: into escrow (-), back out of it
-- (+), and whatever the commit mints. Summed per citizen, the ledger is what
-- they hold, which is the property `/opx.underworld.ledger` reads.
--
-- RANDOMNESS is the op's: `Model.Roll(op.id, salt, ...)`. The id is drawn from
-- a per-boot nonce and a counter, so a client never sees it before the commit.

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
-- Ops are refused until the previous run's escrow has been refunded.
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

-- ── the escrow ──────────────────────────────────────────────────────────────

--- Whether the connection still carries the same character.
local function sameCharacter(op)
	if op.departed then return false end
	local loaded = Op.Character(op.player)
	return loaded ~= nil and loaded.citizenId == op.citizenId and loaded.data == op.loaded.data
end

--- How many dirty eddies a list of items carries.
local function dirtyIn(items)
	local item, total = M.Built.dirty.item, 0
	for _, entry in ipairs(items or {}) do
		if entry.name == item then total = total + entry.count end
	end
	return total
end

--- Puts items and money back on a character, online or not. Answers what could
--- not be put back, for the journal.
-- @author dop42
-- @param player integer|nil the connection, when it still carries them
-- @param citizenId string
-- @param payload table { items, money }
-- @return string[] what was lost
function Op.Refund(player, citizenId, payload)
	local lost = {}
	local bag, purse = inventory(), character()
	-- A previous inventory write may yield across a character switch.
	local target = citizenId
	for _, entry in ipairs(type(payload) == 'table' and payload.items or {}) do
		local added = bag ~= nil and bag.AddItem(target, entry.name, entry.count) or nil
		if type(added) ~= 'table' or not added.ok then
			lost[#lost + 1] = ('%dx %s'):format(entry.count, entry.name)
		end
	end
	for _, entry in ipairs(type(payload) == 'table' and payload.money or {}) do
		local ok = false
		if purse ~= nil then
			if player ~= nil then
				local called, added = pcall(purse.AddMoney, citizenId, entry.type, entry.amount, 'underworld:refund')
				ok = called and added == true
			end
			if not ok and type(purse.AddMoneyOffline) == 'function' then
				local added = purse.AddMoneyOffline(citizenId, entry.type, entry.amount, 'underworld:refund')
				ok = type(added) == 'table' and added.ok == true
			end
		end
		if not ok then lost[#lost + 1] = ('%d %s'):format(entry.amount, entry.type) end
	end
	return lost
end

--- Takes an op's inputs out of the bag and the purse. Yields. Answers nil, or
--- the code and nothing taken.
local function reserve(op)
	local inputs = op.spec.inputs or {}
	local taken = { items = {}, money = {} }
	local bag, purse = inventory(), character()
	for _, entry in ipairs(inputs.items or {}) do
		local removed = bag ~= nil and bag.RemoveItem(op.citizenId, entry.name, entry.count) or nil
		if type(removed) ~= 'table' or not removed.ok then
			Op.Refund(op.player, op.citizenId, taken)
			return entry.name == M.Built.dirty.item and 'not_enough_dirty' or 'not_enough_items'
		end
		taken.items[#taken.items + 1] = { name = entry.name, count = entry.count }
	end
	for _, entry in ipairs(inputs.money or {}) do
		local called, removed = false, false
		if purse ~= nil then called, removed = pcall(purse.RemoveMoney, op.citizenId, entry.type, entry.amount,
			'underworld:' .. op.kind) end
		if not called or removed ~= true then
			Op.Refund(op.player, op.citizenId, taken)
			return 'not_enough_money'
		end
		taken.money[#taken.money + 1] = { type = entry.type, amount = entry.amount }
	end
	op.escrow = taken
	if #taken.items > 0 or #taken.money > 0 then
		Storage.EscrowOpen(op.id, op.citizenId, taken)
		local dirty = dirtyIn(taken.items)
		if dirty > 0 then Storage.Ledger(op.citizenId, 'escrow:' .. op.kind, -dirty, op.at) end
	end
	return nil
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

--- Ends an op without its value, once: the escrow goes back, the claim is let go.
-- @author dop42
-- @param op table
-- @param reason string
function Op.Cancel(op, reason)
	if op.state == 'done' or op.state == 'cancelled' then return false end
	op.state = 'cancelled'
	release(op)
	if type(op.spec.release) == 'function' then pcall(op.spec.release, op) end
	if op.escrow ~= nil then
		local online = sameCharacter(op) and op.player or nil
		local lost = Op.Refund(online, op.citizenId, op.escrow)
		Storage.EscrowClose(op.id)
		local dirty = dirtyIn(op.escrow.items)
		if dirty > 0 then Storage.Ledger(op.citizenId, 'refund:' .. op.kind, dirty, op.at) end
		if #lost > 0 then
			OPX.Audit.Log({ event = 'underworld.refundLost', severity = 'warn', citizenId = op.citizenId,
				message = ('%s: %s'):format(op.id, table.concat(lost, ', ')), data = { op = op.id, kind = op.kind } })
		end
	end
	remember(op, { ok = false, code = reason })
	tell(op, false, reason)
	return true
end

--- Commits an op, once: escrow destroyed first, value created last.
local function commit(op)
	op.state = 'committing'
	if op.escrow ~= nil then Storage.EscrowClose(op.id) end
	local called, ok, code, result = pcall(op.spec.commit, op)
	if not called or ok ~= true then
		if not called then
			Open77.log.warn(('[underworld] the %s commit raised: %s'):format(op.kind, tostring(ok)))
		end
		-- Nothing was created: what was destroyed goes back.
		op.state = 'refunding'
		local escrow = op.escrow
		op.escrow = nil
		release(op)
		if type(op.spec.release) == 'function' then pcall(op.spec.release, op) end
		if escrow ~= nil then
			local lost = Op.Refund(sameCharacter(op) and op.player or nil, op.citizenId, escrow)
			local dirty = dirtyIn(escrow.items)
			if dirty > 0 then Storage.Ledger(op.citizenId, 'refund:' .. op.kind, dirty, op.at) end
			if #lost > 0 then
				OPX.Audit.Log({ event = 'underworld.refundLost', severity = 'warn', citizenId = op.citizenId,
					message = ('%s: %s'):format(op.id, table.concat(lost, ', ')), data = { op = op.id } })
			end
		end
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

--- Refunds every escrow row a previous run left open. Yields; run once at start.
-- @author dop42
function Op.Recover()
	local rows = Storage.EscrowLeft()
	for _, row in ipairs(rows) do
		local payload = type(row.payload) == 'table' and row.payload or {}
		local api = character()
		local online = nil
		if api ~= nil and type(api.GetPlayerByCitizenId) == 'function' then
			local read, loaded = pcall(api.GetPlayerByCitizenId, row.citizenId)
			if read and type(loaded) == 'table' and type(loaded.PlayerData) == 'table' then
				online = loaded.PlayerData.source
			end
		end
		local lost = Op.Refund(online, row.citizenId, payload)
		Storage.EscrowClose(row.opId)
		local dirty = dirtyIn(type(payload.items) == 'table' and payload.items or {})
		if dirty > 0 then Storage.Ledger(row.citizenId, 'recover', dirty) end
		OPX.Audit.Log({ event = 'underworld.recover', severity = #lost > 0 and 'warn' or 'info',
			citizenId = row.citizenId, message = ('escrow %s refunded%s'):format(row.opId,
				#lost > 0 and (' except ' .. table.concat(lost, ', ')) or ''), data = { op = row.opId } })
	end
	if #rows > 0 then
		Open77.log.info(('[underworld] refunded %d escrow(s) a previous run left open'):format(#rows))
	end
	recovered = true
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

--- Lets every open op go WITHOUT refunding it here: a refund is a bag write a
--- stopping resource cannot promise to finish, and the escrow row it would
--- refund is already in the database, where `Op.Recover` finds it at the next
--- start. Refunding twice is the one thing worse than refunding late.
-- @author dop42
function Op.Stop()
	if watchJob ~= nil then pcall(OPX.Scheduler.Cancel, watchJob) end
	watchJob = nil
	local open = 0
	for _, op in pairs(ops) do
		if op.escrow ~= nil then open = open + 1 end
		op.state = 'cancelled'
	end
	ops, byPlayer, locks = {}, {}, {}
	if open > 0 then
		Open77.log.info(('[underworld] stopping with %d op(s) in escrow: refunded at the next start')
			:format(open))
	end
end
