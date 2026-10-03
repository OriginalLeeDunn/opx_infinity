--- What a door is, and who may turn it: pure, and the same on both halves.
-- @author dop42
--
-- ONE SHAPE FOR A DOOR, and three ways in. `config/doorlock.lua` writes doors
-- in UPPER CASE like every other config file; the database row and the staff
-- panel's save carry the same fields in lower case. `FromConfig` turns the first
-- into the second, and `Normalize` is the one gate every door passes through
-- whatever it came from -- so a door the panel saved and a door the file
-- declared are refused for the same reasons, in the same words.
--
-- THE DECISION IS `Evaluate`, and it is ox_doorlock's `isAuthorised` with the
-- platform's own pieces: staff first (an ACL entry, not an ace), then the
-- characters list, then the groups -- through `OPX.JobGate`, the one place a
-- job requirement is decided in this resource -- then the key items. A door
-- that names none of them opens for staff only, which is ox's answer too.
-- Nothing here reads the world: the caller hands in a subject it built from
-- the host, so a test can drive every branch without one.

local M = OPX.Modules.Get('doorlock')

M.Access = {}
local Access = M.Access

local finiteNumber = OPX.Math.Finite

--- Limits on a door, so a row cannot grow past what one event can carry.
Access.MAX_KEY = 48
Access.MAX_NAME = 64
Access.MAX_GROUPS = 16
Access.MAX_ITEMS = 8
Access.MAX_CHARACTERS = 32
Access.MAX_PASSCODE = 32
Access.MAX_AUTOLOCK = 3600
Access.MAX_DOORS = 512
Access.MAX_SOUND = 64

local NAME_PATTERN = '^[%w_%-%.]+$'
local KEY_PATTERN = '^[%l%d_%-]+$'
local CITIZEN_PATTERN = '^[%w]+$'
local SOUND_PATTERN = '^[%w_%-%.]+$'

local function settings()
	local held = OPX.Config.MODULES.doorlock
	return type(held) == 'table' and held or {}
end

local function number(value, low, high)
	local n = finiteNumber(value)
	if n == nil or n < low or n > high then return nil end
	return n
end

local function integer(value, low, high)
	local n = number(value, low, high)
	if n == nil or n % 1 ~= 0 then return nil end
	return math.tointeger(n)
end

--- Whether a value is a boolean, else the fallback.
local function flag(value, fallback)
	if type(value) == 'boolean' then return value end
	return fallback
end

-- ── the settings, bounded ───────────────────────────────────────────────────

--- Metres a door is reached from when it names none.
-- @author dop42
-- @return number
function Access.UseRadius()
	return number(settings().USE_RADIUS, 0.5, Access.MaxReach()) or 2.0
end

--- The ceiling a door's own MAX_DISTANCE is clamped to.
-- @author dop42
-- @return number
function Access.MaxReach()
	return number(settings().MAX_REACH, 1.0, 12.0) or 8.0
end

--- Metres added to a reach on the server, for the press-to-read latency.
-- @author dop42
-- @return number
function Access.Slack()
	return number(settings().SLACK, 0.0, 4.0) or 1.0
end

--- The lockpick block, with every field present.
-- @author dop42
-- @return table { item, canPickUnlocked, breakChance, difficulty, default }
function Access.Lockpick()
	local block = type(settings().LOCKPICK) == 'table' and settings().LOCKPICK or {}
	local levels = {}
	local declared = type(block.DIFFICULTY) == 'table' and block.DIFFICULTY or {}
	for name, level in pairs(declared) do
		if type(name) == 'string' and name:match(KEY_PATTERN) and type(level) == 'table' then
			local duration = integer(level.DURATION_MS, 500, 60000)
			local chance = number(level.CHANCE, 0, 1)
			if duration and chance then levels[name] = { durationMs = duration, chance = chance } end
		end
	end
	if next(levels) == nil then levels.medium = { durationMs = 6000, chance = 0.6 } end
	local default = type(block.DEFAULT_DIFFICULTY) == 'string' and levels[block.DEFAULT_DIFFICULTY]
		and block.DEFAULT_DIFFICULTY or nil
	if default == nil then
		default = levels.medium and 'medium' or next(levels)
	end
	return {
		item = type(block.ITEM) == 'string' and block.ITEM:match(NAME_PATTERN) and block.ITEM
			or 'lockpick',
		canPickUnlocked = block.CAN_PICK_UNLOCKED == true,
		breakChance = number(block.BREAK_CHANCE, 0, 1) or 0.35,
		difficulty = levels,
		default = default,
	}
end

--- The difficulty names, sorted: what the panel offers.
-- @author dop42
-- @return string[]
function Access.Difficulties()
	local names = {}
	for name in pairs(Access.Lockpick().difficulty) do names[#names + 1] = name end
	table.sort(names, function(left, right)
		local levels = Access.Lockpick().difficulty
		return levels[left].durationMs < levels[right].durationMs
	end)
	return names
end

--- The item a bound key is.
-- @author dop42
-- @return string
function Access.KeyItem()
	local name = settings().KEY_ITEM
	return type(name) == 'string' and name:match(NAME_PATTERN) and name or 'door_key'
end

--- 'primary' or 'any'.
-- @author dop42
-- @return string
function Access.Membership()
	return settings().MEMBERSHIP == 'primary' and 'primary' or 'any'
end

-- ── identities ──────────────────────────────────────────────────────────────

--- A native door id in the platform's canonical spelling, or nil.
-- `0x` and sixteen upper-case hex digits, exactly what `open77_doors` keys its
-- registry by: a shorter id typed by hand is padded, a zero id is no door.
-- @author dop42
-- @param token any
-- @return string|nil
function Access.DoorId(token)
	if type(token) ~= 'string' then return nil end
	local digits = token:match('^0[xX](%x+)$')
	if digits == nil or #digits > 16 then return nil end
	digits = ('0'):rep(16 - #digits) .. digits:upper()
	if digits:match('^0+$') then return nil end
	return '0x' .. digits
end

--- A door key: the durable name a door is filed under, or nil.
-- @author dop42
-- @param token any
-- @return string|nil
function Access.Key(token)
	if type(token) ~= 'string' or #token < 1 or #token > Access.MAX_KEY then return nil end
	if not token:match(KEY_PATTERN) then return nil end
	return token
end

--- A key derived from a name, unique against `taken`.
-- @author dop42
-- @param name string|nil
-- @param taken fun(key: string): boolean
-- @return string
function Access.KeyFrom(name, taken)
	local base = type(name) == 'string' and name:lower():gsub('[^%l%d]+', '_'):gsub('^_+', '')
		:gsub('_+$', '') or ''
	if base == '' then base = 'door' end
	base = base:sub(1, Access.MAX_KEY - 4)
	local key, index = base, 1
	while taken(key) do
		index = index + 1
		key = ('%s_%d'):format(base, index)
	end
	return key
end

-- ── one door ────────────────────────────────────────────────────────────────

-- A group: `{ kind = 'job'|'gang', name, grade }`.
local function groupOf(raw)
	if type(raw) ~= 'table' then return nil end
	local kind, name = raw.kind, raw.name
	if kind == nil then
		if raw.JOB ~= nil then kind, name = 'job', raw.JOB
		elseif raw.GANG ~= nil then kind, name = 'gang', raw.GANG end
	end
	if kind ~= 'job' and kind ~= 'gang' then return nil end
	if type(name) ~= 'string' or #name > 48 or not name:match(NAME_PATTERN) then return nil end
	local grade = integer(raw.grade or raw.GRADE or 0, 0, 1000)
	if grade == nil then return nil end
	return { kind = kind, name = name, grade = grade }
end

-- A key item: `{ name, bound, remove }`. A bound key is never spent.
local function itemOf(raw)
	if type(raw) == 'string' then raw = { name = raw } end
	if type(raw) ~= 'table' then return nil end
	local name = raw.name or raw.NAME
	if type(name) ~= 'string' or #name > 48 or not name:match(NAME_PATTERN) then return nil end
	local bound = flag(raw.bound, flag(raw.BOUND, false))
	local remove = flag(raw.remove, flag(raw.REMOVE, false))
	return { name = name, bound = bound, remove = remove and not bound }
end

local function soundOf(value)
	if value == nil or value == '' then return nil end
	if type(value) ~= 'string' or #value > Access.MAX_SOUND or not value:match(SOUND_PATTERN) then
		return false
	end
	return value
end

--- A config block, in the lower-case shape `Normalize` reads.
-- @author dop42
-- @param definition table the UPPER-CASE block from `config/doorlock.lua`
-- @return table
function Access.FromConfig(definition)
	if type(definition) ~= 'table' then return {} end
	local d = definition
	return {
		name = d.NAME, doors = d.DOORS, x = d.X, y = d.Y, z = d.Z, bucket = d.BUCKET,
		locked = d.LOCKED, groups = d.GROUPS, items = d.ITEMS, characters = d.CHARACTERS,
		passcode = d.PASSCODE, autolock = d.AUTOLOCK, lockpick = d.LOCKPICK,
		difficulty = d.DIFFICULTY, maxDistance = d.MAX_DISTANCE, hideUi = d.HIDE_UI,
		onDuty = d.ON_DUTY, automatic = d.AUTOMATIC, lockSound = d.LOCK_SOUND,
		unlockSound = d.UNLOCK_SOUND,
	}
end

--- Validates one door, answering the record every other file reads.
-- @author dop42
--
-- Refused WHOLE on the first fault rather than repaired: a door whose group
-- list lost a row on the way in would open for fewer people than the staff
-- member who saved it believes, or -- worse -- a door whose ids lost one
-- would leave half of a double door unlocked for good.
-- @param key string
-- @param raw table the lower-case shape
-- @param origin string 'config' or 'db'
-- @return table|nil door
-- @return string|nil why
function Access.Normalize(key, raw, origin)
	key = Access.Key(key)
	if key == nil then return nil, 'bad_key' end
	if type(raw) ~= 'table' then return nil, 'bad_door' end

	local name = OPX.Text.Clean(raw.name, Access.MAX_NAME) or key
	name = OPX.String.Trim(name)
	if name == '' then name = key end

	if type(raw.doors) ~= 'table' or #raw.doors < 1 or #raw.doors > 2 then
		return nil, 'bad_doors'
	end
	local ids = {}
	for index = 1, #raw.doors do
		local id = Access.DoorId(raw.doors[index])
		if id == nil then return nil, 'bad_door_id' end
		if ids[1] == id then return nil, 'duplicate_door_id' end
		ids[index] = id
	end

	local x, y, z = number(raw.x, -1e6, 1e6), number(raw.y, -1e6, 1e6), number(raw.z, -1e6, 1e6)
	if x == nil or y == nil or z == nil then return nil, 'bad_position' end
	local bucket = raw.bucket == nil and 0 or integer(raw.bucket, 0, 1000000)
	if bucket == nil then return nil, 'bad_bucket' end

	local groups = {}
	if raw.groups ~= nil then
		if type(raw.groups) ~= 'table' or #raw.groups > Access.MAX_GROUPS then
			return nil, 'bad_groups'
		end
		for index = 1, #raw.groups do
			local group = groupOf(raw.groups[index])
			if group == nil then return nil, 'bad_group' end
			groups[#groups + 1] = group
		end
	end

	local items = {}
	if raw.items ~= nil then
		if type(raw.items) ~= 'table' or #raw.items > Access.MAX_ITEMS then return nil, 'bad_items' end
		for index = 1, #raw.items do
			local item = itemOf(raw.items[index])
			if item == nil then return nil, 'bad_item' end
			items[#items + 1] = item
		end
	end

	local characters = {}
	if raw.characters ~= nil then
		if type(raw.characters) ~= 'table' or #raw.characters > Access.MAX_CHARACTERS then
			return nil, 'bad_characters'
		end
		for index = 1, #raw.characters do
			local citizen = raw.characters[index]
			if type(citizen) ~= 'string' or #citizen > 32 or not citizen:match(CITIZEN_PATTERN) then
				return nil, 'bad_character'
			end
			characters[#characters + 1] = citizen
		end
	end

	local passcode = nil
	if raw.passcode ~= nil and raw.passcode ~= false and raw.passcode ~= '' then
		if type(raw.passcode) ~= 'string' or #raw.passcode > Access.MAX_PASSCODE
			or raw.passcode:find('%c') then
			return nil, 'bad_passcode'
		end
		passcode = raw.passcode
	end

	local autolock = raw.autolock == nil and 0 or integer(raw.autolock, 0, Access.MAX_AUTOLOCK)
	if autolock == nil then return nil, 'bad_autolock' end

	local pick = Access.Lockpick()
	local difficulty = raw.difficulty
	if difficulty == nil or difficulty == '' then difficulty = pick.default end
	if type(difficulty) ~= 'string' or pick.difficulty[difficulty] == nil then
		return nil, 'bad_difficulty'
	end

	local reach = Access.UseRadius()
	if raw.maxDistance ~= nil then
		reach = number(raw.maxDistance, 0.5, 100)
		if reach == nil then return nil, 'bad_distance' end
		if reach > Access.MaxReach() then reach = Access.MaxReach() end
	end

	local lockSound, unlockSound = soundOf(raw.lockSound), soundOf(raw.unlockSound)
	if lockSound == false or unlockSound == false then return nil, 'bad_sound' end

	return {
		key = key,
		name = name,
		origin = origin == 'config' and 'config' or 'db',
		ids = ids,
		x = x, y = y, z = z,
		bucket = bucket,
		locked = flag(raw.locked, true),
		groups = groups,
		items = items,
		characters = characters,
		passcode = passcode,
		autolock = autolock,
		lockpick = raw.lockpick == true,
		difficulty = difficulty,
		maxDistance = reach,
		hideUi = raw.hideUi == true,
		onDuty = raw.onDuty == true,
		automatic = raw.automatic == true,
		lockSound = lockSound,
		unlockSound = unlockSound,
	}
end

--- The door in the lower-case shape a row stores and a save carries.
-- @author dop42
-- @param door table
-- @param withPasscode boolean whether the code itself is kept
-- @return table
function Access.Plain(door, withPasscode)
	local groups, items, characters, ids = {}, {}, {}, {}
	for index, group in ipairs(door.groups) do
		groups[index] = { kind = group.kind, name = group.name, grade = group.grade }
	end
	for index, item in ipairs(door.items) do
		items[index] = { name = item.name, bound = item.bound, remove = item.remove }
	end
	for index, citizen in ipairs(door.characters) do characters[index] = citizen end
	for index, id in ipairs(door.ids) do ids[index] = id end
	return {
		name = door.name, doors = ids, x = door.x, y = door.y, z = door.z, bucket = door.bucket,
		locked = door.locked, groups = groups, items = items, characters = characters,
		passcode = withPasscode and door.passcode or nil,
		hasPasscode = door.passcode ~= nil,
		autolock = door.autolock, lockpick = door.lockpick, difficulty = door.difficulty,
		maxDistance = door.maxDistance, hideUi = door.hideUi, onDuty = door.onDuty,
		automatic = door.automatic, lockSound = door.lockSound, unlockSound = door.unlockSound,
	}
end

--- What every client in the bucket is told about a door: where it is, what
--- state it is in, and nothing about who may turn it.
-- @author dop42
-- @param door table
-- @param locked boolean the live state
-- @return table
function Access.Wire(door, locked)
	local ids = {}
	for index, id in ipairs(door.ids) do ids[index] = id end
	return {
		key = door.key, name = door.name, ids = ids,
		x = door.x, y = door.y, z = door.z,
		locked = locked == true,
		reach = door.maxDistance,
		hideUi = door.hideUi or nil,
		lockpick = door.lockpick or nil,
		passcode = door.passcode ~= nil or nil,
		lockSound = door.lockSound, unlockSound = door.unlockSound,
	}
end

--- The door as the config block that would declare it, for a staff member who
--- wants a panel door checked into `config/doorlock.lua`.
-- @author dop42
-- @param door table
-- @return string
function Access.ConfigBlock(door)
	local parts = {}
	local function add(text) parts[#parts + 1] = text end
	local ids = {}
	for _, id in ipairs(door.ids) do ids[#ids + 1] = ('%q'):format(id) end
	add(('%s = { NAME = %q, DOORS = { %s }, X = %.2f, Y = %.2f, Z = %.2f, BUCKET = %d, ' ..
		'LOCKED = %s,'):format(door.key, door.name, table.concat(ids, ', '), door.x, door.y, door.z,
		door.bucket, tostring(door.locked)))
	if #door.groups > 0 then
		local list = {}
		for _, group in ipairs(door.groups) do
			list[#list + 1] = ('{ %s = %q, GRADE = %d }'):format(group.kind:upper(), group.name, group.grade)
		end
		add((' GROUPS = { %s },'):format(table.concat(list, ', ')))
	end
	if #door.items > 0 then
		local list = {}
		for _, item in ipairs(door.items) do
			list[#list + 1] = ('{ NAME = %q%s%s }'):format(item.name, item.bound and ', BOUND = true' or '',
				item.remove and ', REMOVE = true' or '')
		end
		add((' ITEMS = { %s },'):format(table.concat(list, ', ')))
	end
	if #door.characters > 0 then
		local list = {}
		for _, citizen in ipairs(door.characters) do list[#list + 1] = ('%q'):format(citizen) end
		add((' CHARACTERS = { %s },'):format(table.concat(list, ', ')))
	end
	if door.autolock > 0 then add((' AUTOLOCK = %d,'):format(door.autolock)) end
	if door.lockpick then add((' LOCKPICK = true, DIFFICULTY = %q,'):format(door.difficulty)) end
	if door.onDuty then add(' ON_DUTY = true,') end
	if door.hideUi then add(' HIDE_UI = true,') end
	if door.automatic then add(' AUTOMATIC = true,') end
	add((' MAX_DISTANCE = %.1f },'):format(door.maxDistance))
	return table.concat(parts)
end

-- ── who may turn it ─────────────────────────────────────────────────────────

-- Failure ranking, so a refusal names the closest near-miss.
local RANK = { not_allowed = 0, no_key = 1, job_required = 2, grade_too_low = 3, off_duty = 4,
	job_stale = 1, no_character = 1 }

local function better(current, candidate)
	if candidate == nil then return current end
	if current == nil or (RANK[candidate] or 0) > (RANK[current] or 0) then return candidate end
	return current
end

--- Decides whether a subject may turn a door.
-- @author dop42
--
-- The subject is what the caller read from the world:
--   staff      boolean, the bypass ACL entry
--   snapshot   { job, jobs, gang, gangs, citizenId, atMs } or nil
--   items      fun(item: table): integer -- how many of that key the bag holds
-- A door with no groups, no items and no characters opens for staff only.
-- @param door table
-- @param subject table
-- @param nowMs number
-- @return boolean allowed
-- @return string how: staff, character, group, item -- or the refusal code
-- @return table|nil the item that opened it
function Access.Evaluate(door, subject, nowMs)
	subject = type(subject) == 'table' and subject or {}
	if subject.staff == true then return true, 'staff' end

	local snapshot = type(subject.snapshot) == 'table' and subject.snapshot or nil
	local worst = nil

	if snapshot ~= nil and type(snapshot.citizenId) == 'string' then
		for _, citizen in ipairs(door.characters) do
			if citizen == snapshot.citizenId then return true, 'character' end
		end
	end
	if #door.characters > 0 then worst = better(worst, 'not_allowed') end

	if #door.groups > 0 then
		local jobs, gangs = {}, {}
		for _, group in ipairs(door.groups) do
			local list = group.kind == 'job' and jobs or gangs
			-- The lowest grade named for one group wins: two rows for one job are
			-- two ways in, and the easier one is a way in.
			if list[group.name] == nil or group.grade < list[group.name] then
				list[group.name] = group.grade
			end
		end
		local policy = { maxAgeMs = 60000, membership = Access.Membership() }
		if next(jobs) ~= nil then
			local job = snapshot and { job = snapshot.job, jobs = snapshot.jobs, atMs = snapshot.atMs }
			local passed, why = OPX.JobGate.Evaluate({ jobs = jobs, onDuty = door.onDuty }, job,
				nowMs, policy)
			if passed then return true, 'group' end
			worst = better(worst, why)
		end
		if next(gangs) ~= nil then
			-- The gate reads a gang as a job with no duty clock: the gang the
			-- character runs with is `job`, every gang membership is `jobs`.
			local gang = snapshot and type(snapshot.gang) == 'table'
				and { job = snapshot.gang, jobs = snapshot.gangs, atMs = snapshot.atMs } or nil
			if snapshot and gang == nil then
				gang = { job = { name = '' }, jobs = snapshot.gangs, atMs = snapshot.atMs }
			end
			local passed, why = OPX.JobGate.Evaluate({ jobs = gangs }, gang, nowMs, policy)
			if passed then return true, 'group' end
			worst = better(worst, why)
		end
	end

	if #door.items > 0 then
		local count = type(subject.items) == 'function' and subject.items or nil
		for _, item in ipairs(door.items) do
			local held = count and tonumber(count(item)) or 0
			if held and held > 0 then return true, 'item', item end
		end
		worst = better(worst, 'no_key')
	end

	return false, worst or 'not_allowed'
end

-- ── the config file ─────────────────────────────────────────────────────────

--- Every config door, normalised, and the lines naming each one refused.
-- @author dop42
-- @return table<string, table>
-- @return string[]
function Access.ConfigDoors()
	local doors, problems = {}, {}
	local declared = settings().DOORS
	if declared ~= nil and type(declared) ~= 'table' then
		problems[1] = 'DOORS must be a table of key -> door'
		return doors, problems
	end
	for key, definition in pairs(declared or {}) do
		local door, why = Access.Normalize(key, Access.FromConfig(definition), 'config')
		if door == nil then
			problems[#problems + 1] = ('DOORS.%s refused: %s'):format(tostring(key), why)
		else
			doors[door.key] = door
		end
	end
	return doors, problems
end

--- Squared distance from a door's position.
-- @author dop42
-- @param door table
-- @param x number
-- @param y number
-- @param z number|nil when nil the distance is measured across the ground
-- @return number
function Access.DistanceSquared(door, x, y, z)
	local dz = z ~= nil and (door.z - z) or 0
	return (door.x - x) ^ 2 + (door.y - y) ^ 2 + dz ^ 2
end
