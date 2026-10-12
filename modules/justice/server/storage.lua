--- Every SQL statement justice runs, and the three tables it owns.
-- @author dop42
--
-- The only file in the module that carries SQL. Named parameters, never `?`;
-- no comment inside a SQL string; every call yields, so every caller is on a
-- thread. A nullable column is bound as '' and turned back with NULLIF,
-- because the bridge drops a nil parameter instead of binding NULL.
--
-- NO FOREIGN KEY on the citizen ids: a record is a ledger, and a ledger
-- outlives the character it names (a deleted character's conviction is still
-- the court's history).
--
-- THE WALL CLOCK IS UNIX SECONDS (`Open77.time.unix`) in a BIGINT: a felony's
-- date has to mean the same thing after a restart.
--
-- THE COMPARE-AND-SWAP. A ruling, a bail payment and a verdict are each one
-- UPDATE whose WHERE names the state it was read in; a second judge or a
-- replayed packet finds zero rows and is refused.

local M = OPX.Modules.Get('justice')

M.Storage = {}
local Storage = M.Storage

Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_justice_records (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizen VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    kind VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    code VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    label VARCHAR(128) NOT NULL,
    fine INT UNSIGNED NOT NULL DEFAULT 0,
    jail INT UNSIGNED NOT NULL DEFAULT 0,
    bail INT UNSIGNED NOT NULL DEFAULT 0,
    officer VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    officer_name VARCHAR(96) NULL DEFAULT NULL,
    notes VARCHAR(512) NULL DEFAULT NULL,
    source VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    felony TINYINT UNSIGNED NOT NULL DEFAULT 0,
    paid TINYINT UNSIGNED NOT NULL DEFAULT 0,
    active TINYINT UNSIGNED NOT NULL DEFAULT 0,
    expunged TINYINT UNSIGNED NOT NULL DEFAULT 0,
    expunge VARCHAR(10) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    expunge_by VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    created_at BIGINT NOT NULL,
    KEY idx_opx77_justice_records_citizen (citizen, id),
    KEY idx_opx77_justice_records_expunge (expunge),
    KEY idx_opx77_justice_records_active (kind, active)
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_justice_counsel (
    client VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    client_name VARCHAR(96) NULL DEFAULT NULL,
    lawyer VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    lawyer_name VARCHAR(96) NULL DEFAULT NULL,
    since BIGINT NOT NULL,
    KEY idx_opx77_justice_counsel_lawyer (lawyer)
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_justice_cases (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    defendant VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    defendant_name VARCHAR(96) NULL DEFAULT NULL,
    judge VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    judge_name VARCHAR(96) NULL DEFAULT NULL,
    code VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    summary VARCHAR(512) NULL DEFAULT NULL,
    state VARCHAR(8) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    verdict VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    record_id BIGINT UNSIGNED NULL DEFAULT NULL,
    created_at BIGINT NOT NULL,
    closed_at BIGINT NULL DEFAULT NULL,
    KEY idx_opx77_justice_cases_state (state, id)
) ENGINE=InnoDB
]],
}

local RECORD_COLUMNS = [[id, citizen, kind, code, label, fine, jail, bail, officer, officer_name, notes, source,
felony, paid, active, expunged, expunge, expunge_by, created_at]]

local SQL = {
	ADD = [[
INSERT INTO opx77_justice_records
  (citizen, kind, code, label, fine, jail, bail, officer, officer_name, notes, source, felony, paid, active, created_at)
VALUES (@citizen, @kind, @code, @label, @fine, @jail, @bail, NULLIF(@officer, ''), NULLIF(@officerName, ''),
  NULLIF(@notes, ''), @source, @felony, @paid, @active, @at)
]],
	LIST = 'SELECT ' .. RECORD_COLUMNS .. [[ FROM opx77_justice_records
WHERE citizen = @citizen AND (expunged = 0 OR @all = 1) ORDER BY id DESC LIMIT 200]],
	GET = 'SELECT ' .. RECORD_COLUMNS .. ' FROM opx77_justice_records WHERE id = @id',
	PENDING = 'SELECT ' .. RECORD_COLUMNS .. [[ FROM opx77_justice_records
WHERE expunge = 'pending' AND expunged = 0 ORDER BY id ASC LIMIT 200]],
	WARRANTS = 'SELECT ' .. RECORD_COLUMNS .. [[ FROM opx77_justice_records
WHERE kind = 'warrant' AND active = 1 AND expunged = 0 ORDER BY id DESC LIMIT 200]],
	REQUEST = [[
UPDATE opx77_justice_records SET expunge = 'pending', expunge_by = @by
WHERE id = @id AND citizen = @citizen AND expunged = 0 AND active = 0
  AND (expunge IS NULL OR expunge = 'denied')
]],
	RULE = [[
UPDATE opx77_justice_records SET expunge = @state, expunged = @expunged
WHERE id = @id AND expunge = 'pending' AND expunged = 0
]],
	BAIL = [[
UPDATE opx77_justice_records SET bail = @bail
WHERE id = @id AND kind = 'warrant' AND active = 1
]],
	LIFT = [[
UPDATE opx77_justice_records SET active = 0
WHERE id = @id AND kind = 'warrant' AND active = 1
]],
	PAY_BAIL = [[
UPDATE opx77_justice_records SET active = 0, paid = 1
WHERE id = @id AND citizen = @citizen AND kind = 'warrant' AND active = 1 AND bail = @bail AND bail > 0
]],
	PAID = 'UPDATE opx77_justice_records SET paid = 1 WHERE id = @id',

	COUNSEL_GET = 'SELECT client, client_name, lawyer, lawyer_name, since FROM opx77_justice_counsel WHERE client = @client',
	COUNSEL_SET = [[
INSERT INTO opx77_justice_counsel (client, client_name, lawyer, lawyer_name, since)
VALUES (@client, NULLIF(@clientName, ''), @lawyer, NULLIF(@lawyerName, ''), @since)
ON DUPLICATE KEY UPDATE client_name = VALUES(client_name), lawyer = VALUES(lawyer),
  lawyer_name = VALUES(lawyer_name), since = VALUES(since)
]],
	COUNSEL_DROP = 'DELETE FROM opx77_justice_counsel WHERE client = @client',
	CLIENTS = [[
SELECT client, client_name, lawyer, lawyer_name, since FROM opx77_justice_counsel
WHERE lawyer = @lawyer ORDER BY since DESC LIMIT 200
]],

	CASE_OPEN = [[
INSERT INTO opx77_justice_cases (defendant, defendant_name, judge, judge_name, code, summary, state, created_at)
VALUES (@defendant, NULLIF(@defendantName, ''), @judge, NULLIF(@judgeName, ''), @code, NULLIF(@summary, ''),
  'open', @at)
]],
	CASES = [[
SELECT id, defendant, defendant_name, judge, judge_name, code, summary, state, verdict, created_at
FROM opx77_justice_cases WHERE state = 'open' ORDER BY id DESC LIMIT 200
]],
	CASE_GET = [[
SELECT id, defendant, defendant_name, judge, judge_name, code, summary, state, verdict, created_at
FROM opx77_justice_cases WHERE id = @id
]],
	CASE_CLOSE = [[
UPDATE opx77_justice_cases SET state = 'closed', verdict = @verdict, record_id = NULLIF(@recordId, ''),
  closed_at = @at
WHERE id = @id AND state = 'open'
]],
}
Storage.SQL = SQL

local function str(value)
	if value == nil then return nil end
	return tostring(value)
end

local function int(value)
	return math.tointeger(tonumber(value)) or 0
end

local function flag(value)
	return value == true or tonumber(value) == 1
end

local function recordOf(row)
	if type(row) ~= 'table' then return nil end
	return {
		id = int(row.id), citizen = str(row.citizen), kind = str(row.kind), code = str(row.code),
		label = str(row.label), fine = int(row.fine), jail = int(row.jail), bail = int(row.bail),
		officer = str(row.officer), officerName = str(row.officer_name), notes = str(row.notes),
		source = str(row.source), felony = flag(row.felony), paid = flag(row.paid), active = flag(row.active),
		expunged = flag(row.expunged), expunge = str(row.expunge), expungeBy = str(row.expunge_by),
		at = int(row.created_at),
	}
end

local function rows(read, shape, limit)
	if not read.ok or type(read.value) ~= 'table' then
		if not read.ok then
			Open77.log.error('[justice] a read failed: ' .. tostring(read.detail or read.error))
		end
		return {}
	end
	local out = {}
	for _, row in ipairs(read.value) do
		local shaped = shape(row)
		if shaped ~= nil then out[#out + 1] = shaped end
		if limit ~= nil and #out >= limit then break end
	end
	return out
end

local function changed(result)
	return result.ok == true and (tonumber(result.value) or 0) > 0
end

local function logged(result, what)
	if not result.ok then
		Open77.log.error(('[justice] %s failed: %s'):format(what, tostring(result.detail or result.error)))
	end
	return result
end

-- ── the record ──────────────────────────────────────────────────────────────

--- Writes one cleaned entry (see `Access.Entry`). Yields.
-- @author dop42
-- @return integer|nil the new id
function Storage.Add(citizenId, entry, atS)
	local written = logged(OPX.Storage.Insert(SQL.ADD, {
		citizen = citizenId, kind = entry.kind, code = entry.code, label = entry.label,
		fine = entry.fine, jail = entry.jail, bail = entry.bail or 0,
		officer = entry.officer or '', officerName = entry.officerName or '', notes = entry.notes or '',
		source = entry.source, felony = entry.felony and 1 or 0, paid = entry.paid and 1 or 0,
		active = entry.active and 1 or 0, at = math.floor(atS),
	}), 'a record entry')
	if not written.ok then return nil end
	return math.tointeger(tonumber(written.value)) or 0
end

--- A citizen's record, newest first. Yields.
-- @author dop42
function Storage.List(citizenId, limit, withExpunged)
	return rows(OPX.Storage.Query(SQL.LIST, { citizen = citizenId, all = withExpunged and 1 or 0 }),
		recordOf, limit)
end

--- One entry by id, or nil. Yields.
-- @author dop42
function Storage.Get(id)
	local read = OPX.Storage.Single(SQL.GET, { id = id })
	return read.ok and recordOf(read.value) or nil
end

--- Every expungement request waiting for a judge. Yields.
-- @author dop42
function Storage.Pending(limit)
	return rows(OPX.Storage.Query(SQL.PENDING, {}), recordOf, limit)
end

--- Every active warrant. Yields.
-- @author dop42
function Storage.Warrants(limit)
	return rows(OPX.Storage.Query(SQL.WARRANTS, {}), recordOf, limit)
end

--- A lawyer's request; true when the entry moved to `pending`. Yields.
-- @author dop42
function Storage.Request(id, citizenId, lawyerCid)
	return changed(logged(OPX.Storage.Execute(SQL.REQUEST, { id = id, citizen = citizenId, by = lawyerCid }),
		'an expungement request'))
end

--- A judge's ruling; true when the pending request was ruled. Yields.
-- @author dop42
function Storage.Rule(id, approved)
	return changed(logged(OPX.Storage.Execute(SQL.RULE, { id = id,
		state = approved and 'approved' or 'denied', expunged = approved and 1 or 0 }), 'a ruling'))
end

--- Sets the bail on an active warrant. Yields.
-- @author dop42
function Storage.SetBail(id, bail)
	return changed(logged(OPX.Storage.Execute(SQL.BAIL, { id = id, bail = bail }), 'a bail'))
end

--- Lifts an active warrant. Yields.
-- @author dop42
function Storage.Lift(id)
	return changed(logged(OPX.Storage.Execute(SQL.LIFT, { id = id }), 'a warrant lift'))
end

--- Clears one's own warrant for the bail read; true once, ever. Yields.
-- @author dop42
function Storage.PayBail(id, citizenId, bail)
	return changed(logged(OPX.Storage.Execute(SQL.PAY_BAIL, { id = id, citizen = citizenId, bail = bail }),
		'a bail payment'))
end

--- Marks a fine paid. Yields.
-- @author dop42
function Storage.Paid(id)
	return changed(logged(OPX.Storage.Execute(SQL.PAID, { id = id }), 'a fine payment'))
end

-- ── counsel ─────────────────────────────────────────────────────────────────

local function counselOf(row)
	if type(row) ~= 'table' or row.client == nil then return nil end
	return { client = str(row.client), clientName = str(row.client_name), lawyer = str(row.lawyer),
		lawyerName = str(row.lawyer_name), since = int(row.since) }
end

--- Who represents a citizen, or nil. Yields.
-- @author dop42
function Storage.Counsel(citizenId)
	local read = OPX.Storage.Single(SQL.COUNSEL_GET, { client = citizenId })
	return read.ok and counselOf(read.value) or nil
end

--- Writes (or replaces) a citizen's counsel. Yields.
-- @author dop42
function Storage.SetCounsel(row)
	return logged(OPX.Storage.Execute(SQL.COUNSEL_SET, { client = row.client, clientName = row.clientName or '',
		lawyer = row.lawyer, lawyerName = row.lawyerName or '', since = math.floor(row.since) }), 'a counsel').ok
end

--- Ends a citizen's representation. Yields.
-- @author dop42
function Storage.DropCounsel(citizenId)
	return changed(logged(OPX.Storage.Execute(SQL.COUNSEL_DROP, { client = citizenId }), 'a counsel drop'))
end

--- A lawyer's clients. Yields.
-- @author dop42
function Storage.Clients(lawyerCid, limit)
	return rows(OPX.Storage.Query(SQL.CLIENTS, { lawyer = lawyerCid }), counselOf, limit)
end

-- ── the docket ──────────────────────────────────────────────────────────────

local function caseOf(row)
	if type(row) ~= 'table' or row.id == nil then return nil end
	return { id = int(row.id), defendant = str(row.defendant), defendantName = str(row.defendant_name),
		judge = str(row.judge), judgeName = str(row.judge_name), code = str(row.code), summary = str(row.summary),
		state = str(row.state), verdict = str(row.verdict), at = int(row.created_at) }
end

--- Opens a case. Yields.
-- @author dop42
-- @return integer|nil
function Storage.OpenCase(row, atS)
	local written = logged(OPX.Storage.Insert(SQL.CASE_OPEN, { defendant = row.defendant,
		defendantName = row.defendantName or '', judge = row.judge, judgeName = row.judgeName or '',
		code = row.code, summary = row.summary or '', at = math.floor(atS) }), 'a case')
	if not written.ok then return nil end
	return math.tointeger(tonumber(written.value)) or 0
end

--- The open docket. Yields.
-- @author dop42
function Storage.Cases(limit)
	return rows(OPX.Storage.Query(SQL.CASES, {}), caseOf, limit)
end

--- One case, or nil. Yields.
-- @author dop42
function Storage.Case(id)
	local read = OPX.Storage.Single(SQL.CASE_GET, { id = id })
	return read.ok and caseOf(read.value) or nil
end

--- Closes an open case; true once, ever. Yields.
-- @author dop42
function Storage.CloseCase(id, verdict, recordId, atS)
	return changed(logged(OPX.Storage.Execute(SQL.CASE_CLOSE, { id = id, verdict = verdict,
		recordId = recordId ~= nil and tostring(recordId) or '', at = math.floor(atS) }), 'a verdict'))
end
