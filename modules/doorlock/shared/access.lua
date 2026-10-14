--- What a door is, and who may turn it: pure, and the same on both halves.
-- @author dop42
--
-- ONE SHAPE FOR A DOOR, ox's, and four ways in. The staff panel's save, an
-- export's `createDoor` / `editDoor`, a `DOORS` block of `config/doorlock.lua`
-- (`FromConfig`) and a row of the first version's table (`FromLegacy`) all end
-- in `Normalize`, the one gate every door passes through -- so a door is refused
-- for the same reasons, in the same words, wherever it came from.
--
-- THE DECISION IS `Evaluate`, ox's `isAuthorised` line for line with the
-- platform's own pieces: the bypass grant for ox's ace, the character module's
-- citizen id for ox's `GetCharacterId`, `OPX.JobGate` for ox's `HasGroup` (the
-- one place a job requirement is decided in this resource), the inventory's
-- count for ox_inventory's `Search`. Nothing here reads the world: the caller
-- hands in a subject it built from the host, so a test drives every branch
-- without one.

local M = OPX.Modules.Get('doorlock')

M.Access = {}
local Access = M.Access

local finiteNumber = OPX.Math.Finite

--- Limits on a door, so a row cannot grow past what one event can carry.
Access.MAX_NAME = 64
Access.MAX_GROUPS = 16
Access.MAX_ITEMS = 8
Access.MAX_CHARACTERS = 32
Access.MAX_PASSCODE = 32
Access.MAX_AUTOLOCK = 3600
Access.MAX_DOORS = 512
Access.MAX_SOUND = 64
Access.MAX_STEPS = 10
Access.MAX_ID = 2147483647

local NAME_PATTERN = '^[%w_%-%.]+$'
local METADATA_PATTERN = '^[%w_%-%.:]+$'
local CITIZEN_PATTERN = '^[%w]+$'
local SOUND_PATTERN = '^[%w_%-%.]+$'
local STEP_PATTERN = '^[%l%d_]+$'

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

local function clamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end

-- ── the settings, bounded ───────────────────────────────────────────────────

--- Metres a door is reached from when it names none.
-- @author dop42
-- @return number
function Access.UseRadius()
	return number(settings().USE_RADIUS, 0.5, Access.MaxReach()) or 2.0
end

--- The ceiling a door's own `maxDistance` is clamped to.
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

--- 'primary' or 'any'.
-- @author dop42
-- @return string
function Access.Membership()
	return settings().MEMBERSHIP == 'primary' and 'primary' or 'any'
end

--- The item `/opx.doorlock.key` cuts when a door's items name none.
-- @author dop42
-- @return string
function Access.KeyItem()
	local name = settings().KEY_ITEM
	return type(name) == 'string' and name:match(NAME_PATTERN) and name or 'door_key'
end

--- The named lockpick steps, each `{ durationMs, chance }`.
local function levels()
	local block = type(settings().LOCKPICK) == 'table' and settings().LOCKPICK or {}
	local out = {}
	local declared = type(block.DIFFICULTY) == 'table' and block.DIFFICULTY or {}
	for name, level in pairs(declared) do
		if type(name) == 'string' and name:match(STEP_PATTERN) and type(level) == 'table' then
			local duration = integer(level.DURATION_MS, 300, 30000)
			local chance = number(level.CHANCE, 0, 1)
			if duration and chance then out[name] = { durationMs = duration, chance = chance } end
		end
	end
	if next(out) == nil then out.medium = { durationMs = 2500, chance = 0.6 } end
	return out
end

--- One lockpick step as ox writes it: a level name, or a custom
--- `{ areaSize, speedMultiplier }`. Answers the clean step or nil.
-- @author dop42
-- @param raw any
-- @param known table|nil the named levels, read once by a caller in a loop
-- @return string|table|nil
function Access.Step(raw, known)
	known = known or levels()
	if type(raw) == 'string' then return known[raw] and raw or nil end
	if type(raw) ~= 'table' then return nil end
	local area = number(raw.areaSize, 1, 360)
	local speed = number(raw.speedMultiplier, 0.1, 10)
	if area == nil or speed == nil then return nil end
	return { areaSize = area, speedMultiplier = speed }
end

--- What one step costs: how long its bar runs and the chance its roll passes.
--- A custom step is read as ox's ring would play: a wider zone is easier, a
--- faster needle is harder and shorter.
-- @author dop42
-- @param step string|table a clean step
-- @param known table|nil
-- @return table { durationMs, chance }
function Access.StepCost(step, known)
	known = known or levels()
	if type(step) == 'string' then
		return known[step] or known.medium or select(2, next(known))
	end
	return {
		durationMs = math.floor(clamp(2500 / step.speedMultiplier, 500, 10000)),
		chance = clamp(step.areaSize / 60 / step.speedMultiplier, 0.05, 0.95),
	}
end

--- The lockpick block, with every field present.
-- @author dop42
-- @return table { items, canPickUnlocked, default, levels, breakSuccess, breakFail }
function Access.Lockpick()
	local block = type(settings().LOCKPICK) == 'table' and settings().LOCKPICK or {}
	local known = levels()
	local items = {}
	for _, name in ipairs(type(block.ITEMS) == 'table' and block.ITEMS or {}) do
		if type(name) == 'string' and name:match(NAME_PATTERN) then items[#items + 1] = name end
	end
	if #items == 0 then items[1] = 'lockpick' end
	local default = {}
	for _, raw in ipairs(type(block.DEFAULT) == 'table' and block.DEFAULT or {}) do
		local step = Access.Step(raw, known)
		if step ~= nil and #default < Access.MAX_STEPS then default[#default + 1] = step end
	end
	if #default == 0 then default[1] = known.medium and 'medium' or next(known) end
	local breaks = type(block.BREAK_CHANCE) == 'table' and block.BREAK_CHANCE or {}
	return {
		items = items,
		canPickUnlocked = block.CAN_PICK_UNLOCKED == true,
		default = default,
		levels = known,
		breakSuccess = number(breaks.SUCCESS, 0, 1) or 0.01,
		breakFail = number(breaks.FAIL, 0, 1) or 0.2,
	}
end

--- The step names, easiest first: what the panel's select offers.
-- @author dop42
-- @return string[]
function Access.Difficulties()
	local known = levels()
	local names = {}
	for name in pairs(known) do names[#names + 1] = name end
	table.sort(names, function(left, right)
		if known[left].chance ~= known[right].chance then return known[left].chance > known[right].chance end
		return left < right
	end)
	return names
end

--- The sounds the panel offers, and the ones a door without its own plays.
-- @author dop42
-- @return string[] list
-- @return table { lock, unlock }
function Access.Sounds()
	local block = type(settings().SOUNDS) == 'table' and settings().SOUNDS or {}
	local list = {}
	for _, name in ipairs(type(block.LIST) == 'table' and block.LIST or {}) do
		if type(name) == 'string' and #name <= Access.MAX_SOUND and name:match(SOUND_PATTERN) then
			list[#list + 1] = name
		end
	end
	local default = type(block.DEFAULT) == 'table' and block.DEFAULT or {}
	local function pick(value)
		return type(value) == 'string' and value ~= '' and value:match(SOUND_PATTERN) and value or nil
	end
	return list, { lock = pick(default.LOCK), unlock = pick(default.UNLOCK) }
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

--- A door id, ox's integer, or nil. A numeric string is read as one: a command
--- line and a JSON round trip both hand numbers over as text.
-- @author dop42
-- @param token any
-- @return integer|nil
function Access.Id(token)
	if type(token) == 'string' and token:match('^%d+$') then token = tonumber(token) end
	return integer(token, 1, Access.MAX_ID)
end

-- ── one door ────────────────────────────────────────────────────────────────

local function point(raw)
	if type(raw) ~= 'table' then return nil end
	local x = number(raw.x or raw[1], -1e6, 1e6)
	local y = number(raw.y or raw[2], -1e6, 1e6)
	local z = number(raw.z or raw[3], -1e6, 1e6)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

local function groupName(value)
	if type(value) ~= 'string' or #value > 48 or not value:match(NAME_PATTERN) then return nil end
	return value
end

-- Groups in any of the shapes a door has been written in: ox's map of name to
-- grade, the panel's rows `{ name, grade }`, and the first version's
-- `{ kind, name, grade }` / `{ JOB = ..., GRADE = ... }`. Answers ox's map, or
-- nil and a reason. Two rows for one group keep the LOWER grade: two ways in,
-- and the easier one is a way in.
local function groupsOf(raw)
	local map, count = {}, 0
	local function add(name, grade)
		name = groupName(name)
		grade = integer(grade == nil and 0 or grade, 0, 1000)
		if name == nil or grade == nil then return false end
		if map[name] == nil then
			count = count + 1
			if count > Access.MAX_GROUPS then return false end
			map[name] = grade
		elseif grade < map[name] then
			map[name] = grade
		end
		return true
	end
	if raw == nil then return map, 0 end
	if type(raw) ~= 'table' then return nil, 'bad_groups' end
	if #raw > 0 then
		for index = 1, #raw do
			local row = raw[index]
			if type(row) ~= 'table' then return nil, 'bad_group' end
			local name = row.name or row.JOB or row.GANG or row.NAME
			-- A panel row left blank is the empty row ox's form always keeps.
			if not (name == '' or name == nil) then
				if not add(name, row.grade or row.GRADE) then return nil, 'bad_group' end
			end
		end
	else
		for name, grade in pairs(raw) do
			if not add(name, grade) then return nil, 'bad_group' end
		end
	end
	return map, count
end

-- One item row: `{ name, metadata?, remove? }`. A bare string is an item name,
-- which is how ox stored them before `remove` existed.
local function itemOf(raw)
	if type(raw) == 'string' then raw = { name = raw } end
	if type(raw) ~= 'table' then return nil end
	local name = raw.name or raw.NAME
	if type(name) ~= 'string' or #name > 48 or not name:match(NAME_PATTERN) then return nil end
	local metadata = raw.metadata
	if metadata == nil then metadata = raw.METADATA end
	if metadata == '' or metadata == false then metadata = nil end
	if metadata ~= nil and (type(metadata) ~= 'string' or #metadata > 48
		or not metadata:match(METADATA_PATTERN)) then
		return nil
	end
	local remove = raw.remove
	if remove == nil then remove = raw.REMOVE end
	return { name = name, metadata = metadata, remove = remove == true or nil }
end

local function soundOf(value)
	if value == nil or value == '' or value == false then return nil end
	if type(value) ~= 'string' or #value > Access.MAX_SOUND or not value:match(SOUND_PATTERN) then
		return false
	end
	return value
end

-- ox's state: 1 locked, 0 unlocked, from a number, a boolean or nothing.
local function stateOf(value, fallback)
	if value == 1 or value == true then return 1 end
	if value == 0 or value == false then return 0 end
	return fallback
end

--- A config block, in the lower-case shape `Normalize` reads.
-- @author dop42
-- @param definition table the UPPER-CASE block from `config/doorlock.lua`
-- @return table
function Access.FromConfig(definition)
	if type(definition) ~= 'table' then return {} end
	local d = definition
	local doors = {}
	for index, native in ipairs(type(d.DOORS) == 'table' and d.DOORS or {}) do
		doors[index] = { native = native }
	end
	return {
		name = d.NAME, doors = doors, coords = d.COORDS, bucket = d.BUCKET, state = d.STATE,
		groups = d.GROUPS, items = d.ITEMS, characters = d.CHARACTERS, passcode = d.PASSCODE,
		autolock = d.AUTOLOCK, lockpick = d.LOCKPICK, lockpickDifficulty = d.LOCKPICK_DIFFICULTY,
		maxDistance = d.MAX_DISTANCE, auto = d.AUTO, hideUi = d.HIDE_UI, holdOpen = d.HOLD_OPEN,
		onDuty = d.ON_DUTY, lockSound = d.LOCK_SOUND, unlockSound = d.UNLOCK_SOUND,
	}
end

--- A row of the first version's table (`opx77_doorlock`), in ox's shape.
-- @author dop42
--
-- That version kept a key, one position for both leaves, `locked`, groups as
-- `{ kind, name, grade }` rows, a single difficulty name and BOUND key items --
-- an item that opened only when its metadata named the door. A bound item
-- becomes ox's `metadata` match on the old key, and `/opx.doorlock.key` cut
-- those keys with `door = <key>`, which the server still accepts (see
-- `countItem`), so every key already in a bag keeps opening its door.
-- @param key string the old door key
-- @param plain table the decoded `data` column
-- @param bucket integer|nil the row's bucket column
-- @return table
function Access.FromLegacy(key, plain, bucket)
	if type(plain) ~= 'table' then return {} end
	local doors = {}
	local at = { x = plain.x, y = plain.y, z = plain.z }
	for index, native in ipairs(type(plain.doors) == 'table' and plain.doors or {}) do
		doors[index] = { native = native, coords = at }
	end
	local items = {}
	for index, item in ipairs(type(plain.items) == 'table' and plain.items or {}) do
		if type(item) == 'table' then
			items[index] = { name = item.name, remove = item.remove == true and not item.bound or nil,
				metadata = item.bound == true and key or nil }
		end
	end
	local difficulty = plain.difficulty
	return {
		name = plain.name, doors = doors, coords = at, bucket = plain.bucket or bucket,
		state = plain.locked == false and 0 or 1, groups = plain.groups, items = items,
		characters = plain.characters, passcode = plain.passcode, autolock = plain.autolock,
		lockpick = plain.lockpick, lockpickDifficulty = type(difficulty) == 'string' and { difficulty } or nil,
		maxDistance = plain.maxDistance, auto = plain.automatic, hideUi = plain.hideUi,
		onDuty = plain.onDuty, lockSound = plain.lockSound, unlockSound = plain.unlockSound,
	}
end

--- Validates one door, answering the record every other file reads.
-- @author dop42
--
-- Refused WHOLE on the first fault rather than repaired: a door whose group
-- list lost a row on the way in would open for fewer people than the staff
-- member who saved it believes, or -- worse -- a door whose leaves lost one
-- would leave half of a double door unlocked for good.
--
-- ox's leaves: a single door is `native` (ox's `model` + `coords`: here the
-- native id names the door), a double door is `doors = { {native, coords},
-- {native, coords} }` and its `coords` default to the middle of the two, as in
-- ox's `createDoor`.
-- @param id integer|nil ox's id; nil while a door is checked before its insert
-- @param raw table ox's shape
-- @param origin string|nil 'config:<key>', 'legacy:<key>', or nil for a panel door
-- @return table|nil door
-- @return string|nil why
function Access.Normalize(id, raw, origin)
	if id ~= nil then
		id = Access.Id(id)
		if id == nil then return nil, 'bad_id' end
	end
	if type(raw) ~= 'table' then return nil, 'bad_door' end

	-- The leaves: `doors` (one or two), or ox's single `native`.
	local leaves = {}
	local list = raw.doors
	if type(list) == 'table' and #list > 0 then
		if #list > 2 then return nil, 'bad_doors' end
		for index = 1, #list do
			local leaf = list[index]
			if type(leaf) == 'string' then leaf = { native = leaf } end
			if type(leaf) ~= 'table' then return nil, 'bad_doors' end
			local native = Access.DoorId(leaf.native or leaf.id)
			if native == nil then return nil, 'bad_door_id' end
			if leaves[1] ~= nil and leaves[1].native == native then return nil, 'duplicate_door_id' end
			leaves[index] = { native = native, coords = point(leaf.coords or leaf) }
		end
	elseif raw.native ~= nil then
		local native = Access.DoorId(raw.native)
		if native == nil then return nil, 'bad_door_id' end
		leaves[1] = { native = native }
	else
		return nil, 'bad_doors'
	end

	local coords = point(raw.coords) or point(raw)
	if coords == nil and #leaves == 2 and leaves[1].coords and leaves[2].coords then
		local a, b = leaves[1].coords, leaves[2].coords
		coords = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 }
	end
	if coords == nil and leaves[1].coords ~= nil then coords = leaves[1].coords end
	if coords == nil then return nil, 'bad_position' end
	for _, leaf in ipairs(leaves) do leaf.coords = leaf.coords or coords end

	local name = OPX.Text.Clean(raw.name, Access.MAX_NAME)
	name = name and OPX.String.Trim(name) or ''
	-- ox names a nameless door after its coords; so does this.
	if name == '' then name = ('%.1f, %.1f, %.1f'):format(coords.x, coords.y, coords.z) end

	local bucket = raw.bucket == nil and 0 or integer(raw.bucket, 0, 1000000)
	if bucket == nil then return nil, 'bad_bucket' end

	local groups, groupCount = groupsOf(raw.groups)
	if groups == nil then return nil, groupCount end

	local items = {}
	if raw.items ~= nil then
		if type(raw.items) ~= 'table' then return nil, 'bad_items' end
		for index = 1, #raw.items do
			local entry = raw.items[index]
			local blank = type(entry) == 'table' and (entry.name or entry.NAME or '') == ''
			if not blank then
				local item = itemOf(entry)
				if item == nil then return nil, 'bad_item' end
				if #items >= Access.MAX_ITEMS then return nil, 'bad_items' end
				items[#items + 1] = item
			end
		end
	end

	local characters = {}
	if raw.characters ~= nil then
		if type(raw.characters) ~= 'table' then return nil, 'bad_characters' end
		for index = 1, #raw.characters do
			local citizen = raw.characters[index]
			if type(citizen) == 'number' and citizen % 1 == 0 then citizen = tostring(math.tointeger(citizen)) end
			if citizen ~= '' then
				if type(citizen) ~= 'string' or #citizen > 32 or not citizen:match(CITIZEN_PATTERN) then
					return nil, 'bad_character'
				end
				if #characters >= Access.MAX_CHARACTERS then return nil, 'bad_characters' end
				characters[#characters + 1] = citizen
			end
		end
	end

	local passcode = raw.passcode
	if passcode == false or passcode == '' then passcode = nil end
	if passcode ~= nil then
		-- ox's form sends a numeric code as a number. One past 2^63 has no
		-- integer form, and `tostring(nil)` stored the code as the word "nil".
		if type(passcode) == 'number' and passcode % 1 == 0 then
			local whole = math.tointeger(passcode)
			if whole == nil then return nil, 'bad_passcode' end
			passcode = tostring(whole)
		end
		if type(passcode) ~= 'string' or #passcode > Access.MAX_PASSCODE or passcode:find('%c') then
			return nil, 'bad_passcode'
		end
	end

	local autolock = (raw.autolock == nil or raw.autolock == false) and 0
		or integer(raw.autolock, 0, Access.MAX_AUTOLOCK)
	if autolock == nil then return nil, 'bad_autolock' end

	local steps = nil
	if raw.lockpickDifficulty ~= nil and raw.lockpickDifficulty ~= false then
		if type(raw.lockpickDifficulty) ~= 'table' then return nil, 'bad_difficulty' end
		local known = levels()
		for index = 1, #raw.lockpickDifficulty do
			local entry = raw.lockpickDifficulty[index]
			if entry ~= '' then
				local step = Access.Step(entry, known)
				if step == nil then return nil, 'bad_difficulty' end
				steps = steps or {}
				if #steps >= Access.MAX_STEPS then return nil, 'bad_difficulty' end
				steps[#steps + 1] = step
			end
		end
	end

	local reach = Access.UseRadius()
	if raw.maxDistance ~= nil and raw.maxDistance ~= 0 then
		reach = number(raw.maxDistance, 0.5, 100)
		if reach == nil then return nil, 'bad_distance' end
		if reach > Access.MaxReach() then reach = Access.MaxReach() end
	end

	local lockSound, unlockSound = soundOf(raw.lockSound), soundOf(raw.unlockSound)
	if lockSound == false or unlockSound == false then return nil, 'bad_sound' end

	local ids = {}
	for index, leaf in ipairs(leaves) do ids[index] = leaf.native end

	return {
		id = id,
		name = name,
		origin = type(origin) == 'string' and origin or nil,
		bucket = bucket,
		coords = coords,
		native = #leaves == 1 and leaves[1].native or nil,
		doors = #leaves == 2 and leaves or nil,
		ids = ids,
		state = stateOf(raw.state, 1),
		maxDistance = reach,
		autolock = autolock,
		auto = raw.auto == true,
		lockpick = raw.lockpick == true,
		lockpickDifficulty = steps,
		groups = groups,
		groupCount = groupCount,
		items = items,
		characters = characters,
		passcode = passcode,
		lockSound = lockSound,
		unlockSound = unlockSound,
		hideUi = raw.hideUi == true,
		holdOpen = raw.holdOpen == true,
		onDuty = raw.onDuty == true,
	}
end

local function copyPoint(at) return { x = at.x, y = at.y, z = at.z } end

--- The door in ox's stored shape -- what a row's `data` column holds, what an
--- edit carries and what the panel's detail draws (ox's `encodeData`).
-- @author dop42
-- @param door table
-- @param withPasscode boolean whether the code itself is kept
-- @return table
function Access.Encode(door, withPasscode)
	local groups, items, characters, steps = nil, {}, {}, nil
	if door.groupCount > 0 then
		groups = {}
		for name, grade in pairs(door.groups) do groups[name] = grade end
	end
	for index, item in ipairs(door.items) do
		items[index] = { name = item.name, metadata = item.metadata, remove = item.remove }
	end
	for index, citizen in ipairs(door.characters) do characters[index] = citizen end
	if door.lockpickDifficulty ~= nil then
		steps = {}
		for index, step in ipairs(door.lockpickDifficulty) do
			steps[index] = type(step) == 'table'
				and { areaSize = step.areaSize, speedMultiplier = step.speedMultiplier } or step
		end
	end
	local doors = nil
	if door.doors ~= nil then
		doors = {}
		for index, leaf in ipairs(door.doors) do
			doors[index] = { native = leaf.native, coords = copyPoint(leaf.coords) }
		end
	end
	return {
		name = door.name, coords = copyPoint(door.coords), bucket = door.bucket,
		native = door.native, doors = doors, state = door.state,
		maxDistance = door.maxDistance, autolock = door.autolock > 0 and door.autolock or nil,
		auto = door.auto or nil, lockpick = door.lockpick or nil, lockpickDifficulty = steps,
		groups = groups, items = #items > 0 and items or nil,
		characters = #characters > 0 and characters or nil,
		passcode = withPasscode and door.passcode or nil,
		hasPasscode = (not withPasscode and door.passcode ~= nil) or nil,
		lockSound = door.lockSound, unlockSound = door.unlockSound,
		hideUi = door.hideUi or nil, holdOpen = door.holdOpen or nil, onDuty = door.onDuty or nil,
	}
end

--- ox's `getDoor`: what another resource is told about a door. No code, ever.
-- @author dop42
-- @param door table
-- @param state integer the live state
-- @return table
function Access.Public(door, state)
	local plain = Access.Encode(door, false)
	return {
		id = door.id, name = door.name, state = state, coords = plain.coords, bucket = door.bucket,
		characters = plain.characters, groups = plain.groups, items = plain.items,
		maxDistance = door.maxDistance,
	}
end

--- What every client in the bucket is told about a door: where it is, what
--- state it is in, and nothing about who may turn it.
-- @author dop42
-- @param door table
-- @param state integer the live state
-- @return table
function Access.Wire(door, state)
	local ids = {}
	for index, id in ipairs(door.ids) do ids[index] = id end
	return {
		id = door.id, name = door.name, ids = ids,
		x = door.coords.x, y = door.coords.y, z = door.coords.z,
		state = state,
		reach = door.maxDistance,
		hideUi = door.hideUi or nil,
		holdOpen = door.holdOpen or nil,
		lockpick = door.lockpick or nil,
		passcode = door.passcode ~= nil or nil,
		lockSound = door.lockSound, unlockSound = door.unlockSound,
	}
end

--- The row the staff list draws (ox's table: id, name, and the zone ox reads
--- off the map -- the page shows the state and the distance instead).
-- @author dop42
-- @param door table
-- @param state integer
-- @return table
function Access.Summary(door, state)
	return { id = door.id, name = door.name, state = state, bucket = door.bucket,
		x = door.coords.x, y = door.coords.y, z = door.coords.z, double = door.doors ~= nil or nil,
		seeded = door.origin ~= nil and door.origin:match('^config:') ~= nil or nil }
end

-- ── who may turn it ─────────────────────────────────────────────────────────

-- Failure ranking, so a refusal names the closest near-miss.
local RANK = { not_allowed = 0, no_key = 1, job_stale = 1, no_character = 1, job_required = 2,
	grade_too_low = 3, off_duty = 4 }

local function better(current, candidate)
	if candidate == nil then return current end
	if current == nil or (RANK[candidate] or 0) > (RANK[current] or 0) then return candidate end
	return current
end

-- Which list a group name belongs to, read off the character config: ox's
-- `HasGroup` asks one question of both, and so does this when a name is in
-- neither (a server without the character module's config).
local function kindOf(name)
	local character = OPX.Config.MODULES.character
	if type(character) ~= 'table' then return 'both' end
	if type(character.GANGS) == 'table' and character.GANGS[name] ~= nil then return 'gang' end
	if type(character.JOBS) == 'table' and character.JOBS[name] ~= nil then return 'job' end
	return 'both'
end

-- ox's `IsPlayerInGroup(player, door.groups)`: any one group at its grade.
local function inGroup(door, snapshot, nowMs)
	local jobs, gangs = {}, {}
	for name, grade in pairs(door.groups) do
		local kind = kindOf(name)
		if kind ~= 'gang' then jobs[name] = grade end
		if kind ~= 'job' then gangs[name] = grade end
	end
	local policy = { maxAgeMs = 60000, membership = Access.Membership() }
	local worst = nil
	if next(jobs) ~= nil then
		local job = snapshot and { job = snapshot.job, jobs = snapshot.jobs, atMs = snapshot.atMs }
		local passed, why = OPX.JobGate.Evaluate({ jobs = jobs, onDuty = door.onDuty }, job, nowMs, policy)
		if passed then return true end
		worst = better(worst, why)
	end
	if next(gangs) ~= nil then
		-- The gate reads a gang as a job with no duty clock: the gang the
		-- character runs with is `job`, every gang membership is `jobs`.
		local gang = nil
		if snapshot then
			gang = { job = type(snapshot.gang) == 'table' and snapshot.gang or { name = '' },
				jobs = snapshot.gangs, atMs = snapshot.atMs }
		end
		local passed, why = OPX.JobGate.Evaluate({ jobs = gangs }, gang, nowMs, policy)
		if passed then return true end
		-- A name that was only tried as a gang because it is in neither list must
		-- not drown the job's own reason.
		if next(jobs) == nil then worst = better(worst, why) end
	end
	return false, worst or 'job_required'
end

--- Decides whether a subject may turn a door: ox's `isAuthorised`.
-- @author dop42
--
-- The subject is what the caller read from the world:
--   staff      boolean, the bypass grant (ox's PlayerAceAuthorised)
--   acl        boolean, the ACL entry `doorlock.<id>` (ox's ace `doorlock.<name>`)
--   snapshot   { job, jobs, gang, gangs, citizenId, atMs } or nil
--   items      fun(item: table): integer -- how many of that item the bag holds
--
-- ox, in its order: a listed character opens outright; else the groups decide
-- (in, or refused); else, when no group let them in, the items decide. A door
-- with a code starts out "authorised by the code" -- so a code-only door asks
-- everybody for it -- and whoever got past the groups and items still has to
-- type it. A listed character never does.
-- @param door table
-- @param subject table
-- @param nowMs number
-- @return boolean allowed (before the code)
-- @return string how: staff, acl, character, group, item, passcode -- or the refusal code
-- @return table|nil the item that opened it
-- @return boolean whether the code is still to be given
function Access.Evaluate(door, subject, nowMs)
	subject = type(subject) == 'table' and subject or {}
	if subject.staff == true then return true, 'staff', nil, false end
	if subject.acl == true then return true, 'acl', nil, false end

	local snapshot = type(subject.snapshot) == 'table' and subject.snapshot or nil
	local authorised = door.passcode ~= nil and 'passcode' or false
	local worst, item = nil, nil

	if snapshot ~= nil and type(snapshot.citizenId) == 'string' then
		for _, citizen in ipairs(door.characters) do
			if citizen == snapshot.citizenId then return true, 'character', nil, false end
		end
	end
	if #door.characters > 0 then worst = better(worst, 'not_allowed') end

	if door.groupCount > 0 then
		local passed, why = inGroup(door, snapshot, nowMs)
		if passed then
			authorised = 'group'
		else
			authorised = nil
			worst = better(worst, why)
		end
	end

	if not authorised and #door.items > 0 then
		local count = type(subject.items) == 'function' and subject.items or nil
		for _, entry in ipairs(door.items) do
			local held = count and tonumber(count(entry)) or 0
			if held and held > 0 then
				authorised, item = 'item', entry
				break
			end
		end
		if not authorised then
			authorised = nil
			worst = better(worst, 'no_key')
		end
	end

	if not authorised then return false, worst or 'not_allowed', nil, false end
	return true, authorised, item, door.passcode ~= nil
end

-- ── the config file ─────────────────────────────────────────────────────────

--- Every config door, checked, keyed by its config key; and the lines naming
--- each one refused.
-- @author dop42
-- @return table<string, table> key -> the raw lower-case shape
-- @return string[]
function Access.ConfigSeeds()
	local seeds, problems = {}, {}
	local declared = settings().DOORS
	if declared ~= nil and type(declared) ~= 'table' then
		problems[1] = 'DOORS must be a table of key -> door'
		return seeds, problems
	end
	for key, definition in pairs(declared or {}) do
		local raw = Access.FromConfig(definition)
		if type(key) ~= 'string' or #key > 48 or not key:match(NAME_PATTERN) then
			problems[#problems + 1] = ('DOORS.%s refused: bad_key'):format(tostring(key))
		else
			local door, why = Access.Normalize(nil, raw, 'config:' .. key)
			if door == nil then
				problems[#problems + 1] = ('DOORS.%s refused: %s'):format(key, why)
			else
				seeds[key] = door
			end
		end
	end
	return seeds, problems
end

--- Squared distance from a door's coords.
-- @author dop42
-- @param door table anything with `coords`, or with x/y/z
-- @param x number
-- @param y number
-- @param z number|nil when nil the distance is measured across the ground
-- @return number
function Access.DistanceSquared(door, x, y, z)
	local at = door.coords or door
	local dz = z ~= nil and (at.z - z) or 0
	return (at.x - x) ^ 2 + (at.y - y) ^ 2 + dz ^ 2
end
