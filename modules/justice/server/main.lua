--- Justice, server side: the desk, the record, counsel, the court and the contract.
-- @author dop42
--
-- FOUR DOORS, EACH RE-READ FROM SCRATCH:
--
--   the desk     a citizen at a City Hall desk buys a licence (money first,
--                metadata second, card third -- a licence that cannot be
--                written gives the money back), reads their own record, pays
--                the bail a judge set on their warrant, dismisses their lawyer
--   the record   police and judges read anyone's; a lawyer reads a client's
--                (a counsel row the client consented to); nobody else
--   counsel      a lawyer offers, the citizen consents, a row is written; the
--                lawyer may then ask the court to expunge an entry
--   the court    a judge rules on expungements, signs warrants, sets bail,
--                opens a case and closes it with a verdict: a record entry and
--                a fine, billed through `invoices` when it is there
--
-- THE CONTRACT (`justice` v1) is what the police module calls: AddRecord,
-- GetRecord, HasWarrant, HasLicence, Licences, IssueLicence, RevokeLicence,
-- Crimes. Every function that reaches the database yields: call it on a
-- thread.

local M = OPX.Modules.Get('justice')
local Access = M.Access

local OWNER = 'justice'
local REQUEST_MS = 700
local MAX_INVITES = 64

local S = nil
local character = nil
local invites, inviteOf, serial = {}, {}, 0
local fines = {}
local busyCases = {}
local sweepJob = nil
local burnedSaid = false

-- Read at every use: the contracts are tables other modules own.
local function inventory() return OPX.Api.Get('inventory') end
local function accounts() return OPX.Api.Get('accounts') end
local function invoices() return OPX.Api.Get('invoices') end
local function police() return OPX.Api.Get('police') end
local function Storage() return M.Storage end

-- ── small reads ─────────────────────────────────────────────────────────────

--- Wall-clock seconds; process seconds where the host has none (the suite).
local function wall()
	local time = Open77 and Open77.time
	if type(time) == 'table' and type(time.unix) == 'function' then
		local ok, now = pcall(time.unix)
		if ok and type(now) == 'number' and now == now and now > 0 then return math.floor(now) end
	end
	return OPX.Now() // 1000
end

local function playerId(value)
	local id = math.tointeger(tonumber(value))
	if id == nil or id < 1 or id > 2147483647 then return nil end
	return id
end

local function pointOf(player)
	if playerId(player) == nil then return nil end
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y), OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end

local function apart(a, b)
	if a == nil or b == nil or a.bucket ~= b.bucket then return math.huge end
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function dataOf(player)
	if character == nil or playerId(player) == nil then return nil end
	local read, loaded = pcall(character.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	return loaded.PlayerData
end

local function sourceOf(citizenId)
	if character == nil or type(citizenId) ~= 'string' then return nil end
	local read, loaded = pcall(character.GetPlayerByCitizenId, citizenId)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	return playerId(loaded.PlayerData.source)
end

local function nameOf(data)
	local info = type(data) == 'table' and type(data.charInfo) == 'table' and data.charInfo or {}
	local full = ('%s %s'):format(tostring(info.firstName or ''), tostring(info.lastName or '')):gsub('^%s+', '')
		:gsub('%s+$', '')
	return OPX.Text.Clean(full ~= '' and full or nil, 64)
end

--- A citizen id a client typed, in its canonical form, or nil.
local function citizenOf(value)
	if type(value) ~= 'string' then return nil end
	local parsed = OPX.CitizenId.Parse(value)
	return parsed.ok and parsed.value or nil
end

local function now() return OPX.Now() end

local function answer(player, ok, code, extra)
	if playerId(player) == nil then return ok end
	local payload = type(extra) == 'table' and extra or {}
	payload.ok, payload.code = ok == true, code
	TriggerClientEvent(M.Event.ANSWER, player, payload)
	return ok
end

local function okResult(result) return type(result) == 'table' and result.ok == true end

-- ── the gate ────────────────────────────────────────────────────────────────

local function snapshotOf(data)
	if data == nil then return nil end
	return { job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil, atMs = now() }
end

--- Whether a character holds a role ('police', 'lawyer', 'judge').
local function holds(role, data)
	local requirement = S[role]
	if requirement == nil or data == nil then return false, 'not_allowed' end
	local ok, code = OPX.JobGate.Evaluate(requirement, snapshotOf(data), now(),
		{ maxAgeMs = 60000, membership = S.membership })
	if not ok then return false, code or 'not_allowed' end
	return true, nil
end

local function still(player, data, role)
	return data ~= nil and dataOf(player) == data and (role == nil or holds(role, data) == true)
end

-- ── money ───────────────────────────────────────────────────────────────────

local function balance(player, method)
	local read, value = pcall(character.GetMoney, player, method)
	return read and (OPX.Math.Finite(value) or 0) or 0
end

local function charge(player, method, amount, reason)
	if amount <= 0 then return true end
	local read, ok = pcall(character.RemoveMoney, player, method, amount, reason)
	return read and ok == true
end

local function refund(player, method, amount, reason, citizenId)
	if amount <= 0 then return end
	if citizenId ~= nil and type(character.AddMoneyOffline) == 'function' then
		pcall(character.AddMoneyOffline, citizenId, method, amount, reason)
		return
	end
	pcall(character.AddMoney, player, method, amount, reason)
end

--- Pays money that left a purse into the city treasury, or burns it (logged).
local function toCity(amount, reason, opId)
	if amount <= 0 then return true end
	local api = accounts()
	if S.account ~= nil and api ~= nil and type(api.Deposit) == 'function' then
		local read, result = pcall(api.Deposit, S.account.kind, S.account.key, amount, reason, opId)
		if read and okResult(result) then return true end
		Open77.log.warn(('[justice] the city account refused %d (%s): %s'):format(amount, reason,
			tostring(read and type(result) == 'table' and result.error or result)))
	elseif not burnedSaid then
		burnedSaid = true
		Open77.log.info('[justice] no accounts contract or CITY_ACCOUNT: fees, bail and fines leave the economy')
	end
	OPX.Audit.Log({ event = 'justice.burned', message = reason, data = { amount = amount } })
	return false
end

-- ── licences ────────────────────────────────────────────────────────────────

--- A citizen's licences metadata, online or not. Yields offline.
local function licencesOf(citizenId)
	local player = sourceOf(citizenId)
	if player ~= nil then
		local read, raw = pcall(character.GetMetadata, player, M.LICENCES_KEY)
		return read and Access.Held(raw) or {}, true
	end
	if type(character.ReadMetadata) ~= 'function' then return nil end
	local read = character.ReadMetadata(citizenId)
	if not okResult(read) or type(read.value) ~= 'table' then return nil end
	local metadata = type(read.value.metadata) == 'table' and read.value.metadata or {}
	return Access.Held(metadata[M.LICENCES_KEY]), false
end

local function writeLicences(citizenId, held)
	if type(character.WriteMetadata) ~= 'function' then return false end
	local written = character.WriteMetadata(citizenId, M.LICENCES_KEY, held)
	return okResult(written)
end

local function newSerial(kind)
	serial = serial % 0xffff + 1
	return ('NCC-%s-%04d-%04X'):format(kind:sub(1, 3):upper(), math.random(0, 9999), serial)
end

local function dropCards(holder, citizenId, kind)
	local api = inventory()
	if S.card == nil or api == nil or type(api.RemoveWhere) ~= 'function' then return end
	pcall(api.RemoveWhere, holder, S.card.name, { kind = kind, holder = citizenId })
end

local function giveCard(player, citizenId, name, licence, line)
	local api = inventory()
	if S.card == nil or api == nil or type(api.AddItem) ~= 'function' then return false end
	dropCards(citizenId, citizenId, licence.kind)
	local read, added = pcall(api.AddItem, citizenId, S.card.name, 1, {
		kind = licence.kind, label = licence.label, holder = citizenId, name = name or citizenId,
		serial = line.serial, expires = line.expires,
	})
	return read and okResult(added)
end

--- Writes a licence on a citizen (no fee): the staff and creator door. Yields.
-- @author dop42
local function issue(citizenId, kind, by)
	local licence = S.licences[kind]
	if licence == nil then return OPX.Result.Err('unknown_licence') end
	local held = licencesOf(citizenId)
	if held == nil then return OPX.Result.Err('no_citizen') end
	local line = { issued = wall(), expires = Access.Expiry(licence, wall()), serial = newSerial(kind),
		by = type(by) == 'string' and by:sub(1, 48) or 'city' }
	held[kind] = line
	if not writeLicences(citizenId, held) then return OPX.Result.Err('unavailable') end
	local player = sourceOf(citizenId)
	if player ~= nil then giveCard(player, citizenId, nameOf(dataOf(player)), licence, line) end
	TriggerEvent(M.Event.ON_LICENCE, citizenId, { kind = kind, action = 'issued', by = line.by })
	return OPX.Result.Ok(line)
end

--- Pulls a licence off a citizen, and their card with it. Yields.
-- @author dop42
local function revoke(citizenId, kind, reason, by)
	citizenId = citizenOf(citizenId)
	if citizenId == nil then return OPX.Result.Err('no_citizen') end
	if not Access.Key(kind) then return OPX.Result.Err('unknown_licence') end
	local held = licencesOf(citizenId)
	if held == nil then return OPX.Result.Err('no_citizen') end
	if held[kind] == nil then return OPX.Result.Err('not_held') end
	held[kind] = nil
	if not writeLicences(citizenId, held) then return OPX.Result.Err('unavailable') end
	dropCards(sourceOf(citizenId) or citizenId, citizenId, kind)
	OPX.Audit.Log({ event = 'justice.revoke', message = ('%s %s'):format(citizenId, kind),
		data = { reason = OPX.Text.Clean(reason, 96), by = OPX.Text.Clean(by, 48) } })
	TriggerEvent(M.Event.ON_LICENCE, citizenId, { kind = kind, action = 'revoked', by = OPX.Text.Clean(by, 48) })
	return OPX.Result.Ok(true)
end

-- ── the record ──────────────────────────────────────────────────────────────

--- Writes one entry for a citizen. Yields.
-- @author dop42
local function addRecord(citizenId, raw)
	citizenId = citizenOf(citizenId)
	if citizenId == nil then return OPX.Result.Err('no_citizen') end
	local entry, why = Access.Entry(S, raw)
	if entry == nil then return OPX.Result.Err(why) end
	local id = Storage().Add(citizenId, entry, wall())
	if id == nil then return OPX.Result.Err('unavailable') end
	OPX.Audit.Log({ event = 'justice.record', citizenId = citizenId,
		message = ('%s %s (%s)'):format(entry.kind, entry.code, entry.source),
		data = { id = id, fine = entry.fine, jail = entry.jail, officer = entry.officer } })
	TriggerEvent(M.Event.ON_RECORD, citizenId, { id = id, kind = entry.kind, code = entry.code,
		label = entry.label, fine = entry.fine, jail = entry.jail, source = entry.source })
	return OPX.Result.Ok({ id = id })
end

local function recordOf(citizenId, withExpunged)
	return Storage().List(citizenId, S.recordRows, withExpunged)
end

local function warrantsIn(rows)
	local out = {}
	for _, row in ipairs(rows) do
		if row.kind == M.Kind.WARRANT and row.active and not row.expunged then out[#out + 1] = row end
	end
	return out
end

local function views(rows)
	local out = {}
	for _, row in ipairs(rows) do out[#out + 1] = Access.View(row) end
	return out
end

-- ── the desk ────────────────────────────────────────────────────────────────

local function atDesk(player, key)
	local desk = type(key) == 'string' and S.desks[key] or nil
	if desk == nil then return nil, 'no_desk' end
	local here = pointOf(player)
	if here == nil or apart(here, { x = desk.x, y = desk.y, z = desk.z, bucket = desk.bucket })
		> OPX.Spots.ServerReach(desk.radius) then
		return nil, 'not_at_desk'
	end
	if OPX.Life ~= nil and OPX.Life.Down(player) == true then return nil, 'player_down' end
	return desk, nil
end

--- What a citizen sees at a desk: licences, their record, warrants, counsel.
-- @author dop42
function M.OpenDesk(player, key)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data = dataOf(player)
	if data == nil then return answer(player, false, 'no_character'), 'no_character' end
	local desk, why = atDesk(player, key)
	if desk == nil then return answer(player, false, why), why end
	local cid = data.citizenId
	local held = licencesOf(cid) or {}
	local at = wall()
	local licences = {}
	for _, licence in ipairs(S.licenceList) do
		local line = held[licence.kind]
		licences[#licences + 1] = { kind = licence.kind, label = licence.label, fee = licence.fee,
			days = licence.days, clean = licence.clean, state = Access.State(line, at),
			expires = line and line.expires or nil }
	end
	local rows = recordOf(cid, false)
	if rows == nil then return answer(player, false, 'unavailable'), 'unavailable' end
	local counsel = Storage().Counsel(cid)
	if not still(player, data) then return false, 'no_character' end
	local payload = {
		key = desk.key, label = desk.label, money = S.money, now = at, licences = licences,
		record = views(rows), warrants = views(warrantsIn(rows)),
		counsel = counsel and { name = counsel.lawyerName or counsel.lawyer, since = counsel.since } or nil,
	}
	TriggerClientEvent(M.Event.DESK_DATA, player, payload)
	return true, payload
end

--- Buys a licence at a desk.
-- @author dop42
function M.Buy(player, key, kind)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data = dataOf(player)
	if data == nil then return answer(player, false, 'no_character'), 'no_character' end
	local desk, why = atDesk(player, key)
	if desk == nil then return answer(player, false, why), why end
	local licence = type(kind) == 'string' and S.licences[kind] or nil
	if licence == nil then return answer(player, false, 'unknown_licence'), 'unknown_licence' end
	local cid = data.citizenId
	local held = licencesOf(cid)
	if held == nil then return answer(player, false, 'unavailable'), 'unavailable' end
	local at = wall()
	if Access.State(held[kind], at) == 'valid' then
		return answer(player, false, 'already_held', { licence = licence.label }), 'already_held'
	end
	if licence.clean then
		local clean, code = Access.Clean(recordOf(cid, false), at, S.cleanDays)
		if not clean then return answer(player, false, code, { licence = licence.label }), code end
	end
	if not still(player, data) then return false, 'no_character' end
	if balance(player, S.money) < licence.fee then
		return answer(player, false, 'not_enough_money', { fee = licence.fee }), 'not_enough_money'
	end
	local reason = 'justice:licence:' .. kind
	if not charge(player, S.money, licence.fee, reason) then
		return answer(player, false, 'not_enough_money', { fee = licence.fee }), 'not_enough_money'
	end
	local line = { issued = at, expires = Access.Expiry(licence, at), serial = newSerial(kind), by = desk.key }
	held[kind] = line
	if not writeLicences(cid, held) then
		refund(player, S.money, licence.fee, reason .. ':refund', cid)
		return answer(player, false, 'unavailable'), 'unavailable'
	end
	local carded = giveCard(player, cid, nameOf(data), licence, line)
	toCity(licence.fee, reason, 'justice-licence-' .. line.serial)
	OPX.Audit.Log({ event = 'justice.licence', source = player, citizenId = cid,
		message = ('%s for %d at %s'):format(kind, licence.fee, desk.key),
		data = { serial = line.serial, expires = line.expires, card = carded } })
	TriggerEvent(M.Event.ON_LICENCE, cid, { kind = kind, action = 'issued', by = desk.key })
	return answer(player, true, carded and 'bought' or 'bought_no_card',
		{ licence = licence.label, fee = licence.fee, serial = line.serial }), line
end

--- Pays the bail on one's own active warrant, at a desk.
-- @author dop42
function M.PayBail(player, key, id)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data = dataOf(player)
	if data == nil then return answer(player, false, 'no_character'), 'no_character' end
	local desk, why = atDesk(player, key)
	if desk == nil then return answer(player, false, why), why end
	id = math.tointeger(tonumber(id))
	if id == nil or id < 1 then return answer(player, false, 'invalid'), 'invalid' end
	local row = Storage().Get(id)
	if not still(player, data) then return false, 'no_character' end
	if row == nil or row.citizen ~= data.citizenId or row.kind ~= M.Kind.WARRANT or not row.active then
		return answer(player, false, 'invalid'), 'invalid'
	end
	if row.bail <= 0 then return answer(player, false, 'no_bail'), 'no_bail' end
	local reason = 'justice:bail:' .. id
	if balance(player, S.money) < row.bail or not charge(player, S.money, row.bail, reason) then
		return answer(player, false, 'not_enough_money', { fee = row.bail }), 'not_enough_money'
	end
	if not Storage().PayBail(id, data.citizenId, row.bail) then
		refund(player, S.money, row.bail, reason .. ':refund', data.citizenId)
		return answer(player, false, 'invalid'), 'invalid'
	end
	toCity(row.bail, reason, 'justice-bail-' .. id)
	OPX.Audit.Log({ event = 'justice.bail', source = player, citizenId = data.citizenId,
		message = ('warrant %d bailed for %d'):format(id, row.bail) })
	return answer(player, true, 'bailed', { fee = row.bail }), true
end

--- Ends one's own representation, at a desk.
-- @author dop42
function M.Dismiss(player, key)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data = dataOf(player)
	if data == nil then return answer(player, false, 'no_character'), 'no_character' end
	local desk, why = atDesk(player, key)
	if desk == nil then return answer(player, false, why), why end
	local counsel = Storage().Counsel(data.citizenId)
	if counsel == nil then return answer(player, false, 'no_counsel'), 'no_counsel' end
	Storage().DropCounsel(data.citizenId)
	answer(sourceOf(counsel.lawyer), true, 'client_left', { name = nameOf(data) or data.citizenId })
	OPX.Audit.Log({ event = 'justice.counsel', source = player, citizenId = data.citizenId,
		message = 'dismissed ' .. tostring(counsel.lawyer) })
	return answer(player, true, 'dismissed'), true
end

-- ── reading a record ────────────────────────────────────────────────────────

--- Sends a record to police, a judge, or the citizen's own lawyer.
-- @author dop42
-- @param who integer|string a player id, or a citizen id
function M.ViewRecord(player, who)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data = dataOf(player)
	if data == nil then return answer(player, false, 'no_character'), 'no_character' end
	local cid, name
	if type(who) == 'string' then
		cid = citizenOf(who)
	elseif math.type(who) == 'integer' then
		local target = dataOf(who)
		cid, name = target and target.citizenId or nil, target and nameOf(target) or nil
	end
	if cid == nil then return answer(player, false, 'no_citizen'), 'no_citizen' end
	local viewer
	if holds('judge', data) then
		viewer = 'judge'
	elseif holds('police', data) then
		viewer = 'police'
	elseif holds('lawyer', data) then
		local counsel = Storage().Counsel(cid)
		if counsel == nil or counsel.lawyer ~= data.citizenId then
			return answer(player, false, 'not_your_client'), 'not_your_client'
		end
		viewer, name = 'lawyer', name or counsel.clientName
	else
		return answer(player, false, 'not_allowed'), 'not_allowed'
	end
	if name == nil then
		local online = sourceOf(cid)
		name = online and nameOf(dataOf(online)) or nil
	end
	local rows = recordOf(cid, viewer == 'judge')
	if rows == nil then return answer(player, false, 'unavailable'), 'unavailable' end
	if not still(player, data, viewer) then return false, 'not_allowed' end
	if viewer == 'lawyer' then
		local counsel = Storage().Counsel(cid)
		if counsel == nil or counsel.lawyer ~= data.citizenId or not still(player, data, viewer) then
			return false, 'not_your_client'
		end
	end
	local payload = { citizenId = cid, name = name, viewer = viewer, now = wall(), rows = views(rows),
		warrants = #warrantsIn(rows) }
	TriggerClientEvent(M.Event.RECORD_DATA, player, payload)
	return true, payload
end

-- ── counsel ─────────────────────────────────────────────────────────────────

local function dropInvite(invite)
	invites[invite.id] = nil
	if inviteOf[invite.target] == invite.id then inviteOf[invite.target] = nil end
	if inviteOf[invite.lawyer] == invite.id then inviteOf[invite.lawyer] = nil end
end

--- A lawyer offers to represent a citizen standing close.
-- @author dop42
function M.Offer(lawyer, target)
	if OPX.Cooling(lawyer, 'justice.request', REQUEST_MS) then return answer(lawyer, false, 'too_fast'), 'too_fast' end
	local data = dataOf(lawyer)
	if data == nil then return answer(lawyer, false, 'no_character'), 'no_character' end
	local allowed, code = holds('lawyer', data)
	if not allowed then return answer(lawyer, false, code), code end
	target = playerId(target)
	local client = target and dataOf(target) or nil
	if client == nil then return answer(lawyer, false, 'no_citizen'), 'no_citizen' end
	if target == lawyer then return answer(lawyer, false, 'self'), 'self' end
	if apart(pointOf(lawyer), pointOf(target)) > OPX.Spots.ServerReach(S.lawyerReach) then
		return answer(lawyer, false, 'too_far'), 'too_far'
	end
	if inviteOf[lawyer] ~= nil or inviteOf[target] ~= nil then return answer(lawyer, false, 'busy'), 'busy' end
	if OPX.Table.Count(invites) >= MAX_INVITES then return answer(lawyer, false, 'busy'), 'busy' end
	local counsel = Storage().Counsel(client.citizenId)
	if not still(lawyer, data, 'lawyer') or dataOf(target) ~= client or
		apart(pointOf(lawyer), pointOf(target)) > OPX.Spots.ServerReach(S.lawyerReach) then
		return false, 'expired'
	end
	if inviteOf[lawyer] ~= nil or inviteOf[target] ~= nil then return answer(lawyer, false, 'busy'), 'busy' end
	if counsel ~= nil and counsel.lawyer == data.citizenId then
		return answer(lawyer, false, 'already_client'), 'already_client'
	end
	serial = serial % 0xffff + 1
	local id = ('jc-%06x-%04x'):format(math.random(0, 0xffffff), serial)
	local invite = { id = id, lawyer = lawyer, target = target, lawyerCid = data.citizenId,
		lawyerName = nameOf(data), clientCid = client.citizenId, clientName = nameOf(client),
		untilMs = now() + S.consentMs }
	invites[id] = invite
	inviteOf[lawyer], inviteOf[target] = id, id
	TriggerClientEvent(M.Event.INVITE, target, { id = id, lawyer = invite.lawyerName or invite.lawyerCid,
		ms = S.consentMs, replaces = counsel ~= nil and (counsel.lawyerName or counsel.lawyer) or nil })
	return answer(lawyer, true, 'offered', { name = invite.clientName or invite.clientCid }), id
end

--- The citizen's answer to an offer of representation.
-- @author dop42
function M.Consent(player, id, accepted)
	local invite = type(id) == 'string' and invites[id] or nil
	if invite == nil or invite.target ~= player then return false, 'invalid' end
	dropInvite(invite)
	if now() >= invite.untilMs or
		apart(pointOf(invite.lawyer), pointOf(player)) > OPX.Spots.ServerReach(S.lawyerReach) then
		return answer(player, false, 'expired'), 'expired'
	end
	if not accepted then
		answer(invite.lawyer, false, 'declined')
		return answer(player, true, 'you_declined'), 'declined'
	end
	local lawyerData, clientData = dataOf(invite.lawyer), dataOf(player)
	if lawyerData == nil or lawyerData.citizenId ~= invite.lawyerCid or not holds('lawyer', lawyerData)
		or clientData == nil or clientData.citizenId ~= invite.clientCid then
		return answer(player, false, 'expired'), 'expired'
	end
	local written = Storage().SetCounsel({ client = invite.clientCid, clientName = invite.clientName,
		lawyer = invite.lawyerCid, lawyerName = invite.lawyerName, since = wall() })
	if not written then
		answer(invite.lawyer, false, 'unavailable')
		return answer(player, false, 'unavailable'), 'unavailable'
	end
	OPX.Audit.Log({ event = 'justice.counsel', source = player, citizenId = invite.clientCid,
		message = 'represented by ' .. invite.lawyerCid })
	answer(invite.lawyer, true, 'retained', { name = invite.clientName or invite.clientCid })
	return answer(player, true, 'represented', { name = invite.lawyerName or invite.lawyerCid }), true
end

-- ── the office ──────────────────────────────────────────────────────────────

--- The lawyer's client file or the judge's bench.
-- @author dop42
function M.Office(player)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data = dataOf(player)
	if data == nil then return answer(player, false, 'no_character'), 'no_character' end
	local payload
	if holds('judge', data) then
		local crimes, licences = {}, {}
		for _, crime in ipairs(S.crimeList) do
			crimes[#crimes + 1] = { code = crime.code, label = crime.label, fine = crime.fine, jail = crime.jail }
		end
		for _, licence in ipairs(S.licenceList) do licences[#licences + 1] = { kind = licence.kind, label = licence.label } end
		local pending = {}
		for _, row in ipairs(Storage().Pending(S.recordRows)) do
			local view = Access.View(row)
			view.citizenId = row.citizen
			pending[#pending + 1] = view
		end
		local warrants = {}
		for _, row in ipairs(Storage().Warrants(S.recordRows)) do
			local view = Access.View(row)
			view.citizenId = row.citizen
			warrants[#warrants + 1] = view
		end
		payload = { role = 'judge', now = wall(), pending = pending, warrants = warrants,
			cases = Storage().Cases(S.maxCases), crimes = crimes, licences = licences,
			maxFine = S.maxFine, maxJail = S.maxJail, maxBail = S.maxBail }
	elseif holds('lawyer', data) then
		payload = { role = 'lawyer', now = wall(), clients = Storage().Clients(data.citizenId, S.maxClients) }
	else
		return answer(player, false, 'not_allowed'), 'not_allowed'
	end
	if not still(player, data, payload.role) then return false, 'not_allowed' end
	TriggerClientEvent(M.Event.OFFICE_DATA, player, payload)
	return true, payload
end

--- A lawyer asks the court to expunge an entry of a client's record.
-- @author dop42
function M.Expunge(player, id)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data = dataOf(player)
	if data == nil then return answer(player, false, 'no_character'), 'no_character' end
	local allowed, code = holds('lawyer', data)
	if not allowed then return answer(player, false, code), code end
	id = math.tointeger(tonumber(id))
	local row = id and id > 0 and Storage().Get(id) or nil
	if row == nil then return answer(player, false, 'invalid'), 'invalid' end
	local counsel = Storage().Counsel(row.citizen)
	if counsel == nil or counsel.lawyer ~= data.citizenId then
		return answer(player, false, 'not_your_client'), 'not_your_client'
	end
	if row.active then return answer(player, false, 'warrant_active'), 'warrant_active' end
	if not Storage().Request(id, row.citizen, data.citizenId) then
		return answer(player, false, 'already_requested'), 'already_requested'
	end
	OPX.Audit.Log({ event = 'justice.expungeRequest', source = player, citizenId = row.citizen,
		message = ('entry %d'):format(id) })
	return answer(player, true, 'requested'), true
end

local function judge(player)
	local data = dataOf(player)
	if data == nil then return nil, 'no_character' end
	local allowed, code = holds('judge', data)
	if not allowed then return nil, code end
	return data, nil
end

--- A judge rules on an expungement request.
-- @author dop42
function M.Rule(player, id, approved)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data, why = judge(player)
	if data == nil then return answer(player, false, why), why end
	id = math.tointeger(tonumber(id))
	local row = id and id > 0 and Storage().Get(id) or nil
	if row == nil or row.expunge ~= 'pending' then return answer(player, false, 'invalid'), 'invalid' end
	if not Storage().Rule(id, approved == true) then return answer(player, false, 'invalid'), 'invalid' end
	OPX.Audit.Log({ event = 'justice.rule', source = player, citizenId = row.citizen,
		message = ('entry %d %s'):format(id, approved and 'expunged' or 'denied') })
	answer(sourceOf(row.expungeBy), true, approved and 'expunge_approved' or 'expunge_denied',
		{ label = row.label })
	return answer(player, true, approved and 'ruled_approved' or 'ruled_denied', { label = row.label }), true
end

--- A judge signs a warrant: `{ citizenId, reason, bail }`.
-- @author dop42
function M.Warrant(player, payload)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data, why = judge(player)
	if data == nil then return answer(player, false, why), why end
	if type(payload) ~= 'table' then return answer(player, false, 'invalid'), 'invalid' end
	local cid = citizenOf(payload.citizenId)
	if cid == nil or licencesOf(cid) == nil then return answer(player, false, 'no_citizen'), 'no_citizen' end
	local bail = payload.bail == nil and 0 or Access.Amount(payload.bail, S.maxBail)
	if bail == nil then return answer(player, false, 'bad_amount'), 'bad_amount' end
	local result = addRecord(cid, { kind = M.Kind.WARRANT, code = 'warrant',
		label = OPX.Text.Clean(payload.reason, 96) or 'Warrant', bail = bail, officer = data.citizenId,
		officerName = nameOf(data), source = 'court' })
	if not okResult(result) then return answer(player, false, tostring(result.error)), result.error end
	return answer(player, true, 'warrant_signed', { citizen = cid }), result.value.id
end

--- A judge sets the bail on a warrant, or lifts it.
-- @author dop42
function M.SetBail(player, id, bail, lift)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data, why = judge(player)
	if data == nil then return answer(player, false, why), why end
	id = math.tointeger(tonumber(id))
	if id == nil or id < 1 then return answer(player, false, 'invalid'), 'invalid' end
	if lift == true then
		if not Storage().Lift(id) then return answer(player, false, 'invalid'), 'invalid' end
		OPX.Audit.Log({ event = 'justice.warrantLifted', source = player, message = ('warrant %d'):format(id) })
		return answer(player, true, 'warrant_lifted'), true
	end
	local amount = Access.Amount(bail, S.maxBail)
	if amount == nil then return answer(player, false, 'bad_amount'), 'bad_amount' end
	if not Storage().SetBail(id, amount) then return answer(player, false, 'invalid'), 'invalid' end
	OPX.Audit.Log({ event = 'justice.bailSet', source = player, message = ('warrant %d bail %d'):format(id, amount) })
	return answer(player, true, 'bail_set', { fee = amount }), true
end

--- A judge opens a case: `{ citizenId, code, summary }`.
-- @author dop42
function M.OpenCase(player, payload)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data, why = judge(player)
	if data == nil then return answer(player, false, why), why end
	if type(payload) ~= 'table' then return answer(player, false, 'invalid'), 'invalid' end
	local cid = citizenOf(payload.citizenId)
	if cid == nil or licencesOf(cid) == nil then return answer(player, false, 'no_citizen'), 'no_citizen' end
	local crime = type(payload.code) == 'string' and S.crimes[payload.code] or nil
	if crime == nil then return answer(player, false, 'bad_code'), 'bad_code' end
	local online = sourceOf(cid)
	local id = Storage().OpenCase({ defendant = cid, defendantName = online and nameOf(dataOf(online)) or nil,
		judge = data.citizenId, judgeName = nameOf(data), code = crime.code,
		summary = OPX.Text.Clean(payload.summary, 255) }, wall())
	if id == nil then return answer(player, false, 'unavailable'), 'unavailable' end
	OPX.Audit.Log({ event = 'justice.case', source = player, citizenId = cid,
		message = ('case %d: %s'):format(id, crime.code) })
	return answer(player, true, 'case_opened', { case = id }), id
end

--- Sends a court fine: an invoice when `invoices` is there, else straight from
--- the bank of a defendant who is in the city; unpaid otherwise (on the record).
local function billFine(judgePlayer, defendantCid, amount, recordId, label)
	local target = sourceOf(defendantCid)
	if amount <= 0 or target == nil then return 'unpaid' end
	local api = invoices()
	if api ~= nil and type(api.Issue) == 'function' then
		local read, issued = pcall(api.Issue, { issuer = judgePlayer, target = target, amount = amount,
			reason = label, cutPct = 0, source = 'justice',
			account = S.account and { kind = S.account.kind, key = S.account.key } or nil })
		if read and okResult(issued) and type(issued.value) == 'table' and issued.value.id ~= nil then
			if OPX.Table.Count(fines) < 512 then fines[tostring(issued.value.id)] = recordId end
			return 'invoiced'
		end
		return 'unpaid'
	end
	local reason = 'justice:fine:' .. tostring(recordId)
	if balance(target, 'BANK') >= amount and charge(target, 'BANK', amount, reason) then
		Storage().Paid(recordId)
		toCity(amount, reason, 'justice-fine-' .. tostring(recordId))
		answer(target, true, 'fined', { fee = amount })
		return 'paid'
	end
	return 'unpaid'
end

--- A judge closes a case: `{ caseId, verdict = 'guilty'|'acquitted', fine, jail, notes }`.
-- @author dop42
function M.Verdict(player, payload)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data, why = judge(player)
	if data == nil then return answer(player, false, why), why end
	if type(payload) ~= 'table' then return answer(player, false, 'invalid'), 'invalid' end
	local caseId = math.tointeger(tonumber(payload.caseId))
	local verdict = payload.verdict
	if caseId == nil or caseId < 1 or (verdict ~= 'guilty' and verdict ~= 'acquitted') then
		return answer(player, false, 'invalid'), 'invalid'
	end
	local fine = payload.fine == nil and 0 or Access.Amount(payload.fine, S.maxFine)
	local jail = payload.jail == nil and 0 or Access.Amount(payload.jail, S.maxJail)
	if fine == nil or jail == nil then return answer(player, false, 'bad_amount'), 'bad_amount' end
	if busyCases[caseId] then return answer(player, false, 'busy'), 'busy' end
	busyCases[caseId] = true
	local ok, result, extra = pcall(function()
		local case = Storage().Case(caseId)
		if case == nil or case.state ~= 'open' then return 'invalid' end
		if not still(player, data, 'judge') then return 'no_character' end
		if verdict == 'acquitted' and not Storage().CloseCase(caseId, verdict, nil, wall()) then return 'invalid' end
		OPX.Audit.Log({ event = 'justice.verdict', source = player, citizenId = case.defendant,
			message = ('case %d %s fine %d jail %d'):format(caseId, verdict, fine, jail) })
		if verdict == 'acquitted' then return nil, { verdict = verdict } end
		local crime = S.crimes[case.code]
		local entry, entryError = Access.Entry(S, { kind = M.Kind.VERDICT, code = case.code,
			label = crime and crime.label or case.code, fine = fine, jail = jail, officer = data.citizenId,
			officerName = nameOf(data), notes = OPX.Text.Clean(payload.notes, 255), source = 'court' })
		if entry == nil then return entryError end
		local recordId = Storage().Convict(caseId, case.defendant, entry, wall())
		if recordId == nil then return 'unavailable' end
		TriggerEvent(M.Event.ON_RECORD, case.defendant, { id = recordId, kind = entry.kind, code = entry.code,
			label = entry.label, fine = entry.fine, jail = entry.jail, source = entry.source })
		local billed = billFine(player, case.defendant, fine, recordId,
			crime and crime.label or case.code)
		local jailed = false
		local target = sourceOf(case.defendant)
		local api = police()
		if jail > 0 and target ~= nil and api ~= nil and type(api.Jail) == 'function' then
			local read, sent = pcall(api.Jail, target, { minutes = jail, reason = crime and crime.label or case.code,
				by = data.citizenId, source = 'justice' })
			jailed = read and (sent == true or okResult(sent))
		end
		return nil, { verdict = verdict, billed = billed, jailed = jailed, record = recordId }
	end)
	busyCases[caseId] = nil
	if not ok then
		Open77.log.error('[justice] a verdict raised: ' .. tostring(result))
		return answer(player, false, 'unavailable'), 'unavailable'
	end
	if result ~= nil then return answer(player, false, result), result end
	local code = extra.verdict == 'acquitted' and 'acquitted' or ('guilty_' .. extra.billed)
	return answer(player, true, code, { fee = fine, jail = jail, jailed = extra.jailed }), extra
end

--- A judge revokes a licence: `{ citizenId, kind, reason }`.
-- @author dop42
function M.Revoke(player, payload)
	if OPX.Cooling(player, 'justice.request', REQUEST_MS) then return answer(player, false, 'too_fast'), 'too_fast' end
	local data, why = judge(player)
	if data == nil then return answer(player, false, why), why end
	if type(payload) ~= 'table' or type(payload.kind) ~= 'string' or S.licences[payload.kind] == nil then
		return answer(player, false, 'unknown_licence'), 'unknown_licence'
	end
	local result = revoke(payload.citizenId, payload.kind, payload.reason, data.citizenId)
	if not okResult(result) then return answer(player, false, tostring(result.error)), result.error end
	answer(sourceOf(citizenOf(payload.citizenId)), false, 'licence_revoked',
		{ licence = S.licences[payload.kind].label })
	return answer(player, true, 'revoked', { licence = S.licences[payload.kind].label }), true
end

-- ── housekeeping ────────────────────────────────────────────────────────────

local function sweep()
	local at = now()
	local expired = {}
	for _, invite in pairs(invites) do
		if at > invite.untilMs then expired[#expired + 1] = invite end
	end
	for _, invite in ipairs(expired) do
		dropInvite(invite)
		answer(invite.lawyer, false, 'expired')
	end
end

local function left(id)
	local player = playerId(id)
	local invite = player and invites[inviteOf[player] or ''] or nil
	if invite ~= nil then
		dropInvite(invite)
		answer(player == invite.lawyer and invite.target or invite.lawyer, false, 'expired')
	end
end

local function onInvoicePaid(_, data)
	if type(data) ~= 'table' or data.source ~= 'justice' or data.id == nil then return end
	local recordId = fines[tostring(data.id)]
	if recordId == nil then return end
	fines[tostring(data.id)] = nil
	CreateThread(function() Storage().Paid(recordId) end)
end

local function onInvoiceGone(_, data)
	if type(data) == 'table' and data.source == 'justice' and data.id ~= nil then fines[tostring(data.id)] = nil end
end

local function report(source)
	local lines = {}
	for _, desk in ipairs(S.deskList) do
		lines[#lines + 1] = ('%s "%s" at %.1f, %.1f, %.1f r=%.1f bucket=%d'):format(desk.key, desk.label,
			desk.x, desk.y, desk.z, desk.radius, desk.bucket)
	end
	for _, key in ipairs(S.placeholders) do lines[#lines + 1] = key .. ' DISABLED: not surveyed yet (0,0,0)' end
	for _, line in ipairs(S.problems) do lines[#lines + 1] = 'REFUSED: ' .. line end
	lines[#lines + 1] = ('%d desk(s) open, %d licence(s), %d crime code(s); city account: %s'):format(#S.deskList,
		#S.licenceList, #S.crimeList, S.account and (S.account.kind .. ':' .. S.account.key) or 'none (burned)')
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

local function capture(source, args)
	local player = playerId(source)
	local key = args[1]
	if player == nil or not Access.Key(key) then
		return OPX.CommandResult(source, false, 'usage (in game): <desk key>')
	end
	local at = pointOf(player)
	if at == nil then return OPX.CommandResult(source, false, 'no position') end
	OPX.CommandResult(source, true, ('%s = { LABEL = \'...\', DESK = { X = %.2f, Y = %.2f, Z = %.2f }, RADIUS = 2.0, BUCKET = %d },')
		:format(key, at.x, at.y, at.z, at.bucket))
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Reads the config and contributes the three tables. Never yields.
-- @author dop42
function M.Init()
	invites, inviteOf, serial, fines, busyCases, burnedSaid = {}, {}, 0, {}, {}, false
	S = Access.Read(M.Settings)
	M.S = S
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the `justice` contract the police (and creators) call.
-- @author dop42
function M.Api()
	OPX.Api.Provide('justice', 1, {
		--- `(citizenId, { code, label?, kind?, fine?, jail?, bail?, officer?, officerName?, notes?,
		--- source? = 'police'|'court'|'staff'|'other', paid?, felony? })` -> Result{ id }. Yields.
		AddRecord = function(citizenId, entry) return addRecord(citizenId, entry) end,
		--- `(citizenId, { expunged? })` -> Result{ rows, warrants }. Yields.
		GetRecord = function(citizenId, options)
			local cid = citizenOf(citizenId)
			if cid == nil then return OPX.Result.Err('no_citizen') end
			local rows = recordOf(cid, type(options) == 'table' and options.expunged == true)
			if rows == nil then return OPX.Result.Err('unavailable') end
			return OPX.Result.Ok({ rows = views(rows), warrants = views(warrantsIn(rows)) })
		end,
		--- `(citizenId)` -> Result boolean. Yields.
		HasWarrant = function(citizenId)
			local cid = citizenOf(citizenId)
			if cid == nil then return OPX.Result.Err('no_citizen') end
			local rows = recordOf(cid, false)
			if rows == nil then return OPX.Result.Err('unavailable') end
			return OPX.Result.Ok(#warrantsIn(rows) > 0)
		end,
		--- `(citizenId, kind)` -> boolean, state ('valid'|'expired'|'none'). Yields offline.
		HasLicence = function(citizenId, kind)
			local cid = citizenOf(citizenId)
			if cid == nil or not Access.Key(kind) then return false, 'none' end
			local held = licencesOf(cid)
			local state = Access.State(held and held[kind] or nil, wall())
			return state == 'valid', state
		end,
		--- `(citizenId)` -> Result{ kind -> { issued, expires, serial, by, state } }. Yields offline.
		Licences = function(citizenId)
			local cid = citizenOf(citizenId)
			local held = cid and licencesOf(cid) or nil
			if held == nil then return OPX.Result.Err('no_citizen') end
			local at = wall()
			for _, line in pairs(held) do line.state = Access.State(line, at) end
			return OPX.Result.Ok(held)
		end,
		--- `(citizenId, kind, by?)` -> Result line. No fee: staff and creators. Yields.
		IssueLicence = function(citizenId, kind, by)
			local cid = citizenOf(citizenId)
			if cid == nil then return OPX.Result.Err('no_citizen') end
			return issue(cid, kind, by)
		end,
		--- `(citizenId, kind, reason?, by?)` -> Result. Yields.
		RevokeLicence = function(citizenId, kind, reason, by) return revoke(citizenId, kind, reason, by) end,
		--- The court's crime codes, sorted.
		Crimes = function() return S.crimeList end,
		Licence = function(kind) return S.licences[kind] end,
	})
end

local function door(event, handler)
	RegisterNetEvent(event, function(...)
		local player = playerId(source)
		if player == nil then return end
		local args = table.pack(...)
		local data = dataOf(player)
		CreateThread(function()
			if not still(player, data) then return end
			handler(player, table.unpack(args, 1, math.min(args.n, 4)))
		end)
	end)
end

local function word(value) return type(value) == 'string' and #value <= 48 and value or nil end

--- Registers the card, the doors and the commands. On a coroutine.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	for _, line in ipairs(S.problems) do Open77.log.warn('[justice] config: ' .. line) end
	if #S.placeholders > 0 then
		Open77.log.info(('[justice] desks disabled until surveyed (0,0,0): %s'):format(table.concat(S.placeholders, ', ')))
	end
	if character == nil then
		Open77.log.error('[justice] no character contract: no desk opens')
		return
	end
	local api = inventory()
	if S.card ~= nil and api ~= nil and type(api.RegisterItem) == 'function' then
		local registered = api.RegisterItem(S.card.name, { label = S.card.label, description = S.card.description,
			weight = S.card.weight, stack = false, category = 'document',
			-- A licence is the holder's, not a thing to hand over or leave lying about.
			drop = false }, OWNER)
		if not okResult(registered) then
			Open77.log.warn(('[justice] the item %s was refused: %s'):format(S.card.name,
				tostring(type(registered) == 'table' and registered.error)))
		end
	end

	door(M.Event.DESK, function(player, key) if word(key) then M.OpenDesk(player, key) end end)
	door(M.Event.BUY, function(player, key, kind) if word(key) and word(kind) then M.Buy(player, key, kind) end end)
	door(M.Event.BAIL, function(player, key, id) if word(key) then M.PayBail(player, key, id) end end)
	door(M.Event.DISMISS, function(player, key) if word(key) then M.Dismiss(player, key) end end)
	door(M.Event.RECORD, function(player, who)
		if math.type(who) == 'integer' or (type(who) == 'string' and #who <= 32) then M.ViewRecord(player, who) end
	end)
	door(M.Event.OFFER, function(player, target) if math.type(target) == 'integer' then M.Offer(player, target) end end)
	RegisterNetEvent(M.Event.CONSENT, function(id, accepted)
		local player = playerId(source)
		if player == nil or type(id) ~= 'string' or #id > 32 then return end
		CreateThread(function() M.Consent(player, id, accepted == true) end)
	end)
	door(M.Event.OFFICE, function(player) M.Office(player) end)
	door(M.Event.EXPUNGE, function(player, id) M.Expunge(player, id) end)
	door(M.Event.RULE, function(player, id, approved) M.Rule(player, id, approved == true) end)
	door(M.Event.WARRANT, function(player, payload) M.Warrant(player, payload) end)
	door(M.Event.SET_BAIL, function(player, id, bail, lift) M.SetBail(player, id, bail, lift == true) end)
	door(M.Event.CASE, function(player, payload) M.OpenCase(player, payload) end)
	door(M.Event.VERDICT, function(player, payload) M.Verdict(player, payload) end)
	door(M.Event.REVOKE, function(player, payload) M.Revoke(player, payload) end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, left)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'invoices', 'paid'), onInvoicePaid)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'invoices', 'refused'), onInvoiceGone)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'invoices', 'expired'), onInvoiceGone)

	OPX.Command.Register(M.Command.DESKS, { restricted = true, help = 'justice.help.desks' },
		function(source) report(source) end)
	OPX.Command.Register(M.Command.CAPTURE, { restricted = true, help = 'justice.help.capture',
		params = { { name = 'key', help = locale('justice.help.key') } } },
		function(source, args) capture(source, args) end)

	sweepJob = OPX.Scheduler.Every('justice:sweep', 1000, sweep)
	Open77.log.info(('[justice] ready: %d desk(s), %d licence(s), %d crime code(s)%s'):format(#S.deskList,
		#S.licenceList, #S.crimeList, accounts() == nil and ', no accounts contract yet' or ''))
end

--- Drops the offers in flight.
-- @author dop42
function M.Stop()
	if sweepJob ~= nil then pcall(OPX.Scheduler.Cancel, sweepJob) end
	sweepJob = nil
	invites, inviteOf, fines, busyCases = {}, {}, {}, {}
end
