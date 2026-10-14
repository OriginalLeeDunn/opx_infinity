--- Every SQL statement crafting runs, and the one table it owns.
-- @author dop42
--
-- This is the only file in the module allowed to carry SQL, and a CI check
-- enforces it. Statements bind named parameters (`@citizen`), never `?`: the
-- bridge rewrites `?` by walking the query text. No comment may appear inside a
-- SQL string for the same reason. Every call yields, so every one of them has to
-- be reached from a `CreateThread`.
--
-- THE DATABASE OWNS THE CLOCK, AND THAT IS THE DESIGN AND NOT A CONVENIENCE.
-- An order's deadline has to be right while this resource is not running --
-- a craft started before a restart finishes during it -- so it cannot be
-- measured against `OPX.Now`, which is milliseconds since THIS process started
-- and resets to zero with it. It must not be measured against two clocks either:
-- the collection below is made exactly-once by a DELETE whose WHERE clause tests
-- the deadline, so if Lua decided readiness and the database did not, two
-- collections racing would both pass the Lua test and one of them would hand out
-- an order the other had already handed out.
--
-- So every wall-clock word in this file is MySQL's. Lua is handed and hands back
-- nothing but RELATIVE SECONDS -- how long until this is ready, how long to hold
-- this one for -- which is arithmetic `shared/recipes.lua` does in the open and
-- `tests/run.lua` checks without a database at all.
--
-- `ready_at` IS A `DATETIME` AND NOT A `TIMESTAMP`, which is the one column type
-- decision here that can go quietly wrong. A TIMESTAMP is stored as UTC and
-- CONVERTED to the session time zone on the way in and out, while `UTC_TIMESTAMP()`
-- is UTC whatever the session says -- so writing one into the other on a server
-- whose connection is not UTC shifts every deadline by the offset, and the craft
-- is ready an hour early or an hour late with nothing anywhere saying why. A
-- DATETIME stores the value it is given. The 2038 ceiling a TIMESTAMP carries is
-- the second reason and the smaller one.

local M = OPX.Modules.Get('crafting')

local Result = OPX.Result
local Storage = OPX.Storage

M.Storage = {}

--- The one table this module owns. `Init` hands it to `OPX.Schema.Add`.
--
-- The foreign key is on `citizen_id` and it declares `CHARACTER SET ascii
-- COLLATE ascii_bin` explicitly. It is not decoration: a referencing column
-- whose character set and collation do not match the referenced one is refused
-- by InnoDB with SQL error 1005, `ApplySchema` stops at the first failure, and
-- the whole boot comes up degraded over a default charset nobody typed.
--
-- ON DELETE CASCADE, because an order belongs to a character: a deleted
-- character's unfinished crafts are not somebody else's to collect, and the
-- citizen id is reissued to nobody.
-- `token` on a table that predates it, and the key it is found by.
M.Storage.COLUMNS = {
	{ TABLE = 'opx77_crafting_orders', COLUMN = 'token',
		DEFINITION = 'VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL' },
}
M.Storage.INDEXES = {
	{ TABLE = 'opx77_crafting_orders', NAME = 'idx_opx77_crafting_token', COLUMNS = { 'token' } },
}

M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_crafting_orders (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    bench VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    recipe VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    ready_at DATETIME NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    token VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    KEY idx_opx77_crafting_shelf (citizen_id, bench, ready_at, id),
    KEY idx_opx77_crafting_token (token),
    CONSTRAINT fk_opx77_crafting_character
        FOREIGN KEY (citizen_id) REFERENCES opx77_characters (citizen_id)
        ON DELETE CASCADE
) ENGINE=InnoDB
]],
}

--- How many orders a character has at one bench, and how long until the last is done.
--
-- ONE ROUND TRIP FOR BOTH, because the two are always wanted together: the count
-- decides whether the queue has room and the tail decides when a new order would
-- start. `MAX` over an empty set is NULL, which `COALESCE` reads as "the bench is
-- free now"; a tail in the past comes back negative and `Recipes.StartOffset`
-- is what floors it, in the open, where a test can see it.
-- @author dop42
-- @param citizenId CitizenId
-- @param bench string
-- @return Result { cooking, tail }
function M.Storage.Shelf(citizenId, bench)
	local read = Storage.Single([[
SELECT COUNT(*) AS cooking,
       COALESCE(MAX(TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), ready_at)), 0) AS tail
  FROM opx77_crafting_orders
 WHERE citizen_id = @citizen AND bench = @bench
]], { ['@citizen'] = citizenId, ['@bench'] = bench })
	if not read.ok then return read end

	local row = type(read.value) == 'table' and read.value or {}
	return Result.Ok({
		cooking = math.floor(tonumber(row.cooking) or 0),
		tail = math.floor(tonumber(row.tail) or 0),
	})
end

--- Every order a character has at one bench, soonest first.
--
-- `remaining` is SECONDS FROM NOW and may be negative, which is what "finished
-- and waiting to be collected" looks like. The ORDER BY is what makes the LIMIT
-- take the soonest rather than an arbitrary handful; `Recipes.Order` sorts them
-- again on the way to the screen, because a caller must not depend on a detail
-- of one statement.
-- @author dop42
-- @param citizenId CitizenId
-- @param bench string
-- @param limit integer
-- @return Result table[] { id, recipe, remaining }
function M.Storage.Orders(citizenId, bench, limit)
	local read = Storage.Query([[
SELECT id, recipe, TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), ready_at) AS remaining
  FROM opx77_crafting_orders
 WHERE citizen_id = @citizen AND bench = @bench
 ORDER BY ready_at ASC, id ASC
 LIMIT @limit
]], { ['@citizen'] = citizenId, ['@bench'] = bench, ['@limit'] = limit })
	if not read.ok then return read end

	local rows = type(read.value) == 'table' and read.value or {}
	local out = {}
	for index = 1, #rows do
		local row = rows[index]
		out[index] = {
			id = math.floor(tonumber(row.id) or 0),
			recipe = tostring(row.recipe),
			remaining = math.floor(tonumber(row.remaining) or 0),
		}
	end
	return Result.Ok(out)
end

--- Files a new order, ready `seconds` from now -- IF the shelf has room.
--
-- THE CAP IS IN THE STATEMENT. It used to be read by `Shelf` and filed here,
-- two round trips apart, so two orders placed in the same breath both read the
-- same count and both landed: a queue of three held four. The count and the
-- insert are one statement now, `INSERT ... SELECT ... WHERE count < queue`;
-- InnoDB reads the shelf rows under shared locks for an INSERT ... SELECT, so
-- two racing inserts cannot both go through on the same count -- one waits or
-- is rolled back as a deadlock, which `Storage` answers as a failure and the
-- caller compensates like any other.
-- @author dop42
-- @param citizenId CitizenId
-- @param bench string
-- @param recipe string
-- @param seconds integer
-- @param queue integer how many orders this bench may hold for one character
-- @param token string|nil this placement's own name, for `Placed`
-- @return Result integer|nil the order id, or nil when the shelf was full
function M.Storage.Place(citizenId, bench, recipe, seconds, queue, token)
	local inserted = Storage.Insert([[
INSERT INTO opx77_crafting_orders (citizen_id, bench, recipe, ready_at, token)
SELECT @citizen, @bench, @recipe, DATE_ADD(UTC_TIMESTAMP(), INTERVAL @seconds SECOND), @token
  FROM DUAL
 WHERE (SELECT COUNT(*) FROM opx77_crafting_orders
         WHERE citizen_id = @citizen AND bench = @bench) < @queue
]], { ['@citizen'] = citizenId, ['@bench'] = bench, ['@recipe'] = recipe,
		['@seconds'] = seconds, ['@queue'] = queue, ['@token'] = token })
	if not inserted.ok then return inserted end
	-- No row means no id: the bridge answers 0 (or nothing) for an insert that
	-- the WHERE turned away.
	local id = inserted.value
	if type(id) == 'table' then id = id.insertId end
	id = math.tointeger(tonumber(id))
	if id == nil or id <= 0 then return Result.Ok(nil) end
	return Result.Ok(id)
end

--- Whether a placement went in, read by its token. The question asked when
--- `Place` failed: an answer lost AFTER the insert committed looks exactly like
--- an insert that never ran, and refunding the first is an order AND its price.
-- @author dop42
-- @param citizenId CitizenId
-- @param token string
-- @return Result integer|nil the order id, or nil when there is no such order
function M.Storage.Placed(citizenId, token)
	local read = Storage.Single([[
SELECT id FROM opx77_crafting_orders WHERE citizen_id = @citizen AND token = @token
]], { ['@citizen'] = citizenId, ['@token'] = token })
	if not read.ok then return read end
	if type(read.value) ~= 'table' then return Result.Ok(nil) end
	return Result.Ok(math.tointeger(tonumber(read.value.id)))
end

--- Reads one order a character owns, without claiming it.
-- @author dop42
-- @param citizenId CitizenId
-- @param orderId integer
-- @return Result table|nil { id, bench, recipe, remaining }
function M.Storage.Find(citizenId, orderId)
	local read = Storage.Single([[
SELECT id, bench, recipe, TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), ready_at) AS remaining
  FROM opx77_crafting_orders
 WHERE id = @order AND citizen_id = @citizen
]], { ['@order'] = orderId, ['@citizen'] = citizenId })
	if not read.ok then return read end
	if type(read.value) ~= 'table' then return Result.Ok(nil) end

	local row = read.value
	return Result.Ok({
		id = math.floor(tonumber(row.id) or 0),
		bench = tostring(row.bench),
		recipe = tostring(row.recipe),
		remaining = math.floor(tonumber(row.remaining) or 0),
	})
end

--- Takes one finished order off the shelf, once.
--
-- THE DELETE IS THE CLAIM, and everything about handing the output over hangs
-- off its answer. Two collections of the same order can be in flight at the same
-- time -- a player mashing the row, the screen refreshing, a second connection
-- of the same character -- and both will have read the same row a moment
-- earlier and both will have found it ready. Exactly one of their DELETEs
-- affects a row, and that one is the collection; the other is answered
-- `no_such_order`, which is true by the time it is said.
--
-- `ready_at <= UTC_TIMESTAMP()` is in the WHERE clause and not in Lua for the
-- same reason: the row and the clock have to be tested together, by the thing
-- holding the lock on the row.
-- @author dop42
-- @param citizenId CitizenId
-- @param orderId integer
-- @return Result boolean whether this caller is the one that took it
function M.Storage.Claim(citizenId, orderId)
	local deleted = Storage.Update([[
DELETE FROM opx77_crafting_orders
 WHERE id = @order AND citizen_id = @citizen AND ready_at <= UTC_TIMESTAMP()
]], { ['@order'] = orderId, ['@citizen'] = citizenId })
	if not deleted.ok then return deleted end
	return Result.Ok((tonumber(deleted.value) or 0) > 0)
end

--- Puts a claimed order back on the shelf, already finished.
--
-- THE COMPENSATION FOR A DELIVERY THAT FAILED AFTER THE CLAIM. The claim and the
-- handover are not one transaction and cannot be -- the bag is another module's
-- and is not in this database's reach -- so the order is claimed, the output is
-- handed over, and an output that would not go into the bag is put back here
-- rather than lost. Compensation, not atomicity, and the honest name for the gap
-- is the width of one `AddItem` call.
--
-- It is written ready, not re-timed: the waiting is done and making the player
-- wait again for a failure that was theirs to fix would be a second punishment.
-- @author dop42
-- @param citizenId CitizenId
-- @param bench string
-- @param recipe string
-- @return Result integer the new order id
function M.Storage.Reshelve(citizenId, bench, recipe)
	return Storage.Insert([[
INSERT INTO opx77_crafting_orders (citizen_id, bench, recipe, ready_at)
VALUES (@citizen, @bench, @recipe, UTC_TIMESTAMP())
]], { ['@citizen'] = citizenId, ['@bench'] = bench, ['@recipe'] = recipe })
end
