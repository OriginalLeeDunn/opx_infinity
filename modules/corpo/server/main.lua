--- Server half: the boards, the assignments, the pay, standing and espionage.
-- @author dop42
--
-- THIS FILE IS THE CORP'S HR, ACCOUNTING AND INTERNAL AFFAIRS. A client names
-- an office, an offer, a drop or a player, and every other fact is read here:
-- the corp and its places out of the config this VM built, the position and
-- bucket from the host, the job and grade from the character contract, the
-- tagged item from the inventory contract, the VIP's position from the NPC
-- natives. A request passes, cheapest first: the per-player floor, the lookup,
-- loaded and not down, the job gate, the reach, then the thing itself.
--
-- AN ASSIGNMENT IS PROVEN, NEVER CLAIMED. A delivery is the item carrying the
-- assignment's id AND serial leaving the bag at the destination the server
-- chose when it was taken; a retrieval is a server-timed bar at the terminal;
-- a sweep is the server's own tick finding the employee inside the floor for
-- HOLD_MS without a break; an escort is the server NPC read at the destination.
--
-- MONEY MOVES LAST AND COMES BACK ON FAILURE. The corp's money is taken first
-- (`accounts.Withdraw` with an idempotent op id, or a mint under the hourly
-- cap), then the employee is paid; a payment refused gives the corp its money
-- back. An offer is taken off the board BEFORE anything yields and is put back
-- if the item cannot be handed over.
--
-- ASSIGNMENTS LIVE IN THIS VM. A restart ends them; the tagged items left in a
-- bag are worthless (no assignment answers their id) -- the P2 note in the
-- design is to persist them. Standing lives on the character's metadata.

local M = OPX.Modules.Get('corpo')
local Access = M.Access
local Kind, Stage = M.Kind, M.Stage
local Result = OPX.Result

local OWNER = 'corpo'

-- What `Access.Build` made of the config.
local built = nil
-- corp -> { offers, drawnAt, serial }
local boards = {}
-- id -> assignment
local assignments = {}
local nextId = 0
-- The mint's current hour: { hour, spent }.
local mintWindow = nil
-- contract id -> { corp, amount, via, opId }: gigs outsourced to the fixer board.
local published = {}
-- thief -> { victim, assignment, barId }; thief -> ms of the last attempt.
local thefts, spyClock = {}, {}
local tickJob = nil

--- The roll, a field so a test can load the dice. Answers 0..1.
M.Roll = math.random

-- Shared with server/security.lua, which is loaded after this file.
M.Server = {}
local S = M.Server

-- ── reading the world ───────────────────────────────────────────────────────

function S.PointOf(player)
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y), OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end
local pointOf = S.PointOf

--- Whether a point is within the server's reach of a place.
function S.Within(at, place, extra)
	if type(at) ~= 'table' or at.bucket ~= place.bucket then return false end
	local reach = OPX.Spots.ServerReach(place.radius + (extra or 0))
	local dx, dy, dz = at.x - place.x, at.y - place.y, at.z - place.z
	return dx * dx + dy * dy + dz * dz <= reach * reach
end
local within = S.Within

function S.Distance(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Wall-clock seconds: what a quarter and the mint's hour are counted in.
function S.WallS()
	local time = Open77.time
	if type(time) == 'table' and type(time.unix) == 'function' then
		local read, value = pcall(time.unix)
		value = read and OPX.Math.Finite(value) or nil
		if value ~= nil then return value end
	end
	return OPX.Now() / 1000
end
local wallS = S.WallS

local function character() return OPX.Api.Get('character') end
local function inventory() return OPX.Api.Get('inventory') end
S.Character = character

function S.PlayerOf(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, value = pcall(api.GetPlayer, player)
	if not read or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return value
end
local playerOf = S.PlayerOf

function S.SnapshotOf(loaded)
	local data = loaded.PlayerData
	return {
		job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		atMs = OPX.Now(),
	}
end
local snapshotOf = S.SnapshotOf

--- The corp a character works for (their primary job), its grade and whether
--- they are clocked in; nil when it is no corp's.
function S.RoleOf(loaded)
	local job = type(loaded) == 'table' and loaded.PlayerData.job or nil
	if type(job) ~= 'table' then return nil end
	for _, key in ipairs(built.order) do
		local corp = built.corps[key]
		if corp.job == job.name then
			local grade = type(job.grade) == 'table' and OPX.Math.Finite(job.grade.level) or 0
			return corp, math.floor(grade), job.onDuty == true
		end
	end
	return nil
end
local roleOf = S.RoleOf

local function citizenOf(loaded)
	return type(loaded) == 'table' and loaded.PlayerData.citizenId or nil
end

-- One inventory call answering a value, or nil.
local function valueOf(fn, ...)
	if type(fn) ~= 'function' then return nil end
	local read, answer = pcall(fn, ...)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return nil end
	return answer.value
end

local function itemsOf(player)
	local api = inventory()
	local bag = api and valueOf(api.GetInventory, player) or nil
	return type(bag) == 'table' and type(bag.items) == 'table' and bag.items or {}
end

local function progressApi()
	local api = OPX.Api.Get('progress')
	if api == nil or type(api.Start) ~= 'function' then return nil end
	return api
end
S.Progress = progressApi

-- ── answers ─────────────────────────────────────────────────────────────────

--- Tells one player how a request went, as a toast from the catalogue.
function S.Answer(player, ok, code, params)
	local key = (ok and 'corpo.answer.' or 'corpo.error.') .. tostring(code)
	if not OPX.Locale.Exists(key) then key = ok and 'corpo.answer.done' or 'corpo.error.invalid' end
	pcall(OPX.NotifyLocale, player, key, params, ok and 'success' or 'error')
	return ok, code
end
local answer = S.Answer

--- The employee gate: loaded, holding the corp's job as their primary one, on
--- duty when the corp asks it. Answers the loaded player and grade, or nil, why.
function S.Employee(player, corp)
	local loaded = playerOf(player)
	if loaded == nil then return nil, 'no_character' end
	local ok, why = OPX.JobGate.Evaluate({ jobs = { [corp.job] = 0 }, onDuty = corp.onDuty },
		snapshotOf(loaded), OPX.Now(), { maxAgeMs = 5000, membership = 'primary' })
	if not ok then return nil, why or 'job_required' end
	local _, grade = roleOf(loaded)
	return loaded, grade or 0
end
local employee = S.Employee

-- ── standing ────────────────────────────────────────────────────────────────

local function quarterNow() return Access.Quarter(wallS(), built.quarter.days) end

function S.Record(who, corpKey)
	local api = character()
	local raw = nil
	if api ~= nil and type(api.GetMetadata) == 'function' then
		local read, value = pcall(api.GetMetadata, who, built.standing.metadata)
		if read then raw = value end
	end
	return Access.Record(raw, corpKey, quarterNow()), raw
end
local recordOf = S.Record

function S.SaveRecord(who, corpKey, record)
	local api = character()
	if api == nil or type(api.SetMetadata) ~= 'function' then return false end
	local _, raw = recordOf(who, corpKey)
	local whole = type(raw) == 'table' and OPX.Table.DeepCopy(raw) or {}
	whole[corpKey] = record
	local read, done = pcall(api.SetMetadata, who, built.standing.metadata, whole)
	return read and done ~= false
end
local saveRecord = S.SaveRecord

-- ── the corp's money ────────────────────────────────────────────────────────

local function accountsApi()
	local api = OPX.Api.Get('accounts')
	if api == nil or type(api.Withdraw) ~= 'function' then return nil end
	return api
end

local function mintCap()
	return math.floor(OPX.Tune.Number('CORPO_MINT_PER_HOUR', built.mintPerHour) or built.mintPerHour)
end

local function hourNow() return math.floor(wallS() / 3600) end

--- Whether the corp could pay `amount` now (no money moves).
function S.CanFund(corp, amount)
	if amount <= 0 then return true end
	local api = accountsApi()
	if api ~= nil then
		if type(api.Balance) ~= 'function' then return true end
		local read, balance = pcall(api.Balance, corp.account.kind, corp.account.key)
		local value = read and type(balance) == 'table' and balance.ok and type(balance.value) == 'table'
			and OPX.Math.Finite(balance.value.balance) or nil
		if value == nil or value < amount then return false, 'corp_budget' end
		return true
	end
	local ok = Access.Mint(mintWindow, hourNow(), mintCap(), amount)
	if not ok then return false, 'mint_capped' end
	return true
end
local canFund = S.CanFund

--- Takes `amount` from the corp: its account, or a mint. Answers how ('account'
--- or 'mint'), or nil and why.
function S.Fund(corp, amount, opId, reason)
	local api = accountsApi()
	if api ~= nil then
		local read, taken = pcall(api.Withdraw, corp.account.kind, corp.account.key, amount, reason, opId)
		if read and type(taken) == 'table' and taken.ok == true then return 'account' end
		local why = read and type(taken) == 'table' and taken.error or nil
		if why ~= 'insufficient_funds' then
			Open77.log.warn(('[corpo] the %s account refused %d: %s'):format(corp.key, amount, tostring(why or taken)))
		end
		return nil, 'corp_budget'
	end
	local ok, window = Access.Mint(mintWindow, hourNow(), mintCap(), amount)
	if not ok then return nil, 'mint_capped' end
	mintWindow = window
	return 'mint'
end
local fund = S.Fund

--- Gives a corp back what `Fund` took.
function S.Unfund(corp, amount, via, opId, reason)
	if via == 'account' then
		local api = accountsApi()
		if api ~= nil and type(api.Deposit) == 'function' then
			pcall(api.Deposit, corp.account.kind, corp.account.key, amount, reason, opId .. ':refund')
		end
	elseif via == 'mint' then
		local _, window = Access.Mint(mintWindow, hourNow(), mintCap(), -amount)
		mintWindow = window
	end
end
local unfund = S.Unfund

--- Pays a player out of a corp's money. Answers ok and how, or false and why.
function S.Pay(player, corp, amount, opId, reason)
	if amount <= 0 then return true, 'none' end
	local via, why = fund(corp, amount, opId, reason)
	if via == nil then return false, why end
	local api = character()
	local paid = false
	if api ~= nil and type(api.AddMoney) == 'function' then
		local read, ok = pcall(api.AddMoney, player, built.currency, amount, reason)
		paid = read and ok == true
	end
	if not paid then
		unfund(corp, amount, via, opId, reason)
		return false, 'payment_failed'
	end
	OPX.Audit.Log({ event = 'corpo.pay', message = ('player %d paid %d by %s (%s, %s)'):format(player, amount,
		corp.key, via, opId), data = { corp = corp.key, amount = amount, via = via, op = opId }, source = player })
	return true, via
end
local pay = S.Pay

-- ── the boards ──────────────────────────────────────────────────────────────

local function boardOf(corp)
	local board = boards[corp.key]
	local now = OPX.Now()
	if board == nil or now - board.drawnAt >= built.board.refreshMs then
		local serial = board and board.serial or 0
		board = { offers = Access.Generate(corp, built, built.board.size, M.Roll, serial), drawnAt = now,
			serial = serial + built.board.size }
		boards[corp.key] = board
	end
	return board
end

local function offerAt(board, id)
	if type(id) ~= 'string' then return nil end
	for index, offer in ipairs(board.offers) do
		if offer.id == id then return offer, index end
	end
	return nil
end

local function mine(cid)
	local out = {}
	if cid == nil then return out end
	for _, assignment in pairs(assignments) do
		if assignment.cid == cid then out[#out + 1] = assignment end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end
S.Mine = mine

local function contractsApi()
	local api = OPX.Api.Get('contracts')
	if api == nil or type(api.Post) ~= 'function' then return nil end
	return api
end

local function sendBoard(player, corp, office, grade)
	local board = boardOf(corp)
	local record = recordOf(player, corp.key)
	local rows = {}
	for _, offer in ipairs(board.offers) do
		local ok, why = Access.Eligible(offer, grade, record.s)
		rows[#rows + 1] = {
			id = offer.id, kind = offer.kind, label = offer.label, brief = offer.brief,
			pay = Access.Pay(offer.pay, grade, built), standing = offer.standing,
			minutes = math.ceil(offer.deadlineS / 60), start = offer.from and offer.from.label or nil,
			locked = not ok and why or nil, minGrade = offer.minGrade, minStanding = offer.minStanding,
		}
	end
	local loaded = playerOf(player)
	local active = mine(citizenOf(loaded))[1]
	TriggerClientEvent(M.Event.SHOW_BOARD, player, {
		corp = corp.key, label = corp.label, office = office.key, officeLabel = office.label,
		standing = record.s, quarter = { done = record.qDone, target = built.quarter.target, paid = record.qPaid },
		rows = rows, busy = active ~= nil or nil,
		canPublish = built.publish.enabled and grade >= corp.publishGrade and contractsApi() ~= nil or nil,
	})
end

-- ── what the employee sees ──────────────────────────────────────────────────

local function targetOf(assignment)
	local place = nil
	if assignment.stage == Stage.GOTO or assignment.stage == Stage.SWEEP then place = assignment.from
	else place = assignment.to end
	if place == nil then return nil end
	return { corp = place.corp, list = place.list, key = place.key, label = place.label,
		x = place.x, y = place.y, z = place.z }
end

function S.SendActive(player)
	if player == nil then return end
	local loaded = playerOf(player)
	local assignment = mine(citizenOf(loaded))[1]
	if assignment == nil then
		TriggerClientEvent(M.Event.ACTIVE, player, false)
		return
	end
	TriggerClientEvent(M.Event.ACTIVE, player, {
		id = assignment.id, kind = assignment.kind, label = assignment.label, stage = assignment.stage,
		corp = assignment.corp, target = targetOf(assignment),
		remainingS = math.max(0, math.floor((assignment.deadlineMs - OPX.Now()) / 1000)),
		holdS = assignment.holdMs and math.floor(assignment.holdMs / 1000) or nil,
	})
end
local sendActive = S.SendActive

-- ── items ───────────────────────────────────────────────────────────────────

local function itemName(kind) return built.items[kind].name end

--- The bag slot holding an assignment's tagged item, or nil.
local function slotOf(player, assignment)
	local name = itemName(assignment.item)
	local items = itemsOf(player)
	for index = 1, #items do
		local item = items[index]
		local metadata = type(item) == 'table' and type(item.metadata) == 'table' and item.metadata or nil
		if metadata ~= nil and item.name == name and metadata.assignment == assignment.id
			and metadata.serial == assignment.serial then
			return item.slot, metadata
		end
	end
	return nil
end
S.SlotOf = slotOf

local function giveItem(player, kind, metadata)
	local api = inventory()
	if api == nil or type(api.AddItem) ~= 'function' then return false end
	local read, added = pcall(api.AddItem, player, itemName(kind), 1, metadata)
	return read and type(added) == 'table' and added.ok == true
end

local function takeSlot(player, slot)
	local api = inventory()
	if api == nil or type(api.RemoveFromSlot) ~= 'function' then return false end
	local read, removed = pcall(api.RemoveFromSlot, player, slot, 1)
	return read and type(removed) == 'table' and removed.ok == true
end

local function canCarry(player, kind)
	local api = inventory()
	if api == nil then return false end
	return valueOf(api.CanCarry, player, itemName(kind), 1, { corp = 'x' }) == true
end

local function serialOf(corpKey)
	return ('%s-%d-%06d'):format(corpKey:sub(1, 4), math.floor(wallS()), math.floor(M.Roll() * 1000000))
end

-- ── the VIP ─────────────────────────────────────────────────────────────────

local function npcs()
	local api = Open77.npcs
	if type(api) ~= 'table' or type(api.create) ~= 'function' or type(api.get) ~= 'function' then return nil end
	return api
end

local function despawn(assignment)
	if assignment.npc == nil then return end
	local api = npcs()
	if api ~= nil and type(api.remove) == 'function' then pcall(api.remove, assignment.npc) end
	assignment.npc = nil
end

--- Where an NPC is, from its server snapshot, or nil.
local function npcPoint(id)
	local api = npcs()
	if api == nil then return nil end
	local read, snapshot = pcall(api.get, id)
	if not read or type(snapshot) ~= 'table' then return nil end
	local source = type(snapshot.position) == 'table' and snapshot.position or snapshot
	local x, y, z = OPX.Math.Finite(source.x), OPX.Math.Finite(source.y), OPX.Math.Finite(source.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(snapshot.bucket) or 0,
		health = OPX.Math.Finite(snapshot.health) }
end

-- ── endings ─────────────────────────────────────────────────────────────────

local function stopBar(assignment)
	if assignment.barId == nil or assignment.player == nil then return end
	local api = progressApi()
	if api ~= nil and type(api.Stop) == 'function' then pcall(api.Stop, assignment.player, OWNER, assignment.barId) end
	assignment.barId = nil
end

--- Ends an assignment as a failure. `keepItem` leaves the tagged item where it
--- is (it was stolen and is somebody else's now).
function S.Fail(assignment, reason, loss, keepItem)
	if assignments[assignment.id] ~= assignment then return end
	assignments[assignment.id] = nil
	stopBar(assignment)
	despawn(assignment)
	local player = assignment.player
	local online = player ~= nil and citizenOf(playerOf(player)) == assignment.cid
	if online and not keepItem and assignment.item ~= nil then
		local slot = slotOf(player, assignment)
		if slot ~= nil then takeSlot(player, slot) end
	end
	local who = online and player or assignment.cid
	local record = recordOf(who, assignment.corp)
	Access.Fail(record, loss or assignment.loss, built)
	saveRecord(who, assignment.corp, record)
	OPX.Audit.Log({ event = 'corpo.failed', message = ('%s failed %s (%s)'):format(tostring(assignment.cid),
		assignment.template, reason), data = { corp = assignment.corp, id = assignment.id, reason = reason },
		source = online and player or nil })
	OPX.Publish(M.Event.ON_FAILED, online and player or nil, { cid = assignment.cid, corp = assignment.corp,
		kind = assignment.kind, template = assignment.template, reason = reason })
	if online then
		answer(player, false, 'failed_' .. reason, { label = assignment.label, standing = record.s })
		sendActive(player)
	end
end
local fail = S.Fail

--- Ends an assignment as a success: the corp pays, standing moves, the quarter
--- is counted and its bonus paid the first time the target is met.
function S.Complete(assignment, player)
	if assignments[assignment.id] ~= assignment then return end
	assignments[assignment.id] = nil
	despawn(assignment)
	local corp = built.corps[assignment.corp]
	local reason = ('corpo:%s:%d'):format(assignment.corp, assignment.id)
	local paid, via = pay(player, corp, assignment.pay, ('corpo:%d:%s:pay'):format(assignment.id, assignment.serial),
		reason)
	local record = recordOf(player, corp.key)
	local _, owed = Access.Succeed(record, assignment.standing, built)
	if owed then
		local bonus = built.quarter.bonus
		local got = pay(player, corp, bonus, ('corpo:q:%s:%s:%d'):format(assignment.cid, corp.key, record.q),
			reason .. ':quarter')
		if got then
			record.qPaid = true
			answer(player, true, 'quarter_bonus', { corp = corp.label, amount = OPX.Locale.Money(bonus) })
		end
	end
	saveRecord(player, corp.key, record)
	OPX.Publish(M.Event.ON_COMPLETED, player, { cid = assignment.cid, corp = corp.key, kind = assignment.kind,
		template = assignment.template, pay = paid and assignment.pay or 0, standing = record.s,
		funded = paid and via or nil })
	if paid then
		answer(player, true, 'completed', { label = assignment.label, pay = OPX.Locale.Money(assignment.pay),
			standing = record.s })
	else
		OPX.Audit.Log({ event = 'corpo.unpaid', severity = 'warn', message = ('assignment %d done, not paid: %s')
			:format(assignment.id, tostring(via)), data = { corp = corp.key, amount = assignment.pay, why = via },
			source = player })
		answer(player, false, 'unpaid', { label = assignment.label, standing = record.s })
	end
	sendActive(player)
end
local complete = S.Complete

-- ── the requests ────────────────────────────────────────────────────────────

local function corpOf(payload)
	return type(payload) == 'table' and type(payload.corp) == 'string' and built.corps[payload.corp] or nil
end

--- Opens a corp's board at one of its offices. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { corp, office }
-- @return boolean ok
-- @return string code
function M.Board(player, payload)
	if OPX.Cooling(player, 'corpo.request', built.requestMs) then return answer(player, false, 'too_fast') end
	local corp = corpOf(payload)
	if corp == nil then return answer(player, false, 'unknown_corp') end
	local office = Access.Place(built, corp.key, 'offices', payload.office)
	if office == nil then return answer(player, false, 'unknown_place') end
	local loaded, grade = employee(player, corp)
	if loaded == nil then return answer(player, false, grade) end
	if OPX.Life.Down(player) then return answer(player, false, 'player_down') end
	if not within(pointOf(player), office) then return answer(player, false, 'too_far') end
	sendBoard(player, corp, office, grade)
	return true, 'board'
end

--- Takes an offer off the board. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { corp, office, offer }
-- @return boolean ok
-- @return string code
function M.Accept(player, payload)
	if OPX.Cooling(player, 'corpo.request', built.requestMs) then return answer(player, false, 'too_fast') end
	local corp = corpOf(payload)
	if corp == nil then return answer(player, false, 'unknown_corp') end
	local office = Access.Place(built, corp.key, 'offices', payload.office)
	if office == nil then return answer(player, false, 'unknown_place') end
	local loaded, grade = employee(player, corp)
	if loaded == nil then return answer(player, false, grade) end
	if OPX.Life.Down(player) then return answer(player, false, 'player_down') end
	if not within(pointOf(player), office) then return answer(player, false, 'too_far') end
	local cid = citizenOf(loaded)
	if #mine(cid) >= built.board.maxActive then return answer(player, false, 'already_working') end
	local board = boardOf(corp)
	local offer, index = offerAt(board, payload.offer)
	if offer == nil then return answer(player, false, 'offer_gone') end
	local record = recordOf(player, corp.key)
	local eligible, why = Access.Eligible(offer, grade, record.s)
	if not eligible then return answer(player, false, why) end
	local amount = Access.Pay(offer.pay, grade, built)
	local fundable, broke = canFund(corp, amount)
	if not fundable then return answer(player, false, broke) end
	local destination = nil
	if offer.kind ~= Kind.SWEEP then
		destination = Access.Destination(offer, corp, built, office.key, M.Roll())
		if destination == nil then return answer(player, false, 'offer_gone') end
	end
	if offer.kind == Kind.DELIVER and not canCarry(player, offer.item) then return answer(player, false, 'cannot_carry') end
	if offer.kind == Kind.ESCORT and npcs() == nil then return answer(player, false, 'no_npcs') end
	if offer.kind == Kind.RETRIEVE and progressApi() == nil then return answer(player, false, 'no_bar') end

	-- Off the board before anything yields: first come, first served.
	table.remove(board.offers, index)
	nextId = nextId + 1
	local now = OPX.Now()
	local assignment = {
		id = nextId, cid = cid, player = player, corp = corp.key, template = offer.template, kind = offer.kind,
		label = offer.label, pay = amount, standing = offer.standing, loss = offer.loss,
		item = (offer.kind == Kind.DELIVER or offer.kind == Kind.RETRIEVE) and offer.item or nil,
		stealable = offer.stealable, holdMs = offer.holdMs, durationMs = offer.durationMs, reach = offer.reach,
		record = offer.record, from = offer.from, to = destination, serial = serialOf(corp.key),
		deadlineMs = now + offer.deadlineS * 1000, acceptedAt = now,
	}
	if offer.kind == Kind.DELIVER then
		assignment.stage = Stage.CARRY
		local item = built.items[offer.item]
		if not giveItem(player, offer.item, {
			assignment = assignment.id, serial = assignment.serial, corp = corp.key,
			stealable = offer.stealable or nil, label = item.label,
			description = ('%s - %s -> %s'):format(corp.label, offer.label, destination.label),
		}) then
			table.insert(board.offers, index, offer)
			return answer(player, false, 'cannot_carry')
		end
	elseif offer.kind == Kind.SWEEP then
		assignment.stage = Stage.SWEEP
	else
		assignment.stage = Stage.GOTO
	end
	assignments[assignment.id] = assignment
	OPX.Audit.Log({ event = 'corpo.accepted', message = ('player %d took %s for %s (%d)'):format(player,
		offer.template, corp.key, amount), data = { corp = corp.key, id = assignment.id, template = offer.template,
		pay = amount }, source = player })
	answer(player, true, 'accepted', { label = offer.label,
		target = (assignment.stage == Stage.CARRY and destination or offer.from or destination).label })
	sendActive(player)
	return true, 'accepted'
end

--- Hands the carried item over at an office or a drop, or a stolen shard to
--- the thief's own corp. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { corp, list, place }
-- @return boolean ok
-- @return string code
function M.Deliver(player, payload)
	if OPX.Cooling(player, 'corpo.request', built.requestMs) then return answer(player, false, 'too_fast') end
	if type(payload) ~= 'table' or (payload.list ~= 'offices' and payload.list ~= 'drops') then
		return answer(player, false, 'unknown_place')
	end
	local place = Access.Place(built, payload.corp, payload.list, payload.place)
	if place == nil then return answer(player, false, 'unknown_place') end
	local loaded = playerOf(player)
	if loaded == nil then return answer(player, false, 'no_character') end
	if OPX.Life.Down(player) then return answer(player, false, 'player_down') end
	if not within(pointOf(player), place) then return answer(player, false, 'too_far') end
	local cid = citizenOf(loaded)
	for _, assignment in ipairs(mine(cid)) do
		local to = assignment.to
		if assignment.stage == Stage.CARRY and to ~= nil and to.corp == place.corp and to.list == place.list
			and to.key == place.key then
			assignment.player = player
			local slot = slotOf(player, assignment)
			if slot == nil then return answer(player, false, 'no_item') end
			if not takeSlot(player, slot) then return answer(player, false, 'no_item') end
			complete(assignment, player)
			return true, 'completed'
		end
	end
	if payload.list == 'offices' then return M.HandIn(player, loaded, place) end
	return answer(player, false, 'nothing_to_deliver')
end

--- A stolen shard sold to the thief's own corp at one of its offices.
function M.HandIn(player, loaded, office)
	local corp = built.corps[office.corp]
	local cid = citizenOf(loaded)
	local name = itemName('datashard')
	local items = itemsOf(player)
	for index = 1, #items do
		local item = items[index]
		local metadata = type(item) == 'table' and type(item.metadata) == 'table' and item.metadata or nil
		if metadata ~= nil and item.name == name and metadata.stolen == true and metadata.forCorp == corp.key
			and metadata.thief == cid then
			local hired, why = employee(player, corp)
			if hired == nil then return answer(player, false, why) end
			if not takeSlot(player, item.slot) then return answer(player, false, 'no_item') end
			local amount = Access.Between(built.espionage.pay[1], built.espionage.pay[2], M.Roll())
			local paid, refusal = pay(player, corp, amount, ('corpo:spy:%s'):format(tostring(metadata.serial)),
				'corpo:espionage:' .. corp.key)
			if not paid then
				giveItem(player, 'datashard', metadata)
				return answer(player, false, refusal)
			end
			local record = recordOf(player, corp.key)
			Access.Move(record, built.espionage.standing, built)
			saveRecord(player, corp.key, record)
			OPX.Audit.Log({ event = 'corpo.intel', message = ('player %d sold %s intel to %s for %d'):format(player,
				tostring(metadata.from), corp.key, amount), data = { corp = corp.key, from = metadata.from,
				amount = amount }, source = player })
			return answer(player, true, 'intel_sold', { corp = corp.label, pay = OPX.Locale.Money(amount),
				standing = record.s })
		end
	end
	return answer(player, false, 'nothing_to_deliver')
end

local onRetrieved

--- Starts the terminal bar of a retrieval. Answers the code.
-- @author dop42
-- @param player integer
-- @return boolean ok
-- @return string code
function M.Retrieve(player)
	if OPX.Cooling(player, 'corpo.request', built.requestMs) then return answer(player, false, 'too_fast') end
	local loaded = playerOf(player)
	if loaded == nil then return answer(player, false, 'no_character') end
	local assignment = nil
	for _, candidate in ipairs(mine(citizenOf(loaded))) do
		if candidate.kind == Kind.RETRIEVE and candidate.stage == Stage.GOTO then assignment = candidate end
	end
	if assignment == nil then return answer(player, false, 'no_assignment') end
	if assignment.barId ~= nil then return answer(player, false, 'busy') end
	if OPX.Life.Down(player) then return answer(player, false, 'player_down') end
	if not within(pointOf(player), assignment.from) then return answer(player, false, 'too_far') end
	if not canCarry(player, 'datashard') then return answer(player, false, 'cannot_carry') end
	local api = progressApi()
	if api == nil then return answer(player, false, 'no_bar') end
	local id = assignment.id
	local started = api.Start(player, OWNER, {
		label = locale('corpo.bar.retrieve', { place = assignment.from.label }),
		durationMs = assignment.durationMs, cancelable = true,
	}, function(who, outcome) onRetrieved(who, outcome, id) end)
	if type(started) ~= 'table' or not started.ok then return answer(player, false, 'busy') end
	assignment.player, assignment.barId = player, started.value.id
	return true, 'retrieving'
end

onRetrieved = function(player, outcome, id)
	local assignment = assignments[id]
	if assignment == nil or type(outcome) ~= 'table' or outcome.id ~= assignment.barId then return end
	assignment.barId = nil
	if outcome.completed ~= true then
		if outcome.ending ~= 'left' then answer(player, false, 'retrieve_cancelled') end
		return
	end
	if not within(pointOf(player), assignment.from) then return answer(player, false, 'too_far') end
	local corp = built.corps[assignment.corp]
	if not giveItem(player, 'datashard', {
		assignment = assignment.id, serial = assignment.serial, corp = corp.key,
		stealable = assignment.stealable or nil, label = built.items.datashard.label,
		description = ('%s - %s -> %s'):format(corp.label, assignment.from.label, assignment.to.label),
	}) then
		return answer(player, false, 'cannot_carry')
	end
	assignment.stage = Stage.CARRY
	answer(player, true, 'retrieved', { target = assignment.to.label })
	sendActive(player)
end

--- Meets the VIP at the pickup: a server NPC that follows the employee.
-- @author dop42
-- @param player integer
-- @return boolean ok
-- @return string code
function M.Meet(player)
	if OPX.Cooling(player, 'corpo.request', built.requestMs) then return answer(player, false, 'too_fast') end
	local loaded = playerOf(player)
	if loaded == nil then return answer(player, false, 'no_character') end
	local assignment = nil
	for _, candidate in ipairs(mine(citizenOf(loaded))) do
		if candidate.kind == Kind.ESCORT and candidate.stage == Stage.GOTO then assignment = candidate end
	end
	if assignment == nil then return answer(player, false, 'no_assignment') end
	if OPX.Life.Down(player) then return answer(player, false, 'player_down') end
	local at = pointOf(player)
	if not within(at, assignment.from) then return answer(player, false, 'too_far') end
	local api = npcs()
	if api == nil then return answer(player, false, 'no_npcs') end
	local damage = type(api.damage) == 'table' and api.damage or {}
	local ai = type(api.ai) == 'table' and api.ai or {}
	local from = assignment.from
	local read, id, why = pcall(api.create, {
		record = assignment.record, position = { x = from.x, y = from.y, z = from.z }, yaw = 0.0,
		bucket = from.bucket, aiMode = ai.tasks, damagePolicy = damage.mortal,
	})
	if not read or id == nil then
		Open77.log.warn(('[corpo] the VIP %s could not be spawned: %s'):format(tostring(assignment.record),
			tostring(read and why or id)))
		return answer(player, false, 'no_npcs')
	end
	assignment.npc, assignment.player, assignment.stage = id, player, Stage.ESCORT
	if type(api.tasks) == 'table' and type(api.tasks.follow) == 'function' then
		pcall(api.tasks.follow, id, player, { distance = 2, speed = 'walk' })
	end
	answer(player, true, 'vip_met', { target = assignment.to.label })
	sendActive(player)
	return true, 'escorting'
end

--- Abandons the assignment held, or outsources an offer to the fixer board.
-- @author dop42
-- @param player integer
-- @param payload table { verb, corp?, office?, offer? }
-- @return boolean ok
-- @return string code
function M.Act(player, payload)
	if OPX.Cooling(player, 'corpo.request', built.requestMs) then return answer(player, false, 'too_fast') end
	if type(payload) ~= 'table' then return answer(player, false, 'invalid') end
	local loaded = playerOf(player)
	if loaded == nil then return answer(player, false, 'no_character') end
	if payload.verb == 'abandon' then
		local assignment = mine(citizenOf(loaded))[1]
		if assignment == nil then return answer(player, false, 'no_assignment') end
		assignment.player = player
		fail(assignment, 'abandoned', built.standing.abandonLoss)
		return true, 'abandoned'
	elseif payload.verb == 'outsource' then
		return M.Outsource(player, payload)
	end
	return answer(player, false, 'invalid')
end

local function publishTarget(offer)
	local want = (offer.kind == Kind.SWEEP or offer.kind == Kind.ESCORT) and 'reach_zone' or 'deliver_item'
	for _, target in ipairs(built.publish.targets) do
		if target.type == want then return target end
	end
	return built.publish.targets[1]
end

--- Pushes an offer onto the fixer board, paid by the corp up front. Yields
--- (the contracts module writes). Answers the code.
-- @author dop42
function M.Outsource(player, payload)
	if not built.publish.enabled then return answer(player, false, 'no_contracts') end
	local corp = corpOf(payload)
	if corp == nil then return answer(player, false, 'unknown_corp') end
	local office = Access.Place(built, corp.key, 'offices', payload.office)
	if office == nil then return answer(player, false, 'unknown_place') end
	local loaded, grade = employee(player, corp)
	if loaded == nil then return answer(player, false, grade) end
	if grade < corp.publishGrade then return answer(player, false, 'grade_too_low') end
	if not within(pointOf(player), office) then return answer(player, false, 'too_far') end
	local api = contractsApi()
	if api == nil then return answer(player, false, 'no_contracts') end
	local board = boardOf(corp)
	local offer, index = offerAt(board, payload.offer)
	if offer == nil then return answer(player, false, 'offer_gone') end
	local target = publishTarget(offer)
	local reward = math.floor(offer.pay * built.publish.markup + 0.5)
	local opId = ('corpo:pub:%s:%d'):format(offer.id, board.serial)
	local via, broke = fund(corp, reward, opId, 'corpo:outsource:' .. corp.key)
	if via == nil then return answer(player, false, broke) end
	table.remove(board.offers, index)
	local read, posted = pcall(api.Post, {
		type = target.type, title = OPX.Text.Clean(('%s: %s'):format(corp.label, offer.label), 60) or offer.label,
		brief = offer.brief, reward = reward, funded = 'external', poster = corp.label,
		deadlineS = built.publish.deadlineS,
		objective = target.type == 'reach_zone' and { zone = target.target } or { dropoff = target.target },
	})
	if not read or type(posted) ~= 'table' or posted.ok ~= true then
		unfund(corp, reward, via, opId, 'corpo:outsource:refund')
		table.insert(board.offers, math.min(index, #board.offers + 1), offer)
		local why = read and type(posted) == 'table' and tostring(posted.error) or tostring(posted)
		Open77.log.warn(('[corpo] the fixer board refused an outsourced %s: %s'):format(offer.template, why))
		return answer(player, false, 'outsource_failed')
	end
	published[posted.value] = { corp = corp.key, amount = reward, via = via, opId = opId }
	OPX.Audit.Log({ event = 'corpo.outsourced', message = ('player %d outsourced %s for %s (%d)'):format(player,
		offer.template, corp.key, reward), data = { corp = corp.key, contract = posted.value, reward = reward,
		via = via }, source = player })
	return answer(player, true, 'outsourced', { label = offer.label, reward = OPX.Locale.Money(reward) })
end

--- A gig the corp outsourced ended: a failed, expired or cancelled one gives
--- the corp its money back.
function M.OnGigEnded(payload, refund)
	local id = type(payload) == 'table' and payload.id or nil
	local row = id ~= nil and published[id] or nil
	if row == nil then return end
	published[id] = nil
	if refund then
		local corp = built.corps[row.corp]
		if corp ~= nil then unfund(corp, row.amount, row.via, row.opId, 'corpo:outsource:refund') end
		OPX.Audit.Log({ event = 'corpo.outsourceRefund', message = ('gig %s ended unpaid; %d back to %s')
			:format(tostring(id), row.amount, row.corp), data = row })
	end
end

-- ── espionage ───────────────────────────────────────────────────────────────

local onStolen

--- The assignment a player is carrying a stealable item for, or nil.
local function carrying(cid)
	for _, assignment in ipairs(mine(cid)) do
		if assignment.stage == Stage.CARRY and assignment.stealable then return assignment end
	end
	return nil
end

--- A rival corp's employee lifts a courier's shard. Answers the code.
-- @author dop42
-- @param player integer the thief
-- @param payload table { target }
-- @return boolean ok
-- @return string code
function M.Steal(player, payload)
	if OPX.Cooling(player, 'corpo.request', built.requestMs) then return answer(player, false, 'too_fast') end
	if not built.espionage.enabled then return answer(player, false, 'invalid') end
	local victim = type(payload) == 'table' and math.tointeger(payload.target) or nil
	if victim == nil or victim <= 0 or victim == player then return answer(player, false, 'invalid') end
	local thief = playerOf(player)
	if thief == nil then return answer(player, false, 'no_character') end
	local thiefCorp = roleOf(thief)
	if thiefCorp == nil then return answer(player, false, 'not_corpo') end
	if thefts[player] ~= nil then return answer(player, false, 'busy') end
	local now = OPX.Now()
	if spyClock[player] ~= nil and now - spyClock[player] < built.espionage.cooldownMs then
		return answer(player, false, 'spy_cooldown',
			{ minutes = math.ceil((built.espionage.cooldownMs - (now - spyClock[player])) / 60000) })
	end
	local target = playerOf(victim)
	local assignment = target and carrying(citizenOf(target)) or nil
	if assignment == nil then return answer(player, false, 'nothing_to_steal') end
	if not Access.MayRob(thiefCorp, built.corps[assignment.corp], built) then return answer(player, false, 'not_rival') end
	if OPX.Life.Down(player) then return answer(player, false, 'player_down') end
	local a, b = pointOf(player), pointOf(victim)
	if a == nil or b == nil or a.bucket ~= b.bucket
		or S.Distance(a, b) > OPX.Spots.ServerReach(built.espionage.reach) then
		return answer(player, false, 'too_far')
	end
	if slotOf(victim, assignment) == nil then return answer(player, false, 'nothing_to_steal') end
	local api = progressApi()
	if api == nil then return answer(player, false, 'no_bar') end
	local started = api.Start(player, OWNER, { label = locale('corpo.bar.steal'),
		durationMs = built.espionage.stealMs, cancelable = true },
		function(who, outcome) onStolen(who, outcome) end)
	if type(started) ~= 'table' or not started.ok then return answer(player, false, 'busy') end
	thefts[player] = { victim = victim, assignment = assignment.id, barId = started.value.id }
	spyClock[player] = now
	return true, 'stealing'
end

onStolen = function(player, outcome)
	local theft = thefts[player]
	if theft == nil or type(outcome) ~= 'table' or outcome.id ~= theft.barId then return end
	thefts[player] = nil
	if outcome.completed ~= true then
		if outcome.ending ~= 'left' then answer(player, false, 'steal_cancelled') end
		return
	end
	local assignment = assignments[theft.assignment]
	local thief = playerOf(player)
	local thiefCorp = roleOf(thief)
	local target = playerOf(theft.victim)
	if assignment == nil or thiefCorp == nil or target == nil or citizenOf(target) ~= assignment.cid
		or assignment.stage ~= Stage.CARRY then
		return answer(player, false, 'nothing_to_steal')
	end
	local a, b = pointOf(player), pointOf(theft.victim)
	if a == nil or b == nil or a.bucket ~= b.bucket
		or S.Distance(a, b) > OPX.Spots.ServerReach(built.espionage.reach) then
		return answer(player, false, 'too_far')
	end
	local slot, metadata = slotOf(theft.victim, assignment)
	if slot == nil then return answer(player, false, 'nothing_to_steal') end
	if not canCarry(player, 'datashard') then return answer(player, false, 'cannot_carry') end
	if not takeSlot(theft.victim, slot) then return answer(player, false, 'nothing_to_steal') end
	local victimCorp = built.corps[assignment.corp]
	local loot = {
		stolen = true, forCorp = thiefCorp.key, from = victimCorp.key, thief = citizenOf(thief),
		serial = serialOf(thiefCorp.key), label = built.items.datashard.label,
		description = ('%s intel - for %s'):format(victimCorp.label, thiefCorp.label),
	}
	if not giveItem(player, 'datashard', loot) then
		giveItem(theft.victim, assignment.item, metadata)
		return answer(player, false, 'cannot_carry')
	end
	assignment.player = theft.victim
	fail(assignment, 'stolen', assignment.loss, true)
	OPX.Audit.Security('corpo.stolen', ('player %d lifted %s data off player %d'):format(player, victimCorp.key,
		theft.victim), { thiefCorp = thiefCorp.key, victimCorp = victimCorp.key }, player)
	OPX.Publish(M.Event.ON_STOLEN, player, { thiefCid = citizenOf(thief), victimCid = assignment.cid,
		thiefCorp = thiefCorp.key, victimCorp = victimCorp.key })
	answer(player, true, 'stolen', { corp = thiefCorp.label })
end

-- ── the clock ───────────────────────────────────────────────────────────────

local function tickOne(assignment, now)
	if now >= assignment.deadlineMs then return fail(assignment, 'expired') end
	local player = assignment.player
	if player == nil then return end
	if assignment.stage == Stage.SWEEP then
		local at = pointOf(player)
		if at ~= nil and Access.Inside(at, assignment.from) and not OPX.Life.Down(player) then
			if assignment.holdSince == nil then
				assignment.holdSince = now
				answer(player, true, 'sweep_started', { seconds = math.floor(assignment.holdMs / 1000) })
			elseif now - assignment.holdSince >= assignment.holdMs then
				return complete(assignment, player)
			end
		elseif assignment.holdSince ~= nil then
			assignment.holdSince = nil
			answer(player, false, 'sweep_broken')
		end
	elseif assignment.stage == Stage.ESCORT then
		local vip = npcPoint(assignment.npc)
		if vip == nil then return fail(assignment, 'vip_lost') end
		if vip.health ~= nil and vip.health <= 0 then return fail(assignment, 'vip_dead') end
		local at = pointOf(player)
		if at == nil then return end
		if at.bucket ~= vip.bucket or S.Distance(at, vip) > 80 then return fail(assignment, 'vip_abandoned') end
		local slack = assignment.reach or 6
		if Access.Inside(vip, assignment.to, slack) and Access.Inside(at, assignment.to, slack) then
			return complete(assignment, player)
		end
	end
end

--- One tick: deadlines, sweeps and escorts.
-- @author dop42
function M.Tick()
	local now = OPX.Now()
	local ids = {}
	for id in pairs(assignments) do ids[#ids + 1] = id end
	table.sort(ids)
	for _, id in ipairs(ids) do
		local assignment = assignments[id]
		if assignment ~= nil then
			local ran, failure = pcall(tickOne, assignment, now)
			if not ran then
				Open77.log.error(('[corpo] assignment %d raised: %s'):format(id, tostring(failure)))
				assignments[id] = nil
				despawn(assignment)
			end
		end
	end
end

--- A connection left: its escort fails (the VIP is nobody's now), its bars go.
local function onLeft(player)
	thefts[player], spyClock[player] = nil, nil
	for id, assignment in pairs(assignments) do
		if assignment.player == player then
			assignment.barId = nil
			if assignment.stage == Stage.ESCORT then
				assignment.player = nil
				pcall(fail, assignment, 'vip_lost')
			else
				assignment.player = nil
			end
		end
		if assignments[id] == nil then despawn(assignment) end
	end
	if M.Security ~= nil then M.Security.Left(player) end
end

-- ── staff ───────────────────────────────────────────────────────────────────

local function report(source)
	local lines = {}
	for _, key in ipairs(built.order) do
		local corp = built.corps[key]
		local counts = {}
		for _, list in ipairs(Access.LIST_ORDER) do counts[#counts + 1] = ('%s=%d'):format(list, #corp.lists[list]) end
		local runnable = {}
		for name, template in pairs(built.templates) do
			if Access.Runnable(template, corp, built) then runnable[#runnable + 1] = name end
		end
		table.sort(runnable)
		lines[#lines + 1] = ('%s %s: %s; offers: %s'):format(key, corp.label, table.concat(counts, ' '),
			#runnable > 0 and table.concat(runnable, ', ') or 'NONE (survey an office)')
	end
	for _, name in ipairs(built.disabled) do lines[#lines + 1] = name .. ' DISABLED (ENABLED = false)' end
	if #built.placeholders > 0 then
		lines[#lines + 1] = 'not surveyed: ' .. table.concat(built.placeholders, ', ')
	end
	for _, line in ipairs(built.problems) do lines[#lines + 1] = 'REFUSED: ' .. line end
	local live = 0
	for _ in pairs(assignments) do live = live + 1 end
	lines[#lines + 1] = ('%d corp(s) open, %d assignment(s) live, %d minted this hour')
		:format(#built.order, live, mintWindow and mintWindow.hour == hourNow() and mintWindow.spent or 0)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

local function capture(source, args)
	if source <= 0 then return OPX.CommandResult(source, false, 'the console stands nowhere') end
	local corp, list, name = args[1], args[2], args[3]
	if type(corp) ~= 'string' or not Access.Key(corp) or type(list) ~= 'string' or M.Lists[list] == nil
		or type(name) ~= 'string' or not Access.Key(name) then
		return OPX.CommandResult(source, false,
			'usage: capture <corp> <offices|drops|terminals|floors|pickups|destinations|enclaves> <key>')
	end
	local at = pointOf(source)
	if at == nil then return OPX.CommandResult(source, false, 'your position could not be read') end
	local wide = list == 'floors' or list == 'enclaves'
	local line = ('CORPS.%s.%s.%s = { LABEL = %q, X = %.2f, Y = %.2f, Z = %.2f, RADIUS = %.1f, BUCKET = %d },')
		:format(corp, M.Lists[list], name, name, at.x, at.y, at.z, wide and 20.0 or 2.0, at.bucket)
	Open77.log.info(('[corpo] capture by %d: %s'):format(source, line))
	OPX.Audit.Log({ event = 'corpo.capture', message = line, source = source })
	OPX.CommandResult(source, true, ('paste into config/corpo.lua, then restart:\n  %s'):format(line))
end

local function registerCommands()
	OPX.Command.Register(M.Command.CAPTURE, { restricted = true, help = 'corpo.help.capture',
		params = {
			{ name = 'corp', help = locale('corpo.help.corp') },
			{ name = 'list', help = locale('corpo.help.list') },
			{ name = 'key', help = locale('corpo.help.key') },
		} },
		function(source, args) capture(source, args) end)
	OPX.Command.Register(M.Command.STATUS, { restricted = true, help = 'corpo.help.status' },
		function(source) report(source) end)
end

local function registerItems()
	local api = inventory()
	if api == nil or type(api.RegisterItem) ~= 'function' then
		Open77.log.warn('[corpo] no inventory contract: no briefcase or datashard; deliveries are off')
		return
	end
	for _, item in pairs(built.items) do
		local known = false
		if type(api.GetItem) == 'function' then
			local read, found = pcall(api.GetItem, item.name)
			known = read and found ~= nil
		end
		if not known then
			local read, done = pcall(api.RegisterItem, item.name, { label = item.label, description = item.description,
				weight = item.weight, stack = false, model = 'crate.valuable' }, OWNER)
			if not read or type(done) ~= 'table' or done.ok ~= true then
				Open77.log.warn(('[corpo] the item %s could not be registered: %s'):format(item.name,
					tostring(read and type(done) == 'table' and done.error or done)))
			end
		end
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the corps out of the config and declares the tunable. Never yields.
-- @author dop42
function M.Init()
	built = Access.Build(M.Settings)
	M.Built = built
	boards, assignments, published, thefts, spyClock = {}, {}, {}, {}, {}
	nextId, mintWindow = 0, nil
	OPX.Tune.Declare{
		CORPO_MINT_PER_HOUR = { value = built.mintPerHour, type = 'integer', min = 0, max = 100000000,
			apply = 'live', label = 'Corps: new money per hour', group = 'Corpo', order = 1,
			description = 'The most the corps may pay in new money in one hour when no accounts module runs.' },
	}
	if M.Security ~= nil then M.Security.Init(built) end
end

--- Publishes the server half of the corpo contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('corpo', 1, {
		--- A player's record with a corp: `{ s, done, failed, q, qDone, qPaid }`.
		Standing = function(player, corp)
			if type(corp) ~= 'string' or built.corps[corp] == nil then return nil end
			return (recordOf(player, corp))
		end,
		--- The assignments a player holds: `{ id, corp, kind, template, stage }`.
		Active = function(player)
			local out = {}
			for _, assignment in ipairs(mine(citizenOf(playerOf(player)))) do
				out[#out + 1] = { id = assignment.id, corp = assignment.corp, kind = assignment.kind,
					template = assignment.template, stage = assignment.stage }
			end
			return out
		end,
		--- Every open corp: key -> { label, job, rivals }.
		Corps = function()
			local out = {}
			for _, key in ipairs(built.order) do
				local corp = built.corps[key]
				local rivals = {}
				for rival in pairs(corp.rivals) do rivals[#rivals + 1] = rival end
				table.sort(rivals)
				out[key] = { label = corp.label, job = corp.job, rivals = rivals }
			end
			return out
		end,
		--- Whether a player may stand in an enclave: `(bool, why)`.
		CanEnter = function(player, corp, enclave) return M.Security.CanEnter(player, corp, enclave) end,
		--- The enclave a player is trespassing in, or nil: `{ corp, enclave }`.
		Trespassing = function(player) return M.Security.Trespassing(player) end,
		--- Moves a player's standing with a corp (another module's reward or fine).
		AddStanding = function(player, corp, delta)
			if type(corp) ~= 'string' or built.corps[corp] == nil or OPX.Math.Finite(delta) == nil then
				return Result.Err('invalid')
			end
			local record = recordOf(player, corp)
			Access.Move(record, math.floor(delta), built)
			if not saveRecord(player, corp, record) then return Result.Err('no_character') end
			return Result.Ok(record.s)
		end,
	})
end

--- Wires the requests, the commands, the items and the clock.
-- @author dop42
function M.Start()
	for _, line in ipairs(built.problems) do Open77.log.warn('[corpo] config: ' .. line) end
	if #built.placeholders > 0 then
		Open77.log.info(('[corpo] not surveyed yet (/opx.corpo.capture): %s')
			:format(table.concat(built.placeholders, ', ')))
	end
	if #built.disabled > 0 then
		Open77.log.info('[corpo] disabled corps: ' .. table.concat(built.disabled, ', '))
	end
	if OPX.Api.Get('accounts') == nil then
		Open77.log.info('[corpo] no accounts contract: corps pay in new money, capped per hour')
	end
	registerItems()

	local function on(event, handler, threaded)
		RegisterNetEvent(event, function(payload)
			local player = tonumber(source)
			if player == nil or player <= 0 then return end
			if threaded then CreateThread(function() handler(player, payload) end)
			else handler(player, payload) end
		end)
	end
	on(M.Event.BOARD, M.Board)
	on(M.Event.ACCEPT, M.Accept, true)
	on(M.Event.ACT, M.Act, true)
	on(M.Event.DELIVER, M.Deliver, true)
	on(M.Event.RETRIEVE, M.Retrieve)
	on(M.Event.MEET, M.Meet)
	on(M.Event.STEAL, M.Steal)
	on(M.Event.DETAIN, function(player, payload) M.Security.Detain(player, payload) end)
	on(M.Event.HELLO, function(player)
		if OPX.Cooling(player, 'corpo.hello', 1000) then return end
		local cid = citizenOf(playerOf(player))
		for _, assignment in ipairs(mine(cid)) do assignment.player = player end
		sendActive(player)
		M.Security.SendRole(player, true)
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = math.tointeger(tonumber(playerId))
		if player ~= nil then onLeft(player) end
	end)
	-- The fixer board's endings, for the gigs a corp outsourced.
	local LOCAL = OPX.Channel.LOCAL
	AddEventHandler(OPX.Event(LOCAL, 'contracts', 'paid'), function(_, payload) M.OnGigEnded(payload, false) end)
	for _, ending in ipairs({ 'failed', 'expired', 'cancelled' }) do
		AddEventHandler(OPX.Event(LOCAL, 'contracts', ending), function(_, payload) M.OnGigEnded(payload, true) end)
	end

	registerCommands()
	tickJob = OPX.Scheduler.Every('corpo:tick', built.tickMs, M.Tick)
	M.Security.Start()
end

--- Ends every escort (the VIPs go) and stops the clocks.
-- @author dop42
function M.Stop()
	if tickJob ~= nil and OPX.Scheduler.Cancel ~= nil then pcall(OPX.Scheduler.Cancel, tickJob) end
	tickJob = nil
	for _, assignment in pairs(assignments) do pcall(despawn, assignment) end
	if M.Security ~= nil then pcall(M.Security.Stop) end
end
