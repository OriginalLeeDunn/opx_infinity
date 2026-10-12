--- Config reads, the boot validator, and every number the desk pays by.
-- @author dop42
--
-- PURE, like `modules/hauling/shared/access.lua`: not one host call. Every
-- function takes what it needs as arguments -- the config, a clock, a list of
-- recent sales -- so the server calls it in a handler and a test drives it to
-- every branch without a world.
--
-- `Build` turns the operator's config into the shapes both halves read and
-- answers what it refused. A BAD NEWSROOM IS REFUSED ALONE: a typo in the
-- screamsheet's desk must not take N54 off the air. A desk at three exact
-- zeros is not refused but DISABLED until somebody surveys it, and named so.

local M = OPX.Modules.Get('media')

M.Model = {}
local Model = M.Model

local finiteNumber = OPX.Math.Finite
local coordinate = OPX.Spots.Coordinate

local KEY_PATTERN = '^[%w_%-]+$'
local MAX_KEY = 48
Model.MAX_KEY = MAX_KEY

local function key(value)
	return type(value) == 'string' and #value >= 1 and #value <= MAX_KEY and value:match(KEY_PATTERN) ~= nil
end
Model.Key = key

local function text(value, maximum)
	if type(value) ~= 'string' or value == '' or #value > (maximum or 96) then return nil end
	return value
end

local function bounded(value, low, high)
	value = finiteNumber(value)
	if value == nil or value < low or value > high then return nil end
	return value
end

local function integer(value, low, high)
	value = bounded(value, low, high)
	if value == nil or value % 1 ~= 0 then return nil end
	return math.floor(value)
end

local function number(value, low, high, fallback)
	local read = bounded(value, low, high)
	if read == nil then return fallback end
	return read
end

local function whole(value, low, high, fallback)
	local read = integer(value, low, high)
	if read == nil then return fallback end
	return read
end

-- `{ MIN, MAX }` as `{ min, max }`, with a floor that never passes the ceiling.
local function span(raw, low, high, fallbackMin, fallbackMax)
	raw = type(raw) == 'table' and raw or {}
	local max = whole(raw.MAX, 1, high, fallbackMax)
	local min = whole(raw.MIN, low, max, math.min(fallbackMin, max))
	return { min = min, max = max }
end

local function clip(value)
	if type(value) ~= 'string' then return '' end
	return value
end

-- ── the newsrooms ───────────────────────────────────────────────────────────

local function deskOf(network, index, raw, problems, placeholders)
	local where = ('NETWORKS.%s.DESKS[%d]'):format(network, index)
	if type(raw) ~= 'table' then
		problems[#problems + 1] = where .. ': not a table'
		return nil
	end
	if not key(raw.KEY) then
		problems[#problems + 1] = where .. ': KEY must be a short word'
		return nil
	end
	local x, y, z = coordinate(raw.X), coordinate(raw.Y), coordinate(raw.Z)
	if x == nil or y == nil or z == nil then
		problems[#problems + 1] = where .. ': X, Y and Z must be numbers'
		return nil
	end
	local label = text(raw.LABEL) or raw.KEY
	if x == 0 and y == 0 and z == 0 then
		placeholders[#placeholders + 1] = ('%s/%s'):format(network, raw.KEY)
		return nil
	end
	return {
		key = raw.KEY, network = network, label = label, x = x, y = y, z = z,
		radius = number(raw.RADIUS, 0.5, 10, 2.0),
		bucket = whole(raw.BUCKET, 0, 1000000, 0),
		rate = number(raw.RATE, 0, 10, 1.0),
	}
end

local function networkOf(name, raw, problems, placeholders)
	if not key(name) then return nil, 'the key must be a short word' end
	if type(raw) ~= 'table' then return nil, 'not a table' end
	local label = text(raw.LABEL, 48)
	if label == nil then return nil, 'LABEL is required (48 bytes at most)' end
	local tag = text(raw.TAG, 12) or name:upper()
	local account = nil
	if raw.ACCOUNT ~= nil then
		local declared = raw.ACCOUNT
		if type(declared) ~= 'table' or (declared.KIND ~= 'job' and declared.KIND ~= 'gang') or not key(declared.KEY) then
			return nil, "ACCOUNT must be { KIND = 'job'|'gang', KEY = '<name>' }"
		end
		account = { kind = declared.KIND, key = declared.KEY }
	end
	local desks = {}
	local declared = type(raw.DESKS) == 'table' and raw.DESKS or {}
	local seen = {}
	for index = 1, math.min(#declared, 16) do
		local desk = deskOf(name, index, declared[index], problems, placeholders)
		if desk ~= nil then
			if seen[desk.key] then
				problems[#problems + 1] = ('NETWORKS.%s.DESKS: %s is named twice'):format(name, desk.key)
			else
				seen[desk.key] = true
				desks[#desks + 1] = desk
			end
		end
	end
	return {
		key = name, label = label, tag = tag,
		broadcast = raw.BROADCAST ~= false,
		account = account,
		desks = desks,
	}
end

local function itemOf(raw, fallbackName, fallbackLabel, fallbackWeight)
	raw = type(raw) == 'table' and raw or {}
	return {
		name = key(raw.NAME) and raw.NAME or fallbackName,
		label = text(raw.LABEL, 48) or fallbackLabel,
		description = text(raw.DESCRIPTION, 160),
		weight = whole(raw.WEIGHT, 0, 100000, fallbackWeight),
	}
end

local function gradesOf(raw)
	local out = {}
	for _, grade in ipairs(type(raw) == 'table' and raw or {}) do
		local level = integer(grade, 0, 100)
		if level ~= nil then out[level] = true end
	end
	return out
end

--- Builds the shapes both halves read out of the config.
-- @author dop42
-- @param settings table OPX.Config.MODULES.media
-- @return table { networks, job, ..., problems, placeholders }
function Model.Build(settings)
	settings = type(settings) == 'table' and settings or {}
	local problems, placeholders = {}, {}
	local networks, names = {}, {}
	for name in pairs(type(settings.NETWORKS) == 'table' and settings.NETWORKS or {}) do names[#names + 1] = tostring(name) end
	table.sort(names)
	for _, name in ipairs(names) do
		local network, why = networkOf(name, settings.NETWORKS[name], problems, placeholders)
		if network == nil then
			problems[#problems + 1] = ('NETWORKS.%s: %s'):format(name, why)
		else
			networks[name] = network
		end
	end
	local default = settings.DEFAULT_NETWORK
	if networks[default] == nil then
		local first = nil
		for _, name in ipairs(names) do
			if networks[name] ~= nil then first = name break end
		end
		if default ~= nil then
			problems[#problems + 1] = ('DEFAULT_NETWORK %s is not a newsroom; %s is used'):format(tostring(default),
				tostring(first))
		end
		default = first
	end

	local broadcast = type(settings.BROADCAST) == 'table' and settings.BROADCAST or {}
	local photo = type(settings.PHOTO) == 'table' and settings.PHOTO or {}
	local upload = type(photo.UPLOAD) == 'table' and photo.UPLOAD or {}
	local story = type(settings.STORY) == 'table' and settings.STORY or {}
	local sales = type(settings.SALES) == 'table' and settings.SALES or {}
	local salePhoto = type(sales.PHOTO) == 'table' and sales.PHOTO or {}
	local saleStory = type(sales.STORY) == 'table' and sales.STORY or {}
	local tips = type(settings.TIPS) == 'table' and settings.TIPS or {}
	local kit = type(settings.KIT) == 'table' and settings.KIT or {}
	local pass = type(settings.PASS) == 'table' and settings.PASS or {}
	local items = type(settings.ITEMS) == 'table' and settings.ITEMS or {}

	local url = type(photo.UPLOAD_URL) == 'string' and photo.UPLOAD_URL or ''
	if url ~= '' and not (url:match('^https?://[^%s@/]+') and #url <= 512) then
		problems[#problems + 1] = 'PHOTO.UPLOAD_URL must be an absolute http(s) URL without credentials; photos stay records'
		url = ''
	end
	local fresh = whole(sales.FRESH_S, 0, 604800, 1800)

	return {
		networks = networks,
		defaultNetwork = default,
		job = key(settings.JOB) and settings.JOB or 'reporter',
		onDuty = settings.ON_DUTY ~= false,
		metadata = key(settings.METADATA) and settings.METADATA or 'press',
		assignGrade = whole(settings.ASSIGN_GRADE, 0, 100, 3),
		freelance = gradesOf(settings.FREELANCE_GRADES),
		currency = key(settings.CURRENCY) and settings.CURRENCY or 'BANK',
		broadcast = {
			minGrade = whole(broadcast.MIN_GRADE, 0, 100, 2),
			headline = span(broadcast.HEADLINE, 1, 120, 6, 80),
			text = span(broadcast.TEXT, 0, 400, 0, 240),
			durationMs = whole(broadcast.DURATION_MS, 2000, 60000, 14000),
			chat = broadcast.CHAT ~= false,
			networkCooldownMs = whole(broadcast.NETWORK_COOLDOWN_MS, 0, 86400000, 300000),
			globalCooldownMs = whole(broadcast.GLOBAL_COOLDOWN_MS, 0, 86400000, 60000),
			maxPerHour = whole(broadcast.MAX_PER_HOUR, 1, 1000, 6),
			stinger = type(broadcast.STINGER) == 'table' and broadcast.STINGER or nil,
			feed = whole(broadcast.FEED, 1, 50, 10),
		},
		photo = {
			minGrade = whole(photo.MIN_GRADE, 0, 100, 0),
			durationMs = whole(photo.DURATION_MS, 0, 60000, 2500),
			maxDrift = number(photo.MAX_DRIFT, 0.5, 50, 3.0),
			maxPerHour = whole(photo.MAX_PER_HOUR, 1, 1000, 12),
			crowdRadius = number(photo.CROWD_RADIUS, 0, 200, 25.0),
			uploadUrl = url,
			upload = {
				format = (upload.FORMAT == 'png') and 'png' or 'jpeg',
				quality = whole(upload.QUALITY, 1, 100, 70),
				scale = number(upload.SCALE, 0.05, 1, 0.5),
				timeoutMs = whole(upload.TIMEOUT_MS, 1000, 60000, 20000),
			},
			animation = text(photo.ANIMATION, 64),
		},
		story = {
			minGrade = whole(story.MIN_GRADE, 0, 100, 0),
			headline = span(story.HEADLINE, 1, 120, 8, 80),
			body = span(story.BODY, 1, 480, 60, 480),
			cooldownMs = whole(story.COOLDOWN_MS, 0, 86400000, 300000),
			maxPerHour = whole(story.MAX_PER_HOUR, 1, 1000, 6),
		},
		sales = {
			photo = {
				base = whole(salePhoto.BASE, 0, 1000000, 120),
				crowdBonus = whole(salePhoto.CROWD_BONUS, 0, 1000000, 25),
				crowdMax = whole(salePhoto.CROWD_MAX, 0, 100, 6),
				uploadedMult = number(salePhoto.UPLOADED_MULT, 0, 10, 1.25),
			},
			story = {
				base = whole(saleStory.BASE, 0, 1000000, 150),
				perWord = whole(saleStory.PER_WORD, 0, 100000, 3),
				wordCap = whole(saleStory.WORD_CAP, 0, 10000, 120),
			},
			freshS = fresh,
			staleS = whole(sales.STALE_S, fresh, 31536000, math.max(fresh, 21600)),
			staleMult = number(sales.STALE_MULT, 0, 1, 0.25),
			repeatRadius = number(sales.REPEAT_RADIUS, 0, 1000, 40.0),
			repeatS = whole(sales.REPEAT_S, 0, 604800, 3600),
			repeatMult = number(sales.REPEAT_MULT, 0, 1, 0.3),
			sellerCap = whole(sales.SELLER_CAP_PER_HOUR, 0, 100000000, 4000),
			mintCap = whole(sales.MINT_PER_HOUR, 0, 100000000, 12000),
		},
		tips = {
			min = whole(tips.MIN, 1, 400, 10),
			max = whole(tips.MAX, 1, 400, 240),
			cooldownMs = whole(tips.COOLDOWN_MS, 0, 86400000, 60000),
			keep = whole(tips.KEEP, 0, 100, 20),
			keepS = whole(tips.KEEP_S, 60, 604800, 7200),
		},
		kit = {
			cooldownMs = whole(kit.COOLDOWN_MS, 0, 86400000, 600000),
			cameraGrade = whole(kit.CAMERA_GRADE, 0, 100, 0),
		},
		pass = { showRadius = number(pass.SHOW_RADIUS, 0.5, 20, 3.0) },
		items = {
			pass = itemOf(items.PASS, 'press_pass', 'Press pass', 10),
			camera = itemOf(items.CAMERA, 'press_camera', 'Press camera', 900),
			photo = itemOf(items.PHOTO, 'press_photo', 'Press photo', 5),
			story = itemOf(items.STORY, 'press_story', 'Story draft', 5),
		},
		requestMs = whole(settings.REQUEST_MS, 100, 10000, 800),
		problems = problems,
		placeholders = placeholders,
	}
end

--- The problems alone: what the boot logs.
-- @author dop42
-- @param settings table
-- @return string[]
function Model.Problems(settings)
	return Model.Build(settings).problems
end

--- Every open desk, as the client puts them on the eye -- read straight from
--- the config one newsroom at a time, because the whole `Build` is more than
--- one client resume can afford. `yield` (a `Wait(0)` on the client) runs
-- between two newsrooms.
-- @author dop42
-- @param settings table OPX.Config.MODULES.media
-- @param yield function|nil
-- @return table[] { network, key, label, x, y, z, radius }
function Model.Desks(settings, yield)
	local declared = type(settings) == 'table' and type(settings.NETWORKS) == 'table' and settings.NETWORKS or {}
	local out, names = {}, {}
	for name in pairs(declared) do
		if type(name) == 'string' then names[#names + 1] = name end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		if yield then yield() end
		local network = networkOf(name, declared[name], {}, {})
		for _, desk in ipairs(network and network.desks or {}) do out[#out + 1] = desk end
	end
	return out
end

-- ── what a player typed ─────────────────────────────────────────────────────

--- Cleans one line a player typed and holds it to `{ min, max }` characters.
--- Answers the line, or nil and `too_short` / `too_long`.
-- @author dop42
-- @param value any
-- @param limits table { min, max }
-- @return string|nil
-- @return string|nil
function Model.Line(value, limits)
	if value == nil then value = '' end
	if type(value) ~= 'string' then return nil, 'too_short' end
	-- Cut far past the ceiling first, then clean: a megabyte typed is refused
	-- without being scanned.
	if #value > limits.max * 4 + 8 then return nil, 'too_long' end
	local clean = OPX.Text.Clean(value, limits.max * 4 + 8) or ''
	clean = clean:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
	local length = utf8.len(clean) or #clean
	if length > limits.max then return nil, 'too_long' end
	if length < limits.min then return nil, 'too_short' end
	return clean
end

--- Splits `/breaking <headline> | <text>` typed in one go.
-- @author dop42
-- @param raw string
-- @return string headline
-- @return string text
function Model.SplitBreaking(raw)
	raw = clip(raw)
	local headline, rest = raw:match('^(.-)%s*|%s*(.*)$')
	if headline == nil then return raw, '' end
	return headline, rest
end

--- Words in a text, the way the desk counts them.
-- @author dop42
-- @param value string
-- @return integer
function Model.Words(value)
	local count = 0
	for _ in clip(value):gmatch('%S+') do count = count + 1 end
	return count
end

-- ── grades and newsrooms ────────────────────────────────────────────────────

--- The newsroom a character works for, from their metadata.
-- @author dop42
-- @param built table
-- @param record any the metadata value
-- @return string
function Model.NetworkOf(built, record)
	local name = type(record) == 'table' and record.network or nil
	if type(name) == 'string' and built.networks[name] ~= nil then return name end
	return built.defaultNetwork
end

--- Whether a reporter of this grade may sell to a desk of that newsroom.
-- @author dop42
-- @param built table
-- @param grade integer
-- @param own string the reporter's newsroom
-- @param deskNetwork string
-- @return boolean
function Model.MaySellTo(built, grade, own, deskNetwork)
	if own == deskNetwork then return true end
	return built.freelance[grade] == true
end

-- ── what the desk pays ──────────────────────────────────────────────────────

--- How much of its price a piece keeps at an age, 0..1.
-- @author dop42
-- @param sales table built.sales
-- @param ageS number
-- @return number
function Model.Freshness(sales, ageS)
	ageS = finiteNumber(ageS) or 0
	if ageS <= sales.freshS then return 1 end
	if ageS >= sales.staleS or sales.staleS <= sales.freshS then return sales.staleMult end
	local through = (ageS - sales.freshS) / (sales.staleS - sales.freshS)
	return 1 - through * (1 - sales.staleMult)
end

--- Whether a photo is old news: within REPEAT_RADIUS of one the same desk
--- bought less than REPEAT_S ago.
-- @author dop42
-- @param sales table built.sales
-- @param metadata table the photo's
-- @param bought table[] { x, y, z, at } this desk's recent purchases
-- @param nowS number
-- @return boolean
function Model.Repeat(sales, metadata, bought, nowS)
	local x, y, z = finiteNumber(metadata.x), finiteNumber(metadata.y), finiteNumber(metadata.z)
	if x == nil or y == nil or z == nil then return false end
	local reach = sales.repeatRadius * sales.repeatRadius
	for _, row in ipairs(bought or {}) do
		if nowS - row.at < sales.repeatS then
			local dx, dy, dz = row.x - x, row.y - y, row.z - z
			if dx * dx + dy * dy + dz * dz <= reach then return true end
		end
	end
	return false
end

--- The price of one photo at one desk. Answers eddies (an integer) and whether
--- it was paid as old news.
-- @author dop42
-- @param built table
-- @param desk table
-- @param metadata table
-- @param bought table[] the desk's recent purchases
-- @param nowS number
-- @return integer
-- @return boolean
function Model.PhotoPrice(built, desk, metadata, bought, nowS)
	local sales = built.sales
	local rules = sales.photo
	local crowd = integer(metadata.crowd, 0, 1000) or 0
	local price = rules.base + rules.crowdBonus * math.min(crowd, rules.crowdMax)
	if metadata.uploaded == true then price = price * rules.uploadedMult end
	price = price * Model.Freshness(sales, nowS - (finiteNumber(metadata.at) or nowS))
	local old = Model.Repeat(sales, metadata, bought, nowS)
	if old then price = price * sales.repeatMult end
	return math.max(0, math.floor(price * desk.rate)), old
end

--- The price of one story at one desk, in eddies.
-- @author dop42
-- @param built table
-- @param desk table
-- @param metadata table
-- @param nowS number
-- @return integer
function Model.StoryPrice(built, desk, metadata, nowS)
	local sales = built.sales
	local rules = sales.story
	local words = integer(metadata.words, 0, 100000) or 0
	local price = rules.base + rules.perWord * math.min(words, rules.wordCap)
	price = price * Model.Freshness(sales, nowS - (finiteNumber(metadata.at) or nowS))
	return math.max(0, math.floor(price * desk.rate))
end

--- What is left of an hourly allowance. `rows` is `{ at, amount }`, seconds.
-- @author dop42
-- @param rows table[]
-- @param cap integer
-- @param nowS number
-- @return integer
function Model.Left(rows, cap, nowS)
	local spent = 0
	for _, row in ipairs(rows or {}) do
		if nowS - row.at < 3600 then spent = spent + row.amount end
	end
	return math.max(0, cap - spent)
end

--- Drops the rows of an hourly window that have aged out. Answers the list.
-- @author dop42
-- @param rows table[]
-- @param nowS number
-- @param windowS integer|nil
-- @return table[]
function Model.Prune(rows, nowS, windowS)
	local keep = {}
	for _, row in ipairs(rows or {}) do
		if nowS - row.at < (windowS or 3600) then keep[#keep + 1] = row end
	end
	return keep
end
