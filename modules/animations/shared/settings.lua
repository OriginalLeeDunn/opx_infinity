--- The validated view of config/animations.lua both halves read.
-- @author dop42
--
-- Every value either half computes or looks up is resolved here, once, at load
-- on each side, so that a typo is a warning at boot and a fallback rather than a
-- raise in the middle of a request. The defaults are written once, in these
-- calls. Switches that are true by default read `~= false` on purpose: a
-- misspelled flag keeps the default. `RESTRICTED` reads `== true` instead, in
-- server/commands.lua: those commands act on their caller alone, so a misspelled
-- flag leaves them open.
--
-- This runs after shared/catalogue.lua, because DISABLED is checked against it.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common

-- The operator table, or an empty one.
local Config = type(M.Settings) == 'table' and M.Settings or {}

M.Opt = {}
local Opt = M.Opt

--- Everything wrong with config/animations.lua, in English, for the boot log.
M.Problems = {}

local function problem(line)
	M.Problems[#M.Problems + 1] = line
end

-- Answers a configured whole number in range, or the fallback.
local function bounded(key, value, low, high, fallback)
	local parsed = Common.Integer(value, low, high)
	if parsed == nil then
		problem(('%s must be a whole number in %d..%d; using %d'):format(key, low, high, fallback))
		return fallback
	end
	return parsed
end

local PRESENTERS = { auto = true, always = true, never = true }
Opt.PRESENTER = Config.PRESENTER
if not PRESENTERS[Opt.PRESENTER] then
	problem('PRESENTER must be "auto", "always" or "never"; using "auto"')
	Opt.PRESENTER = 'auto'
end

Opt.NOTIFY = Config.NOTIFY ~= false
Opt.PROMPTS = Config.PROMPTS ~= false
Opt.TOAST_MS = bounded('TOAST_MS', Config.TOAST_MS, 750, 120000, 4000)

Opt.LOOP_BY_DEFAULT = Config.LOOP_BY_DEFAULT ~= false
Opt.MAX_DURATION_MS = bounded('MAX_DURATION_MS', Config.MAX_DURATION_MS,
	M.MIN_DURATION_MS, M.SERVICE_MAX_MS, M.SERVICE_MAX_MS)
Opt.ONE_SHOT_MS = bounded('ONE_SHOT_MS', Config.ONE_SHOT_MS, M.MIN_DURATION_MS,
	Opt.MAX_DURATION_MS, math.min(10000, Opt.MAX_DURATION_MS))

local rate = type(Config.RATE_LIMIT) == 'table' and Config.RATE_LIMIT or {}
if type(Config.RATE_LIMIT) ~= 'table' then problem('RATE_LIMIT must be a table') end
Opt.WINDOW_MS = bounded('RATE_LIMIT.WINDOW_MS', rate.WINDOW_MS, 250, 600000, 10000)
Opt.REQUESTS = bounded('RATE_LIMIT.REQUESTS', rate.REQUESTS, 1, 1000, 6)

local picker = type(Config.PICKER) == 'table' and Config.PICKER or {}
Opt.CLOSE_ON_SELECT = picker.CLOSE_ON_SELECT ~= false
Opt.SHOW_VARIANT_WORDS = picker.SHOW_VARIANT_WORDS ~= false

-- Answers a configured default key, false, or the fallback.
local function keyName(key, value, fallback)
	if value == false then return false end
	if value == nil then return fallback end
	if type(value) == 'string' and #value > 0 and #value <= 32 and not value:find('[%s%c]') then
		return value
	end
	problem(('%s must be a key name or false; using %q'):format(key, fallback))
	return fallback
end

local keys = type(Config.KEYS) == 'table' and Config.KEYS or {}
if Config.KEYS ~= nil and type(Config.KEYS) ~= 'table' then
	problem('KEYS must be a table; using the default keys')
end
Opt.KEY_PICKER = keyName('KEYS.PICKER', keys.PICKER, 'F3')
Opt.KEY_STOP = keyName('KEYS.STOP', keys.STOP, 'X')
-- Two identical keys keep the picker's alone; the stop key is not registered.
if Opt.KEY_PICKER and Opt.KEY_PICKER == Opt.KEY_STOP then
	problem(('KEYS.PICKER and KEYS.STOP are both %q; the stop key is not registered'):format(
		Opt.KEY_STOP))
	Opt.KEY_STOP = false
end

--- Catalogue names the operator switched off.
Opt.DISABLED = {}

--- DISABLED names no written row carries. They may be platform profiles, which
--- are only known once the server has read the platform's catalogue: it checks
--- them then, and says which matched nothing.
Opt.DISABLED_UNWRITTEN = {}
if Config.DISABLED ~= nil and type(Config.DISABLED) ~= 'table' then
	problem('DISABLED must be a list of catalogue names')
elseif type(Config.DISABLED) == 'table' then
	for _, name in pairs(Config.DISABLED) do
		local entry = Catalogue.Entry(name)
		if entry ~= nil then
			Opt.DISABLED[entry.name] = true
		elseif Catalogue.DuoKind(name) ~= nil then
			-- A paired kind's own id (`escort`, `carried`...): withholds that row.
			Opt.DISABLED[name] = true
		elseif type(name) == 'string' and name:lower():match('^[%l%d_]+$') and #name <= 64 then
			Opt.DISABLED[name:lower()] = true
			Opt.DISABLED_UNWRITTEN[#Opt.DISABLED_UNWRITTEN + 1] = name:lower()
		else
			problem(('DISABLED names %q, which cannot be a profile id'):format(tostring(name)))
		end
	end
end

--- Whether the platform's own catalogue is offered beside the written rows.
Opt.PLATFORM = Config.PLATFORM ~= false

-- ── emotes with a nearby player ──
local shared = type(Config.SHARED) == 'table' and Config.SHARED or {}
if Config.SHARED ~= nil and type(Config.SHARED) ~= 'table' then
	problem('SHARED must be a table; no emote with a nearby player is offered')
end
Opt.SHARED = shared.ENABLED ~= false and type(Config.SHARED) == 'table'
Opt.SHARED_INVITE_MS = Opt.SHARED
	and bounded('SHARED.INVITE_MS', shared.INVITE_MS, 1000, 60000, 15000) or 15000

-- The coordinator accepts 0.25 to 10 metres; a decimal, so not `bounded`.
local range = tonumber(shared.RANGE)
if range == nil or range ~= range or range < 0.25 or range > 10 then
	if shared.RANGE ~= nil then problem('SHARED.RANGE must be a number in 0.25..10; using 3') end
	range = 3.0
end
Opt.SHARED_RANGE = range

--- Whether any two catalogue profiles may be asked for, one per body.
Opt.SHARED_ANY = Opt.SHARED and shared.ANY ~= false

--- How long a pair of two profiles plays. Two one-shot gestures play for the
--- longer of their measured clips instead.
Opt.SHARED_DURATION_MS = shared.DURATION_MS == nil and 30000 or
	bounded('SHARED.DURATION_MS', shared.DURATION_MS, M.MIN_DURATION_MS, M.SERVICE_MAX_MS, 30000)

-- What each of the platform's own kinds plays for when nothing says otherwise.
local KIND_MS = { carry = 60000, escort = 60000, give = 5000, heal = 12000 }

--- The platform's paired kinds by their coordinator name: enabled, and for how
--- long. A kind config does not name stays on at its default length.
Opt.SHARED_KINDS = {}
local kinds = type(shared.KINDS) == 'table' and shared.KINDS or {}
if shared.KINDS ~= nil and type(shared.KINDS) ~= 'table' then
	problem('SHARED.KINDS must be a table; every kind keeps its default')
end
for kind, fallback in pairs(KIND_MS) do
	local row = type(kinds[kind]) == 'table' and kinds[kind] or {}
	Opt.SHARED_KINDS[kind] = {
		enabled = Opt.SHARED and row.ENABLED ~= false,
		durationMs = row.DURATION_MS == nil and fallback or
			bounded(('SHARED.KINDS.%s.DURATION_MS'):format(kind), row.DURATION_MS,
				M.MIN_DURATION_MS, M.SERVICE_MAX_MS, fallback),
	}
end
for kind in pairs(kinds) do
	if KIND_MS[kind] == nil then
		problem(('SHARED.KINDS.%s is not a kind the platform pairs (carry, escort, give, ' ..
			'heal); ignored'):format(tostring(kind)))
	end
end

--- The configured shortcuts, checked for shape. Whether their profiles exist is
--- a question for the running build, answered by the server. An ID may not be
--- one of the paired kinds' own (`carry`, `healed`...): `/e with <word>` reads
--- those first.
Opt.SHARED_PAIRS = {}
local pairIds = {}
for index, row in ipairs(type(shared.PAIRS) == 'table' and shared.PAIRS or {}) do
	local id = type(row) == 'table' and row.ID or nil
	local actor = type(row) == 'table' and row.ACTOR or nil
	local target = type(row) == 'table' and row.TARGET or nil
	if type(id) ~= 'string' or not id:match('^[%l%d_]+$') or #id > 32 or pairIds[id]
		or Catalogue.DuoKind(id) ~= nil or type(actor) ~= 'string' or type(target) ~= 'string' then
		problem(('SHARED.PAIRS[%d] needs a unique lower-case ID that is not a paired kind, ' ..
			'an ACTOR and a TARGET; skipped'):format(index))
	else
		pairIds[id] = true
		Opt.SHARED_PAIRS[#Opt.SHARED_PAIRS + 1] = {
			id = id,
			actor = actor:lower(),
			target = target:lower(),
			durationMs = bounded(('SHARED.PAIRS[%d].DURATION_MS'):format(index), row.DURATION_MS,
				M.MIN_DURATION_MS, M.SERVICE_MAX_MS, 10000),
		}
	end
end

--- The raw command table server/commands.lua registers from.
Opt.COMMANDS = type(Config.COMMANDS) == 'table' and Config.COMMANDS or {}
if type(Config.COMMANDS) ~= 'table' then problem('COMMANDS must be a table; no command exists') end

--- Answers the first configured command a name is typed after.
-- @author dop42
-- @return string|nil
function Opt.PlayCommand()
	for _, key in ipairs({ 'EMOTE', 'ANIM' }) do
		local entry = Opt.COMMANDS[key]
		local name = type(entry) == 'table' and entry.NAME or nil
		if type(name) == 'string' and name ~= '' then return name end
	end
	return nil
end

--- Answers the name the LIST command is registered under.
-- @author dop42
-- @return string|nil
function Opt.ListCommand()
	local entry = Opt.COMMANDS.LIST
	local name = type(entry) == 'table' and entry.NAME or nil
	if type(name) == 'string' and name ~= '' then return name end
	return nil
end
