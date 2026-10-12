--- The underworld's rows: the dirty-money ledger, the escrow, the tills and the
--- laundering batches.
-- @author dop42
--
-- Every statement in the module lives here. No foreign key to the character
-- table, as `modules/downed/server/storage.lua` says: the order tables are
-- created in is not this module's to decide.
--
-- WRITES THAT NOTHING WAITS FOR GO THROUGH ONE QUEUE, drained by one thread in
-- the order they were asked for: a ledger line, an escrow opened then closed, a
-- till's charges. The order is the point -- an escrow row deleted before its
-- insert landed would come back at the next boot as money owed. READS and the
-- two writes whose answer matters (a batch collected exactly once, a batch
-- inserted) are asked directly and yield.
--
-- A FAILED STATEMENT IS A WARNING, never an error: the money it was about has
-- either not moved yet (a read) or is in the audit journal already (a write),
-- and an error line is what the hostile-input battery reads as a door that died.

local M = OPX.Modules.Get('underworld')

M.Storage = {}
local Storage = M.Storage

Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_underworld_ledger (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    source VARCHAR(48) NOT NULL,
    amount BIGINT NOT NULL,
    x FLOAT NULL, y FLOAT NULL, z FLOAT NULL,
    ts TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY opx77_underworld_ledger_citizen (citizen_id, ts)
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_underworld_escrow (
    op_id VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    payload TEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_underworld_registers (
    store_id VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    charges INT NOT NULL,
    last_at DATETIME NOT NULL
) ENGINE=InnoDB
]],
	[[
CREATE TABLE IF NOT EXISTS opx77_underworld_batches (
    id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    front_id VARCHAR(32) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    dirty BIGINT NOT NULL,
    clean BIGINT NOT NULL,
    payout VARCHAR(16) NOT NULL,
    deposited_at DATETIME NOT NULL,
    ready_at DATETIME NOT NULL,
    collected TINYINT(1) NOT NULL DEFAULT 0,
    KEY opx77_underworld_batches_citizen (citizen_id, front_id, collected)
) ENGINE=InnoDB
]],
}

local INSERT_LEDGER = [[
INSERT INTO opx77_underworld_ledger (citizen_id, source, amount, x, y, z)
VALUES (@citizen, @source, @amount, @x, @y, @z)
]]
local SELECT_LEDGER = [[
SELECT source, amount, x, y, z, ts FROM opx77_underworld_ledger WHERE citizen_id = @citizen
ORDER BY id DESC LIMIT 20
]]
local SUM_LEDGER = 'SELECT COALESCE(SUM(amount), 0) FROM opx77_underworld_ledger WHERE citizen_id = @citizen'

local INSERT_ESCROW = [[
INSERT INTO opx77_underworld_escrow (op_id, citizen_id, payload) VALUES (@op, @citizen, @payload)
]]
local DELETE_ESCROW = 'DELETE FROM opx77_underworld_escrow WHERE op_id = @op'
local SELECT_ESCROW = 'SELECT op_id, citizen_id, payload FROM opx77_underworld_escrow LIMIT 500'

local SELECT_REGISTERS = [[
SELECT store_id, charges, TIMESTAMPDIFF(SECOND, last_at, UTC_TIMESTAMP()) AS age
FROM opx77_underworld_registers
]]
local UPSERT_REGISTER = [[
INSERT INTO opx77_underworld_registers (store_id, charges, last_at)
VALUES (@store, @charges, DATE_SUB(UTC_TIMESTAMP(), INTERVAL @age SECOND))
ON DUPLICATE KEY UPDATE charges = @charges, last_at = DATE_SUB(UTC_TIMESTAMP(), INTERVAL @age SECOND)
]]

local INSERT_BATCH = [[
INSERT INTO opx77_underworld_batches (citizen_id, front_id, dirty, clean, payout, deposited_at, ready_at)
VALUES (@citizen, @front, @dirty, @clean, @payout, UTC_TIMESTAMP(),
        DATE_ADD(UTC_TIMESTAMP(), INTERVAL @seconds SECOND))
]]
-- "A DAY" IS THE UTC CALENDAR DAY, read off the database's clock like every
-- other time in this file (`modules/crafting/server/storage.lua` says why a
-- process clock cannot be stored and a TIMESTAMP column must not be).
local SUM_DEPOSITED = [[
SELECT COALESCE(SUM(dirty), 0) FROM opx77_underworld_batches
WHERE citizen_id = @citizen AND deposited_at >= UTC_DATE()
]]
local SELECT_BATCHES = [[
SELECT id, dirty, clean, payout, TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), ready_at) AS remaining
FROM opx77_underworld_batches
WHERE citizen_id = @citizen AND front_id = @front AND collected = 0 ORDER BY id LIMIT 50
]]
-- `ready_at <= UTC_TIMESTAMP()` in the WHERE clause, so a batch that is not
-- ready cannot be collected whatever the caller believed.
local COLLECT_BATCH = [[
UPDATE opx77_underworld_batches SET collected = 1
WHERE id = @id AND citizen_id = @citizen AND collected = 0 AND ready_at <= UTC_TIMESTAMP()
]]
local UNCOLLECT_BATCH = 'UPDATE opx77_underworld_batches SET collected = 0 WHERE id = @id'

-- Writes waiting for the one worker, oldest first.
local queue = {}
local draining = false

--- A value shaped like a citizen id that fits the column, or nil.
local function citizenOf(value)
	if type(value) ~= 'string' or #value < 1 or #value > 16 or not value:match('^[%w%-]+$') then
		return nil
	end
	return value
end
Storage.CitizenOf = citizenOf

local function warn(what, result)
	Open77.log.warn(('[underworld] cannot %s: %s'):format(what,
		tostring(type(result) == 'table' and (result.detail or result.error) or result)))
end

--- Whether the tables can be used: the schema was applied at boot.
-- @author dop42
-- @return boolean
function Storage.Ready()
	return OPX.BootError == nil
end

local function drain()
	if draining then return end
	draining = true
	CreateThread(function()
		while #queue > 0 do
			local job = table.remove(queue, 1)
			local written = OPX.Storage.Execute(job.sql, job.params)
			if not written.ok then warn(job.verb, written) end
		end
		draining = false
	end)
end

local function enqueue(verb, sql, params)
	if not Storage.Ready() then return end
	queue[#queue + 1] = { verb = verb, sql = sql, params = params }
	drain()
end

--- Queues one ledger line: dirty eddies made (+) or destroyed (-), or an
--- escrow movement (amount 0 with the op in `source`).
-- @author dop42
-- @param citizenId string
-- @param source string what made or destroyed it, e.g. `robbery:kabuki_247`
-- @param amount integer
-- @param at table|nil { x, y, z }
function Storage.Ledger(citizenId, source, amount, at)
	local citizen = citizenOf(citizenId)
	if citizen == nil then return end
	at = type(at) == 'table' and at or {}
	enqueue('write a ledger line', INSERT_LEDGER, {
		citizen = citizen, source = OPX.Text.Bytes(tostring(source), 48),
		amount = math.tointeger(math.floor(tonumber(amount) or 0)) or 0,
		x = OPX.Math.Finite(at.x), y = OPX.Math.Finite(at.y), z = OPX.Math.Finite(at.z),
	})
end

--- A character's last ledger lines and the running sum. Yields.
-- @author dop42
-- @param citizenId string
-- @return table|nil rows
-- @return integer sum
function Storage.LedgerOf(citizenId)
	local citizen = citizenOf(citizenId)
	if citizen == nil or not Storage.Ready() then return nil, 0 end
	local rows = OPX.Storage.Query(SELECT_LEDGER, { citizen = citizen })
	if not rows.ok then
		warn('read the ledger', rows)
		return nil, 0
	end
	local sum = OPX.Storage.Scalar(SUM_LEDGER, { citizen = citizen })
	return type(rows.value) == 'table' and rows.value or {}, sum.ok and (tonumber(sum.value) or 0) or 0
end

--- Queues an escrow row: what an op took out of a bag, to be handed back if
--- the server dies before the op ends.
-- @author dop42
-- @param opId string
-- @param citizenId string
-- @param payload table { items = { { name, count } }, money = { { type, amount } } }
function Storage.EscrowOpen(opId, citizenId, payload)
	local citizen = citizenOf(citizenId)
	if citizen == nil then return end
	enqueue('open an escrow', INSERT_ESCROW, { op = opId, citizen = citizen,
		payload = json.encode(payload) })
end

--- Queues the end of an escrow row, however the op ended.
-- @author dop42
-- @param opId string
function Storage.EscrowClose(opId)
	enqueue('close an escrow', DELETE_ESCROW, { op = opId })
end

--- Every escrow row a previous run left open. Yields.
-- @author dop42
-- @return table[] { opId, citizenId, payload }
function Storage.EscrowLeft()
	if not Storage.Ready() then return {} end
	local rows = OPX.Storage.Query(SELECT_ESCROW, {})
	if not rows.ok then
		warn('read the escrow', rows)
		return {}
	end
	local out = {}
	for _, row in ipairs(type(rows.value) == 'table' and rows.value or {}) do
		if type(row) == 'table' and type(row.op_id) == 'string' and citizenOf(row.citizen_id) then
			out[#out + 1] = { opId = row.op_id, citizenId = row.citizen_id,
				payload = OPX.Storage.Decode(row.payload, nil) }
		end
	end
	return out
end

--- Every till's stored charges, and how many seconds ago they were true. Yields.
-- @author dop42
-- @return table<string, { charges, age }>
function Storage.Registers()
	if not Storage.Ready() then return {} end
	local rows = OPX.Storage.Query(SELECT_REGISTERS, {})
	if not rows.ok then
		warn('read the tills', rows)
		return {}
	end
	local out = {}
	for _, row in ipairs(type(rows.value) == 'table' and rows.value or {}) do
		if type(row) == 'table' and type(row.store_id) == 'string' then
			out[row.store_id] = { charges = tonumber(row.charges), age = math.max(0, tonumber(row.age) or 0) }
		end
	end
	return out
end

--- Queues a till's charges.
-- @author dop42
-- @param storeId string
-- @param charges integer
-- @param age integer seconds since the next charge started counting
function Storage.SaveRegister(storeId, charges, age)
	enqueue('write a till', UPSERT_REGISTER, { store = storeId, charges = charges,
		age = math.max(0, math.tointeger(math.floor(age)) or 0) })
end

--- What a character has deposited at every front today (UTC). Yields.
-- @author dop42
-- @param citizenId string
-- @return integer|nil nil when it could not be read
function Storage.DepositedToday(citizenId)
	local citizen = citizenOf(citizenId)
	if citizen == nil or not Storage.Ready() then return nil end
	local read = OPX.Storage.Scalar(SUM_DEPOSITED, { citizen = citizen })
	if not read.ok then
		warn('read the deposits', read)
		return nil
	end
	return math.floor(tonumber(read.value) or 0)
end

--- Files a batch. Yields. Answers whether it was written.
-- @author dop42
-- @return boolean
function Storage.InsertBatch(citizenId, frontId, dirty, clean, payout, seconds)
	local citizen = citizenOf(citizenId)
	if citizen == nil or not Storage.Ready() then return false end
	local written = OPX.Storage.Insert(INSERT_BATCH, { citizen = citizen, front = frontId, dirty = dirty,
		clean = clean, payout = payout, seconds = math.max(0, math.floor(seconds)) })
	if not written.ok then warn('file a batch', written) end
	return written.ok == true
end

--- A character's uncollected batches at one front. Yields.
-- @author dop42
-- @return table[]|nil { id, dirty, clean, payout, remaining } (seconds, <= 0 is ready)
function Storage.Batches(citizenId, frontId)
	local citizen = citizenOf(citizenId)
	if citizen == nil or not Storage.Ready() then return nil end
	local rows = OPX.Storage.Query(SELECT_BATCHES, { citizen = citizen, front = frontId })
	if not rows.ok then
		warn('read the batches', rows)
		return nil
	end
	local out = {}
	for _, row in ipairs(type(rows.value) == 'table' and rows.value or {}) do
		if type(row) == 'table' and tonumber(row.id) ~= nil then
			out[#out + 1] = { id = tonumber(row.id), dirty = math.floor(tonumber(row.dirty) or 0),
				clean = math.floor(tonumber(row.clean) or 0), payout = tostring(row.payout),
				remaining = math.floor(tonumber(row.remaining) or 0) }
		end
	end
	return out
end

--- Marks one batch collected, once: answers true only for the call that did.
--- Yields.
-- @author dop42
-- @return boolean
function Storage.Collect(id, citizenId)
	local citizen = citizenOf(citizenId)
	if citizen == nil or not Storage.Ready() then return false end
	local written = OPX.Storage.Update(COLLECT_BATCH, { id = id, citizen = citizen })
	if not written.ok then
		warn('collect a batch', written)
		return false
	end
	local affected = written.value
	if type(affected) == 'table' then affected = affected.affectedRows end
	return (tonumber(affected) or 0) == 1
end

--- Undoes a collect whose payout was refused. Queued.
-- @author dop42
function Storage.Uncollect(id)
	enqueue('undo a collect', UNCOLLECT_BATCH, { id = id })
end
