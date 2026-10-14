--- The row registry: validation, ownership and matching, with no host call of its own.
-- @author dop42
--
-- Deliberately pure. Every question that needs the host -- is this owner still
-- running, what did the ray hit, does this row's owner say yes -- is asked by the
-- caller and handed in. That is what makes `alive` a parameter of `Model.New`
-- rather than a call from inside the loops here, and it is why one sweep can
-- serve a whole batch: the registry never decides on its own when to ask.
--
-- The two bounds below are the ones a pick pays for. `Candidates` walks every
-- registered row, and every row that matches costs its owner a question, so the
-- size of this table IS the cost of holding the key down.

local M = OPX.Modules.Get('target')

M.Model = {}
local Model = M.Model

-- Target kinds the screen ray answers.
local KINDS = { player = true, vehicle = true, npc = true, prop = true, door = true, device = true,
	item = true, object = true, world = true, sky = true }

-- Icons the page draws, and NOT a list of its own: `OPX.Glyphs` in
-- `core/shared/glyphs.lua` is the one set, because the three hand-kept copies
-- this used to be one of had drifted to 47 names, 45 and 14. A name outside it
-- is refused rather than passed through -- the page selects a local glyph by it,
-- and an unknown name would reach the DOM as an attribute nobody wrote.
Model.ICONS = OPX.Glyphs

-- Rows every owner together may hold.
Model.MAX_TOTAL = 128

-- Rows one owner may hold.
Model.MAX_PER_OWNER = 48

-- Entries in one batch, one filter list or one entity list.
Model.MAX_LIST = 32

-- Bytes a row's data may weigh, counted roughly.
local MAX_DATA_BYTES = 2048

-- The fields a definition keeps; anything else is dropped. `onSelect` runs when
-- the row is chosen, `canInteract` decides whether it is listed at all, and
-- `checked` answers true or false to draw a box. `confirm` asks for a second
-- click before `onSelect` runs; a `danger` row asks unless it says `confirm = false`.
local FIELDS = { 'id', 'label', 'onSelect', 'canInteract', 'checked', 'description', 'group', 'icon',
	'enabled', 'networked', 'allowSelf', 'selfOnly', 'danger', 'confirm', 'distance', 'order', 'types', 'records',
	'entities', 'spheres', 'data' }

-- Largest radius of one sphere, in metres.
local MAX_SPHERE_RADIUS = 10

-- Whether a value is a finite number. `OPX.Math.IsFinite` and not a fourth hand
-- rolling of it: this one tested `value > -math.huge and value < math.huge`
-- rather than comparing against the infinities directly, which is the same
-- answer by a different route and a fifth thing to get right next time.
local finite = OPX.Math.IsFinite

--- Whether a value is one line of text no longer than max bytes.
-- @author dop42
-- @param value any
-- @param max integer
-- @return boolean
function Model.Text(value, max)
	return type(value) == 'string' and #value > 0 and #value <= max and not value:find('%c')
end

--- Whether a value is an id, an owner name or an export name.
-- @author dop42
-- @param value any
-- @return boolean
function Model.Name(value)
	return Model.Text(value, 64) and value:match('^[%w_%.:%-]+$') ~= nil
end

-- Deep copy of plain data, so a caller's table is never kept. A function passes
-- through by reference, which is what makes an in-process callback survive the
-- copy that `Update` and `Describe` make of a definition.
local function copy(value)
	if type(value) ~= 'table' then return value end
	local out = {}
	for key, item in pairs(value) do out[key] = copy(item) end
	return out
end

--- Whether a value is an array of 1..max entries with no holes or extra keys.
-- @author dop42
-- @param value any
-- @param max integer
-- @return boolean
function Model.Dense(value, max)
	if type(value) ~= 'table' or #value < 1 or #value > max then return false end
	local count = 0
	for key in pairs(value) do
		if not finite(key) or key % 1 ~= 0 or key < 1 or key > #value then return false end
		count = count + 1
	end
	return count == #value
end

--- Normalises a row callback into a function or an `{ resource, export }` pair.
-- @author dop42
--
-- Three accepted shapes, and the middle one is why this exists. A FUNCTION is
-- called in-process and is what a module registers. A TABLE naming a resource and
-- an export goes over `OPX.Lib.Rpc.Call`, for an owner that is a genuinely separate
-- resource. A bare STRING is the shape every caller written before this runtime
-- used -- an export on the owner's own resource -- and is normalised into the
-- second, so those definitions register unchanged.
-- @param value any
-- @param owner string
-- @return function|table|nil nil when the value is none of the three
function Model.Callback(value, owner)
	if type(value) == 'function' then return value end
	if type(value) == 'string' then
		if not Model.Name(value) or not Model.Name(owner) then return nil end
		return { resource = owner, export = value }
	end
	if type(value) ~= 'table' then return nil end
	if not Model.Name(value.resource) or not Model.Name(value.export) then return nil end
	return { resource = value.resource, export = value.export }
end

-- Whether row data is small plain data: no functions and no cycles. There is no
-- `getmetatable` in the client sandbox, so a table carrying a metatable cannot be
-- refused here and is simply copied field by field, which strips it.
local function plainData(value)
	local remaining, seen = MAX_DATA_BYTES, {}
	local function visit(item, depth)
		remaining = remaining - 8
		if remaining < 0 or depth > 4 then return false end
		local kind = type(item)
		if kind == 'string' then
			remaining = remaining - #item
			return remaining >= 0
		end
		if kind == 'number' then return finite(item) end
		if kind == 'boolean' or kind == 'nil' then return true end
		if kind ~= 'table' or seen[item] then return false end
		seen[item] = true
		for key, child in pairs(item) do
			local keyOk = (type(key) == 'string' and #key <= 64)
				or (finite(key) and key % 1 == 0 and key >= 1 and key <= 64)
			if not keyOk or not visit(key, depth + 1) or not visit(child, depth + 1) then return false end
		end
		seen[item] = nil
		return true
	end
	return visit(value, 0)
end

-- Whether a value names exactly one entity by player, vehicle, npc, engine or
-- prop id.
local function selector(value)
	if type(value) ~= 'table' then return false end
	local count = 0
	for key, id in pairs(value) do
		count = count + 1
		if key == 'playerId' or key == 'vehicleId' or key == 'npcId' then
			-- Vehicle and npc ids carry a generation and can pass 2^32: keep exact
			-- integers only.
			if not finite(id) or id % 1 ~= 0 or id < 1
				or (math.type(id) ~= 'integer' and id > 9007199254740991) then
				return false
			end
		elseif key == 'engineEntity' or key == 'propId' then
			if type(id) ~= 'string' or #id > 20 or not id:match('^[1-9]%d*$') then return false end
		else
			return false
		end
	end
	return count == 1
end

-- Whether a value is a point with a radius: x, y, z and radius, nothing else.
local function sphere(value)
	if type(value) ~= 'table' then return false end
	for key in pairs(value) do
		if key ~= 'x' and key ~= 'y' and key ~= 'z' and key ~= 'radius' then return false end
	end
	return finite(value.x) and finite(value.y) and finite(value.z) and finite(value.radius)
		and value.radius >= 0.1 and value.radius <= MAX_SPHERE_RADIUS
end

-- Turns an optional list into a lookup set, or answers false when it is malformed.
local function set(value, valid)
	if value == nil then return nil, true end
	if not Model.Dense(value, Model.MAX_LIST) then return nil, false end
	local out = {}
	for _, entry in ipairs(value) do
		if not valid(entry) then return nil, false end
		out[entry] = true
	end
	return out, true
end

--- Makes an empty registry, asking `alive` whether an owner generation still runs.
-- @author dop42
-- @param alive fun(owner: string, generation: any): boolean
-- @return table
function Model.New(alive)
	local registry = {}
	local rows, sequence = {}, 0

	--- Forgets the rows of owners that stopped, or that reloaded under a new
	--- generation.
	-- @author dop42
	--
	-- With `census`, the same walk also counts the surviving rows -- the total,
	-- the owner's own and the owner's tokens by id -- which is what a batch
	-- needs for its limits; a second walk was the other half of a batch's cost.
	-- The verdicts are remembered per owner, with the generation they answered
	-- for, rather than under a key string built for every row.
	local function sweep(census, owner)
		-- ONE question per owner generation, not per row. Each is a host read, and
		-- a registry of a hundred rows held by four owners is four reads, not a
		-- hundred. This is the loop that made the difference.
		local verdicts, asked = {}, {}
		for token, row in pairs(rows) do
			local name, generation = row.owner, row.generation
			local ok
			if asked[name] == generation and verdicts[name] ~= nil then
				ok = verdicts[name]
			else
				ok = alive(name, generation) == true
				asked[name], verdicts[name] = generation, ok
			end
			if not ok then
				rows[token] = nil
			elseif census ~= nil then
				census.total = census.total + 1
				if name == owner then
					census.own = census.own + 1
					census.byId[row.id] = token
				end
			end
		end
	end

	function registry.Sweep()
		sweep(nil, nil)
	end

	--- Forgets every row of one owner.
	-- @author dop42
	-- @param owner string
	function registry.RemoveOwner(owner)
		for token, row in pairs(rows) do
			if row.owner == owner then rows[token] = nil end
		end
	end

	--- Validates one definition and stores it, replacing the owner's row of the
	--- same id.
	-- @author dop42
	-- @param owner string
	-- @param generation any
	-- @param definition table
	-- @param swept boolean|nil whether the caller already swept, as a batch does once for all
	-- @param census table|nil the batch's running count: `total`, `own` and the
	-- owner's tokens by id, so a batch walks the registry once and not once a row
	-- @param undo table|nil the batch's log of what each store replaced
	-- @return string|nil the token
	-- @return string|nil the refusal
	function registry.Register(owner, generation, definition, swept, census, undo)
		if not swept then registry.Sweep() end
		if not Model.Name(owner) or not alive(owner, generation) then return nil, 'invalid_owner' end

		local d = definition
		if type(d) ~= 'table' or not Model.Name(d.id) or not Model.Text(d.label, 80) then
			return nil, 'invalid_option'
		end
		local onSelect = Model.Callback(d.onSelect, owner)
		if onSelect == nil then return nil, 'invalid_option' end
		local canInteract
		if d.canInteract ~= nil then
			canInteract = Model.Callback(d.canInteract, owner)
			if canInteract == nil then return nil, 'invalid_predicate' end
		end
		local checked
		if d.checked ~= nil then
			checked = Model.Callback(d.checked, owner)
			if checked == nil then return nil, 'invalid_checked' end
		end
		if d.description ~= nil and not Model.Text(d.description, 180) then return nil, 'invalid_description' end
		if d.group ~= nil and not Model.Text(d.group, 40) then return nil, 'invalid_group' end
		if d.icon ~= nil and not Model.ICONS[d.icon] then return nil, 'invalid_icon' end
		for _, field in ipairs({ 'enabled', 'networked', 'allowSelf', 'selfOnly', 'danger', 'confirm' }) do
			if d[field] ~= nil and type(d[field]) ~= 'boolean' then return nil, 'invalid_' .. field end
		end
		local distance = d.distance or 3.0
		if not finite(distance) or distance < 0.1 or distance > 50 then return nil, 'invalid_distance' end
		local order = d.order or 0
		if not finite(order) or order % 1 ~= 0 or math.abs(order) > 1000 then return nil, 'invalid_order' end
		local types, typesOk = set(d.types, function(kind) return KINDS[kind] == true end)
		if not typesOk then return nil, 'invalid_types' end
		local records, recordsOk = set(d.records, function(record) return Model.Text(record, 200) end)
		if not recordsOk then return nil, 'invalid_records' end
		if d.selfOnly and (not d.allowSelf or (types and not types.player)) then return nil, 'invalid_self_filter' end
		if d.entities ~= nil then
			if not Model.Dense(d.entities, Model.MAX_LIST) then return nil, 'invalid_entities' end
			for _, entry in ipairs(d.entities) do
				if not selector(entry) then return nil, 'invalid_entities' end
			end
		end
		if d.spheres ~= nil then
			if not Model.Dense(d.spheres, Model.MAX_LIST) then return nil, 'invalid_spheres' end
			for _, entry in ipairs(d.spheres) do
				if not sphere(entry) then return nil, 'invalid_spheres' end
			end
		end
		if not plainData(d.data) then return nil, 'invalid_data' end

		local total, own, previous = 0, 0, nil
		if census ~= nil then
			total, own, previous = census.total, census.own, census.byId[d.id]
		else
			for token, row in pairs(rows) do
				total = total + 1
				if row.owner == owner then
					own = own + 1
					if row.id == d.id then previous = token end
				end
			end
		end
		if previous == nil and (total >= Model.MAX_TOTAL or own >= Model.MAX_PER_OWNER) then
			return nil, 'option_limit'
		end
		if previous ~= nil then
			if undo ~= nil then undo[#undo + 1] = { token = previous, row = rows[previous] } end
			rows[previous] = nil
		end

		local kept = {}
		for _, field in ipairs(FIELDS) do kept[field] = copy(d[field]) end
		sequence = sequence + 1
		local token = tostring(sequence)
		rows[token] = {
			token = token, sequence = sequence, owner = owner, generation = generation,
			id = d.id, label = d.label, description = d.description, group = d.group or '',
			icon = d.icon or 'interact', onSelect = onSelect, canInteract = canInteract,
			checked = checked, types = types, records = records, distance = distance, order = order,
			enabled = d.enabled ~= false, networked = d.networked, allowSelf = d.allowSelf == true,
			selfOnly = d.selfOnly == true, danger = d.danger == true,
			confirm = d.confirm == true or (d.danger == true and d.confirm ~= false),
			entities = copy(d.entities), spheres = copy(d.spheres), data = copy(d.data), definition = kept,
		}
		if undo ~= nil then undo[#undo + 1] = { token = token } end
		if census ~= nil then
			if previous == nil then
				census.total, census.own = census.total + 1, census.own + 1
			end
			census.byId[d.id] = token
		end
		return token
	end

	--- Registers a batch whole or not at all.
	-- @author dop42
	-- @param owner string
	-- @param generation any
	-- @param definitions table[]
	-- @return string[]|nil
	-- @return string|nil the refusal
	function registry.RegisterMany(owner, generation, definitions)
		if not Model.Dense(definitions, Model.MAX_LIST) then return nil, 'invalid_options' end
		local ids = {}
		for _, d in ipairs(definitions) do
			if type(d) ~= 'table' or not Model.Name(d.id) or ids[d.id] then return nil, 'invalid_or_duplicate_id' end
			ids[d.id] = true
		end
		-- Once for the whole batch, and every Register below is told so: a batch of
		-- sixteen rows used to be sixteen sweeps, each of them a host read per owner.
		--
		-- ONE WALK FOR THE BATCH, and an undo log instead of a copy. Every row
		-- used to count the whole registry for the limits, and the batch copied
		-- the whole registry for its rollback: at a full registry that was most of
		-- what a staff batch cost, inside the one resume the caller gave it. The
		-- census is counted in the sweep's own walk and kept up to date as the
		-- batch stores; a refusal puts back exactly what the batch replaced and
		-- removes what it added.
		local census = { total = 0, own = 0, byId = {} }
		sweep(census, owner)
		local undo, count = {}, sequence
		local tokens = {}
		for _, d in ipairs(definitions) do
			local token, reason = registry.Register(owner, generation, d, true, census, undo)
			if token == nil then
				for index = #undo, 1, -1 do
					local change = undo[index]
					rows[change.token] = change.row
				end
				sequence = count
				return nil, reason
			end
			tokens[#tokens + 1] = token
		end
		return tokens
	end

	--- Answers a live row by token, or nil.
	-- @author dop42
	-- @param token any
	-- @return table|nil
	function registry.Get(token)
		if type(token) ~= 'string' then return nil end
		local row = rows[token]
		if row ~= nil and not alive(row.owner, row.generation) then
			rows[token] = nil
			return nil
		end
		return row
	end

	--- Re-registers one of the owner's rows with some fields changed, under a new
	--- token.
	-- @author dop42
	-- @param owner string
	-- @param generation any
	-- @param token string
	-- @param patch table
	-- @return string|nil the new token
	-- @return string|nil the refusal
	function registry.Update(owner, generation, token, patch)
		local row = registry.Get(token)
		if row == nil or row.owner ~= owner then return nil, 'not_owner' end
		if type(patch) ~= 'table' or (patch.id ~= nil and patch.id ~= row.id) then return nil, 'invalid_patch' end
		local definition = copy(row.definition)
		for key, value in pairs(patch) do definition[key] = value end
		return registry.Register(owner, generation, definition)
	end

	--- Answers a copy of one of the owner's definitions.
	-- @author dop42
	-- @param owner string
	-- @param token string
	-- @return table|nil
	-- @return string|nil the refusal
	function registry.Describe(owner, token)
		local row = registry.Get(token)
		if row == nil or row.owner ~= owner then return nil, 'not_owner' end
		return copy(row.definition)
	end

	--- Removes one of the owner's rows.
	-- @author dop42
	-- @param owner string
	-- @param token string
	-- @return boolean
	-- @return string|nil the refusal
	function registry.Unregister(owner, token)
		local row = type(token) == 'string' and rows[token] or nil
		if row == nil then return false, 'option_not_found' end
		if row.owner ~= owner then return false, 'not_owner' end
		rows[token] = nil
		return true
	end

	--- Removes several of the owner's rows, all or none.
	-- @author dop42
	-- @param owner string
	-- @param tokens string[]
	-- @return boolean
	-- @return string|nil the refusal
	function registry.UnregisterMany(owner, tokens)
		if not Model.Dense(tokens, Model.MAX_LIST) then return false, 'invalid_tokens' end
		for _, token in ipairs(tokens) do
			local row = type(token) == 'string' and rows[token] or nil
			if row == nil or row.owner ~= owner then return false, 'not_owner' end
		end
		for _, token in ipairs(tokens) do rows[token] = nil end
		return true
	end

	--- Switches one of the owner's rows on or off.
	-- @author dop42
	-- @param owner string
	-- @param token string
	-- @param value boolean
	-- @return boolean
	-- @return string|nil the refusal
	function registry.SetEnabled(owner, token, value)
		local row = type(token) == 'string' and rows[token] or nil
		if row == nil or row.owner ~= owner then return false, 'not_owner' end
		if type(value) ~= 'boolean' then return false, 'expected_boolean' end
		row.enabled = value
		row.definition.enabled = value
		return true
	end

	--- Whether a row applies to what the ray hit, before its predicate.
	-- @author dop42
	-- @param row table
	-- @param context table
	-- @return boolean
	--
	-- CHEAPEST TEST FIRST. Every test here is a pure predicate of the row and the
	-- context, so their order changes the cost and never the answer -- and this
	-- runs for every registered row on every hover and every pick, inside the
	-- scheduler's shared resume. The owner check (a lookup through the module
	-- registry) and the entity and sphere walks used to come before the plain
	-- field compares that turn most rows away; they now come after.
	function registry.Matches(row, context)
		if not row.enabled then return false end
		local target = type(context.target) == 'table' and context.target or { kind = 'world', networked = false }
		if target.kind == 'sky' then
			-- Empty space is opt-in, never a surface at distance zero.
			if row.types == nil or row.types.sky ~= true then return false end
		elseif not finite(context.playerDistance) or context.playerDistance < 0
			or context.playerDistance > row.distance then
			return false
		end
		if target.isLocalPlayer and not row.allowSelf then return false end
		if row.selfOnly and target.isLocalPlayer ~= true then return false end
		if row.types ~= nil and row.types[target.kind] ~= true then return false end
		if row.records ~= nil and row.records[target.record] ~= true then return false end
		if row.networked ~= nil and row.networked ~= target.networked then return false end
		if not alive(row.owner, row.generation) then return false end
		if row.entities ~= nil then
			local named = false
			for _, entry in ipairs(row.entities) do
				for key, id in pairs(entry) do
					if target[key] == id then named = true end
				end
			end
			if not named then return false end
		end
		if row.spheres ~= nil then
			-- The hit point, so a mesh with no collision still answers through the
			-- ground under it.
			local at = context.position
			if target.kind == 'sky' or type(at) ~= 'table' then return false end
			local inside = false
			for _, entry in ipairs(row.spheres) do
				if (at.x - entry.x) ^ 2 + (at.y - entry.y) ^ 2 + (at.z - entry.z) ^ 2 <= entry.radius ^ 2 then
					inside = true
					break
				end
			end
			if not inside then return false end
		end
		return true
	end

	--- Every row matching a context, in display order.
	-- @author dop42
	-- @param context table
	-- @return table[]
	function registry.Candidates(context)
		registry.Sweep()
		local out = {}
		for _, row in pairs(rows) do
			if registry.Matches(row, context) then out[#out + 1] = row end
		end

		-- A GROUP IS SORTED WHOLE, AT THE RANK OF ITS BEST ROW.
		--
		-- `order` came first and the group second, which meant two rows of one
		-- folder with different orders were separated by every row that ordered
		-- between them. The page folds a group into a folder wherever its name is
		-- first seen, so the folder still appeared -- but the rows AROUND it moved
		-- to wherever those two orders fell, and the column read as a shuffle of
		-- one owner's rows into another's.
		--
		-- Ranking by the group's lowest order keeps both properties that matter:
		-- every folder is one contiguous run, and a folder still sits where its
		-- most important row asked to sit. The ungrouped rows are a group like any
		-- other -- `''` -- so an owner that wants its own row above every folder
		-- still says so with `order` and nothing else.
		local rank = {}
		for _, row in ipairs(out) do
			local best = rank[row.group]
			if best == nil or row.order < best then rank[row.group] = row.order end
		end

		table.sort(out, function(left, right)
			local a, b = rank[left.group], rank[right.group]
			if a ~= b then return a < b end
			if left.group ~= right.group then return left.group < right.group end
			if left.order ~= right.order then return left.order < right.order end
			if left.label ~= right.label then return left.label < right.label end
			return left.sequence < right.sequence
		end)
		return out
	end

	--- Whether at least one row matches a context, before predicates.
	-- @author dop42
	-- @param context table
	-- @return boolean
	function registry.Any(context)
		for _, row in pairs(rows) do
			if registry.Matches(row, context) then return true end
		end
		return false
	end

	--- The owner's rows, short form, by id.
	-- @author dop42
	-- @param owner string
	-- @return table[]
	function registry.List(owner)
		registry.Sweep()
		local out = {}
		for _, row in pairs(rows) do
			if row.owner == owner then
				out[#out + 1] = { token = row.token, id = row.id, label = row.label, enabled = row.enabled }
			end
		end
		table.sort(out, function(left, right) return left.id < right.id end)
		return out
	end

	--- How many rows are held, and by how many owners. For the diagnostic line.
	-- @author dop42
	-- @return integer
	-- @return integer
	function registry.Size()
		local total, owners, seen = 0, 0, {}
		for _, row in pairs(rows) do
			total = total + 1
			if not seen[row.owner] then
				seen[row.owner] = true
				owners = owners + 1
			end
		end
		return total, owners
	end

	return registry
end
