--- The creator surface, server half: what another Open77 resource may call.
-- @author dop42
--
-- LAST IN THE SERVER MANIFEST. Everything it wraps is a contract another file
-- publishes during the module phases, and an export registered at file scope is
-- supported -- so this file only has to exist after the modules, and it reads
-- every contract at the moment of the call rather than holding one.
--
-- WHY THIS EXISTS. Inside `opx_infinity` modules talk through `OPX.Api.Get`, and
-- that table lives in this VM: no other resource can reach it, and the old
-- `opx77_*` exports went away with the split into modules. A creator writing a
-- job, a shop or a heist as a resource of their own had nothing to call. The
-- devkit cards for `server:exports` (op77.45) and `GetInvokingResource` are the
-- platform's answer, and this is the curated set built on them.
--
-- THE ANSWER IS ALWAYS ONE PLAIN TABLE, the old opx77 export contract:
--
--   { ok = true, value = <answer> }          the value may be nil
--   { ok = false, error = <code> }           a stable code, branchable
--
-- one value and not `ok, code`, because a synchronous `exports.opx_infinity:X()`
-- and an awaited `Open77.exports.call` must read the same, and `local r = ...`
-- of a two-value answer silently keeps the boolean and drops the reason. An
-- export never raises: a body that does is logged and answered
-- `error.unavailable`.
--
-- EVERY CALL PASSES THREE GATES BEFORE ITS BODY:
--   1. the caller -- the name the HOST reports, never an argument;
--   2. the scope  -- `SERVER.EXPORTS.READ` for a question, `.WRITERS` for a
--                    change, both in `config/server.lua`;
--   3. the boot   -- nothing answers before the boot thread has settled.
-- and every argument is then checked again by the export AND by the contract
-- under it. The server stays the authority: a player id is a connection the
-- host knows, a citizen id is parsed, an amount is a whole positive number.
--
-- A WRITE IS AUDITED WITH ITS CALLER, `event=export.<Name>`, beside whatever the
-- module itself writes; money additionally carries `ext:<resource>:` in front
-- of its reason, so the money ledger line names who paid too.
--
-- CALL A WRITE WITH `Open77.exports.call(...)` AND AWAIT IT. A write, and any
-- read of a character who is not online, can reach the database, and the
-- synchronous form fails a callee that yields with `export_yielded`. Those
-- exports (AddMoneyOffline, SetJob, SetGang, RemoveJob, RemoveGang, the stash
-- and key exports, SetVehicleState, the door writes, OpenStash, GetVehicle,
-- GetOwnedVehicles, AddVehicle, GiveKeys, and an item, metadata or HasKeys
-- export naming a citizen id) take one tick before touching anything, so a
-- synchronous call fails there with nothing begun, and then run on a thread of
-- this resource that a cancelled caller cannot leave half-done. The reads of a
-- loaded player (GetPlayerData, GetPlayers, GetMoney, HasJob, GetJob, GetGang,
-- IsStaff, GetMetadata, IsDown), the catalogue reads, and the memory-only
-- writes (SetDuty, SetMetadata, Revive, RegisterItem, the use, bar and bench
-- registrations, Notify) answer at once and are safe either way.

local Result = OPX.Result

-- The version of THIS surface. Bumped on any breaking change to an export's
-- arguments or answer; a name is never reused for something else.
local SURFACE = 1

-- A money reason a caller may give, in characters.
local MAX_REASON = 64

-- Job, gang and stash names: what the configs use.
local NAME_PATTERN = '^[%w_%-%.]+$'

-- Callers already told how to be admitted, by `caller \1 export`, so a
-- resource retrying in a loop writes one hint and not one per tick.
local hinted = {}

-- The answer shapes, the caller gate and the allowlist test are shared with the
-- client surface: `core/shared/exports.lua`.
local Export = OPX.Export
local refuse, ok, answered = Export.Refuse, Export.Ok, Export.Answered

local function settings()
	local server = OPX.Config.SERVER or {}
	return type(server.EXPORTS) == 'table' and server.EXPORTS or {}
end

local admits = Export.Admits

-- ── the arguments ────────────────────────────────────────────────────────────

--- A player id the host knows a connection for, or nil.
local function playerOf(value)
	local id = math.tointeger(tonumber(value))
	if type(value) ~= 'number' or id == nil or id < 1 or id > 2147483647 then return nil end
	if OPX.UserIdOf(id) == nil then return nil end
	return id
end

--- A citizen id in its canonical form, or nil.
local function citizenOf(value)
	if type(value) ~= 'string' then return nil end
	local parsed = OPX.CitizenId.Parse(value)
	return parsed.ok and parsed.value or nil
end

--- What an inventory call may name: a connected player id, or a citizen id.
local function targetOf(value)
	if type(value) == 'number' then return playerOf(value) end
	return citizenOf(value)
end

--- Whether a call names a citizen id, which reaches a character nobody may be
--- playing and yields; a player id answers from what is loaded.
local function byCitizen(target)
	return type(target) == 'string'
end

--- A bounded name, or nil.
local function nameOf(value, maximum)
	if type(value) ~= 'string' or #value < 1 or #value > (maximum or 48) then return nil end
	if not value:match(NAME_PATTERN) then return nil end
	return value
end

--- A whole number in bounds, or nil. `nil` in is answered as `fallback`.
local function countOf(value, low, high, fallback)
	if value == nil then return fallback end
	local n = math.tointeger(tonumber(value))
	if type(value) ~= 'number' or n == nil or n < low or n > high then return nil end
	return n
end

--- A money type this server has, or nil.
local function moneyTypeOf(value)
	local character = OPX.Api.Get('character')
	if type(value) ~= 'string' or character == nil or not character.IsMoneyType(value) then
		return nil
	end
	return value
end

--- A caller's reason, cleaned, bounded and named after its caller.
local function reasonOf(caller, value)
	local text = '-'
	if value ~= nil then
		if type(value) ~= 'string' then return nil end
		text = OPX.Text.Clean(value, MAX_REASON, '...') or '-'
	end
	return ('ext:%s:%s'):format(caller, text)
end

--- Metadata a caller may hand an inventory call: nil, or a plain table.
local function metadataOf(value)
	if value == nil then return true, nil end
	if type(value) ~= 'table' then return false, nil end
	return true, value
end

-- ── the gate ─────────────────────────────────────────────────────────────────

--- Whether a call of an export may yield, from its raw arguments.
local function mayYield(yields, args)
	if yields == true then return true end
	if type(yields) == 'function' then return yields(table.unpack(args, 1, args.n)) == true end
	return false
end

--- Runs a body that may yield on a thread of THIS resource, and waits for it.
--
-- A BODY THAT YIELDS MUST NOT BE ABANDONED HALF-WAY, and the host abandons an
-- export coroutine in two documented cases (devkit, server-exports): a
-- synchronous caller -- the callee "must not yield", the call fails with
-- `export_yielded` and nothing resumes it -- and an asynchronous caller that
-- times out, stops or reloads, which "cancels the target's scheduled task. This
-- stops future continuation; it cannot undo writes already performed". A body
-- abandoned there keeps whatever it held: the offline money ledger busy (every
-- login of that character refused until the stale guard, a minute later), an
-- inventory `loading` marker every later load of that stash or bag waits 35 s
-- on and then fails, and a statement already submitted whose caller was told
-- the call failed -- and retries it.
--
-- So two things, in this order. A PROBE: one `Wait(0)` before anything is
-- touched. A synchronous caller fails right there with nothing begun; an
-- asynchronous one loses a tick. Then the body runs on a thread THIS resource
-- owns, which no caller's lifetime can cancel, and the export coroutine only
-- waits on it: if that coroutine is abandoned, the body still finishes and
-- lets go of what it held.
-- @return boolean ran, any answer -- `pcall`'s shape
local function detached(body, caller, args)
	if not pcall(Wait, 0) then return true, refuse('export.mustAwait') end
	local box = { done = false }
	CreateThread(function()
		box.ran, box.answer = pcall(body, caller, table.unpack(args, 1, args.n))
		box.done = true
	end)
	while not box.done do Wait(0) end
	return box.ran, box.answer
end

local hasExports = Export.Available

--- Publishes one export behind the three gates.
-- @param name string the export name
-- @param scope string `read` or `write`
-- @param body fun(caller: string, ...): table the plain answer
-- @param yields boolean|fun(...): boolean|nil whether a call can yield -- reach
--   the database or wait -- given its raw arguments. Such a call is run
--   `detached`, above.
local function publish(name, scope, body, yields)
	if not hasExports() then return end
	exports(name, function(...)
		local caller = Export.Caller()
		if caller == nil then return refuse('export.callerDenied') end

		local config = settings()
		local list = scope == 'write' and config.WRITERS or config.READ
		if not admits(list, caller) then
			-- Its own dedupe window per CALLER. Through `Audit.Security` with no
			-- source, every denial on the host shared one window, so a resource
			-- retrying in a loop hid every other resource's denial from the log.
			OPX.Audit.Log({
				event = 'export.denied',
				severity = 'warn',
				message = ('%s called %s'):format(caller, name),
				data = { caller = caller, export = name, scope = scope },
				owner = 'ext:' .. caller,
			})
			local key = caller .. '\1' .. name
			if not hinted[key] then
				hinted[key] = true
				Open77.log.warn(('[exports] %s was refused %s; to admit it, add `%s = true` to ' ..
					'EXPORTS.%s in config/server.lua'):format(caller, name, caller,
					scope == 'write' and 'WRITERS' or 'READ'))
			end
			return refuse('export.callerDenied')
		end

		if not OPX.Booted then return refuse('export.booting') end

		local args = table.pack(...)
		local ran, answer
		if mayYield(yields, args) then
			ran, answer = detached(body, caller, args)
		else
			ran, answer = pcall(body, caller, table.unpack(args, 1, args.n))
		end
		if not ran then
			Open77.log.error(('[exports] %s raised for %s: %s')
				:format(name, caller, tostring(answer)))
			answer = refuse('error.unavailable')
		elseif type(answer) ~= 'table' then
			answer = refuse('error.unavailable')
		end

		if scope == 'write' then
			args.n = nil
			OPX.Audit.Log({
				event = 'export.' .. name,
				severity = answer.ok and 'info' or 'warn',
				message = caller,
				data = { caller = caller, args = args, error = answer.error },
				-- A refused write is collapsed per caller; one that landed is a
				-- ledger line (`export.` in `lib/server/audit.lua`) and never is.
				owner = 'ext:' .. caller,
			})
		end
		return answer
	end)
end

--- The loaded character at a player id, or nil and the refusal.
local function loaded(value)
	local character = OPX.Api.Get('character')
	if character == nil then return nil, refuse('error.unavailable') end
	local id = playerOf(value)
	if id == nil then return nil, refuse('export.badArgument') end
	local player = character.GetPlayer(id)
	if player == nil then return nil, refuse('error.notLoggedIn') end
	return player, nil, character
end

-- ── who a player is ──────────────────────────────────────────────────────────

publish('GetVersion', 'read', function()
	return ok({ version = OPX.VERSION, exports = SURFACE })
end)

publish('GetPlayerData', 'read', function(_, source)
	local player, refused, character = loaded(source)
	if player == nil then return refused end
	return ok(character.PublicView(player))
end)

publish('GetPlayerByCitizenId', 'read', function(_, citizenId)
	local character = OPX.Api.Get('character')
	if character == nil then return refuse('error.unavailable') end
	local id = citizenOf(citizenId)
	if id == nil then return refuse('export.badArgument') end
	local player = character.GetPlayerByCitizenId(id)
	if player == nil then return refuse('error.notLoggedIn') end
	return ok(character.PublicView(player))
end)

publish('IsStaff', 'read', function(_, source)
	local id = playerOf(source)
	if id == nil then return refuse('export.badArgument') end
	local right = settings().STAFF_PERMISSION
	if type(right) ~= 'string' or right == '' then right = 'command.opx.admin' end
	-- The index is inside the pcall: a host without `acl.read` installs no
	-- `Open77.acl` at all, and that is "not staff", not a raise.
	local read, allowed = pcall(function() return Open77.acl.isAllowed(id, right) end)
	return ok(read and allowed == true)
end)

-- ── money ────────────────────────────────────────────────────────────────────

publish('GetMoney', 'read', function(_, source, moneyType)
	local player, refused, character = loaded(source)
	if player == nil then return refused end
	if moneyType == nil then return ok(OPX.Table.DeepCopy(character.GetMoney(player))) end
	if moneyTypeOf(moneyType) == nil then return refuse('money.badType') end
	return ok(character.GetMoney(player, moneyType))
end)

--- The two loaded-character money doors share everything but the verb.
local function moneyDoor(verb)
	return function(caller, source, moneyType, amount, reason)
		local player, refused, character = loaded(source)
		if player == nil then return refused end
		if moneyTypeOf(moneyType) == nil then return refuse('money.badType') end
		local value = countOf(amount, 1, 9999999999, nil)
		if value == nil then return refuse('money.badAmount') end
		local why = reasonOf(caller, reason)
		if why == nil then return refuse('export.badArgument') end
		local done, code = character[verb](player, moneyType, value, why)
		if not done then return refuse(code or 'error.unavailable') end
		return ok(character.GetMoney(player, moneyType))
	end
end

publish('AddMoney', 'write', moneyDoor('AddMoney'))
publish('RemoveMoney', 'write', moneyDoor('RemoveMoney'))

publish('AddMoneyOffline', 'write', function(caller, citizenId, moneyType, amount, reason)
	local character = OPX.Api.Get('character')
	if character == nil then return refuse('error.unavailable') end
	local id = citizenOf(citizenId)
	if id == nil then return refuse('export.badArgument') end
	if moneyTypeOf(moneyType) == nil then return refuse('money.badType') end
	local value = countOf(amount, 1, 9999999999, nil)
	if value == nil then return refuse('money.badAmount') end
	local why = reasonOf(caller, reason)
	if why == nil then return refuse('export.badArgument') end
	return answered(character.AddMoneyOffline(id, moneyType, value, why))
end, true)

-- ── jobs and gangs ───────────────────────────────────────────────────────────

publish('HasJob', 'read', function(_, source, name, onDuty, minGrade)
	local player, refused, character = loaded(source)
	if player == nil then return refused end
	if nameOf(name) == nil then return refuse('export.badArgument') end
	if onDuty ~= nil and type(onDuty) ~= 'boolean' then return refuse('export.badArgument') end
	local grade = countOf(minGrade, 0, 255, false)
	if grade == nil then return refuse('export.badArgument') end
	return ok(character.HasJob(player, name, onDuty == true, grade or nil))
end)

publish('HasGang', 'read', function(_, source, name, minGrade)
	local player, refused, character = loaded(source)
	if player == nil then return refused end
	if nameOf(name) == nil then return refuse('export.badArgument') end
	local grade = countOf(minGrade, 0, 255, false)
	if grade == nil then return refuse('export.badArgument') end
	return ok(character.HasGang(player, name, grade or nil))
end)

publish('GetJob', 'read', function(_, source)
	local player, refused = loaded(source)
	if player == nil then return refused end
	return ok(OPX.Table.DeepCopy(player.PlayerData.job))
end)

publish('GetGang', 'read', function(_, source)
	local player, refused = loaded(source)
	if player == nil then return refused end
	return ok(OPX.Table.DeepCopy(player.PlayerData.gang))
end)

-- THE CHANGES GO THROUGH THE GROUPS FUNCTIONS THEMSELVES, the ones the staff
-- commands use, so `job:beforeSet` / `gang:beforeSet` may veto them
-- (`job.vetoed`), and a change that lands raises `opx:in:character:job|gang`
-- inside the resource and `opx:on:character:job|gang` for every other one.
-- A citizen id reaches a character nobody is playing; that change holds the
-- offline ledger, so a login racing it reads it back rather than saving the old
-- job over it. Every one of them writes a membership row, so every one yields:
-- await it.

--- A Groups Result as the plain answer, its value copied off the live record.
local function grouped(result)
	if type(result) == 'table' and result.ok == true then
		return ok(OPX.Table.DeepCopy(result.value))
	end
	return answered(result)
end

--- The two primary-group setters share everything but the verb.
local function groupSetter(verb)
	return function(_, target, name, grade)
		local character = OPX.Api.Get('character')
		if character == nil or character[verb] == nil then return refuse('error.unavailable') end
		local who = targetOf(target)
		if who == nil or nameOf(name) == nil then return refuse('export.badArgument') end
		local level = countOf(grade, 0, 255, 0)
		if level == nil then return refuse('export.badArgument') end
		return grouped(character[verb](who, name, level))
	end
end

--- And the two removals.
local function groupRemover(verb)
	return function(_, target, name)
		local character = OPX.Api.Get('character')
		if character == nil or character[verb] == nil then return refuse('error.unavailable') end
		local who = targetOf(target)
		if who == nil or nameOf(name) == nil then return refuse('export.badArgument') end
		return grouped(character[verb](who, name))
	end
end

publish('SetJob', 'write', groupSetter('SetJob'), true)
publish('SetGang', 'write', groupSetter('SetGang'), true)
publish('RemoveJob', 'write', groupRemover('RemovePlayerFromJob'), true)
publish('RemoveGang', 'write', groupRemover('RemovePlayerFromGang'), true)

-- Duty is a loaded character's alone: an offline one has no shift to be on.
-- Memory only, so it never yields.
publish('SetDuty', 'write', function(_, source, onDuty)
	local player, refused, character = loaded(source)
	if player == nil then return refused end
	if type(onDuty) ~= 'boolean' then return refuse('export.badArgument') end
	if character.SetJobDuty == nil then return refuse('error.unavailable') end
	return answered(character.SetJobDuty(player, onDuty))
end)

-- ── a caller's own metadata ──────────────────────────────────────────────────
-- A CALLER WRITES ONLY UNDER ITS OWN NAME. The key a creator names is stored
-- as `ext.<resource>.<key>` in the character's metadata, the resource being the
-- name the host reports: no argument can reach `health`, `armor` or any other
-- key opx keeps there, nor another resource's keys. A key is one segment
-- (no dot), so `ext.a.b.c` belongs to `a.b` alone and never to `a`.
--
-- WHAT IS STORED IS PLAIN DATA, BOUNDED: a boolean, a finite number, a string,
-- or a table of those keyed by text or position, with no metatable, no cycle,
-- and an encoded size under `SERVER.EXPORTS.METADATA`. It is persisted with the
-- character like the rest of the metadata, and it travels with the rest of
-- PlayerData to the player's OWN client -- so it is no place for a secret the
-- player must not read. Online characters only.

local META_KEY = '^[%w_%-]+$'

local function metaLimits()
	local configured = type(settings().METADATA) == 'table' and settings().METADATA or {}
	local function bound(value, fallback)
		local n = math.tointeger(tonumber(value))
		return (n ~= nil and n > 0) and n or fallback
	end
	return {
		bytes = bound(configured.MAX_BYTES, 4096),
		keys = bound(configured.MAX_KEYS, 32),
		total = bound(configured.MAX_TOTAL_BYTES, 16384),
	}
end

--- The stored key of a caller's key, or nil.
local function metaKeyOf(caller, key)
	if type(key) ~= 'string' or #key < 1 or #key > 48 or not key:match(META_KEY) then
		return nil
	end
	return ('ext.%s.%s'):format(caller, key)
end

--- Every stored key of one caller, by its own key.
local function metaOwned(metadata, caller)
	local prefix = ('ext.%s.'):format(caller)
	local owned = {}
	for stored, value in pairs(type(metadata) == 'table' and metadata or {}) do
		if type(stored) == 'string' and stored:sub(1, #prefix) == prefix then
			local own = stored:sub(#prefix + 1)
			if own:match(META_KEY) then owned[own] = value end
		end
	end
	return owned
end

--- Whether a value is plain data: no function, no userdata, no metatable, no
--- cycle, no NaN or infinity, bounded depth and breadth.
local function plainData(value, depth, budget)
	local kind = type(value)
	if kind == 'boolean' or kind == 'string' then return true end
	if kind == 'number' then return value == value and value ~= math.huge and value ~= -math.huge end
	if kind ~= 'table' or depth > 8 or getmetatable(value) ~= nil then return false end
	for key, inner in pairs(value) do
		budget.left = budget.left - 1
		if budget.left < 0 then return false end
		local keyed = type(key) == 'string' and #key <= 64
			or (math.type(key) == 'integer' and key >= 1)
		if not keyed or not plainData(inner, depth + 1, budget) then return false end
	end
	return true
end

--- The encoded size of a plain value, or nil.
local function encodedSize(value)
	local encoded, text = pcall(json.encode, value)
	if not encoded or type(text) ~= 'string' then return nil end
	return #text
end

--- Why a caller's value cannot be kept next to what it already keeps, or nil.
local function metaRefusal(owned, key, value)
	if value == nil then return nil end
	local limits = metaLimits()
	local size = encodedSize(value)
	if size == nil then return 'export.badValue' end
	if size > limits.bytes then return 'export.tooLarge' end
	local keys, total = 1, size
	for own, held in pairs(owned) do
		if own ~= key then
			keys = keys + 1
			total = total + (encodedSize(held) or 0)
		end
	end
	if keys > limits.keys or total > limits.total then return 'export.tooLarge' end
	return nil
end

-- A CITIZEN ID REACHES A CHARACTER NOBODY IS PLAYING, through the row, held in
-- the offline ledger the money and group writes use: a login racing the write
-- reads it back rather than saving the old metadata over it. That path reads
-- the database, so a call naming a citizen id yields and must be awaited; a
-- player id answers from memory exactly as before.

publish('GetMetadata', 'read', function(caller, target, key)
	if key ~= nil and metaKeyOf(caller, key) == nil then return refuse('export.badArgument') end
	local metadata
	if type(target) == 'string' then
		local character = OPX.Api.Get('character')
		if character == nil or character.ReadMetadata == nil then return refuse('error.unavailable') end
		local id = citizenOf(target)
		if id == nil then return refuse('export.badArgument') end
		local read = character.ReadMetadata(id)
		if not read.ok then return answered(read) end
		metadata = read.value.metadata
	else
		local player, refused = loaded(target)
		if player == nil then return refused end
		metadata = player.PlayerData.metadata
	end
	if key == nil then return ok(OPX.Table.DeepCopy(metaOwned(metadata, caller))) end
	return ok(OPX.Table.DeepCopy(type(metadata) == 'table' and metadata[metaKeyOf(caller, key)] or nil))
end, byCitizen)

publish('SetMetadata', 'write', function(caller, target, key, value)
	local stored = metaKeyOf(caller, key)
	if stored == nil then return refuse('export.badArgument') end
	if value ~= nil and not plainData(value, 1, { left = 512 }) then
		return refuse('export.badValue')
	end

	if type(target) == 'string' then
		local character = OPX.Api.Get('character')
		if character == nil or character.WriteMetadata == nil then return refuse('error.unavailable') end
		local id = citizenOf(target)
		if id == nil then return refuse('export.badArgument') end
		-- The bounds are checked against the metadata AS IT STANDS AT THE WRITE,
		-- read under the ledger, not against a read made before the wait.
		local written = character.WriteMetadata(id, stored, OPX.Table.DeepCopy(value), function(metadata)
			return metaRefusal(metaOwned(metadata, caller), key, value)
		end)
		if not written.ok then return answered(written) end
		return ok(true)
	end

	local player, refused, character = loaded(target)
	if player == nil then return refused end
	local refusal = metaRefusal(metaOwned(player.PlayerData.metadata, caller), key, value)
	if refusal ~= nil then return refuse(refusal) end
	if character.SetMetadata(player, stored, OPX.Table.DeepCopy(value)) ~= true then
		return refuse('error.notLoggedIn')
	end
	return ok(true)
end, byCitizen)

-- ── downed ───────────────────────────────────────────────────────────────────

publish('IsDown', 'read', function(_, source)
	local downed = OPX.Api.Get('downed')
	if downed == nil or downed.IsDown == nil then return refuse('error.unavailable') end
	local id = playerOf(source)
	if id == nil then return refuse('export.badArgument') end
	return answered(downed.IsDown(id))
end)

-- Through the module's own Revive, the one path a staff revive takes: its
-- `REVIVERS` switch, its gate check, its audit line -- which names the caller
-- and the reason -- and `opx:on:downed:changed` when the player gets up.
publish('Revive', 'write', function(caller, source, reason)
	local downed = OPX.Api.Get('downed')
	if downed == nil or downed.Revive == nil then return refuse('error.unavailable') end
	local id = playerOf(source)
	if id == nil then return refuse('export.badArgument') end
	if reason ~= nil and (type(reason) ~= 'string' or #reason > 256) then
		return refuse('export.badArgument')
	end
	return answered(downed.Revive(id, caller, reason))
end)

-- ── needs ────────────────────────────────────────────────────────────────────
-- The server owns them (the owner's ruling, 2026-10), so these are the creator's
-- door to them: through the `needs` contract, bounded and clamped there, and
-- announced on `opx:on:needs:changed` like any other move. The reason a write
-- names is what the client and the bus are told moved the needs.

--- A needs patch: a table of plain number values under plain names, or nil.
local function needsPatch(value)
	if type(value) ~= 'table' then return nil end
	local count = 0
	for key, number in pairs(value) do
		count = count + 1
		if count > 16 or type(key) ~= 'string' or #key > 32 or type(number) ~= 'number' then
			return nil
		end
	end
	return count > 0 and value or nil
end

publish('GetNeeds', 'read', function(_, source)
	local needs = OPX.Api.Get('needs')
	if needs == nil then return refuse('error.unavailable') end
	local id = playerOf(source)
	if id == nil then return refuse('export.badArgument') end
	return answered(needs.GetNeeds(id))
end, true)

--- The two needs writes share everything but the verb.
local function needsDoor(verb)
	return function(caller, source, patch)
		local needs = OPX.Api.Get('needs')
		if needs == nil then return refuse('error.unavailable') end
		local id = playerOf(source)
		local values = needsPatch(patch)
		if id == nil or values == nil then return refuse('export.badArgument') end
		return answered(needs[verb](id, values, 'ext:' .. caller))
	end
end
publish('AddNeeds', 'write', needsDoor('AddNeeds'), true)
publish('SetNeeds', 'write', needsDoor('SetNeeds'), true)

-- ── items ────────────────────────────────────────────────────────────────────

--- The inventory contract, or nil.
local function inventory()
	return OPX.Api.Get('inventory')
end

--- The checked arguments every item export takes, or the refusal.
local function itemArgs(target, name, count, metadata, countRequired)
	local who = targetOf(target)
	if who == nil then return nil, refuse('export.badArgument') end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then
		return nil, refuse('export.badArgument')
	end
	local units = countOf(count, 1, 1000000, countRequired and nil or 1)
	if units == nil then return nil, refuse('export.badArgument') end
	local fits, meta = metadataOf(metadata)
	if not fits then return nil, refuse('export.badArgument') end
	return { target = who, name = name, count = units, metadata = meta }, nil
end

publish('HasItem', 'read', function(_, target, name, count, metadata)
	local api = inventory()
	if api == nil then return refuse('error.unavailable') end
	local args, refused = itemArgs(target, name, count, metadata, false)
	if args == nil then return refused end
	local counted = api.GetItemCount(args.target, args.name, args.metadata)
	if not counted.ok then return answered(counted) end
	return ok(counted.value >= args.count)
end, byCitizen)

publish('CountItem', 'read', function(_, target, name, metadata)
	local api = inventory()
	if api == nil then return refuse('error.unavailable') end
	local args, refused = itemArgs(target, name, nil, metadata, false)
	if args == nil then return refused end
	return answered(api.GetItemCount(args.target, args.name, args.metadata))
end, byCitizen)

publish('AddItem', 'write', function(_, target, name, count, metadata)
	local api = inventory()
	if api == nil then return refuse('error.unavailable') end
	local args, refused = itemArgs(target, name, count, metadata, false)
	if args == nil then return refused end
	return answered(api.AddItem(args.target, args.name, args.count, args.metadata))
end, byCitizen)

publish('RemoveItem', 'write', function(_, target, name, count, metadata)
	local api = inventory()
	if api == nil then return refuse('error.unavailable') end
	local args, refused = itemArgs(target, name, count, metadata, false)
	if args == nil then return refused end
	return answered(api.RemoveItem(args.target, args.name, args.count, args.metadata))
end, byCitizen)

-- ── stashes ──────────────────────────────────────────────────────────────────

--- The checked arguments every stash export takes, or the refusal.
local function stashArgs(stash, item, count, metadata)
	if nameOf(stash) == nil then return nil, refuse('export.badArgument') end
	if type(item) ~= 'string' or #item < 1 or #item > 64 then
		return nil, refuse('export.badArgument')
	end
	local units = countOf(count, 1, 1000000, 1)
	if units == nil then return nil, refuse('export.badArgument') end
	local fits, meta = metadataOf(metadata)
	if not fits then return nil, refuse('export.badArgument') end
	return { stash = stash, item = item, count = units, metadata = meta }, nil
end

publish('CountInStash', 'read', function(_, stash, item, metadata)
	local api = inventory()
	if api == nil or api.CountInStash == nil then return refuse('error.unavailable') end
	local args, refused = stashArgs(stash, item, nil, metadata)
	if args == nil then return refused end
	return answered(api.CountInStash(args.stash, args.item, args.metadata))
end, true)

publish('AddToStash', 'write', function(caller, stash, item, count, metadata)
	local api = inventory()
	if api == nil or api.AddToStash == nil then return refuse('error.unavailable') end
	local args, refused = stashArgs(stash, item, count, metadata)
	if args == nil then return refused end
	-- A stash that does not exist yet is created only under the rule of
	-- `SERVER.EXPORTS.STASHES`: configured, or `<caller>.<name>` within the cap.
	local stashes = type(settings().STASHES) == 'table' and settings().STASHES or {}
	return answered(api.AddToStash(args.stash, args.item, args.count, args.metadata, {
		creator = caller,
		cap = math.tointeger(tonumber(stashes.CREATE_CAP)),
	}))
end, true)

publish('RemoveFromStash', 'write', function(_, stash, item, count, metadata)
	local api = inventory()
	if api == nil or api.RemoveFromStash == nil then return refuse('error.unavailable') end
	local args, refused = stashArgs(stash, item, count, metadata)
	if args == nil then return refused end
	return answered(api.RemoveFromStash(args.stash, args.item, args.count, args.metadata))
end, true)

-- ── chat ─────────────────────────────────────────────────────────────────────

publish('SendChat', 'write', function(_, target, message)
	local chat = OPX.Api.Get('chat')
	if chat == nil or chat.Send == nil then return refuse('error.unavailable') end
	return answered(chat.Send(target, message))
end)

publish('BroadcastChat', 'write', function(_, message, options)
	local chat = OPX.Api.Get('chat')
	if chat == nil or chat.Broadcast == nil then return refuse('error.unavailable') end
	if options ~= nil and type(options) ~= 'table' then return refuse('export.badArgument') end
	return answered(chat.Broadcast(message, options))
end)

-- ── vehicles and keys ────────────────────────────────────────────────────────

publish('RevokeKeys', 'write', function(_, target, plate)
	local keys = OPX.Api.Get('vehiclekeys')
	if keys == nil or keys.Revoke == nil then return refuse('error.unavailable') end
	local who = targetOf(target)
	if who == nil or type(plate) ~= 'string' then return refuse('export.badArgument') end
	return answered(keys.Revoke(who, plate))
end, true)

publish('RevokeAllKeys', 'write', function(_, plate)
	local keys = OPX.Api.Get('vehiclekeys')
	if keys == nil or keys.RevokeAll == nil then return refuse('error.unavailable') end
	if type(plate) ~= 'string' then return refuse('export.badArgument') end
	return answered(keys.RevokeAll(plate))
end, true)

publish('SetVehicleState', 'write', function(_, plate, state, garage)
	local vehicles = OPX.Api.Get('vehicles')
	if vehicles == nil or vehicles.SetState == nil then return refuse('error.unavailable') end
	if type(plate) ~= 'string' or type(state) ~= 'string' then
		return refuse('export.badArgument')
	end
	if garage ~= nil and nameOf(garage) == nil then return refuse('export.badArgument') end
	return answered(vehicles.SetState(plate, state, garage))
end, true)

-- ── doors ────────────────────────────────────────────────────────────────────
-- ox_doorlock's server exports under their ox meaning (`modules/doorlock`). A
-- door is ox's integer id; a door seeded from config or carried over from the
-- first version also answers to its old key. No answer ever carries a code.

--- A door reference: ox's id, or a seeded door's key.
local function doorRef(value)
	if type(value) == 'number' then return math.tointeger(value) end
	return nameOf(value)
end

local function doorlockApi(method)
	local doorlock = OPX.Api.Get('doorlock')
	if doorlock == nil or doorlock[method] == nil then return nil end
	return doorlock
end

-- ox's `getDoor(id)`.
publish('GetDoor', 'read', function(_, ref)
	local doorlock = doorlockApi('Get')
	if doorlock == nil then return refuse('error.unavailable') end
	if doorRef(ref) == nil then return refuse('export.badArgument') end
	return answered(doorlock.Get(doorRef(ref)))
end)

-- ox's `getDoorFromName(name)`.
publish('GetDoorFromName', 'read', function(_, name)
	local doorlock = doorlockApi('GetFromName')
	if doorlock == nil then return refuse('error.unavailable') end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then return refuse('export.badArgument') end
	return answered(doorlock.GetFromName(name))
end)

-- ox's `getAllDoors()`.
publish('GetAllDoors', 'read', function()
	local doorlock = doorlockApi('All')
	if doorlock == nil then return refuse('error.unavailable') end
	return answered(doorlock.All())
end)

-- ox's `setDoorState(id, state)` called by a resource: the caller decided who
-- may, and the door's own rules are not consulted. On the networked backend it
-- reaches `open77_doors` and yields, so it is awaited like every other write.
publish('SetDoorState', 'write', function(caller, ref, state)
	local doorlock = doorlockApi('SetState')
	if doorlock == nil then return refuse('error.unavailable') end
	if doorRef(ref) == nil or (state ~= 0 and state ~= 1 and type(state) ~= 'boolean') then
		return refuse('export.badArgument')
	end
	return answered(doorlock.SetState(doorRef(ref), state, 'ext:' .. caller))
end, true)

-- The first version's boolean spelling of the same, kept for its callers.
publish('SetDoorLocked', 'write', function(caller, ref, locked)
	local doorlock = doorlockApi('SetLocked')
	if doorlock == nil then return refuse('error.unavailable') end
	if doorRef(ref) == nil or type(locked) ~= 'boolean' then return refuse('export.badArgument') end
	return answered(doorlock.SetLocked(doorRef(ref), locked, 'ext:' .. caller))
end, true)

-- ox's `createDoor(data)`, answering the new id. The door is validated exactly
-- as a staff save is, minus the staff member's position.
publish('CreateDoor', 'write', function(caller, data)
	local doorlock = doorlockApi('Create')
	if doorlock == nil then return refuse('error.unavailable') end
	if type(data) ~= 'table' then return refuse('export.badArgument') end
	return answered(doorlock.Create(data, 'ext:' .. caller))
end, true)

-- ox's `editDoor(id, data)`: the fields given replace the door's.
publish('EditDoor', 'write', function(caller, ref, data)
	local doorlock = doorlockApi('Edit')
	if doorlock == nil then return refuse('error.unavailable') end
	if doorRef(ref) == nil or type(data) ~= 'table' then return refuse('export.badArgument') end
	return answered(doorlock.Edit(doorRef(ref), data, 'ext:' .. caller))
end, true)

-- ox's `removeDoor(id)`.
publish('RemoveDoor', 'write', function(caller, ref)
	local doorlock = doorlockApi('Remove')
	if doorlock == nil then return refuse('error.unavailable') end
	if doorRef(ref) == nil then return refuse('export.badArgument') end
	return answered(doorlock.Remove(doorRef(ref), 'ext:' .. caller))
end, true)

-- ── fuel ─────────────────────────────────────────────────────────────────────
-- ox_fuel has no getter export: a resource reads `Entity(vehicle).state.fuel`,
-- a PERCENTAGE. That bag field exists here too, under the same name, but it is
-- the platform's and holds LITRES (`open77_fuel`), so a port of an ox consumer
-- asks these instead and gets ox's unit back. ox's `setPaymentMethod` and
-- `setMoneyCheck` take a function, which no export can carry: the pump offers
-- cash and bank itself (`PAYMENT` in `config/fuel.lua`).

local function fuelApi()
	local fuel = OPX.Api.Get('fuel')
	if fuel == nil or fuel.Get == nil then return nil end
	return fuel
end

--- A vehicle id another resource handed in: an integer, or its text.
local function vehicleArg(value)
	if math.type(value) == 'integer' and value > 0 then return value end
	if type(value) == 'string' and #value >= 1 and #value <= 32 and not value:find('%s') then return value end
	return nil
end

-- ox's `state.fuel`: the tank in percent, 0..100, or nil before anybody filled it.
publish('GetFuel', 'read', function(_, vehicleId)
	local fuel = fuelApi()
	if fuel == nil then return refuse('error.unavailable') end
	if vehicleArg(vehicleId) == nil then return refuse('export.badArgument') end
	local read = fuel.Get(vehicleArg(vehicleId))
	if not read.ok then return answered(read) end
	return ok(read.value.percent)
end)

-- The whole tank: `{ litres, capacity, percent, usesFuel }`.
publish('GetFuelState', 'read', function(_, vehicleId)
	local fuel = fuelApi()
	if fuel == nil then return refuse('error.unavailable') end
	if vehicleArg(vehicleId) == nil then return refuse('export.badArgument') end
	return answered(fuel.Get(vehicleArg(vehicleId)))
end)

-- ox's `state:set('fuel', percent)`, announced on `opx:on:fuel:changed` with
-- `reason = 'ext:<caller>'`. Memory only: safe either way it is called.
publish('SetFuel', 'write', function(caller, vehicleId, percent)
	local fuel = fuelApi()
	if fuel == nil or fuel.Set == nil then return refuse('error.unavailable') end
	if vehicleArg(vehicleId) == nil or type(percent) ~= 'number' then return refuse('export.badArgument') end
	return answered(fuel.Set(vehicleArg(vehicleId), percent, 'ext:' .. caller))
end)

-- ── who is in the city, and what it is made of ───────────────────────────────

--- A loaded character as a roster row: who, and the two groups. No money, no
--- metadata -- `GetPlayerData` is the read for one player.
local function rosterRow(player)
	local data = player.PlayerData
	local charInfo = type(data.charInfo) == 'table' and data.charInfo or {}
	return {
		source = data.source,
		citizenId = data.citizenId,
		firstName = charInfo.firstName,
		lastName = charInfo.lastName,
		job = OPX.Table.DeepCopy(data.job),
		gang = OPX.Table.DeepCopy(data.gang),
	}
end

-- Every loaded character, or those a filter keeps: `{ job, gang, onDuty }`.
-- `GetPlayers({ job = 'ncpd', onDuty = true })` is the "how many cops are on"
-- question every heist asks.
publish('GetPlayers', 'read', function(_, filter)
	local character = OPX.Api.Get('character')
	if character == nil then return refuse('error.unavailable') end
	if filter ~= nil and type(filter) ~= 'table' then return refuse('export.badArgument') end
	filter = filter or {}
	if (filter.job ~= nil and nameOf(filter.job) == nil)
		or (filter.gang ~= nil and nameOf(filter.gang) == nil)
		or (filter.onDuty ~= nil and type(filter.onDuty) ~= 'boolean') then
		return refuse('export.badArgument')
	end
	local rows = {}
	for _, player in ipairs(character.GetPlayers()) do
		local data = player.PlayerData
		local job, gang = data.job or {}, data.gang or {}
		if (filter.job == nil or job.name == filter.job)
			and (filter.gang == nil or gang.name == filter.gang)
			and (filter.onDuty == nil or (job.onDuty == true) == filter.onDuty) then
			rows[#rows + 1] = rosterRow(player)
		end
	end
	table.sort(rows, function(a, b) return a.source < b.source end)
	return ok(rows)
end)

publish('GetJobs', 'read', function()
	local character = OPX.Api.Get('character')
	if character == nil or character.ListGroups == nil then return refuse('error.unavailable') end
	return ok(character.ListGroups('job'))
end)

publish('GetGangs', 'read', function()
	local character = OPX.Api.Get('character')
	if character == nil or character.ListGroups == nil then return refuse('error.unavailable') end
	return ok(character.ListGroups('gang'))
end)

-- ── the item catalogue and a whole bag ───────────────────────────────────────

publish('GetItem', 'read', function(_, name)
	local api = inventory()
	if api == nil or api.GetItem == nil then return refuse('error.unavailable') end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then return refuse('export.badArgument') end
	return ok(OPX.Table.DeepCopy(api.GetItem(name)))
end)

publish('GetItems', 'read', function()
	local api = inventory()
	if api == nil or api.GetItems == nil then return refuse('error.unavailable') end
	return ok(api.GetItems())
end)

publish('GetInventory', 'read', function(_, target)
	local api = inventory()
	if api == nil or api.GetInventory == nil then return refuse('error.unavailable') end
	local who = targetOf(target)
	if who == nil then return refuse('export.badArgument') end
	local read = api.GetInventory(who)
	if not (type(read) == 'table' and read.ok) then return answered(read) end
	return ok(OPX.Table.DeepCopy(read.value))
end, byCitizen)

publish('CanCarryItem', 'read', function(_, target, name, count, metadata)
	local api = inventory()
	if api == nil or api.CanCarry == nil then return refuse('error.unavailable') end
	local args, refused = itemArgs(target, name, count, metadata, false)
	if args == nil then return refused end
	return answered(api.CanCarry(args.target, args.name, args.count, args.metadata))
end, byCitizen)

-- A NEW ITEM, ON BOTH HALVES, WHILE THE SERVER RUNS. Validated whole by the
-- catalogue's own `Register`, which every client runs on the same table; never
-- a weapon, never a name config or another resource already holds. Its owner
-- is the caller, and only the caller may register it again (which replaces it).
publish('RegisterItem', 'write', function(caller, name, definition)
	local api = inventory()
	if api == nil or api.RegisterItem == nil then return refuse('error.unavailable') end
	if type(name) ~= 'string' or #name < 1 or #name > 48 or type(definition) ~= 'table' then
		return refuse('export.badArgument')
	end
	local items = type(settings().ITEMS) == 'table' and settings().ITEMS or {}
	local cap = math.tointeger(tonumber(items.MAX_PER_CALLER)) or 64
	return answered(api.RegisterItem(name, OPX.Table.DeepCopy(definition), 'ext:' .. caller, cap))
end)

-- A USE HANDLER IN ANOTHER RESOURCE. When a player uses the item, the
-- inventory holds the slot and calls the caller's export
-- `export(source, { name, slot, count, metadata, label, citizenId })` inside its
-- handler deadline; the export answers `{ ok = true, consume = <n> }` to let
-- the use go ahead -- `consume` overriding the item's own -- or
-- `{ ok = false, error = <code> }` to refuse it. A use nobody answers in time
-- is refused, and nothing is consumed.
publish('RegisterUsableItem', 'write', function(caller, name, export)
	local api = inventory()
	if api == nil or api.RegisterUsable == nil or api.UsableOwner == nil then
		return refuse('error.unavailable')
	end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then return refuse('export.badArgument') end
	if type(export) ~= 'string' or #export < 1 or #export > 64 or not export:match('^[%w_]+$') then
		return refuse('export.badArgument')
	end
	if api.GetItem(name) == nil then return refuse('unknown_item') end
	local owner = 'ext:' .. caller
	local holder = api.UsableOwner(name)
	-- Never taken from another owner: a module's own handler, or another
	-- resource's, is a decision this caller does not get to override.
	if holder ~= nil and holder ~= owner then return refuse('export.usableTaken') end
	local registered, why = api.RegisterUsable(name, function(source, info)
		local calls = Open77.exports
		if type(calls) ~= 'table' or type(calls.call) ~= 'function' then
			return { ok = false, error = 'use_refused' }
		end
		local promise = calls.call(caller, export, source, info)
		if not promise then return { ok = false, error = 'use_refused' } end
		return promise:await()
	end, owner)
	if not registered then return refuse(why or 'error.unavailable') end
	return ok(true)
end)

publish('UnregisterUsableItem', 'write', function(caller, name)
	local api = inventory()
	if api == nil or api.UnregisterUsable == nil then return refuse('error.unavailable') end
	if type(name) ~= 'string' or #name < 1 or #name > 64 then return refuse('export.badArgument') end
	return ok(api.UnregisterUsable(name, 'ext:' .. caller) == true)
end)

-- A stash in front of a player, as `exports.ox_inventory:forceOpenInventory`
-- does it: the caller decided who may open it. Only a configured stash or one
-- in the caller's own `<resource>.` namespace, and a new one only under
-- `STASHES.CREATE_CAP`.
publish('OpenStash', 'write', function(caller, source, name, options)
	local api = inventory()
	if api == nil or api.OpenStash == nil then return refuse('error.unavailable') end
	local id = playerOf(source)
	if id == nil or nameOf(name) == nil then return refuse('export.badArgument') end
	if options ~= nil and type(options) ~= 'table' then return refuse('export.badArgument') end
	local opened = OPX.Table.DeepCopy(options or {})
	local stashes = type(settings().STASHES) == 'table' and settings().STASHES or {}
	opened.creator = caller
	opened.cap = math.tointeger(tonumber(stashes.CREATE_CAP))
	return answered(api.OpenStash(id, name, opened))
end, true)

-- ── vehicles ─────────────────────────────────────────────────────────────────

-- The stored state numbers, as words a caller can read.
local VEHICLE_STATE = { [0] = 'stored', [1] = 'out', [2] = 'impounded' }

--- A vehicle row as a caller is handed it: who, what, where, and how it is.
local function vehicleView(row)
	if type(row) ~= 'table' then return nil end
	return {
		plate = row.plate,
		citizenId = row.citizenId,
		record = row.record,
		garage = row.garage,
		state = VEHICLE_STATE[row.state] or tostring(row.state),
		health = row.health,
		spawned = row.spawned == true,
	}
end

--- A plate as the vehicles module writes one, or nil.
local function plateOf(value)
	if type(value) ~= 'string' or #value < 1 or #value > 12 or not value:match('^[%w%-]+$') then
		return nil
	end
	return value
end

--- The citizen id a vehicle call names: a loaded player's, or one given.
local function ownerOf(target)
	if type(target) == 'number' then
		local player, refused = loaded(target)
		if player == nil then return nil, refused end
		return player.PlayerData.citizenId
	end
	local citizenId = citizenOf(target)
	if citizenId == nil then return nil, refuse('export.badArgument') end
	return citizenId
end

publish('GetVehicle', 'read', function(_, plate)
	local vehicles = OPX.Api.Get('vehicles')
	if vehicles == nil or vehicles.Get == nil then return refuse('error.unavailable') end
	if plateOf(plate) == nil then return refuse('export.badArgument') end
	local read = vehicles.Get(plate)
	if not (type(read) == 'table' and read.ok) then return answered(read) end
	return ok(vehicleView(read.value))
end, true)

publish('GetOwnedVehicles', 'read', function(_, target)
	local vehicles = OPX.Api.Get('vehicles')
	if vehicles == nil or vehicles.List == nil then return refuse('error.unavailable') end
	local citizenId, refused = ownerOf(target)
	if citizenId == nil then return refused end
	local read = vehicles.List(citizenId)
	if not (type(read) == 'table' and read.ok) then return answered(read) end
	local rows = {}
	for index, row in ipairs(read.value or {}) do rows[index] = vehicleView(row) end
	return ok(rows)
end, true)

-- A vehicle row made for a character: a reward, a prize, a car sold by a
-- caller's own shop. Through `vehicles.Register`, so `PER_CHARACTER` holds and
-- `opx:on:vehicles:registered` is raised. No key is cut: `GiveKeys` does that.
publish('AddVehicle', 'write', function(_, target, record, options)
	local vehicles = OPX.Api.Get('vehicles')
	if vehicles == nil or vehicles.Register == nil then return refuse('error.unavailable') end
	local citizenId, refused = ownerOf(target)
	if citizenId == nil then return refused end
	if type(record) ~= 'string' or #record < 1 or #record > 128
		or not record:match('^[%w_%.]+$') then
		return refuse('export.badArgument')
	end
	if options ~= nil and type(options) ~= 'table' then return refuse('export.badArgument') end
	options = options or {}
	if options.garage ~= nil and nameOf(options.garage) == nil then
		return refuse('export.badArgument')
	end
	local made = vehicles.Register(citizenId, record, { garage = options.garage })
	if not (type(made) == 'table' and made.ok) then return answered(made) end
	return ok(vehicleView(made.value))
end, true)

publish('HasKeys', 'read', function(_, target, plate)
	local keys = OPX.Api.Get('vehiclekeys')
	if keys == nil or keys.Count == nil then return refuse('error.unavailable') end
	local who = targetOf(target)
	if who == nil or plateOf(plate) == nil then return refuse('export.badArgument') end
	return ok(keys.Count(who, plate) > 0)
end, byCitizen)

publish('GiveKeys', 'write', function(_, target, plate, model)
	local keys = OPX.Api.Get('vehiclekeys')
	if keys == nil or keys.Give == nil then return refuse('error.unavailable') end
	local who = targetOf(target)
	if who == nil or plateOf(plate) == nil then return refuse('export.badArgument') end
	if model ~= nil and (type(model) ~= 'string' or #model > 128) then
		return refuse('export.badArgument')
	end
	return answered(keys.Give(who, plate, model))
end, true)

-- ── a toast and a bar on one player's screen ─────────────────────────────────

-- The kinds a toast may be.
local TOAST_KINDS = { info = true, success = true, warning = true, error = true }

publish('Notify', 'write', function(_, source, message, kind, durationMs)
	local id = playerOf(source)
	if id == nil or type(message) ~= 'string' or message == '' then
		return refuse('export.badArgument')
	end
	if kind ~= nil and not TOAST_KINDS[kind] then return refuse('export.badArgument') end
	local duration = countOf(durationMs, 1000, 30000, 5000)
	if duration == nil then return refuse('export.badArgument') end
	local sent, why = OPX.Notify(id, OPX.Text.Clean(message, 240, '...'), kind or 'info', duration)
	if not sent then return refuse(why == 'duplicate' and 'export.duplicate' or 'error.unavailable') end
	return ok(true)
end)

-- A BAR THE SERVER STARTS AND THE SERVER JUDGES. The client draws it and says
-- how it ended; whether it FINISHED is decided by the server's own clock (see
-- `modules/progress/server/main.lua`). The answer is the bar's id; the outcome
-- arrives on `opx:on:progress:finished` as `(source, { id, owner, ending,
-- completed, elapsedMs })`, `owner` being the caller.
--
-- Bars each caller has up, by player, so a caller that stops takes them down.
local serverBars = {}

publish('StartProgress', 'write', function(caller, source, spec)
	local progress = OPX.Api.Get('progress')
	if progress == nil or progress.Start == nil then return refuse('error.unavailable') end
	local id = playerOf(source)
	if id == nil or type(spec) ~= 'table' then return refuse('export.badArgument') end
	local started = progress.Start(id, caller, {
		label = spec.label,
		durationMs = spec.durationMs,
		cancelable = spec.cancelable == true,
		animation = type(spec.animation) == 'table' and {
			name = spec.animation.name, variant = spec.animation.variant,
		} or nil,
	}, function(player)
		local held = serverBars[caller]
		if held ~= nil then held[player] = nil end
	end)
	if type(started) == 'table' and started.ok then
		serverBars[caller] = serverBars[caller] or {}
		serverBars[caller][id] = started.value.id
	end
	return answered(started)
end)

publish('StopProgress', 'write', function(caller, source, barId)
	local progress = OPX.Api.Get('progress')
	if progress == nil or progress.Stop == nil then return refuse('error.unavailable') end
	local id = playerOf(source)
	if id == nil or (barId ~= nil and math.type(barId) ~= 'integer') then
		return refuse('export.badArgument')
	end
	return answered(progress.Stop(id, caller, barId))
end)

-- ── crafting benches ─────────────────────────────────────────────────────────
-- A BENCH ANOTHER RESOURCE OWNS, on the crafting module's own rules: recipes
-- validated against the catalogue, materials and price taken on the server,
-- orders cooking in the database. The key is stored as `<caller>:<key>`, so a
-- caller can never take a bench a module or another resource registered. The
-- gate cannot be a function across a VM, so it is a JOB LIST: `jobs = { ncpd =
-- 0 }` (minimum grade) and `onDuty`. A player opens it with the client export
-- `OpenCraftingBench(key)`.

--- The stored key of a caller's bench key, or nil.
local function benchKeyOf(caller, key)
	if type(key) ~= 'string' or #key < 1 or #key > 32 or not key:match('^[%w_%-%.]+$') then
		return nil
	end
	return caller .. ':' .. key
end

--- The job gate a bench definition names, or nil for none, or false when malformed.
local function benchGate(jobs, onDuty)
	if jobs == nil then return nil end
	if type(jobs) ~= 'table' or next(jobs) == nil then return false end
	if onDuty ~= nil and type(onDuty) ~= 'boolean' then return false end
	for job, grade in pairs(jobs) do
		if nameOf(job) == nil or math.type(grade) ~= 'integer' or grade < 0 or grade > 255 then
			return false
		end
	end
	return function(player)
		local character = OPX.Api.Get('character')
		if character == nil then return false end
		for job, grade in pairs(jobs) do
			if character.HasJob(player, job, onDuty == true, grade) then return true end
		end
		return false
	end
end

publish('RegisterCraftingBench', 'write', function(caller, key, definition)
	local crafting = OPX.Api.Get('crafting')
	if crafting == nil or crafting.RegisterBench == nil then return refuse('error.unavailable') end
	local stored = benchKeyOf(caller, key)
	if stored == nil or type(definition) ~= 'table' then return refuse('export.badArgument') end
	local bench = OPX.Table.DeepCopy(definition)
	local gate = benchGate(bench.jobs, bench.onDuty)
	if gate == false then return refuse('export.badArgument') end
	bench.jobs, bench.onDuty = nil, nil
	bench.canUse = gate
	bench.owner = 'ext:' .. caller
	-- Registered again on a caller's restart: its own old bench goes first.
	if crafting.UnregisterBench ~= nil then crafting.UnregisterBench(stored, bench.owner) end
	local registered = crafting.RegisterBench(stored, bench)
	if not (type(registered) == 'table' and registered.ok) then return answered(registered) end
	return ok({ key = stored, recipes = registered.value })
end)

publish('UnregisterCraftingBench', 'write', function(caller, key)
	local crafting = OPX.Api.Get('crafting')
	if crafting == nil or crafting.UnregisterBench == nil then return refuse('error.unavailable') end
	local stored = benchKeyOf(caller, key)
	if stored == nil then return refuse('export.badArgument') end
	return answered(crafting.UnregisterBench(stored, 'ext:' .. caller))
end)

-- ── a caller that stops ──────────────────────────────────────────────────────
-- WHAT A CALLER HANDED THIS RESOURCE THAT ONLY IT CAN ANSWER GOES WITH IT: a
-- use handler would call an export that no longer exists (every use of the
-- item refused at the deadline), a bench would take orders for a resource that
-- is gone, a bar would hold a player for nobody. Its items stay -- stacks of
-- them are in bags -- and so does everything it wrote.
AddEventHandler(OPX.Host.RESOURCE_STOP, function(name)
	if type(name) ~= 'string' or name == GetCurrentResourceName() then return end
	-- ONLY A CALLER THAT IS STILL GONE. Another resource's stop reaches this VM
	-- QUEUED, on a later tick (devkit, server-api "Resource lifecycle events":
	-- "a stop/start can occur before the next tick", check `GetResourceState`),
	-- so on a `restart` the new instance can have registered its handlers,
	-- benches and bars before this runs -- and wiping by name would take those.
	-- And the server bus is host-wide: any resource can raise `onResourceStop`
	-- naming a running one. Either way, a caller that is running is left alone;
	-- its new registrations replace its old ones.
	local read, state = pcall(GetResourceState, name)
	if read and (state == 'running' or state == 'starting') then return end
	local owner = 'ext:' .. name
	local api = inventory()
	if api ~= nil and api.UnregisterUsables ~= nil then api.UnregisterUsables(owner) end
	local crafting = OPX.Api.Get('crafting')
	if crafting ~= nil and crafting.UnregisterBenches ~= nil then crafting.UnregisterBenches(owner) end
	local held = serverBars[name]
	serverBars[name] = nil
	local progress = OPX.Api.Get('progress')
	if progress ~= nil and progress.Stop ~= nil and held ~= nil then
		for player, barId in pairs(held) do progress.Stop(player, name, barId) end
	end
end)

if not hasExports() then
	Open77.log.warn('[exports] this host has no `exports`: the creator surface is not published')
end
