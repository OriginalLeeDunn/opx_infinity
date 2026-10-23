--- The bar's config validator and its arithmetic. Pure: no host call.
-- @author dop42
--
-- `Read` NORMALISES ONCE AND NAMES WHAT IT DROPS. A refused item, recipe,
-- venue, catalogue row or price is not there at all, and its line is in
-- `problems` for the boot log. A position at 0,0,0 is not a problem: it is a
-- placeholder, named in `placeholders`, and the piece it belongs to is disabled
-- until somebody surveys it -- the rule every place module here follows. A
-- venue needs its COUNTER and its STASH; a supplier at 0,0,0 only loses the
-- supplier.
--
-- The server builds `S` once at Init and decides every price, recipe and gate
-- from it. The client never runs `Read` (its budget): it walks VENUES itself,
-- one per resume, for the positions it draws.

local M = OPX.Modules.Get('bar')

M.Model = {}
local Model = M.Model

local finiteNumber = OPX.Math.Finite

Model.KINDS = { drink = true, food = true, ingredient = true }
Model.MONEY = { BANK = true, EDDIES = true }
Model.BILLING = { auto = true, direct = true, invoice = true }
Model.FUNDS = { account = true, personal = true }
Model.ACCOUNT_KINDS = { job = true, gang = true }
Model.ID = '^[%w_]+$'
Model.ID_MAX = 48
Model.STASH = '^[%w_%-%.]+$'
-- Bounds that keep a runtime item inside what the inventory accepts.
Model.MAX_STATUS = 100
Model.MAX_INPUTS = 8
Model.MAX_MENU = 30
Model.MAX_CATALOG = 30

local function clamp(value, low, high, fallback)
	value = finiteNumber(value)
	if value == nil then return fallback end
	if value < low then return low end
	if value > high then return high end
	return value
end

local function int(value)
	local number = finiteNumber(value)
	if number == nil or number ~= math.floor(number) then return nil end
	return math.tointeger(number)
end

local function word(value, maximum, pattern)
	if type(value) ~= 'string' or #value < 1 or #value > maximum then return nil end
	if not value:match(pattern) then return nil end
	return value
end

local function text(value, maximum)
	if type(value) ~= 'string' or value == '' then return nil end
	return OPX.Text.Clean(value, maximum, '...')
end

local function sortedKeys(map)
	local keys = {}
	if type(map) ~= 'table' then return keys end
	for key in pairs(map) do
		if type(key) == 'string' then keys[#keys + 1] = key end
	end
	table.sort(keys)
	return keys
end

local function firstKey(map)
	local keys = sortedKeys(map)
	return keys[1]
end

--- Whether a declared point is the 0,0,0 placeholder.
-- @author dop42
function Model.Placeholder(point)
	return type(point) == 'table' and finiteNumber(point.X) == 0 and finiteNumber(point.Y) == 0
		and finiteNumber(point.Z) == 0
end

local function point(raw)
	if type(raw) ~= 'table' then return nil end
	local x, y, z = OPX.Spots.Coordinate(raw.X), OPX.Spots.Coordinate(raw.Y), OPX.Spots.Coordinate(raw.Z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

-- ── items and recipes ───────────────────────────────────────────────────────

local function readItem(name, raw, lines)
	local where = 'ITEMS.' .. name
	if word(name, 48, '^[%w_]+$') == nil then
		lines[#lines + 1] = where .. ': an item name is 1..48 letters, digits or _'
		return nil
	end
	if type(raw) ~= 'table' then lines[#lines + 1] = where .. ': must be a table'; return nil end
	local kind = raw.KIND
	if not Model.KINDS[kind] then
		lines[#lines + 1] = where .. ": KIND is 'drink', 'food' or 'ingredient'"
		return nil
	end
	local weight = int(raw.WEIGHT)
	if raw.WEIGHT ~= nil and (weight == nil or weight < 0) then
		lines[#lines + 1] = where .. ': WEIGHT is whole grams >= 0'
		return nil
	end
	local model = raw.MODEL ~= nil and word(raw.MODEL, 128, '^[%w_%-%.]+$') or nil
	if raw.MODEL ~= nil and model == nil then
		lines[#lines + 1] = where .. ': MODEL is a props alias'
		return nil
	end
	local item = {
		name = name, kind = kind,
		label = text(raw.LABEL, 48) or name,
		description = text(raw.DESCRIPTION, 200),
		weight = weight or (kind == 'ingredient' and 500 or 300),
		model = model,
		category = kind,
		thirst = clamp(raw.THIRST, 0, Model.MAX_STATUS, 0),
		hunger = clamp(raw.HUNGER, 0, Model.MAX_STATUS, 0),
		alcohol = clamp(raw.ALCOHOL, 0, 20, 0),
	}
	if kind == 'ingredient' and (item.thirst > 0 or item.hunger > 0 or item.alcohol > 0) then
		lines[#lines + 1] = where .. ': an ingredient has no THIRST, HUNGER or ALCOHOL (ignored)'
		item.thirst, item.hunger, item.alcohol = 0, 0, 0
	end
	return item
end

--- The runtime definition the inventory's `RegisterItem` takes for one item.
-- @author dop42
-- @param item table a read item
-- @return table
function Model.Definition(item)
	local definition = {
		label = item.label, weight = item.weight, stack = true, drop = true,
		category = item.category,
	}
	if item.description ~= nil then definition.description = item.description end
	if item.model ~= nil then definition.model = item.model end
	if item.kind ~= 'ingredient' then
		local status = {}
		if item.thirst > 0 then status.thirst = item.thirst end
		if item.hunger > 0 then status.hunger = item.hunger end
		definition.use = {
			consume = 1, close = true,
			-- Use the authored eating pose where offered; keep older catalogues usable.
			animation = item.kind == 'food' and { name = 'takeout', fallback = 'drink', durationMs = 3000 }
				or { name = 'drink', durationMs = 3000 },
		}
		if next(status) ~= nil then definition.use.status = status end
	end
	return definition
end

local function readRecipe(key, raw, S, lines)
	local where = 'RECIPES.' .. key
	if word(key, 48, '^[%w_]+$') == nil then
		lines[#lines + 1] = where .. ': a recipe key is 1..48 letters, digits or _'
		return nil
	end
	if type(raw) ~= 'table' then lines[#lines + 1] = where .. ': must be a table'; return nil end
	local output = S.items[raw.ITEM]
	if output == nil or output.kind == 'ingredient' then
		lines[#lines + 1] = where .. ': ITEM names no drink or food in ITEMS'
		return nil
	end
	local count = int(raw.COUNT == nil and 1 or raw.COUNT)
	if count == nil or count < 1 or count > 100 then
		lines[#lines + 1] = where .. ': COUNT is 1..100'
		return nil
	end
	local inputs = {}
	for index, row in ipairs(type(raw.INPUTS) == 'table' and raw.INPUTS or {}) do
		local item = type(row) == 'table' and S.items[row.ITEM] or nil
		local need = type(row) == 'table' and int(row.COUNT == nil and 1 or row.COUNT) or nil
		if item == nil then
			lines[#lines + 1] = ('%s.INPUTS[%d]: ITEM names nothing in ITEMS'):format(where, index)
			return nil
		end
		if need == nil or need < 1 or need > 1000 then
			lines[#lines + 1] = ('%s.INPUTS[%d]: COUNT is 1..1000'):format(where, index)
			return nil
		end
		inputs[#inputs + 1] = { item = item.name, count = need }
	end
	if #inputs == 0 or #inputs > Model.MAX_INPUTS then
		lines[#lines + 1] = ('%s: INPUTS is 1..%d ingredients'):format(where, Model.MAX_INPUTS)
		return nil
	end
	return {
		key = key, item = output.name, count = count, inputs = inputs,
		ms = math.floor(clamp(raw.MS, 500, 600000, S.mixMs)),
	}
end

-- ── venues ──────────────────────────────────────────────────────────────────

local function readStash(raw, where, label, lines)
	if type(raw) ~= 'table' then lines[#lines + 1] = where .. ': STASH is required'; return nil, false end
	local name = word(raw.NAME, 48, Model.STASH)
	if name == nil then
		lines[#lines + 1] = where .. '.STASH: NAME is 1..48 of letters, digits, _ - .'
		return nil, false
	end
	if Model.Placeholder(raw) then return nil, true end
	local at = point(raw)
	if at == nil then lines[#lines + 1] = where .. '.STASH: X, Y and Z are coordinates'; return nil, false end
	at.name = name
	at.label = text(raw.LABEL, 64) or label
	at.slots = math.floor(clamp(int(raw.SLOTS), 1, 200, 50))
	at.maxWeight = math.floor(clamp(int(raw.MAX_WEIGHT), 1, 100000000, 100000))
	return at, false
end

local function readSupply(raw, where, S, lines, placeholders, id)
	if raw == nil then return nil end
	if type(raw) ~= 'table' then lines[#lines + 1] = where .. ': SUPPLY must be a table'; return nil end
	local catalog = {}
	for index, row in ipairs(type(raw.CATALOG) == 'table' and raw.CATALOG or {}) do
		local rowWhere = ('%s.SUPPLY.CATALOG[%d]'):format(where, index)
		local item = type(row) == 'table' and S.items[row.ITEM] or nil
		local price = type(row) == 'table' and int(row.PRICE) or nil
		local count = type(row) == 'table' and int(row.COUNT == nil and 1 or row.COUNT) or nil
		if item == nil then
			lines[#lines + 1] = rowWhere .. ': ITEM names nothing in ITEMS'
		elseif price == nil or price < 0 then
			lines[#lines + 1] = rowWhere .. ': PRICE is a whole amount >= 0'
		elseif count == nil or count < 1 or count > 1000 then
			lines[#lines + 1] = rowWhere .. ': COUNT is 1..1000'
		elseif #catalog >= Model.MAX_CATALOG then
			lines[#lines + 1] = rowWhere .. (': past %d rows, dropped'):format(Model.MAX_CATALOG)
		else
			catalog[#catalog + 1] = { index = index, item = item.name, price = price, count = count }
		end
	end
	if Model.Placeholder(raw) then
		placeholders[#placeholders + 1] = id .. '.SUPPLY'
		return nil
	end
	if #catalog == 0 then
		lines[#lines + 1] = where .. '.SUPPLY: no valid CATALOG row'
		return nil
	end
	local at = point(raw)
	if at == nil then lines[#lines + 1] = where .. '.SUPPLY: X, Y and Z are coordinates'; return nil end
	at.catalog = catalog
	return at
end

local function readAccount(raw, venue, where, lines)
	if raw ~= nil then
		if type(raw) ~= 'table' or not Model.ACCOUNT_KINDS[raw.KIND] or word(raw.KEY, 48, '^[%w_]+$') == nil then
			lines[#lines + 1] = where .. ": ACCOUNT is { KIND = 'job'|'gang', KEY = name }"
			return nil
		end
		return { kind = raw.KIND, key = raw.KEY }
	end
	local job = firstKey(venue.jobs)
	if job ~= nil then return { kind = 'job', key = job } end
	local gang = firstKey(venue.gangs)
	if gang ~= nil then return { kind = 'gang', key = gang } end
	return nil
end

local function readVenue(index, raw, S, lines, placeholders)
	local where = ('VENUES[%d]'):format(index)
	if type(raw) ~= 'table' then lines[#lines + 1] = where .. ': must be a table'; return nil end
	local id = word(raw.ID, Model.ID_MAX, Model.ID)
	if id == nil then
		lines[#lines + 1] = where .. ': ID is 1..48 letters, digits or _'
		return nil
	end
	where = 'VENUES.' .. id
	local before = #lines
	OPX.JobGate.Problems(raw.JOBS, where, lines)
	OPX.JobGate.GangProblems(raw.GANGS, where, lines)
	if #lines > before then return nil end
	local jobs = type(raw.JOBS) == 'table' and next(raw.JOBS) ~= nil and raw.JOBS or nil
	local gangs = type(raw.GANGS) == 'table' and next(raw.GANGS) ~= nil and raw.GANGS or nil
	if jobs == nil and gangs == nil then
		-- A bar anybody could work is a bar anybody could empty: refused.
		lines[#lines + 1] = where .. ': names no JOBS and no GANGS'
		return nil
	end
	local venue = {
		id = id, label = text(raw.LABEL, 64) or id,
		jobs = jobs, gangs = gangs,
		onDuty = raw.ON_DUTY ~= false,
		bucket = int(raw.BUCKET) or 0,
		supplyGrade = int(raw.SUPPLY_GRADE) or 1,
		menu = {}, prices = {}, sells = {},
	}
	venue.account = readAccount(raw.ACCOUNT, venue, where, lines)

	if Model.Placeholder(raw.COUNTER) then
		placeholders[#placeholders + 1] = id
		return nil
	end
	venue.counter = point(raw.COUNTER)
	if venue.counter == nil then lines[#lines + 1] = where .. ': COUNTER needs X, Y and Z'; return nil end
	local stash, placeholder = readStash(raw.STASH, where, venue.label, lines)
	if placeholder then placeholders[#placeholders + 1] = id .. '.STASH' return nil end
	if stash == nil then return nil end
	venue.stash = stash
	venue.supply = readSupply(raw.SUPPLY, where, S, lines, placeholders, id)

	local prices = type(raw.PRICES) == 'table' and raw.PRICES or {}
	for menuIndex, key in ipairs(type(raw.MENU) == 'table' and raw.MENU or {}) do
		local recipe = S.recipes[key]
		if recipe == nil then
			lines[#lines + 1] = ('%s.MENU[%d]: %s is not in RECIPES'):format(where, menuIndex, tostring(key))
		elseif #venue.menu >= Model.MAX_MENU then
			lines[#lines + 1] = ('%s.MENU: past %d recipes, dropped'):format(where, Model.MAX_MENU)
		else
			venue.menu[#venue.menu + 1] = key
			local price = int(prices[recipe.item])
			if price == nil or price < 0 then
				lines[#lines + 1] = ('%s.PRICES: %s has no whole price >= 0, it is mixed but never served')
					:format(where, recipe.item)
			elseif venue.prices[recipe.item] == nil then
				venue.prices[recipe.item] = price
				venue.sells[#venue.sells + 1] = recipe.item
			end
		end
	end
	if #venue.menu == 0 then lines[#lines + 1] = where .. ': MENU names no recipe'; return nil end

	if raw.BLIP ~= false and type(raw.BLIP) == 'table' then
		venue.blip = {
			sprite = (type(raw.BLIP.SPRITE) == 'string' and word(raw.BLIP.SPRITE, 64, '^[%w_]+$'))
				or math.tointeger(raw.BLIP.SPRITE) or 'bar',
			icon = word(raw.BLIP.ICON, 32, '^[%w_%-]+$'),
			color = type(raw.BLIP.COLOR) == 'string' and raw.BLIP.COLOR:match('^#%x%x%x%x%x%x%x?%x?$') or nil,
			size = math.floor(clamp(raw.BLIP.SIZE, 16, 128, 48)),
		}
	end
	return venue
end

-- ── the whole config ────────────────────────────────────────────────────────

--- Normalises the config into what the server decides with.
-- @author dop42
-- @param cfg table OPX.Config.MODULES.bar
-- @return table S
function Model.Read(cfg)
	cfg = type(cfg) == 'table' and cfg or {}
	local lines, placeholders = {}, {}
	local serve = type(cfg.SERVE) == 'table' and cfg.SERVE or {}
	local drunk = type(cfg.DRUNK) == 'table' and cfg.DRUNK or {}
	local startDistance = clamp(serve.START_DISTANCE, 0.25, 10, 3)
	local S = {
		problems = lines,
		placeholders = placeholders,
		membership = cfg.MEMBERSHIP == 'any' and 'any' or 'primary',
		jobMaxAgeMs = clamp(cfg.JOB_MAX_AGE_MS, 1000, 3600000, 60000),
		reach = clamp(cfg.REACH, 0.5, 10, 2.5),
		serveRadius = clamp(cfg.SERVE_RADIUS, 1, 200, 20),
		serveReach = clamp(cfg.SERVE_REACH, 0.5, 10, 3),
		requestMs = math.floor(clamp(cfg.REQUEST_MS, 100, 60000, 700)),
		money = Model.MONEY[cfg.MONEY] and cfg.MONEY or 'BANK',
		billing = Model.BILLING[cfg.BILLING] and cfg.BILLING or 'auto',
		staffCut = math.floor(clamp(cfg.STAFF_CUT_PCT, 0, 100, 25)),
		funds = Model.FUNDS[cfg.SUPPLY_FUNDS] and cfg.SUPPLY_FUNDS or 'account',
		mixMs = math.floor(clamp(cfg.MIX_MS, 500, 600000, 5000)),
		animation = word(cfg.ANIMATION, 32, '^[%w_]+$'),
		serve = {
			durationMs = math.floor(clamp(serve.DURATION_MS, 500, 600000, 3000)),
			inviteMs = math.floor(clamp(serve.INVITE_MS, 1000, 60000, 15000)),
			startDistance = startDistance,
			breakDistance = math.max(startDistance, 5),
		},
		drunk = {
			effect = word(drunk.EFFECT, 32, '^[%w_]+$'),
			decayPerMinute = clamp(drunk.DECAY_PER_MINUTE, 0, 100, 0.25),
			fullAt = clamp(drunk.FULL_AT, 0.1, 100, 6),
			secondsPerUnit = clamp(drunk.SECONDS_PER_UNIT, 0, 600, 45),
			maxSeconds = clamp(drunk.MAX_SECONDS, 1, 600, 300),
		},
		items = {}, itemList = {},
		recipes = {}, recipeList = {},
		venues = {}, venueList = {},
	}
	if cfg.MONEY ~= nil and not Model.MONEY[cfg.MONEY] then
		lines[#lines + 1] = "MONEY is 'BANK' or 'EDDIES'; read as 'BANK'"
	end
	if cfg.BILLING ~= nil and not Model.BILLING[cfg.BILLING] then
		lines[#lines + 1] = "BILLING is 'auto', 'direct' or 'invoice'; read as 'auto'"
	end
	if cfg.SUPPLY_FUNDS ~= nil and not Model.FUNDS[cfg.SUPPLY_FUNDS] then
		lines[#lines + 1] = "SUPPLY_FUNDS is 'account' or 'personal'; read as 'account'"
	end

	for _, name in ipairs(sortedKeys(cfg.ITEMS)) do
		local item = readItem(name, cfg.ITEMS[name], lines)
		if item ~= nil then
			S.items[name] = item
			S.itemList[#S.itemList + 1] = item
		end
	end
	for _, key in ipairs(sortedKeys(cfg.RECIPES)) do
		local recipe = readRecipe(key, cfg.RECIPES[key], S, lines)
		if recipe ~= nil then
			S.recipes[key] = recipe
			S.recipeList[#S.recipeList + 1] = recipe
		end
	end

	local stashes = {}
	for index, raw in ipairs(type(cfg.VENUES) == 'table' and cfg.VENUES or {}) do
		local venue = readVenue(index, raw, S, lines, placeholders)
		if venue ~= nil then
			if S.venues[venue.id] ~= nil then
				lines[#lines + 1] = ('VENUES.%s: ID is used twice, the second is dropped'):format(venue.id)
			elseif stashes[venue.stash.name] ~= nil then
				lines[#lines + 1] = ('VENUES.%s.STASH: NAME %s is already %s\'s'):format(venue.id,
					venue.stash.name, stashes[venue.stash.name])
			else
				stashes[venue.stash.name] = venue.id
				S.venues[venue.id] = venue
				S.venueList[#S.venueList + 1] = venue
			end
		end
	end
	return S
end

--- The validator's lines for a config, the boot log's input.
-- @author dop42
-- @param cfg table
-- @return string[]
function Model.Problems(cfg)
	return Model.Read(cfg).problems
end

-- ── the arithmetic ──────────────────────────────────────────────────────────

--- What a recipe still lacks, given what the stash holds.
-- @author dop42
-- @param recipe table a read recipe
-- @param have table item -> count held
-- @return table[] `{ item, need, have }` for each short ingredient; empty when it can be mixed
function Model.Missing(recipe, have)
	local short = {}
	for _, input in ipairs(recipe.inputs) do
		local held = math.tointeger(type(have) == 'table' and have[input.item] or 0) or 0
		if held < input.count then
			short[#short + 1] = { item = input.item, need = input.count, have = held }
		end
	end
	return short
end

--- Splits a sale between the bartender and the house.
-- @author dop42
-- @param total integer
-- @param cutPct number 0..100
-- @return integer staff, integer house (they sum to total)
function Model.Split(total, cutPct)
	total = math.max(0, math.tointeger(total) or 0)
	local pct = clamp(cutPct, 0, 100, 0)
	local staff = math.floor(total * pct / 100)
	return staff, total - staff
end

--- A drunk level after some time has passed.
-- @author dop42
-- @param level number
-- @param elapsedMs number
-- @param decayPerMinute number
-- @return number never below 0
function Model.Sober(level, elapsedMs, decayPerMinute)
	level = finiteNumber(level) or 0
	local minutes = math.max(0, finiteNumber(elapsedMs) or 0) / 60000
	local left = level - minutes * math.max(0, finiteNumber(decayPerMinute) or 0)
	return left > 0 and left or 0
end

--- The screen effect a drunk level plays.
-- @author dop42
-- @param drunk table S.drunk
-- @param level number
-- @return number strength 0..1, integer seconds (0: none)
function Model.Effect(drunk, level)
	level = finiteNumber(level) or 0
	if level <= 0 then return 0, 0 end
	local strength = math.min(1, level / drunk.fullAt)
	strength = math.floor(strength * 100 + 0.5) / 100
	if strength < 0.05 then strength = 0.05 end
	local seconds = math.floor(math.min(drunk.maxSeconds, level * drunk.secondsPerUnit) + 0.5)
	return strength, seconds
end
