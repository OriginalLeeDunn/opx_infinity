--- Every SQL statement this module runs, and the one table it owns.
-- @author dop42
--
-- The only file in the module allowed to carry SQL, which a CI check enforces.
-- Nothing here decides anything: `server/main.lua` decides.
--
-- OX'S TABLE, ONE ROW PER DOOR: an integer id, the name, and the door itself as
-- one JSON column (`sql/ox_doorlock.sql`). A door is a nested thing -- groups,
-- items, characters, one or two leaves -- read and written whole by the panel,
-- and never queried by anything but its id. Three columns are ours:
--
--   origin      'config:<key>' for a door seeded from `config/doorlock.lua`,
--               'legacy:<key>' for one carried over from the first version's
--               table, NULL for a door staff made. UNIQUE, so a seed or a
--               migration is an INSERT IGNORE that can run on every boot and
--               lands once -- ox's `WHERE NOT EXISTS (... name = ?)`, keyed on
--               something a rename cannot break.
--   removed     a tombstone for a deleted seeded door, so the next boot does
--               not insert it again. A door staff made is deleted outright.
--   updated_by  who saved it last, for the row.
--
-- Statements bind named parameters (`@id`), never `?`, and no comment may sit
-- inside a SQL string: the bridge rewrites by walking the text.

local M = OPX.Modules.Get('doorlock')

local Storage = OPX.Storage

M.Storage = {}

--- The first version's table, read once per boot for the migration, never written.
M.Storage.LEGACY = 'opx77_doorlock'

--- One CREATE TABLE IF NOT EXISTS per table this module owns.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_doorlocks (
    id INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(64) NOT NULL,
    data MEDIUMTEXT NOT NULL,
    origin VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NULL,
    removed TINYINT(1) NOT NULL DEFAULT 0,
    updated_by VARCHAR(64) NOT NULL DEFAULT '',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    UNIQUE KEY opx77_doorlocks_origin (origin)
) ENGINE=InnoDB
]],
}

--- Every live door, by id.
-- @author dop42
-- @return Result carrying an array of rows { id, name, data, origin }
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT id, name, data, origin
  FROM opx77_doorlocks
 WHERE removed = 0
 ORDER BY id
  ]])
end

--- Inserts a door staff made, answering its new id.
-- @author dop42
-- @param name string
-- @param data table ox's stored shape, passcode included
-- @param by string who made it
-- @return Result carrying the insert id
function M.Storage.Insert(name, data, by)
	return Storage.Insert([[
INSERT INTO opx77_doorlocks (name, data, updated_by)
VALUES (@name, @data, @by)
  ]], { name = name, data = json.encode(data), by = by or '' })
end

--- Inserts a seeded or migrated door once: a row already filed under this
--- origin -- live or tombstoned -- is left alone, and the answer is then 0.
-- @author dop42
-- @param origin string 'config:<key>' or 'legacy:<key>'
-- @param name string
-- @param data table
-- @return Result carrying the insert id, 0 when it was already there
function M.Storage.Seed(origin, name, data)
	return Storage.Insert([[
INSERT IGNORE INTO opx77_doorlocks (name, data, origin, updated_by)
VALUES (@name, @data, @origin, @by)
  ]], { name = name, data = json.encode(data), origin = origin, by = 'seed' })
end

--- Rewrites one door.
-- @author dop42
-- @param id integer
-- @param name string
-- @param data table
-- @param by string
-- @return Result
function M.Storage.Update(id, name, data, by)
	return Storage.Execute([[
UPDATE opx77_doorlocks SET name = @name, data = @data, updated_by = @by
 WHERE id = @id
  ]], { id = id, name = name, data = json.encode(data), by = by or '' })
end

--- Deletes a door staff made; tombstones a seeded or migrated one.
-- @author dop42
-- @param id integer
-- @param seeded boolean whether the row carries an origin
-- @param by string
-- @return Result
function M.Storage.Delete(id, seeded, by)
	if seeded then
		return Storage.Execute('UPDATE opx77_doorlocks SET removed = 1, updated_by = @by WHERE id = @id',
			{ id = id, by = by or '' })
	end
	return Storage.Execute('DELETE FROM opx77_doorlocks WHERE id = @id', { id = id })
end

--- Whether the first version's table exists on this database.
-- Asked rather than selected from: a SELECT on a missing table is an error the
-- bridge logs, on every boot of every server that never ran that version.
-- @author dop42
-- @return Result carrying a count
function M.Storage.HasLegacy()
	return Storage.Scalar([[
SELECT COUNT(*)
  FROM information_schema.tables
 WHERE table_schema = DATABASE() AND table_name = 'opx77_doorlock'
  ]])
end

--- Every row of the first version's table.
-- @author dop42
-- @return Result carrying rows { door_key, name, bucket, data }
function M.Storage.FetchLegacy()
	return Storage.Query([[
SELECT door_key, name, bucket, data
  FROM opx77_doorlock
 ORDER BY created_at
  ]])
end
