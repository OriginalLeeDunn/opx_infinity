--- Every SQL statement the treasury runs, and the two tables it owns.
-- @author dop42
--
-- The only file in the module that carries SQL. Nothing here decides anything:
-- `server/accounts.lua` validates and decides, this file writes.
--
-- `opx77_company_accounts` IS TAKEN OVER FROM THE DEALERSHIP, NOT COPIED. The
-- CREATE below is the dealership's own statement, byte for byte in its columns
-- and keys, so on a server that already has the table it is a no-op and every
-- balance in it is the treasury's balance from the first boot. The dealership
-- keeps its own copy of the statement (it still pays sales into the table
-- through its pending ledger, and must still boot with this module disabled):
-- two `IF NOT EXISTS` for one table is one table.
--
-- `opx77_company_ledger` is new: one row per movement, named by its operation
-- id. `op_id` is UNIQUE, and each movement is ONE transaction that writes the
-- ledger row and the balance together -- so a movement retried under the same
-- id fails on the key, rolls back whole, and the caller reads the first row
-- back as its receipt. `balance_after` is filled in the same transaction, which
-- is what a replay answers.
--
-- THE WITHDRAWAL GUARD IS IN SQL. The ledger row of a debit is an INSERT ...
-- SELECT from the account row WHERE balance >= amount, and the balance is then
-- moved by joining that ledger row: a debit the balance cannot cover writes no
-- row and moves nothing, inside the same transaction, whatever else is running.
-- No read in Lua decides whether there is enough.
--
-- Transactions bind positional `?` (the bridge's transaction form), single
-- statements named `@key`; no comment may appear inside a SQL string.

local M = OPX.Modules.Get('business')

local Storage = OPX.Storage
local Result = OPX.Result

M.Storage = {}
M.Storage.COLUMNS = {
	{ TABLE = 'opx77_company_ledger', COLUMN = 'attempt_token',
		DEFINITION = 'VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL' },
}

M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_company_accounts (
    kind VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    group_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    balance BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (kind, group_key)
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_company_ledger (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    op_id VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    kind VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    group_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    delta BIGINT NOT NULL,
    balance_after BIGINT NULL DEFAULT NULL,
    reason VARCHAR(96) NOT NULL DEFAULT '',
    actor VARCHAR(48) NULL DEFAULT NULL,
    attempt_token VARCHAR(96) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_opx77_company_ledger_op (op_id),
    KEY ix_opx77_company_ledger_group (kind, group_key, id)
) ENGINE=InnoDB
]],
}

--- One account's balance; nil when it has never been paid into.
-- @author dop42
-- @param kind string
-- @param group string
-- @return Result carrying { balance } or nil
function M.Storage.Balance(kind, group)
	return Storage.Single([[
SELECT balance
  FROM opx77_company_accounts
 WHERE kind = @kind AND group_key = @group
  ]], { kind = kind, group = group })
end

--- The ledger row an operation id wrote, or nil: the receipt a replay answers.
-- @author dop42
-- @param opId string
-- @return Result carrying { delta, balance_after, kind, group_key } or nil
function M.Storage.Receipt(opId)
	return Storage.Single([[
SELECT kind, group_key, delta, balance_after, attempt_token
  FROM opx77_company_ledger
 WHERE op_id = @op
  ]], { op = opId })
end

-- Each statement is gated by the attempt nonce. A guarded INSERT matching zero
-- rows cannot cause an earlier receipt with the same op_id to move money again.
local STAMP = 'UPDATE opx77_company_ledger l JOIN opx77_company_accounts a ' ..
	'ON a.kind = l.kind AND a.group_key = l.group_key ' ..
	'SET l.balance_after = a.balance WHERE l.op_id = ? AND l.attempt_token = ?'

function M.Storage.CreditStatements(op)
	return {
		{ query = 'INSERT INTO opx77_company_ledger (op_id, kind, group_key, delta, reason, actor, attempt_token) ' ..
			"SELECT ?, ?, ?, ?, ?, NULLIF(?, ''), ? WHERE COALESCE((SELECT balance " ..
			'FROM opx77_company_accounts WHERE kind = ? AND group_key = ? FOR UPDATE), 0) <= ?',
			values = { op.id, op.kind, op.group, op.amount, op.reason, op.actor or '', op.attempt,
				op.kind, op.group, 9007199254740991 - op.amount } },
		{ query = 'INSERT INTO opx77_company_accounts (kind, group_key, balance) ' ..
			'SELECT kind, group_key, delta FROM opx77_company_ledger WHERE op_id = ? AND attempt_token = ? ' ..
			'ON DUPLICATE KEY UPDATE balance = balance + VALUES(balance)', values = { op.id, op.attempt } },
		{ query = STAMP, values = { op.id, op.attempt } },
	}
end

function M.Storage.Credit(op) return Storage.Transaction(M.Storage.CreditStatements(op)) end

function M.Storage.DebitStatements(op)
	return {
		{ query = 'INSERT INTO opx77_company_ledger (op_id, kind, group_key, delta, reason, actor, attempt_token) ' ..
			"SELECT ?, kind, group_key, ?, ?, NULLIF(?, ''), ? FROM opx77_company_accounts " ..
			'WHERE kind = ? AND group_key = ? AND balance >= ? FOR UPDATE',
			values = { op.id, -op.amount, op.reason, op.actor or '', op.attempt, op.kind, op.group, op.amount } },
		{ query = 'UPDATE opx77_company_accounts a JOIN opx77_company_ledger l ' ..
			'ON l.kind = a.kind AND l.group_key = a.group_key ' ..
			'SET a.balance = a.balance + l.delta WHERE l.op_id = ? AND l.attempt_token = ?',
			values = { op.id, op.attempt } },
		{ query = STAMP, values = { op.id, op.attempt } },
	}
end

function M.Storage.Debit(op) return Storage.Transaction(M.Storage.DebitStatements(op)) end

function M.Storage.MoveStatements(op)
	return {
		{ query = 'INSERT INTO opx77_company_ledger (op_id, kind, group_key, delta, reason, actor, attempt_token) ' ..
			"SELECT ?, kind, group_key, ?, ?, NULLIF(?, ''), ? FROM opx77_company_accounts " ..
			'WHERE kind = ? AND group_key = ? AND balance >= ? AND COALESCE((SELECT balance ' ..
			'FROM opx77_company_accounts target WHERE target.kind = ? AND target.group_key = ? FOR UPDATE), 0) <= ? FOR UPDATE',
			values = { op.out, -op.amount, op.reason, op.actor or '', op.attempt,
				op.from.kind, op.from.group, op.amount, op.to.kind, op.to.group, 9007199254740991 - op.amount } },
		{ query = 'INSERT INTO opx77_company_ledger (op_id, kind, group_key, delta, reason, actor, attempt_token) ' ..
			'SELECT ?, ?, ?, -delta, reason, actor, ? FROM opx77_company_ledger WHERE op_id = ? AND attempt_token = ?',
			values = { op.into, op.to.kind, op.to.group, op.attempt, op.out, op.attempt } },
		{ query = 'INSERT INTO opx77_company_accounts (kind, group_key, balance) ' ..
			'SELECT kind, group_key, 0 FROM opx77_company_ledger WHERE op_id = ? AND attempt_token = ? ' ..
			'ON DUPLICATE KEY UPDATE balance = balance', values = { op.into, op.attempt } },
		{ query = 'UPDATE opx77_company_accounts a JOIN opx77_company_ledger l ' ..
			'ON l.kind = a.kind AND l.group_key = a.group_key ' ..
			'SET a.balance = a.balance + l.delta WHERE (l.op_id = ? OR l.op_id = ?) AND l.attempt_token = ?',
			values = { op.out, op.into, op.attempt } },
		{ query = STAMP, values = { op.out, op.attempt } },
		{ query = STAMP, values = { op.into, op.attempt } },
	}
end

function M.Storage.Move(op) return Storage.Transaction(M.Storage.MoveStatements(op)) end

--- Records a movement ANOTHER writer already applied to the balance (the
--- dealership's settled sales), so the history and the bus see it. Idempotent
--- on the operation id; it never touches the balance.
-- @author dop42
-- @param op table { id, kind, group, amount, reason, actor, balance }
-- @return Result
function M.Storage.Note(op)
	return Storage.Execute([[
INSERT IGNORE INTO opx77_company_ledger (op_id, kind, group_key, delta, balance_after, reason, actor)
VALUES (@op, @kind, @group, @delta, NULLIF(@after, ''), @reason, NULLIF(@actor, ''))
  ]], { op = op.id, kind = op.kind, group = op.group, delta = op.amount, after = op.balance ~= nil and tostring(op.balance) or '',
		reason = op.reason, actor = op.actor or '' })
end

--- The newest movements of one account, newest first, a bounded page.
-- @author dop42
-- @param kind string
-- @param group string
-- @param limit integer already clamped by the caller
-- @return Result carrying a list of rows
function M.Storage.History(kind, group, limit)
	limit = math.tointeger(limit) or 10
	if limit < 1 then return Result.Ok({}) end
	return Storage.Query([[
SELECT delta, reason, actor, UNIX_TIMESTAMP(created_at) AS at
  FROM opx77_company_ledger
 WHERE kind = @kind AND group_key = @group
 ORDER BY id DESC
 LIMIT @limit
  ]], { kind = kind, group = group, limit = limit })
end

--- The company participant in one character-wallet transaction.
-- Eligibility subqueries lock the company row with the wallet before either
-- balance changes. Every effect is gated by this exact wallet attempt.
function M.Storage.WalletStatements(op, kind, key, amount, deposit)
	local delta = deposit and amount or -amount
	local gate = ' FROM opx77_money_ledger WHERE op_id = ? AND attempt_token = ?'
	local statements = {
		{ query = 'INSERT INTO opx77_company_ledger (op_id, kind, group_key, delta, reason, actor) ' ..
			'SELECT ?, ?, ?, ?, ?, ?' .. gate,
			values = { op.id, kind, key, delta, op.reason, op.citizenId, op.id, op.attempt } },
		{ query = 'INSERT INTO opx77_company_accounts (kind, group_key, balance) SELECT ?, ?, 0' ..
			gate .. ' ON DUPLICATE KEY UPDATE balance = balance',
			values = { kind, key, op.id, op.attempt } },
		{ query = 'UPDATE opx77_company_accounts a JOIN opx77_money_ledger l ' ..
			'ON l.op_id = ? AND l.attempt_token = ? SET a.balance = a.balance + ? ' ..
			'WHERE a.kind = ? AND a.group_key = ?',
			values = { op.id, op.attempt, delta, kind, key } },
		{ query = 'UPDATE opx77_company_ledger l JOIN opx77_company_accounts a ' ..
			'ON a.kind = l.kind AND a.group_key = l.group_key SET l.balance_after = a.balance ' ..
			'WHERE l.op_id = ? AND EXISTS (SELECT 1 FROM opx77_money_ledger m ' ..
			'WHERE m.op_id = ? AND m.attempt_token = ?)',
			values = { op.id, op.id, op.attempt } },
	}
	local guard
	if deposit then
		guard = { query = 'COALESCE((SELECT balance FROM opx77_company_accounts ' ..
			'WHERE kind = ? AND group_key = ? FOR UPDATE), 0) <= ?',
			values = { kind, key, 9007199254740991 - amount }, error = 'money.tooLarge' }
	else
		guard = { query = 'EXISTS (SELECT 1 FROM opx77_company_accounts ' ..
			'WHERE kind = ? AND group_key = ? AND balance >= ? FOR UPDATE)',
			values = { kind, key, amount }, error = 'insufficient_funds' }
	end
	return statements, guard
end
