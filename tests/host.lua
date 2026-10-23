--- A stand-in for the OPEN//77 host, enough to boot the runtime off-platform.
-- @author dop42
--
-- Runs in desktop Lua 5.4, not in the sandbox, so it may use what the sandbox
-- removes. The code under test may not, and `Sandbox` below is what enforces it.

local Host = {}

--- The sandbox installs a `json` global, and every JSON column binding goes
--- through it. A stub that only pretended to encode would let a round-trip bug
--- pass, so this one really encodes and really decodes its own output.
--
-- An empty Lua table encodes as `{}`, not `[]` -- the same asymmetry the pages
-- have to guard against, and the reason the runtime's decoders never trust `#`.
local json = {}

local function encodeValue(value, out)
	local kind = type(value)
	if value == nil then
		out[#out + 1] = 'null'
	elseif kind == 'boolean' then
		out[#out + 1] = tostring(value)
	elseif kind == 'number' then
		-- NaN and the infinities are not JSON. They arrive from clients and the
		-- runtime is expected to reject them before they reach a column.
		if value ~= value or value == math.huge or value == -math.huge then
			out[#out + 1] = 'null'
		else
			out[#out + 1] = (value % 1 == 0) and ('%d'):format(value) or ('%.14g'):format(value)
		end
	elseif kind == 'string' then
		out[#out + 1] = '"' .. value:gsub('[%c"\\]', function(char)
			local escapes = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r',
				['\t'] = '\\t' }
			return escapes[char] or ('\\u%04x'):format(char:byte())
		end) .. '"'
	elseif kind == 'table' then
		local count = 0
		for _ in pairs(value) do count = count + 1 end
		if count > 0 and count == #value then
			out[#out + 1] = '['
			for index = 1, count do
				if index > 1 then out[#out + 1] = ',' end
				encodeValue(value[index], out)
			end
			out[#out + 1] = ']'
		else
			-- Keys sorted: two encodings of the same table must compare equal,
			-- which is what lets a caller skip a write when nothing changed.
			local keys = {}
			for key in pairs(value) do keys[#keys + 1] = tostring(key) end
			table.sort(keys)
			out[#out + 1] = '{'
			for index = 1, #keys do
				if index > 1 then out[#out + 1] = ',' end
				encodeValue(keys[index], out)
				out[#out + 1] = ':'
				local nested = value[keys[index]]
				if nested == nil then nested = value[tonumber(keys[index])] end
				encodeValue(nested, out)
			end
			out[#out + 1] = '}'
		end
	else
		out[#out + 1] = 'null'
	end
end

function json.encode(value)
	local out = {}
	encodeValue(value, out)
	return table.concat(out)
end

local decodeValue

local function skip(text, at)
	return text:find('[^ \t\r\n]', at) or #text + 1
end

function decodeValue(text, at)
	at = skip(text, at)
	local char = text:sub(at, at)

	if char == '{' or char == '[' then
		local isArray = char == '['
		local closer = isArray and ']' or '}'
		local out, index = {}, 0
		at = skip(text, at + 1)
		if text:sub(at, at) == closer then return out, at + 1 end
		while true do
			local key
			if isArray then
				index = index + 1
				key = index
			else
				key, at = decodeValue(text, at)
				at = skip(text, at)
				if text:sub(at, at) ~= ':' then return nil, at end
				at = at + 1
			end
			out[key], at = decodeValue(text, at)
			at = skip(text, at)
			local next = text:sub(at, at)
			if next == closer then return out, at + 1 end
			if next ~= ',' then return nil, at end
			at = skip(text, at + 1)
		end
	elseif char == '"' then
		local out, index = {}, at + 1
		while index <= #text do
			local byte = text:sub(index, index)
			if byte == '"' then return table.concat(out), index + 1 end
			if byte == '\\' then
				local escaped = text:sub(index + 1, index + 1)
				local plain = { n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\' }
				if plain[escaped] then
					out[#out + 1] = plain[escaped]
					index = index + 2
				elseif escaped == 'u' then
					out[#out + 1] = string.char(tonumber(text:sub(index + 2, index + 5), 16) % 256)
					index = index + 6
				else
					index = index + 2
				end
			else
				out[#out + 1] = byte
				index = index + 1
			end
		end
		return nil, index
	end

	local literal = text:match('^[%-%d%.eE%+]+', at)
	if literal then return tonumber(literal), at + #literal end
	for word, value in pairs({ ['true'] = true, ['false'] = false, ['null'] = nil }) do
		if text:sub(at, at + #word - 1) == word then return value, at + #word end
	end
	if text:sub(at, at + 3) == 'null' then return nil, at + 4 end
	return nil, at
end

function json.decode(text)
	if type(text) ~= 'string' then return nil end
	local ok, value = pcall(decodeValue, text, 1)
	if not ok then return nil end
	return value
end

Host.json = json

-- Value nodes the host accepts in one WebUI payload, and the rule it counts by:
-- the value itself, and both halves of every pair under a table. `modules/menu`
-- and `modules/panel` both count against this, and this file is the third copy
-- on purpose -- a stub that shared the runtime's counter could not catch the
-- runtime's counter being wrong.
Host.MAX_PAYLOAD_NODES = 1024

--- Turns a list of VFX aliases into the alias -> path map the native answers.
-- @author dop42
--
-- Kept as a list in the source because a list of 51 names is what anybody
-- maintaining it wants to read, and turned into the map here because a map is
-- what `Open77.vfx.catalog` actually hands back.
-- @param aliases string[]
-- @return table<string, string>
function Host.VfxCatalog(aliases)
	local map = {}
	for index = 1, #aliases do
		map[aliases[index]] = ('base\\fx\\%s.effect'):format(aliases[index]:gsub('%.', '\\'))
	end
	return map
end

--- The nodes one payload comes to.
-- @author dop42
-- @param value any
-- @return integer
function Host.PayloadNodes(value)
	local nodes = 1
	if type(value) ~= 'table' then return nodes end
	for key, nested in pairs(value) do
		nodes = nodes + Host.PayloadNodes(key) + Host.PayloadNodes(nested)
	end
	return nodes
end

--- What steers each bridge `Host.Database` has built, keyed by the bridge and
--- weak on that key so a bridge a test has dropped is not kept alive by it.
Host.steering = setmetatable({}, { __mode = 'k' })

--- A stand-in for the `MySQL` bridge. `answers` maps a method name to a function
--- of (sql, params); a method that is absent raises, which is what the real
--- bridge does and the whole reason `OPX.Storage` wraps every call.
-- @author dop42
--
-- EVERY QUERY USED TO BE ATOMIC, and that made a whole class of bug unreachable.
-- `bridge.query.await` called straight through and answered on the spot, so no
-- two threads could ever be part-way through a query at the same time -- no
-- interleaving was reachable by any route, which is precisely the failure
-- `OPX.Storage` and every read-modify-write above it exist to guard against.
-- The card is exact: the continuation "resumes on the owning resource's
-- scheduler, never on the database worker". So `await` YIELDS once before it
-- answers, and the caller comes back on a later `control.Pump` round -- which
-- is what lets a test start two claims on one row and watch them overtake each
-- other.
--
-- It yields only when it is legal to: `OPX.Schema.Apply` is called straight
-- from test code, off any coroutine, and the real bridge would raise there
-- rather than silently succeed. `control.database.strict` makes it raise, so a
-- call site can be PROVED to be on a thread; the default answers instead, so
-- that proving it is a test's choice and not a precondition of every test.
--
-- THE METHOD IS A CALLABLE THAT ALSO CARRIES `.await`, which is the shape the
-- card documents ("two forms: pass a callback, or use `.await`"). It was a
-- plain table, so the documented callback form raised `attempt to call a table
-- value` and no test could use it.
-- @param answers table<string, function>
-- @return table
function Host.Database(answers)
	local bridge = {}

	-- What a test steers, reachable as `control.database` once an environment
	-- has been built with this bridge, and as a field on the bridge itself for
	-- the tests that build one without booting.
	--
	--   strict   true: an `await` off a coroutine raises, as the real one does
	--   calls    every call in order: { method, sql, params, form }
	--   park     a function of (method, sql) answering true to hold that call
	--            suspended until `control.database.Resume()` lets it go
	local steering = { strict = false, calls = {}, park = nil, parked = {} }

	local function invoke(method, sql, params)
		local answer = answers[method]
		if answer == nil then error(('no stub for MySQL.%s'):format(method), 0) end
		return answer(sql, params)
	end

	-- THE LIMITS OF ONE REQUEST, as the cards state them (`Open77.database.update`
	-- and `.transaction`, since op77.45): 64 KiB of SQL and 64 parameters per
	-- statement, and 1 to 64 statements per transaction. The real bridge checks
	-- them before the request leaves and `.await` RAISES the reason. The stub
	-- did not check them at all, so a multi-row INSERT binding 250 values passed
	-- every test here and was refused whole on a real server.
	local MAX_SQL, MAX_PARAMS, MAX_STATEMENTS = 65536, 64, 64

	local function countParams(params)
		if type(params) ~= 'table' then return 0 end
		local count = 0
		for _ in pairs(params) do count = count + 1 end
		return count
	end

	local function statementRefusal(sql, params)
		if type(sql) == 'string' and #sql > MAX_SQL then return 'sql_too_large' end
		if countParams(params) > MAX_PARAMS then return 'too_many_parameters' end
		return nil
	end

	local function refusal(method, sql, params)
		if method ~= 'transaction' then return statementRefusal(sql, params) end
		local list = sql
		if type(list) ~= 'table' or #list < 1 or #list > MAX_STATEMENTS then
			return 'invalid_transaction'
		end
		for index = 1, #list do
			local entry = list[index]
			local why = type(entry) == 'table'
				and statementRefusal(entry.query, entry.values or entry.parameters)
			if why then return why end
		end
		return nil
	end

	for _, method in ipairs({ 'query', 'single', 'scalar', 'insert', 'update', 'transaction' }) do
		local function await(sql, params)
			steering.calls[#steering.calls + 1] =
				{ method = method, sql = sql, params = params, form = 'await' }

			local refused = refusal(method, sql, params)
			if refused ~= nil then error(refused, 0) end

			if coroutine.isyieldable() then
				-- PARKED CALLS COME BACK IN THE ORDER THEY ARE RELEASED, not in
				-- the order they were made: a database worker answers whichever
				-- query finishes first, and a runtime that assumed otherwise is
				-- the bug this affordance is for.
				if steering.park ~= nil and steering.park(method, sql, params) then
					local ticket = { held = true }
					steering.parked[#steering.parked + 1] = ticket
					while ticket.held do coroutine.yield() end
				else
					-- The ordinary case: one trip through the scheduler.
					coroutine.yield()
				end
			elseif steering.strict then
				error(('MySQL.%s.await was called off a coroutine'):format(method), 0)
			end

			return invoke(method, sql, params)
		end

		bridge[method] = setmetatable({ await = await }, {
			-- The callback form. The continuation runs on the caller's side of
			-- the wire, so it is queued rather than called here -- a callback
			-- that ran before this returned would be the one thing the card
			-- says never happens.
			__call = function(_, sql, params, callback)
				if type(params) == 'function' then callback, params = params, nil end
				steering.calls[#steering.calls + 1] =
					{ method = method, sql = sql, params = params, form = 'callback' }
				local rows = invoke(method, sql, params)
				if type(callback) == 'function' then callback(rows) end
				return nil
			end,
		})
	end

	--- Lets every parked call go, oldest first.
	function steering.Resume(count)
		local released = 0
		for index = 1, #steering.parked do
			local ticket = steering.parked[index]
			if ticket.held then
				ticket.held = false
				released = released + 1
				if count ~= nil and released >= count then break end
			end
		end
		return released
	end

	-- Held OUTSIDE the bridge, in a weak-keyed registry, rather than as
	-- `bridge.control`: the bridge models `MySQL` and a key the platform does
	-- not have on it is a key a caller could come to depend on. `Host.Steering`
	-- is the lookup, and `Host.Environment` publishes it as `control.database`.
	Host.steering[bridge] = steering
	return bridge
end

--- What steers one bridge, for a test that built one without booting.
-- @author dop42
-- @param bridge table
-- @return table|nil
function Host.Steering(bridge) return bridge ~= nil and Host.steering[bridge] or nil end


-- ── the per-resume budget meter (opt-in) ─────────────────────────────────────
-- THE CLIENT KILLS A RESUME THAT OVERRUNS ITS INSTRUCTION BUDGET, silently and
-- mid-operation, and the stub below runs every handler for free. Set
-- `OPX_BUDGET_METER=<instructions>` and the client half counts what each
-- resume costs -- every thread resumed by `Pump`, every net event, page
-- handler, event handler and key mapping the suite plays, and every scheduler
-- job inside the pass that ran it -- and `Host.Meter` keeps the worst cost per
-- call site. `tests/run.lua` prints the sites past the figure when the suite
-- ends. Off by default: the count hook makes the suite slower, and the tests
-- that count instructions themselves would read the meter's hook instead of
-- their own.
local METER_LIMIT = tonumber(os.getenv and os.getenv('OPX_BUDGET_METER') or nil)
local METER_STEP = 100
Host.Meter = { limit = METER_LIMIT, worst = {} }

-- THE STUB'S OWN WORK IS NOT THE RUNTIME'S. A page send here walks the payload
-- to count its nodes and the stub `json` encodes in Lua, where the platform
-- does both natively. So each tick of the hook is charged to whatever was
-- running when it fired, and a tick that landed in this file is not charged.
local HOST_SOURCE = debug.getinfo(1, 'S').short_src

-- The open counters per thread. Nested sites -- a job inside the pass, a
-- handler a handler called -- each keep their own count and all of them are
-- charged, so the pass still reads as the one resume it is on the platform.
local counters = setmetatable({}, { __mode = 'k' })

local function meterSite(fn)
	local info = debug.getinfo(fn, 'S')
	return info and ('%s:%d'):format(info.short_src, info.linedefined) or '?'
end

local function meterOpen(thread)
	local open = counters[thread]
	if open == nil then
		open = {}
		counters[thread] = open
	end
	local counter = { spent = 0 }
	open[#open + 1] = counter
	if #open == 1 then
		debug.sethook(thread, function()
			local info = debug.getinfo(2, 'S')
			if info ~= nil and info.short_src == HOST_SOURCE then return end
			for index = 1, #open do open[index].spent = open[index].spent + METER_STEP end
		end, '', METER_STEP)
	end
	return counter
end

local function meterClose(thread, counter, site)
	local open = counters[thread]
	for index = #open, 1, -1 do
		if open[index] == counter then table.remove(open, index) break end
	end
	if #open == 0 then debug.sethook(thread) end
	local worst = Host.Meter.worst
	if counter.spent > (worst[site] or 0) then worst[site] = counter.spent end
end

-- Runs `fn` counted under `label` and the place it was defined.
local function metered(label, fn, ...)
	local thread = coroutine.running()
	local counter = meterOpen(thread)
	local results = table.pack(pcall(fn, ...))
	meterClose(thread, counter, label .. ' ' .. meterSite(fn))
	if not results[1] then error(results[2], 0) end
	return table.unpack(results, 2, results.n)
end

-- Wraps a function the runtime hands over so every call to it is counted.
local function meterWrap(label, fn)
	if METER_LIMIT == nil or type(fn) ~= 'function' then return fn end
	return function(...) return metered(label, fn, ...) end
end

-- Resumes one client thread, counted, under where it was made, where it
-- resumed and where it yielded next.
local function meterResume(thread, origin)
	if METER_LIMIT == nil or origin == nil then return coroutine.resume(thread) end
	local function at()
		local info = coroutine.status(thread) == 'suspended' and debug.getinfo(thread, 2, 'Sl') or nil
		return info and ('%s:%d'):format(info.short_src, info.currentline) or nil
	end
	local from = at() or 'start'
	local counter = meterOpen(thread)
	local results = table.pack(coroutine.resume(thread))
	meterClose(thread, counter, ('thread %s: %s -> %s'):format(origin, from, at() or 'end'))
	return table.unpack(results, 1, results.n)
end

--- Counts every job the client scheduler is given, by name, when the meter is
--- on. Called by the test boot once `core/client/scheduler.lua` has loaded.
-- @author dop42
-- @param scheduler table OPX.Scheduler
function Host.MeterJobs(scheduler)
	if METER_LIMIT == nil or type(scheduler) ~= 'table' or type(scheduler.Every) ~= 'function' then return end
	local every = scheduler.Every
	scheduler.Every = function(name, intervalMs, step)
		return every(name, intervalMs, meterWrap('job ' .. tostring(name), step))
	end
end

--- Builds a fresh environment carrying the globals the platform installs.
-- @author dop42
-- @param side string 'server' or 'client'
-- @param database table|nil the `MySQL` bridge, absent by default
-- @return table env
-- @return table log every line the runtime wrote, by level
function Host.Environment(side, database)
	local log = { debug = {}, info = {}, warn = {}, error = {} }
	local threads = {}
	-- Where each client thread was made, for the budget meter.
	local threadOrigins = setmetatable({}, { __mode = 'k' })
	local handlers = {}
	local commands = {}
	local netEvents = {}
	local clientEvents = {}
	local serverEvents = {}
	local clock = 0
	-- Forward-declared: the host globals below close over them, and a local
	-- declared after them would leave those closures pointing at a global
	-- instead. The marker, keyboard and ACL stubs close over these four, and so
	-- does `vehicles`: a spawn stub that read a global `vehicles` recorded the
	-- creation and then raised, so every bring-out was answered as a refusal
	-- while the vehicle it created sat in the world.
	local control
	local markers, input, acl, keyMappings, vehicles, vehicleCreates, vehicleRemoves, seats
	local bodies, effects, travels, notices, placement, lifts, trips
	-- The blue holocall eye-glow leases, by player id. A REAL LEASE STORE and
	-- not an accepting stub, for the reason the bag store above gives about
	-- itself: `modules/calls` renews a bounded lease every sweep, releases it on
	-- every exit and has a watchdog that re-takes one the platform dropped, and
	-- a stub that answered `true` and kept nothing could not tell any of those
	-- three apart -- nor a call that lit both parties from one that lit neither.
	local holocall, voice
	local plates, watchers
	local world, lives, gate, generations, carried, environment
	local blips, hud, loadscreen

	-- The thirteen canonical stock-HUD components, in the platform's own order,
	-- and every alias `setVisible`/`isVisible` accept for them. Both are the
	-- catalogue's, not this file's invention: a stub that answered for a name the
	-- engine does not know would let a typo in `config/hud.lua` pass here and
	-- fail in the game as `invalid_hud_component`.
	local HUD_COMPONENTS = {
		'minimap', 'compass', 'clock', 'health', 'stamina', 'weapon', 'speedometer',
		'questTracker', 'phone', 'scanner', 'vanillaNotifications', 'crosshair', 'hubMenu',
	}
	local HUD_CANONICAL = {
		map = 'minimap', radar = 'minimap', time = 'clock', hp = 'health',
		ammo = 'weapon', weapons = 'weapon', weaponammo = 'weapon',
		speed = 'speedometer', quest = 'questTracker', tracker = 'questTracker',
		objectives = 'questTracker', vision = 'scanner', visionmode = 'scanner',
		notifications = 'vanillaNotifications', notification = 'vanillaNotifications',
		toasts = 'vanillaNotifications', reticle = 'crosshair', reticule = 'crosshair',
		hub = 'hubMenu',
	}
	for _, name in ipairs(HUD_COMPONENTS) do HUD_CANONICAL[name:lower()] = name end

	-- The live tunable values, by key: what `Open77.tunables.declare` hands back
	-- and what `control.tunables` lets a test move while the runtime is up.
	local tunables = {}

	-- Replicated state bags, by `<kind>:<id>`. A REAL store and not an accepting
	-- stub: the runtime skips a write whose value has not moved, and a `set` that
	-- always answered true without keeping anything would make that skip -- and
	-- every read after it -- untestable.
	local bags = {}

	-- One bag handle. The five method names shadow the keys of the same name, which
	-- is the platform's own rule and the one thing a caller can get wrong here.
	-- A LIVE onChange. The stub answered a handle and never called anybody, on
	-- the argument that a delta only arrives from the other side of a wire that
	-- does not exist here. True of the wire, and it made every consumer of a
	-- replicated key untestable -- which is how a character name could be
	-- written correctly by the server for months with nothing reading it.
	-- Writes announce synchronously: the platform delivers on a tick boundary,
	-- and a test that pumps sees the same order either way.
	local function announce(kind, id, key, value)
		for _, entry in pairs(watchers.byId) do
			local wants = entry.selector == nil or entry.selector == kind
			if wants and (entry.key == nil or entry.key == key) then
				pcall(entry.handler, { kind = kind, id = tostring(id) }, key, value)
			end
		end
	end

	local function bagFor(kind, id)
		local slot = ('%s:%s'):format(kind, tostring(id))
		bags[slot] = bags[slot] or {}
		local methods = {
			set = function(_, key, value)
				bags[slot][key] = value
				announce(kind, id, key, value)
				return true
			end,
			clear = function(_, key)
				if key == nil then
					local had = bags[slot]
					bags[slot] = {}
					for name in pairs(had) do announce(kind, id, name, nil) end
					return true
				end
				if bags[slot][key] == nil then return false, 'unknown_bag' end
				bags[slot][key] = nil
				announce(kind, id, key, nil)
				return true
			end,
			get = function(_, key) return bags[slot][key] end,
			all = function()
				local out = {}
				for key, value in pairs(bags[slot]) do out[key] = value end
				return out
			end,
			revision = function() return 1 end,
			selector = function() return { kind = kind, id = tostring(id) } end,
		}
		return setmetatable({}, {
			__index = function(_, key) return methods[key] or bags[slot][key] end,
		})
	end

	-- Typed resource-local KVP, including atomic claims. The backing table is
	-- exposed on control for integration assertions after the host is created.
	local kvp = {}
	local Open77 = {
		log = {
			debug = function(line) log.debug[#log.debug + 1] = tostring(line) end,
			info = function(line) log.info[#log.info + 1] = tostring(line) end,
			warn = function(line) log.warn[#log.warn + 1] = tostring(line) end,
			error = function(line) log.error[#log.error + 1] = tostring(line) end,
		},
		time = { monotonic = function() return clock / 1000 end,
			unix = function() return math.floor(clock / 1000) end },
		kvp = {
			get = function(key, fallback) if kvp[key] == nil then return fallback end; return kvp[key] end,
			set = function(key, value) kvp[key] = value; return true end,
			setIfAbsent = function(key, value) if kvp[key] ~= nil then return false end; kvp[key] = value; return true end,
			compareAndSet = function(key, expected, replacement)
				local held = kvp[key]
				if type(held) ~= type(expected) or held ~= expected then return false end
				if type(held) == 'number' and math.type(held) ~= math.type(expected) then return false end
				kvp[key] = replacement
				return true
			end,
		},
		exports = { call = function() return nil, 'no_host' end },

		-- `Open77.state` holds two unrelated things and the platform says so: the
		-- resource-private blob that survives a reload, and the replicated bags.
		--
		-- A REAL BLOB, AND ONE THAT CAN REFUSE. `save` answered true and kept
		-- nothing, `load` answered nil forever: a module could not be shown its
		-- own carried state coming back, so every `restoreState` in the runtime
		-- took its cold-start path in every test and the whole adoption branch
		-- -- protocol check, bounds, the refusal that drops all of it -- was
		-- unreachable. `control.carried` is the blob; set `carried.refuse` to a
		-- string and `save` answers `false, reason` the way a host with no room
		-- for it does.
		state = {
			save = function(value)
				if carried.refuse ~= nil then return false, tostring(carried.refuse) end
				-- Through JSON, because that is what the platform stores it as:
				-- a blob carrying a function or a cycle would not survive, and a
				-- stub keeping the live table by reference would hide that.
				carried.blob = json.decode(json.encode(value))
				carried.writes[#carried.writes + 1] = carried.blob
				-- THE LAST FEW WRITES, NOT ALL OF THEM, for the reason the thread
				-- list below is compacted: every periodic save of a whole section
				-- kept its blob here, so the list was memory the RUNTIME never
				-- holds, and the hostile battery's growth check measured it --
				-- its array doubling past 16384 entries read as a +256 KB leak on
				-- whichever door happened to be running when the count crossed.
				if #carried.writes > 64 then table.remove(carried.writes, 1) end
				return true
			end,
			load = function() return carried.blob end,
			clear = function() carried.blob = nil; return true end,

			global = bagFor('global', 0),
			player = function(id) return bagFor('player', id) end,
			entity = function(kind, id) return bagFor(kind, id) end,
			localPlayer = function() return bagFor('player', 1) end,

			onChange = function(selector, key, handler)
				if type(handler) ~= 'function' then return nil, 'invalid_handler' end
				if selector ~= nil and type(selector) ~= 'string' then
					return nil, 'invalid_state_selector'
				end
				if key ~= nil and type(key) ~= 'string' then return nil, 'invalid_state_key' end
				if watchers.refuse ~= nil then return nil, tostring(watchers.refuse) end
				watchers.next = watchers.next + 1
				watchers.byId[watchers.next] =
					{ selector = selector, key = key, handler = handler }
				return watchers.next
			end,
			offChange = function(handle)
				if watchers.byId[handle] == nil then return false, 'unknown_watcher' end
				watchers.byId[handle] = nil
				return true
			end,
		},

		-- `notifications` WAS DECLARED TWICE IN THIS TABLE, here and again near
		-- the bottom. Lua keeps the last one, so this key was dead: the
		-- swallowing `send = function() return true end` that stood here read
		-- like the live stub and was not, and anybody correcting it would have
		-- changed nothing. The real one, which records every toast, is the only
		-- one now.

		-- One declaration per resource, answering a live table the runtime reads
		-- through. A host that does not install this at all is the other case the
		-- runtime has to survive, so tests can clear it.
		--
		-- THE PROXY ANSWERS VALUES, AND THIS ANSWERED THE DECLARATION. `declare`
		-- takes `{ KEY = { value = 750, type = 'integer', ... } }` and the real
		-- host hands back a proxy where `proxy.KEY` is 750; this stub handed back
		-- the block itself, so `proxy.KEY` was the SPEC TABLE. `OPX.Tune.Number`
		-- tests what it reads with `IsFinite`, a table is not finite, and so every
		-- tunable in the suite quietly read as the caller's floor -- which for
		-- every rate limit in this runtime is 0, meaning OFF. That is why a staff
		-- menu shipped tripping its own refresh floor on ordinary navigation with
		-- a green suite behind it, and why the elevators' REQUESTS_PER_WINDOW came
		-- out 0 -- the first floor request any player made was rate-limited before
		-- it was looked at. No test could see a floor at all.
		--
		-- The table is the live one and is handed to the test through
		-- `control.tunables`, so a test can move a value the way an operator moves
		-- it from the panel.
		tunables = {
			declare = function(block)
				-- A spec that is a bare value rather than a table is taken as
				-- the value: `declare` accepts both and a stub that did not
				-- would raise where the real host answers.
				for key, spec in pairs(block) do
					tunables[key] = type(spec) == 'table' and spec.value or spec
				end
				return tunables
			end,
		},

		-- THE READINESS GATE, AND IT REALLY HOLDS. Five constants stood here and
		-- one of them was inverted:
		--
		--   `isReady` answered false for everybody. The card is explicit the
		--   other way -- "a player the host does not know is reported ready, so
		--   an unknown id never blocks a mode forever" -- so every gate in the
		--   suite read SHUT, `Players.GateOpen` was false for every player, and
		--   the eight guards in `core/server/gate.lua` all sat behind a door
		--   nothing could open.
		--
		--   `status` answered nil, which made the lost-session recovery in
		--   `Gate.Release` -- the branch that asks the host who is holding when
		--   this VM has forgotten -- permanently dead code.
		--
		--   `hold` answered a constant 1, so a stale session token and a fresh
		--   one compared equal and the recycled-player-id race the file exists
		--   to prevent was unobservable.
		--
		--   `participate` and `release` never refused, so neither refusal path
		--   was reachable.
		--
		-- A slot becomes KNOWN when `control.Admit` puts an account on it, and
		-- its session token is bumped then -- which is what makes a release
		-- carrying the previous connection's token land on a mismatch, exactly
		-- as it would on the platform.
		ready = {
			participate = function(declaration)
				gate.participations[#gate.participations + 1] = declaration
				if gate.refuseParticipate ~= nil then return false, gate.refuseParticipate end
				return true
			end,

			-- Answers the PLAYER's session, not a per-hold token: the card says
			-- "returns the player's `session`, which later identifies the hold
			-- being released", and refreshing an existing hold restarts its
			-- deadline rather than issuing a new number.
			hold = function(playerId, reason)
				local id = tonumber(playerId) or playerId
				if gate.refuseHold ~= nil then return nil, gate.refuseHold end
				local session = gate.sessions[id]
				if session == nil then return nil, 'unknown_player' end
				local held = gate.holds[id] or {}
				gate.holds[id] = held
				held['opx_infinity'] = { reason = tostring(reason or ''), at = clock }
				return session
			end,

			-- A session that no longer matches is DROPPED rather than releasing a
			-- newer hold -- the one rule that keeps a late release from opening
			-- the gate for whoever reconnected onto the same slot.
			release = function(playerId, session, note)
				local id = tonumber(playerId) or playerId
				gate.releases[#gate.releases + 1] =
					{ playerId = id, session = session, note = note }
				if gate.refuseRelease ~= nil then return false, gate.refuseRelease end
				if session ~= nil and gate.sessions[id] ~= nil and session ~= gate.sessions[id] then
					return false, 'session_mismatch'
				end
				-- A SESSION MISMATCH IS THE ONLY REFUSAL. Releasing when this
				-- resource holds nothing answers TRUE, because the postcondition
				-- -- "we are not holding this player" -- is satisfied, and
				-- because `OPX.Gate.Release` documents itself as idempotent and
				-- "safe for a player who never held one". Modelling that as a
				-- refusal would make the runtime log an error on every ordinary
				-- double release and would make its own promise a lie.
				local held = gate.holds[id]
				if held ~= nil then held['opx_infinity'] = nil end
				return true
			end,

			status = function(playerId)
				local id = tonumber(playerId) or playerId
				local session = gate.sessions[id]
				local holds = {}
				for resource, held in pairs(gate.holds[id] or {}) do
					holds[#holds + 1] = { resource = resource, reason = held.reason,
						ageMs = clock - held.at }
				end
				table.sort(holds, function(left, right) return left.resource < right.resource end)
				return {
					known = session ~= nil,
					ready = #holds == 0,
					session = session,
					ageMs = 0,
					holds = holds,
				}
			end,

			-- An UNKNOWN id is ready. That is the card's rule and the opposite of
			-- what stood here.
			isReady = function(playerId)
				local id = tonumber(playerId) or playerId
				if gate.sessions[id] == nil then return true end
				return next(gate.holds[id] or {}) == nil
			end,
		},

		-- Spawned vehicles. `create` answers an opaque engine id, which is stored
		-- as-is and never put through `tonumber`: these are 64-bit and would not
		-- survive it.
		--
		-- Every creation is recorded, because WHERE a vehicle was created is the
		-- whole point of a garage marker: a test that only saw an id could not
		-- tell a vehicle placed on the marker from one placed beside the player.
		vehicles = {
			-- A CONSTANT TABLE, NOT A CALL, and the platform's own ten values.
			-- The card is explicit: `Open77.vehicles.flags` is a public constant
			-- table, "reasons it can return: none (a table, not a call)". This
			-- stub was `function() return {} end`, so `masks()` in
			-- `modules/admin/server/vehicles.lua` took its callable branch, got
			-- an empty table back, and every configured flag resolved
			-- `unknown_flag` -- the exact failure that file's own comment warns
			-- about, manufactured by the harness and certified green. Because it
			-- is a table here, the branch the runtime will really take on this
			-- build is the branch the suite exercises.
			flags = { engineOn = 1, locked = 2, destroyed = 4, exploded = 8,
				invulnerable = 16, immortal = 32, lightsOn = 64, highBeams = 128,
				sirenOn = 256, paintApplied = 512 },

			create = function(options)
				vehicleCreates[#vehicleCreates + 1] = options
				if vehicles.refuse ~= nil then return nil, tostring(vehicles.refuse) end
				-- A DISTINCT id per creation, the way the engine hands them out. A stub
				-- that answered one constant made every live vehicle the same vehicle
				-- to anything matching by id -- the seat oracle among them -- so a
				-- player sitting in one car could be read as sitting in another.
				vehicles.next = (vehicles.next or 0) + 1
				local id = ('0x%016x'):format(vehicles.next)
				-- WHAT EXISTS, not only what was asked for. `vehicleCreates` is
				-- the request log and it never shrinks; `world` is the set of
				-- vehicles that are in the world NOW, which is the only thing
				-- `all` can honestly answer. A garage exit is blocked by a car
				-- that exists, not by a car that was once created.
				vehicles.world[#vehicles.world + 1] = {
					id = id,
					record = options.record,
					position = type(options.position) == 'table'
						and { x = options.position.x, y = options.position.y,
							z = options.position.z } or nil,
					bucket = options.bucket or 0,
					-- The flags a creation asked for, as the engine's own
					-- bitfield: `create` takes the nine flag names as booleans
					-- in its definition and a snapshot reports them in `flags`.
					-- A showroom car that asked to be locked and is not is the
					-- failure the dealership warns about, and it is only
					-- visible if the two are connected here.
					flags = (options.locked and 2 or 0)
						+ (options.engineOn and 1 or 0)
						+ (options.lightsOn and 64 or 0),
					persistent = options.persistent == true,
				}
				return id
			end,

			-- Every vehicle that exists, oldest first, optionally of one routing
			-- bucket. The real call filters by bucket when it is given one and
			-- answers everything when it is not.
			all = function(bucket)
				local listed = {}
				for index = 1, #vehicles.world do
					local car = vehicles.world[index]
					if bucket == nil or car.bucket == bucket then listed[#listed + 1] = car end
				end
				return listed
			end,
			-- What a live vehicle projects, FOR THE ID THAT WAS ASKED ABOUT. This
			-- ignored its argument entirely and answered one shared snapshot, so
			-- two live vehicles were the same vehicle to everything that reads
			-- one: per-vehicle occupancy could not be distinguished, and neither
			-- could a read-before-remove that names the wrong car.
			--
			-- `vehicles.byId[id]` is the per-vehicle store and is checked first.
			-- `vehicles.snapshot` is kept as the fallback for the id-agnostic
			-- tests that predate the store -- an unknown id still answers nil
			-- when neither is set, which is the other answer a caller must
			-- survive.
			-- `world` is read LAST, after `snapshot`, and the order is load-bearing:
			-- a test that sets `snapshot` is saying "every live vehicle projects
			-- this", which is how the occupied-recall case is written, and a
			-- world entry taking precedence would silently answer the created
			-- car instead. With no snapshot set, a vehicle answers what it was
			-- created as -- which is what lets a caller read back a flag it
			-- asked for.
			get = function(id)
				local known = id ~= nil and vehicles.byId[id]
				if known ~= nil then return known end
				if vehicles.snapshot ~= nil then return vehicles.snapshot end
				for index = 1, #vehicles.world do
					if vehicles.world[index].id == id then return vehicles.world[index] end
				end
				return nil
			end,
			-- Recorded, because "the vehicle was put away" and "it is still in the
			-- world with a row that says stored" read identically from a return
			-- value. The comment above has always promised this list.
			remove = function(id)
				vehicleRemoves[#vehicleRemoves + 1] = id
				-- And it stops existing, which is the half a removal log cannot
				-- say: a garage exit a car was just recalled off has to read as
				-- free again on the very next pass.
				for index = #vehicles.world, 1, -1 do
					if vehicles.world[index].id == id then table.remove(vehicles.world, index) end
				end
				return true
			end,
			-- RECORDED, for the same reason `remove` is: "the flags were written"
			-- and "the runtime meant to write them" read identically off a bare
			-- `true`, and the mask a flag resolves to is the whole question when
			-- the bits come from the host rather than from a private copy.
			update = function(id, patch)
				vehicles.updates[#vehicles.updates + 1] = { id = id, patch = patch }
				if vehicles.refuseUpdate ~= nil then return false, vehicles.refuseUpdate end
				return true
			end,
			-- THE ENTRY LOCK, kept in the vehicle's own `flags` bit (2) and not in a
			-- private table beside it: the card says `setLocked` moves only
			-- `VehicleStateFlags.Locked`, and a snapshot reports that bit, so a lock
			-- set here is a lock `get(id).flags` shows and one the admin flag
			-- command's write is read back through. An unknown vehicle answers nil
			-- from `isLocked` and `false, vehicle_not_found` from `setLocked`, which
			-- are the card's answers.
			isLocked = function(id)
				local car = id ~= nil and (vehicles.byId[id] or nil)
				if car == nil then
					for index = 1, #vehicles.world do
						if vehicles.world[index].id == id then car = vehicles.world[index] end
					end
				end
				if car == nil then return nil end
				return ((tonumber(car.flags) or 0) & 2) ~= 0
			end,
			setLocked = function(id, locked)
				local car = id ~= nil and (vehicles.byId[id] or nil)
				if car == nil then
					for index = 1, #vehicles.world do
						if vehicles.world[index].id == id then car = vehicles.world[index] end
					end
				end
				if car == nil then return false, 'vehicle_not_found' end
				if type(locked) ~= 'boolean' then return false, 'invalid_argument' end
				local bits = tonumber(car.flags) or 0
				car.flags = locked and (bits | 2) or (bits & ~2)
				vehicles.locks[#vehicles.locks + 1] = { id = id, locked = locked }
				return true
			end,
			-- THE ENGINE BIT, kept in the vehicle's own `flags` (1) like the lock
			-- above: the card says `setEngine` writes only `engineOn`, and a
			-- snapshot reports it there, so a cut is a cut the next read sees.
			-- Every call is recorded in `vehicles.engines`, because "the engine
			-- was cut" and "the engine happened to be off" read alike otherwise.
			setEngine = function(id, on)
				local car = id ~= nil and (vehicles.byId[id] or nil)
				if car == nil then
					for index = 1, #vehicles.world do
						if vehicles.world[index].id == id then car = vehicles.world[index] end
					end
				end
				if car == nil then return false, 'vehicle_not_found' end
				if type(on) ~= 'boolean' then return false, 'invalid_argument' end
				local bits = tonumber(car.flags) or 0
				car.flags = on and (bits | 1) or (bits & ~1)
				vehicles.engines[#vehicles.engines + 1] = { id = id, on = on }
				return true
			end,
			triggerHorn = function() return true end,
			getDamage = function() return {} end,
			setDamage = function() return true end,
			-- The seat THIS client is in, which is what tells the strip whether the
			-- key is about to take a vehicle out or put one away. Slot 1 is the
			-- local player here, the same convention `state.localPlayer` uses.
			getPlayerSeat = function() return seats[1] end,
		},

		-- Network elevators. A REAL flag store and not an accepting stub, because
		-- the one thing this module's job gate rests on is that an adopted cabin
		-- comes up LOCKED: the platform turns a press of the vanilla in-cabin floor
		-- button into a player request, and `locked` is the only bit that refuses
		-- one. A `setFlags` that answered true without keeping anything would make
		-- the difference between a gated lift and an ungated one invisible here,
		-- which is exactly the bug the tests below exist to catch.
		--
		-- The constants carry the platform's own values -- powered 1, locked 2,
		-- interactionAllowed 4, doorsClosed 8 -- from the `setFlags` card, so a mask
		-- assembled by the runtime is compared against the numbers the engine uses
		-- and not against a private set that would agree with any of them.
		elevators = {
			flags = { powered = 1, locked = 2, interactionAllowed = 4, doorsClosed = 8 },

			-- Engine hashes are opaque 64-bit values and never go through
			-- `tonumber`; the id the host hands back for one is a plain integer, and
			-- the two are different things the runtime must not confuse.
			adopt = function(definition)
				lifts.adopts[#lifts.adopts + 1] = definition
				if lifts.refuse ~= nil then return nil, tostring(lifts.refuse) end
				lifts.next = lifts.next + 1
				local id = lifts.next
				lifts.byId[id] = {
					id = id,
					engineEntity = definition.engineEntity,
					bucket = definition.bucket or 0,
					floorCount = definition.floorCount,
					activeFloor = definition.initialFloor or 0,
					phase = 'idle',
					x = definition.position and definition.position.x,
					y = definition.position and definition.position.y,
					z = definition.position and definition.position.z,
					-- The host's OWN default when the caller names none: powered plus
					-- interaction allowed, per the `adopt` card. A stub that defaulted
					-- to locked would have passed the runtime as it stood before this
					-- change, which is the whole point of writing it out.
					--
					-- `ignoreAdoptFlags` is the build that predates the field and drops
					-- it in silence. That is not a hypothetical: it is the reason the
					-- runtime reads the mask back instead of trusting its own request,
					-- and without it here that read-back could never be exercised.
					flags = (not lifts.ignoreAdoptFlags and definition.flags) or 5,
				}
				return id
			end,

			get = function(id) return lifts.byId[id] end,

			all = function(bucket)
				local rows = {}
				for _, lift in pairs(lifts.byId) do
					if bucket == nil or lift.bucket == bucket then rows[#rows + 1] = lift end
				end
				-- Sorted, because `pairs` order would reshuffle which lift the
				-- runtime's re-claim scan meets first between runs.
				table.sort(rows, function(left, right) return left.id < right.id end)
				return rows
			end,

			-- REPLACES the mask, the way the real one documents itself. Set
			-- `lifts.refuseFlags` to answer false, which is how a cabin owned by
			-- another resource refuses a lock it does not own.
			setFlags = function(id, flags)
				local lift = lifts.byId[id]
				if lift == nil then return false, 'no_such_elevator' end
				if lifts.refuseFlags then return false, 'not_owner' end
				lift.flags = flags
				lifts.flagWrites[#lifts.flagWrites + 1] = { id = id, flags = flags }
				return true
			end,

			goTo = function(id, floor)
				local lift = lifts.byId[id]
				if lift == nil then return false end
				lifts.trips[#lifts.trips + 1] = { id = id, floor = floor }
				lift.targetFloor = floor
				return true
			end,

			remove = function(id)
				lifts.removes[#lifts.removes + 1] = id
				lifts.byId[id] = nil
				return true
			end,

			-- What a client's scan sees. Empty by default: a world with no streamed
			-- lift in it is the honest answer for a harness with no world.
			nearby = function() return lifts.nearby end,
		},

		-- World markers. The stub validates exactly what `client/src/api/Markers.cpp`
		-- validates -- four styles, two shapes, radius 0.1..50, maximumDistance
		-- 1..500 -- so a marker the engine would refuse under `unsupported_style`
		-- fails here rather than silently in a live session. A marker that is never
		-- removed is the other half of the same class of bug, so `list` is real.
		-- THE VOICE STACK. Server-side channel ownership and the one client call
		-- the calls module makes. Modelled rather than accepted: a stub that
		-- answered true to everything would have let the call ship with the audio
		-- half missing a second time, and the questions a test needs to ask are
		-- about MEMBERSHIP -- who is on which channel, and is the channel still
		-- there -- not about how many times a function was called.
		voice = {
			createChannel = function(options)
				if voice.absent then return nil, 'voice_unavailable' end
				if voice.refuse ~= nil then return nil, voice.refuse end
				-- "`options` is required and must be a table", verbatim from the
				-- card, and a refusal a caller passing nothing would deserve.
				if type(options) ~= 'table' then return nil, 'options_required' end
				local id = ('chan-%d'):format(voice.next)
				voice.next = voice.next + 1
				voice.channels[id] = { id = id, name = options.name, members = {} }
				return { id = id, name = options.name }
			end,
			removeChannel = function(channelId)
				if voice.channels[channelId] == nil then return false, 'no_such_channel' end
				voice.channels[channelId] = nil
				return true
			end,
			addPlayer = function(channelId, playerId, options)
				local channel = voice.channels[channelId]
				if channel == nil then return false, 'no_such_channel' end
				local id = tonumber(playerId) or playerId
				-- The real host will not put a slot nobody is on into a channel,
				-- and a stub that did would hide a call added for a player who
				-- had already gone.
				if control.accounts[id] == nil then return false, 'no_such_player' end
				local speak = true
				local listen = true
				if type(options) == 'table' then
					if options.canSpeak == false then speak = false end
					if options.canListen == false then listen = false end
				end
				channel.members[id] = { canSpeak = speak, canListen = listen }
				return true
			end,
			removePlayer = function(channelId, playerId)
				local channel = voice.channels[channelId]
				if channel == nil then return false, 'no_such_channel' end
				channel.members[tonumber(playerId) or playerId] = nil
				return true
			end,
			-- The client half: what route this machine's frames take. `status`
			-- answers the PTT state a test staged, so a module that forces the
			-- microphone open is visible as a `transmit` of true that no test
			-- ever asked for.
			status = function()
				if voice.status == nil then return nil, 'voice_backend_unavailable' end
				return voice.status
			end,
			setTransmitting = function(enabled, intent)
				voice.transmit = { enabled = enabled, intent = intent }
				return true
			end,
		},

		nameplates = {
			set = function(playerId, options)
				local id = tonumber(playerId)
				if id == nil or id <= 0 then return false, 'invalid_argument' end
				if type(options) ~= 'table' then return false, 'invalid_argument' end
				local label = options.label
				if label ~= nil and type(label) ~= 'string' then return false, 'invalid_argument' end
				if plates.refuse ~= nil then return false, tostring(plates.refuse) end
				plates.byId[id] = options
				plates.set[#plates.set + 1] = { player = id, label = label }
				return true
			end,
			remove = function(playerId)
				local id = tonumber(playerId)
				if id == nil then return false, 'invalid_argument' end
				if plates.byId[id] == nil then return false, 'unknown_override' end
				plates.byId[id] = nil
				plates.removed[#plates.removed + 1] = id
				return true
			end,
		},
		markers = {
			create = function(options)
				if type(options) ~= 'table' or type(options.position) ~= 'table' then
					return nil, 'invalid_argument'
				end
				local styles = { interaction = true, objective = true, spawn = true, danger = true }
				-- The op77.83 catalogue: eight shapes, from the `markers` guide.
				local shapes = { ring = true, cylinder = true, checkpoint = true, arrow = true,
					chevron = true, cone = true, diamond = true, sphere = true }
				if not styles[tostring(options.style)] then return nil, 'unsupported_style' end
				if not shapes[tostring(options.shape)] then return nil, 'unsupported_shape' end
				local radius = tonumber(options.radius)
				if radius == nil or radius < 0.1 or radius > 50.0 then
					return nil, 'invalid_argument'
				end
				local maxDistance = tonumber(options.maxDistance)
				if maxDistance == nil or maxDistance < 1.0 or maxDistance > 500.0 then
					return nil, 'invalid_argument'
				end
				if markers.refuse ~= nil then return nil, tostring(markers.refuse) end
				markers.next = (markers.next or 0) + 1
				local id = 'marker-' .. tostring(markers.next)
				markers.byId[id] = options
				markers.created[#markers.created + 1] = id
				return id
			end,
			update = function(id, patch)
				if markers.byId[id] == nil then return false, 'unknown_marker' end
				if type(patch) == 'table' then
					for key, value in pairs(patch) do markers.byId[id][key] = value end
				end
				return true
			end,
			remove = function(id)
				if markers.byId[id] == nil then return false, 'unknown_marker' end
				markers.byId[id] = nil
				markers.removed[#markers.removed + 1] = id
				return true
			end,
			clear = function()
				for id in pairs(markers.byId) do markers.byId[id] = nil end
				return true
			end,
			list = function()
				local out = {}
				for id in pairs(markers.byId) do out[#out + 1] = id end
				table.sort(out)
				return out
			end,
		},

		-- Vanilla map pins. THE REFUSALS ARE THE POINT OF THIS STUB. A blip that
		-- the engine turns away is invisible and silent -- `create` answers `nil`
		-- plus a reason and nothing is logged anywhere the operator can read --
		-- which is the exact failure `modules/blips` was written to end, so a stub
		-- that only modelled success would let every one of them through green.
		--
		-- What is modelled, and each is a real 2.31 refusal from the platform
		-- guide rather than a shape invented here:
		--   * `color`, `colour`, `alpha`, `opacity`, `scale`, `shortRange` and
		--     `category` are refused BY NAME as `unsupported_option:<key>`, and
		--     `kind = "radius"` as `unsupported_kind:radius`. A mappin carries no
		--     such field; opacity and scale live on the UI profile the SPRITE
		--     resolves, shared by every pin using it.
		--   * `range` outside 0..4000 is `invalid_range`.
		--   * `title` is capped at 128 bytes and `description` at 1024.
		--   * the per-resource quota is 128; the 129th create is refused.
		--   * `blips.permission = true` answers every call
		--     `permission_denied:ui.vanilla.map`, which is how an UNDECLARED
		--     client permission behaves -- silently, with the server journal
		--     saying nothing at all.
		-- `blips.refuse` is the markers stub's escape hatch, for "the API is there
		-- and said no" without naming a particular cause.
		--
		-- IDS ARE DECIMAL STRINGS AND NEVER NUMBERS. The platform's handles are
		-- 64-bit and its guide says in as many words not to put them through
		-- `tonumber`; a stub handing back integers would let a caller that does
		-- pass here and lose the handle in the game.
		blips = {
			create = function(options)
				if blips.permission then return nil, 'permission_denied:ui.vanilla.map' end
				if type(options) ~= 'table' then return nil, 'invalid_argument' end
				if type(options.position) ~= 'table' and options.entity == nil then
					return nil, 'invalid_argument'
				end
				for _, key in ipairs({ 'color', 'colour', 'alpha', 'opacity', 'scale',
					'shortRange', 'category' }) do
					if options[key] ~= nil then return nil, 'unsupported_option:' .. key end
				end
				if options.kind ~= nil then
					if tostring(options.kind) == 'radius' then return nil, 'unsupported_kind:radius' end
					return nil, 'unsupported_option:kind'
				end
				if options.range ~= nil then
					local range = tonumber(options.range)
					if range == nil or range < 0 or range > 4000 then return nil, 'invalid_range' end
				end
				if options.title ~= nil and #tostring(options.title) > 128 then
					return nil, 'invalid_argument'
				end
				if options.description ~= nil and #tostring(options.description) > 1024 then
					return nil, 'invalid_argument'
				end
				if options.title ~= nil and options.label ~= nil then
					return nil, 'invalid_argument'
				end
				if blips.refuse ~= nil then return nil, tostring(blips.refuse) end
				if blips.count >= 128 then return nil, 'blip_quota_exceeded' end
				blips.next = blips.next + 1
				-- DELIBERATELY PAST 2^53, which is the width a double carries
				-- exactly. Lua 5.4's own integers are 64-bit and would survive a
				-- `tonumber`, so this does not catch that on its own -- what it
				-- catches is the handle reaching anything that holds numbers as
				-- doubles, a WebUI payload or a JSON round trip, where the id comes
				-- back a DIFFERENT number and every lookup with it misses. The
				-- string-ness of the handle is asserted separately in `run.lua`.
				local id = ('%d'):format(9007199254740993 + blips.next)
				blips.byId[id] = options
				blips.count = blips.count + 1
				blips.created[#blips.created + 1] = id
				return id
			end,
			remove = function(id)
				if blips.permission then return false, 'permission_denied:ui.vanilla.map' end
				if type(id) ~= 'string' or blips.byId[id] == nil then return false, 'unknown_blip' end
				blips.byId[id] = nil
				blips.count = blips.count - 1
				blips.removed[#blips.removed + 1] = id
				return true
			end,
			clear = function()
				if blips.permission then return false, 'permission_denied:ui.vanilla.map' end
				for id in pairs(blips.byId) do
					blips.byId[id] = nil
					blips.removed[#blips.removed + 1] = id
				end
				blips.count = 0
				return true
			end,
			get = function(id)
				if blips.permission then return nil, 'permission_denied:ui.vanilla.map' end
				return blips.byId[id]
			end,
			list = function()
				if blips.permission then return nil, 'permission_denied:ui.vanilla.map' end
				local out = {}
				for id in pairs(blips.byId) do out[#out + 1] = id end
				table.sort(out)
				return out
			end,
			sprites = function()
				-- The one function in the namespace that checks no permission.
				return { { name = 'DefaultVariant', value = 0 } }
			end,
		},

		-- The keyboard. `isCaptured` answers what the test set, so a player typing
		-- into the chat box is a case a caller can actually be exercised against.
		input = {
			isCaptured = function() return input.captured == true end,
			keyFor = function(id) return input.keys[id] end,
			mappings = function()
				local out = {}
				for id, key in pairs(input.keys) do
					out[#out + 1] = { resource = 'opx_infinity', id = id, key = key }
				end
				return out
			end,
			isDown = function(key) return input.down[key] == true end,
		},

		-- `acl.read` is granted in the manifest, and the capture door asks the same
		-- question the command gate asks. Empty means refused, which is the shape
		-- every caller has to survive; `control.Allow` is how a test grants one.
		-- THE THREE REFUSALS THE CARD NAMES, and not a bare boolean. This
		-- answered `true`/`false` and nothing else, so a caller could not be
		-- shown the difference between "the ACL says no" and "the ACL could not
		-- be asked" -- and `permission_denied:acl.read`, `invalid_permission`
		-- and `invalid_player_id` were three documented answers no test could
		-- produce.
		--
		-- `acl.refuse` is a build where this resource does not hold `acl.read`:
		-- every question comes back denied WITH A REASON, which is the
		-- degradation `core/server/commands.lua` and the staff menu are both
		-- built around. `control.Allow` is still how a grant is made.
		acl = {
			isAllowed = function(playerId, permission)
				if acl.refuse ~= nil then return false, tostring(acl.refuse) end
				if type(permission) ~= 'string' or permission == '' then
					return false, 'invalid_permission'
				end
				-- The console is source 0 and is NOT a player here: the card is
				-- explicit that it answers `invalid_player_id` for it rather
				-- than yes, which is why `commands.lua` names the console
				-- instead of asking.
				local id = tonumber(playerId)
				if id == nil or id % 1 ~= 0 or id <= 0 then return false, 'invalid_player_id' end
				local granted = acl.granted
				if granted == nil then return false end
				local player = granted[tostring(playerId)]
				return player ~= nil and player[tostring(permission)] == true
			end,
		},

		-- A REAL BUCKET STORE. `getPlayer` answered a constant 0 and `setPlayer`
		-- kept nothing, so "the player moved to bucket N" was unobservable by any
		-- route: every `Buckets.Move` skipped its own no-op check, every
		-- `Buckets.Release` saw a player who was never in a selection bucket, and
		-- every bucket comparison anywhere in the suite was `0 == 0`. A bucket is
		-- the only thing standing between two instances of the same shop, so a
		-- harness that cannot tell them apart certifies a reach check that is not
		-- there. `control.Bucket` is how a test puts somebody in one.
		routingBuckets = {
			setPlayer = function(playerId, bucket)
				local id = tonumber(playerId) or playerId
				local value = tonumber(bucket)
				-- The host's own range, and the reason it is checked: a bucket id
				-- outside it is refused rather than stored, which is the answer
				-- `Buckets.Move` warns on and could never reach.
				if value == nil or value % 1 ~= 0 or value < 0 or value > 4294967295 then
					return false, 'invalid_bucket'
				end
				-- AND A SLOT NOBODY IS ON CANNOT BE MOVED. The real host refuses
				-- this and the stub used to accept it, which is why every
				-- departure filed `[bucket] N could not be moved … (unloaded)` at
				-- warn on the live server and not one test ever saw it: the one
				-- path that produces the line could not be reached from here.
				-- `control.Admit` is how a test says a slot is occupied, so its
				-- absence is the disconnect.
				if control.accounts[id] == nil then return false, 'no_such_player' end
				world.buckets[id] = value
				world.bucketWrites[#world.bucketWrites + 1] = { playerId = id, bucket = value }
				return true
			end,
			getPlayer = function(playerId)
				return world.buckets[tonumber(playerId) or playerId] or 0
			end,
			setPopulationEnabled = function(bucket, on)
				world.population[#world.population + 1] = { bucket = bucket, enabled = on }
				return true
			end,
			setLockdownMode = function(bucket, mode)
				world.lockdown[#world.lockdown + 1] = { bucket = bucket, mode = mode }
				return true
			end,
		},

		-- THE CLOCK ANSWERS A SNAPSHOT TABLE, not the number 0. The card is
		-- `{ day, hour, minute, second, totalSeconds, frozen }` or nil, and
		-- `modules/weather` guards its whole drift correction with
		-- `if type(live) == 'table'` -- so with a 0 here that branch was never
		-- once entered and the module re-applied the time on every single pass
		-- with nothing to say it was wrong. A REAL store, because the drift
		-- correction is a comparison between what the engine holds and what the
		-- server asked for, and a `setTime` that kept nothing made the two the
		-- same question.
		environment = {
			getTime = function()
				if environment.refuse ~= nil then return nil, environment.refuse end
				local total = environment.seconds % 86400
				return {
					day = environment.day,
					hour = math.floor(total / 3600),
					minute = math.floor(total % 3600 / 60),
					second = total % 60,
					totalSeconds = total,
					frozen = environment.timeFrozen,
				}
			end,
			setTime = function(hour, minute, second)
				if environment.refuseSet ~= nil then return false, environment.refuseSet end
				environment.seconds =
					((tonumber(hour) or 0) * 3600 + (tonumber(minute) or 0) * 60
						+ (tonumber(second) or 0)) % 86400
				environment.writes[#environment.writes + 1] = environment.seconds
				return true
			end,
			setTimeFrozen = function(held) environment.timeFrozen = held == true; return true end,
			setWeather = function(preset)
				environment.weather = preset
				return true
			end,
			setWeatherFrozen = function(held)
				environment.weatherFrozen = held == true
				return true
			end,
			isWeatherFrozen = function() return environment.weatherFrozen end,
		},

		players = {
			-- The admitted slots, which is what a server-side fan-out walks. An
			-- always-empty list would make "every client in the bucket was told"
			-- untestable, and a capture that told nobody would look the same as one
			-- that told everybody.
			all = function()
				local ids = {}
				for slot in pairs(control.accounts or {}) do
					local id = tonumber(slot)
					if id ~= nil then ids[#ids + 1] = id end
				end
				table.sort(ids)
				return ids
			end,
			-- The display name the host holds for a slot, and NOT a constant. It
			-- was `'player'` for everybody, which is a name with no control
			-- character in it and eight bytes long -- so `downed`'s strip and its
			-- 32-byte cut could never fire, and neither could any other caller's.
			-- `control.Rename` is how a test gives somebody a name the host would
			-- really hand over.
			name = function(playerId)
				local id = tonumber(playerId) or playerId
				if control.accounts[id] == nil then return nil end
				return world.names[id] or ('player-' .. tostring(id))
			end,

			-- WHERE THE PLAYER ACTUALLY IS, and nil for a slot the host does not
			-- know. This answered `{ x = 0, y = 0, z = 0, bucket = 0 }` for every
			-- id that was ever asked about, with no way to move it: all 26
			-- server-side call sites read the origin, every reach test compared
			-- origin against anchor, and every bucket comparison was `0 == 0`.
			-- Eight of the ten reach and bucket mutants in the audit survived on
			-- this one stub alone. The bucket comes from the routing store above,
			-- so a player the runtime moved reads as moved. `control.Stand` is
			-- how a test walks somebody somewhere.
			position = function(playerId)
				local id = tonumber(playerId) or playerId
				local at = world.positions[id]
				if at == nil then return nil end
				return { x = at.x, y = at.y, z = at.z, bucket = world.buckets[id] or 0 }
			end,

			-- THE RICH READ, 2.31.13+op77.67, and the only place on the server
			-- side a player's FACING can be had at all: `position` above answers
			-- `{ x, y, z, bucket }` and carries no yaw, which is why
			-- `/opx.admin.self.pos` printed a hardcoded `HEADING = 0.0` for as
			-- long as it existed.
			--
			-- Answers what the card says it answers: `playerId`, `bucket`,
			-- `fresh` and `ready` always; `position`, `heading` and its alias
			-- `yaw` only once the slot has reported. A slot this harness has
			-- never stood anywhere has NO position and NO heading, which is the
			-- case a caller has to survive and the case that would otherwise
			-- read as a player standing at the origin facing north.
			--
			-- `control.Stand` sets both, so a test can face somebody a way and
			-- read it back.
			get = function(playerId)
				local id = tonumber(playerId) or playerId
				if control.accounts[id] == nil then return nil, 'player_not_found' end
				local snapshot = { playerId = id, bucket = world.buckets[id] or 0,
					fresh = true, ready = true }
				local at = world.positions[id]
				if at ~= nil then
					snapshot.ageMs = 0
					snapshot.position = { x = at.x, y = at.y, z = at.z }
					local yaw = world.headings[id]
					if yaw ~= nil then
						snapshot.heading = yaw
						snapshot.yaw = yaw
					end
				end
				local named = world.names[id]
				if named ~= nil then snapshot.name = named end
				return snapshot
			end,

			-- A SNAPSHOT TABLE, not a string. The card answers
			-- `{ phase = alive|dead|revivepending|respawnpending|recovering }` or
			-- nil, and every consumer in this runtime type-checks for a table --
			-- so a stub answering `'alive'` made `Players.Alive` HARD FALSE for
			-- every player in the suite and `Players.MayAct` answer `false,
			-- 'dead'` everywhere. The whole inventory door sat behind a refusal
			-- the harness manufactured. `control.Life` sets a phase; a slot with
			-- no life state at all is the not-incarnated case, which is a real
			-- answer this host now gives and callers have to survive.
			getLifeState = function(playerId)
				local phase = lives[tonumber(playerId) or playerId]
				if phase == nil then return nil end
				return { phase = phase }
			end,
			isDead = function(playerId)
				return lives[tonumber(playerId) or playerId] == 'dead'
			end,
			-- The three life transitions really move the phase. They answered a
			-- bare `true` and changed nothing, so the placement sequence in
			-- `modules/character` -- kill, then respawn on the point -- could not
			-- be told from one that killed and left the body there.
			kill = function(playerId)
				local id = tonumber(playerId) or playerId
				if lives[id] == nil then return false, 'not_incarnated' end
				lives[id] = 'dead'
				world.transitions[#world.transitions + 1] = { playerId = id, verb = 'kill' }
				return true
			end,
			-- The canonical maximum. Recorded rather than swallowed: the whole
			-- point of a configurable pool is that a fraction lands against it,
			-- and a stub that answers true and keeps nothing cannot tell a body
			-- placed at full from one placed at 40 per cent.
			setMaxHealth = function(playerId, maximum)
				local id = tonumber(playerId) or playerId
				local wanted = tonumber(maximum)
				if wanted == nil or wanted < 1 then return false, 'invalid_argument' end
				world.maxHealth[id] = wanted
				return true
			end,
			respawn = function(playerId, position)
				local id = tonumber(playerId) or playerId
				if lives[id] == nil then return false, 'not_incarnated' end
				lives[id] = 'alive'
				if type(position) == 'table' then control.Stand(id, position) end
				world.transitions[#world.transitions + 1] = { playerId = id, verb = 'respawn',
					health = type(position) == 'table' and position.health or nil }
				return true
			end,
			revive = function(playerId)
				local id = tonumber(playerId) or playerId
				if lives[id] == nil then return false, 'not_incarnated' end
				lives[id] = 'alive'
				world.transitions[#world.transitions + 1] = { playerId = id, verb = 'revive' }
				return true
			end,
			setArmor = function() return true end,
			-- The seat a connection is sitting in, or nil. The marker key's whole
			-- behaviour turns on this answer -- it is what decides whether the key
			-- puts a vehicle away or brings one out -- so a suite that could not
			-- set it could not exercise half the door. `control.Seat` is the way.
			getVehicleSeat = function(playerId) return seats[tonumber(playerId) or playerId] end,

			-- The one native that hides a body. Recorded rather than accepted: on
			-- the server a veil is a REASON and here it is a boolean, and a test
			-- that could not read the boolean could not tell a body that was
			-- handed back from one that was never hidden. `bodies.refuse` answers
			-- a reason instead, the way a host without the API does.
			setVisible = function(playerId, visible)
				if bodies.refuse ~= nil then return false, bodies.refuse end
				local id = tonumber(playerId) or playerId
				bodies.visible[id] = visible == true
				bodies.writes[#bodies.writes + 1] = { playerId = id, visible = visible == true }
				return true
			end,
			setFrozen = function(playerId, held)
				local id = tonumber(playerId) or playerId
				bodies.frozen[id] = held == true
				return true
			end,
			-- The reader the veil is asked through. nil, not false, when nothing
			-- has ever written it: the module falls back to its own mark on nil.
			isVisible = function(playerId) return bodies.visible[tonumber(playerId) or playerId] end,
			isFrozen = function(playerId) return bodies.frozen[tonumber(playerId) or playerId] end,
			disconnect = function() return true end,

			-- ── the blue holocall eye-glow ───────────────────────────────────
			--
			-- THE REFUSALS ARE MODELLED, NOT JUST THE SUCCESS, and the card's
			-- own list is what they are modelled from: `holocall_unavailable`,
			-- `invalid_argument`, `invalid_options`. A stub that took anything
			-- and answered `true` would make the whole of `M.Init`'s clamping
			-- untestable -- `durationMs` has a documented 0..600000 range and a
			-- config outside it refuses EVERY renewal while logging nothing a
			-- player can see, which is exactly the class of fault this harness
			-- exists to catch off-platform.
			setHoloCallEyes = function(playerId, enabled, options)
				local id = tonumber(playerId) or playerId
				holocall.writes[#holocall.writes + 1] =
					{ playerId = id, enabled = enabled, options = options }
				if holocall.absent then return false, 'holocall_unavailable' end
				if holocall.refuse ~= nil then return false, holocall.refuse end
				if type(enabled) ~= 'boolean' then return false, 'invalid_argument' end
				-- The card says the id is a network player id, so a slot the
				-- host does not know is an argument fault and not a lease.
				if type(id) ~= 'number' or control.accounts[id] == nil then
					return false, 'invalid_argument'
				end
				local duration = 0
				if options ~= nil then
					if type(options) ~= 'table' then return false, 'invalid_options' end
					for key in pairs(options) do
						-- "options may ONLY contain durationMs". A stub that
						-- ignored a stray key would accept a caller passing
						-- `{ durationMs = 30000, ms = 1 }` that the platform
						-- refuses whole.
						if key ~= 'durationMs' then return false, 'invalid_options' end
					end
					duration = options.durationMs
					if duration == nil then
						duration = 0
					elseif type(duration) ~= 'number' or duration % 1 ~= 0
						or duration < 0 or duration > 600000 then
						return false, 'invalid_options'
					end
				end
				if enabled then
					-- `0` means "until this resource releases it", which is a
					-- different thing from "for no time at all".
					holocall.ours[id] = duration > 0 and { expiresAt = clock + duration } or false
				else
					-- "false releases only its lease": another resource's is
					-- untouched, which is the property `eyesOn` rests on.
					holocall.ours[id] = nil
				end
				return true
			end,

			getHoloCallEyes = function(playerId)
				local id = tonumber(playerId) or playerId
				holocall.reads[#holocall.reads + 1] = id
				if holocall.absent then return nil, 'holocall_unavailable' end
				if holocall.readRefuse ~= nil then return nil, holocall.readRefuse end
				if type(id) ~= 'number' then return nil, 'invalid_player' end
				if control.accounts[id] == nil then return nil, 'player_unavailable' end
				local own = holocall.ours[id]
				-- EXPIRY IS REAL. A bounded lease that never lapsed here would
				-- make the renewal in `calls:scan` indistinguishable from doing
				-- nothing at all.
				if own ~= nil and own ~= false and clock >= own.expiresAt then
					holocall.ours[id] = nil
					own = nil
				end
				-- "The glow remains enabled while ANY resource holds a lease."
				return own ~= nil or holocall.others[id] == true
			end,

			-- Moves a living body with no life transition, and answers a PROMISE
			-- for whether it got there. See `trips` above for why the two are not
			-- the same answer. The promise is already settled when it is handed
			-- back, which is a simplification the caller cannot observe: it awaits
			-- either way, and awaiting a settled promise is legal.
			teleport = function(playerId, position, options)
				trips.calls[#trips.calls + 1] = {
					playerId = tonumber(playerId) or playerId,
					position = position,
					options = options,
				}
				if trips.refuse ~= nil then return nil, trips.refuse end
				local rejection = trips.reject
				local landed = {
					x = type(position) == 'table' and position.x or nil,
					y = type(position) == 'table' and position.y or nil,
					z = type(position) == 'table' and position.z or nil,
					state = trips.state or 'settled',
				}
				return {
					await = function()
						if rejection ~= nil then return nil, rejection end
						return landed
					end,
					status = function()
						return rejection ~= nil and 'rejected' or 'resolved'
					end,
				}
			end,
		},

		character = {
			state = function() return { health = 100 } end,
			-- THREE NUMBERS, not a table: `Open77.character.position()` answers
			-- x, y, z, and every client module reads it that way. A stub that
			-- answered a table made every one of those reads nil -- a marker
			-- module drew nothing, with no error to say why.
			position = function() return placement.x, placement.y, placement.z end,
			yaw = function() return 0 end,
		},

		-- The travel natives. Recorded, because the staff half READS BACK what it
		-- set -- `isNoclip` is how the client notices the native was switched off
		-- underneath it, which is the one edge the server cannot see -- and a
		-- no-op stub would make that read always false, a state this client never
		-- produces. `travels.refuse` is a build without the natives.
		travel = {
			setNoclip = function(on)
				if travels.refuse ~= nil then return false, travels.refuse end
				travels.noclip = on == true
				travels.calls[#travels.calls + 1] = { name = 'setNoclip', value = on == true }
				return true
			end,
			isNoclip = function() return travels.noclip end,
			setMapPick = function(on)
				travels.mapPick = on == true
				travels.calls[#travels.calls + 1] = { name = 'setMapPick', value = on == true }
				return true
			end,
			isMapPick = function() return travels.mapPick end,
		},

		-- The effect layer, in the shape the native answers with. `play` RESOLVES
		-- a name against the engine's own catalogue and answers `handle, reason`
		-- -- it never raises -- so a stub that raised would leave the refused
		-- path untested, and one that always answered a handle would hide a
		-- typo'd alias that draws nothing. `effects.refuse` forces the refusal.
		--
		-- The catalogue is a COPY of `kVfxCatalog` in
		-- `client/src/api/Effects.cpp` (51 aliases, counted 2026-09-19). It is
		-- here for one question a suite should be able to ask without the game:
		-- is the effect a config names one the engine actually carries?
		vfx = {
			catalog = function() return effects.catalogue end,
			play = function(effect, options)
				local call = { effect = effect, options = options }
				if effects.refuse ~= nil then
					call.refused = effects.refuse
					effects.calls[#effects.calls + 1] = call
					return nil, effects.refuse
				end
				effects.next = effects.next + 1
				call.id = effects.next
				effects.plays[#effects.plays + 1] = call
				effects.live[effects.next] = effect
				return effects.next
			end,
			-- The move, in the shape the native answers with: `bool, reason`, and
			-- refused outright for a handle this resource does not hold -- which
			-- is what ends the follow loop, so `effects.updates` is also the
			-- evidence that it stopped rather than spun.
			update = function(id, options)
				if effects.live[id] == nil then return false, 'effect_not_found' end
				if options == nil or type(options.position) ~= 'table' then
					return false, 'invalid_position'
				end
				effects.updates[#effects.updates + 1] = { id = id, options = options }
				return true
			end,
			playEntity = function(effect, options)
				effects.entityPlays[#effects.entityPlays + 1] = { effect = effect, options = options }
				effects.next = effects.next + 1
				return effects.next
			end,
			stop = function(id)
				effects.stopped[#effects.stopped + 1] = id
				effects.live[id] = nil
				return true
			end,
			list = function()
				local out = {}
				for id, effect in pairs(effects.live) do
					out[#out + 1] = { id = id, effect = effect }
				end
				return out
			end,
		},

		sfx = {
			play = function(event, options)
				effects.sfx[#effects.sfx + 1] = { event = event, options = options }
				return #effects.sfx
			end,

			-- The frontend door: a 2D Wwise event with no entity and no
			-- emitter. It answers `true`, or `nil` plus a reason -- NOT a
			-- handle -- because a frontend one-shot has nothing to address a
			-- stop to.
			--
			-- IT REFUSES AN UNKNOWN NAME RATHER THAN FORWARDING IT, which is
			-- the platform's documented behaviour and the only reason the
			-- calls module's ringtone is testable at all: a stub that accepted
			-- every string could not tell `ui_phone_incoming_call` from a name
			-- somebody made up, and "an invented event is indistinguishable
			-- from no sound" is already written in `config/admin.lua` about
			-- the other door. `effects.sfxEvents` is the curated table; a test
			-- that wants a refusal names something outside it.
			play2d = function(event)
				effects.sfx2d[#effects.sfx2d + 1] = event
				if effects.refuse2d ~= nil then return nil, effects.refuse2d end
				if type(event) ~= 'string' or event == '' then return nil, 'invalid_sfx_event' end
				if not effects.sfxEvents[event] then return nil, 'invalid_sfx_event' end
				return true
			end,
		},

		-- Player notifications, in the shape the runtime sends them: the toast is
		-- how a staff action explains itself in game, and a stub that swallowed
		-- one would leave "was the operator told?" unanswerable off-platform.
		notifications = {
			send = function(playerId, message)
			local payload = type(message) == 'table' and message or { message = message }
			notices[#notices + 1] = { playerId = tonumber(playerId) or playerId,
				type = payload.type, message = payload.message }
			return true
		end,
		},

		-- The stock HUD's thirteen components. It used to be `setVisible` answering
		-- a bare `true`, which is enough to boot `modules/hud` and not enough to
		-- ask it anything: the READ was missing entirely.
		--
		-- `modules/blips` is what needed it. Whether the vanilla minimap is on
		-- decides whether a mappin can reach the minimap at all -- the component
		-- governs "Map panel, geometry, player marker, MAPPINS, GPS lines" -- and
		-- that is the sentence the module puts in the operator's journal. A stub
		-- with no `isVisible` would have let it report a state it never read.
		--
		-- A HIDE IS A CLAIM AND NOT AN OVERRIDE, which is modelled because it is
		-- the part people get wrong: `setVisible(c, true)` releases only the
		-- CALLER's claim, and the component stays hidden while anybody else holds
		-- one. Names are case-insensitive, an unknown one is `invalid_hud_component`
		-- rather than a silent success, and `hud.refuse` turns every call away the
		-- way a build without `ui.vanilla.hud` does.
		hud = {
			components = function()
				if hud.refuse ~= nil then return nil, tostring(hud.refuse) end
				local out = {}
				for _, name in ipairs(HUD_COMPONENTS) do out[#out + 1] = name end
				return out
			end,
			setVisible = function(component, visible)
				if hud.refuse ~= nil then return false, tostring(hud.refuse) end
				local name = HUD_CANONICAL[type(component) == 'string' and component:lower() or '']
				if name == nil then return false, 'invalid_hud_component' end
				local claims = hud.claims[name] or {}
				hud.claims[name] = claims
				claims[hud.owner] = visible == false and true or nil
				return true, next(claims) == nil
			end,
			isVisible = function(component)
				if hud.refuse ~= nil then return nil, tostring(hud.refuse) end
				local name = HUD_CANONICAL[type(component) == 'string' and component:lower() or '']
				if name == nil then return nil, 'invalid_hud_component' end
				return next(hud.claims[name] or {}) == nil
			end,
			state = function()
				if hud.refuse ~= nil then return nil, tostring(hud.refuse) end
				local out = {}
				for _, name in ipairs(HUD_COMPONENTS) do
					out[name] = next(hud.claims[name] or {}) == nil
				end
				return out
			end,
		},

		-- THE NATIVE LOADING LIFECYCLE, and the three clients it has to be read on.
		-- `loadscreen.api` is which of them this is: 'state' answers both readers,
		-- 'flag' has `isLoading` alone, and 'absent' is the client that predates
		-- both -- whose `Open77.screen` still exists (the fade natives are older)
		-- and simply has neither name in it. A reader that is not there is NIL, not
		-- a function that refuses, because "is it a function" is exactly the
		-- question a feature detection asks.
		--
		-- `refuse` makes every read answer `nil, <reason>`, the way a client
		-- without `screen.read` answers. `reads` counts every call, which is how
		-- a test tells a cheap cadence from a busy loop.
		screen = setmetatable({}, { __index = function(_, key)
			if key == 'loadingState' and loadscreen.api == 'state' then
				return function()
					loadscreen.reads = loadscreen.reads + 1
					if loadscreen.refuse ~= nil then return nil, tostring(loadscreen.refuse) end
					local out = {}
					for field, value in pairs(loadscreen.state) do out[field] = value end
					return out
				end
			end
			if key == 'isLoading' and (loadscreen.api == 'state' or loadscreen.api == 'flag') then
				return function()
					loadscreen.reads = loadscreen.reads + 1
					if loadscreen.refuse ~= nil then return nil, tostring(loadscreen.refuse) end
					return loadscreen.state.active == true
				end
			end
			return nil
		end }),

		-- A GENERATION THAT CAN CHANGE. This answered a constant 1 for every
		-- resource forever, so every abort-on-reload guard in the runtime --
		-- `modules/target`'s row sweep, `modules/needs`, the deferred callbacks
		-- in `modules/animations` -- compared 1 against 1 and was trivially
		-- satisfied. A reload is the event those guards exist for and it could
		-- not be staged. `control.Reload(name)` bumps one.
		--
		-- The card's other two answers are here too: this VM's own generation
		-- when no name is given, and 0 for a resource that is not running.
		resource = {
			generation = function(resourceName)
				if resourceName == nil then return generations['opx_infinity'] or 1 end
				return generations[tostring(resourceName)] or 0
			end,
		},
	}

	Open77.database = database

	-- Recorded by the marker and key stubs above, and read by the tests.
	markers = { byId = {}, created = {}, removed = {}, next = 0 }
	-- Recorded by the blip stub. `count` is tracked separately from `byId` so the
	-- 128-per-resource quota is exercised against the number LIVE rather than the
	-- number ever made -- a resource at the cap that removes one may create one.
	-- `refuse` fails the next create with a reason of the test's choosing;
	-- `permission` models the undeclared `ui.vanilla.map`, which refuses every
	-- call and says so only in the player's own log.
	blips = { byId = {}, created = {}, removed = {}, next = 0, count = 0,
		refuse = nil, permission = false }
	-- The stock-HUD hide claims, component -> owner -> true. `owner` is which
	-- resource the calls are attributed to, so a test can make a SECOND resource
	-- hold a claim and check that releasing ours does not reveal the component.
	hud = { claims = {}, owner = 'opx_infinity', refuse = nil }
	-- The native loading lifecycle, idle: no load has ever run, which is what a
	-- client that has finished joining answers. `control.Load` moves it.
	loadscreen = { api = 'state', refuse = nil, reads = 0, state = {
		active = false, id = '0', revision = 0, kind = 'unknown',
		progressKnown = false, progress = nil, elapsedMs = 0,
	} }
	-- Recorded by the nameplate stub: which players carry an override, and every
	-- set and remove in order.  makes the host turn an override away.
	plates = { byId = {}, set = {}, removed = {}, refuse = nil }
	watchers = { byId = {}, next = 0, refuse = nil }
	input = { captured = false, keys = {}, down = {} }
	-- `refuse` is a string: every ACL question comes back `false, <reason>`, the
	-- way a build without the `acl.read` grant answers.
	acl = { granted = {}, refuse = nil }
	-- Set `refuse` to make the engine refuse a creation, the way an unsupported
	-- record or a full world would, and `snapshot` to make `get` answer a live
	-- vehicle's projection -- the occupied case, which is the one a recall has to
	-- refuse.
	-- `byId` is the per-vehicle store `get` reads first: put a projection in it
	-- under the id `create` handed back and two live vehicles stop being one.
	-- `world` is every vehicle that EXISTS right now, in creation order, which is
	-- what `Open77.vehicles.all` answers. It is kept by `create` and `remove`
	-- rather than set by a test, because the one question it is there to answer
	-- -- is anything parked on this garage exit -- is a question about what those
	-- two calls did, and a hand-written list would let a test assert an exit is
	-- blocked by a car the runtime never created.
	-- `locks` is every `setLocked` the runtime made, in order, and `engines` every
	-- `setEngine`.
	vehicles = { refuse = nil, snapshot = nil, byId = {}, updates = {},
		refuseUpdate = nil, world = {}, locks = {}, engines = {} }
	vehicleCreates = {}
	vehicleRemoves = {}

	-- Adopted elevators, and every mutation in order. `refuse` makes `adopt`
	-- answer nil the way a host with no elevator authority does, and `refuseFlags`
	-- makes `setFlags` answer false the way a cabin another resource owns does --
	-- the two paths on which an adoption must NOT be kept.
	lifts = { byId = {}, next = 0, adopts = {}, flagWrites = {}, trips = {},
		removes = {}, nearby = {}, refuse = nil, refuseFlags = false,
		ignoreAdoptFlags = false }

	-- Who is sitting in what, by player id. Empty is "everybody is on foot",
	-- which is the answer most of the suite wants and one caller has to survive.
	seats = {}

	-- Bodies the server half hid or gave back, keyed by player id, with every
	-- write in order -- a veil applied twice reads differently from one that
	-- moved, which is the difference between a fix and a coincidence.
	bodies = { visible = {}, frozen = {}, writes = {}, refuse = nil }

	-- `ours` is this resource VM's lease per player, as `{ expiresAt }` or the
	-- sentinel `false` for a lease taken with `durationMs = 0`, which the
	-- platform holds until it is released. `others` is a lease held by SOME
	-- OTHER resource, which is the case that makes `getHoloCallEyes` a
	-- genuinely different question from "did we ask for one": the reader
	-- answers for every resource at once, and a caller that treated it as its
	-- own would release a glow it never took. `control.EyesHeldElsewhere` is
	-- how a test stages that.
	--
	-- `absent` takes both natives away, which is the op77.62-and-older host the
	-- calls module is written to survive; `refuse` makes the writer answer a
	-- reason, the way a host that has the API and said no does.
	holocall = { ours = {}, others = {}, writes = {}, reads = {},
		absent = false, refuse = nil, readRefuse = nil }

	-- THE VOICE STACK, modelled because a call that nobody can hear was shipped
	-- once already. `channels` is id -> { name, members = { playerId -> perms } },
	-- so a test can ask the two questions that matter -- is this player on the
	-- call's channel, and did the channel go when the call did -- rather than
	-- counting calls to a stub that always said yes. `absent` is a host with no
	-- voice stack at all, which must cost the call its audio and nothing else.
	voice = { channels = {}, next = 1, absent = false, refuse = nil,
		transmit = nil, status = nil }

	-- The travel natives' own state, and every write to them.
	travels = { noclip = false, mapPick = false, calls = {}, refuse = nil }

	-- Every `Open77.players.teleport` the server half asked for, and what the
	-- platform is to answer.
	--
	-- THE NATIVE ANSWERS A PROMISE AND NOT A BOOLEAN, and the distinction is the
	-- whole reason this stub is not a one-liner. A trip that is refused OUTRIGHT
	-- -- a player in a vehicle, a body that is not alive -- answers `nil, reason`
	-- and no move is ever issued. A trip that is ACCEPTED answers a promise that
	-- settles later: it RESOLVES `{ x, y, z, state }` when the client reports the
	-- body on the point, grounded and not falling for three frames, and REJECTS
	-- with `settle_timeout` when it never did. A stub that answered true for both
	-- would make "the body arrived" and "the body was asked to move" the same
	-- observation, and the second is the one that was already true before
	-- anybody wrote a settle watch.
	--
	--   trips.refuse  a string: the native refuses outright, nothing moves
	--   trips.reject  a string: the move is issued and the arrival never comes
	--   trips.state   'settled' (the default) or 'near', for a resolution
	trips = { calls = {}, refuse = nil, reject = nil, state = 'settled' }

	-- Notifications the runtime sent, oldest first.
	notices = {}

	-- The world as the SERVER sees it, per player id: where each body is, which
	-- routing bucket it is in, what the host calls it, and every write the
	-- runtime made to any of the three.
	--
	-- Separate from `placement`, which is the CLIENT's own local operator: the
	-- two were conflated by `control.placement` being the only movable position
	-- in the harness, and `control.placement` feeds `character.position`, which
	-- no server script can call. Nothing could move a server-side position at
	-- all, so no reach check on the server side was ever exercised.
	world = {
		positions = {}, headings = {}, buckets = {}, names = {},
		bucketWrites = {}, population = {}, lockdown = {}, transitions = {},
		-- The canonical health maximum each player was given, by player id.
		maxHealth = {},
	}

	-- The life phase of each player id, or nil for a slot with no body. Set on
	-- admission and moved by `kill`, `respawn`, `revive` and `control.Life`.
	lives = {}

	-- The readiness gate's own state. A REAL gate, because the runtime's whole
	-- recycled-player-id defence rests on a session token that CHANGES, and the
	-- stub answered a constant 1 -- so a stale token and a fresh one compared
	-- equal and the race `core/server/gate.lua` exists to prevent could not be
	-- staged. `holds` is per player, per resource; `sessions` is the token the
	-- host hands out, bumped every time a slot is admitted afresh.
	--
	--   gate.refuseHold         a string: `hold` answers nil and that reason
	--   gate.refuseParticipate  a string: `participate` refuses the declaration
	--   gate.refuseRelease      a string: `release` answers false and that reason
	gate = { sessions = {}, holds = {}, nextSession = 100, participations = {},
		releases = {}, refuseHold = nil, refuseParticipate = nil, refuseRelease = nil }

	-- VM generations by resource name. This resource starts at 1; anything not
	-- named here is not running and answers 0, which is the card's own answer.
	-- `control.Reload` bumps one.
	generations = { opx_infinity = 1 }

	-- The resource-private blob that survives a reload. `blob` is what `load`
	-- answers, `writes` is every `save` in order, and `refuse` makes `save`
	-- answer `false, reason`.
	carried = { blob = nil, writes = {}, refuse = nil }

	-- The engine's own clock and weather, so a drift correction has two numbers
	-- to compare rather than one. `refuse` makes `getTime` answer nil plus a
	-- reason -- a build without the environment backend -- and `refuseSet` does
	-- the same for `setTime`.
	environment = { day = 1, seconds = 0, timeFrozen = false, weather = nil,
		weatherFrozen = false, writes = {}, refuse = nil, refuseSet = nil }

	-- Where the local operator is standing. Movable, because an effect that is
	-- placed once and left behind and one that follows the operator read
	-- identically unless the suite can move the operator between pumps.
	placement = { x = 0.0, y = 0.0, z = 0.0 }

	-- Effects the client half asked the engine for. `plays` is the world ones,
	-- `calls` every attempt including the refusals, and `live` the handles still
	-- held -- a pop that was never stopped shows up there.
	effects = {
		-- A MAP FROM ALIAS TO PATH, which is what the card answers: "table
		-- mapping alias to effect path, or nil; reason". This was a 51-element
		-- ARRAY, so `catalog()['fire.large']` -- the only way anybody reads a
		-- catalogue -- was nil for all 51 legal aliases, and a config naming a
		-- real effect looked exactly like one naming a typo. The paths are
		-- synthesised from the alias rather than copied from the engine: what a
		-- caller may do with a cooked path is build-dependent, so the only
		-- property worth modelling here is that a legal alias has one and an
		-- illegal alias has none.
		--
		-- The aliases themselves are the real list, a copy of `kVfxCatalog` in
		-- `client/src/api/Effects.cpp` (51 of them, counted 2026-09-19).
		catalogue = Host.VfxCatalog({
			'blood.puddle', 'electric.arc', 'electric.destruction', 'electric.device',
			'electric.emp', 'electric.industrial_arm', 'explosion.frag', 'explosion.fuel',
			'explosion.grenade', 'explosion.nuclear', 'explosion.steam', 'explosion.turret',
			'fire.gas', 'fire.large', 'fire.medium', 'fire.small', 'fire.tiny',
			'glass.shatter', 'impact.concrete', 'impact.default', 'impact.metal',
			'impact.water', 'laser.mine', 'neon.holo_zone', 'neon.loot_drop',
			'race.firework.burst', 'race.flare.smoke', 'smoke.ambient',
			'smoke.column.black', 'smoke.exterior', 'smoke.machine', 'smoke.poison_gas',
			'smoke.steam', 'sparks.burst.large', 'sparks.burst.small', 'sparks.cable',
			'sparks.welding', 'steam.column', 'steam.sewer', 'vehicle.exhaust',
			'vehicle.fire', 'vehicle.police_lights', 'vehicle.skid', 'vehicle.skid.mark',
			'vehicle.skid.smoke', 'water.drip', 'water.hydrant', 'water.sprinkler',
			'weather.dust', 'weather.rain', 'weather.sandstorm',
		}),
		plays = {}, calls = {}, entityPlays = {}, stopped = {}, live = {}, sfx = {},
		updates = {},
		next = 0, refuse = nil,

		-- Every `Open77.sfx.play2d` the client half asked for, in order, and
		-- the curated table it is judged against. These eight are Cyberpunk's
		-- own `ui_phone_01` bank as the devkit's sfx catalogue lists them for
		-- game build 2.31 -- the same eight `config/calls.lua` names, written
		-- here so the config and the host agree about which strings are real
		-- and a typo in either is one failing check rather than a silent
		-- ringtone nobody hears.
		sfx2d = {},
		refuse2d = nil,
		sfxEvents = {
			['ui_phone_incoming_call'] = true,
			['ui_phone_incoming_call_stop'] = true,
			['ui_phone_incoming_call_positive'] = true,
			['ui_phone_incoming_call_negative'] = true,
			['ui_phone_initiation_call'] = true,
			['ui_phone_initiation_call_stop'] = true,
			['ui_phone_off'] = true,
			['ui_menu_onpress'] = true,
		},
	}

	local env = {
		Open77 = Open77,
		json = json,
		MySQL = database,

		CreateThread = function(fn)
			local thread = coroutine.create(fn)
			threads[#threads + 1] = thread
			if side == 'client' and METER_LIMIT ~= nil then threadOrigins[thread] = meterSite(fn) end
		end,
		Wait = function() coroutine.yield() end,
		GetGameTimer = function() return clock end,
		GetCurrentResourceName = function() return 'opx_infinity' end,
		GetResourceState = function() return 'stopped' end,

		-- Identity comes from the host and only from the host. `control.Admit`
		-- below is how a test says a slot is occupied.
		GetPlayerIdentifier = function(playerId) return control.accounts[playerId] end,
		GetPlayerName = function(playerId)
			return control.accounts[playerId] and ('player-' .. tostring(playerId)) or nil
		end,

		AddEventHandler = function(name, fn)
			handlers[name] = handlers[name] or {}
			table.insert(handlers[name], side == 'client' and meterWrap('event ' .. name, fn) or fn)
		end,
		TriggerEvent = function(name, ...)
			for _, fn in ipairs(handlers[name] or {}) do fn(...) end
		end,
		RegisterNetEvent = function(name, fn)
			netEvents[name] = side == 'client' and meterWrap('net ' .. name, fn) or fn
		end,

		-- A CEF page. `emit` is how a test plays the page: it invokes whatever
		-- the runtime wired to that channel, exactly as the real bridge would.
		WebUI = {
			create = function(spec)
				-- `visible` starts from the spec, not from a later `show`. The runtime creates
				-- the surface visible on purpose, and a stub that ignores the flag would
				-- make a never-painting page look identical to a working one.
				local page = {
					spec = spec,
					sent = {},
					-- Every send the host turned away, newest last.
					refused = {},
					handlers = {},
					focus = {},
					visible = spec.visible == true,
					alive = true,
				}
				page.send = function(_, channel, payload)
					-- THE HOST BOUNDS A WebUI PAYLOAD AND REFUSES AN OVERSIZED ONE
					-- WHOLE. This stub used to answer true to everything, which is
					-- why the fitting room's catalogue could be lost on the wire for
					-- a release with a green suite behind it: every batch it sent was
					-- past the bound, `WebUI.Page.send` answered false on the real
					-- host, and nothing here ever said so. Modelled rather than
					-- asserted per test, so the whole suite is the check.
					local nodes = Host.PayloadNodes(payload)
					if nodes > Host.MAX_PAYLOAD_NODES then
						page.refused[#page.refused + 1] =
							{ channel = channel, nodes = nodes }
						return false
					end
					page.sent[#page.sent + 1] = { channel = channel, payload = payload }
					return true
				end
				page.on = function(_, channel, handler)
					page.handlers[channel] = side == 'client' and meterWrap('page ' .. channel, handler) or handler
				end
				page.setFocus = function(_, keyboard, cursor)
					page.focus = { keyboard = keyboard, cursor = cursor }
					return true
				end
				page.hasFocus = function() return page.focus.keyboard or page.focus.cursor end
				page.show = function() page.visible = true; return true end
				page.hide = function() page.visible = false; return true end
				page.destroy = function() page.alive = false; return true end
				control.pages[#control.pages + 1] = page
				return page
			end,
		},
		-- RAISES ON A DUPLICATE, because the host does and this stub did not.
		--
		-- The devkit card for build 2.31.13+op77.76 is exact: "Names are 1 to 64
		-- characters ... registering one twice raises `duplicate command`." This
		-- was a silent overwrite, and the cost of that was measured rather than
		-- imagined: the appearance module registered `opx.appearance` twice, the
		-- raise took the rest of its `Start` with it -- including the hook that
		-- loads a character's clothing at login -- and all 1012 checks passed
		-- over it. A stub that accepts what the engine refuses is a stub that
		-- certifies a broken server.
		--
		-- Names are checked too, for the same reason: a name with a space in it
		-- is a command nobody can ever type, and the suite should say so here
		-- rather than let an operator find out.
		RegisterCommand = function(name, fn, restricted)
			if type(name) ~= 'string' or #name < 1 or #name > 64
				or name:match('^[%w_%.:%-]+$') == nil then
				error(('invalid command name %q'):format(tostring(name)), 2)
			end
			-- Case-insensitively, as the host matches them.
			local key = name:lower()
			if commands[key] ~= nil then error('duplicate command', 2) end
			commands[key] = { run = fn, restricted = restricted == true }
		end,

		-- The host's command registry, which `core/server/commands.lua` reads
		-- before it takes a short alias: a bare word like `noclip` is far likelier
		-- to be owned by another resource in the session than a prefixed one is.
		--
		-- The shape is the card's -- `name`, `resource`, `restricted`, `source` --
		-- and it answers for the whole session and not just this resource, which
		-- is the only reason the runtime bothers to ask. `control.Claim` is how a
		-- test puts another resource's command in it.
		GetRegisteredCommands = function()
			local rows = {}
			for name, entry in pairs(commands) do
				rows[#rows + 1] = {
					name = name,
					resource = entry.resource or 'opx_infinity',
					restricted = entry.restricted,
					source = 'resource',
				}
			end
			table.sort(rows, function(left, right) return left.name < right.name end)
			return rows
		end,

		-- Two answer shapes are documented for the host call: the effective key,
		-- or `true, key`. Both are produced here, because reading only one of them
		-- is a bug this suite has already caught once.
		RegisterKeyMapping = function(id, name, key, onPressed, onReleased)
			if keyMappings.refuse then return false, keyMappings.refuse end
			if key == false then return false, 'no_key' end
			local effective = type(key) == 'string' and key ~= '' and key or 'E'
			input.keys[id] = effective
			keyMappings.byId[id] = { name = name, key = effective, pressed = meterWrap('key ' .. id, onPressed),
				released = type(onReleased) == 'function' and meterWrap('key release ' .. id, onReleased) or nil }
			if keyMappings.secondShape then return true, effective end
			return effective
		end,
	}

	keyMappings = { byId = {}, refuse = false, secondShape = false }

	if side == 'server' then
		env.TriggerClientEvent = function(name, source, ...)
			clientEvents[#clientEvents + 1] = { name = name, source = source, ... }
			-- A SERVER TOAST IS A NOTICE, whichever door it left by. `OPX.Notify`
			-- used to hand every one to `Open77.notifications` and now raises it on
			-- the runtime's own channel; the suite asks "what was this player
			-- told?" through `notices` in fifty-odd places, and that question did
			-- not change when the route did.
			local payload = ...
			if name == 'opx:net:runtime:toast' and type(payload) == 'table' then
				notices[#notices + 1] = { playerId = tonumber(source) or source,
					type = payload.kind, message = payload.message }
			end
		end
	else
		-- RECORDED, NOT SWALLOWED. This used to be an empty function, which made
		-- the one channel a client half has to the operator the one channel the
		-- suite could not see: `modules/appearance` reports every clothing and
		-- fitting-room decision over it, precisely because `Open77.log` on a
		-- client writes to a file on the player's machine. A test that cannot read
		-- this cannot tell a module that decided nothing from one that decided and
		-- said so, which is the distinction two diagnoses of the fitting room both
		-- got wrong.
		env.TriggerServerEvent = function(name, ...)
			serverEvents[#serverEvents + 1] = { name = name, ... }
			return true
		end
	end

	-- `require` exists in the CLIENT VM and nowhere else: the dedicated-server
	-- sandbox has no module loader at all. Installing it on the client side only
	-- is what lets a shared_script that reached for it fail here, which is the
	-- one place that mistake is cheap to find.
	--
	-- It resolves `@opx_lib/...` against the sibling checkout, so these tests
	-- exercise the REAL library rather than a stand-in -- a stub would pass while
	-- the two repositories drifted apart, which is the failure this is meant to
	-- catch.
	if side == 'client' then env.require = Host.RequireFor(env) end

	-- CROSS-RESOURCE EXPORTS, on both runtimes, in the shape the devkit cards
	-- give for op77.45 (server) and op77.3 (client): `exports(name, fn)`
	-- publishes, `GetInvokingResource()` names the caller inside an export and
	-- nil outside one, and `Open77.exports.call` dispatches to another resource.
	--
	-- A REAL REGISTRY AND A REAL CALLER. `control.CallExport(caller, name, ...)`
	-- runs a published export AS that resource, on a coroutine like the host's
	-- scheduler does, and answers what the export answered -- so a test asserts
	-- on the allowlist and the identity, not on a function it reached around
	-- them. Every outgoing `Open77.exports.call` is recorded, and answers a
	-- promise whose `await` returns true: the reply a creator's own export would
	-- give back is not this resource's business.
	local published, exportCalls = {}, {}
	local invoking = nil
	-- A CALLABLE TABLE, as the host gives it: called to publish, indexed for
	-- `exports.other:name()`. A plain function here once let a `type(exports)
	-- == 'function'` test pass in the suite and fail on every real server.
	env.exports = setmetatable({}, {
		__call = function(_, name, fn)
			if type(name) ~= 'string' or #name < 1 or #name > 64 then
				error('invalid_export_name', 2)
			end
			if type(fn) ~= 'function' then error('export_function_required', 2) end
			published[name] = fn
			return true
		end,
		__newindex = function() error('Open77: exports is not assignable', 2) end,
	})
	env.GetInvokingResource = function() return invoking end
	Open77.exports.call = function(resource, name, ...)
		exportCalls[#exportCalls + 1] = { resource = resource, name = name, args = { ... } }
		return { await = function() return true end, status = function() return 'resolved' end }
	end

	env._G = env
	setmetatable(env, { __index = _G })

	-- What the harness hands back to a test.
	control = {
		kvp = kvp,
		log = log,
		commands = commands,
		netEvents = netEvents,
		clientEvents = clientEvents,
		serverEvents = serverEvents,

		-- What this resource published with `exports`, by name, and every
		-- `Open77.exports.call` it made, oldest first.
		exports = published,
		exportCalls = exportCalls,

		--- Calls one published export as another resource would, and answers
		--- what it answered. Run on a coroutine and pumped, because an export
		--- body may yield exactly as the host lets it; `GetInvokingResource`
		--- names `caller` for the whole of that coroutine and nil after it.
		CallExport = function(caller, name, ...)
			local fn = published[name]
			if fn == nil then return nil, 'export_not_found' end
			local args = table.pack(...)
			local done, answer, failure = false, nil, nil
			local thread = coroutine.create(function()
				invoking = caller
				local ran, value = pcall(fn, table.unpack(args, 1, args.n))
				invoking = nil
				if ran then answer = value else failure = value end
				done = true
			end)
			for _ = 1, 400 do
				invoking = caller
				local ok, why = coroutine.resume(thread)
				invoking = nil
				if not ok then return nil, tostring(why) end
				if done then break end
				control.Pump(1)
			end
			if not done then return nil, 'export_timeout' end
			if failure ~= nil then return nil, 'export_raised: ' .. tostring(failure) end
			return answer
		end,

		--- Calls one published export and gives up on it after `rounds` resumes,
		--- the way the host does: a SYNCHRONOUS caller (`rounds` 1) fails the
		--- call with `export_yielded` at the callee's first yield and never
		--- resumes it, and an asynchronous caller that times out, stops or
		--- reloads cancels the callee's task, which "stops future continuation"
		--- (devkit, server-exports). The coroutine is dropped where it stood.
		AbandonExport = function(caller, rounds, name, ...)
			local fn = published[name]
			if fn == nil then return nil, 'export_not_found' end
			local args = table.pack(...)
			local done, answer = false, nil
			local thread = coroutine.create(function()
				answer = fn(table.unpack(args, 1, args.n))
				done = true
			end)
			for round = 1, rounds do
				invoking = caller
				local ok, why = coroutine.resume(thread)
				invoking = nil
				if not ok then return nil, 'export_raised: ' .. tostring(why) end
				if done then return answer end
				if round < rounds then control.Pump(1) end
			end
			return nil, rounds == 1 and 'export_yielded' or 'export_cancelled'
		end,
		-- The live tunables, so a test can move one the way the Warden panel does.
		tunables = tunables,
		handlers = handlers,

		--- Moves the clock on without resuming anything, so a test can step past
		--- every rate window at once without paying for the frames in between.
		Advance = function(ms) clock = clock + (tonumber(ms) or 0) end,

		--- Resumes every queued thread up to `rounds` times, so a `while true`
		--- loop in the runtime cannot hang the test.
		Pump = function(rounds)
			for _ = 1, rounds or 40 do
				clock = clock + 100
				local alive = false
				-- A finished thread is dropped from the list, as the host drops a
				-- finished task. Kept, it is memory the RUNTIME never holds, and a
				-- check measuring what a flood of requests leaves behind would be
				-- measuring the harness.
				local live = 0
				for index = 1, #threads do
					local thread = threads[index]
					threads[index] = nil
					if coroutine.status(thread) ~= 'dead' then
						live = live + 1
						threads[live] = thread
					else
						threadOrigins[thread] = nil
					end
				end
				for _, thread in ipairs(threads) do
					if coroutine.status(thread) == 'suspended' then
						alive = true
						local ok, failure = meterResume(thread, threadOrigins[thread])
						if not ok then
							log.error[#log.error + 1] = 'thread died: ' .. tostring(failure)
						end
					end
				end
				if not alive then return end
			end
		end,

		-- Slot -> durable account id. Identity comes from the host and only from
		-- the host, so this is the only way a test can make a slot real.
		accounts = {},

		-- Every WebUI page the runtime created, newest last.
		pages = {},

		-- World markers the runtime created and removed. `markers.refuse` makes the
		-- next creation fail, which is how "the API is there but said no" is
		-- exercised.
		markers = markers,
		plates = plates,
		watchers = watchers,

		-- The vanilla map pins the runtime created and removed, and the two
		-- levers that make the engine say no: `blips.refuse` is a reason string
		-- for the next create, `blips.permission = true` is the undeclared
		-- `ui.vanilla.map` -- every call turned away, nothing logged where the
		-- operator can read it, and a map that is simply empty.
		blips = blips,

		-- The stock HUD's hide claims. `hud.claims.minimap` carrying an owner is
		-- the state `config/hud.lua`'s `VANILLA.minimap = false` produces, and it
		-- is what decides whether a mappin can reach the minimap at all.
		hud = hud,

		-- The native loading lifecycle: which readers this client has (`api`),
		-- the refusal switch, the read count and the state itself. Move the
		-- state with `control.Load`, which bumps the revision the way the
		-- platform does on every change.
		loadscreen = loadscreen,

		--- Moves the native loading lifecycle. Fields not named are kept;
		--- `active = true` on a load that was not up opens a NEW cycle with a
		--- new id, and the revision goes up on every call, as it does on the
		--- platform for any change at all.
		Load = function(fields)
			local state = loadscreen.state
			if fields.active == true and state.active ~= true then
				state.id = tostring((tonumber(state.id) or 0) + 1)
				state.elapsedMs = 0
				state.kind, state.progressKnown, state.progress = 'unknown', false, nil
			end
			for field, value in pairs(fields) do state[field] = value end
			if fields.progress == false then state.progress = nil end
			state.revision = (tonumber(state.revision) or 0) + 1
		end,

		-- The keyboard: `input.captured` is another surface holding it, `input.keys`
		-- is what each mapping answers to after a rebind.
		input = input,

		-- The ACL's own state. `granted` is what `control.Allow` writes; set
		-- `acl.refuse` to a string to make every question come back `false,
		-- <reason>`, the way a build without the `acl.read` grant answers -- a
		-- refusal CARRYING a reason, which is not the same thing as a host that
		-- could not be asked at all.
		acl = acl,

		-- Key mappings the runtime declared, by id.
		keyMappings = keyMappings,

		-- The vehicle stubs themselves: what `get` answers and what the engine
		-- refuses are both set through here.
		vehicles = vehicles,

		-- Every argument list `Open77.vehicles.create` was called with, and every
		-- id `remove` was called with.
		vehicleCreates = vehicleCreates,
		vehicleRemoves = vehicleRemoves,

		-- Every adopted lift, every flag mask written to one, every trip scheduled
		-- and every release -- plus the two refusal switches. A lift's `flags` here
		-- is the engine's own bitmask, so a test asserts on `locked` being set and
		-- not on the runtime having meant to set it.
		lifts = lifts,

		-- Bodies the server half hid, by player id, and every write in order.
		bodies = bodies,

		-- Where the local operator stands; move it to test anything that follows
		-- the operator rather than the spot they were in.
		placement = placement,

		-- Effects the client half asked the engine for, in order, refusals too.
		effects = effects,

		-- Travel native state and every write to it.
		travels = travels,

		-- Every server-side teleport asked for, and the answer the platform is
		-- to give: see the block where it is built for what `refuse`, `reject`
		-- and `state` each mean.
		trips = trips,

		-- Notifications the runtime sent, oldest first.
		notices = notices,

		-- Where every player stands on the SERVER, which bucket each is in, what
		-- the host calls them, and every bucket write, population and lockdown
		-- call and life transition the runtime made. Move a body with
		-- `control.Stand`, not by writing here.
		world = world,

		-- Life phase by player id. `control.Life` is the way to move one.
		lives = lives,

		-- The readiness gate's own state: session tokens, who holds what, and
		-- the three refusal switches. `control.Hold` and `control.Free` stage
		-- another resource's hold.
		gate = gate,

		-- VM generation by resource name. `control.Reload` is how a test makes a
		-- resource look reloaded to an abort-on-reload guard.
		generations = generations,

		-- The resource-private blob that survives a reload, every write to it,
		-- and the refusal switch.
		carried = carried,

		-- The engine's clock and weather, and the two refusal switches.
		environment = environment,

		-- What steers the MySQL bridge this environment was booted with, or nil
		-- when it has none: `strict`, `calls`, `park` and `Resume`. Parking a
		-- query is how two threads are made to overlap inside one.
		database = Host.Steering(database),

		--- Reloads a resource: its generation changes, which is exactly what a
		--- guard holding a cached handle is watching for. With no name it is
		--- this resource.
		Reload = function(resourceName)
			local key = tostring(resourceName or 'opx_infinity')
			generations[key] = (generations[key] or 0) + 1
			return generations[key]
		end,

		--- Grants one permission to one player, as an ACL entry would.
		Allow = function(playerId, permission)
			local player = acl.granted[tostring(playerId)]
			if player == nil then
				player = {}
				acl.granted[tostring(playerId)] = player
			end
			player[tostring(permission)] = true
		end,

		--- Registers a command as ANOTHER resource in the session, so a collision
		--- with `open77_shell` or `open77_weapons` can be exercised. The runtime
		--- has no way to tell this apart from a real one, which is the point: a
		--- short alias competes for one session-wide namespace.
		Claim = function(name, resourceName)
			commands[tostring(name):lower()] =
				{ run = function() end, restricted = false, resource = resourceName }
		end,

		--- Takes one back off, so a refusal can be exercised after a grant.
		Deny = function(playerId, permission)
			local player = acl.granted[tostring(playerId)]
			if player ~= nil then player[tostring(permission)] = nil end
		end,

		--- Puts an account on a slot, or clears it when `userId` is nil.
		---
		--- Admitting a slot gives it everything the host gives a real connection:
		--- a position at the origin, the world bucket, an alive body and a FRESH
		--- gate session. The session is what makes a recycled player id testable
		--- -- admit 7, release with its token, admit 7 again, and a release
		--- carrying the old token now lands on `session_mismatch` the way it
		--- would on the platform.
		Admit = function(playerId, userId)
			local id = tonumber(playerId) or playerId
			control.accounts[playerId] = userId
			if userId == nil then
				world.positions[id] = nil
				world.buckets[id] = nil
				world.names[id] = nil
				lives[id] = nil
				gate.sessions[id] = nil
				gate.holds[id] = nil
				-- AND THE GLOW, because the platform says so: a holocall lease
				-- "clears on death, disconnect, resource stop/reload/failure or
				-- expiry". Leaving it here would let a test see a lit slot that
				-- nobody is sitting in, which is the one thing the lease's own
				-- documentation promises cannot happen.
				holocall.ours[id] = nil
				holocall.others[id] = nil
				return
			end
			world.positions[id] = world.positions[id] or { x = 0.0, y = 0.0, z = 0.0 }
			world.buckets[id] = world.buckets[id] or 0
			lives[id] = lives[id] or 'alive'
			gate.nextSession = gate.nextSession + 1
			gate.sessions[id] = gate.nextSession
			gate.holds[id] = {}
		end,

		--- Walks a player to a point. Takes `{ x, y, z }` or three numbers, so a
		--- test can move the body a reach check measures against -- which nothing
		--- in this harness could do before.
		---
		--- AND FACES THEM A WAY, optionally: a fourth number, or `heading`/`yaw`
		--- on the table. Only `Open77.players.get` answers it, so a caller that
		--- reads a facing off `position` cannot be told from one that reads it
		--- off the rich snapshot unless the two disagree -- and they do, because
		--- `position` has no yaw at all. A call that names no heading LEAVES THE
		--- OLD ONE rather than resetting it to zero: zero is a legal facing, and
		--- a reset would make "never faced anywhere" and "facing north" the same
		--- state, which is the distinction the capture path turns on.
		Stand = function(playerId, x, y, z, heading)
			local id = tonumber(playerId) or playerId
			if type(x) == 'table' then
				heading = x.heading or x.yaw or heading
				x, y, z = x.x, x.y, x.z
			end
			world.positions[id] = { x = tonumber(x) or 0.0, y = tonumber(y) or 0.0,
				z = tonumber(z) or 0.0 }
			if tonumber(heading) ~= nil then world.headings[id] = tonumber(heading) end
		end,

		--- Sets a player's life phase, or takes their body away entirely when it
		--- is nil -- which is what the host answers for somebody behind a
		--- continue screen, and the case `MayAct` and `downed` both branch on.
		--- One of `alive`, `dead`, `revivepending`, `respawnpending`,
		--- `recovering`.
		Life = function(playerId, phase)
			local id = tonumber(playerId) or playerId
			lives[id] = phase
			-- THE PLATFORM CLEARS A HOLOCALL LEASE ON DEATH, in its own words,
			-- and modelling it here is what makes `modules/calls`'s watchdog
			-- mean anything: the module re-takes a lease that went while the
			-- call was still live, and without this the glow would survive a
			-- flatline in the harness and nowhere else.
			if phase == 'dead' or phase == nil then
				holocall.ours[id] = nil
				holocall.others[id] = nil
			end
		end,

		--- Whether the platform is showing the blue glow on a slot, and whose
		--- lease it is. Two answers, because `getHoloCallEyes` deliberately
		--- collapses them and a test asserting on the collapsed one could not
		--- tell a resource that took a lease from one that merely benefited
		--- from somebody else's.
		--- @return boolean lit, boolean ours
		Eyes = function(playerId)
			local id = tonumber(playerId) or playerId
			local own = holocall.ours[id]
			if own ~= nil and own ~= false and clock >= own.expiresAt then
				holocall.ours[id] = nil
				own = nil
			end
			return own ~= nil or holocall.others[id] == true, own ~= nil
		end,

		--- Stages a lease held by ANOTHER resource, which `getHoloCallEyes`
		--- reports and `setHoloCallEyes(false)` must never touch.
		EyesHeldElsewhere = function(playerId, held)
			holocall.others[tonumber(playerId) or playerId] = held == true
		end,

		--- Takes this VM's lease away without telling it, the way a platform
		--- reload or an expiry does. The case the calls sweep's watchdog is
		--- written for.
		EyesDropped = function(playerId)
			holocall.ours[tonumber(playerId) or playerId] = nil
		end,

		--- The holocall stub's own state: every write, every read, and the two
		--- switches that make the natives absent or refusing. Handed over by
		--- reference, so a test flips `absent` or `refuse` on it directly, the
		--- way it already does with `markers.refuse` and `bodies.refuse`.
		holocall = holocall,
		-- The voice stack's own state: channels, their members, and the one
		-- client-side route assertion. A test asks this who is on a call's channel.
		voice = voice,

		--- Puts a player in a routing bucket directly, the way another resource
		--- would, without going through the runtime's own move.
		Bucket = function(playerId, bucket)
			world.buckets[tonumber(playerId) or playerId] = tonumber(bucket) or 0
		end,

		--- Gives the host a display name for a slot. The default is
		--- `player-<id>`; pass one with a control character or past 32 bytes to
		--- exercise a caller's strip and cut.
		Rename = function(playerId, name)
			world.names[tonumber(playerId) or playerId] = name
		end,

		--- Takes a hold on a player as ANOTHER resource, so "the gate is shut
		--- because somebody else is still loading" can be staged. `Free` lifts it.
		Hold = function(playerId, resourceName, reason)
			local id = tonumber(playerId) or playerId
			gate.holds[id] = gate.holds[id] or {}
			gate.holds[id][tostring(resourceName)] = { reason = reason or 'test', at = clock }
		end,

		--- Lifts another resource's hold.
		Free = function(playerId, resourceName)
			local held = gate.holds[tonumber(playerId) or playerId]
			if held then held[tostring(resourceName)] = nil end
		end,

		--- Puts a player in a vehicle, or takes them out when it is nil.
		Seat = function(playerId, assignment) seats[tonumber(playerId) or playerId] = assignment end,

		--- Plays the page: invokes whatever the runtime wired to that channel,
		--- exactly as the real bridge would when the page emits.
		PageEmit = function(page, channel, payload)
			local handler = page and page.handlers[channel]
			if handler then handler(payload) end
		end,

		--- Reports every created page ready. A real page does this once it has
		--- loaded, and nothing can be sent to a surface before it does.
		ReadyPages = function()
			for _, page in ipairs(control.pages) do
				local handler = page.handlers['opx:ready']
				if handler then handler({}) end
			end
		end,

		Fire = function(name, ...)
			for _, fn in ipairs(handlers[name] or {}) do fn(...) end
		end,
	}

	return env, control
end

--- Names the sandbox removes on BOTH runtimes. Loading code that reaches for one
--- is a failure the test should report here rather than on the test server.
Host.Sandbox = { 'io', 'os', 'debug', 'package', 'dofile', 'loadfile' }

--- Names the CLIENT VM has and the dedicated server does not.
---
--- `require` is the whole list, and it is separated from `Host.Sandbox` rather
--- than dropped from it because the distinction is real and load-bearing: a
--- `client_script` may import a library, and a `shared_script` that did the same
--- would break the moment the server loaded it. Merging the two lists would
--- either forbid a legal import or permit an illegal one.
Host.ClientOnly = { 'require' }

--- Where a published dependency library lives.
---
--- A sibling checkout by default, which is how they sit on a workstation.
--- `OPX_LIB_PATH` overrides it, and CI needs that: `actions/checkout` refuses a
--- path outside the workspace, so the runner clones the library INTO the
--- workspace and points this at it. Without the override, CI cannot see the
--- sibling at all and every client boot dies on the first `require`.
---
--- The suite loads the REAL library rather than a stub on purpose -- a stub
--- would pass while the two repositories drifted apart -- so a missing checkout
--- has to be loud rather than skipped.
Host.Providers = { opx_lib = os.getenv('OPX_LIB_PATH') or '../opx_lib' }

--- Builds the client VM's `require` for ONE environment.
---
--- A FACTORY rather than a plain function, and the environment is the whole
--- reason. `loadfile(path)` runs a module in the REAL global table -- which is
--- not where the harness's stubbed `Open77` lives; that is in the sandbox
--- `env`. So every library wrapper resolved its natives against a table that
--- was never there, took its absent-native path for the entire suite, and the
--- SUCCESS paths of `Input`, `Rpc`, `Store` and `Players` went untested while
--- their refusals were covered. The suite loads the real library precisely so
--- the two repositories cannot drift; loading it blind to the stub gave up
--- most of that.
---
--- The cache moves inside for the same reason. It was module-level and shared
--- across every environment the suite builds, where the platform caches per
--- caller generation -- two consumers get two copies. Per environment is both
--- the faithful shape and what lets the stub differ between tests.
-- @author dop42
-- @param env table the sandbox the importing resource runs in
-- @return function
function Host.RequireFor(env)
	local imported = {}

	local function resolve(name)
	if type(name) ~= 'string' then return nil, 'invalid_module_name' end

	local provider, module = name:match('^@([%w_]+)/?(.*)$')
	if provider == nil then
		-- A bare name resolves inside the CALLING resource on the platform. This
		-- resource ships no importable modules, so reaching for one is a mistake
		-- rather than something to support.
		return nil, ('unqualified require(%q)'):format(name)
	end

	local root = Host.Providers[provider]
	if root == nil then return nil, 'module_dependency_not_declared' end
	if module == '' then module = 'init' end

	local path = ('%s/%s.lua'):format(root, (module:gsub('%.', '/')))
	if imported[path] ~= nil then return imported[path] end

	-- IN `env`, which is the point of the factory: the module resolves its
	-- natives against the stub the test installed, not against the real global
	-- table where there is no platform at all.
	local chunk, why = loadfile(path, 't', env)
	if chunk == nil then
		-- The sibling is genuinely absent, rather than the import being wrong.
		return nil, ('module_dependency_not_running: %s'):format(tostring(why))
	end

	-- The library imports its own siblings through the caller's `require`,
	-- which in a running client is this same resolver. It already IS
	-- `env.require` and the module runs in `env`, so the lookup finds it with
	-- no global swap -- the swap this replaced was only ever needed because the
	-- module was running somewhere `env` could not be seen from.
	local value = chunk()

	if value == nil then value = true end
	imported[path] = value
	return value
	end

	return resolve
end

--- Reads the manifest and answers the scripts for one side, in load order.
--- Parsing the real manifest rather than a copy means a file added to the
--- resource and forgotten in the manifest fails here.
-- @author dop42
-- @param path string
-- @param side string 'server' or 'client'
-- @return string[]
--- THE PLATFORM'S ORDER, NOT THE MANIFEST'S.
--
-- `SharedScripts.Concat(ServerScripts)` is literally what both loaders execute before
-- any phase runs -- `ServerResourceHost.cs` and `LuaResourceRuntime.cs` in
-- `Open77.Server.Scripting` -- so every SHARED script runs before any script of the
-- side's own, whatever order the manifest lists them in. A harness that reads the
-- manifest top to bottom is a harness that can only ever agree with the platform by
-- accident, and it disagreed about exactly the thing that mattered: a module is
-- declared by a `shared_script` and three configs are `server_script`s, so the suite
-- had the config loaded before the module declared itself while a real server had it
-- the other way round. The module's settings were empty in production and populated
-- here, which is a whole class of fault this file existed to catch and did not.
-- @author XEROX710
-- @param path string
-- @param side string 'server' or 'client'
-- @return string[]
function Host.LoadOrder(path, side)
	local own = side .. '_script'
	local shared, mine = {}, {}
	for line in io.lines(path) do
		local kind, file = line:match('^%s*([%a_]+)%s+"([^"]+)"')
		if kind == 'shared_script' then
			shared[#shared + 1] = file
		elseif kind == own then
			mine[#mine + 1] = file
		end
	end
	for _, file in ipairs(mine) do shared[#shared + 1] = file end
	return shared
end

return Host
