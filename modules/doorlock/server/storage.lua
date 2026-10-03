--- Every SQL statement this module runs, and the one table it owns.
-- @author dop42
--
-- The only file in the module allowed to carry SQL, which a CI check enforces.
-- Nothing here decides anything: `server/main.lua` decides.
--
-- ONE ROW PER DOOR, AND THE DOOR IS ONE JSON COLUMN. ox_doorlock stores its
-- doors the same way, and for the same reason: a door is a nested thing -- a
-- list of groups, a list of items, one or two native ids -- and every field of
-- it is read and written whole by the panel. Columns for it would be a join
-- table per list and a migration per field, for a row that is never queried by
-- anything but its key. The two fields that ARE queried by something else stay
-- columns: `bucket`, and `updated_by`, which names the staff member.
--
-- Statements bind named parameters (`@key`), never `?`, and no comment may sit
-- inside a SQL string: the bridge rewrites by walking the text.

local M = OPX.Modules.Get('doorlock')

local Storage = OPX.Storage

M.Storage = {}

--- One CREATE TABLE IF NOT EXISTS per table this module owns.
M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_doorlock (
    door_key VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    name VARCHAR(64) NOT NULL,
    bucket INT UNSIGNED NOT NULL DEFAULT 0,
    data MEDIUMTEXT NOT NULL,
    updated_by VARCHAR(64) NOT NULL DEFAULT '',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],
}

--- Every saved door, oldest first.
-- @author dop42
-- @return Result carrying an array of rows { door_key, name, bucket, data }
function M.Storage.FetchAll()
	return Storage.Query([[
SELECT door_key, name, bucket, data
  FROM opx77_doorlock
 ORDER BY created_at
  ]])
end

--- Inserts a door, or replaces the one already filed under its key.
-- One statement: two saves in the same tick would both pass a select, and the
-- primary key is the only thing that can settle a key.
-- @author dop42
-- @param key string
-- @param name string
-- @param bucket integer
-- @param data table the door in its plain shape, passcode included
-- @param by string who saved it, for the row
-- @return Result
function M.Storage.Upsert(key, name, bucket, data, by)
	return Storage.Execute([[
INSERT INTO opx77_doorlock (door_key, name, bucket, data, updated_by)
VALUES (@key, @name, @bucket, @data, @by)
ON DUPLICATE KEY UPDATE name = @name, bucket = @bucket, data = @data, updated_by = @by
  ]], {
		key = key,
		name = name,
		bucket = bucket,
		data = json.encode(data),
		by = by or '',
	})
end

--- Deletes a door by its key.
-- @author dop42
-- @param key string
-- @return Result
function M.Storage.Delete(key)
	return Storage.Execute('DELETE FROM opx77_doorlock WHERE door_key = @key', { key = key })
end
