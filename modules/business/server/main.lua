--- Server half: the HR terminal, the recruiting offers, the treasury desk.
-- @author dop42
--
-- EVERY DECISION IS HERE. A client asks for the terminal, a hire, a firing, a
-- promotion, a deposit; the server re-reads the boss's grade, the employee's
-- grade, the rank rule, the head-count cap, the distance and the balance,
-- decides, and answers with a locale key. A citizen id a client sends is a
-- NAME, never a fact: the grade it holds is read from the roster again.
--
-- EVERY STAFF CHANGE GOES THROUGH THE CHARACTER CONTRACT -- SetJob / SetGang
-- for a new grade on the primary group, AddPlayerToJob / AddPlayerToGang for a
-- grade on a group that is not primary (so promoting somebody in their side gig
-- does not switch what they are working), RemovePlayerFromJob /
-- RemovePlayerFromGang to fire, SetJobDuty to clock. Those carry the
-- `job:beforeSet` / `gang:beforeSet` vetoes, the offline ledger (an employee
-- who is not playing is changed in their row, safely against a login racing
-- it) and the `opx:on:character:job` bus. A veto comes back as `job.vetoed`
-- and is shown to the boss as such.
--
-- THE MONEY PATTERN at the treasury desk: a deposit takes the boss's cash
-- FIRST, then credits the account under a fresh operation id, and gives the
-- cash back only if the credit provably did not happen (an UNKNOWN outcome is
-- held and logged, never refunded: a refund there could mint). A withdrawal
-- debits the account FIRST (the SQL guard refuses an overdraft), then pays the
-- boss, offline if they left meanwhile, and credits the account back under a
-- derived id only if neither payment landed.

local M = OPX.Modules.Get('business')
local Access, Kind, Verb = M.Access, M.Kind, M.Verb
local Accounts = M.Accounts
local Result = OPX.Result

-- Per-player request windows.
local windows = {}
-- Open recruiting offers by id, and the offer each target holds.
local offers, offerOf = {}, {}
local nextOffer = 0
-- Citizen ids with a staff change in flight: one change per employee at a time.
local changing = {}
local hiring = {}
local sweepJob = nil

local OWNER = 'business'

local function safe(value) return OPX.Audit.Safe(tostring(value), 96) end
local function characterApi() return OPX.Api.Get('character') end

-- ── the people ──────────────────────────────────────────────────────────────

--- The loaded Player at a connection, or nil.
local function playerOf(source)
	local api = characterApi()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local ok, player = pcall(api.GetPlayer, source)
	if not ok or type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
	return player
end

local function dataOf(source)
	local player = playerOf(source)
	return player and player.PlayerData or nil
end

--- The loaded Player playing a citizen id, or nil.
local function onlineOf(citizenId)
	local api = characterApi()
	if api == nil or type(api.GetPlayerByCitizenId) ~= 'function' then return nil end
	local ok, player = pcall(api.GetPlayerByCitizenId, citizenId)
	if not ok or type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
	return player
end

local function nameOf(data)
	local info = type(data) == 'table' and type(data.charInfo) == 'table' and data.charInfo or {}
	local name = OPX.String.Trim(('%s %s'):format(info.firstName or '', info.lastName or ''))
	return name ~= '' and name or tostring(data and data.citizenId or '?')
end

--- The position and bucket of a connection, or nil.
local function standing(source)
	source = math.tointeger(tonumber(source))
	if source == nil or source < 1 then return nil end
	if type(Open77.players) ~= 'table' or type(Open77.players.position) ~= 'function' then
		return nil
	end
	local ok, at = pcall(Open77.players.position, source)
	if not ok or type(at) ~= 'table' then return nil end
	local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(tonumber(at.bucket)) or 0 }
end

local function near(a, b, reach)
	if a == nil or b == nil or a.bucket ~= b.bucket then return false, nil end
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	local gap = math.sqrt(dx * dx + dy * dy + dz * dz)
	return gap <= reach, gap
end

--- The grade somebody holds in a group as a MEMBERSHIP (primary or not).
local function heldGrade(data, kind, key)
	if type(data) ~= 'table' then return nil end
	local primary = kind == Kind.JOB and data.job or data.gang
	if type(primary) == 'table' and primary.name == key then
		local grade = type(primary.grade) == 'table' and primary.grade.level or primary.grade
		return math.tointeger(tonumber(grade)) or 0, true
	end
	local held = kind == Kind.JOB and data.jobs or data.gangs
	if type(held) == 'table' and held[key] ~= nil then
		return math.tointeger(tonumber(held[key])) or 0, false
	end
	return nil
end

-- ── telling people ──────────────────────────────────────────────────────────

local function tell(source, key, params, kind)
	source = math.tointeger(tonumber(source))
	if source == nil or source < 1 then return end
	OPX.NotifyLocale(source, key, params, kind or 'info')
end

--- A refusal by code: the character module's own keys (`job.vetoed`) as they
--- are, this module's under `business.refused.`, anything else generic.
local function refuse(source, code)
	code = tostring(code or 'generic')
	local key = 'business.refused.' .. code
	if not OPX.Locale.Exists(key) then
		key = OPX.Locale.Exists(code) and code or 'business.refused.generic'
	end
	tell(source, key, nil, 'error')
end

local function money(amount) return OPX.Locale.Money(amount, Access.POCKET) end

local function allowed(source)
	local at = OPX.Now()
	local window = windows[source]
	if window == nil or at - window.started >= Access.RATE_WINDOW_MS then
		window = { started = at, count = 0 }
		windows[source] = window
	end
	if window.count >= Access.RATE_REQUESTS then return false end
	window.count = window.count + 1
	return true
end

-- ── the desk: may this connection act for this group ────────────────────────

--- Whether the office rule lets a connection use a group's terminal here.
local function officeOk(source, kind, key)
	if not Access.REQUIRE_OFFICE then return true end
	if #Access.Offices(kind, key) == 0 then return true end
	return Access.AtOffice(kind, key, standing(source))
end

--- The boss's side of a request, or nil and the refusal code.
-- @return table|nil { player, data, kind, key, level, citizenId }
local function deskOf(source, kind, key)
	if not Access.ValidGroup(kind, key) then return nil, 'bad_group' end
	local player = playerOf(source)
	if player == nil then return nil, 'no_character' end
	local data = player.PlayerData
	local level = Access.Standing(data, kind, key)
	if level == nil or not Access.MayOpen(kind, key, level) then return nil, 'not_boss' end
	if not officeOk(source, kind, key) then return nil, 'office' end
	return { player = player, data = data, kind = kind, key = key, level = level,
		citizenId = data.citizenId }
end

-- ── the roster ──────────────────────────────────────────────────────────────

--- Everyone in a group, online or not, as `{ citizenId, name, grade, online,
--- onDuty, source }`, highest grade first. Reads the database.
-- @author dop42
-- @param kind string
-- @param key string
-- @return Result { rows }
local function roster(kind, key)
	if not Access.ValidGroup(kind, key) then return Result.Err('bad_group') end
	local api = characterApi()
	if api == nil or type(api.GetGroupMembers) ~= 'function' then return Result.Err('no_character') end
	local ok, read = pcall(api.GetGroupMembers, kind, key)
	if not ok or type(read) ~= 'table' or not read.ok then
		return Result.Err('roster_failed', ok and type(read) == 'table' and read.detail or tostring(read))
	end
	local rows, seen = {}, {}
	for _, member in ipairs(type(read.value) == 'table' and read.value or {}) do
		local cid = member.citizenId
		if type(cid) == 'string' and not seen[cid] then
			seen[cid] = true
			local row = { citizenId = cid, name = tostring(member.name or cid),
				grade = math.tointeger(tonumber(member.grade)) or 0, online = false, onDuty = false }
			local live = onlineOf(cid)
			if live ~= nil then
				local data = live.PlayerData
				local grade, primary = heldGrade(data, kind, key)
				-- The live grade wins over the row: a change that landed this second
				-- is in memory before it is in every read.
				if grade ~= nil then row.grade = grade end
				row.online, row.source = true, data.source
				row.primary = primary == true
				row.onDuty = primary == true and kind == Kind.JOB and type(data.job) == 'table'
					and data.job.onDuty == true
				row.name = nameOf(data)
			end
			rows[#rows + 1] = row
		end
	end
	table.sort(rows, function(a, b)
		if a.grade ~= b.grade then return a.grade > b.grade end
		if a.online ~= b.online then return a.online end
		return a.name < b.name
	end)
	return Result.Ok({ rows = rows })
end

--- One member's current grade and whether the group is their primary one.
-- Online from memory, offline from the roster and the stored row.
local function memberOf(kind, key, citizenId)
	local live = onlineOf(citizenId)
	if live ~= nil then
		local grade, primary = heldGrade(live.PlayerData, kind, key)
		if grade == nil then return nil, 'not_member' end
		return { grade = grade, primary = primary, online = true, data = live.PlayerData }
	end
	local list = roster(kind, key)
	if not list.ok then return nil, list.error end
	local found = nil
	for _, row in ipairs(list.value.rows) do
		if row.citizenId == citizenId then found = row break end
	end
	if found == nil then return nil, 'not_member' end
	-- Whether the group is their PRIMARY one decides SetJob over AddPlayerToJob,
	-- and an offline row knows it.
	local primary = false
	local api = characterApi()
	if api ~= nil and type(api.GetCharacter) == 'function' then
		local ok, read = pcall(api.GetCharacter, citizenId)
		local entity = ok and type(read) == 'table' and read.ok and type(read.value) == 'table'
			and read.value.entity or nil
		local group = type(entity) == 'table' and (kind == Kind.JOB and entity.job or entity.gang) or nil
		primary = type(group) == 'table' and group.name == key
	end
	return { grade = found.grade, primary = primary, online = false }
end

-- ── the staff changes, through the character contract ───────────────────────

local function call(name, ...)
	local api = characterApi()
	if api == nil or type(api[name]) ~= 'function' then return Result.Err('no_character') end
	local ok, answer = pcall(api[name], ...)
	if not ok then
		Open77.log.error(('[business] character.%s raised: %s'):format(name, safe(answer)))
		return Result.Err('generic')
	end
	if type(answer) ~= 'table' then return Result.Err('generic') end
	return answer
end

--- Puts a member at a grade: SetJob / SetGang when the group is primary (the
--- hooks run), the membership only when it is not.
local function setGrade(kind, key, citizenId, level, primary)
	if primary then
		return call(kind == Kind.JOB and 'SetJob' or 'SetGang', citizenId, key, level)
	end
	return call(kind == Kind.JOB and 'AddPlayerToJob' or 'AddPlayerToGang', citizenId, key, level)
end

--- Runs one change on one employee at a time.
local function withEmployee(citizenId, body)
	if changing[citizenId] then return false, 'busy' end
	changing[citizenId] = true
	local ok, done, why = pcall(body)
	changing[citizenId] = nil
	if not ok then
		Open77.log.error('[business] a staff change raised: ' .. safe(done))
		return false, 'generic'
	end
	return done, why
end

local function staffEvent(desk, verb, citizenId, grade)
	OPX.Publish(M.Event.ON_STAFF, nil, { kind = desk.kind, key = desk.key, verb = verb,
		citizenId = citizenId, by = desk.citizenId, grade = grade })
	OPX.Audit.Player(desk.player, 'business.' .. verb, ('%s:%s %s%s'):format(desk.kind, desk.key,
		safe(citizenId), grade ~= nil and (' grade ' .. grade) or ''), { kind = desk.kind, key = desk.key })
end

local function gradeName(kind, key, level)
	local grade = Access.Grade(kind, key, level)
	return grade and tostring(grade.name or level) or tostring(level)
end

-- ── the terminal ────────────────────────────────────────────────────────────

--- One desk as the client draws it. Reads the database (roster, balance).
local function deskView(desk)
	local kind, key, level = desk.kind, desk.key, desk.level
	local isBoss = Access.IsBoss(kind, key, level)
	local bank = Access.BankAuth(kind, key, level)
	local rules = Access.Rules(kind, key)
	local view = {
		kind = kind, key = key, label = Access.Label(kind, key), level = level,
		gradeName = gradeName(kind, key, level), isBoss = isBoss, bankAuth = bank,
		mayHire = Access.MayHire(kind, key, level), duty = isBoss and rules.duty,
		max = rules.maxEmployees, currency = Access.POCKET,
	}
	if isBoss or bank then
		local balance = Accounts.Balance(kind, key)
		view.balance = balance.ok and balance.value.balance or nil
		if Access.HISTORY_SHOWN > 0 then
			local history = Accounts.History(kind, key, Access.HISTORY_SHOWN)
			view.history = history.ok and history.value.rows or {}
		end
	end
	local list = roster(kind, key)
	view.count = list.ok and #list.value.rows or nil
	view.employees = {}
	if list.ok then
		for _, row in ipairs(list.value.rows) do
			if #view.employees >= Access.ROSTER_SHOWN then break end
			local self = row.citizenId == desk.citizenId
			local manage = isBoss and not self and Access.MayManage(level, row.grade)
			local up = Access.Step(kind, key, row.grade, 1)
			local down = Access.Step(kind, key, row.grade, -1)
			view.employees[#view.employees + 1] = {
				citizenId = row.citizenId, name = row.name, grade = row.grade,
				gradeName = gradeName(kind, key, row.grade), online = row.online, onDuty = row.onDuty,
				self = self or nil,
				fire = manage or nil,
				promote = (manage and up ~= nil and Access.MayGrant(level, up)) or nil,
				demote = (manage and down ~= nil) or nil,
				duty = (manage and view.duty and row.online and row.primary) or nil,
			}
		end
	end
	return view
end

--- Sends the terminal: every group the player may open (or one), refused when
--- there is none.
-- @author dop42
-- @param source integer
-- @param kind string|nil
-- @param key string|nil
-- @return boolean, string|nil
local function sendTerminal(source, kind, key)
	local data = dataOf(source)
	if data == nil then return false, 'no_character' end
	local wanted = {}
	if kind ~= nil then
		local desk, why = deskOf(source, kind, key)
		if desk == nil then return false, why end
		wanted[1] = desk
	else
		local blocked = false
		for _, entry in ipairs(Access.Desks(data)) do
			local desk, why = deskOf(source, entry.kind, entry.key)
			if desk ~= nil then wanted[#wanted + 1] = desk elseif why == 'office' then blocked = true end
		end
		if #wanted == 0 then return false, blocked and 'office' or 'not_boss' end
	end
	local desks = {}
	for index, desk in ipairs(wanted) do desks[index] = deskView(desk) end
	local current = dataOf(source)
	if current == nil or current.citizenId ~= data.citizenId then return false, 'no_character' end
	for _, desk in ipairs(wanted) do
		local fresh = deskOf(source, desk.kind, desk.key)
		if fresh == nil or fresh.level ~= desk.level then return false, 'not_boss' end
	end
	TriggerClientEvent(M.Event.SHOW, source, { desks = desks })
	return true
end

-- ── recruiting ──────────────────────────────────────────────────────────────

local function closeOffer(id, why)
	local offer = offers[id]
	if offer == nil then return end
	offers[id] = nil
	if offerOf[offer.target] == id then offerOf[offer.target] = nil end
	TriggerClientEvent(M.Event.OFFER, offer.target, { id = id, closed = true })
	if why ~= nil then
		tell(offer.boss, 'business.hire.' .. why, { name = offer.targetName }, 'warning')
	end
end

--- How many people a group employs now, or nil when the roster cannot be read.
local function headcount(kind, key)
	local list = roster(kind, key)
	if not list.ok then return nil end
	return #list.value.rows
end

--- The checks an offer passes when it is made AND when it is accepted.
local function hireable(desk, target, checkedCount)
	local rules = Access.Rules(desk.kind, desk.key)
	if not Access.MayHire(desk.kind, desk.key, desk.level) then return false, 'not_boss' end
	if Access.Grade(desk.kind, desk.key, rules.hireGrade) == nil then return false, 'bad_grade' end
	if not Access.IsBoss(desk.kind, desk.key, desk.level)
		and not Access.MayGrant(desk.level, rules.hireGrade) then
		return false, 'rank'
	end
	local data = dataOf(target)
	if data == nil then return false, 'no_target' end
	if data.citizenId == desk.citizenId then return false, 'self' end
	if heldGrade(data, desk.kind, desk.key) ~= nil then return false, 'already_member' end
	local close = near(standing(desk.player.PlayerData.source), standing(target), Access.HIRE_RADIUS)
	if not close then return false, 'too_far' end
	if rules.maxEmployees > 0 and not checkedCount then
		local count = headcount(desk.kind, desk.key)
		if count == nil then return false, 'roster_failed' end
		if count >= rules.maxEmployees then return false, 'full' end
		local fresh = deskOf(desk.data.source, desk.kind, desk.key)
		local current = dataOf(target)
		if fresh == nil or fresh.citizenId ~= desk.citizenId then return false, 'not_boss' end
		if current == nil or current.citizenId ~= data.citizenId then return false, 'no_target' end
		return hireable(fresh, target, true)
	end
	return true, nil, data, rules
end

--- A boss offers a nearby player a contract. They have to accept it.
-- @author dop42
-- @param source integer the boss
-- @param kind string
-- @param key string
-- @param target any the player id picked off the eye or the nearby list
-- @return boolean, string|nil
local function hire(source, kind, key, target)
	target = math.tointeger(tonumber(target))
	if target == nil or target < 1 then return false, 'no_target' end
	local desk, why = deskOf(source, kind, key)
	if desk == nil then return false, why end
	if offerOf[target] ~= nil then return false, 'offer_pending' end
	local ok, refusal, data, rules = hireable(desk, target)
	if not ok then return false, refusal end
	-- Checked again after the yields `hireable` made.
	if offerOf[target] ~= nil then return false, 'offer_pending' end

	nextOffer = nextOffer + 1
	local id = nextOffer
	local label = Access.Label(kind, key)
	offers[id] = {
		id = id, kind = kind, key = key, boss = source, bossCid = desk.citizenId,
		target = target, targetCid = data.citizenId, targetName = nameOf(data),
		grade = rules.hireGrade, expiresAt = OPX.Now() + Access.HIRE_TTL_S * 1000,
	}
	offerOf[target] = id
	TriggerClientEvent(M.Event.OFFER, target, { id = id, label = label,
		grade = gradeName(kind, key, rules.hireGrade), boss = nameOf(desk.data), ttl = Access.HIRE_TTL_S })
	tell(source, 'business.hire.sent', { name = nameOf(data), label = label }, 'info')
	OPX.Audit.Player(desk.player, 'business.offer', ('%s:%s to %s'):format(kind, key,
		safe(data.citizenId)), { kind = kind, key = key })
	return true
end

--- The recruit answers. A yes is checked again, all of it, then written.
-- @author dop42
-- @param source integer the recruit
-- @param id any
-- @param accept boolean
-- @return boolean, string|nil
local function answerOnce(source, id, accept)
	id = math.tointeger(tonumber(id))
	local offer = id and offers[id] or nil
	if offer == nil or offer.target ~= source then return false, 'no_offer' end
	local data = dataOf(source)
	if data == nil or data.citizenId ~= offer.targetCid then
		closeOffer(id, nil)
		return false, 'no_offer'
	end
	if OPX.Now() > offer.expiresAt then
		closeOffer(id, 'expired')
		return false, 'expired'
	end
	if accept ~= true then
		closeOffer(id, 'declined')
		tell(source, 'business.offer.declined', nil, 'info')
		return true
	end
	-- Taken off the table BEFORE any yield: a double click is one hire.
	offers[id] = nil
	offerOf[source] = nil

	local bossData = dataOf(offer.boss)
	if bossData == nil or bossData.citizenId ~= offer.bossCid then
		tell(source, 'business.refused.boss_gone', nil, 'error')
		return false, 'boss_gone'
	end
	local desk, why = deskOf(offer.boss, offer.kind, offer.key)
	if desk == nil then
		tell(offer.boss, 'business.hire.failed', { name = offer.targetName }, 'error')
		return false, why
	end
	local ok, refusal = hireable(desk, source)
	if not ok then
		tell(offer.boss, 'business.hire.failed', { name = offer.targetName }, 'error')
		return false, refusal
	end

	local done, code = withEmployee(offer.targetCid, function()
		local wrote
		if Access.HIRE_PRIMARY then
			wrote = call(offer.kind == Kind.JOB and 'SetJob' or 'SetGang', offer.targetCid, offer.key,
				offer.grade)
		else
			wrote = setGrade(offer.kind, offer.key, offer.targetCid, offer.grade, false)
		end
		if not wrote.ok then return false, wrote.error end
		return true
	end)
	if not done then
		tell(offer.boss, 'business.hire.failed', { name = offer.targetName }, 'error')
		return false, code
	end
	local label = Access.Label(offer.kind, offer.key)
	tell(source, 'business.offer.welcome', { label = label,
		grade = gradeName(offer.kind, offer.key, offer.grade) }, 'success')
	tell(offer.boss, 'business.hire.done', { name = offer.targetName, label = label }, 'success')
	staffEvent(desk, Verb.HIRE, offer.targetCid, offer.grade)
	return true
end

-- Hold the group's headcount read through the membership write: two recruits
-- accepting together must not both consume its final employee place.
local function answer(source, id, accept)
	local offer = offers[math.tointeger(tonumber(id))]
	if offer == nil then return false, 'no_offer' end
	local key = offer.kind .. ':' .. offer.key
	if hiring[key] then return false, 'busy' end
	hiring[key] = true
	local ok, done, why = pcall(answerOnce, source, id, accept)
	hiring[key] = nil
	if not ok then
		Open77.log.error('[business] accepting a hire raised: ' .. safe(done))
		return false, 'generic'
	end
	return done, why
end

--- Nearby players a boss could offer a contract to: ids and distances only.
local function nearby(source, kind, key)
	local desk, why = deskOf(source, kind, key)
	if desk == nil then return false, why end
	if not Access.MayHire(kind, key, desk.level) then return false, 'not_boss' end
	local here = standing(source)
	if here == nil then return false, 'too_far' end
	local api = characterApi()
	local rows = {}
	local ok, players = pcall(api.GetPlayers)
	for _, player in ipairs(ok and type(players) == 'table' and players or {}) do
		local data = type(player) == 'table' and player.PlayerData or nil
		local other = data and math.tointeger(tonumber(data.source)) or nil
		if other ~= nil and other ~= source and heldGrade(data, kind, key) == nil then
			local close, gap = near(here, standing(other), Access.HIRE_RADIUS)
			if close then rows[#rows + 1] = { target = other, metres = math.floor(gap * 10 + 0.5) / 10 } end
		end
		if #rows >= 12 then break end
	end
	table.sort(rows, function(a, b) return a.metres < b.metres end)
	TriggerClientEvent(M.Event.NEARBY, source, { kind = kind, key = key, rows = rows })
	return true
end

-- ── firing, promoting, demoting, clocking ───────────────────────────────────

local function manage(source, kind, key, citizenId, verb)
	citizenId = Access.CitizenId(citizenId)
	if citizenId == nil then return false, 'no_target' end
	local desk, why = deskOf(source, kind, key)
	if desk == nil then return false, why end
	if not Access.IsBoss(kind, key, desk.level) then return false, 'not_boss' end
	if citizenId == desk.citizenId then return false, 'self' end

	return withEmployee(citizenId, function()
		local member, missing = memberOf(kind, key, citizenId)
		if member == nil then return false, missing end
		-- The boss is read again AFTER the yields above: a boss demoted
		-- meanwhile acts with the grade they hold now.
		local fresh = deskOf(source, kind, key)
		if fresh == nil or fresh.citizenId ~= desk.citizenId
			or not Access.IsBoss(kind, key, fresh.level) then return false, 'not_boss' end
		if not Access.MayManage(fresh.level, member.grade) then return false, 'rank' end

		if verb == Verb.FIRE then
			local wrote = call(kind == Kind.JOB and 'RemovePlayerFromJob' or 'RemovePlayerFromGang',
				citizenId, key)
			if not wrote.ok then return false, wrote.error end
			staffEvent(fresh, verb, citizenId, nil)
			local live = onlineOf(citizenId)
			if live ~= nil then
				tell(live.PlayerData.source, 'business.staff.firedYou', { label = Access.Label(kind, key) },
					'warning')
			end
			return true
		end

		if verb == Verb.PROMOTE or verb == Verb.DEMOTE then
			local level = Access.Step(kind, key, member.grade, verb == Verb.PROMOTE and 1 or -1)
			if level == nil then return false, 'edge' end
			if verb == Verb.PROMOTE and not Access.MayGrant(fresh.level, level) then return false, 'rank' end
			local wrote = setGrade(kind, key, citizenId, level, member.primary)
			if not wrote.ok then return false, wrote.error end
			staffEvent(fresh, verb, citizenId, level)
			local live = onlineOf(citizenId)
			if live ~= nil then
				tell(live.PlayerData.source, verb == Verb.PROMOTE and 'business.staff.promotedYou'
					or 'business.staff.demotedYou', { label = Access.Label(kind, key),
					grade = gradeName(kind, key, level) }, verb == Verb.PROMOTE and 'success' or 'warning')
			end
			return true
		end

		if verb == Verb.DUTY then
			if kind ~= Kind.JOB or not Access.Rules(kind, key).duty then return false, 'no_duty' end
			if not member.online or not member.primary then return false, 'not_online' end
			local onDuty = type(member.data.job) == 'table' and member.data.job.onDuty == true
			local wrote = call('SetJobDuty', citizenId, not onDuty)
			if not wrote.ok then return false, wrote.error end
			staffEvent(fresh, verb, citizenId, nil)
			return true
		end
		return false, 'bad_request'
	end)
end

-- ── the treasury desk ───────────────────────────────────────────────────────

local function walletTransfer(source, kind, key, amount, depositing)
	amount = Access.Amount(amount)
	if amount == nil then return false, 'bad_amount' end
	local desk, why = deskOf(source, kind, key)
	if desk == nil then return false, why end
	if not Access.BankAuth(kind, key, desk.level) then return false, 'no_bank' end
	local api = characterApi()
	if type(api.AtomicMoney) ~= 'function' then return false, 'generic' end
	local player = api.GetPlayer(source)
	if not player or player.PlayerData.citizenId ~= desk.citizenId then return false, 'no_money' end
	local direction = depositing and 'deposit' or 'withdraw'
	local reason = ('business:%s:%s:%s'):format(direction, kind, key)
	local opId = Accounts.Mint(depositing and 'boss-dep' or 'boss-wdr')
	local answer = api.AtomicMoney(player, Access.POCKET, amount, depositing and 'remove' or 'add',
		reason, opId, function(context)
			context.publish = function()
				local receipt = M.Storage.Receipt(context.id)
				if receipt.ok and receipt.value then
					Accounts.WalletCommitted(kind, key, depositing and amount or -amount,
						tonumber(receipt.value.balance_after), reason, context.id, desk.citizenId)
				end
			end
			return function(operation)
				return M.Storage.WalletStatements(operation, kind, key, amount, depositing)
			end
		end)
	if not answer.ok then return false, answer.error end
	local receipt = M.Storage.Receipt(opId)
	local current = api.GetPlayer(source)
	if receipt.ok and receipt.value and current and current.PlayerData.citizenId == desk.citizenId then
		tell(source, depositing and 'business.bank.deposited' or 'business.bank.withdrew',
			{ amount = money(amount), balance = money(tonumber(receipt.value.balance_after) or 0) }, 'success')
	end
	return true
end

local function deposit(source, kind, key, amount)
	return walletTransfer(source, kind, key, amount, true)
end

local function withdraw(source, kind, key, amount)
	return walletTransfer(source, kind, key, amount, false)
end

-- ── the door ────────────────────────────────────────────────────────────────

local VERBS = {
	[Verb.HIRE] = function(source, kind, key, payload) return hire(source, kind, key, payload.target) end,
	[Verb.NEARBY] = function(source, kind, key) return nearby(source, kind, key) end,
	[Verb.FIRE] = function(source, kind, key, payload) return manage(source, kind, key, payload.citizenId, Verb.FIRE) end,
	[Verb.PROMOTE] = function(source, kind, key, payload)
		return manage(source, kind, key, payload.citizenId, Verb.PROMOTE)
	end,
	[Verb.DEMOTE] = function(source, kind, key, payload)
		return manage(source, kind, key, payload.citizenId, Verb.DEMOTE)
	end,
	[Verb.DUTY] = function(source, kind, key, payload) return manage(source, kind, key, payload.citizenId, Verb.DUTY) end,
	[Verb.DEPOSIT] = function(source, kind, key, payload) return deposit(source, kind, key, payload.amount) end,
	[Verb.WITHDRAW] = function(source, kind, key, payload) return withdraw(source, kind, key, payload.amount) end,
}

-- The verbs after which the terminal is drawn again, fresh.
local REDRAW = { fire = true, promote = true, demote = true, duty = true, deposit = true, withdraw = true }

--- Runs one verb for a connection, the way the network door does.
-- @author dop42
-- @param source integer
-- @param payload table { kind, key, verb, ... }
-- @return boolean, string|nil
local function act(source, payload)
	if type(payload) ~= 'table' then return false, 'bad_request' end
	local run = VERBS[payload.verb]
	if run == nil then return false, 'bad_request' end
	local kind, key = payload.kind, payload.key
	if not Access.ValidGroup(kind, key) then return false, 'bad_group' end
	local fields = {
		target = payload.target, citizenId = payload.citizenId, amount = payload.amount,
	}
	for name, value in pairs(fields) do
		if type(value) ~= 'string' and type(value) ~= 'number' then fields[name] = nil end
	end
	local ok, why = run(source, kind, key, fields)
	if ok and REDRAW[payload.verb] then
		if payload.verb ~= Verb.DEPOSIT and payload.verb ~= Verb.WITHDRAW then
			tell(source, 'business.staff.' .. payload.verb, nil, 'success')
		end
		sendTerminal(source, kind, key)
	end
	return ok, why
end

local function sweep()
	local now = OPX.Now()
	local lapsed = {}
	for id, offer in pairs(offers) do
		if now > offer.expiresAt then lapsed[#lapsed + 1] = id end
	end
	for _, id in ipairs(lapsed) do closeOffer(id, 'expired') end
end

-- ── the contracts ───────────────────────────────────────────────────────────

local function resolveData(player)
	if type(player) == 'table' and type(player.PlayerData) == 'table' then return player.PlayerData end
	if type(player) == 'string' then
		local live = onlineOf(player)
		return live and live.PlayerData or nil
	end
	return dataOf(player)
end

--- `business` v1: whether a player is a boss of a job (or of a gang, with
--- `kind = 'gang'`).
-- @author dop42
-- @param player Source|CitizenId|Player
-- @param job string
-- @param kind string|nil 'job' (default) | 'gang'
-- @return boolean
local function isBoss(player, job, kind)
	kind = kind == Kind.GANG and Kind.GANG or Kind.JOB
	local data = resolveData(player)
	if data == nil or not Access.ValidGroup(kind, job) then return false end
	local level = Access.Standing(data, kind, job)
	return level ~= nil and Access.IsBoss(kind, job, level)
end

--- Publishes `accounts` v1 and `business` v1.
-- @author dop42
function M.Api()
	OPX.Api.Provide('accounts', 1, {
		Balance = Accounts.Balance,
		Deposit = Accounts.Deposit,
		Withdraw = Accounts.Withdraw,
		Transfer = Accounts.Transfer,
		PayCitizen = Accounts.PayCitizen,
		PrepareTrade = Accounts.PrepareTrade,
		History = Accounts.History,
		-- Beyond v1, for a writer that banks into the same table on its own
		-- (the dealership): records the movement for the history and the bus.
		Note = Accounts.Note,
	})
	OPX.Api.Provide('business', 1, {
		IsBoss = isBoss,
		Employees = function(job, kind)
			kind = kind == Kind.GANG and Kind.GANG or Kind.JOB
			return roster(kind, job)
		end,
		-- Beyond v1: the desks a player may open, `{ kind, key, level }`.
		Desks = function(player) return Access.Desks(resolveData(player)) end,
	})
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Resets the state and contributes the treasury tables.
-- @author dop42
function M.Init()
	windows, offers, offerOf, nextOffer, changing, hiring = {}, {}, {}, 0, {}, {}
	Accounts.Reset()
	OPX.Schema.Add(M.Storage.SCHEMA)
	OPX.Schema.AddColumns(M.Storage.COLUMNS)
end

--- Wires the requests, the commands and the offer sweep.
-- @author dop42
function M.Start()
	for _, line in ipairs(Access.Problems()) do Open77.log.warn('[business] config: ' .. line) end

	RegisterNetEvent(M.Event.OPEN, function(payload)
		local source = tonumber(source) or 0
		if source <= 0 then return end
		if not allowed(source) then return refuse(source, 'too_fast') end
		local kind, key, office = nil, nil, nil
		if type(payload) == 'table' and payload.kind ~= nil then
			kind, key = payload.kind, payload.key
			if not Access.ValidGroup(kind, key) then return refuse(source, 'bad_group') end
			office = math.tointeger(tonumber(payload.office))
		end
		CreateThread(function()
			-- A request from an office eye row is honoured only standing there.
			if office ~= nil and not Access.AtOffice(kind, key, standing(source), office) then
				return refuse(source, 'office')
			end
			local ok, why = sendTerminal(source, kind, key)
			if not ok then refuse(source, why) end
		end)
	end)

	RegisterNetEvent(M.Event.ACT, function(payload)
		local source = tonumber(source) or 0
		if source <= 0 then return end
		if not allowed(source) then return refuse(source, 'too_fast') end
		if type(payload) ~= 'table' then return refuse(source, 'bad_request') end
		local copy = { verb = payload.verb, kind = payload.kind, key = payload.key,
			target = payload.target, citizenId = payload.citizenId, amount = payload.amount }
		CreateThread(function()
			local ok, why = act(source, copy)
			if not ok then refuse(source, why) end
		end)
	end)

	RegisterNetEvent(M.Event.ANSWER, function(payload)
		local source = tonumber(source) or 0
		if source <= 0 then return end
		if not allowed(source) then return refuse(source, 'too_fast') end
		if type(payload) ~= 'table' then return end
		local id, accept = payload.id, payload.accept == true
		CreateThread(function()
			local ok, why = answer(source, id, accept)
			if not ok then refuse(source, why) end
		end)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function()
		local source = tonumber(source) or 0
		windows[source] = nil
		local held = offerOf[source]
		if held ~= nil then closeOffer(held, 'expired') end
		local mine = {}
		for id, offer in pairs(offers) do
			if offer.boss == source then mine[#mine + 1] = id end
		end
		for _, id in ipairs(mine) do closeOffer(id, nil) end
	end)

	local commands = Access.COMMANDS
	if type(commands.BOSS) == 'string' and commands.BOSS ~= '' then
		OPX.Command.Register(commands.BOSS, { help = 'business.help.boss', cooldownMs = 750 },
			function(source)
				if source <= 0 then return end
				CreateThread(function()
					local ok, why = sendTerminal(source, nil, nil)
					if not ok then refuse(source, why) end
				end)
			end)
	end
	if type(commands.ACCOUNTS) == 'string' and commands.ACCOUNTS ~= '' then
		OPX.Command.Register(commands.ACCOUNTS, { restricted = true, help = 'business.help.accounts',
			params = { { name = 'job|gang', help = locale('business.help.kind') },
				{ name = 'name', help = locale('business.help.key') },
				{ name = 'deposit|withdraw', help = locale('business.help.verb') },
				{ name = 'amount', help = locale('business.help.amount') } } },
			function(source, args, raw)
				local kind, key, verb, amount = args[1], args[2], args[3], Access.Amount(args[4])
				CreateThread(function()
					local by = ('staff:%s'):format(tostring(source))
					local answer
					if verb == 'deposit' or verb == 'withdraw' then
						if amount == nil then
							answer = Result.Err('accounts.badAmount')
						elseif verb == 'deposit' then
							answer = Accounts.Deposit(kind, key, amount, 'staff:adjust', nil, by)
						else
							answer = Accounts.Withdraw(kind, key, amount, 'staff:adjust', nil, by)
						end
					else
						answer = Accounts.Balance(kind, key)
					end
					OPX.CommandNotice(source, raw, answer.ok and 'success' or 'error', answer.ok
						and locale('business.staff.balance', { kind = tostring(kind), key = tostring(key),
							balance = money(answer.value.balance) })
						or locale('business.staff.refused', { code = tostring(answer.error) }))
				end)
			end)
	end

	sweepJob = OPX.Scheduler.Every('business:offers', 5000, sweep)
end

--- Stops the sweep and drops the open offers.
-- @author dop42
function M.Stop()
	if sweepJob ~= nil then OPX.Scheduler.Cancel(sweepJob) sweepJob = nil end
	offers, offerOf = {}, {}
end

-- For the tests and for staff tooling inside this VM.
M.Server = {
	Act = act,
	Hire = hire,
	Answer = answer,
	Manage = manage,
	Deposit = deposit,
	Withdraw = withdraw,
	Terminal = sendTerminal,
	Roster = roster,
	Offers = function() return offers end,
	Sweep = sweep,
	IsBoss = isBoss,
}
