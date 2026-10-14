--- Values off the wire, metadata comparison, and the checked configuration.
-- @author dop42
--
-- Both halves read this, so that a value the client accepts and the server
-- refuses cannot exist: a screen that draws a move the server will not make is
-- worse than one that never offered it.
--
-- `OPX.Validate` answers a `Result` and is the right shape for a form. Nothing
-- here is a form: these are per-slot tests inside loops that run over a whole
-- container, and a Result per stack is a table per stack. They answer the value
-- or nil.

local M = OPX.Modules.Get('inventory')

M.Common = {}
local Common = M.Common

--- Widest integer either half accepts off the wire.
-- Past 2^53-1 a JSON number is no longer exact and `%d` has no integer form.
Common.MAX_INTEGER = 9007199254740991

--- A whole number inside a range, or nil.
-- NaN is rejected before either comparison: it passes both `<` tests unchallenged
-- and would then poison whatever it is stored in.
-- @author dop42
-- @param value any
-- @param low number
-- @param high number
-- @return integer|nil
function Common.Integer(value, low, high)
	if type(value) ~= 'number' or value ~= value or value % 1 ~= 0 then return nil end
	if value < low or value > high then return nil end
	return math.floor(value)
end

--- A whole number in range read from a word somebody typed.
-- @author dop42
-- @param value any
-- @param low number
-- @param high number
-- @return integer|nil
function Common.TypedInteger(value, low, high)
	if type(value) == 'string' and #value <= 20 then value = tonumber(value) end
	return Common.Integer(value, low, high)
end

--- A non-empty bounded string, optionally matching a pattern, or nil.
-- @author dop42
-- @param value any
-- @param maximum integer bytes
-- @param pattern string|nil
-- @return string|nil
function Common.Word(value, maximum, pattern)
	if type(value) ~= 'string' or #value == 0 or #value > maximum then return nil end
	if pattern and not value:match(pattern) then return nil end
	return value
end

--- Byte length of the first `maximum` characters of a UTF-8 string.
-- Lead bytes are counted rather than bytes, so a cut never falls inside a
-- character -- which would put invalid UTF-8 on the wire and in a log line.
local function span(text, maximum)
	local size = math.min(#text, maximum * 4)
	local characters = 0
	for index = 1, size do
		local byte = text:byte(index)
		if byte < 0x80 or byte > 0xBF then
			if characters >= maximum then return index - 1 end
			characters = characters + 1
		end
	end
	return size
end

--- Display text with no control characters, trimmed and cut to `maximum`
--- characters, or nil when nothing is left.
-- @author dop42
-- @param value any
-- @param maximum integer characters
-- @return string|nil
function Common.Clean(value, maximum)
	if type(value) == 'number' then value = tostring(value) end
	if type(value) ~= 'string' then return nil end
	value = OPX.String.Trim((value:gsub('%c', ' ')))
	if value == '' then return nil end
	if #value > maximum then value = value:sub(1, span(value, maximum)) end
	return value
end

--- A deep copy of plain data.
-- `OPX.Table.DeepCopy` is cycle-safe and copies keys too; metadata is a flat
-- table off the wire that has already been size-checked, so this is the cheaper
-- walk for something done once per stack moved.
-- @author dop42
-- @param value any
-- @return any
function Common.Copy(value)
	if type(value) ~= 'table' then return value end
	local out = {}
	for key, item in pairs(value) do out[key] = Common.Copy(item) end
	return out
end

--- Whether two plain values are deeply equal.
local function same(a, b)
	if a == b then return true end
	if type(a) ~= 'table' or type(b) ~= 'table' then return false end
	for key, value in pairs(a) do
		if not same(value, b[key]) then return false end
	end
	for key in pairs(b) do
		if a[key] == nil then return false end
	end
	return true
end

--- Whether two stacks' metadata make one kind of stack.
-- Nil and an empty table are the same thing, so a stack that lost its last
-- metadata key still stacks with a plain one.
-- @author dop42
-- @param a table|nil
-- @param b table|nil
-- @return boolean
function Common.SameMetadata(a, b)
	local emptyA = type(a) ~= 'table' or next(a) == nil
	local emptyB = type(b) ~= 'table' or next(b) == nil
	if emptyA or emptyB then return emptyA == emptyB end
	return same(a, b)
end

--- The encoded byte size of plain data, or nil when it will not encode.
-- @author dop42
-- @param value any
-- @return integer|nil
function Common.EncodedSize(value)
	local encoded, text = pcall(json.encode, value)
	if not encoded or type(text) ~= 'string' then return nil end
	return #text
end

--- Metadata a caller supplied, checked against the size bound and copied.
-- The second answer is false only when something was given AND refused, so a
-- caller can tell "no metadata" from "metadata I would not take".
-- @author dop42
-- @param value any
-- @param maximum integer encoded bytes
-- @return table|nil
-- @return boolean
function Common.Metadata(value, maximum)
	if value == nil then return nil, true end
	if type(value) ~= 'table' then return nil, false end
	if next(value) == nil then return nil, true end
	local size = Common.EncodedSize(value)
	if size == nil or size > maximum then return nil, false end
	return Common.Copy(value), true
end

--- The catalogue key answering a refusal code, or the module's generic one.
-- Every code this module produces is a bare word (`too_heavy`, `not_enough`) and
-- the key is composed from a literal prefix, so no key is orphaned and a code
-- with no line falls back rather than reaching a player as an internal word.
-- @author dop42
-- @param code any
-- @param prefix string ends with a dot
-- @return string
function Common.ErrorKey(code, prefix)
	local key = prefix .. tostring(code)
	if OPX.Locale.Exists(key) then return key end
	return prefix .. 'failed'
end

-- ── the checked configuration ────────────────────────────────────────────────
--
-- `config/inventory.lua` is read once, here, and every value either half makes a
-- calculation or a lookup on is resolved into `M.Options`. A mistyped entry
-- becomes a line in `M.Problems` and a fallback, never an error raised in the
-- middle of a request. The problems are written in English and only the server's
-- boot log reads them; no player ever sees one.

--- Everything wrong with `config/inventory.lua`, in English, for the boot log.
M.Problems = {}

local function problem(line)
	M.Problems[#M.Problems + 1] = line
end

--- A configured table, or an empty one with a problem recorded.
local function section(value, key)
	if value == nil then return {} end
	if type(value) ~= 'table' then
		problem(('%s must be a table; using its defaults'):format(key))
		return {}
	end
	return value
end

--- A configured whole number in range, or the fallback with a problem recorded.
local function bounded(key, value, low, high, fallback)
	if value == nil then return fallback end
	local parsed = Common.Integer(value, low, high)
	if parsed == nil then
		problem(('%s must be a whole number in %d..%d; using %d'):format(key, low, high, fallback))
		return fallback
	end
	return parsed
end

--- A finite configured number in range, or the fallback.
local function distance(key, value, low, high, fallback)
	if value == nil then return fallback end
	local parsed = tonumber(value)
	if not OPX.Math.IsFinite(parsed) or parsed < low or parsed > high then
		problem(('%s must be a number in %s..%s; using %s'):format(key, low, high, fallback))
		return fallback
	end
	return parsed
end

--- A configured key name, or false for a mapping the operator switched off.
local function keyName(key, value, fallback)
	if value == false then return false end
	if value == nil then return fallback end
	if type(value) == 'string' and #value > 0 and #value <= 32 and not value:find('[%s%c]') then
		return value
	end
	problem(('%s must be a key name or false; using %q'):format(key, tostring(fallback)))
	return fallback
end

--- A configured slots-and-grams pair.
local function size(key, value, slots, weight)
	local raw = section(value, key)
	return {
		slots = bounded(key .. '.SLOTS', raw.SLOTS, 0, 200, slots),
		maxWeight = bounded(key .. '.MAX_WEIGHT', raw.MAX_WEIGHT, 0, 4000000000, weight),
	}
end

local Config = M.Settings

--- The checked view of `config/inventory.lua`. Read this, never `M.Settings`.
M.Options = {}
local Options = M.Options

local bag = section(Config.BAG, 'BAG')
Options.BAG_SLOTS = bounded('BAG.SLOTS', bag.SLOTS, 1, 200, 40)
Options.BAG_MAX_WEIGHT = bounded('BAG.MAX_WEIGHT', bag.MAX_WEIGHT, 0, 4000000000, 30000)

Options.DEFAULT_ITEM_WEIGHT =
	bounded('DEFAULT_ITEM_WEIGHT', Config.DEFAULT_ITEM_WEIGHT, 0, 1000000, 100)
Options.MAX_STACK = bounded('MAX_STACK', Config.MAX_STACK, 1, 2147483647, 1000000)
Options.MAX_METADATA_BYTES =
	bounded('MAX_METADATA_BYTES', Config.MAX_METADATA_BYTES, 64, 4096, 1024)

local reach = section(Config.REACH, 'REACH')
Options.REACH = distance('REACH.DISTANCE', reach.DISTANCE, 0.5, 25, 3.0)
Options.REACH_VEHICLE = distance('REACH.VEHICLE', reach.VEHICLE, 1, 25, 4.5)

local hotbar = section(Config.HOTBAR, 'HOTBAR')
Options.HOTBAR = hotbar.ENABLED ~= false
Options.HOTBAR_SLOTS = Options.HOTBAR and bounded('HOTBAR.SLOTS', hotbar.SLOTS, 0, 9, 5) or 0

-- How long the peek key holds the hotbar row on screen. The floor is there
-- because a row shown for a quarter of a second is a flicker nobody reads, and
-- the ceiling because a row held for half a minute is not a peek, it is a HUD
-- element the operator should be asked for on purpose.
Options.HOTBAR_PEEK_MS = bounded('HOTBAR.PEEK_MS', hotbar.PEEK_MS, 500, 30000, 4000)

local keys = section(Config.KEYS, 'KEYS')
Options.KEY_OPEN = keyName('KEYS.OPEN', keys.OPEN, 'I')

--- Default key per hotbar slot, false where no mapping is registered.
Options.KEYS_HOTBAR = {}
local hotbarKeys = type(keys.HOTBAR) == 'table' and keys.HOTBAR or {}
if keys.HOTBAR ~= nil and type(keys.HOTBAR) ~= 'table' then
	problem('KEYS.HOTBAR must be a list of key names')
end
for index = 1, Options.HOTBAR_SLOTS do
	local key = keyName(('KEYS.HOTBAR[%d]'):format(index), hotbarKeys[index], tostring(index + 3))
	if key and key == Options.KEY_OPEN then
		problem(('KEYS.HOTBAR[%d] is the open key %q; that hotbar key is not registered')
			:format(index, key))
		key = false
	end
	Options.KEYS_HOTBAR[index] = key
end

--- The key that shows the hotbar row, or false where none is registered.
--
-- CHECKED AGAINST THE KEYS IT WOULD SHADOW, exactly as each hotbar key is
-- checked against the open key above. A peek bound to the same key as a hotbar
-- slot would draw the row and use the item in the same press, which is the one
-- thing this key must not do; bound to the open key it would fight the bag.
Options.KEY_PEEK = Options.HOTBAR_SLOTS > 0
	and keyName('KEYS.PEEK', keys.PEEK, 'TAB') or false
if Options.KEY_PEEK and Options.KEY_PEEK == Options.KEY_OPEN then
	problem(('KEYS.PEEK is the open key %q; the peek key is not registered')
		:format(Options.KEY_PEEK))
	Options.KEY_PEEK = false
end
for index = 1, Options.HOTBAR_SLOTS do
	if Options.KEY_PEEK and Options.KEY_PEEK == Options.KEYS_HOTBAR[index] then
		problem(('KEYS.PEEK is hotbar key %d (%q); the peek key is not registered')
			:format(index, Options.KEY_PEEK))
		Options.KEY_PEEK = false
	end
end

Options.USE_COOLDOWN_MS = bounded('USE_COOLDOWN_MS', Config.USE_COOLDOWN_MS, 0, 60000, 750)
Options.USE_HANDLER_MS = bounded('USE_HANDLER_MS', Config.USE_HANDLER_MS, 500, 25000, 5000)

local rate = section(Config.RATE_LIMIT, 'RATE_LIMIT')
Options.RATE_WINDOW_MS = bounded('RATE_LIMIT.WINDOW_MS', rate.WINDOW_MS, 100, 60000, 1000)
Options.RATE_REQUESTS = bounded('RATE_LIMIT.REQUESTS', rate.REQUESTS, 1, 1000, 20)

local save = section(Config.SAVE, 'SAVE')
Options.SAVE_DELAY_MS = bounded('SAVE.DELAY_MS', save.DELAY_MS, 0, 600000, 2000)
Options.SAVE_SWEEP_MS = bounded('SAVE.SWEEP_MS', save.SWEEP_MS, 250, 60000, 1000)
Options.SAVE_BATCH = bounded('SAVE.BATCH', save.BATCH, 1, 64, 16)

local drops = section(Config.DROPS, 'DROPS')
Options.DROPS = drops.ENABLED ~= false
Options.DROP_SLOTS = bounded('DROPS.SLOTS', drops.SLOTS, 1, 200, 25)
Options.DROP_LIFETIME_MIN = bounded('DROPS.LIFETIME_MINUTES', drops.LIFETIME_MINUTES, 1, 10080, 30)
Options.DROP_MAX = bounded('DROPS.MAX', drops.MAX, 1, 2048, 200)
Options.DROP_MAX_PER_CHARACTER =
	bounded('DROPS.MAX_PER_CHARACTER', drops.MAX_PER_CHARACTER, 1, 2048, 10)
Options.DROP_COOLDOWN_MS = bounded('DROPS.COOLDOWN_MS', drops.COOLDOWN_MS, 0, 60000, 1000)
Options.DROP_DISTANCE = distance('DROPS.DISTANCE', drops.DISTANCE, 0.1, 10, 1.5)
Options.DROP_MODEL = Common.Word(drops.MODEL, 256) or 'crate.small'
Options.DROP_PROMPT_RADIUS = distance('DROPS.PROMPT_RADIUS', drops.PROMPT_RADIUS, 2, 250, 20)

Options.TRUNK = size('TRUNK', Config.TRUNK, 30, 80000)
Options.GLOVEBOX = size('GLOVEBOX', Config.GLOVEBOX, 10, 10000)

--- Whether an owned vehicle's boot answers only to its owner. See the config.
Options.TRUNK_OWNER_ONLY = Config.TRUNK_OWNER_ONLY ~= false

local bikes = section(Config.BIKES, 'BIKES')

--- Lowercased record fragments that mark a two-wheeler.
Options.BIKE_PATTERNS = {}
for _, pattern in ipairs(type(bikes.PATTERNS) == 'table' and bikes.PATTERNS or {}) do
	if type(pattern) == 'string' and pattern ~= '' then
		Options.BIKE_PATTERNS[#Options.BIKE_PATTERNS + 1] = pattern:lower()
	end
end
Options.BIKE_TRUNK_DIVISOR = bounded('BIKES.TRUNK_DIVISOR', bikes.TRUNK_DIVISOR, 1, 100, 3)

--- Resolved stashes by name, and in configuration order.
Options.STASHES = {}
Options.STASH_LIST = {}
for index, raw in ipairs(section(Config.STASHES, 'STASHES')) do
	local where = ('STASHES[%d]'):format(index)
	local name = type(raw) == 'table' and Common.Word(raw.NAME, 48, '^[%w_%-%.]+$') or nil
	local position = type(raw) == 'table' and raw.POSITION or nil
	local x = type(position) == 'table' and tonumber(position.X) or nil
	local y = type(position) == 'table' and tonumber(position.Y) or nil
	local z = type(position) == 'table' and tonumber(position.Z) or nil
	local placed = OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)
	if name == nil then
		problem(where .. ': NAME must be letters, digits, _ - . up to 48; left out')
	elseif not placed then
		problem(where .. ' ' .. name .. ': POSITION needs X, Y and Z; left out')
	elseif Options.STASHES[name] then
		problem(where .. ': ' .. name .. ' is declared twice; the first one is kept')
	else
		local stash = {
			name = name,
			label = type(raw.LABEL) == 'string' and raw.LABEL or nil,
			slots = bounded(where .. '.SLOTS', raw.SLOTS, 1, 200, 50),
			maxWeight = bounded(where .. '.MAX_WEIGHT', raw.MAX_WEIGHT, 0, 4000000000, 100000),
			position = { x = x, y = y, z = z },
			bucket = bounded(where .. '.BUCKET', raw.BUCKET, 0, 1000000, 0),
		}
		Options.STASHES[name] = stash
		Options.STASH_LIST[#Options.STASH_LIST + 1] = stash
	end
end

local weapons = section(Config.WEAPONS, 'WEAPONS')
Options.WEAPONS = weapons.ENABLED ~= false
Options.WEAPON_SLOT = bounded('WEAPONS.SLOT', weapons.SLOT, 1, 3, 1)
Options.REMOVE_UNBACKED = weapons.REMOVE_UNBACKED ~= false
Options.WEAPON_SCAN_MS = bounded('WEAPONS.SCAN_MS', weapons.SCAN_MS, 1000, 600000, 5000)
Options.AMMO_SYNC_MS = bounded('WEAPONS.AMMO_SYNC_MS', weapons.AMMO_SYNC_MS, 500, 60000, 2000)

--- Item name -> percentage of maximum health a use restores (`HEALING`).
Options.HEALING = {}
for name, percent in pairs(section(Config.HEALING, 'HEALING')) do
	local amount = tonumber(percent)
	if type(name) ~= 'string' or amount == nil or amount ~= amount or amount <= 0 or amount > 100 then
		problem(('HEALING.%s must be a percentage above 0 and at most 100'):format(tostring(name)))
	else
		Options.HEALING[name] = amount
	end
end

local nearby = section(Config.NEARBY, 'NEARBY')
Options.NEARBY_MAX = bounded('NEARBY.MAX', nearby.MAX, 0, 12, 4)
Options.NEARBY_SCAN_MS = bounded('NEARBY.SCAN_MS', nearby.SCAN_MS, 250, 10000, 1000)

--- Resolved tabs: key, category list and the rest flag.
Options.TABS = {}
for index, raw in ipairs(section(Config.TABS, 'TABS')) do
	local key = type(raw) == 'table' and Common.Word(raw.KEY, 32, '^[%w_]+$') or nil
	if key == nil then
		problem(('TABS[%d] needs a KEY'):format(index))
	else
		local categories = {}
		for _, category in ipairs(type(raw.CATEGORIES) == 'table' and raw.CATEGORIES or {}) do
			if type(category) == 'string' then categories[#categories + 1] = category end
		end
		Options.TABS[#Options.TABS + 1] =
			{ key = key, categories = categories, rest = raw.REST == true }
	end
end

Options.MAX_COMMAND_COUNT =
	bounded('MAX_COMMAND_COUNT', Config.MAX_COMMAND_COUNT, 1, Options.MAX_STACK, 10000)

--- The money-to-item bridge: whether it is wired, what it trades and how much.
--
-- RESOLVED HERE AND NOT AT THE MOMENT OF USE, because every one of these
-- mistakes has the same shape -- half a bridge -- and half a bridge is where
-- money goes missing. A withdraw that debits `EDIES` (a typo) into an item
-- nothing can deposit destroys the balance on the first use, and it would not be
-- noticed until a player complained; refusing to wire the bridge at all is a
-- line in the boot log that somebody reads the same day.
--
-- THE ITEM IS NOT CHECKED HERE. `shared/catalog.lua` loads after this file, so
-- there is no catalogue to ask yet. `server/currency.lua` asks at `Start`, where
-- there is, and turns the bridge off the same way.
local currency = section(Config.CURRENCY, 'CURRENCY')
Options.CURRENCY_ENABLED = currency.ENABLED ~= false
Options.CURRENCY_ITEM = Common.Word(currency.ITEM, 48, '^[%w_%-%.]+$')
Options.CURRENCY_MONEY_TYPE = nil
Options.CURRENCY_MAX_WITHDRAW =
	bounded('CURRENCY.MAX_WITHDRAW', currency.MAX_WITHDRAW, 1, Options.MAX_STACK, 1000000)

if Options.CURRENCY_ENABLED then
	if Options.CURRENCY_ITEM == nil then
		problem('CURRENCY.ITEM must be an item name; no money can be withdrawn as an item')
		Options.CURRENCY_ENABLED = false
	end

	-- A money type the server does not have is the typo that costs the most:
	-- `AddMoney` and `RemoveMoney` both answer `money.badType` for it, so the
	-- withdraw would refuse and the deposit would refuse -- but only AFTER the
	-- deposit had already taken the notes out of the bag. Off is the safe state.
	local types = type(OPX.Config.SHARED) == 'table' and type(OPX.Config.SHARED.MONEY) == 'table'
		and OPX.Config.SHARED.MONEY.TYPES or nil
	local named = Common.Word(currency.MONEY_TYPE, 32, '^[%w_]+$')
	if type(types) ~= 'table' or named == nil or types[named] == nil then
		problem(('CURRENCY.MONEY_TYPE %q is not a money type this server declares; no money ' ..
			'can be withdrawn as an item'):format(tostring(currency.MONEY_TYPE)))
		Options.CURRENCY_ENABLED = false
	else
		Options.CURRENCY_MONEY_TYPE = named
	end
end
