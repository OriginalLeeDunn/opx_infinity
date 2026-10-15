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
SELECT kind, group_key, delta, balance_after
  FROM opx77_company_ledger
 WHERE op_id = @op
  ]], { op = opId })
end

-- The statement that writes a movement's balance_after, shared by all three.
local STAMP = 'UPDATE opx77_company_ledger l JOIN opx77_company_accounts a ' ..
	'ON a.kind = l.kind AND a.group_key = l.group_key ' ..
	'SET l.balance_after = a.balance WHERE l.op_id = ?'

--- Credits an account, creating it at the first credit. One transaction.
-- @author dop42
-- @param op table { id, kind, group, amount, reason, actor }
-- @return Result
function M.Storage.Credit(op)
	return Storage.Transaction({
		{ query = 'INSERT INTO opx77_company_ledger (op_id, kind, group_key, delta, reason, actor) ' ..
			'VALUES (?, ?, ?, ?, ?, ?)',
			values = { op.id, op.kind, op.group, op.amount, op.reason, op.actor } },
		{ query = 'INSERT INTO opx77_company_accounts (kind, group_key, balance) VALUES (?, ?, ?) ' ..
			'ON DUPLICATE KEY UPDATE balance = balance + VALUES(balance)',
			values = { op.kind, op.group, op.amount } },
		{ query = STAMP, values = { op.id } },
	})
end

--- Debits an account if, and only if, it covers the amount. One transaction;
--- a debit it cannot cover commits nothing, and the missing receipt says so.
-- @author dop42
-- @param op table { id, kind, group, amount, reason, actor }
-- @return Result
function M.Storage.Debit(op)
	return Storage.Transaction({
		{ query = 'INSERT INTO opx77_company_ledger (op_id, kind, group_key, delta, reason, actor) ' ..
			'SELECT ?, kind, group_key, ?, ?, ? FROM opx77_company_accounts ' ..
			'WHERE kind = ? AND group_key = ? AND balance >= ?',
			values = { op.id, -op.amount, op.reason, op.actor, op.kind, op.group, op.amount } },
		{ query = 'UPDATE opx77_company_accounts a JOIN opx77_company_ledger l ' ..
			'ON l.kind = a.kind AND l.group_key = a.group_key ' ..
			'SET a.balance = a.balance + l.delta WHERE l.op_id = ?',
			values = { op.id } },
		{ query = STAMP, values = { op.id } },
	})
end

--- Moves money between two accounts: the debit guarded as above, the credit
--- written from the debit's own row, so a debit refused credits nothing.
-- @author dop42
-- @param op table { out, into, from = {kind, group}, to = {kind, group}, amount, reason, actor }
-- @return Result
function M.Storage.Move(op)
	return Storage.Transaction({
		{ query = 'INSERT INTO opx77_company_ledger (op_id, kind, group_key, delta, reason, actor) ' ..
			'SELECT ?, kind, group_key, ?, ?, ? FROM opx77_company_accounts ' ..
			'WHERE kind = ? AND group_key = ? AND balance >= ?',
			values = { op.out, -op.amount, op.reason, op.actor, op.from.kind, op.from.group, op.amount } },
		{ query = 'INSERT INTO opx77_company_ledger (op_id, kind, group_key, delta, reason, actor) ' ..
			'SELECT ?, ?, ?, -delta, reason, actor FROM opx77_company_ledger WHERE op_id = ?',
			values = { op.into, op.to.kind, op.to.group, op.out } },
		{ query = 'INSERT INTO opx77_company_accounts (kind, group_key, balance) ' ..
			'SELECT kind, group_key, 0 FROM opx77_company_ledger WHERE op_id = ? ' ..
			'ON DUPLICATE KEY UPDATE balance = balance',
			values = { op.into } },
		{ query = 'UPDATE opx77_company_accounts a JOIN opx77_company_ledger l ' ..
			'ON l.kind = a.kind AND l.group_key = a.group_key ' ..
			'SET a.balance = a.balance + l.delta WHERE l.op_id = ? OR l.op_id = ?',
			values = { op.out, op.into } },
		{ query = STAMP, values = { op.out } },
		{ query = STAMP, values = { op.into } },
	})
end

--- Records a movement ANOTHER writer already applied to the balance (the
--- dealership's settled sales), so the history and the bus see it. Idempotent
--- on the operation id; it never touches the balance.
-- @author dop42
-- @param op table { id, kind, group, amount, reason, actor, balance }
-- @return Result
function M.Storage.Note(op)
	return Storage.Execute([[
INSERT IGNORE INTO opx77_company_ledger (op_id, kind, group_key, delta, balance_after, reason, actor)
VALUES (@op, @kind, @group, @delta, @after, @reason, @actor)
  ]], { op = op.id, kind = op.kind, group = op.group, delta = op.amount, after = op.balance,
		reason = op.reason, actor = op.actor })
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
