--- The item catalogue both halves read, normalised once at load.
-- @author dop42
--
-- A malformed row is a boot warning and is left out, never an error raised in
-- the middle of a request. The name of an item is constrained because it is
-- stored in an `ascii_bin` column and typed into a command.
--
-- WEAPONS ARE NOT INDEXED HERE. The host checks a script's load time every 10,000
-- VM instructions and cancels the whole resource set when a check falls past its
-- deadline, so no single file may reach one. A weapon costs roughly 160
-- instructions: this file only queues their names, and each `shared/catalog-<n>.lua`
-- indexes `PART` of them. The last part calls `Finish`, which indexes whatever is
-- left and sorts every name. A missing part costs load time, never a weapon.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options

M.Catalog = {}
local Catalog = M.Catalog

local function problem(line)
	M.Problems[#M.Problems + 1] = line
end

--- Pattern an item name matches: stored in a column, typed in commands.
Catalog.NAME = '^[%w_%-%.]+$'

--- Longest item name in bytes. The column is VARCHAR(48).
Catalog.NAME_MAX = 48

--- Weapons one `shared/catalog-<n>.lua` part indexes.
Catalog.PART = 40

local DEFAULT_WEIGHT = Options.DEFAULT_ITEM_WEIGHT

-- Normalised entries by name, and every name, sorted once the last part runs.
local entries = {}
local names = {}

local function validName(name, where)
	if Common.Word(name, Catalog.NAME_MAX, Catalog.NAME) then return true end
	problem(('%s: %q is not a usable item name (letters, digits, _ - . up to %d)')
		:format(where, tostring(name), Catalog.NAME_MAX))
	return false
end

local function weightOf(name, raw, where)
	local weight = Common.Integer(raw.WEIGHT, 0, 1000000000)
	if weight == nil then
		problem(('%s %s: WEIGHT must be whole grams; using %d'):format(where, name, DEFAULT_WEIGHT))
		return DEFAULT_WEIGHT
	end
	return weight
end

--- A catalogue key or a piece of plain text, or nil.
local function textField(value)
	if type(value) ~= 'string' or value == '' or #value > 160 then return nil end
	return value
end

--- Normalises an item's USE table: how many units it spends, whether the screen
--- closes, what it moves and what it plays.
local function useOf(name, use, where)
	if use == nil then return nil end
	if type(use) ~= 'table' then
		problem(('%s %s: USE must be a table; not usable'):format(where, name))
		return nil
	end
	local out = {
		consume = Common.Integer(use.CONSUME == nil and 1 or use.CONSUME, 0, 1000000),
		close = use.CLOSE ~= false,
	}
	if out.consume == nil then
		problem(('%s %s: USE.CONSUME must be a whole number; using 1'):format(where, name))
		out.consume = 1
	end
	if type(use.STATUS) == 'table' then
		local status = {}
		for key, amount in pairs(use.STATUS) do
			local value = tonumber(amount)
			if type(key) == 'string' and OPX.Math.IsFinite(value) then
				status[key] = value
			else
				problem(('%s %s: USE.STATUS.%s is not a number'):format(where, name, tostring(key)))
			end
		end
		if next(status) ~= nil then out.status = status end
	end
	if type(use.ANIMATION) == 'table' and Common.Word(use.ANIMATION.NAME, 32, '^[%w_]+$') then
		out.animation = {
			name = use.ANIMATION.NAME,
			variant = Common.Integer(use.ANIMATION.VARIANT, 1, 64),
			durationMs = Common.Integer(use.ANIMATION.DURATION_MS, 1000, 600000),
		}
	elseif use.ANIMATION ~= nil then
		problem(('%s %s: USE.ANIMATION needs a NAME'):format(where, name))
	end
	return out
end

--- The prop a pile of this item is drawn with: a CURATED ALIAS, and nothing else.
--
-- `Open77.props.create` does accept a raw cooked depot path as well, and this
-- used to allow one. It must not, and the reason is that the failure is silent
-- BOTH WAYS:
--
--   * the prop renderer matches a prebuilt host entity per registered alias, so
--     a raw `.mesh` reaches the marker fallback on the client. Receiving a prop
--     id does not prove the model drew;
--   * and because an id came back, `World.CreateDrop` never falls through to
--     `DROP_MODEL`. A pile that would have been an honest crate is a marker
--     instead, with nothing logged on either side.
--
-- An unknown ALIAS is refused by the server with `unknown_alias`, which is the
-- behaviour we want: no id, the crate is drawn, and the warning names the model
-- once. So the alias is the only form that fails loudly, and it is the only one
-- taken here. A weapon that needs its own geometry needs a host shipped for it
-- first -- see the catalogue's note on integrating a decorative weapon.
local function modelOf(name, value, where)
	if value == nil then return nil end
	local model = Common.Word(value, 256, '^[%w_%-%.]+$')
	if model == nil or model:find('%.mesh$') then
		problem(('%s %s: MODEL must be a curated Open77.props alias, not a depot ' ..
			'path -- a raw mesh draws as a marker and suppresses the pile fallback; ' ..
			'the pile model is used'):format(where, name))
		return nil
	end
	return model
end

--- The fields every kind of catalogue entry shares.
--
-- `droppable` is the one that is not a display detail. A pile on the ground is a
-- MEMORY-ONLY container: it is swept after `DROPS.LIFETIME_MINUTES` and nothing
-- about it survives a restart. That is a fair price for a bandage and a wrong one
-- for a stack of eddies, which is somebody's balance in transit -- dropped and
-- forgotten, it is money deleted with nothing anywhere saying so. `DROP = false`
-- is therefore enforced by `Actions.Drop` on the SERVER; the flag is carried into
-- `ViewOf` only so the screen stops offering a row it is about to be refused for.
local function base(name, raw, where)
	return {
		name = name,
		weight = weightOf(name, raw, where),
		stackable = raw.STACK ~= false,
		droppable = raw.DROP ~= false,
		category = Common.Word(raw.CATEGORY, 32, '^[%w_]+$') or 'misc',
		label = textField(raw.LABEL),
		description = textField(raw.DESCRIPTION),
		image = Common.Word(raw.IMAGE, 64, '^[%w_%-%.]+$'),
		model = modelOf(name, raw.MODEL, where),
	}
end

--- Adds an entry, keeping the first of two carrying one name.
local function add(entry, where)
	if entries[entry.name] then
		problem(('%s: %s is declared twice; the first one is kept'):format(where, entry.name))
		return
	end
	entries[entry.name] = entry
	names[#names + 1] = entry.name
end

local data = M.Data or {}

local items = type(data.ITEMS) == 'table' and data.ITEMS or {}
if type(data.ITEMS) ~= 'table' then problem('data/items.lua declares no ITEMS') end
for name, raw in pairs(items) do
	if validName(name, 'data/items.lua') then
		if type(raw) ~= 'table' then
			problem(('data/items.lua %s: not a table'):format(name))
		else
			local entry = base(name, raw, 'data/items.lua')
			entry.use = useOf(name, raw.USE, 'data/items.lua')
			entry.usable = entry.use ~= nil
			add(entry, 'data/items.lua')
		end
	end
end

local weapons = type(data.WEAPONS) == 'table' and data.WEAPONS or {}
if type(data.WEAPONS) ~= 'table' then problem('data/weapons.lua declares no WEAPONS') end

-- Ammunition before the weapons, so a weapon class can be checked against the
-- ammunition it names rather than loading nothing at the moment it is drawn.
for name, raw in pairs(type(weapons.AMMO) == 'table' and weapons.AMMO or {}) do
	if validName(name, 'data/weapons.lua AMMO') then
		if type(raw) ~= 'table' then
			problem(('data/weapons.lua AMMO %s: not a table'):format(name))
		else
			local entry = base(name, raw, 'data/weapons.lua AMMO')
			entry.category = 'ammo'
			entry.stackable = true
			entry.usable = true
			local max = Common.Integer(raw.MAX, 1, 100000)
			entry.ammo = { max = max or 250 }
			if max == nil then
				problem(('data/weapons.lua AMMO %s: MAX must be a whole number; using 250')
					:format(name))
			end
			add(entry, 'data/weapons.lua AMMO')
		end
	end
end

local classes = type(weapons.CLASSES) == 'table' and weapons.CLASSES or {}
local weaponRows = type(weapons.WEAPONS) == 'table' and weapons.WEAPONS or {}

-- Weapon names left to index, in the order the parts take them. The order comes
-- from `pairs`, so which part carries a given weapon changes from one start to
-- the next -- of no consequence while the names are unique, which `add` enforces.
local queue = {}
for name in pairs(weaponRows) do queue[#queue + 1] = name end

local nextWeapon = 1

--- Indexes the next `count` weapons. Each part file calls this once.
-- @author dop42
-- @param count integer
function Catalog.IndexWeapons(count)
	local last = math.min(#queue, nextWeapon + count - 1)
	for position = nextWeapon, last do
		local name = queue[position]
		local raw = weaponRows[name]
		if validName(name, 'data/weapons.lua WEAPONS') and type(raw) == 'table' then
			local record = Common.Word(raw.RECORD, 256, '^Items%.[%w_%.]+$')
			local class = classes[raw.CLASS]
			if record == nil then
				problem(('data/weapons.lua %s: RECORD must be an Items.* TweakDB record; left out')
					:format(name))
			elseif type(class) ~= 'table' then
				problem(('data/weapons.lua %s: CLASS %q is not in CLASSES; left out')
					:format(name, tostring(raw.CLASS)))
			else
				local ammo = class.AMMO
				if ammo ~= nil and not (entries[ammo] and entries[ammo].ammo) then
					problem(('data/weapons.lua class %s names ammo %q, which AMMO does not ' ..
						'declare; %s loads nothing'):format(tostring(raw.CLASS), tostring(ammo), name))
					ammo = nil
				end
				local entry = base(name, raw, 'data/weapons.lua')
				entry.model = entry.model
					or modelOf(tostring(raw.CLASS), class.MODEL, 'data/weapons.lua class')
				entry.category = 'weapon'
				entry.stackable = false
				entry.usable = true
				-- THE MAGAZINE, AND IT IS NOT THE AMMO ITEM'S STACK. `AMMO.MAX` is
				-- how many rounds fit in a BOX -- five hundred for a handgun --
				-- and the weapon half was reading it as how many fit in the gun,
				-- so a player could load a pistol with the whole crate. The
				-- weapon's own value wins, its class's is the default, and a
				-- class with none loads nothing rather than everything: a
				-- magazine nobody stated is a magazine nobody has thought about,
				-- and refusing is the answer that gets noticed.
				local magazine = Common.Integer(raw.MAGAZINE, 1, 9999)
					or Common.Integer(class.MAGAZINE, 1, 9999)
				if ammo ~= nil and magazine == nil then
					problem(('data/weapons.lua %s: neither it nor class %s states a MAGAZINE, so '
						.. 'it loads nothing'):format(name, tostring(raw.CLASS)))
				end
				entry.weapon = { record = record, class = raw.CLASS, ammo = ammo,
					magazine = magazine }
				add(entry, 'data/weapons.lua')
			end
		end
	end
	nextWeapon = last + 1
end

--- Indexes the weapons left over, then sorts every item name.
-- @author dop42
function Catalog.Finish()
	local left = #queue - nextWeapon + 1
	if left > Catalog.PART then
		problem(('data/weapons.lua: %d weapons were left to the last catalogue part; add a ' ..
			'shared/catalog-<n>.lua part to open77.lua for every %d weapons past it')
			:format(left, Catalog.PART))
	end
	Catalog.IndexWeapons(left)
	table.sort(names)
end

-- ── items registered at runtime ──────────────────────────────────────────────
-- ANOTHER RESOURCE MAY ADD AN ITEM WHILE THE SERVER RUNS, through the
-- `RegisterItem` export. The definition is checked HERE, by the one function
-- both halves run, so the server cannot accept a row the client would refuse
-- and draw differently. It is refused WHOLE on the first thing wrong, unlike a
-- config row, which is a boot warning: a creator calling an export is told why
-- at the call, and half an item is worse than none.
--
-- WHAT A RUNTIME ITEM MAY NOT BE: a weapon or ammunition (those need a TweakDB
-- record and a class, which only `data/weapons.lua` can vouch for), a name
-- the catalogue already carries from config, or a name another owner
-- registered. Its own owner may register it again, which REPLACES it -- a
-- creator restarting its resource sends the same definitions again.
--
-- IT IS NOT REMOVED WHEN ITS OWNER STOPS. Stacks of it are in bags and in the
-- database, and an item that vanished from the catalogue under them would weigh
-- the default and draw as its bare name until the owner came back.

-- The creator-facing fields, lower case, and the catalogue key each becomes.
local RUNTIME_FIELDS = {
	label = 'LABEL', description = 'DESCRIPTION', weight = 'WEIGHT', stack = 'STACK',
	drop = 'DROP', category = 'CATEGORY', image = 'IMAGE', model = 'MODEL', use = 'USE',
}

-- The fields of `use`, lower case.
local RUNTIME_USE = { consume = 'CONSUME', close = 'CLOSE', status = 'STATUS', animation = 'ANIMATION' }

-- Most needs one runtime item's `use.status` may move. The needs a server has
-- are a handful; see the client budget note where it is checked.
local RUNTIME_STATUS_MAX = 8

-- Runtime definitions by name, as given (lower case), with their owner: what
-- the server sends a client that joins after they were registered.
local runtime = {}

--- The first thing wrong with a runtime definition, or nil and the catalogue
--- row it becomes.
local function runtimeRow(raw)
	if type(raw) ~= 'table' or getmetatable(raw) ~= nil then return 'definition' end
	local row = {}
	for key, value in pairs(raw) do
		local field = type(key) == 'string' and RUNTIME_FIELDS[key] or nil
		if field == nil then return 'field:' .. tostring(key) end
		row[field] = value
	end
	if row.LABEL ~= nil and textField(row.LABEL) == nil then return 'label' end
	if row.DESCRIPTION ~= nil and textField(row.DESCRIPTION) == nil then return 'description' end
	if row.WEIGHT ~= nil and Common.Integer(row.WEIGHT, 0, 1000000000) == nil then return 'weight' end
	if row.STACK ~= nil and type(row.STACK) ~= 'boolean' then return 'stack' end
	if row.DROP ~= nil and type(row.DROP) ~= 'boolean' then return 'drop' end
	if row.CATEGORY ~= nil and Common.Word(row.CATEGORY, 32, '^[%w_]+$') == nil then return 'category' end
	if row.CATEGORY == 'weapon' or row.CATEGORY == 'ammo' then return 'category' end
	if row.IMAGE ~= nil and Common.Word(row.IMAGE, 64, '^[%w_%-%.]+$') == nil then return 'image' end
	if row.MODEL ~= nil then
		local model = Common.Word(row.MODEL, 256, '^[%w_%-%.]+$')
		if model == nil or model:find('%.mesh$') then return 'model' end
	end
	if row.USE ~= nil then
		if type(row.USE) ~= 'table' then return 'use' end
		local use = {}
		for key, value in pairs(row.USE) do
			local field = type(key) == 'string' and RUNTIME_USE[key] or nil
			if field == nil then return 'use.' .. tostring(key) end
			use[field] = value
		end
		if use.CONSUME ~= nil and Common.Integer(use.CONSUME, 0, 1000000) == nil then
			return 'use.consume'
		end
		if use.CLOSE ~= nil and type(use.CLOSE) ~= 'boolean' then return 'use.close' end
		if use.STATUS ~= nil then
			if type(use.STATUS) ~= 'table' then return 'use.status' end
			-- BOUNDED, because every client walks this table twice (here and in
			-- `useOf`) inside the one resume that received it: a few hundred keys
			-- on one item spend the whole budget, the client's handler is killed,
			-- and the item the server took never reaches that client.
			local keys = 0
			for key, amount in pairs(use.STATUS) do
				keys = keys + 1
				if keys > RUNTIME_STATUS_MAX or type(key) ~= 'string' or #key > 32
					or not OPX.Math.IsFinite(amount) then
					return 'use.status'
				end
			end
		end
		if use.ANIMATION ~= nil then
			local animation = use.ANIMATION
			if type(animation) ~= 'table' or Common.Word(animation.name, 32, '^[%w_]+$') == nil
				or (animation.variant ~= nil and Common.Integer(animation.variant, 1, 64) == nil)
				or (animation.durationMs ~= nil
					and Common.Integer(animation.durationMs, 1000, 600000) == nil) then
				return 'use.animation'
			end
			use.ANIMATION = { NAME = animation.name, VARIANT = animation.variant,
				DURATION_MS = animation.durationMs }
		end
		row.USE = use
	end
	return nil, row
end

--- Puts a name into the sorted list where it belongs. A binary search and one
--- insert, never a sort: a client receives these a chunk at a time inside one
--- resume, and sorting a few hundred names there costs more than its budget.
local function placeName(name)
	local low, high = 1, #names
	while low <= high do
		local middle = (low + high) // 2
		if names[middle] < name then low = middle + 1 else high = middle - 1 end
	end
	table.insert(names, low, name)
end

--- Adds, or replaces for its own owner, one item at runtime.
-- @author dop42
-- @param name any
-- @param raw any the creator-facing definition, lower-case fields
-- @param owner string who registered it
-- @return boolean
-- @return string|nil the refusal: `bad_name`, `item_taken`, `bad_definition:<field>`
function Catalog.Register(name, raw, owner)
	if Common.Word(name, Catalog.NAME_MAX, Catalog.NAME) == nil then return false, 'bad_name' end
	if type(owner) ~= 'string' or owner == '' then return false, 'bad_owner' end
	local held = entries[name]
	if held ~= nil and held.owner ~= owner then return false, 'item_taken' end
	local wrong, row = runtimeRow(raw)
	if wrong ~= nil then return false, 'bad_definition:' .. wrong end

	local entry = base(name, row, 'runtime ' .. owner)
	entry.use = useOf(name, row.USE, 'runtime ' .. owner)
	entry.usable = entry.use ~= nil
	entry.owner = owner
	entries[name] = entry
	if held == nil then placeName(name) end
	runtime[name] = { owner = owner, definition = Common.Copy(raw) }
	return true, nil
end

--- Every item registered at runtime: name -> { owner, definition }. A copy.
-- @author dop42
-- @return table
function Catalog.Runtime()
	return Common.Copy(runtime)
end

--- How many items one owner registered at runtime.
-- @author dop42
-- @param owner string
-- @return integer
function Catalog.RuntimeCount(owner)
	local count = 0
	for _, held in pairs(runtime) do
		if held.owner == owner then count = count + 1 end
	end
	return count
end

--- One catalogue entry by name, or nil.
-- @author dop42
-- @param name any
-- @return table|nil
function Catalog.Get(name)
	if type(name) ~= 'string' then return nil end
	return entries[name]
end

--- Every item name, sorted.
-- @author dop42
-- @return string[]
function Catalog.Names()
	return names
end

--- The grams a count of an item weighs, defaulting for one the catalogue no
--- longer carries.
-- @author dop42
-- @param name string
-- @param count integer|nil
-- @return integer
function Catalog.WeightOf(name, count)
	local entry = entries[name]
	return (entry and entry.weight or DEFAULT_WEIGHT) * (count or 1)
end

--- The grams per unit of an item nothing knows about.
-- @author dop42
-- @return integer
function Catalog.DefaultWeight()
	return DEFAULT_WEIGHT
end

--- Resolves a field that may be a catalogue key, keeping it as text when it is
--- not one. The same rule serves an item's LABEL and a configured stash's.
-- @author dop42
-- @param value string|nil
-- @return string|nil
function Catalog.Rendered(value)
	if value == nil then return nil end
	if OPX.Locale.Exists(value) then return locale(value) end
	return value
end

--- An item's display name in the configured language.
-- @author dop42
-- @param name string
-- @return string
function Catalog.Label(name)
	local entry = entries[name]
	if entry and entry.label then return Catalog.Rendered(entry.label) end
	local key = 'inventory.item.' .. tostring(name)
	if OPX.Locale.Exists(key) then return locale(key) end
	return tostring(name)
end

--- An item's description in the configured language, or nil.
-- @author dop42
-- @param name string
-- @return string|nil
function Catalog.Description(name)
	local entry = entries[name]
	if entry and entry.description then return Catalog.Rendered(entry.description) end
	local key = 'inventory.item.' .. tostring(name) .. '.description'
	if OPX.Locale.Exists(key) then return locale(key) end
	return nil
end

--- One entry as the screen reads it, or nil.
-- Roughly sixty VM instructions: a client walking the whole catalogue does it in
-- parts and yields between them, which is why there is no read-it-all-at-once.
-- @author dop42
-- @param name any
-- @return table|nil
function Catalog.ViewOf(name)
	local entry = type(name) == 'string' and entries[name] or nil
	if entry == nil then return nil end
	return {
		label = Catalog.Label(entry.name),
		description = Catalog.Description(entry.name),
		weight = entry.weight,
		image = entry.image,
		usable = entry.usable == true,
		stackable = entry.stackable,
		droppable = entry.droppable ~= false,
		category = entry.category,
		weapon = entry.weapon ~= nil,
		ammo = entry.ammo ~= nil,
	}
end
