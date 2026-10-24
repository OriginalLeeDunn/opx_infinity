--- Every SQL statement invoices runs, and the two tables it owns.
-- @author dop42
--
-- The only file in the module that carries SQL. Named parameters, never `?`;
-- no comment inside a SQL string; every call yields, so every caller is on a
-- thread. A nullable column is bound as `''` and turned back with `NULLIF`,
-- because the bridge drops a nil parameter instead of binding NULL.
--
-- NO FOREIGN KEYS: a bill outlives the characters on it, and the ledger
-- outlives everything. Wall-clock times are unix seconds written by the server
-- into BIGINTs: a tab that lapses in a week must lapse in a week across a
-- restart, which `OPX.Now` (process milliseconds) cannot promise.
--
-- THE COMPARE-AND-SWAP. Every state change is one UPDATE whose WHERE names the
-- state AND the revision it was read at; a writer that raced us finds zero rows
-- and is refused. The in-memory claim in `server/main.lua` is the first belt,
-- this is the second.

local M = OPX.Modules.Get('invoices')

local Result = OPX.Result
local Storage = OPX.Storage

M.Storage = {}
M.Storage.COLUMNS = {
	{ TABLE = 'opx77_invoice_ledger', COLUMN = 'durable_version', DEFINITION = 'TINYINT UNSIGNED NOT NULL DEFAULT 0' },
	{ TABLE = 'opx77_invoice_ledger', COLUMN = 'destination',
		DEFINITION = 'VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL' },
}

M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_invoices (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    state VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    rev INT UNSIGNED NOT NULL DEFAULT 0,
    issuer_cid VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    issuer_name VARCHAR(64) NOT NULL,
    target_cid VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    target_name VARCHAR(64) NOT NULL,
    company VARCHAR(64) NULL DEFAULT NULL,
    amount INT UNSIGNED NOT NULL,
    reason VARCHAR(160) NOT NULL,
    account_kind VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    account_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    cut_pct TINYINT UNSIGNED NOT NULL DEFAULT 0,
    source VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    paid_with VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    issued_at BIGINT NOT NULL,
    expires_at BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_opx77_invoices_state (state),
    KEY idx_opx77_invoices_target (target_cid, state),
    KEY idx_opx77_invoices_issuer (issuer_cid, state)
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_invoice_ledger (
    op_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    invoice_id BIGINT UNSIGNED NOT NULL,
    phase VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    amount INT UNSIGNED NOT NULL,
    state VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    durable_version TINYINT UNSIGNED NOT NULL DEFAULT 0,
    destination VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_opx77_invoice_ledger_state (state),
    KEY idx_opx77_invoice_ledger_invoice (invoice_id)
) ENGINE=InnoDB
]],
}

local function nullable(value) return value ~= nil and tostring(value) or '' end

local function text(value)
	if value == nil or value == '' or type(value) == 'userdata' then return nil end
	return tostring(value)
end

--- Reads one row into the record shape the server keeps in memory.
-- @author dop42
-- @param row table
-- @return table
function M.Storage.Record(row)
	local kind, key = text(row.account_kind), text(row.account_key)
	return {
		id = math.tointeger(tonumber(row.id)) or 0,
		state = tostring(row.state),
		rev = math.tointeger(tonumber(row.rev)) or 0,
		issuerCid = tostring(row.issuer_cid),
		issuerName = tostring(row.issuer_name or ''),
		targetCid = tostring(row.target_cid),
		targetName = tostring(row.target_name or ''),
		company = text(row.company),
		amount = math.tointeger(tonumber(row.amount)) or 0,
		reason = tostring(row.reason or ''),
		account = (kind ~= nil and key ~= nil) and { kind = kind, key = key } or nil,
		cutPct = math.tointeger(tonumber(row.cut_pct)) or 0,
		source = tostring(row.source or ''),
		paidWith = text(row.paid_with),
		issuedAt = math.floor(tonumber(row.issued_at) or 0),
		expiresAt = math.floor(tonumber(row.expires_at) or 0),
	}
end

--- Files a new bill, answering its id.
-- @author dop42
-- @param record table
-- @return Result integer
function M.Storage.Insert(record)
	local inserted = Storage.Insert([[
INSERT INTO opx77_invoices
    (state, rev, issuer_cid, issuer_name, target_cid, target_name, company, amount, reason,
     account_kind, account_key, cut_pct, source, issued_at, expires_at)
VALUES
    (@state, 0, @issuer, @issuerName, @target, @targetName, NULLIF(@company, ''), @amount, @reason,
     NULLIF(@kind, ''), NULLIF(@key, ''), @cut, @source, @issuedAt, @expiresAt)
]], {
		['@state'] = record.state,
		['@issuer'] = record.issuerCid,
		['@issuerName'] = record.issuerName,
		['@target'] = record.targetCid,
		['@targetName'] = record.targetName,
		['@company'] = nullable(record.company),
		['@amount'] = record.amount,
		['@reason'] = record.reason,
		['@kind'] = nullable(record.account and record.account.kind),
		['@key'] = nullable(record.account and record.account.key),
		['@cut'] = record.cutPct,
		['@source'] = record.source,
		['@issuedAt'] = math.floor(tonumber(record.issuedAt) or 0),
		['@expiresAt'] = math.floor(tonumber(record.expiresAt) or 0),
	})
	if not inserted.ok then return inserted end
	local id = math.tointeger(tonumber(inserted.value))
	if id == nil or id < 1 then return Result.Err('insert_failed') end
	return Result.Ok(id)
end

--- Writes a bill's new state IF the row still stands where it was read.
-- @author dop42
-- @param record table carrying the NEW state, rev, paidWith and expiresAt
-- @param fromState string
-- @param fromRev integer
-- @return Result boolean whether the row moved
function M.Storage.Move(record, fromState, fromRev)
	local moved = Storage.Update([[
UPDATE opx77_invoices
   SET state = @state, rev = @rev, paid_with = NULLIF(@paidWith, ''), expires_at = @expiresAt
 WHERE id = @id AND state = @from AND rev = @fromRev
]], {
		['@id'] = record.id,
		['@state'] = record.state,
		['@rev'] = record.rev,
		['@paidWith'] = nullable(record.paidWith),
		['@expiresAt'] = math.floor(tonumber(record.expiresAt) or 0),
		['@from'] = fromState,
		['@fromRev'] = fromRev,
	})
	if not moved.ok then return moved end
	return Result.Ok((tonumber(moved.value) or 0) > 0)
end

--- Every bill not yet final, oldest first.
-- @author dop42
-- @return Result table[] records
function M.Storage.LoadOpen()
	local read = Storage.Query([[
SELECT id, state, rev, issuer_cid, issuer_name, target_cid, target_name, company, amount, reason,
       account_kind, account_key, cut_pct, source, paid_with, issued_at, expires_at
  FROM opx77_invoices
 WHERE state IN ('asked', 'unpaid', 'settling')
 ORDER BY id ASC
]], {})
	if not read.ok then return read end
	local out = {}
	for _, row in ipairs(type(read.value) == 'table' and read.value or {}) do
		out[#out + 1] = M.Storage.Record(row)
	end
	return Result.Ok(out)
end

-- ── the ledger ──────────────────────────────────────────────────────────────

--- Reserves one money operation by its id, or answers the first receipt.
-- @author dop42
-- @param op table { id, invoiceId, phase, citizenId, amount }
-- @return Result { fresh, state }
function M.Storage.Reserve(op)
	local inserted = Storage.Update([[
INSERT IGNORE INTO opx77_invoice_ledger (op_id, invoice_id, phase, citizen_id, amount, state, durable_version, destination)
VALUES (@op, @invoice, @phase, NULLIF(@citizen, ''), @amount, 'reserved', 1, @destination)
]], {
		['@op'] = op.id,
		['@invoice'] = op.invoiceId,
		['@phase'] = op.phase,
		['@citizen'] = nullable(op.citizenId),
		['@amount'] = op.amount,
		['@destination'] = op.destination or 'character',
	})
	if not inserted.ok then return inserted end
	if (tonumber(inserted.value) or 0) > 0 then
		return Result.Ok({ fresh = true, state = 'reserved', durable = true, destination = op.destination or 'character' })
	end
	local read = M.Storage.OpInfo(op.id)
	if not read.ok then return read end
	local row = read.value or {}
	return Result.Ok({ fresh = false, state = row.state or 'reserved',
		durable = tonumber(row.durable_version) == 1, destination = row.destination })
end

--- The state of one operation, or nil when it was never reserved.
-- @author dop42
-- @param opId string
-- @return Result string|nil
function M.Storage.OpInfo(opId)
	return Storage.Single([[
SELECT state, durable_version, destination FROM opx77_invoice_ledger WHERE op_id = @op
]], { ['@op'] = opId })
end

function M.Storage.OpState(opId)
	local read = M.Storage.OpInfo(opId)
	if not read.ok then return read end
	return Result.Ok(type(read.value) == 'table' and tostring(read.value.state) or nil)
end

--- Marks a reserved operation committed, cancelled or orphaned.
-- @author dop42
-- @param opId string
-- @param state string
-- @return Result
function M.Storage.Settle(opId, state)
	return Storage.Update([[
UPDATE opx77_invoice_ledger SET state = @state WHERE op_id = @op AND state = 'reserved'
]], { ['@op'] = opId, ['@state'] = state })
end

--- Takes a cancelled operation back for one more attempt; a cancelled
--- operation moved nothing, and the WHERE lets only one caller have it.
-- @author dop42
-- @param opId string
-- @return Result boolean
function M.Storage.Rearm(opId)
	local moved = Storage.Update([[
UPDATE opx77_invoice_ledger SET state = 'reserved' WHERE op_id = @op AND state = 'cancelled' AND durable_version = 1
]], { ['@op'] = opId })
	if not moved.ok then return moved end
	return Result.Ok((tonumber(moved.value) or 0) > 0)
end

--- Every operation a dead process left `reserved`.
-- @author dop42
-- @return Result table[] { id, invoiceId, phase, citizenId, amount }
function M.Storage.Pending()
	local read = Storage.Query([[
SELECT op_id, invoice_id, phase, citizen_id, amount, durable_version
  FROM opx77_invoice_ledger WHERE state = 'reserved'
]], {})
	if not read.ok then return read end
	local out = {}
	for _, row in ipairs(type(read.value) == 'table' and read.value or {}) do
		out[#out + 1] = { id = tostring(row.op_id), invoiceId = math.tointeger(tonumber(row.invoice_id)),
			phase = tostring(row.phase), citizenId = text(row.citizen_id),
			amount = math.tointeger(tonumber(row.amount)) or 0, durable = tonumber(row.durable_version) == 1 }
	end
	return Result.Ok(out)
end
