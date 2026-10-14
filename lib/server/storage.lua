--- Database access through the MySQL bridge, answering Result values.
-- @author dop42
--
-- This is the only place that talks to the bridge. `MySQL` is an alias of
-- `Open77.database`, installed only with the `database.access` permission, so it
-- may be absent: `run` reads the global and answers `no-database` rather than
-- indexing a nil.
--
-- IT IS AN ORDINARY GLOBAL READ AND NOT `rawget`, and this paragraph went on
-- saying `rawget` after the call had stopped being one. `core/shared/main.lua`
-- carries the argument: `rawget` skips the metatable an Open77 environment
-- installs, which is the very thing that resolves a host global, and reading a
-- global that is not there never raises anyway -- so there was nothing for it to
-- guard. `core/server/tunables.lua` then cited this file as precedent for a
-- `rawget` that was no longer in it.
--
-- Every call yields, so it must come from a `CreateThread` -- never from file
-- scope, and never from an event handler that is not itself on a thread.
--
-- `MySQL.<method>.await` RAISES instead of answering `value, reason`, and an
-- error raised inside a `CreateThread` kills that thread silently. `run` wraps
-- every call in a `pcall` and answers a `Result` instead: `no-database` when the
-- bridge is not installed, `query-failed` carrying the raw exception as `detail`.
-- A `nil` value is an empty result, not a failure: `single` answers `nil` for
-- 'no rows'.
--
-- Statements use named parameters (`@citizen`) rather than `?`, and NO comment
-- may appear inside a SQL string: the bridge rewrites `?` by walking the query
-- text and a comment inside it is not seen as one.

local Result = OPX.Result

OPX.Storage = {}
local Storage = OPX.Storage

-- nil until the probe has run, then kept for the life of the resource.
local ready = nil
local readyReason = 'not probed'

--- Runs one bridge method, turning a raise into a Result.
local function run(method, sql, params)
	local api = MySQL
	local fn = api and api[method]
	if not fn or type(fn.await) ~= 'function' then
		return Result.Err('no-database', ('MySQL.%s.await is unavailable'):format(method))
	end

	local ok, value = pcall(fn.await, sql, params)
	if not ok then
		return Result.Err('query-failed', tostring(value))
	end
	return Result.Ok(value)
end

--- Runs a statement answering a list of rows.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Query(sql, params) return run('query', sql, params) end

--- Runs a statement answering one row, or nil.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Single(sql, params) return run('single', sql, params) end

--- Runs a statement answering one column of one row.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Scalar(sql, params) return run('scalar', sql, params) end

--- Runs an insert answering the inserted id.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Insert(sql, params) return run('insert', sql, params) end

--- Runs a write or DDL statement answering the rows affected.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Update(sql, params) return run('update', sql, params) end

--- Runs a write whose answer nobody reads, an alias of update.
-- @author dop42
-- @param sql string
-- @param params table|nil
-- @return Result
function OPX.Storage.Execute(sql, params) return run('update', sql, params) end

--- Commits several statements as one unit, or none of them.
-- @author dop42
--
-- Separate from `run` because it is the one bridge method that resolves
-- `false, reason` instead of raising: routed through `run`, a rollback would
-- read as a success. It distinguishes `transaction-raised` (the bridge raised)
-- from `transaction-failed` (the bridge rolled back).
-- @param statements table a list of { query, parameters } pairs
-- @return Result
function OPX.Storage.Transaction(statements)
	local api = MySQL
	local fn = api and api.transaction
	if not fn or type(fn.await) ~= 'function' then
		return Result.Err('no-database', 'MySQL.transaction.await is unavailable')
	end

	local ok, committed, reason = pcall(fn.await, statements)
	if not ok then
		return Result.Err('transaction-raised', tostring(committed))
	end
	if committed ~= true then
		return Result.Err('transaction-failed', tostring(reason))
	end
	return Result.Ok(true)
end

--- Resource state that survives a reload, one namespace per writer.
-- @author dop42
--
-- `Open77.state` IS NOT A KEY-VALUE STORE. The card for 2.31.13+op77.76 is
-- exact: "Not a key-value store: it holds one value per resource." This is one
-- resource, and TWO modules were writing that one value whole --
-- `modules/weather/server/state.lua` its clock, epoch and preset, and
-- `modules/admin/server/world.lua` the destinations an operator placed in game.
-- Whichever wrote last destroyed the other's carried state, and both write
-- often: weather on every mutation and on its first anchor, the destinations on
-- every add and remove.
--
-- Nothing crashed, which is why it went unnoticed: each stamps its own protocol
-- number and refuses a blob that does not carry it, so the loser cold-starts.
-- What it cost was silent. Place a staff destination and the world clock
-- restarts on the next reload; let the weather roll and the destinations are
-- gone. Weather says so in the log -- "carried state ignored: protocol nil is
-- not 1" -- against a blob that was never weather's.
--
-- It could not be seen off-platform either: the test host's `state.save`
-- accepted everything and kept nothing and `load` answered nil forever, so
-- every restore in this runtime took its cold-start path in every test.
--
-- So: one blob holding a table of namespaces, and each writer reads and writes
-- its own. A namespace neither module has written is absent, which is the same
-- cold start each already handles -- including the first boot after this
-- change, when the old unnamespaced blob is ignored once by both.
OPX.Carry = {}

-- Stamped on the envelope, not on what a caller puts inside it: a caller keeps
-- its own version number for its own shape, and this one is only about whether
-- the envelope is one of ours.
local CARRY_PROTOCOL = 1

--- Whether the host offers the reload store at all.
local function carryApi()
	local state = Open77.state
	if type(state) ~= 'table' or type(state.save) ~= 'function'
		or type(state.load) ~= 'function' then
		return nil
	end
	return state
end

--- Every namespace carried across the reload, or an empty table.
-- An envelope that is not ours -- the unnamespaced blob an older build wrote,
-- or anything else the host handed back -- reads as nothing carried.
local function namespaces()
	local state = carryApi()
	if state == nil then return {} end
	local read, carried = pcall(state.load)
	if not read or type(carried) ~= 'table' then return {} end
	if carried.CARRY ~= CARRY_PROTOCOL or type(carried.namespaces) ~= 'table' then return {} end
	return carried.namespaces
end

--- What one namespace carried across the reload, or nil.
-- @author dop42
-- @param namespace string
-- @return any
function OPX.Carry.Load(namespace)
	if type(namespace) ~= 'string' or namespace == '' then return nil end
	return namespaces()[namespace]
end

--- Carries one namespace's value, leaving every other namespace alone.
--- `nil` clears that namespace and only that one.
-- @author dop42
--
-- Read-modify-write, and it has to be: the whole point is that this writer does
-- not know who else has carried something. The host round-trips the blob
-- through JSON, so what comes back is already a copy and there is nothing to
-- alias.
-- @param namespace string
-- @param value any JSON-encodable, or nil to clear
-- @return boolean
-- @return string|nil the refusal
function OPX.Carry.Save(namespace, value)
	if type(namespace) ~= 'string' or namespace == '' then return false, 'bad-namespace' end
	local state = carryApi()
	if state == nil then return false, 'no-state-api' end

	local held = namespaces()
	held[namespace] = value

	-- A `save` may be REFUSED -- an unserialisable blob, or a stopping resource,
	-- whose write the host turns away on purpose. Read rather than assumed: a
	-- refusal recorded as a success is carried state nobody knows is gone.
	local wrote, saved, reason = pcall(state.save, { CARRY = CARRY_PROTOCOL, namespaces = held })
	if not wrote then return false, tostring(saved) end
	if saved == false then return false, tostring(reason) end
	return true
end

--- Decodes a JSON column, answering the fallback when it cannot.
-- @author dop42
--
-- Accepts either a string or an already-decoded table, because one bridge
-- version does the one and another does the other. A column that will not decode
-- is absent rather than fatal: the row loads with the fallback.
-- @param value any
-- @param fallback table|nil
-- @return table|nil
function OPX.Storage.Decode(value, fallback)
	if type(value) == 'table' then return value end
	if type(value) ~= 'string' or value == '' then return fallback end
	local ok, decoded = pcall(json.decode, value)
	if not ok or type(decoded) ~= 'table' then return fallback end
	return decoded
end

--- Binds a nullable JSON column, absence as an empty string.
-- @author dop42
--
-- The bridge DROPS a `nil` parameter instead of binding NULL, and MySqlConnector
-- then refuses the query (`Parameter '@x' must be defined`). So a nullable column
-- receives `''` for 'nothing' and the statement turns it back with
-- `NULLIF(@x, '')`: encoded JSON is never the empty string.
-- @param value any
-- @return string
function OPX.Storage.Nullable(value)
	return value ~= nil and json.encode(value) or ''
end

--- Probes the database once and answers whether it answered.
-- @author dop42
--
-- The answer is kept for the life of the resource: nil until the probe has run,
-- then true or false. Without a database the resource still boots, and says in
-- two lines that nobody can log in until that is fixed.
-- @return boolean, string
function OPX.Storage.Ready()
	if ready ~= nil then return ready, readyReason end

	local probe = Storage.Scalar('SELECT 1')
	if not probe.ok then
		ready = false
		readyReason = tostring(probe.detail)
		Open77.log.error('[storage] no database: ' .. readyReason)
		Open77.log.error('[storage] the core will boot, but nobody can be logged in until this ' ..
			'is fixed')
		return false, readyReason
	end

	ready = true
	readyReason = 'ready'
	return true, readyReason
end

--- Runs every CREATE TABLE statement in order, stopping at the first failure.
-- @author dop42
--
-- The list is an argument rather than one hard-coded schema, so that each module
-- contributes its own tables. Order matters: foreign keys first. Stopping beats
-- carrying on with an incomplete schema, so the caller can refuse connections
-- exactly as it does without a database.
-- @param statements table a list of SQL strings
-- @return Result
function OPX.Storage.ApplySchema(statements)
	for i = 1, #statements do
		local statement = statements[i]
		local created = Storage.Execute(statement)
		if not created.ok then
			local tableName = statement:match('CREATE TABLE IF NOT EXISTS ([%w_]+)') or ('#' .. i)
			Open77.log.error(('[storage] creating %s failed: %s')
				:format(tableName, tostring(created.detail)))
			return Result.Err('schema-failed', tableName)
		end
	end

	Open77.log.info(('[storage] schema ready: %d table(s)'):format(#statements))
	return Result.Ok(#statements)
end

-- A bare SQL identifier: what a table, an index or a column may be named when
-- it is spliced into DDL, which cannot bind one as a parameter.
local IDENTIFIER = '^[%a_][%w_]*$'

-- What a column definition spliced into DDL may hold: a type, its size, a
-- character set, NULL / NOT NULL and a plain default. No quotes, no semicolons.
local COLUMN_DEFINITION = '^[%w_ %(%),]+$'

--- Adds a column to a table that may predate it, and does nothing when it is
--- already there. The column's twin of `EnsureIndex`, for the same reason: a
--- column written into a CREATE TABLE reaches a fresh install and nothing else.
-- @author dop42
-- @param tableName string
-- @param column string
-- @param definition string e.g. `VARCHAR(40) CHARACTER SET ascii COLLATE ascii_bin NULL`
-- @return Result true when it was added, false when it was already there
function OPX.Storage.EnsureColumn(tableName, column, definition)
	if type(tableName) ~= 'string' or not tableName:match(IDENTIFIER)
		or type(column) ~= 'string' or not column:match(IDENTIFIER)
		or type(definition) ~= 'string' or not definition:match(COLUMN_DEFINITION) then
		return Result.Err('bad-column', tostring(column))
	end
	local present = Storage.Scalar([[
SELECT COUNT(*)
  FROM information_schema.COLUMNS
 WHERE table_schema = DATABASE() AND table_name = @tableName AND column_name = @column
  ]], { tableName = tableName, column = column })
	if not present.ok then return present end
	if (tonumber(present.value) or 0) > 0 then return Result.Ok(false) end

	local added = Storage.Execute(('ALTER TABLE %s ADD COLUMN %s %s')
		:format(tableName, column, definition))
	if not added.ok then return added end
	Open77.log.info(('[storage] added column %s to %s'):format(column, tableName))
	return Result.Ok(true)
end

--- Adds an index to a table that may predate it, and does nothing when it is
--- already there.
-- @author dop42
--
-- THE MIGRATION `CREATE TABLE IF NOT EXISTS` CANNOT BE. A key written into a
-- CREATE TABLE reaches a fresh install and nothing else: IF NOT EXISTS sees an
-- existing table and touches nothing, key list included. MySQL has no
-- `CREATE INDEX IF NOT EXISTS` either, so the question is asked of
-- `information_schema` first and the ALTER runs only when the answer is no --
-- which makes it safe to run on every boot, fresh or not.
-- @param tableName string
-- @param indexName string
-- @param columns string[]
-- @return Result true when it was added, false when it was already there
function OPX.Storage.EnsureIndex(tableName, indexName, columns)
	if type(tableName) ~= 'string' or not tableName:match(IDENTIFIER)
		or type(indexName) ~= 'string' or not indexName:match(IDENTIFIER)
		or type(columns) ~= 'table' or #columns == 0 then
		return Result.Err('bad-index', tostring(indexName))
	end
	for index = 1, #columns do
		if type(columns[index]) ~= 'string' or not columns[index]:match(IDENTIFIER) then
			return Result.Err('bad-index', tostring(indexName))
		end
	end

	local present = Storage.Scalar([[
SELECT COUNT(*)
  FROM information_schema.STATISTICS
 WHERE table_schema = DATABASE() AND table_name = @tableName AND index_name = @indexName
  ]], { tableName = tableName, indexName = indexName })
	if not present.ok then return present end
	if (tonumber(present.value) or 0) > 0 then return Result.Ok(false) end

	local added = Storage.Execute(('ALTER TABLE %s ADD KEY %s (%s)')
		:format(tableName, indexName, table.concat(columns, ', ')))
	if not added.ok then return added end
	Open77.log.info(('[storage] added index %s to %s'):format(indexName, tableName))
	return Result.Ok(true)
end
