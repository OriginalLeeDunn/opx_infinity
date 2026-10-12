--- The `accounts` v1 contract: one treasury per job and per gang.
-- @author dop42
--
-- `Balance`, `Deposit`, `Withdraw`, `Transfer`, `History`, every one answering
-- an `OPX.Result`, every one yielding (they read the database): call them from
-- a `CreateThread`, as every network handler does.
--
-- IDEMPOTENT BY OPERATION ID. A caller that may retry -- an invoice paid, a
-- payroll run resumed after a restart -- passes an `opId` it can mint again.
-- The receipt is looked up FIRST (a replay costs one read and writes nothing),
-- then the movement is written as one transaction whose ledger row carries the
-- id under a UNIQUE key, then the receipt is read back. A write that failed but
-- left a receipt behind (the answer was lost after the commit, or another
-- thread with the same id won) is the same movement, answered with its first
-- receipt. An id reused for a DIFFERENT movement is refused rather than
-- answered with somebody else's receipt. Without an opId one is minted.
--
-- ONE MOVEMENT PER ACCOUNT AT A TIME inside this VM (`serial`), on top of the
-- SQL guard. The guard alone is correct -- a debit the balance cannot cover
-- writes nothing -- but two debits racing on one row can deadlock in InnoDB and
-- one of them would come back as a failure the player did nothing to earn.
--
-- THE BUS. Every movement that actually happened (never a replay) raises
-- `opx:on:accounts:changed` `(nil, { kind, key, delta, balance, reason })` and
-- writes a `money.company.*` audit line, which the audit log never collapses.

local M = OPX.Modules.Get('business')
local Access = M.Access
local Result = OPX.Result
local Store = M.Storage

M.Accounts = {}

-- Account name -> true while a movement on it is in flight.
local busy = {}
-- Minted operation ids since boot, the sequence part of the id.
local sequence = 0

-- Frames a movement waits for its account before it gives up.
local SERIAL_FRAMES = 300

local function safe(value) return OPX.Audit.Safe(tostring(value), 96) end

--- Wall-clock seconds from the host, else process seconds (the test harness).
local function wall()
	local time = Open77 and Open77.time
	if type(time) == 'table' and type(time.unix) == 'function' then
		local ok, now = pcall(time.unix)
		if ok and type(now) == 'number' and now == now then return math.floor(now) end
	end
	return OPX.Now() // 1000
end

--- A fresh operation id, unique across restarts: the wall clock, the process
--- clock, a sequence and a random part. An id that repeated after a restart
--- would be answered as a replay of somebody else's movement.
-- @author dop42
-- @param prefix string
-- @return string
function M.Accounts.Mint(prefix)
	sequence = sequence + 1
	return ('%s:%d:%d:%d:%d'):format(tostring(prefix or 'op'):sub(1, 24), wall(), OPX.Now() % 100000,
		sequence, math.random(0, 999999))
end

local function nameOf(kind, key) return kind .. ':' .. key end

local function actorText(actor)
	if actor == nil then return nil end
	local text = OPX.Text.Clean(tostring(actor), 48)
	return text ~= '' and text or nil
end

--- Runs `body` holding every named account, in name order so two transfers in
--- opposite directions cannot each hold one and wait for the other.
local function serial(names, body)
	table.sort(names)
	local held = {}
	local function release()
		for index = 1, #held do busy[held[index]] = nil end
	end
	for _, name in ipairs(names) do
		local waited = 0
		while busy[name] do
			if waited >= SERIAL_FRAMES then
				release()
				return Result.Err('accounts.busy', name)
			end
			waited = waited + 1
			Wait(0)
		end
		busy[name] = true
		held[#held + 1] = name
	end
	local ok, answer = pcall(body)
	release()
	if not ok then
		Open77.log.error('[business] a treasury movement raised: ' .. safe(answer))
		return Result.Err('accounts.failed', tostring(answer))
	end
	return answer
end

local function integerOf(value) return math.tointeger(tonumber(value)) end

local function announce(kind, key, delta, balance, reason, opId, actor)
	OPX.Publish(M.Event.ON_ACCOUNT, nil, { kind = kind, key = key, delta = delta,
		balance = balance, reason = reason })
	OPX.Audit.Log({
		event = delta >= 0 and 'money.company.credit' or 'money.company.debit',
		message = ('%s:%s %+d -> %d (%s)'):format(kind, key, delta, balance or -1, reason),
		data = { opId = opId, by = actor },
		owner = 'business',
	})
end

--- Checks the arguments every movement shares, answering the op or a refusal.
local function prepare(kind, key, amount, reason, opId, actor, prefix)
	if not Access.ValidGroup(kind, key) then return nil, Result.Err('accounts.badGroup') end
	local whole = math.tointeger(amount)
	if whole == nil or whole < 1 or whole > Access.MAX_AMOUNT then
		return nil, Result.Err('accounts.badAmount')
	end
	local id
	if opId ~= nil then
		id = Access.OpId(opId)
		if id == nil then return nil, Result.Err('accounts.badOpId') end
	else
		id = M.Accounts.Mint(prefix)
	end
	return { id = id, kind = kind, group = key, amount = whole, reason = Access.Reason(reason),
		actor = actorText(actor) }
end

--- Answers a receipt as the movement it records, or refuses an id reused for a
--- different movement.
local function fromReceipt(row, op, sign)
	local delta = integerOf(row.delta) or 0
	if row.kind ~= op.kind or row.group_key ~= op.group or delta ~= sign * op.amount then
		return Result.Err('accounts.opIdConflict', op.id)
	end
	return Result.Ok({ balance = integerOf(row.balance_after) or 0, opId = op.id, replay = true })
end

--- One credit or debit, the whole receipt dance. See the header.
local function move(op, sign)
	return serial({ nameOf(op.kind, op.group) }, function()
		local prior = Store.Receipt(op.id)
		if not prior.ok then return Result.Err('accounts.failed', prior.detail) end
		if prior.value ~= nil then return fromReceipt(prior.value, op, sign) end

		local wrote = sign > 0 and Store.Credit(op) or Store.Debit(op)
		local after = Store.Receipt(op.id)
		if not after.ok then
			-- THE ONE CASE NOBODY CAN ANSWER: the write's outcome is unknown and
			-- so is the receipt. Said loudly, with the id that settles it.
			Open77.log.error(('[business] treasury movement %s on %s:%s has an UNKNOWN outcome ' ..
				'(%s); read opx77_company_ledger for op_id %s'):format(sign > 0 and 'credit' or 'debit',
				op.kind, op.group, safe(after.detail), op.id))
			return Result.Err('accounts.unknown', op.id)
		end
		local row = after.value
		if row == nil then
			if not wrote.ok then return Result.Err('accounts.failed', wrote.detail) end
			if sign < 0 then return Result.Err('insufficient_funds') end
			return Result.Err('accounts.failed', 'no receipt')
		end
		if not wrote.ok then return fromReceipt(row, op, sign) end

		local balance = integerOf(row.balance_after) or 0
		announce(op.kind, op.group, sign * op.amount, balance, op.reason, op.id, op.actor)
		return Result.Ok({ balance = balance, opId = op.id })
	end)
end

--- One account's balance.
-- @author dop42
-- @param kind string 'job' | 'gang'
-- @param key string
-- @return Result { balance }
function M.Accounts.Balance(kind, key)
	if not Access.ValidGroup(kind, key) then return Result.Err('accounts.badGroup') end
	local read = Store.Balance(kind, key)
	if not read.ok then return Result.Err('accounts.failed', read.detail) end
	local row = type(read.value) == 'table' and read.value or nil
	return Result.Ok({ balance = integerOf(row and row.balance) or 0 })
end

--- Pays into an account.
-- @author dop42
-- @param kind string
-- @param key string
-- @param amount integer > 0
-- @param reason string
-- @param opId string|nil idempotency key
-- @param actor string|nil who, for the ledger (a citizen id, a module)
-- @return Result { balance, opId, replay? }
function M.Accounts.Deposit(kind, key, amount, reason, opId, actor)
	local op, refused = prepare(kind, key, amount, reason, opId, actor, 'dep')
	if op == nil then return refused end
	return move(op, 1)
end

--- Takes out of an account, refusing `insufficient_funds` rather than
--- overdrawing it.
-- @author dop42
-- @param kind string
-- @param key string
-- @param amount integer > 0
-- @param reason string
-- @param opId string|nil
-- @param actor string|nil
-- @return Result { balance, opId, replay? }
function M.Accounts.Withdraw(kind, key, amount, reason, opId, actor)
	local op, refused = prepare(kind, key, amount, reason, opId, actor, 'wdr')
	if op == nil then return refused end
	return move(op, -1)
end

--- Moves money from one account to another, both or neither.
-- @author dop42
-- @param fromKind string
-- @param fromKey string
-- @param toKind string
-- @param toKey string
-- @param amount integer > 0
-- @param reason string
-- @param opId string|nil
-- @param actor string|nil
-- @return Result { balance (the payer's), to (the payee's), opId, replay? }
function M.Accounts.Transfer(fromKind, fromKey, toKind, toKey, amount, reason, opId, actor)
	if not Access.ValidGroup(toKind, toKey) then return Result.Err('accounts.badGroup') end
	local op, refused = prepare(fromKind, fromKey, amount, reason, opId, actor, 'xfr')
	if op == nil then return refused end
	if fromKind == toKind and fromKey == toKey then return Result.Err('accounts.sameAccount') end
	local out, into = op.id .. ':out', op.id .. ':in'
	local plan = { out = out, into = into, from = { kind = fromKind, group = fromKey },
		to = { kind = toKind, group = toKey }, amount = op.amount, reason = op.reason, actor = op.actor }

	return serial({ nameOf(fromKind, fromKey), nameOf(toKind, toKey) }, function()
		local function receipts()
			local a, b = Store.Receipt(out), Store.Receipt(into)
			if not a.ok or not b.ok then return nil end
			return { out = a.value, into = b.value }
		end
		local function answer(found, replay)
			local debit = integerOf(found.out.delta) or 0
			if found.out.kind ~= fromKind or found.out.group_key ~= fromKey or debit ~= -op.amount then
				return Result.Err('accounts.opIdConflict', op.id)
			end
			return Result.Ok({ balance = integerOf(found.out.balance_after) or 0,
				to = found.into and integerOf(found.into.balance_after) or nil, opId = op.id,
				replay = replay or nil })
		end

		local prior = receipts()
		if prior == nil then return Result.Err('accounts.failed', 'receipt read') end
		if prior.out ~= nil then return answer(prior, true) end

		local wrote = Store.Move(plan)
		local after = receipts()
		if after == nil then
			Open77.log.error(('[business] treasury transfer %s has an UNKNOWN outcome; read ' ..
				'opx77_company_ledger for op_id %s'):format(op.id, out))
			return Result.Err('accounts.unknown', op.id)
		end
		if after.out == nil then
			if not wrote.ok then return Result.Err('accounts.failed', wrote.detail) end
			return Result.Err('insufficient_funds')
		end
		if not wrote.ok then return answer(after, true) end

		local paid = answer(after, false)
		if paid.ok then
			announce(fromKind, fromKey, -op.amount, paid.value.balance, op.reason, out, op.actor)
			announce(toKind, toKey, op.amount, paid.value.to or 0, op.reason, into, op.actor)
		end
		return paid
	end)
end

--- The newest movements of an account, newest first.
-- @author dop42
-- @param kind string
-- @param key string
-- @param limit integer|nil clamped to 1..ACCOUNTS.HISTORY_MAX
-- @return Result { rows = { { amount, reason, at, by? } } }
function M.Accounts.History(kind, key, limit)
	if not Access.ValidGroup(kind, key) then return Result.Err('accounts.badGroup') end
	local wanted = math.tointeger(tonumber(limit)) or math.max(1, Access.HISTORY_SHOWN)
	wanted = math.max(1, math.min(Access.HISTORY_MAX, wanted))
	local read = Store.History(kind, key, wanted)
	if not read.ok then return Result.Err('accounts.failed', read.detail) end
	local rows = {}
	for index, row in ipairs(type(read.value) == 'table' and read.value or {}) do
		rows[index] = { amount = integerOf(row.delta) or 0, reason = tostring(row.reason or ''),
			at = integerOf(row.at) or 0, by = row.actor ~= nil and tostring(row.actor) or nil }
	end
	return Result.Ok({ rows = rows })
end

--- Records a credit another writer has ALREADY applied to the balance -- the
--- dealership's settled sales -- so the history and the bus see it. Never moves
--- money; idempotent on the operation id; best effort (a lost note is a missing
--- history line, never a wrong balance).
-- @author dop42
-- @param kind string
-- @param key string
-- @param amount integer
-- @param reason string
-- @param opId string
-- @param actor string|nil
-- @return Result
function M.Accounts.Note(kind, key, amount, reason, opId, actor)
	local op, refused = prepare(kind, key, amount, reason, opId, actor, 'note')
	if op == nil then return refused end
	local balance = M.Accounts.Balance(kind, key)
	op.balance = balance.ok and balance.value.balance or nil
	local wrote = Store.Note(op)
	if not wrote.ok then return Result.Err('accounts.failed', wrote.detail) end
	if (math.tointeger(wrote.value) or 0) > 0 then
		announce(op.kind, op.group, op.amount, op.balance, op.reason, op.id, op.actor)
	end
	return Result.Ok({ balance = op.balance, opId = op.id })
end

--- Forgets the in-flight marks (a module restart inside the VM).
-- @author dop42
function M.Accounts.Reset()
	busy = {}
end
