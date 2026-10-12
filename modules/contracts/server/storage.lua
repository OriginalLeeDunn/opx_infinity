--- Every SQL statement contracts runs, and the three tables it owns.
-- @author dop42
--
-- The only file in the module that carries SQL. Named parameters, never `?`;
-- no comment inside a SQL string; every call yields, so every caller is on a
-- thread. A nullable column is bound as `''` and turned back with `NULLIF`,
-- because the bridge drops a nil parameter instead of binding NULL.
--
-- NO FOREIGN KEYS, on purpose: a gig outlives the characters in it (a deleted
-- merc's paid gig is still history), and the ledger must outlive everything.
--
-- THE WALL CLOCK IS UNIX SECONDS, written by the server (`Open77.time.unix`),
-- into a BIGINT. A deadline has to mean the same thing after a restart, which
-- `OPX.Now` -- milliseconds since this process started -- does not.
--
-- THE COMPARE-AND-SWAP. Every state change is one UPDATE whose WHERE names the
-- state AND the revision it was read at; a writer that raced us finds zero rows
-- and is refused. The in-memory claim in `server/main.lua` is the first belt,
-- this is the second, and it is the one that holds across two processes.

local M = OPX.Modules.Get('contracts')

local Result = OPX.Result
local Storage = OPX.Storage

M.Storage = {}

M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_contracts (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    state VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    outcome VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    rev INT UNSIGNED NOT NULL DEFAULT 0,
    type VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    district VARCHAR(48) NULL DEFAULT NULL,
    title VARCHAR(96) NOT NULL,
    brief TEXT NULL,
    poster_kind VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    poster_cid VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    poster_name VARCHAR(64) NULL DEFAULT NULL,
    payer_cid VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    merc_cid VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    reward INT UNSIGNED NOT NULL,
    cut_pct TINYINT UNSIGNED NOT NULL,
    funded VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    min_cred INT UNSIGNED NOT NULL DEFAULT 0,
    validate VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    objective JSON NOT NULL,
    proof JSON NULL,
    deadline_at BIGINT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_opx77_contracts_state (state),
    KEY idx_opx77_contracts_merc (merc_cid, state),
    KEY idx_opx77_contracts_poster (poster_cid, state)
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_contract_ledger (
    op_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    contract_id BIGINT UNSIGNED NOT NULL,
    phase VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    amount INT UNSIGNED NOT NULL,
    state VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_opx77_contract_ledger_state (state),
    KEY idx_opx77_contract_ledger_contract (contract_id)
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_contract_events (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    contract_id BIGINT UNSIGNED NOT NULL,
    at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    actor_cid VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    from_state VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    to_state VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    data JSON NULL,
    KEY idx_opx77_contract_events_contract (contract_id)
) ENGINE=InnoDB
]],
}

local function nullable(value) return value ~= nil and tostring(value) or '' end

-- The bound parameters of a record's mutable columns.
local function mutable(record)
	return {
		['@id'] = record.id,
		['@state'] = record.state,
		['@outcome'] = nullable(record.outcome),
		['@rev'] = record.rev,
		['@merc'] = nullable(record.mercCid),
		['@proof'] = Storage.Nullable(record.proof),
		['@deadline'] = math.floor(tonumber(record.deadlineAt) or 0),
	}
end

--- Reads one row into the record shape the server keeps in memory.
-- @author dop42
-- @param row table
-- @return table
function M.Storage.Record(row)
	local function text(value)
		if value == nil or value == '' or type(value) == 'userdata' then return nil end
		return tostring(value)
	end
	return {
		id = math.tointeger(tonumber(row.id)) or 0,
		state = tostring(row.state),
		outcome = text(row.outcome),
		rev = math.tointeger(tonumber(row.rev)) or 0,
		type = tostring(row.type),
		district = text(row.district),
		title = tostring(row.title or ''),
		brief = text(row.brief),
		posterKind = tostring(row.poster_kind),
		posterCid = text(row.poster_cid),
		posterName = text(row.poster_name),
		payerCid = text(row.payer_cid),
		mercCid = text(row.merc_cid),
		reward = math.tointeger(tonumber(row.reward)) or 0,
		cutPct = math.tointeger(tonumber(row.cut_pct)) or 0,
		funded = tostring(row.funded),
		minCred = math.tointeger(tonumber(row.min_cred)) or 0,
		validate = tostring(row.validate),
		objective = Storage.Decode(row.objective, {}),
		proof = Storage.Decode(row.proof, nil),
		deadlineAt = math.floor(tonumber(row.deadline_at) or 0),
	}
end

--- Files a new gig in state `locking`, answering its id.
-- @author dop42
-- @param record table
-- @return Result integer
function M.Storage.Insert(record)
	local inserted = Storage.Insert([[
INSERT INTO opx77_contracts
    (state, rev, type, district, title, brief, poster_kind, poster_cid, poster_name,
     payer_cid, reward, cut_pct, funded, min_cred, validate, objective, deadline_at)
VALUES
    (@state, 0, @type, NULLIF(@district, ''), @title, NULLIF(@brief, ''), @posterKind,
     NULLIF(@posterCid, ''), NULLIF(@posterName, ''), NULLIF(@payerCid, ''), @reward, @cut,
     @funded, @minCred, @validate, @objective, @deadline)
]], {
		['@state'] = record.state,
		['@type'] = record.type,
		['@district'] = nullable(record.district),
		['@title'] = record.title,
		['@brief'] = nullable(record.brief),
		['@posterKind'] = record.posterKind,
		['@posterCid'] = nullable(record.posterCid),
		['@posterName'] = nullable(record.posterName),
		['@payerCid'] = nullable(record.payerCid),
		['@reward'] = record.reward,
		['@cut'] = record.cutPct,
		['@funded'] = record.funded,
		['@minCred'] = record.minCred,
		['@validate'] = record.validate,
		['@objective'] = json.encode(record.objective or {}),
		['@deadline'] = math.floor(tonumber(record.deadlineAt) or 0),
	})
	if not inserted.ok then return inserted end
	local id = math.tointeger(tonumber(inserted.value))
	if id == nil or id < 1 then return Result.Err('insert_failed') end
	return Result.Ok(id)
end

--- Writes a record's new state IF the row still stands where it was read.
-- `record` carries the NEW values (state, rev, merc, proof, deadline,
-- outcome); `fromState` and `fromRev` are what the caller read.
-- @author dop42
-- @param record table
-- @param fromState string
-- @param fromRev integer
-- @return Result boolean whether the row moved
function M.Storage.Move(record, fromState, fromRev)
	local params = mutable(record)
	params['@from'] = fromState
	params['@fromRev'] = fromRev
	local moved = Storage.Update([[
UPDATE opx77_contracts
   SET state = @state, rev = @rev, outcome = NULLIF(@outcome, ''),
       merc_cid = NULLIF(@merc, ''), proof = NULLIF(@proof, ''), deadline_at = @deadline
 WHERE id = @id AND state = @from AND rev = @fromRev
]], params)
	if not moved.ok then return moved end
	return Result.Ok((tonumber(moved.value) or 0) > 0)
end

--- Removes a gig that never got its escrow, so it never existed.
-- @author dop42
-- @param id integer
-- @return Result
function M.Storage.Forget(id)
	return Storage.Update([[
DELETE FROM opx77_contracts WHERE id = @id AND state = 'locking'
]], { ['@id'] = id })
end

--- Every gig not yet final, oldest first.
-- @author dop42
-- @return Result table[] records
function M.Storage.LoadOpen()
	local read = Storage.Query([[
SELECT id, state, outcome, rev, type, district, title, brief, poster_kind, poster_cid,
       poster_name, payer_cid, merc_cid, reward, cut_pct, funded, min_cred, validate,
       objective, proof, deadline_at
  FROM opx77_contracts
 WHERE state IN ('locking', 'posted', 'accepted', 'in_progress', 'proof', 'settling', 'disputed')
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
-- `INSERT IGNORE` on the primary key: the second caller with the same op id
-- inserts nothing and reads the row the first one wrote.
-- @author dop42
-- @param op table { id, contractId, phase, citizenId, amount }
-- @return Result { fresh, state }
function M.Storage.Reserve(op)
	local inserted = Storage.Update([[
INSERT IGNORE INTO opx77_contract_ledger (op_id, contract_id, phase, citizen_id, amount, state)
VALUES (@op, @contract, @phase, NULLIF(@citizen, ''), @amount, 'reserved')
]], {
		['@op'] = op.id,
		['@contract'] = op.contractId,
		['@phase'] = op.phase,
		['@citizen'] = nullable(op.citizenId),
		['@amount'] = op.amount,
	})
	if not inserted.ok then return inserted end
	if (tonumber(inserted.value) or 0) > 0 then return Result.Ok({ fresh = true, state = 'reserved' }) end
	local read = Storage.Single([[
SELECT state FROM opx77_contract_ledger WHERE op_id = @op
]], { ['@op'] = op.id })
	if not read.ok then return read end
	local state = type(read.value) == 'table' and tostring(read.value.state) or 'reserved'
	return Result.Ok({ fresh = false, state = state })
end

--- Marks a reserved operation done or abandoned.
-- @author dop42
-- @param opId string
-- @param state string committed | cancelled | orphaned
-- @return Result
function M.Storage.Settle(opId, state)
	return Storage.Update([[
UPDATE opx77_contract_ledger SET state = @state WHERE op_id = @op AND state = 'reserved'
]], { ['@op'] = opId, ['@state'] = state })
end

--- Takes a cancelled operation back for one more attempt. A cancelled
--- operation moved nothing, so trying again cannot pay twice; the WHERE makes
--- sure only one caller gets it back.
-- @author dop42
-- @param opId string
-- @return Result boolean whether this caller holds it now
function M.Storage.Rearm(opId)
	local moved = Storage.Update([[
UPDATE opx77_contract_ledger SET state = 'reserved' WHERE op_id = @op AND state = 'cancelled'
]], { ['@op'] = opId })
	if not moved.ok then return moved end
	return Result.Ok((tonumber(moved.value) or 0) > 0)
end

--- Every operation left `reserved` by a process that died mid-payment.
-- @author dop42
-- @return Result table[] { id, contractId, phase, citizenId, amount }
function M.Storage.Pending()
	local read = Storage.Query([[
SELECT op_id, contract_id, phase, citizen_id, amount
  FROM opx77_contract_ledger WHERE state = 'reserved'
]], {})
	if not read.ok then return read end
	local out = {}
	for _, row in ipairs(type(read.value) == 'table' and read.value or {}) do
		out[#out + 1] = { id = tostring(row.op_id), contractId = math.tointeger(tonumber(
			row.contract_id)), phase = tostring(row.phase), citizenId = row.citizen_id ~= nil
			and tostring(row.citizen_id) or nil, amount = math.tointeger(tonumber(row.amount)) or 0 }
	end
	return Result.Ok(out)
end

--- Whether an operation was committed.
-- @author dop42
-- @param opId string
-- @return Result boolean
function M.Storage.Committed(opId)
	local read = Storage.Single([[
SELECT state FROM opx77_contract_ledger WHERE op_id = @op
]], { ['@op'] = opId })
	if not read.ok then return read end
	return Result.Ok(type(read.value) == 'table' and read.value.state == 'committed')
end

--- How much new money the NPC fixers were paid out in the last hour.
-- @author dop42
-- @return Result integer
function M.Storage.MintedLastHour()
	local read = Storage.Scalar([[
SELECT COALESCE(SUM(amount), 0) FROM opx77_contract_ledger
 WHERE phase = 'mint' AND state = 'committed' AND at > (NOW() - INTERVAL 1 HOUR)
]], {})
	if not read.ok then return read end
	return Result.Ok(math.tointeger(tonumber(read.value)) or 0)
end

--- One line of a gig's history. Best effort: a history row that fails is
--- logged by the caller and never blocks the gig.
-- @author dop42
-- @param contractId integer
-- @param actorCid string|nil
-- @param from string|nil
-- @param to string
-- @param data table|nil
-- @return Result
function M.Storage.History(contractId, actorCid, from, to, data)
	return Storage.Insert([[
INSERT INTO opx77_contract_events (contract_id, actor_cid, from_state, to_state, data)
VALUES (@contract, NULLIF(@actor, ''), NULLIF(@from, ''), @to, NULLIF(@data, ''))
]], {
		['@contract'] = contractId,
		['@actor'] = nullable(actorCid),
		['@from'] = nullable(from),
		['@to'] = to,
		['@data'] = Storage.Nullable(data),
	})
end
