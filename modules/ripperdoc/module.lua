--- The ripperdoc clinic: a chair, a tray of chrome, and the two people it takes.
-- @author XEROX710
--
-- WHAT THIS IS FOR. A job a player can hold (the catalogue already names
-- `ripperdoc` -- Apprentice, Ripperdoc, Chrome Surgeon), a chair a patient sits
-- in, and the platform's own cyberware store behind it. The ripperdoc offers;
-- the patient accepts; the platform stages the work and says when it is done.
--
-- THE MONEY RULE IS THE PLATFORM'S, FOLLOWED EXACTLY. The .87 wiki states it
-- for RP payments: "reserve funds before submission, finalize only on
-- successful completion and compensate failure". So the price is taken at
-- ACCEPT, the charge stands only when `onCyberwareOperationCompleted` says
-- `result.ok == true`, and anything else is refunded to the cent. A staged
-- ticket is pending work, never a finished installation -- which is why the
-- ledger keeps its own transaction record beside it.
--
-- TWO WAYS TO SIT, ONE FUNNEL. With a ripperdoc operating the chair they drive:
-- the patient browses and answers offers. With nobody operating it the patient
-- may serve themselves -- same validation, same reserve-and-settle, just nobody
-- to pay. The request asked for both ("players can work as ripperdocs" and
-- "give users the option to equip/unequip cyberware"), and one code path
-- answers both because the difference is only who may make the offer.
--
-- THE COMPLETION ARRIVES AS A SERVER-LOCAL EVENT and names the player the way
-- the host names them (a string). Tickets are matched to OUR transaction and
-- nobody else's, per the wiki's "never consume someone else's ticket".

local M = OPX.Modules.Declare{
	id = 'ripperdoc',
	side = 'both',
	-- The job side hooks onto `jobs` (the operator's pay funnel); a server
	-- without jobs simply has nobody to bank. The clinic itself works
	-- regardless.
	fatal = false,
	optional = { 'jobs' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

M.Event = {
	-- Client to server: the press at the chair, and every intent.
	USE = OPX.Event(NET, 'ripperdoc', 'use'),
	STAND = OPX.Event(NET, 'ripperdoc', 'stand'),
	INVITE = OPX.Event(NET, 'ripperdoc', 'invite'),
	OFFER = OPX.Event(NET, 'ripperdoc', 'offer'),
	ANSWER = OPX.Event(NET, 'ripperdoc', 'answer'),
	CLOSE = OPX.Event(NET, 'ripperdoc', 'close'),

	-- Server to client, one player at a time: the whole truth in one frame.
	FRAME = OPX.Event(NET, 'ripperdoc', 'frame'),

	-- THE PLACEMENT ROUND-TRIP, the same shape `modules/garages` uses. A typed
	-- command has no facing of its own, so the server asks the capturer's client
	-- for one (`CAPTURE` out, `CAPTURED` back). `CHAIRS` carries the captured
	-- chairs to every client, and `ASK` is a client asking for them on start.
	CAPTURE = OPX.Event(NET, 'ripperdoc', 'capture'),
	CAPTURED = OPX.Event(NET, 'ripperdoc', 'captured'),
	CHAIRS = OPX.Event(NET, 'ripperdoc', 'chairs'),
	ASK = OPX.Event(NET, 'ripperdoc', 'ask'),

	-- Client-local: what the state half says the page should draw.
	VIEW = OPX.Event(LOCAL, 'ripperdoc', 'view'),

	-- Server-local: a piece just broke at zero condition, and the durable
	-- implants among those are pulled the way every pull happens.
	ON_BROKEN = OPX.Event(LOCAL, 'ripperdoc', 'broken'),

	-- Server-local: what one patient has fitted just changed (a fit, a pull, a
	-- repair, a break, a load). `server/effects.lua` recomposes the numbers
	-- the chrome is worth on it.
	ON_CHANGED = OPX.Event(LOCAL, 'ripperdoc', 'changed'),

	-- THE DIAGNOSIS ROUND-TRIP. A "not ready" record has causes on BOTH
	-- runtimes -- the binding is the server's, the native projection is the
	-- patient's own client -- so the server asks the client what its
	-- `open77_cyberware` support reports (`PROBE` out, `PROBED` back) and
	-- journals both halves in one line.
	PROBE = OPX.Event(NET, 'ripperdoc', 'probe'),
	PROBED = OPX.Event(NET, 'ripperdoc', 'probed'),

	-- THE RECORDER. `RECORD` switches one client's base-game menu recorder on
	-- or off and asks it for a dump; `RECORDED` is a recorded line coming back
	-- to the server journal, where an operator can read it.
	RECORD = OPX.Event(NET, 'ripperdoc', 'record'),
	RECORDED = OPX.Event(NET, 'ripperdoc', 'recorded'),

	-- THE RECORD READER. The base game's own database names its cyberware; a
	-- dedicated server has no engine to ask, so it hands a batch of TweakDB
	-- record ids to one client (`RESOLVE` out) and that client answers what
	-- its live TweakDB says each one is (`RESOLVED` back): the display name
	-- in the player's own language, the quality, the equipment area.
	RESOLVE = OPX.Event(NET, 'ripperdoc', 'resolve'),
	RESOLVED = OPX.Event(NET, 'ripperdoc', 'resolved'),

	-- A page-local intent: which body system the patient is browsing, or which
	-- piece they opened. Never leaves the client -- the tray is shared data.
	BROWSE = OPX.Event(LOCAL, 'ripperdoc', 'browse'),

	-- THE MOVEMENT KIT ON THE PATIENT'S OWN MACHINE. `KIT` tells one player
	-- which powers the server holds for them, the default key each answers to
	-- and the look it wears -- and, once they are up out of the chair, a
	-- one-use token to have the powers fitted in it projected again
	-- (`REPROJECT` back). `server/sandevistan.lua` says why a power fitted in
	-- the chair has to be.
	KIT = OPX.Event(NET, 'ripperdoc', 'kit'),
	REPROJECT = OPX.Event(NET, 'ripperdoc', 'reproject'),

	-- A Sandevistan's look, to every client: whose, which phase, which look
	-- and how long it has left. `client/sandevistan.lua` draws it on the body.
	SANDY = OPX.Event(NET, 'ripperdoc', 'sandy'),

	-- `/opx.sandy.key`, carried to the caller's own machine: only a client can
	-- read or rebind its own key.
	KEYBIND = OPX.Event(NET, 'ripperdoc', 'keybind'),

	-- What a client did with a Sandevistan phase -- its clock, its screen, the
	-- doors its build has, the body it drew on -- sent back once per boost so
	-- the server's journal holds both halves of every test.
	SANDYREPORT = OPX.Event(NET, 'ripperdoc', 'sandyreport'),
}

--- Names the host owns. Escape is swallowed by the plugin before any surface
--- sees it and arrives as this instead, so it cannot be renamed here.
M.Host = {
	PAUSE_KEY = 'open77:pauseKey',
}

-- The two namespaces the module's own files fill. Created here, beside each
-- other, so no file has to index a table that does not exist yet (the reason
-- `modules/skills/module.lua` gives for owning the namespaces in one place).
M.Ripper = {}
M.RipperView = {}

-- The key, in the same shape as the scanner's and the tree's: the id is stable
-- because a player's rebind is stored under it.
M.Ripper.KEY = { ID = 'opx.ripperdoc.use', NAME = 'ripperdoc.key.use', DEFAULT = 'E' }

-- The name a refusal on the placement routeway carries, so a client can tell
-- one operation's refusal from another's.
M.Operation = { CAPTURE = 'clinicCapture' }

-- What a chair key and a chair label may be. The key is the durable name the
-- commands name a chair by; the label is the operator's own words and is never
-- translated.
M.Ripper.MAX_KEY = 48
M.Ripper.MAX_LABEL = 64

--- The captured chairs as rows. The config rows beside them never move: a
-- capture is a chair an operator placed in game, kept in the database and
-- merged into `M.Ripper.Chairs` so every reader sees both without knowing
-- which is which.
M.Ripper.Captured = {}

-- ONE TABLE, TWO READERS, exactly as `M.Radio.Refusal` and `M.Skill.Refusal`
-- are: the server refuses with a code, a player reads a sentence, and the map
-- between them lives here so the panel and the toast say the same thing in the
-- same words. A code this table has not heard of names itself rather than
-- going blank.
M.Ripper.Refusal = {
	noCharacter = 'ripperdoc.noCharacter',
	noSuchChair = 'ripperdoc.noSuchChair',
	noSuchEntry = 'ripperdoc.noSuchEntry',
	noSuchGrade = 'ripperdoc.noSuchGrade',
	noSuchTarget = 'ripperdoc.noSuchTarget',
	tooFar = 'ripperdoc.tooFar',
	taken = 'ripperdoc.taken',
	seated = 'ripperdoc.seated',
	notRipperdoc = 'ripperdoc.notRipperdoc',
	noPatient = 'ripperdoc.noPatient',
	busy = 'ripperdoc.busy',
	slotFilled = 'ripperdoc.slotFilled',
	slotEmpty = 'ripperdoc.slotEmpty',
	noOffer = 'ripperdoc.noOffer',
	noInvite = 'ripperdoc.noInvite',
	cannotPay = 'ripperdoc.cannotPay',
	notReady = 'ripperdoc.notReady',
	hostRefused = 'ripperdoc.hostRefused',
	noHost = 'ripperdoc.noHost',
	healthy = 'ripperdoc.healthy',
	alreadyFitted = 'ripperdoc.alreadyFitted',
	systemFull = 'ripperdoc.systemFull',
	powerTaken = 'ripperdoc.powerTaken',
	overCapacity = 'ripperdoc.overCapacity',
	bodyNotReady = 'ripperdoc.bodyNotReady',
	seatedElsewhere = 'ripperdoc.seatedElsewhere',
	changed = 'ripperdoc.changed',
	serviceDown = 'ripperdoc.serviceDown',
	notSold = 'ripperdoc.notSold',
}

--- THE PLATFORM RESOURCES A PIECE NEEDS RUNNING to be more than a ledger row:
--- the native projection of arms, legs and the ground slam lives in
--- `open77_cyberware`, the dash in `open77_dash`, the overdrive in
--- `open77_reflex`, and quickhacks and Self-ICE in `open77_hacking`. A server
--- whose `resources.load` leaves one out still accepts the definitions and the
--- grants -- and nothing ever reaches the player's body. Config SERVICES
--- overrides a name.
M.Ripper.SERVICES = {
	implant = 'open77_cyberware', dash = 'open77_dash', reflex = 'open77_reflex',
	ability = 'open77_cyberware', hacking = 'open77_hacking', ice = 'open77_hacking',
}

--- The platform resources one piece needs running, in the order to name them.
-- @param entry table
-- @return table array of resource names
function M.Ripper.ServicesFor(entry)
	local names = type(M.Settings.SERVICES) == 'table' and M.Settings.SERVICES or {}
	local function name(kind)
		local value = names[kind]
		if value == false then return nil end
		return type(value) == 'string' and value ~= '' and value or M.Ripper.SERVICES[kind]
	end
	local out = {}
	local kind = M.Ripper.KindOf(entry)
	local grant = M.Ripper.GrantKind(entry)
	if kind == 'implant' or kind == 'ice' then out[#out + 1] = name('implant') end
	if kind == 'ice' then out[#out + 1] = name('ice') end
	if grant ~= nil then out[#out + 1] = name(grant) end
	local seen, unique = {}, {}
	for _, service in ipairs(out) do
		if service ~= nil and not seen[service] then
			seen[service] = true
			unique[#unique + 1] = service
		end
	end
	return unique
end

-- The config readers. Resolved when read and never captured (the README's own
-- rule for `M.Settings`), so a reloaded config is the next answer rather than
-- the first one for ever.

-- ── the tray ──────────────────────────────────────────────────────────────
--
-- ONE LIST, TWO SOURCES. The operator's hand-tuned CATALOG entries come first
-- and win on an id; the base game's pieces (`shared/cyberware.lua`) follow,
-- priced by the operator's VANILLA policy. Every entry leaves here in ONE
-- normalised shape -- a system, a kind, a tier, a capacity and a price on
-- every grade -- so no reader has to know which source an entry came from.
-- Built once and cached against the config tables it was built from: the
-- page, the offer rules and the wear ticks all read it, many times a second.

--- The platform's durable implant slots (wiki/cyberware.md: arms, legs,
--- operating_system, self_ice, purge). A config entry in one of these is an
--- implant unless it says otherwise.
M.Ripper.PLATFORM_SLOTS = {
	arms = true, legs = true, operating_system = true, self_ice = true, purge = true,
}

-- The stand-ins for an absent block. ONE table each, for the life of the VM:
-- the tray is cached against the identity of the tables it was built from,
-- and a fresh `{}` per read would be a cache that never holds.
local NO_POLICY = {}
local NO_POLICY_OFF = { enabled = false }
local NO_CATALOG = {}

--- The operator's policy for the base-game pieces. Never nil. `VANILLA =
--- false` is the whole base game switched off.
-- @return table
function M.Ripper.VanillaPolicy()
	local policy = M.Settings.VANILLA
	if type(policy) == 'table' then return policy end
	if policy == false then return NO_POLICY_OFF end
	return NO_POLICY
end

--- Whether a piece is OFF the shelf: chrome with no multiplayer adapter on
--- this build (`rp`) is not sold unless the operator says so (`VANILLA.SELL_RP`),
--- because a patient who pays for a Mantis Blade expects a blade on the arm and
--- the platform has no way to put one there. It stays in the tray for the
--- patients who already wear one -- they can still have it pulled or mended --
--- and comes back on sale the day its kind gains an adapter.
-- @param entry table
-- @param policy table|nil the VANILLA policy
-- @return boolean
function M.Ripper.Unsold(entry, policy)
	if type(entry) ~= 'table' or entry.KIND ~= 'rp' then return false end
	policy = type(policy) == 'table' and policy or {}
	return policy.SELL_RP ~= true
end

--- The native reasons a patient's own client can give for a failed fitting,
--- each with its own sentence (`ripperdoc.native.<reason>`). Anything else
--- reads the generic sentence with the reason quoted.
M.Ripper.NATIVE_REASONS = {
	native_leg_slot_owned = true, native_leg_capability_owned = true,
	native_equip_failed = true, native_equipment_timeout = true,
	native_leg_grant_lost = true, body_not_ready = true, player_unavailable = true,
	body_changed = true, cyberware_equipment_owned = true, queue_full = true,
	unsupported_profile = true, gorilla_arms_not_drawn = true, api_unavailable = true,
	stale_projection = true,
}

--- What a patient's client said about a failed native fitting, reduced to one
--- reason token: the legs projector for a legs piece, the arms projector for
--- everything else, then whatever error the probe itself hit.
-- @param answer table|nil the probe's report
-- @param entry table|nil
-- @return string|nil
function M.Ripper.NativeReason(answer, entry)
	if type(answer) ~= 'table' then return nil end
	local function token(value)
		value = type(value) == 'string' and value or nil
		if value == nil or value == '' or #value > 48 or value:find('[^%w_]') then return nil end
		return value
	end
	local order = (type(entry) == 'table' and entry.SLOT == 'legs')
		and { answer.legs, answer.local_ } or { answer.local_, answer.legs }
	for _, part in ipairs(order) do
		if type(part) == 'table' and part.phase ~= 'ready' then
			local reason = token(part.reason)
			if reason ~= nil and reason ~= 'not_projected' then return reason end
		end
	end
	return token(answer.error)
end

--- The sentence one native reason reads as.
-- @param reason string
-- @return string locale key
function M.Ripper.NativeWhyKey(reason)
	if M.Ripper.NATIVE_REASONS[reason] then return 'ripperdoc.native.' .. reason end
	return 'ripperdoc.native.other'
end

--- Whether a piece may be bought or upgraded at the chair.
-- @param entry table|nil
-- @return boolean
function M.Ripper.Sold(entry)
	return type(entry) == 'table' and entry.HIDDEN ~= true
end

--- The operator's own pieces. Never nil.
-- @return table
local function configCatalog()
	return type(M.Settings.CATALOG) == 'table' and M.Settings.CATALOG or NO_CATALOG
end

--- A price rounded the way a shop prints one: to the nearest 5.
-- @param value number
-- @return integer
local function roundPrice(value)
	return math.max(0, math.floor((tonumber(value) or 0) / 5 + 0.5) * 5)
end

--- The kind a config entry is, when it names none. A grant is a grant, a piece
--- in a platform slot is an implant, a piece carrying stat effects is a stat
--- piece, and anything else is chrome with no mechanical effect.
-- @param entry table
-- @return string
local function kindOf(entry)
	if type(entry.KIND) == 'string' and entry.KIND ~= '' then return entry.KIND end
	local legacy = M.Cyber ~= nil and M.Cyber.LEGACY[entry.id] or nil
	if legacy ~= nil and legacy.KIND ~= nil then return legacy.KIND end
	local power = type(entry.POWER) == 'table' and entry.POWER.GRANT or nil
	if power == 'dash' or power == 'reflex' or power == 'ability' then return 'grant' end
	if entry.SLOT == 'self_ice' then return 'ice' end
	if M.Ripper.PLATFORM_SLOTS[entry.SLOT] then return 'implant' end
	for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
		if type(grade.EFFECTS) == 'table' and next(grade.EFFECTS) ~= nil then return 'stat' end
	end
	return 'rp'
end

--- One config entry, normalised into the catalogue's shape without touching
--- the config table itself (a reload must find the file's own values).
-- @param entry table
-- @return table|nil
local function normalizeConfig(entry)
	if type(entry) ~= 'table' or type(entry.id) ~= 'string' or entry.id == '' then return nil end
	local legacy = M.Cyber ~= nil and M.Cyber.LEGACY[entry.id] or {}
	local out = {}
	for key, value in pairs(entry) do out[key] = value end
	out.KIND = kindOf(entry)
	out.HIDDEN = M.Ripper.Unsold(out, M.Ripper.VanillaPolicy()) or nil
	out.SYSTEM = type(entry.SYSTEM) == 'string' and entry.SYSTEM
		or legacy.SYSTEM or entry.SLOT or 'frontal_cortex'
	out.DESC = type(entry.DESC) == 'string' and entry.DESC or ('ripperdoc.cw.' .. entry.id .. '.desc')
	out.TIER = math.max(1, math.min(5, math.floor(tonumber(entry.TIER) or legacy.TIER or 1)))
	local capacity = tonumber(entry.CAPACITY) or legacy.CAPACITY or 0
	out.GRADES = {}
	for index, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
		if type(grade) == 'table' and type(grade.id) == 'string' then
			local copy = {}
			for key, value in pairs(grade) do copy[key] = value end
			copy.TIER = math.max(1, math.min(5,
				math.floor(tonumber(grade.TIER) or (out.TIER + index - 1))))
			copy.CAPACITY = math.max(0, math.floor(tonumber(grade.CAPACITY)
				or (capacity * (1 + 0.2 * (copy.TIER - out.TIER))) + 0.5))
			copy.PRICE = math.max(0, tonumber(grade.PRICE) or 0)
			if type(copy.RECORD) ~= 'string' and M.Cyber ~= nil then
				copy.RECORD = M.Cyber.RecordFor(entry.id, copy.TIER, index)
			end
			out.GRADES[#out.GRADES + 1] = copy
		end
	end
	out.REMOVE = math.max(0, tonumber(entry.REMOVE) or 0)
	return out
end

--- The base-game pieces, priced by the operator's policy and filtered by it.
-- @param taken table ids the config already declares
-- @param yieldEvery integer|nil rows per resume; nil builds in one go
-- @return table
local function vanillaEntries(taken, yieldEvery)
	local policy = M.Ripper.VanillaPolicy()
	if policy.enabled == false or M.Cyber == nil then return {} end
	local byTier = type(policy.PRICE_BY_TIER) == 'table' and policy.PRICE_BY_TIER
		or { 120, 350, 800, 1600, 3000 }
	local iconic = tonumber(policy.ICONIC_MULTIPLIER) or 1.6
	local rp = tonumber(policy.RP_MULTIPLIER) or 0.6
	local removeFraction = tonumber(policy.REMOVE_FRACTION) or 0.1
	local removeMin = tonumber(policy.REMOVE_MIN) or 25
	local excluded = {}
	for _, id in ipairs(type(policy.EXCLUDE) == 'table' and policy.EXCLUDE or {}) do
		excluded[id] = true
	end
	local out = {}
	for index = 1, M.Cyber.Count() do
		if yieldEvery ~= nil and index % yieldEvery == 0 then Wait(0) end
		local entry = M.Cyber.Entry(index)
		if entry ~= nil and not taken[entry.id] and not excluded[entry.id] then
			entry.HIDDEN = M.Ripper.Unsold(entry, policy) or nil
			local factor = (entry.ICONIC and iconic or 1) * (entry.KIND == 'rp' and rp or 1)
			for _, grade in ipairs(entry.GRADES) do
				grade.PRICE = roundPrice((tonumber(byTier[grade.TIER]) or 0) * factor)
			end
			entry.REMOVE = math.max(removeMin,
				roundPrice((tonumber(byTier[entry.TIER]) or 0) * removeFraction))
			out[#out + 1] = entry
		end
	end
	return out
end

--- THE SANDEVISTAN'S COOLDOWN (config `SANDEVISTAN.COOLDOWN_MS`): one number
--- for every Sandevistan the tray sells, or nil when each grade keeps its own.
--- Clamped to 1-120 s, the platform's own range for a power's cooldown.
-- @return number|nil ms
function M.Ripper.SandyCooldown()
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or nil
	if sandy == nil then return nil end
	local ms = OPX.Math.Finite(sandy.COOLDOWN_MS)
	if ms == nil or ms <= 0 then return nil end
	return math.floor(math.max(1000, math.min(120000, ms)))
end

--- Puts every grade of one Sandevistan on the tray's cooldown: `cooldownMs`
--- and `chargeRegenMs` become it, and a boost never outlasts it (the platform
--- refuses a duration past the cooldown). Each grade's VALUE is COPIED: the
--- config's own table is never written (a reload must find the file's values).
-- @param entry table
-- @param cooldown number|nil
local function onSandyCooldown(entry, cooldown)
	if cooldown == nil or M.Ripper.GrantKind(entry) ~= 'reflex' then return end
	for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
		if type(grade) == 'table' and type(grade.VALUE) == 'table' then
			local value = {}
			for key, field in pairs(grade.VALUE) do value[key] = field end
			value.cooldownMs = cooldown
			value.chargeRegenMs = cooldown
			local duration = tonumber(value.durationMs)
			if duration ~= nil and duration > cooldown then value.durationMs = cooldown end
			grade.VALUE = value
		end
	end
end

local cache = { config = nil, policy = nil, cooldown = nil, list = nil, byId = nil }

--- Builds the whole tray and caches it.
-- @param yieldEvery integer|nil rows per resume; nil builds in one go
-- @return table
local function buildCatalog(yieldEvery)
	local config = configCatalog()
	local policy = M.Ripper.VanillaPolicy()
	local cooldown = M.Ripper.SandyCooldown()
	local list, byId, taken = {}, {}, {}
	for _, raw in ipairs(config) do
		local entry = normalizeConfig(raw)
		if entry ~= nil and byId[entry.id] == nil then
			onSandyCooldown(entry, cooldown)
			list[#list + 1] = entry
			byId[entry.id] = entry
			taken[entry.id] = true
		end
	end
	for index, entry in ipairs(vanillaEntries(taken, yieldEvery)) do
		onSandyCooldown(entry, cooldown)
		list[#list + 1] = entry
		byId[entry.id] = entry
		-- Sliced like the build above it: a hundred-odd pieces through
		-- `onSandyCooldown` in the thread's last resume was the dearest resume of
		-- the whole client boot (~5,600 instructions, `tests/run.lua`).
		if yieldEvery ~= nil and index % (yieldEvery * 8) == 0 then Wait(0) end
	end
	cache.config, cache.policy, cache.cooldown, cache.list, cache.byId = config, policy, cooldown, list, byId
	return list
end

--- Whether the cached tray is the one the current config would build.
-- @return boolean
function M.Ripper.CatalogReady()
	return cache.list ~= nil and cache.config == configCatalog()
		and cache.policy == M.Ripper.VanillaPolicy()
		and cache.cooldown == M.Ripper.SandyCooldown()
end

--- The whole tray: the config's pieces, then the base game's.
-- @return table array of normalised entries, never nil
function M.Ripper.Catalog()
	if M.Ripper.CatalogReady() then return cache.list end
	return buildCatalog(nil)
end

--- Builds the tray a few rows per resume, for a runtime with a per-resume
--- instruction budget: a hundred-odd pieces at five tiers each is several
--- hook intervals of arithmetic, and the client's first page must not be
--- the resume that dies doing it. YIELDS -- call from a thread.
-- @param yieldEvery integer rows per resume
function M.Ripper.WarmCatalog(yieldEvery)
	if M.Ripper.CatalogReady() then return end
	buildCatalog(math.max(1, math.floor(tonumber(yieldEvery) or 4)))
end

--- Forgets the built tray, so the next read builds it again (tests that edit
--- the config in place, and a reload).
function M.Ripper.ResetCatalog()
	cache.config, cache.policy, cache.cooldown, cache.list, cache.byId = nil, nil, nil, nil, nil
end

--- The kind of an entry: `implant`, `ice`, `grant`, `stat` or `rp`.
-- @param entry table|nil
-- @return string|nil
function M.Ripper.KindOf(entry)
	return type(entry) == 'table' and entry.KIND or nil
end

--- Whether the platform's durable record holds this piece (an implant or the
--- Self-ICE). Everything else is held in OUR ledger.
-- @param entry table|nil
-- @return boolean
function M.Ripper.IsPlatform(entry)
	local kind = M.Ripper.KindOf(entry)
	return kind == 'implant' or kind == 'ice'
end

--- Whether the clinic's own ledger is what says this piece is fitted: the
--- movement grants, the stat pieces and the roleplay chrome.
-- @param entry table|nil
-- @return boolean
function M.Ripper.IsLedger(entry)
	return type(entry) == 'table' and not M.Ripper.IsPlatform(entry)
end

-- ── the body and its capacity ─────────────────────────────────────────────

--- Every body system with its slot count, the base game's with the
--- operator's overrides applied. Never nil.
-- @return table array of { id, SLOTS }
function M.Ripper.Systems()
	local overrides = type(M.Settings.SYSTEMS) == 'table' and M.Settings.SYSTEMS or {}
	local out = {}
	for _, system in ipairs(M.Cyber ~= nil and M.Cyber.SYSTEMS or {}) do
		local slots = tonumber(overrides[system.id])
		out[#out + 1] = {
			id = system.id,
			SLOTS = slots ~= nil and math.max(0, math.floor(slots)) or system.SLOTS,
		}
	end
	return out
end

--- How many pieces one system takes.
-- @param systemId string
-- @return integer
function M.Ripper.SlotsOf(systemId)
	for _, system in ipairs(M.Ripper.Systems()) do
		if system.id == systemId then return system.SLOTS end
	end
	return 1
end

--- The capacity every body starts with, before any compressor.
-- @return integer
function M.Ripper.CapacityBase()
	local capacity = type(M.Settings.CAPACITY) == 'table' and M.Settings.CAPACITY or {}
	local base = OPX.Math.Finite(capacity.BASE)
	if base == nil then return 100 end
	return math.max(0, math.floor(base))
end

--- Whether the capacity rule is on at all.
-- @return boolean
function M.Ripper.CapacityEnforced()
	local capacity = type(M.Settings.CAPACITY) == 'table' and M.Settings.CAPACITY or {}
	return capacity.enabled ~= false
end

--- What a trade-in is worth: the fraction of the fitted grade's price an
--- upgrade credits against the new one.
-- @return number 0..1
function M.Ripper.TradeIn()
	local upgrade = type(M.Settings.UPGRADE) == 'table' and M.Settings.UPGRADE or {}
	local value = OPX.Math.Finite(upgrade.TRADE_IN)
	if value == nil then return 0.5 end
	return math.max(0, math.min(1, value))
end

--- Every chair in the world: the config rows and the captured ones, with a
-- captured chair SHADOWING a config row of the same id (a capture is one chair
-- moved, not two).
-- @return table the merged CHAIRS array, never nil
function M.Ripper.Chairs()
	local config = type(M.Settings.CHAIRS) == 'table' and M.Settings.CHAIRS or {}
	if #M.Ripper.Captured == 0 then return config end
	local taken, merged = {}, {}
	for _, chair in ipairs(M.Ripper.Captured) do taken[chair.id] = true end
	for _, chair in ipairs(config) do
		if not taken[chair.id] then merged[#merged + 1] = chair end
	end
	for _, chair in ipairs(M.Ripper.Captured) do merged[#merged + 1] = chair end
	return merged
end

--- One chair row by id, a captured one before a config one.
-- @param id string
-- @return table|nil
function M.Ripper.Chair(id)
	for _, chair in ipairs(M.Ripper.Captured) do
		if chair.id == id then return chair end
	end
	local config = type(M.Settings.CHAIRS) == 'table' and M.Settings.CHAIRS or {}
	for _, chair in ipairs(config) do
		if chair.id == id then return chair end
	end
	return nil
end

--- One chair row, checked and in the shape every reader already uses -- the
-- shape `config/ripperdoc.lua` CHAIRS declares. Anything that cannot be a
-- chair in the world answers nil and why, named once here so the command, the
-- capture routeway and a row read back out of the database are all refused by
-- one rule.
-- @param key string the durable name
-- @param label string|nil the operator's words; the key when empty
-- @param x any
-- @param y any
-- @param z any
-- @param yaw any
-- @param extra table|nil the seat: { SEAT = {FORWARD, RIGHT, UP, YAW}, FX, FY,
-- BUCKET, VANILLA = {CLASS, NAME, ENGINE} } -- every field optional and checked
-- @return table|nil, string|nil
--- A map coordinate: finite and on the map, or nil.
-- @param value any
-- @return number|nil
local function coordinate(value)
	local number = OPX.Math.Finite(value)
	if number == nil or math.abs(number) > 20000 then return nil end
	return number
end

--- A finite number no larger than a limit either way, or nil.
-- @param value any
-- @param limit number
-- @return number|nil
local function within(value, limit)
	local number = OPX.Math.Finite(value)
	if number == nil or math.abs(number) > limit then return nil end
	return number
end

--- A word out of a capture: no control characters, 96 bytes at most.
-- @param value any
-- @return string
local function word(value)
	value = type(value) == 'string' and value:gsub('[%c]', '') or ''
	return value:sub(1, 96)
end

function M.Ripper.Row(key, label, x, y, z, yaw, extra)
	if type(key) ~= 'string' or not key:match('^[%w_%-%.]+$') or #key > M.Ripper.MAX_KEY then
		return nil, ('a chair key is 1 to %d letters, digits, dots, dashes or underscores')
			:format(M.Ripper.MAX_KEY)
	end
	label = type(label) == 'string' and label or ''
	label = OPX.String.Trim((label:gsub('%c', ' ')))
	if label == '' then label = key end
	if #label > M.Ripper.MAX_LABEL then label = label:sub(1, M.Ripper.MAX_LABEL) end

	local X, Y, Z = coordinate(x), coordinate(y), coordinate(z)
	if X == nil or Y == nil or Z == nil then
		return nil, 'the position must be three finite numbers on the map'
	end
	local heading = OPX.Math.Finite(yaw) or 0.0
	local row = { id = key, NAME = label, X = X, Y = Y, Z = Z, YAW = heading % 360.0 }
	if type(extra) == 'table' then
		local seat = type(extra.SEAT) == 'table' and extra.SEAT or {}
		-- A seat offset is a nudge inside the chair, never a second place: two
		-- metres is more than any chair, and anything past it is refused to 0.
		row.SEAT = {
			FORWARD = within(seat.FORWARD, 2) or 0,
			RIGHT = within(seat.RIGHT, 2) or 0,
			UP = within(seat.UP, 2) or 0,
			YAW = (within(seat.YAW, 360) or 0) % 360.0,
		}
		local fx, fy = within(extra.FX, 1.001), within(extra.FY, 1.001)
		if fx ~= nil and fy ~= nil and (fx * fx + fy * fy) > 0.25 then
			local length = math.sqrt(fx * fx + fy * fy)
			row.FX, row.FY = fx / length, fy / length
		end
		row.BUCKET = math.floor(within(extra.BUCKET, 2147483647) or 0)
		if type(extra.VANILLA) == 'table' then
			local vanilla = { CLASS = word(extra.VANILLA.CLASS), NAME = word(extra.VANILLA.NAME),
				ENGINE = word(extra.VANILLA.ENGINE) }
			if vanilla.CLASS ~= '' or vanilla.NAME ~= '' or vanilla.ENGINE ~= '' then
				row.VANILLA = vanilla
				-- A chair the base game already placed needs no second chair.
				row.PROP = false
			end
		end
		if extra.PROP == false then row.PROP = false end
	end
	return row
end

--- The pose the patient takes in a chair: the chair's own point and facing,
--- nudged by its seat offsets along the chair's own axes. The axes are the
--- engine's when the capture read them (`FX`, `FY`, the chair's forward), and
--- otherwise follow from the yaw the way REDengine turns one: yaw 0 faces +y,
--- and a positive yaw turns toward -x.
-- @param chair table a chair row
-- @return table { x, y, z, yaw }
function M.Ripper.Anchor(chair)
	local yaw = tonumber(chair.YAW) or 0
	local fx, fy = tonumber(chair.FX), tonumber(chair.FY)
	if fx == nil or fy == nil then
		local radians = math.rad(yaw)
		fx, fy = -math.sin(radians), math.cos(radians)
	end
	-- Right of a forward (fx, fy) on a z-up plane.
	local rx, ry = fy, -fx
	local seat = type(chair.SEAT) == 'table' and chair.SEAT or {}
	local forward, right, up = tonumber(seat.FORWARD) or 0, tonumber(seat.RIGHT) or 0,
		tonumber(seat.UP) or 0
	return {
		x = (tonumber(chair.X) or 0) + fx * forward + rx * right,
		y = (tonumber(chair.Y) or 0) + fy * forward + ry * right,
		z = (tonumber(chair.Z) or 0) + up,
		yaw = (yaw + (tonumber(seat.YAW) or 0)) % 360.0,
	}
end

--- Replaces the captured list with what is checked, sorted so two runs draw
-- the same chairs in the same order.
-- @param rows table array of rows in the `M.Ripper.Row` shape
-- @param yieldEvery integer|nil rows per resume; YIELDS when given
-- @return integer how many were accepted
function M.Ripper.SetCaptured(rows, yieldEvery)
	local accepted = M.Ripper.CheckCaptured(rows, yieldEvery)
	M.Ripper.Captured = accepted
	return #accepted
end

--- The captured rows that pass `Row`, one per id, sorted -- without keeping
--- them anywhere.
-- @param rows table
-- @param yieldEvery integer|nil rows per resume; YIELDS when given
-- @return table
function M.Ripper.CheckCaptured(rows, yieldEvery)
	local accepted, seen = {}, {}
	for index, row in ipairs(type(rows) == 'table' and rows or {}) do
		-- On the client a list of chairs is several hundred instructions a
		-- row, and the caller that can afford to wait says so.
		if yieldEvery ~= nil and index % yieldEvery == 0 then Wait(0) end
		local chair = M.Ripper.Row(type(row) == 'table' and row.id or nil,
			type(row) == 'table' and row.NAME or nil,
			type(row) == 'table' and row.X or nil,
			type(row) == 'table' and row.Y or nil,
			type(row) == 'table' and row.Z or nil,
			type(row) == 'table' and row.YAW or nil,
			type(row) == 'table' and row or nil)
		if chair ~= nil and not seen[chair.id] then
			seen[chair.id] = true
			accepted[#accepted + 1] = chair
		end
	end
	table.sort(accepted, function(a, b) return a.id < b.id end)
	return accepted
end

--- One tray entry by its short id.
-- @param id string
-- @return table|nil
function M.Ripper.Entry(id)
	M.Ripper.Catalog()
	return cache.byId ~= nil and cache.byId[id] or nil
end

--- One grade of an entry.
-- @param entry table
-- @param gradeId string
-- @return table|nil
function M.Ripper.Grade(entry, gradeId)
	for _, grade in ipairs(type(entry) == 'table' and entry.GRADES or {}) do
		if grade.id == gradeId then return grade end
	end
	return nil
end

--- What the clinic charges in.
-- @return string a money type of `OPX.Config.SHARED.MONEY.TYPES`
function M.Ripper.Money()
	return type(M.Settings.MONEY) == 'string' and M.Settings.MONEY or 'EDDIES'
end

--- Metres between the patient and the chair for the press to mean anything.
-- @return number
function M.Ripper.Reach()
	return type(M.Settings.REACH) == 'number' and M.Settings.REACH or 2.5
end

--- Jobs bank points a finished installation pays the operator.
-- @return number
function M.Ripper.Points()
	return type(M.Settings.POINTS) == 'number' and M.Settings.POINTS or 5
end

--- The marker look, in the engine's own vocabulary.
-- @return table
function M.Ripper.Marker()
	return type(M.Settings.MARKER) == 'table' and M.Settings.MARKER
		or { shape = 'cylinder', style = 'interaction', RADIUS = 1.2, LIFT = 0.06 }
end

--- Metres a marker draws from at all.
-- @return number
function M.Ripper.MaxDistance()
	return type(M.Settings.MAX_DISTANCE) == 'number' and M.Settings.MAX_DISTANCE or 150.0
end

--- The visible chair prop policy -- what is spawned under the pose so the
-- patient has a chair to look at. Never nil: a host without a prop API is
-- answered here once and the seats work as the invisible workspots they were.
-- @return table
function M.Ripper.ChairProp()
	return type(M.Settings.CHAIR_PROP) == 'table' and M.Settings.CHAIR_PROP or {}
end

--- The durability policy.
-- @return table
function M.Ripper.Durability()
	return type(M.Settings.DURABILITY) == 'table' and M.Settings.DURABILITY or {}
end

--- The one normalizer: the host names players as strings on the cyberware
-- wire and as numbers in this runtime's handlers; one key for both so a
-- ledger, a grant and a ticket all name the same player.
-- @param player number|string
-- @return number|string
function M.Ripper.KeyOf(player)
	return tonumber(player) or tostring(player)
end

--- The piece a host wear event wears down, and the weight one use of it carries
--- (`M.Ripper.WearWeight`: a use costs `USE_MINUTES` of life times this).
-- @param eventName string a key of `DURABILITY.WEAR_BY`
-- @return table|nil the entry
-- @return number weight
function M.Ripper.WearEntry(eventName)
	local durability = M.Ripper.Durability()
	if durability.enabled == false then return nil, 0 end
	local id = type(durability.WEAR_BY) == 'table' and durability.WEAR_BY[eventName] or nil
	if type(id) ~= 'string' then return nil, 0 end
	local entry = M.Ripper.Entry(id)
	if entry == nil then return nil, 0 end
	return entry, M.Ripper.WearWeight(entry)
end

--- The pricing of a repair appointment.
-- @return number eddies per durability point missing
function M.Ripper.PricePerPoint()
	local per = tonumber(M.Ripper.Durability().PRICE_PER_POINT)
	return per and per >= 0 and per or 0
end

-- ── the lifecycle ─────────────────────────────────────────────────────────
--
-- CHROME IS NOT FOREVER, AND IT AGES IN REAL DAYS. Every fitted piece carries
-- one condition number (100 fresh, 0 broken) and a LIFE: `LIFESPAN_DAYS` of
-- calendar time from its fitting (or its last repair) to broken, running
-- whether its owner is online or not. What the body does to it on top -- the
-- use its own power sees (a punch, a jump, an overdrive), the damage the body
-- under it takes, a death -- takes extra life off, counted in MINUTES of its
-- life and never more than `WEAR_DAYS` of it: a piece worked hard every day
-- still breaks no sooner than `LIFESPAN_DAYS - WEAR_DAYS` days in. The
-- character's level (the skill tree) stretches the whole life, `LEVEL_LIFESPAN`
-- times as long at the level cap. The number has four bands the player can
-- read -- OPTIMAL, WORN, FAILING, BROKEN -- and the last two cost them: a
-- failing piece gives only part of what it is worth, a broken one gives
-- nothing (and a broken implant is pulled), until a ripperdoc repairs it.

--- Seconds in a real day.
M.Ripper.DAY_SECONDS = 86400

--- One number from the durability block, finite and inside its bounds.
-- @param key string
-- @param default number
-- @param lo number
-- @param hi number
-- @return number
local function lifecycleNumber(key, default, lo, hi)
	local value = OPX.Math.Finite(M.Ripper.Durability()[key])
	if value == nil then return default end
	return math.max(lo, math.min(hi, value))
end

--- The lifecycle's numbers, read and bounded once per call.
-- @return table
function M.Ripper.Lifecycle()
	return {
		-- Real days from fresh to broken by the calendar alone, online or not;
		-- 0 switches durability off (nothing wears at all).
		LIFESPAN_DAYS = lifecycleNumber('LIFESPAN_DAYS', 6, 0, 3650),
		-- The most extra life use, damage and deaths may take off one life.
		WEAR_DAYS = lifecycleNumber('WEAR_DAYS', 1, 0, 3650),
		-- Minutes of life one use costs (times the piece's WEAR weight), 100
		-- damage costs a plating piece, and a death costs every piece.
		USE_MINUTES = lifecycleNumber('USE_MINUTES', 0.5, 0, 1440),
		DAMAGE_MINUTES = lifecycleNumber('DAMAGE_MINUTES', 4, 0, 1440),
		DEATH_MINUTES = lifecycleNumber('DEATH_MINUTES', 60, 0, 14400),
		-- An iconic piece's whole life is this many times as long.
		ICONIC_LIFESPAN = lifecycleNumber('ICONIC_LIFESPAN', 1, 0.1, 100),
		-- How many times as long the whole life is at the level cap.
		LEVEL_LIFESPAN = lifecycleNumber('LEVEL_LIFESPAN', 1.5, 1, 100),
		TICK_SECONDS = lifecycleNumber('TICK_SECONDS', 60, 5, 3600),
		WORN_AT = lifecycleNumber('WORN_AT', 60, 0, 100),
		FAILING_AT = lifecycleNumber('FAILING_AT', 25, 0, 100),
		FAILING_EFFECT = lifecycleNumber('FAILING_EFFECT', 0.5, 0, 1),
		-- A full repair costs this fraction of the grade's price, pro rata.
		REPAIR_FRACTION = lifecycleNumber('REPAIR_FRACTION', 0.35, 0, 10),
		REPAIR_MIN = lifecycleNumber('REPAIR_MIN', 10, 0, 1000000),
	}
end

--- How far up the skill tree a character is, 0 at level 1 and 1 at the cap:
--- `(level - 1) / (cap - 1)`, clamped. No cap (or a cap of 1) is 0.
-- @param level number|nil
-- @param cap number|nil
-- @return number 0..1
function M.Ripper.LevelFraction(level, cap)
	level, cap = OPX.Math.Finite(level), OPX.Math.Finite(cap)
	if level == nil or cap == nil or cap <= 1 then return 0 end
	return math.max(0, math.min(1, (level - 1) / (cap - 1)))
end

--- How many times as long a life is at this level: 1 at level 1,
--- `LEVEL_LIFESPAN` at the cap, linear between.
-- @param level number|nil
-- @param cap number|nil
-- @param life table|nil `M.Ripper.Lifecycle()`, read when absent
-- @return number
function M.Ripper.LevelFactor(level, cap, life)
	life = life or M.Ripper.Lifecycle()
	return 1 + (life.LEVEL_LIFESPAN - 1) * M.Ripper.LevelFraction(level, cap)
end

--- One character's level and the level cap, as the skill tree says
--- (`OPX.Api.Get('skills').Level(citizenId)` -> `level, cap`). A server with no
--- tree -- or a tree that cannot say -- answers level 1, which is no bonus.
-- @param citizenId string|nil
-- @return number level
-- @return number cap
function M.Ripper.LevelOf(citizenId)
	if type(citizenId) ~= 'string' or citizenId == '' then return 1, 1 end
	local skills = OPX.Api.Get('skills')
	local reader = type(skills) == 'table' and skills.Level or nil
	if type(reader) ~= 'function' then return 1, 1 end
	local ran, level, cap = pcall(reader, citizenId)
	if not ran then return 1, 1 end
	-- A record (or a Result carrying one) is read as well as the pair.
	if type(level) == 'table' then
		local record = type(level.value) == 'table' and level.value or level
		level, cap = record.level, record.cap or cap
	end
	level, cap = OPX.Math.Finite(level), OPX.Math.Finite(cap)
	if level == nil then return 1, 1 end
	return math.max(1, level), math.max(1, cap or 1)
end

--- Real seconds one piece lasts from fresh to broken by the calendar alone,
--- for a character at this level: the lifespan, stretched by the level and --
--- for an iconic piece -- by `ICONIC_LIFESPAN`. 0 when durability is off.
-- @param entry table|nil
-- @param level number|nil
-- @param cap number|nil
-- @param life table|nil `M.Ripper.Lifecycle()`, read when absent
-- @return number seconds
function M.Ripper.LifeSeconds(entry, level, cap, life)
	life = life or M.Ripper.Lifecycle()
	if M.Ripper.Durability().enabled == false or life.LIFESPAN_DAYS <= 0 then return 0 end
	local iconic = (type(entry) == 'table' and entry.ICONIC == true) and life.ICONIC_LIFESPAN or 1
	return life.LIFESPAN_DAYS * M.Ripper.DAY_SECONDS * M.Ripper.LevelFactor(level, cap, life) * iconic
end

--- The most condition use, damage and deaths may take off one life, in
--- points. The level and the iconic factor stretch the life AND this cap
--- together, so in points it is one number: `100 x WEAR_DAYS / LIFESPAN_DAYS`.
-- @param life table|nil `M.Ripper.Lifecycle()`, read when absent
-- @return number points
function M.Ripper.WearCapPoints(life)
	life = life or M.Ripper.Lifecycle()
	if life.LIFESPAN_DAYS <= 0 then return 0 end
	return 100 * math.min(life.WEAR_DAYS, life.LIFESPAN_DAYS) / life.LIFESPAN_DAYS
end

-- ── the wall clock ────────────────────────────────────────────────────────
--
-- A LIFE IS CALENDAR TIME, so it needs a clock that keeps running while the
-- server does not: the platform's own wall clock (`GetUnixTime`, fractional
-- seconds, or `Open77.time.unix`), else the database's `UNIX_TIMESTAMP()` read
-- once at Start and advanced by the server's own timer. With neither, the
-- monotonic timer is all there is: chrome then ages only while this server
-- runs, and a stamp from one boot is never read against another's (a stamp
-- under `WALL_FLOOR` is not a wall-clock reading).

--- The smallest reading taken for a wall clock (2001): anything below is a
--- monotonic timer, never a date.
M.Ripper.WALL_FLOOR = 1e9

-- The database's clock at Start and `OPX.Now()` when it was read, or nil.
local unixAnchor = nil

--- A reading in unix seconds, or nil when it cannot be one. A reading in
--- milliseconds is humoured.
-- @param value any
-- @return number|nil
local function unixSeconds(value)
	local seconds = OPX.Math.Finite(value)
	if seconds == nil then return nil end
	if seconds >= 1e11 then seconds = seconds / 1000 end
	if seconds < M.Ripper.WALL_FLOOR or seconds >= 1e11 then return nil end
	return seconds
end

--- The platform's own wall clock, or nil on a host without one. Read at every
--- call and never captured: a global the host installs late is still found.
-- @return number|nil unix seconds
function M.Ripper.PlatformUnix()
	if type(GetUnixTime) == 'function' then
		local ran, value = pcall(GetUnixTime)
		local seconds = ran and unixSeconds(value) or nil
		if seconds ~= nil then return seconds end
	end
	local time = type(Open77) == 'table' and Open77.time or nil
	if type(time) == 'table' and type(time.unix) == 'function' then
		local ran, value = pcall(time.unix)
		local seconds = ran and unixSeconds(value) or nil
		if seconds ~= nil then return seconds end
	end
	return nil
end

--- Now, in unix seconds: the platform's wall clock, else the database's clock
--- from Start advanced by the server's timer, else the server's timer alone.
-- @return number seconds
-- @return string `platform`, `database` or `monotonic`
function M.Ripper.UnixNow()
	local platform = M.Ripper.PlatformUnix()
	if platform ~= nil then return platform, 'platform' end
	if unixAnchor ~= nil then
		return unixAnchor.unix + (OPX.Now() - unixAnchor.at) / 1000, 'database'
	end
	return OPX.Now() / 1000, 'monotonic'
end

--- Takes the database's clock (`SELECT UNIX_TIMESTAMP()`, read at Start) as
--- the wall clock for a host without one of its own. nil forgets it.
-- @param unix any unix seconds
-- @param at number|nil `OPX.Now()` when it was read
-- @return boolean taken
function M.Ripper.AnchorUnix(unix, at)
	if unix == nil then
		unixAnchor = nil
		return false
	end
	local seconds = unixSeconds(unix)
	if seconds == nil then return false end
	unixAnchor = { unix = seconds, at = tonumber(at) or OPX.Now() }
	return true
end

--- Whether a stamp is a wall-clock reading (and so comparable with another
--- one across restarts), rather than a monotonic timer's.
-- @param seconds any
-- @return boolean
function M.Ripper.WallClock(seconds)
	return unixSeconds(seconds) ~= nil
end

--- The band a condition is in.
-- @param points number
-- @param broken boolean|nil
-- @return string `optimal`, `worn`, `failing` or `broken`
function M.Ripper.ConditionState(points, broken)
	points = tonumber(points) or 100
	if broken == true or points <= 0 then return 'broken' end
	local life = M.Ripper.Lifecycle()
	if points < life.FAILING_AT then return 'failing' end
	if points < life.WORN_AT then return 'worn' end
	return 'optimal'
end

--- What fraction of its effects a piece in this condition is worth.
-- @param points number
-- @param broken boolean|nil
-- @return number 0..1
function M.Ripper.EffectFactor(points, broken)
	local state = M.Ripper.ConditionState(points, broken)
	if state == 'broken' then return 0 end
	if state == 'failing' then return M.Ripper.Lifecycle().FAILING_EFFECT end
	return 1
end

--- What buying the wear back costs: the missing share of the grade's price,
--- times the repair fraction, never below the floor -- a price that follows
--- the chrome, so a worn Kiroshi is not repaired at a Sandevistan's rate. A
--- grade with no price falls back to the flat per-point rate.
-- @param grade table|nil
-- @param points number
-- @param broken boolean|nil
-- @return integer
function M.Ripper.RepairPrice(grade, points, broken)
	local missing = 100 - math.max(0, math.min(100, tonumber(points) or 100))
	if broken == true then missing = 100 end
	if missing <= 0 then return 0 end
	local life = M.Ripper.Lifecycle()
	local price = type(grade) == 'table' and tonumber(grade.PRICE) or nil
	local cost
	if price ~= nil and price > 0 then
		cost = price * life.REPAIR_FRACTION * missing / 100
	else
		cost = missing * M.Ripper.PricePerPoint()
	end
	return math.max(math.floor(life.REPAIR_MIN), math.ceil(cost))
end

--- Whether a fitted entry is what a wear selector names. A selector is a
--- piece id (the shipped config's own shape), `slot:<platform slot>`,
--- `grant:<dash|reflex|ability>` or `system:<body system>`.
-- @param selector string
-- @param entry table
-- @return boolean
function M.Ripper.WearMatches(selector, entry)
	if type(selector) ~= 'string' or type(entry) ~= 'table' then return false end
	local class, value = selector:match('^(%a+):([%w_]+)$')
	if class == nil then
		-- A plain id names one piece -- and, since the shipped ids name the
		-- family's first member, the family: `arms` wears whichever Gorilla
		-- Arms are fitted, `reflex` whichever Sandevistan.
		local named = M.Ripper.Entry(selector)
		if named == nil then return entry.id == selector end
		if entry.id == named.id then return true end
		if M.Ripper.IsPlatform(named) and M.Ripper.IsPlatform(entry) then
			return named.SLOT ~= nil and named.SLOT == entry.SLOT
		end
		local grant = M.Ripper.GrantKind(named)
		return grant ~= nil and grant == M.Ripper.GrantKind(entry)
	end
	if class == 'slot' then return M.Ripper.IsPlatform(entry) and entry.SLOT == value end
	if class == 'grant' then return M.Ripper.GrantKind(entry) == value end
	if class == 'system' then return entry.SYSTEM == value end
	return false
end

--- The selector one host wear event wears, and what one use costs a piece.
-- @param eventName string a key of `DURABILITY.WEAR_BY`
-- @return string|nil selector
function M.Ripper.WearSelector(eventName)
	local durability = M.Ripper.Durability()
	if durability.enabled == false then return nil end
	local selector = type(durability.WEAR_BY) == 'table' and durability.WEAR_BY[eventName] or nil
	return type(selector) == 'string' and selector or nil
end

--- The weight one use of a piece carries: its own `WEAR` (a Sandevistan's
--- overdrive is harder on it than a dash), else `DURABILITY.WEAR`, else 1. A
--- use costs `USE_MINUTES` of the piece's life times this.
-- @param entry table
-- @return number
function M.Ripper.WearWeight(entry)
	local weight = tonumber(type(entry) == 'table' and entry.WEAR or nil)
		or tonumber(M.Ripper.Durability().WEAR) or 1
	if weight ~= weight or weight < 0 then return 0 end
	return weight
end

--- How a piece is held: `hacking` (a durable implant with a hack beside it),
-- or one of the session grants (`dash`, `reflex`, `ability`). A piece with no
-- POWER block is a plain durable implant.
-- @param entry table
-- @return string|nil
function M.Ripper.GrantKind(entry)
	local power = type(entry) == 'table' and type(entry.POWER) == 'table' and entry.POWER or nil
	local kind = power and type(power.GRANT) == 'string' and power.GRANT or nil
	if kind == 'dash' or kind == 'reflex' or kind == 'ability' or kind == 'hacking' then
		return kind
	end
	return nil
end

--- Whether the piece is held as a session grant rather than a durable
-- implant (the movement kit).
-- @param entry table
-- @return boolean
function M.Ripper.IsGrant(entry)
	local kind = M.Ripper.GrantKind(entry)
	return kind == 'dash' or kind == 'reflex' or kind == 'ability'
end

--- The platform definition id for one grade. Implants name one definition for
-- the piece; grants and hacks name one per grade, because a grade IS a
-- different config.
-- @param entry table
-- @param grade table|nil
-- @return string
function M.Ripper.DefinitionFor(entry, grade)
	-- A GRANT'S DEFINITION IS ITS CONFIG'S, shared by every grade that
	-- configures the power the same way (`M.Ripper.GrantPlan`).
	if M.Ripper.IsGrant(entry) and type(grade) == 'table' then
		local planned = M.Ripper.GrantPlan().byGrade[tostring(entry.id) .. '|' .. tostring(grade.id)]
		if planned ~= nil then return planned end
	end
	local base = type(entry) == 'table' and type(entry.DEFINITION) == 'string'
		and entry.DEFINITION or ('opx.ripperdoc.' .. tostring(type(entry) == 'table' and entry.id or 'piece'))
	-- A HACK IS NOT A GRANT. `wiki/hacking.md`: the hack definition and the
	-- implant are registered "using the same provider resource, definition ID,
	-- version and grade IDs" -- one definition carrying every grade. Minting a
	-- per-grade id for the hack gave an implant whose deck the hacking service
	-- had never heard of, so a bought deck could not upload anything.
	if M.Ripper.IsGrant(entry) then
		return base .. '.' .. tostring(type(grade) == 'table' and grade.id or 'grade')
	end
	return base
end

-- ── the keys the powers answer to ─────────────────────────────────────────
--
-- ONE KEY PER POWER CLASS, NOT PER PIECE. The platform registers ONE
-- rebindable action per movement module on the player's machine -- for the
-- Sandevistans that is `open77_reflex`'s `reflex_overdrive`, "Overdrive: engage
-- the reflex boost" -- and a definition's `inputKey` is only that action's
-- DEFAULT (`wiki/reflex-overdrive.md`). Two Sandevistans shipping two defaults
-- would move a player's key every time they changed chrome, so the default is
-- the class's: `POWER_KEYS` in `config/ripperdoc.lua`, then the piece's own
-- `POWER.KEY`, then the shipped one here. A player's own rebind (Pause >
-- Settings > KEY BINDINGS, or `/opx.sandy.key`) wins over all three and
-- follows them to every server.
M.Ripper.POWER_KEYS = { reflex = 'x', dash = 'z', ability = 'l' }

-- The action a Sandevistan is engaged through on the player's machine: the
-- mapping `open77_reflex` registers from the definition's `inputKey`.
M.Ripper.SANDY_MAPPING = { RESOURCE = 'open77_reflex', ID = 'reflex_overdrive' }

-- The platform's own vocabulary for a movement `inputKey`, copied from the
-- reflex client's `validKey`: one lowercase letter or digit, f1..f12, or one of
-- these named keys. Anything else is refused by the player's client, which
-- acks the projection as failed and leaves the power dead.
local NAMED_KEYS = {}
for name in ('space enter return tab shift ctrl control alt capslock backspace insert'
	.. ' delete home end pageup pagedown up down left right'):gmatch('%S+') do
	NAMED_KEYS[name] = true
end

--- A key in the platform's `inputKey` vocabulary, lowercased, or nil.
-- @param key any
-- @return string|nil
function M.Ripper.PowerKeyValid(key)
	if type(key) ~= 'string' then return nil end
	local lowered = key:lower()
	if lowered:match('^[a-z0-9]$') or lowered:match('^f[1-9]$') or lowered:match('^f1[0-2]$')
		or NAMED_KEYS[lowered] then
		return lowered
	end
	return nil
end

--- The default key a piece's power is registered under, lowercase, or nil for a
--- piece that is not a movement power.
-- @param entry table
-- @return string|nil
function M.Ripper.PowerKey(entry)
	local kind = M.Ripper.GrantKind(entry)
	if kind ~= 'dash' and kind ~= 'reflex' and kind ~= 'ability' then return nil end
	local keys = type(M.Settings.POWER_KEYS) == 'table' and M.Settings.POWER_KEYS or {}
	local power = type(entry.POWER) == 'table' and entry.POWER or {}
	return M.Ripper.PowerKeyValid(keys[kind]) or M.Ripper.PowerKeyValid(power.KEY)
		or M.Ripper.POWER_KEYS[kind]
end

--- The mapping a Sandevistan is engaged through on the player's machine.
-- @return table { RESOURCE, ID }
function M.Ripper.SandyMapping()
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or {}
	local mapping = type(sandy.MAPPING) == 'table' and sandy.MAPPING or {}
	return {
		RESOURCE = type(mapping.RESOURCE) == 'string' and mapping.RESOURCE ~= ''
			and mapping.RESOURCE or M.Ripper.SANDY_MAPPING.RESOURCE,
		ID = type(mapping.ID) == 'string' and mapping.ID ~= '' and mapping.ID
			or M.Ripper.SANDY_MAPPING.ID,
	}
end

-- ── what a Sandevistan looks like on the body ─────────────────────────────

-- ── how long a Sandevistan's boost runs ───────────────────────────────────
--
-- THE BOOST GROWS WITH THE CHARACTER. The platform's overdrive is capped at
-- 15 s by its own client and its definitions are shared by grade, so the
-- definitions never change with a level. What the ripperdoc draws of a boost
-- -- the look, the owner's slowed world, the players slowed around them, the
-- screen -- is its own, and THAT runs for the level-scaled time: the grade's
-- own `durationMs` at level 1, `SANDEVISTAN.LEVEL_SECONDS` at the level cap
-- (the first number for a tier-1 grade, the second for tier 5, linear
-- between), linear in the level. A Sandevistan the platform draws (no LOOK)
-- has nothing of the ripperdoc's to lengthen and keeps the platform's boost.

--- The longest boost the ripperdoc runs, in seconds: the clients hold a boost
--- for at most 45 s (a boost and its 250 ms margin, `CAP_MS` in both
--- `server/sandevistan.lua` and `client/sandevistan.lua`, and opx_sandy_view
--- 1.4.9's own claim ceiling).
M.Ripper.SANDY_MAX_SECONDS = 44

--- `SANDEVISTAN.LEVEL_SECONDS`, bounded: what a tier-1 and a tier-5 grade's
--- boost lasts at the level cap. nil when it is not set (every level then runs
--- the grade's own duration).
-- @return table|nil { lo, hi } seconds
function M.Ripper.SandyLevelSeconds()
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or {}
	local pair = type(sandy.LEVEL_SECONDS) == 'table' and sandy.LEVEL_SECONDS or nil
	if pair == nil then return nil end
	local lo, hi = OPX.Math.Finite(pair[1]), OPX.Math.Finite(pair[2])
	if lo == nil and hi == nil then return nil end
	lo, hi = lo or hi, hi or lo
	local most = M.Ripper.SANDY_MAX_SECONDS
	return { math.max(0.5, math.min(most, lo)), math.max(0.5, math.min(most, hi)) }
end

--- How long one Sandevistan's boost runs for a character at this level --
--- never shorter than the grade's own.
-- @param tier number the grade's tier, 1..5
-- @param baseMs number the grade's own `durationMs` (what level 1 runs)
-- @param level number|nil
-- @param cap number|nil
-- @return integer ms
function M.Ripper.SandyBoostMs(tier, baseMs, level, cap)
	local base = math.max(500, OPX.Math.Finite(baseMs) or 6000)
	local seconds = M.Ripper.SandyLevelSeconds()
	local fraction = M.Ripper.LevelFraction(level, cap)
	if seconds == nil or fraction <= 0 then return math.floor(base + 0.5) end
	tier = math.max(1, math.min(5, math.floor(tonumber(tier) or 1)))
	local target = (seconds[1] + (seconds[2] - seconds[1]) * (tier - 1) / 4) * 1000
	-- A level lengthens a boost and never shortens it: the platform's own
	-- overdrive runs its definition's time whatever the ripperdoc draws.
	return math.floor(math.max(base, base + (target - base) * fraction) + 0.5)
end

--- A grade's own boost, in ms: the `durationMs` of the definition that
--- serves it (past the platform's definition limit that is the nearest kept
--- config, which is what the platform really runs), else its own config's.
-- @param entry table
-- @param grade table
-- @return number ms
function M.Ripper.SandyBaseMs(entry, grade)
	local plan = M.Ripper.GrantPlan()
	local id = plan.byGrade[tostring(entry.id) .. '|' .. tostring(grade.id)]
	for _, def in ipairs(id ~= nil and plan.defs or {}) do
		if def.id == id and type(def.config) == 'table' then
			local ms = OPX.Math.Finite(def.config.durationMs)
			if ms ~= nil then return ms end
		end
	end
	return OPX.Math.Finite(M.Ripper.GrantConfig(entry, grade).durationMs) or 6000
end

--- WHAT THE CHARACTER'S LEVEL IS WORTH TO THEIR CHROME, for a page that shows
--- it (the skill tree): how long a (non-iconic) piece lasts and how much of
--- that hard use may take, in days, and the shortest and longest Sandevistan
--- boost the ripperdoc runs, in seconds -- at this level, at level 1 (`Base`)
--- and at the cap (`Max`). A tray whose Sandevistans the ripperdoc does not
--- draw answers their own boosts, which no level lengthens. Durability off
--- answers 0 days.
-- @param level number
-- @param cap number
-- @return table { lifeDays, lifeBaseDays, lifeMaxDays, wearDays, activeSeconds = {lo, hi},
--   activeBaseSeconds = {lo, hi}, activeMaxSeconds = {lo, hi} }
function M.Ripper.ChromeLevel(level, cap)
	local life = M.Ripper.Lifecycle()
	level = OPX.Math.Finite(level) or 1
	cap = OPX.Math.Finite(cap)
	local days = M.Ripper.LifeSeconds(nil, 1, 1, life) / M.Ripper.DAY_SECONDS
	local wear = days > 0 and math.min(life.WEAR_DAYS, life.LIFESPAN_DAYS) or 0
	-- Rounded by dividing, so 32.5 is 32.5 and 7.42 is 7.42 to the last bit.
	local function round(value, places)
		local scale = 10 ^ places
		return math.floor(value * scale + 0.5) / scale
	end
	-- The Sandevistan grades the ripperdoc draws, and so lengthens; with none,
	-- every Sandevistan grade at the platform's own boost.
	local drawn, own = {}, {}
	for _, entry in ipairs(M.Ripper.Catalog()) do
		if M.Ripper.GrantKind(entry) == 'reflex' then
			local styled = M.Ripper.SandyLook(entry) ~= nil
			for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
				local row = { tier = grade.TIER, base = M.Ripper.SandyBaseMs(entry, grade) }
				if styled then drawn[#drawn + 1] = row else own[#own + 1] = row end
			end
		end
	end
	local scaled = #drawn > 0
	local grades = scaled and drawn or own
	local function range(at)
		local lo, hi = nil, nil
		for _, row in ipairs(grades) do
			local ms = scaled and M.Ripper.SandyBoostMs(row.tier, row.base, at, cap) or row.base
			lo = (lo == nil or ms < lo) and ms or lo
			hi = (hi == nil or ms > hi) and ms or hi
		end
		return { round((lo or 0) / 1000, 1), round((hi or 0) / 1000, 1) }
	end
	local factor = M.Ripper.LevelFactor(level, cap, life)
	return {
		lifeDays = round(days * factor, 2),
		lifeBaseDays = round(days, 2),
		lifeMaxDays = round(days * life.LEVEL_LIFESPAN, 2),
		wearDays = round(wear * factor, 2),
		activeSeconds = range(level),
		activeBaseSeconds = range(1),
		activeMaxSeconds = range(cap or 1),
	}
end

--- The look a piece's overdrive wears on the body (config `SANDEVISTAN`), or
--- nil when it keeps the platform's own presentation.
-- @param entry table
-- @return table|nil the look
-- @return string|nil its name
function M.Ripper.SandyLook(entry)
	if type(entry) ~= 'table' or M.Ripper.GrantKind(entry) ~= 'reflex' then return nil, nil end
	local sandy = type(M.Settings.SANDEVISTAN) == 'table' and M.Settings.SANDEVISTAN or nil
	if sandy == nil or sandy.enabled == false then return nil, nil end
	local chosen = type(sandy.LOOK) == 'table' and sandy.LOOK[entry.id] or nil
	if type(chosen) ~= 'string' then return nil, nil end
	local look = type(sandy.LOOKS) == 'table' and sandy.LOOKS[chosen] or nil
	if type(look) ~= 'table' then return nil, nil end
	return look, chosen
end

-- ── the grant definitions ──────────────────────────────────────────────────
--
-- THE PLATFORM HOLDS AT MOST A FEW DEFINITIONS PER MODULE PER RESOURCE: staging
-- refused the ninth reflex and the ninth ground-slam definition with
-- `definition_limit`, which left Warp Dancer T5, the Falcon, the Apogee and the
-- top Berserks sold but ungrantable. A definition is only a CONFIG, so grades
-- that configure a power identically share one, and when a module still has
-- more distinct configs than the platform takes, the extra grades are served by
-- the nearest config that fits. The id is a hash of the config, so it is the
-- same on every boot whatever order the tray is built in.

--- The config a grade grants: the module's own config verbatim, with the power
--- class's key as the default binding (`M.Ripper.PowerKey`) and, for a
--- Sandevistan that wears its own look, no platform presentation.
-- @param entry table
-- @param grade table
-- @return table
function M.Ripper.GrantConfig(entry, grade)
	local config = {}
	for field, value in pairs(type(grade) == 'table' and type(grade.VALUE) == 'table' and grade.VALUE or {}) do
		config[field] = value
	end
	local key = type(entry) == 'table' and M.Ripper.PowerKey(entry) or nil
	if config.inputKey == nil and key ~= nil then config.inputKey = key end
	-- A SANDEVISTAN WITH ITS OWN LOOK asks the platform to draw nothing: the
	-- platform's `native` presentation is a blue glow, sparks at the feet and
	-- the Berserk's sounds, and it would play UNDER the look this server
	-- draws (`server/sandevistan.lua`). `none` still runs every phase and
	-- every release path; it only switches the platform's picture off.
	if M.Ripper.SandyLook(entry) ~= nil then config.presentation = 'none' end
	return config
end

--- A config as one stable string.
-- @param config table
-- @return string
local function serialize(config)
	local keys = {}
	for key in pairs(config) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do parts[#parts + 1] = key .. '=' .. tostring(config[key]) end
	return table.concat(parts, ';')
end

--- FNV-1a, 32 bits, as eight hex digits.
-- @param text string
-- @return string
local function fingerprint(text)
	local hash = 2166136261
	for index = 1, #text do
		hash = ((hash ~ text:byte(index)) * 16777619) & 0xFFFFFFFF
	end
	return ('%08x'):format(hash)
end

--- How far apart two configs are: the relative gap of every number they
--- share, and a full step for every word that differs.
-- @param a table
-- @param b table
-- @return number
local function distance(a, b)
	local total = 0
	for key, value in pairs(a) do
		local other = b[key]
		if type(value) == 'number' and type(other) == 'number' then
			local scale = math.max(math.abs(value), math.abs(other), 1)
			total = total + math.abs(value - other) / scale
		elseif value ~= other then
			total = total + 1
		end
	end
	return total
end

--- The most definitions the platform takes per module (config GRANTS).
-- @return integer
function M.Ripper.GrantLimit()
	local grants = type(M.Settings.GRANTS) == 'table' and M.Settings.GRANTS or {}
	local limit = OPX.Math.Finite(grants.DEFINITION_LIMIT)
	if limit == nil or limit < 1 then return 8 end
	return math.floor(limit)
end

local plan = { list = nil, limit = nil, value = nil }

--- Every grant definition the tray needs, and the one each grade uses.
-- @return table { defs = array of {id, kind, profile, config, grades}, byGrade = "entry|grade" -> id }
function M.Ripper.GrantPlan()
	local list = M.Ripper.Catalog()
	local limit = M.Ripper.GrantLimit()
	if plan.value ~= nil and plan.list == list and plan.limit == limit then return plan.value end
	local PROFILE = { dash = 'dash', reflex = 'reflex_overdrive', ability = 'ground_slam' }
	local out = { defs = {}, byGrade = {} }
	local perKind = {}
	-- Every distinct config, in the order the tray first names it.
	for _, entry in ipairs(list) do
		if M.Ripper.IsGrant(entry) then
			local kind = M.Ripper.GrantKind(entry)
			perKind[kind] = perKind[kind] or { order = {}, byKey = {} }
			for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
				local config = M.Ripper.GrantConfig(entry, grade)
				local key = serialize(config)
				local slot = perKind[kind].byKey[key]
				if slot == nil then
					slot = { key = key, config = config, grades = {}, tier = tonumber(grade.TIER) or 1 }
					perKind[kind].byKey[key] = slot
					perKind[kind].order[#perKind[kind].order + 1] = slot
				end
				slot.grades[#slot.grades + 1] = tostring(entry.id) .. '|' .. tostring(grade.id)
			end
		end
	end
	for kind, bucket in pairs(perKind) do
		-- MORE THAN FITS: keep the configs the most grades use, then the
		-- strongest tiers, and serve the rest from the nearest kept one.
		local kept = {}
		for _, slot in ipairs(bucket.order) do kept[#kept + 1] = slot end
		if #kept > limit then
			table.sort(kept, function(a, b)
				-- A config that draws its OWN look is kept first: served by the
				-- nearest other config, a Sandevistan bought for its look would
				-- wear the platform's instead.
				local ownA, ownB = a.config.presentation == 'none', b.config.presentation == 'none'
				if ownA ~= ownB then return ownA end
				if #a.grades ~= #b.grades then return #a.grades > #b.grades end
				if a.tier ~= b.tier then return a.tier > b.tier end
				return a.key < b.key
			end)
			for index = #kept, limit + 1, -1 do kept[index] = nil end
		end
		local keptSet = {}
		for _, slot in ipairs(kept) do
			slot.id = ('opx.ripperdoc.%s.%s'):format(kind, fingerprint(slot.key))
			keptSet[slot] = true
			out.defs[#out.defs + 1] = { id = slot.id, kind = kind, profile = PROFILE[kind],
				config = slot.config, grades = slot.grades }
		end
		for _, slot in ipairs(bucket.order) do
			if not keptSet[slot] then
				-- THE LOOK DECIDES FIRST. A grade the platform should draw must
				-- not be served by a definition that asks it to draw nothing
				-- (nor the other way round): that grade would be a Sandevistan
				-- nobody could see. Only when no config of its class was kept
				-- does any config do.
				local own = slot.config.presentation == 'none'
				local best, gap = nil, math.huge
				for pass = 1, 2 do
					for _, candidate in ipairs(kept) do
						if pass == 2 or (candidate.config.presentation == 'none') == own then
							local d = distance(slot.config, candidate.config) + distance(candidate.config, slot.config)
							if d < gap then best, gap = candidate, d end
						end
					end
					if best ~= nil then break end
				end
				slot.id = best ~= nil and best.id or nil
				slot.servedBy = best
			end
			for _, gradeKey in ipairs(slot.grades) do out.byGrade[gradeKey] = slot.id end
		end
	end
	table.sort(out.defs, function(a, b) return a.id < b.id end)
	plan.list, plan.limit, plan.value = list, limit, out
	return out
end

--- The platform module a grant is armed through.
-- @param entry table
-- @return table|nil the `Open77.dash`/`reflex`/`abilities`/`hacking` namespace
function M.Ripper.GrantModule(entry)
	local kind = M.Ripper.GrantKind(entry)
	if kind == nil or type(Open77) ~= 'table' then return nil end
	local name = kind == 'dash' and 'dash' or kind == 'reflex' and 'reflex'
		or kind == 'ability' and 'abilities' or 'hacking'
	local module = Open77[name]
	return type(module) == 'table' and module or nil
end
