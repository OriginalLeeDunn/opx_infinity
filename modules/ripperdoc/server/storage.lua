--- The operation receipts: what was taken in escrow, and how far it got.
-- @author dop42
--
-- ONE ROW PER OPERATION, written BEFORE the money or the part moves and moved
-- through `reserved` -> `submitted` -> `committed` | `cancelled`. A server that
-- dies in between leaves a row that says exactly what to give back (reserved)
-- or which native operation to replay with the SAME operation id and expected
-- revision (submitted) -- the platform's receipts make that replay idempotent.
--
-- THE BRIDGE DROPS A nil PARAMETER instead of binding NULL (see
-- `OPX.Storage.Nullable`), so every nullable column is bound as '' and turned
-- back with NULLIF in the statement.
--
-- NO FOREIGN KEY on the citizen ids, like `opx77_character_down`: a receipt is
-- a ledger line, and a ledger outlives the character it names.

local M = OPX.Modules.Get('ripperdoc')

M.Storage = {}
local Storage = M.Storage

Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_ripperdoc_operations (
    id VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    patient VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    doc VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    clinic VARCHAR(48) NOT NULL,
    action VARCHAR(8) NOT NULL,
    chrome VARCHAR(48) NOT NULL,
    tier TINYINT UNSIGNED NOT NULL,
    phase VARCHAR(12) NOT NULL,
    amount INT UNSIGNED NOT NULL DEFAULT 0,
    method VARCHAR(8) NOT NULL,
    part TEXT NULL,
    native_op VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NULL,
    revision BIGINT NULL,
    outcome VARCHAR(16) NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    INDEX opx77_ripperdoc_operations_phase (phase),
    INDEX opx77_ripperdoc_operations_patient (patient)
) ENGINE=InnoDB
]],
}

local INSERT = [[
INSERT INTO opx77_ripperdoc_operations
  (id, patient, doc, clinic, action, chrome, tier, phase, amount, method, part)
VALUES (@id, @patient, @doc, @clinic, @action, @chrome, @tier, @phase, @amount, @method, NULLIF(@part, ''))
]]

local UPDATE = [[
UPDATE opx77_ripperdoc_operations
SET phase = @phase, native_op = NULLIF(@nativeOp, ''), revision = NULLIF(@revision, ''),
    outcome = NULLIF(@outcome, '')
WHERE id = @id
]]

local OPEN = [[
SELECT id, patient, doc, clinic, action, chrome, tier, phase, amount, method, part, native_op, revision, outcome
FROM opx77_ripperdoc_operations WHERE phase IN ('reserved', 'submitted') LIMIT 500
]]

local function encode(value)
	if value == nil then return nil end
	local ok, out = pcall(json.encode, value)
	return ok and out or nil
end

--- Writes the receipt of a new operation, phase `reserved`. Yields.
-- @author dop42
-- @return boolean
function Storage.Insert(op)
	local written = OPX.Storage.Insert(INSERT, {
		id = op.id, patient = op.patientCid, doc = op.docCid, clinic = op.clinic,
		action = op.action, chrome = op.chrome, tier = op.tier, phase = M.Phase.RESERVED,
		amount = op.total, method = op.method,
		-- Everything a commit needs that is not a column, for a replay after a crash.
		part = encode({ source = op.part.source, slot = op.part.slot, meta = op.part.meta, serial = op.part.serial,
			origin = op.origin, condition = op.condition, humanity = op.humanity }) or '',
	})
	if not written.ok then
		Open77.log.error(('[ripperdoc] the receipt of %s was not written: %s')
			:format(op.id, tostring(written.detail or written.error)))
	end
	return written.ok == true
end

--- Moves a receipt to a phase. Yields; a failure is logged, never raised.
-- @author dop42
function Storage.Phase(op, phase, outcome)
	local written = OPX.Storage.Execute(UPDATE, {
		id = op.id, phase = phase, nativeOp = op.nativeOp or '',
		revision = op.revision ~= nil and tostring(math.tointeger(op.revision) or op.revision) or '',
		outcome = outcome or op.outcome or '',
	})
	if not written.ok then
		Open77.log.error(('[ripperdoc] the receipt of %s was not moved to %s: %s')
			:format(op.id, phase, tostring(written.detail or written.error)))
	end
	return written.ok == true
end

--- Every receipt still open: what a crash left behind. Yields.
-- @author dop42
-- @return table[]
function Storage.Open()
	local read = OPX.Storage.Query(OPEN, {})
	if not read.ok or type(read.value) ~= 'table' then
		if not read.ok then
			Open77.log.error('[ripperdoc] the open receipts could not be read: ' ..
				tostring(read.detail or read.error))
		end
		return {}
	end
	local rows = {}
	for _, row in ipairs(read.value) do
		rows[#rows + 1] = {
			id = tostring(row.id), patientCid = tostring(row.patient), docCid = tostring(row.doc),
			clinic = tostring(row.clinic), action = tostring(row.action), chrome = tostring(row.chrome),
			tier = math.tointeger(tonumber(row.tier)) or 1, phase = tostring(row.phase),
			total = math.tointeger(tonumber(row.amount)) or 0, method = tostring(row.method),
			part = OPX.Storage.Decode(row.part, nil),
			nativeOp = row.native_op ~= nil and tostring(row.native_op) or nil,
			revision = tonumber(row.revision),
			outcome = row.outcome ~= nil and tostring(row.outcome) or nil,
		}
	end
	return rows
end
