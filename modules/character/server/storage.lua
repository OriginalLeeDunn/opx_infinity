--- Every SQL statement this module runs, and the tables it owns.
-- @author dop42
--
-- This is the only file in the module allowed to carry SQL, and a CI check
-- enforces it. Nothing here decides anything: ownership and deletion are checked
-- by the caller. Every statement yields and answers a `Result`, so every one of
-- them has to be reached from a `CreateThread`.
--
-- Statements bind named parameters (`@citizen`), never `?`: the bridge rewrites
-- `?` by walking the query text. No comment may appear inside a SQL string for
-- the same reason.

local M = OPX.Modules.Get('character')

local Result = OPX.Result
local Storage = OPX.Storage

M.Storage = {}

-- Decodes a JSON column, answering the fallback when it will not decode.
local decode = Storage.Decode

-- Binds a nullable JSON column: the bridge drops a nil parameter instead of
-- binding NULL, so absence travels as '' and the statement turns it back with
-- NULLIF(@x, ''). Encoded JSON is never the empty string.
local nullable = Storage.Nullable

--- Encodes a JSON column, an absent value as an empty object.
local function encode(value)
	return json.encode(value or {})
end

--- One CREATE TABLE IF NOT EXISTS per table this module owns, in foreign-key
--- order. `Init` hands the list to `OPX.Schema.Add`.
-- There are no migrations, and that is deliberate while the project is in
-- development: a table that exists is never touched by IF NOT EXISTS, so a
-- changed table is dropped and recreated rather than migrated.
--
-- WHICH IS WHY `idx_opx77_characters_seen` IS ALSO IN `INDEXES` BELOW. The
-- staff find screen reads the whole table by last-played, and that index is what
-- makes the read a backward range scan over 26 entries instead of a filesort
-- over every living character. In the CREATE TABLE it reached a fresh install
-- and nothing else -- IF NOT EXISTS sees an existing table and does nothing at
-- all, key list included -- so every server that predated it went without, and
-- the fix was a line an operator had to run by hand. `OPX.Storage.EnsureIndex`
-- asks `information_schema` first and adds it only when it is missing, so it is
-- safe on every boot; a failure there is a warning, because without the index
-- the find screen still ANSWERS, by walking the table.
--- Indexes a table that already exists may be missing; see the note above.
M.Storage.INDEXES = {
	{ TABLE = 'opx77_characters', NAME = 'idx_opx77_characters_seen',
		COLUMNS = { 'deleted_at', 'last_logged_out', 'citizen_id' } },
}

M.Storage.SCHEMA = {
	[[
CREATE TABLE IF NOT EXISTS opx77_users (
    user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    display_name VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL DEFAULT '',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
) ENGINE=InnoDB
]],

	[[
CREATE TABLE IF NOT EXISTS opx77_characters (
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    cid TINYINT UNSIGNED NOT NULL DEFAULT 1,
    name VARCHAR(64) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL DEFAULT '',
    char_info JSON NOT NULL,
    money JSON NOT NULL,
    job JSON NOT NULL,
    gang JSON NOT NULL,
    position JSON NULL DEFAULT NULL,
    metadata JSON NOT NULL,
    appearance JSON NULL DEFAULT NULL,
    last_logged_out TIMESTAMP NULL DEFAULT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    deleted_at TIMESTAMP NULL DEFAULT NULL,
    KEY idx_opx77_characters_user (user_id, deleted_at),
    KEY idx_opx77_characters_seen (deleted_at, last_logged_out, citizen_id),
    CONSTRAINT fk_opx77_character_user
        FOREIGN KEY (user_id) REFERENCES opx77_users (user_id)
        ON DELETE CASCADE
) ENGINE=InnoDB
]],

	[[
CREATE TABLE IF NOT EXISTS opx77_character_groups (
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    group_type ENUM('job', 'gang') NOT NULL,
    group_name VARCHAR(48) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    grade TINYINT UNSIGNED NOT NULL DEFAULT 0,
    joined_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (citizen_id, group_type, group_name),
    KEY idx_opx77_character_groups_lookup (group_type, group_name, grade),
    CONSTRAINT fk_opx77_character_group_character
        FOREIGN KEY (citizen_id) REFERENCES opx77_characters (citizen_id)
        ON DELETE CASCADE
) ENGINE=InnoDB
]],

	[[
CREATE TABLE IF NOT EXISTS opx77_active_characters (
    user_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
    citizen_id VARCHAR(16) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    locked_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    KEY idx_opx77_active_characters_citizen (citizen_id),
    CONSTRAINT fk_opx77_active_character_user
        FOREIGN KEY (user_id) REFERENCES opx77_users (user_id)
        ON DELETE CASCADE,
    CONSTRAINT fk_opx77_active_character_character
        FOREIGN KEY (citizen_id) REFERENCES opx77_characters (citizen_id)
        ON DELETE CASCADE
) ENGINE=InnoDB
]],
}

--- Turns a character row into the entity the module passes around.
-- Every JSON column gets a default; `appearance` defaults to nil, which means
-- 'never captured' rather than 'empty'.
-- @author dop42
-- @param row table|nil
-- @return table|nil
function M.Storage.ToEntity(row)
	if not row then return nil end
	return {
		citizenId = row.citizen_id,
		userId = row.user_id,
		cid = row.cid,
		name = row.name,
		charInfo = decode(row.char_info, {}),
		money = decode(row.money, {}),
		job = decode(row.job, {}),
		gang = decode(row.gang, {}),
		position = decode(row.position, nil),
		metadata = decode(row.metadata, {}),
		appearance = decode(row.appearance, nil),
		lastLoggedOut = row.last_logged_out,
		-- Nil unless the statement asked for it, which only the account listing
		-- does. A read that did not select it leaves this absent rather than
		-- inventing a date, so nothing downstream can mistake "not read" for
		-- "never created".
		createdAt = row.created_at,
	}
end

local toEntity = M.Storage.ToEntity

--- Records the account behind a session and stamps its visit.
-- `display_name` is rewritten unconditionally and `last_seen_at` set explicitly:
-- ON UPDATE CURRENT_TIMESTAMP only fires when a column actually changes.
-- @author dop42
-- @param userId UserId
-- @param displayName string|nil
-- @return Result
function M.Storage.UpsertAccount(userId, displayName)
	return Storage.Execute([[
INSERT INTO opx77_users (user_id, display_name)
VALUES (@user, @name)
ON DUPLICATE KEY UPDATE
    display_name = VALUES(display_name),
    last_seen_at = CURRENT_TIMESTAMP
  ]], { user = userId, name = displayName or '' })
end

--- Lists an account's living characters, never-played first, then most recent.
-- Never-played first is where the player is looking.
-- @author dop42
-- @param userId UserId
-- @return Result
function M.Storage.FetchAll(userId)
	-- `created_at` is read here and not by `FetchOne`: it is what tells two unnamed
	-- characters on one account apart in a staff listing, which is the only place
	-- anything reads it. A character that has been loaded is identified by its
	-- name and its citizen id instead.
	local rows = Storage.Query([[
SELECT citizen_id, user_id, cid, name, char_info, money, job, gang,
       position, metadata, appearance, last_logged_out, created_at
  FROM opx77_characters
 WHERE user_id = @user AND deleted_at IS NULL
 ORDER BY last_logged_out IS NULL DESC, last_logged_out DESC, cid ASC
  ]], { user = userId })
	if not rows.ok then return rows end

	local list = rows.value or {}
	local out = {}
	for i = 1, #list do out[i] = toEntity(list[i]) end
	return Result.Ok(out)
end

--- The character an account is locked on, or nil when it is on none.
-- @author dop42
--
-- THE LOCK IS WHAT A CONNECTION ENTERS ON. There is no selection screen: a
-- session loads the character this names, or, when it names none, a new one. The
-- row goes with the character (ON DELETE CASCADE) and with the account, so a lock
-- can never name something that is gone -- only a SOFT-deleted character can
-- still be named here, which is why the living row is read back before it is used.
-- @param userId UserId
-- @return Result the citizen id, or nil
function M.Storage.FetchActive(userId)
	local row = Storage.Single([[
SELECT a.citizen_id
  FROM opx77_active_characters a
  JOIN opx77_characters c ON c.citizen_id = a.citizen_id
 WHERE a.user_id = @user AND c.deleted_at IS NULL
 LIMIT 1
  ]], { user = userId })
	if not row.ok then return row end
	return Result.Ok(row.value and row.value.citizen_id or nil)
end

--- Locks an account on one character. Ownership is the caller's to have checked.
-- @author dop42
-- @param userId UserId
-- @param citizenId CitizenId
-- @return Result
function M.Storage.SetActive(userId, citizenId)
	return Storage.Execute([[
INSERT INTO opx77_active_characters (user_id, citizen_id)
VALUES (@user, @citizen)
ON DUPLICATE KEY UPDATE
    citizen_id = VALUES(citizen_id),
    locked_at = CURRENT_TIMESTAMP
  ]], { user = userId, citizen = citizenId })
end

--- Takes an account off whatever character it was locked on.
-- The next connection builds a new one, which is what `opx.create` asks for.
-- @author dop42
-- @param userId UserId
-- @return Result
function M.Storage.ClearActive(userId)
	return Storage.Execute([[
DELETE FROM opx77_active_characters WHERE user_id = @user
  ]], { user = userId })
end

--- Reads one living character by citizen id, whoever owns it.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.Storage.FetchOne(citizenId)
	local row = Storage.Single([[
SELECT citizen_id, user_id, cid, name, char_info, money, job, gang,
       position, metadata, appearance, last_logged_out
  FROM opx77_characters
 WHERE citizen_id = @citizen AND deleted_at IS NULL
 LIMIT 1
  ]], { citizen = citizenId })
	if not row.ok then return row end
	if not row.value then return Result.Err('character.notFound', citizenId) end
	return Result.Ok(toEntity(row.value))
end

--- Answers the lowest free slot number on an account.
-- The lowest free number rather than the highest plus one: a deleted slot is
-- reused instead of numbers climbing past the configured limit.
-- @author dop42
-- @param userId UserId
-- @param slots integer
-- @return Result
function M.Storage.NextCid(userId, slots)
	local rows = Storage.Query([[
SELECT cid FROM opx77_characters
 WHERE user_id = @user AND deleted_at IS NULL
  ]], { user = userId })
	if not rows.ok then return rows end

	local taken = {}
	local list = rows.value or {}
	for i = 1, #list do taken[list[i].cid] = true end

	for cid = 1, slots do
		if not taken[cid] then return Result.Ok(cid) end
	end
	return Result.Err('character.limit', tostring(slots))
end

-- `name` IS VARCHAR(64), AND A NAME IS TWO HALVES OF UP TO 32 LETTERS EACH plus
-- the space between them: 65. Under strict SQL mode the row refused it, and a
-- staff rename to two full-length halves made every later save of that
-- character fail, autosave and logout alike. The column is the roster's
-- denormalised "First Last"; the halves themselves live in `char_info`, whole,
-- so the column is cut in letters to what it holds.
local function storedName(name)
	return type(name) == 'string' and OPX.Text.Clean(name, 64) or ''
end

--- Inserts a new character row, the unique key deciding a collision.
-- Never a SELECT first: two players creating in the same tick would both pass it.
-- @author dop42
-- @param entity table
-- @return Result
function M.Storage.Insert(entity)
	return Storage.Execute([[
INSERT INTO opx77_characters
    (citizen_id, user_id, cid, name, char_info, money, job, gang, position, metadata)
VALUES
    (@citizen, @user, @cid, @name, @charInfo, @money, @job, @gang, NULLIF(@position, ''),
     @metadata)
  ]], {
		citizen = entity.citizenId,
		user = entity.userId,
		cid = entity.cid,
		name = storedName(entity.name),
		charInfo = encode(entity.charInfo),
		money = encode(entity.money),
		job = encode(entity.job),
		gang = encode(entity.gang),
		position = nullable(entity.position),
		metadata = encode(entity.metadata),
	})
end

--- Writes a loaded character back, never its identity columns.
-- Neither `citizen_id` nor `user_id` appears in the SET list: an UPDATE able to
-- move a character to another account is exactly how characters get stolen.
-- @author dop42
-- @param entity table
-- @param loggedOut boolean|nil Stamps last_logged_out.
-- @return Result
function M.Storage.Save(entity, loggedOut)
	return Storage.Execute([[
UPDATE opx77_characters
   SET name = @name,
       char_info = @charInfo,
       money = @money,
       job = @job,
       gang = @gang,
       position = NULLIF(@position, ''),
       metadata = @metadata,
       appearance = NULLIF(@appearance, ''),
       last_logged_out = CASE WHEN @loggedOut = 1 THEN CURRENT_TIMESTAMP ELSE last_logged_out END
 WHERE citizen_id = @citizen
  ]], {
		citizen = entity.citizenId,
		name = storedName(entity.name),
		charInfo = encode(entity.charInfo),
		money = encode(entity.money),
		job = encode(entity.job),
		gang = encode(entity.gang),
		position = nullable(entity.position),
		metadata = encode(entity.metadata),
		appearance = nullable(entity.appearance),
		loggedOut = loggedOut and 1 or 0,
	})
end

--- Adds to one balance of a character that is not loaded, in one statement.
-- @author dop42
--
-- AN INCREMENT, NEVER A READ-MODIFY-WRITE. The balance is read and written by the
-- same `UPDATE`, so two offline payments landing together each add to what the
-- other left, where a fetch-then-save pair would both read the old balance and
-- the second would erase the first. An absent currency key counts as zero, which
-- is what `NormaliseEntity` answers for one on the next login anyway.
--
-- The JSON path is a bound parameter, built from a money type the caller has
-- already checked against `MONEY.TYPES`; no text from anywhere else reaches it.
-- @param citizenId CitizenId
-- @param moneyType MoneyType
-- @param amount integer positive
-- @return Result
function M.Storage.AddMoney(citizenId, moneyType, amount)
	local written = Storage.Execute([[
UPDATE opx77_characters
   SET money = JSON_SET(money, @path,
       COALESCE(CAST(JSON_UNQUOTE(JSON_EXTRACT(money, @path)) AS SIGNED), 0) + @amount)
 WHERE citizen_id = @citizen AND deleted_at IS NULL
  ]], { citizen = citizenId, path = '$.' .. moneyType, amount = amount })
	if not written.ok then return written end
	-- The bridge answers the affected rows as a number or under `affectedRows`;
	-- zero is a character that is not there, and anything unreadable is left to
	-- the read that follows to decide.
	local affected = written.value
	if type(affected) == 'table' then affected = affected.affectedRows end
	if tonumber(affected) == 0 then return Result.Err('character.notFound', citizenId) end
	return Result.Ok(true)
end

--- Reads one stored balance of a character, loaded or not.
-- @author dop42
-- @param citizenId CitizenId
-- @param moneyType MoneyType
-- @return Result integer
function M.Storage.Balance(citizenId, moneyType)
	local read = Storage.Scalar([[
SELECT CAST(JSON_UNQUOTE(JSON_EXTRACT(money, @path)) AS SIGNED)
  FROM opx77_characters
 WHERE citizen_id = @citizen AND deleted_at IS NULL
 LIMIT 1
  ]], { citizen = citizenId, path = '$.' .. moneyType })
	if not read.ok then return read end
	return Result.Ok(math.tointeger(tonumber(read.value)) or 0)
end

--- Sets, or with a nil value removes, one top-level key of an offline
--- character's metadata, leaving every other key as the row holds it.
-- The path is a bound parameter built from a key the caller has already held to
-- `[%w_%-%.]`, quoted so a dot in it is part of the key and not a step.
-- @author dop42
-- @param citizenId CitizenId
-- @param key string
-- @param value any plain data, or nil to remove the key
-- @return Result
function M.Storage.SetMetadataKey(citizenId, key, value)
	local path = '$."' .. key .. '"'
	local written
	if value == nil then
		written = Storage.Execute([[
UPDATE opx77_characters
   SET metadata = JSON_REMOVE(metadata, @path)
 WHERE citizen_id = @citizen AND deleted_at IS NULL
  ]], { citizen = citizenId, path = path })
	else
		written = Storage.Execute([[
UPDATE opx77_characters
   SET metadata = JSON_SET(metadata, @path, CAST(@value AS JSON))
 WHERE citizen_id = @citizen AND deleted_at IS NULL
  ]], { citizen = citizenId, path = path, value = json.encode(value) })
	end
	if not written.ok then return written end
	local affected = written.value
	if type(affected) == 'table' then affected = affected.affectedRows end
	if tonumber(affected) == 0 then return Result.Err('character.notFound', citizenId) end
	return Result.Ok(true)
end

-- The one-column statement an offline group change writes, per column. Two whole
-- statements rather than one with the column name interpolated into it.
local SAVE_PRIMARY = {
	job = [[
UPDATE opx77_characters
   SET job = @value
 WHERE citizen_id = @citizen
  ]],
	gang = [[
UPDATE opx77_characters
   SET gang = @value
 WHERE citizen_id = @citizen
  ]],
}

--- Rewrites only the job or gang column of an offline character.
-- The whole row is never rewritten offline: the rest of it was never loaded.
-- @author dop42
-- @param citizenId CitizenId
-- @param column string job or gang
-- @param value table|nil
-- @return Result
function M.Storage.SavePrimary(citizenId, column, value)
	local statement = SAVE_PRIMARY[column]
	if not statement then return Result.Err('error.badRequest', tostring(column)) end
	return Storage.Execute(statement, {
		citizen = citizenId,
		value = json.encode(value or {}),
	})
end

--- Counts every character row an account ever wrote, deleted ones included.
-- The only read here that does not filter `deleted_at`: it is what bounds the
-- create-delete-create cycle, which a soft delete would otherwise leave unbounded.
-- @author dop42
-- @param userId UserId
-- @return Result
function M.Storage.CountRows(userId)
	local row = Storage.Single([[
SELECT COUNT(*) AS total FROM opx77_characters WHERE user_id = @user
  ]], { user = userId })
	if not row.ok then return row end
	return Result.Ok(tonumber(row.value and row.value.total) or 0)
end

--- Marks a character deleted, keeping its row.
-- The row stays so that a mistake can be undone and so that a citizen id is never
-- handed to a stranger.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.Storage.SoftDelete(citizenId)
	return Storage.Execute([[
UPDATE opx77_characters SET deleted_at = CURRENT_TIMESTAMP
 WHERE citizen_id = @citizen AND deleted_at IS NULL
  ]], { citizen = citizenId })
end

--- Really removes a character row.
-- Only the rollback of a creation whose membership rows failed calls this: the
-- row is seconds old and holds nothing.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.Storage.DeleteRow(citizenId)
	return Storage.Execute([[
DELETE FROM opx77_characters WHERE citizen_id = @citizen
  ]], { citizen = citizenId })
end

--- Deletes a character's rows from one configured cascade table.
-- The statement is built by concatenation because a parameter cannot stand in
-- for a table or a column name; both come from the operator's own configuration.
-- @author dop42
-- @param tableName string
-- @param columnName string
-- @param citizenId CitizenId
-- @return Result
function M.Storage.DeleteCascade(tableName, columnName, citizenId)
	return Storage.Execute(
		('DELETE FROM %s WHERE %s = @citizen'):format(tableName, columnName),
		{ citizen = citizenId })
end

--- Reads a character's job and gang memberships as grade maps.
-- @author dop42
-- @param citizenId CitizenId
-- @return Result
function M.Storage.FetchGroups(citizenId)
	local rows = Storage.Query([[
SELECT group_type, group_name, grade
  FROM opx77_character_groups
 WHERE citizen_id = @citizen
  ]], { citizen = citizenId })
	if not rows.ok then return rows end

	local jobs, gangs = {}, {}
	local list = rows.value or {}
	for i = 1, #list do
		local row = list[i]
		if row.group_type == 'job' then
			jobs[row.group_name] = row.grade
		else
			gangs[row.group_name] = row.grade
		end
	end
	return Result.Ok({ jobs = jobs, gangs = gangs })
end

--- Joins a group, or changes the grade held in it.
-- Which of the two follows from the composite primary key, not from a call site
-- that remembered to check.
-- @author dop42
-- @param citizenId CitizenId
-- @param groupType GroupType
-- @param groupName string
-- @param grade integer
-- @return Result
function M.Storage.UpsertGroup(citizenId, groupType, groupName, grade)
	return Storage.Execute([[
INSERT INTO opx77_character_groups (citizen_id, group_type, group_name, grade)
VALUES (@citizen, @type, @name, @grade)
ON DUPLICATE KEY UPDATE grade = VALUES(grade)
  ]], { citizen = citizenId, type = groupType, name = groupName, grade = grade })
end

--- Removes one job or gang membership row.
-- @author dop42
-- @param citizenId CitizenId
-- @param groupType GroupType
-- @param groupName string
-- @return Result
function M.Storage.RemoveGroup(citizenId, groupType, groupName)
	return Storage.Execute([[
DELETE FROM opx77_character_groups
 WHERE citizen_id = @citizen AND group_type = @type AND group_name = @name
  ]], { citizen = citizenId, type = groupType, name = groupName })
end

-- ── finding a character on an account nobody is sitting in ───────────────────
--
-- THE READS THAT DO NOT START FROM AN ACCOUNT. Everything above this line is
-- keyed on a `user_id` or a `citizen_id` the caller already holds, which is what
-- a session can always answer. The staff find screen has neither: the person it
-- is looking for is not connected, so there is no session to ask, and the only
-- thing left is the table itself. That makes these the two widest statements in
-- the module and the two that had to be bounded hardest.
--
-- NEITHER TAKES A ROW COUNT. `LIMIT 26` is written into the statement rather
-- than bound, exactly as `MembersOf` writes its 200, so the ceiling is a
-- property of the SQL and not of whoever calls it -- a caller cannot ask for ten
-- thousand rows because there is no argument with which to ask. 26 is
-- `FIND_PAGE` plus the probe row described on it.
--
-- NEITHER USES OFFSET. A page past the first is a SEEK: it is handed the sort
-- key of the last row the reader saw and asks for what comes after it. OFFSET
-- would make page four hundred read 10,000 index entries to throw 9,975 of them
-- away, and -- worse on a roster ordered by last-played, which is reordered by
-- every logout while the operator reads it -- a row that moves to the top pushes
-- one row down across the page boundary, so OFFSET shows it twice. A seek is
-- stable for everything BELOW the cursor, which is the only part the reader has
-- not seen yet.

--- Rows one find answers. The statements carry LIMIT 26, one more than this, and
--- the extra row is the PROBE: it is never shown, and it is the only way a seek
--- can say whether a next page exists -- there is no count to subtract from.
M.Storage.FIND_PAGE = 25

-- Escapes the two LIKE metacharacters and the escape itself, so a term of `%`
-- searches for a per-cent sign instead of matching every row in the table. The
-- statements rely on MySQL's default LIKE escape, a backslash, rather than
-- naming it with ESCAPE: under NO_BACKSLASH_ESCAPES the literal `'\\'` an ESCAPE
-- clause needs is two characters and the server refuses the clause outright.
local function likeTerm(term)
	local escaped = term:gsub('\\', '\\\\'):gsub('%%', '\\%%'):gsub('_', '\\_')
	return '%' .. escaped .. '%'
end

--- Turns a find row into what the staff screen draws.
-- Wider than `ToEntity` by the account's display name and narrower by everything
-- a character CARRIES: money, position, metadata and appearance are not read at
-- all, so no amount of paging through this screen ever puts them on the wire.
local function toFound(row)
	local info = decode(row.char_info, {})
	local job = decode(row.job, {})
	local gang = decode(row.gang, {})
	return {
		citizenId = row.citizen_id,
		userId = row.user_id,
		cid = row.cid,
		account = row.display_name,
		firstName = info.firstName,
		lastName = info.lastName,
		gender = info.gender,
		job = job.label,
		gang = gang.name ~= 'none' and gang.label or nil,
		lastLoggedOut = row.last_logged_out,
		createdAt = row.created_at,
	}
end

--- Shapes a find result, or passes the failure through.
local function toFoundList(rows)
	if not rows.ok then return rows end
	local list = rows.value or {}
	local out = {}
	for i = 1, #list do out[i] = toFound(list[i]) end
	return Result.Ok(out)
end

--- The most recently played characters, newest first; the first page.
-- @author dop42
--
-- `last_logged_out IS NOT NULL` drops characters that have never been played at
-- all. They have no place in an order BY when somebody was last here, and they
-- are not lost: the search below reads them like any other row.
-- @return Result up to FIND_PAGE + 1 rows
function M.Storage.FindRecent()
	return toFoundList(Storage.Query([[
SELECT c.citizen_id, c.user_id, c.cid, c.char_info, c.job, c.gang,
       c.last_logged_out, c.created_at, u.display_name
  FROM opx77_characters c
  JOIN opx77_users u ON u.user_id = c.user_id
 WHERE c.deleted_at IS NULL AND c.last_logged_out IS NOT NULL
 ORDER BY c.last_logged_out DESC, c.citizen_id DESC
 LIMIT 26
  ]]))
end

--- The page of most recently played characters after one the reader has seen.
-- @author dop42
--
-- A WHOLE SECOND STATEMENT rather than the one above with a predicate that is
-- sometimes true, which is the same choice `SAVE_PRIMARY` makes one screen up:
-- the first page has no cursor to compare against and there is no sentinel to
-- invent -- a TIMESTAMP stops at 2038, so there is no value above every row.
--
-- The comparison is a ROW CONSTRUCTOR and not two ANDed halves, because the sort
-- key is the PAIR: two characters logged out in the same second are ordered by
-- citizen id, and a seek that only compared the timestamp would either repeat
-- them or step over them.
-- @param seenAt string the last row's last_logged_out
-- @param cursor CitizenId the last row's citizen id
-- @return Result up to FIND_PAGE + 1 rows
function M.Storage.FindRecentAfter(seenAt, cursor)
	return toFoundList(Storage.Query([[
SELECT c.citizen_id, c.user_id, c.cid, c.char_info, c.job, c.gang,
       c.last_logged_out, c.created_at, u.display_name
  FROM opx77_characters c
  JOIN opx77_users u ON u.user_id = c.user_id
 WHERE c.deleted_at IS NULL AND c.last_logged_out IS NOT NULL
   AND (c.last_logged_out, c.citizen_id) < (@seenAt, @cursor)
 ORDER BY c.last_logged_out DESC, c.citizen_id DESC
 LIMIT 26
  ]], { seenAt = seenAt, cursor = cursor }))
end

--- Characters whose name, account name or citizen id carries a term.
-- @author dop42
--
-- ONE STATEMENT FOR EVERY PAGE, unlike the pair above, because the sort key here
-- is the primary key: `citizen_id` is ascii_bin, never null and never rewritten,
-- and the empty string is below every value it can hold. So the first page is
-- the seek with `''` for a cursor and there is no special case to write.
--
-- THE LIKE IS NOT INDEXED AND CANNOT BE. A contains-match has a leading wildcard,
-- which no B-tree serves; anchoring it to a prefix would index it and would stop
-- finding anybody by their family name, since `name` is "First Last". So this
-- walks the primary key from the cursor and STOPS at 26 matches -- which is a
-- handful of rows for a term anybody actually types, and one pass over the table
-- for a term that matches nothing. What bounds how often that pass is paid is
-- not here: it is the three-character floor and the operator's read cooldown,
-- both in the caller.
-- @param term string already trimmed and length-checked by the caller
-- @param cursor CitizenId the last citizen id seen, or '' for the first page
-- @return Result up to FIND_PAGE + 1 rows
function M.Storage.FindByTerm(term, cursor)
	return toFoundList(Storage.Query([[
SELECT c.citizen_id, c.user_id, c.cid, c.char_info, c.job, c.gang,
       c.last_logged_out, c.created_at, u.display_name
  FROM opx77_characters c
  JOIN opx77_users u ON u.user_id = c.user_id
 WHERE c.deleted_at IS NULL
   AND c.citizen_id > @cursor
   AND (c.name LIKE @like OR u.display_name LIKE @like OR c.citizen_id = @exact)
 ORDER BY c.citizen_id ASC
 LIMIT 26
  ]], { cursor = cursor, like = likeTerm(term), exact = term }))
end

--- Lists at most 200 living members of a group, highest grade first.
-- Bounded because an unbounded result blocks the database worker.
-- @author dop42
-- @param groupType GroupType
-- @param groupName string
-- @return Result
function M.Storage.MembersOf(groupType, groupName)
	local rows = Storage.Query([[
SELECT g.citizen_id, g.grade, c.name, c.char_info
  FROM opx77_character_groups g
  JOIN opx77_characters c ON c.citizen_id = g.citizen_id
 WHERE g.group_type = @type AND g.group_name = @name AND c.deleted_at IS NULL
 ORDER BY g.grade DESC, c.name ASC
 LIMIT 200
  ]], { type = groupType, name = groupName })
	if not rows.ok then return rows end

	local list = rows.value or {}
	local out = {}
	for i = 1, #list do
		local row = list[i]
		local charInfo = decode(row.char_info, {})
		out[i] = {
			citizenId = row.citizen_id,
			grade = row.grade,
			name = ('%s %s'):format(charInfo.firstName or '?', charInfo.lastName or '?'),
		}
	end
	return Result.Ok(out)
end
