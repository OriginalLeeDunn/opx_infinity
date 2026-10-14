--- Every SQL statement this module runs, and the one table it owns.
-- @author dop42
--
-- This is the only file in the module allowed to carry SQL, and a CI check
-- enforces it. Nothing here decides anything: `server/main.lua` decides.
--
-- Statements bind named parameters (`@plate`), never `?`: the bridge rewrites
-- `?` by walking the query text. No comment may appear inside a SQL string for
-- the same reason. Every statement yields and answers a `Result`, so every one
-- of them has to be reached from a `CreateThread`.

local M = OPX.Modules.Get('vehicles')

local Result = OPX.Result
local Storage = OPX.Storage

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS per table this module owns.
-- The foreign key means the character table has to exist first, which is what
-- the `character` requirement and the manifest order guarantee.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_vehicles (
    plate VARCHAR(12) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    record VARCHAR(256) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    appearance VARCHAR(128) CHARACTER SET ascii COLLATE ascii_bin NULL DEFAULT NULL,
    garage VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL DEFAULT 'impound',
    state TINYINT UNSIGNED NOT NULL DEFAULT 1,
    health FLOAT NOT NULL DEFAULT 1,
    body JSON NULL DEFAULT NULL,
    paint JSON NULL DEFAULT NULL,
    metadata JSON NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_opx77_vehicles_owner (citizen_id, state),
    CONSTRAINT fk_opx77_vehicle_character
        FOREIGN KEY (citizen_id) REFERENCES opx77_characters (citizen_id)
        ON DELETE CASCADE
) ENGINE=InnoDB
]],
}

--- Columns added after the table first shipped. `CREATE TABLE IF NOT EXISTS`
--- reaches a fresh install and nothing else, so a column a server's existing
--- table lacks is added by `OPX.Schema.AddColumns` at boot.
--
-- `fuel` IS THE TANK, IN LITRES, as the vehicle's `fuel` state-bag field holds
-- it -- the platform's field (`open77_fuel`) and `modules/fuel`'s. NULL is a car
-- nobody has measured yet: one from before the column, or a fresh purchase, and
-- it comes out with whatever tank a fresh car gets. Kept here, beside health and
-- damage, because it is a fact about the car the garage puts away and gives
-- back, and the module that writes this row is the one that knows when.
M.Storage.COLUMNS = {
	{ TABLE = 'opx77_vehicles', COLUMN = 'fuel', DEFINITION = 'FLOAT NULL DEFAULT NULL' },
}

--- Where a vehicle is, as stored in the state column.
-- A number and not a string, because the column is a TINYINT: a game mode adds
-- its own states without touching the table.
M.Storage.STATE = { OUT = 0, STORED = 1, IMPOUNDED = 2 }

local STATE = M.Storage.STATE

--- Turns a vehicle row into the entity `server/main.lua` uses.
-- @author dop42
-- @param row table
-- @return table
function M.Storage.ToEntity(row)
	local state = tonumber(row.state)
	local health = tonumber(row.health)
	local fuel = tonumber(row.fuel)
	return {
		plate = row.plate,
		citizenId = row.citizen_id,
		record = row.record,
		appearance = row.appearance,
		garage = row.garage,
		state = OPX.Math.IsFinite(state) and state or STATE.STORED,
		health = OPX.Math.IsFinite(health) and health or 1.0,
		damage = Storage.Decode(row.body, nil),
		paint = Storage.Decode(row.paint, nil),
		metadata = Storage.Decode(row.metadata, {}),
		-- Nil, not 0, for a car never measured: an empty tank is a real reading.
		fuel = OPX.Math.IsFinite(fuel) and fuel >= 0 and fuel or nil,
	}
end

local toEntity = M.Storage.ToEntity

--- Lists every vehicle a character owns, oldest first.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.Storage.FetchByOwner(citizenId)
	local rows = Storage.Query([[
SELECT plate, citizen_id, record, appearance, garage, state, health, body, paint, metadata, fuel
  FROM opx77_vehicles
 WHERE citizen_id = @citizen
 ORDER BY created_at
  ]], { citizen = citizenId })
	if not rows.ok then return rows end

	local fetched = rows.value
	local list = {}
	for index = 1, type(fetched) == 'table' and #fetched or 0 do
		list[index] = toEntity(fetched[index])
	end
	return Result.Ok(list)
end

--- Reads one vehicle by its plate.
-- @author dop42
-- @param plate string
-- @return Result
function M.Storage.FetchOne(plate)
	local row = Storage.Single([[
SELECT plate, citizen_id, record, appearance, garage, state, health, body, paint, metadata, fuel
  FROM opx77_vehicles
 WHERE plate = @plate
 LIMIT 1
  ]], { plate = plate })
	if not row.ok then return row end
	if not row.value then return Result.Err('vehicle.notFound', plate) end
	return Result.Ok(toEntity(row.value))
end

--- Inserts a vehicle row, the plate key deciding a collision.
-- Never a SELECT first: two draws in the same tick would both pass it, and the
-- primary key is the only thing that can settle a plate.
-- @author dop42
-- @param entity table
-- @return Result
function M.Storage.Insert(entity)
	return Storage.Execute([[
INSERT INTO opx77_vehicles (plate, citizen_id, record, appearance, garage, state, health,
                            body, paint, metadata)
VALUES (@plate, @citizen, @record, NULLIF(@appearance, ''), @garage, @state, @health,
        NULLIF(@body, ''), NULLIF(@paint, ''), @metadata)
  ]], {
		plate = entity.plate,
		citizen = entity.citizenId,
		record = entity.record,
		-- An appearance is a name and not JSON, so it cannot go through
		-- `OPX.Storage.Nullable`; absence still travels as '' for NULLIF.
		appearance = entity.appearance ~= nil and tostring(entity.appearance) or '',
		garage = entity.garage,
		state = entity.state,
		health = entity.health,
		body = Storage.Nullable(entity.damage),
		paint = Storage.Nullable(entity.paint),
		metadata = json.encode(entity.metadata or {}),
	})
end

--- The `fuel` parameter: the litres, or -1 for "not read", which the statements
--- below turn into "keep what the row has" -- a nil would bind as NULL and
--- forget a tank that was simply not asked about this time.
local function fuelParam(fuel)
	if type(fuel) == 'number' and fuel == fuel and fuel >= 0 and fuel < 1000000 then return fuel end
	return -1
end

--- Writes back a vehicle's condition, paint, state, garage and tank.
-- Neither `plate` nor `citizen_id` appears in the SET list: an UPDATE able to
-- move a vehicle to another character is how vehicles get stolen.
-- @author dop42
-- @param entity table
-- @return Result
function M.Storage.Save(entity)
	return Storage.Execute([[
UPDATE opx77_vehicles
   SET garage = @garage, state = @state, health = @health, body = NULLIF(@body, ''),
       paint = NULLIF(@paint, ''), metadata = @metadata,
       fuel = IF(@fuel < 0, fuel, @fuel)
 WHERE plate = @plate
  ]], {
		plate = entity.plate,
		garage = entity.garage,
		state = entity.state,
		health = entity.health,
		body = Storage.Nullable(entity.damage),
		paint = Storage.Nullable(entity.paint),
		metadata = json.encode(entity.metadata or {}),
		fuel = fuelParam(entity.fuel),
	})
end

--- Writes only a vehicle's state, and its garage when one is given.
-- One column, so that a change of state cannot write back a stale copy of
-- everything else.
-- @author dop42
-- @param plate string
-- @param state integer
-- @param garage string|nil
-- @return Result
function M.Storage.SetState(plate, state, garage)
	if garage == nil then
		return Storage.Execute(
			'UPDATE opx77_vehicles SET state = @state WHERE plate = @plate',
			{ plate = plate, state = state })
	end
	return Storage.Execute(
		'UPDATE opx77_vehicles SET state = @state, garage = @garage WHERE plate = @plate',
		{ plate = plate, state = state, garage = garage })
end

--- Writes back the condition of a vehicle and files it as stored, SENT NOW and
--- answered later. The resource-stop path, and the one statement here that does
--- not await.
-- @author dop42
--
-- A stop handler is not a coroutine: every `.await` in this file fails there,
-- and a `CreateThread` is not promised another resume once the resource is
-- going. The bridge's CALLBACK form sends the statement before it returns and
-- needs neither, so the write leaves while the engine can still be asked what
-- the car looked like. No read first -- that would be an await -- so `flags`,
-- which lives inside the metadata blob, is set in place with `JSON_SET`.
-- @param entity table { plate, state, health, damage, flags, fuel }
-- @param onDone function|nil (ok, reason), when the database answers
-- @return boolean sent
-- @return string|nil why not
function M.Storage.SaveConditionNow(entity, onDone)
	local api = MySQL
	local update = api and api.update
	if update == nil then return false, 'no-database' end
	local params = {
		plate = entity.plate,
		state = entity.state,
		health = entity.health,
		body = Storage.Nullable(entity.damage),
		fuel = fuelParam(entity.fuel),
	}
	local sql = [[
UPDATE opx77_vehicles
   SET state = @state, health = @health, body = NULLIF(@body, ''),
       fuel = IF(@fuel < 0, fuel, @fuel)
 WHERE plate = @plate
  ]]
	if entity.flags ~= nil then
		params.flags = entity.flags
		sql = [[
UPDATE opx77_vehicles
   SET state = @state, health = @health, body = NULLIF(@body, ''),
       fuel = IF(@fuel < 0, fuel, @fuel),
       metadata = JSON_SET(metadata, '$.flags', @flags)
 WHERE plate = @plate
  ]]
	end
	local called, sent, why = pcall(update, sql, params, function(affected, reason)
		if onDone ~= nil then onDone(reason == nil, reason) end
	end)
	if not called then return false, tostring(sent) end
	if sent == false then return false, tostring(why) end
	return true
end

--- Deletes a vehicle row by its plate.
-- @author dop42
-- @param plate string
-- @return Result
function M.Storage.Delete(plate)
	return Storage.Execute('DELETE FROM opx77_vehicles WHERE plate = @plate', { plate = plate })
end

--- Removes every vehicle a deleted character owned.
-- @author dop42
--
-- THE FOREIGN KEY DOES NOT DO THIS, although `citizen_id` above really does
-- carry `ON DELETE CASCADE`: a character delete is a SOFT delete -- `deleted_at`
-- is stamped and the row stays -- and no cascade fires for an UPDATE. Left to
-- the cascade, a deleted character's cars stayed in the table for ever, owned by
-- a citizen id nothing could ever log in as.
--
-- ALL OF THEM, wherever they are. A vehicle that was out in the world when its
-- owner was deleted is still that owner's row; the state column is not consulted
-- because there is no owner left for any state of it to belong to.
-- @param citizenId CitizenId
-- @return Result
function M.Storage.PurgeCharacter(citizenId)
	return Storage.Execute('DELETE FROM opx77_vehicles WHERE citizen_id = @citizen',
		{ citizen = citizenId })
end

--- Counts the vehicles one character owns, for the ceiling.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.Storage.CountByOwner(citizenId)
	local row = Storage.Single(
		'SELECT COUNT(*) AS total FROM opx77_vehicles WHERE citizen_id = @citizen',
		{ citizen = citizenId })
	if not row.ok then return row end
	return Result.Ok(tonumber(row.value and row.value.total) or 0)
end
