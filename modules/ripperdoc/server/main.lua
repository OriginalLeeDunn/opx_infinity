--- The clinic's server half: the chair, the ledger, and every decision about
-- chrome. One authority -- the page a player presses is a picture of what this
-- half already said.
-- @author XEROX710
--
-- THE TRANSACTION IS THE PLATFORM'S OWN RULE, FOLLOWED EXACTLY. Reserve the
-- price before submission, finalize only on a completion that says
-- `result.ok == true`, compensate anything else. So `settle` takes the money,
-- stages the work and keeps ITS OWN record beside the platform's ticket -- and
-- `onCompleted` is the only place a staged charge is kept or given back. A
-- refund is owed to the CHARACTER that paid, not to whoever holds the slot by
-- then: it is credited to that character wherever they are, or queued and paid
-- the next time they load.
--
-- A TICKET IS PENDING WORK, NEVER A PURCHASE. The staged response says
-- `{ok=true, ticket=...}` and the work lands later, as a server-local event
-- that names the player the way the host names them (a string). A ticket that
-- is not OURS is left alone -- "never consume someone else's ticket".
--
-- THE TRAY IS A BODY, NOT A LIST. Every piece belongs to one of the base
-- game's body systems, each with its own slot count, and the whole body has a
-- CAPACITY (`module.lua`). An offer is refused -- in words -- when the system
-- is full, when the platform slot or the grant it needs is taken, or when the
-- chrome would not fit; an upgrade trades the fitted grade in. Four kinds of
-- piece, two paths: a platform implant is STAGED and settled by the completion,
-- and everything the ledger holds (grants, stat chrome, roleplay chrome) is
-- fitted on the spot, because there is nothing to stage and nothing to roll
-- back.
--
-- "NOT READY" IS DIAGNOSED, NOT SHRUGGED AT. The platform answers `current`
-- nil while a record is loading, projecting or restoring -- and for ever when
-- no character was bound, when the support resource is stopped, or when a
-- restore timed out. Every one of those looked the same to a patient ("the
-- record is not ready") and left nothing in the journal. Now the refusal says
-- which it is, the journal carries both halves (the server's binding and the
-- patient's own client projection, asked for over PROBE), and a binding that
-- is stuck is bound again.
--
-- THE SEATS HEAL THEMSELVES, AND ARE ALSO TOLD. Every seat is reaped on touch
-- (a chair whose bodies are gone is a free chair), and a disconnect or a
-- character put down frees theirs at once.

local M = OPX.Modules.Get('ripperdoc')
local Event = M.Event
local Refusal = M.Ripper.Refusal

-- Contracts, resolved on first use rather than in a phase: an optional
-- dependency may publish after this module has run.
local character, jobs = nil, nil

-- chair id -> { sitter, attendant, playback, offer, invite }
local seats = {}
-- normalized player key -> { chair, role, player }
local where = {}
-- normalized player key -> { token, at }: the one-use ticket a patient who
-- stood up hands back to have the powers armed in the chair projected again
local reprojects = {}
-- normalized patient key -> the staged transaction awaiting its completion.
local pending = {}
-- ticket -> a staged transaction whose character left before it completed.
local orphans = {}
-- player -> { at, count }: the recorder lines heard in the current minute.
local recordedBudget = {}
-- Offer ids, so an answer names the offer it answers and not whatever is
-- current by then.
local offerSeq = 0
-- player -> the last time a "not ready" was journalled and a rebind asked for
local diagnosed, rebound = {}, {}
-- player -> the probe the server is waiting on
local probes = {}
-- player -> true while their base-game menu recorder was switched on here
local recording = {}
-- The pending sweep's run flag, so Stop ends it.
local sweeping = false

-- How long an invitation stands, and how long a staged operation may go
-- without a completion before the record is read to settle it.
local INVITE_TIMEOUT_MS = 30000
local PENDING_TIMEOUT_MS = 600000

--- The contracts, fetched once and kept.
local function contracts()
	if character == nil then character = OPX.Api.Get('character') end
	if jobs == nil then jobs = OPX.Api.Get('jobs') end
end

--- One player's character record, or nil when there is none to read.
-- @param player number
-- @return table|nil
local function data(player)
	contracts()
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local ran, record = pcall(character.GetPlayer, player)
	if not ran or type(record) ~= 'table' then return nil end
	-- The contract answers the PLAYER object and the facts live on its
	-- PlayerData -- the same shape `modules/ncpd/server/radio.lua` reads.
	return type(record.PlayerData) == 'table' and record.PlayerData or record
end

--- Whether this character works the chair right now: a ripperdoc, and -- when
--- the config asks, which it does by default -- on duty. Off duty, a
--- ripperdoc is a patient like anybody else (docs/jobs.md: the ripperdoc is
--- paid only while clocked in, so the desk is only theirs then too).
-- @param record table|nil
-- @return boolean
local function operates(record)
	if record == nil then return false end
	local attend = type(M.Settings.ATTEND) == 'table' and M.Settings.ATTEND or {}
	local job = type(record.job) == 'table' and record.job or nil
	if attend.REQUIRE_DUTY == false then
		if type(record.jobs) == 'table' and record.jobs.ripperdoc ~= nil then return true end
		return job ~= nil and job.name == 'ripperdoc'
	end
	return job ~= nil and job.name == 'ripperdoc' and job.onDuty == true
end

--- The one normalizer. The host names players as strings on the cyberware wire
-- ("Player IDs follow host string conventions") and as numbers in this
-- runtime's handlers; one key for both so a ticket matches its patient.
local keyOf = M.Ripper.KeyOf

--- Whether a player sits in a clinic chair right now, as the patient. The
--- chrome ledger asks when it arms a power: a power armed on a seated body
--- never reaches it (`M.Chrome.Reproject`).
-- @param player number
-- @return boolean
function M.Ripper.Seated(player)
	local at = where[keyOf(player)]
	return at ~= nil and at.role == 'sitter'
end

--- The reprojection token a player was handed and has not given back, or nil.
-- @param player number
-- @return string|nil
function M.Ripper.PendingReproject(player)
	local issued = reprojects[keyOf(player)]
	return issued ~= nil and issued.token or nil
end

--- The cyberware store, or nil on a host without it.
local function store()
	return type(Open77) == 'table' and Open77.cyberware or nil
end

--- The durable record, or nil while it is not ready (see the file's note).
-- @param player number
-- @return table|nil
local function recordOf(player)
	local api = store()
	if api == nil or type(api.current) ~= 'function' then return nil end
	local ran, record = pcall(api.current, player)
	if not ran then return nil end
	return type(record) == 'table' and record or nil
end

--- The implant sitting in a slot of a record, or nil.
-- @param record table|nil
-- @param slot string
-- @return table|nil
local function implantOf(record, slot)
	if type(record) ~= 'table' or type(slot) ~= 'string' then return nil end
	local implant = record[slot]
	-- The record names the operating system slot `operatingSystem` on the
	-- wire in some builds and `operating_system` in others; read both.
	if implant == nil and slot == 'operating_system' then implant = record.operatingSystem end
	if implant == nil and slot == 'self_ice' then implant = record.selfIce end
	return type(implant) == 'table' and implant or nil
end

--- A player's position and bucket, read on the server.
-- @param player number
-- @return table|nil
local function positionOf(player)
	local api = type(Open77) == 'table' and Open77.players or nil
	if api == nil or type(api.position) ~= 'function' then return nil end
	local ran, position = pcall(api.position, player)
	if not ran or type(position) ~= 'table' then return nil end
	return position
end

--- Whether the player stands within reach of a chair, IN THE CHAIR'S BUCKET.
--- A chair has one bucket (0 unless its row names one): a player in an
--- instance at the same coordinates is not at this chair.
-- @param player number
-- @param chair table
-- @param reach number
-- @return boolean
local function near(player, chair, reach)
	if chair == nil then return false end
	local position = positionOf(player)
	if position == nil then return false end
	local bucket = tonumber(position.bucket) or 0
	if bucket ~= (tonumber(chair.BUCKET) or 0) then return false end
	local dx = (position.x or 0) - (chair.X or 0)
	local dy = (position.y or 0) - (chair.Y or 0)
	local dz = (position.z or 0) - (chair.Z or 0)
	return (dx * dx + dy * dy + dz * dz) <= (reach * reach)
end

--- Whether a body is in no state to be operated on: down, or dead. The down
--- screen is drawn by the client and proves nothing, so both are asked here.
-- @param player number
-- @return boolean
local function incapacitated(player)
	local downed = OPX.Api.Get('downed')
	if downed ~= nil and type(downed.IsDown) == 'function' then
		local read, answer = pcall(downed.IsDown, player)
		if read and type(answer) == 'table' and answer.ok == true
			and type(answer.value) == 'table' and answer.value.down == true then
			return true
		end
	end
	local players = Open77.players
	if type(players.isDead) == 'function' then
		local read, dead = pcall(players.isDead, player)
		if read and dead == true then return true end
	end
	return false
end

--- The seat for a chair, created on first use.
-- @param chairId string
-- @return table
local function seatOf(chairId)
	local seat = seats[chairId]
	if seat == nil then
		seat = { sitter = nil, attendant = nil, playback = nil, offer = nil, invite = nil }
		seats[chairId] = seat
	end
	return seat
end

-- ── the patient's body ──────────────────────────────────────────────────────

--- Everything one patient has fitted, what it costs the body, and how full
--- each system is. THE SLOT TRUTH IS PLATFORM-FIRST: a platform piece is fitted
--- when the durable record holds its definition; everything else is fitted
--- when the ledger names a grade for it. A platform piece that BROKE was
--- pulled, so it is listed (a repair fits it back) but takes no slot and no
--- capacity -- it is not in the body any more.
-- @param player number
-- @return table { citizen, ready, fitted = { entryId -> piece }, list, used, systems, capacity }
local function patientState(player)
	local citizen = (data(player) or {}).citizenId
	local record = recordOf(player)
	local state = {
		citizen = citizen, ready = record ~= nil, fitted = {}, list = {},
		used = 0, systems = {}, capacity = M.Ripper.CapacityBase(),
	}
	if citizen ~= nil then M.Chrome.Hold(citizen, player) end
	-- THE LEDGER IS ONLY TRUSTED ONCE IT IS READ: before that, a row made up
	-- here would shadow the condition the database holds (a relog, then a
	-- press at the chair, and every implant was "fresh" again).
	local loaded = citizen ~= nil and M.Chrome.Loaded(citizen)
	for _, entry in ipairs(M.Ripper.Catalog()) do
		local row = M.Chrome.Row(citizen, entry.id)
		local gradeId, broken, inBody = nil, row.broken == true, true
		if M.Ripper.IsPlatform(entry) then
			local implant = implantOf(record, entry.SLOT)
			local definition = implant ~= nil and tostring(implant.definition or '') or ''
			if definition ~= '' and definition == M.Ripper.DefinitionFor(entry, nil) then
				gradeId = type(implant.grade) == 'table' and tostring(implant.grade.id or '') or ''
				if not broken and loaded then
					M.Chrome.Adopt(citizen, entry.id, gradeId)
					row = M.Chrome.Row(citizen, entry.id)
				end
			elseif broken and tostring(row.grade or '') ~= '' then
				gradeId, inBody = tostring(row.grade), false
			elseif record == nil and tostring(row.grade or '') ~= '' then
				-- The record cannot be read: the ledger's word is the best
				-- there is, and the tray says the record is not ready.
				gradeId = tostring(row.grade)
			elseif record ~= nil and loaded and tostring(row.grade or '') ~= '' then
				-- The record says this slot does not hold the piece the ledger
				-- remembers: it left the body some other way (another implant in
				-- the slot, a staff removal). The ledger follows the platform, and
				-- a row for a piece nobody wears never wears again.
				M.Chrome.Pull(citizen, entry.id)
			end
		elseif tostring(row.grade or '') ~= '' then
			gradeId = tostring(row.grade)
		end
		if gradeId ~= nil and gradeId ~= '' then
			local grade = M.Ripper.Grade(entry, gradeId)
			local points = math.max(0, math.min(100, tonumber(row.points) or 100))
			local piece = {
				id = entry.id, grade = gradeId, points = points, broken = broken,
				state = M.Ripper.ConditionState(points, broken), inBody = inBody,
				capacity = grade ~= nil and grade.CAPACITY or 0,
				repair = M.Ripper.RepairPrice(grade, points, broken),
			}
			state.fitted[entry.id] = piece
			state.list[#state.list + 1] = piece
			if inBody then
				state.used = state.used + piece.capacity
				state.systems[entry.SYSTEM] = (state.systems[entry.SYSTEM] or 0) + 1
			end
		end
	end
	if M.Effects ~= nil then
		state.capacity = state.capacity + (M.Effects.Totals(citizen).capacity or 0)
	end
	return state
end
M.Ripper.PatientState = patientState

--- The patient's chrome as the page draws it: what is fitted, the body's
--- slots and capacity. The catalogue itself never crosses the wire -- both
--- runtimes read it from the shared config -- so a frame stays small whatever
--- the tray holds.
-- @param player number
-- @return table
local function chromeFor(player)
	local state = patientState(player)
	local fitted = {}
	for _, piece in ipairs(state.list) do
		-- HOW LONG IT HAS LEFT, at the rate the calendar wears it for this
		-- character now, and how much of its extra-wear allowance is spent --
		-- in seconds of its life. Absent for a broken piece.
		local life = M.Chrome.Life(state.citizen, piece.id)
		fitted[#fitted + 1] = {
			id = piece.id, grade = piece.grade, points = math.floor(piece.points + 0.5),
			state = piece.state, broken = piece.broken, inBody = piece.inBody,
			repair = piece.repair,
			left = life.left, wear = life.wear, wearCap = life.wearCap,
		}
	end
	local systems = {}
	for _, system in ipairs(M.Ripper.Systems()) do
		systems[#systems + 1] = { id = system.id, used = state.systems[system.id] or 0,
			slots = system.SLOTS }
	end
	return {
		ready = state.ready,
		fitted = fitted,
		systems = systems,
		capacity = { used = state.used, max = state.capacity,
			enforced = M.Ripper.CapacityEnforced() },
	}
end

-- ── "not ready", diagnosed ──────────────────────────────────────────────────

--- Why one patient's durable record is not ready, as a code the player can
--- read and a detail table the journal carries.
-- @param player number
-- @return string code
-- @return table detail
local function diagnose(player)
	local detail = { player = player }
	local api = store()
	if api == nil or type(api.current) ~= 'function' then return 'noStore', detail end
	contracts()
	local status = character ~= nil and type(character.CyberwareStatus) == 'function'
		and character.CyberwareStatus(player) or nil
	detail.binding = status
	if type(status) == 'table' then
		if status.support ~= 'running' and status.support ~= 'unknown' then
			return 'supportStopped', detail
		end
		if status.outcome == 'refused' then return 'bindRefused', detail end
		if status.outcome == 'skipped' and status.adapter ~= nil then
			-- Another resource owns the binding; whether it bound is its
			-- business, and the record is waiting on it.
			return 'adapterBinding', detail
		end
		if status.outcome == 'skipped' or status.outcome == 'never' then
			return 'unbound', detail
		end
	end
	if incapacitated(player) then return 'bodyNotReady', detail end
	local players = Open77.players
	if type(players.getVehicleSeat) == 'function' then
		local read, seat = pcall(players.getVehicleSeat, player)
		if read and seat ~= nil then return 'bodyNotReady', detail end
	end
	if type(api.leaseState) == 'function' then
		local read, lease = pcall(api.leaseState, player)
		if read and lease ~= nil then
			detail.lease = lease
			return 'leaseActive', detail
		end
	end
	return 'projecting', detail
end

--- A detail table as one journal line.
-- @param value any
-- @param depth integer|nil
-- @return string
local function flat(value, depth)
	depth = depth or 0
	if type(value) ~= 'table' then return tostring(value) end
	if depth > 3 then return '{...}' end
	-- BOUNDED IN BREADTH as well as depth: the probe's answer is a table off
	-- the wire, and the journal line is cut at 1500 characters anyway.
	local keys = {}
	for key in pairs(value) do
		if #keys >= 64 then break end
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		parts[#parts + 1] = key .. '=' .. flat(value[key] ~= nil and value[key]
			or value[tonumber(key)], depth + 1)
	end
	return '{' .. table.concat(parts, ' ') .. '}'
end

--- Journals a "not ready", asks the patient's client what its projection
--- says, and binds a stuck binding again -- each at most once a window, so a
--- patient pressing a disabled button cannot flood anything.
-- @param player number
-- @return string the code
local function onNotReady(player)
	local code, detail = diagnose(player)
	local now = OPX.Now()
	local policy = type(M.Settings.DIAGNOSTICS) == 'table' and M.Settings.DIAGNOSTICS or {}
	local window = tonumber(policy.LOG_EVERY_MS) or 15000
	if diagnosed[player] == nil or now - diagnosed[player] >= window then
		diagnosed[player] = now
		Open77.log.warn(('[ripperdoc] player %d: the cyberware record is not ready (%s) %s')
			:format(player, code, flat(detail)))
		-- The other half lives on the patient's machine.
		local nonce = tostring(now) .. ':' .. tostring(player)
		probes[player] = { nonce = nonce, at = now, code = code }
		pcall(TriggerClientEvent, M.Event.PROBE, player, nonce)
	end
	-- A binding that bound long ago and still projects nothing is a binding
	-- whose restore timed out: the platform parks it as failed for ever, and
	-- binding again is what starts it over.
	local rebindAfter = tonumber(policy.REBIND_AFTER_MS) or 20000
	local status = type(detail.binding) == 'table' and detail.binding or {}
	local stuck = (code == 'projecting' and (tonumber(status.ageMs) or 0) >= rebindAfter)
		or code == 'bindRefused' or code == 'unbound'
	if stuck and (rebound[player] == nil or now - rebound[player] >= rebindAfter)
		and character ~= nil and type(character.RebindCyberware) == 'function' then
		rebound[player] = now
		local ran, after = pcall(character.RebindCyberware, player)
		Open77.log.info(('[ripperdoc] player %d: bound the cyberware identity again -> %s')
			:format(player, ran and flat(after) or tostring(after)))
	end
	return code
end

--- The sentence a "not ready" refusal carries.
-- @param code string
-- @return table flash args
local function notReadyArgs(code)
	return { why = 'ripperdoc.why.' .. tostring(code) }
end

-- ── the frames ──────────────────────────────────────────────────────────────

--- Frees a chair whose bodies are no longer on the server, or no longer at
--- THIS chair. THE cleanup of last resort -- disconnects and unloads free a
--- seat at once, and this catches whatever slipped past them.
-- @param chairId string
local function reap(chairId)
	local seat = seats[chairId]
	if seat == nil then return end
	for role, key in pairs({ sitter = seat.sitter, attendant = seat.attendant }) do
		if key ~= nil then
			local at = where[key]
			local here = at ~= nil and at.chair == chairId and at.role == role
				and data(at.player) ~= nil
			if not here then
				seat[role] = nil
				if role == 'sitter' then seat.playback, seat.offer = nil, nil end
				if at ~= nil and at.chair == chairId then where[key] = nil end
			end
		end
	end
	if seat.invite ~= nil and OPX.Now() - (seat.invite.at or 0) >= INVITE_TIMEOUT_MS then
		seat.invite = nil
	end
end

--- The one offer, as both sides see it.
-- @param seat table
-- @return table|nil
local function offerView(seat)
	local offer = seat.offer
	if offer == nil then return nil end
	return {
		id = offer.id,
		mode = offer.mode,
		entry = offer.entry,
		grade = offer.grade,
		name = offer.name,
		gradeName = offer.gradeName,
		price = offer.price,
		by = offer.byName,
	}
end

--- Everybody worth offering the seat to: players at the chair, in its bucket,
--- who are not part of any chair already. The host's roster read tolerantly --
--- ids arrive as numbers or strings, and a roster of records is humoured.
-- @param chair table
-- @param seat table
-- @return table rows
local function invitees(chair, seat)
	local rows = {}
	local api = type(Open77) == 'table' and Open77.players or nil
	if api == nil or type(api.all) ~= 'function' then return rows end
	local ran, everyone = pcall(api.all)
	if not ran or type(everyone) ~= 'table' then return rows end
	for _, other in ipairs(everyone) do
		if #rows >= 8 then break end
		local otherPlayer = tonumber(type(other) == 'table'
			and (other.id or other.player or other.source or other.playerId) or other)
		local otherKey = otherPlayer ~= nil and keyOf(otherPlayer) or nil
		local record = otherPlayer ~= nil and data(otherPlayer) or nil
		if record ~= nil and otherKey ~= seat.attendant and where[otherKey] == nil
			and near(otherPlayer, chair, M.Ripper.Reach() * 4) then
			rows[#rows + 1] = { id = otherPlayer, name = record.name or tostring(otherPlayer) }
		end
	end
	return rows
end

--- The patient's cash, for the page's "can I afford this" readout. Only ever
--- sent to the patient themselves.
-- @param player number
-- @return number
local function walletOf(player)
	local record = data(player)
	local money = record ~= nil and type(record.money) == 'table' and record.money or {}
	return tonumber(money[M.Ripper.Money()]) or 0
end

--- The whole truth for one player, in one frame. THE AUTO-OPEN IS THIS: the
-- sitter's menu appears because a `sitter` frame arrived, not because anyone
-- pressed a key.
-- @param key number|string
-- @param flash table|nil the sentence to state, if any
-- @return table frame
local function frameFor(key, flash)
	local at = where[key]
	if at == nil then return { mode = 'closed', why = 'noSeat', flash = flash } end
	local seat = seats[at.chair]
	local chair = M.Ripper.Chair(at.chair)
	if seat == nil or chair == nil then return { mode = 'closed', why = 'noSeat', flash = flash } end

	if at.role == 'sitter' then
		return {
			mode = 'sitter',
			chair = at.chair,
			name = chair.NAME,
			attended = seat.attendant ~= nil,
			busy = pending[key] ~= nil,
			offer = offerView(seat),
			chrome = chromeFor(at.player),
			wallet = walletOf(at.player),
			money = M.Ripper.Money(),
			flash = flash,
		}
	end

	local patient = seat.sitter
	local patientAt = patient ~= nil and where[patient] or nil
	return {
		mode = 'desk',
		chair = at.chair,
		name = chair.NAME,
		patient = patientAt ~= nil and patientAt.player or 0,
		seated = patientAt ~= nil,
		patientName = patientAt ~= nil and ((data(patientAt.player) or {}).name
			or tostring(patientAt.player)) or '',
		busy = patient ~= nil and pending[patient] ~= nil,
		offer = offerView(seat),
		invite = seat.invite ~= nil and { name = seat.invite.name or '' } or nil,
		invitees = patientAt == nil and invitees(chair, seat) or {},
		chrome = patientAt ~= nil and chromeFor(patientAt.player) or nil,
		money = M.Ripper.Money(),
		flash = flash,
	}
end

--- Sends one player a frame.
-- @param player number
-- @param frame table
local function pushTo(player, frame)
	if player == nil then return end
	local sent, failure = pcall(TriggerClientEvent, M.Event.FRAME, player, frame)
	if not sent then
		Open77.log.warn('[ripperdoc] the frame did not leave: ' .. tostring(failure))
	end
end

--- Sends a seated player their own fresh frame.
-- @param key number|string
-- @param flash table|nil
local function push(key, flash)
	local at = where[key]
	if at == nil then return end
	pushTo(at.player, frameFor(key, flash))
end

--- Everyone at one chair, refreshed. A flash goes to the actor and to nobody
--- else; `flashes` sends each of the two their own sentence instead.
-- @param seat table
-- @param flash table|nil
-- @param actor number|string|nil
-- @param flashes table|nil key -> flash
local function refresh(seat, flash, actor, flashes)
	-- TWO SLOTS, WALKED EXPLICITLY: `ipairs` over `{sitter, attendant}` would
	-- stop at the first nil and skip the operator on an empty chair.
	for index = 1, 2 do
		local key = index == 1 and seat.sitter or seat.attendant
		if key ~= nil then
			local own = flashes ~= nil and flashes[key] or (actor == key and flash or nil)
			push(key, own)
		end
	end
end

--- States a refusal the way this player can read it: inside the panel when
-- they have one, as a notice when they do not.
-- @param player number
-- @param code string a key of `M.Ripper.Refusal`
-- @param args table|nil
local function refuse(player, code, args)
	local key = keyOf(player)
	local flash = { key = Refusal[code] or code, args = args or {} }
	if where[key] ~= nil then
		push(key, flash)
	else
		pushTo(player, { mode = 'notice', flash = flash })
	end
end

-- ── seating ─────────────────────────────────────────────────────────────────

--- The workspot a patient is posed in (config SEAT.PROFILE, the platform's
--- portable `chair` by default).
-- @return string
local function seatProfile()
	local seat = type(M.Settings.SEAT) == 'table' and M.Settings.SEAT or {}
	return type(seat.PROFILE) == 'string' and seat.PROFILE ~= '' and seat.PROFILE or 'chair'
end

--- Puts the patient in the chair: the platform's portable workspot, posed on
--- the chair's seat (its anchor, `M.Ripper.Anchor`) and facing the way it
--- faces. On a base-game chair that is the chair's own spot and facing, read by
--- the capture -- so the patient sits in the chair the city already placed,
--- with nothing spawned under them.
-- @param source number
-- @param key number|string
-- @param chair table
-- @param seat table
local function sit(source, key, chair, seat)
	local api = type(Open77) == 'table' and Open77.animations or nil
	if api == nil or type(api.playAt) ~= 'function' then
		return refuse(source, 'noHost')
	end
	local anchor = M.Ripper.Anchor(chair)
	local ran, playback, why = pcall(api.playAt, source, seatProfile(),
		{ x = anchor.x, y = anchor.y, z = anchor.z }, anchor.yaw, {})
	if not ran or type(playback) ~= 'table' or playback.playbackId == nil then
		return refuse(source, 'hostRefused',
			{ why = tostring((not ran and playback) or why or 'playAt') })
	end
	-- An invitation to this chair or any other is spent the moment they sit.
	for _, other in pairs(seats) do
		if other.invite ~= nil and other.invite.to == key then other.invite = nil end
	end
	seat.sitter = key
	seat.playback = playback.playbackId
	where[key] = { chair = chair.id, role = 'sitter', player = source }
	-- THE LEDGER ARRIVES BEHIND THE FIRST FRAME. Condition lives in our own
	-- table, so the tray is drawn once as everything-fresh and redrawn the
	-- moment the patient's rows are in -- and any grant they own but are not
	-- holding (a new session) is armed again.
	CreateThread(function()
		M.Chrome.Load((data(source) or {}).citizenId)
		M.Chrome.Ensure(source)
		local seated = seats[chair.id]
		if seated ~= nil and seated.sitter == key then push(key, nil) end
	end)
	-- THE AUTO-OPEN: this frame is the menu appearing in front of them.
	push(key, nil)
	if seat.attendant ~= nil then push(seat.attendant, nil) end
end

--- Takes one player out of whatever chair they are part of, saying why to
--- them and refreshing whoever is left. The one exit every path shares:
--- standing, stepping away, a disconnect, an unload, a chair removed.
-- @param key number|string
-- @param why string
-- @param tell boolean whether to send the leaver their closing frame
local function unseat(key, why, tell)
	local at = where[key]
	-- An invitation TO this player is withdrawn wherever it stands.
	for _, other in pairs(seats) do
		if other.invite ~= nil and other.invite.to == key then
			other.invite = nil
			if other.attendant ~= nil then push(other.attendant, nil) end
		end
	end
	if at == nil then return end
	local seat = seats[at.chair]
	where[key] = nil
	if seat ~= nil then
		if at.role == 'sitter' and seat.sitter == key then
			local api = type(Open77) == 'table' and Open77.animations or nil
			if api ~= nil and seat.playback ~= nil then
				local stop = type(api.stopAt) == 'function' and api.stopAt or api.stop
				if type(stop) == 'function' then
					if stop == api.stopAt then pcall(stop, seat.playback)
					else pcall(stop, at.player, seat.playback) end
				end
			end
			seat.sitter, seat.playback, seat.offer = nil, nil, nil
		elseif at.role == 'attendant' and seat.attendant == key then
			seat.attendant = nil
			-- The operator's open offer and invitation go with the operator.
			if seat.offer ~= nil and seat.offer.byKey == key then seat.offer = nil end
			if seat.invite ~= nil then
				local invitee = seat.invite.player
				seat.invite = nil
				if invitee ~= nil and where[keyOf(invitee)] == nil then
					pushTo(invitee, { mode = 'closed', why = 'withdrawn' })
				end
			end
		end
		refresh(seat, nil, nil)
	end
	if tell then pushTo(at.player, { mode = 'closed', why = why }) end
	-- THE POWERS ARMED IN THE CHAIR GO ON AGAIN ONCE THE PATIENT IS UP. They
	-- reached a body that sat in a workspot, which the movement clients will
	-- not use and do not keep (`M.Chrome.Reproject` says how that looked from
	-- the game) -- and a Sandevistan the patient ALREADY wore died the first
	-- frame they sat, for the same reason. Only the patient's machine knows
	-- when the workspot has really let go of the body, so it is handed a
	-- one-use token and asks with it.
	if at.role == 'sitter' and tell and why ~= 'unloaded'
		and (M.Chrome.Stale(at.player) or M.Chrome.ArmedEntry(at.player, 'reflex') ~= nil) then
		local token = ('%d:%d'):format(OPX.Now(), math.random(1, 1073741823))
		reprojects[key] = { token = token, at = OPX.Now() }
		M.Chrome.PushKit(at.player, { reproject = token })
	end
end

-- ── money ───────────────────────────────────────────────────────────────────

--- Gives a price back to the CHARACTER that paid it: wherever that character
--- is loaded now, or -- when it is not loaded at all -- queued and paid the
--- next time it is. The wiki's "compensate failure", in one place.
-- @param citizenId string|nil
-- @param player number|nil the slot it was paid from, the last resort
-- @param price number
-- @param reason string
local function compensate(citizenId, player, price, reason)
	contracts()
	price = tonumber(price) or 0
	if price <= 0 or character == nil or type(character.AddMoney) ~= 'function' then return end
	local target = nil
	if type(citizenId) == 'string' and type(character.GetPlayerByCitizenId) == 'function' then
		local ran, online = pcall(character.GetPlayerByCitizenId, citizenId)
		if ran and online ~= nil then target = citizenId end
	elseif citizenId == nil then
		target = player
	end
	if target ~= nil then
		local ran, ok = pcall(character.AddMoney, target, M.Ripper.Money(), price, reason)
		if ran and ok == true then return end
	end
	if type(citizenId) ~= 'string' then
		Open77.log.error(('[ripperdoc] the refund of %d for player %s did not land')
			:format(price, tostring(player)))
		return
	end
	CreateThread(function()
		local queued = M.Storage.QueueRefund(citizenId, M.Ripper.Money(), math.floor(price), reason)
		if type(queued) ~= 'table' or queued.ok ~= true then
			Open77.log.error(('[ripperdoc] the refund of %d for %s could not be queued: %s')
				:format(price, citizenId, tostring(type(queued) == 'table' and queued.detail)))
			return
		end
		Open77.log.info(('[ripperdoc] the refund of %d for %s is queued for their next load')
			:format(price, citizenId))
	end)
end

--- Pays one character every refund that waited for them. Each row is deleted
--- BEFORE it is paid, and only by the delete that removed it -- two loads
--- racing cannot pay one refund twice. Yields.
-- @param player number
-- @param citizenId string
local function payQueued(player, citizenId)
	contracts()
	if character == nil or type(character.AddMoney) ~= 'function' then return end
	local rows = M.Storage.FetchRefunds(citizenId)
	if type(rows) ~= 'table' or rows.ok ~= true then return end
	for _, row in ipairs(type(rows.value) == 'table' and rows.value or {}) do
		local gone = M.Storage.DeleteRefund(row.id, citizenId)
		if type(gone) == 'table' and gone.ok == true and tonumber(gone.value) == 1 then
			local ran, ok = pcall(character.AddMoney, player, tostring(row.money_type),
				tonumber(row.amount) or 0, 'ripperdoc:refund')
			if ran and ok == true then
				pcall(OPX.NotifyLocale, player, 'ripperdoc.refunded', { amount = row.amount }, 'info')
			else
				Open77.log.error(('[ripperdoc] a queued refund of %s for %s could not be paid')
					:format(tostring(row.amount), citizenId))
				M.Storage.QueueRefund(citizenId, tostring(row.money_type),
					tonumber(row.amount) or 0, tostring(row.reason or ''))
			end
		end
	end
end

--- Pays the operator through the jobs funnel -- the same `pay` every shift
--- goes through, so the seniority bank and the skill tree see this work like
--- any other. Self-service pays nobody, and an operator who is no longer on
--- duty in the job is not paid for it either.
-- @param citizenId string|nil
-- @param player number|nil
local function payOperator(citizenId, player)
	if citizenId == nil then return end
	if player ~= nil and not operates(data(player)) then return end
	contracts()
	if jobs ~= nil and type(jobs.Award) == 'function' then
		pcall(jobs.Award, citizenId, 'ripperdoc', M.Ripper.Points())
	end
end

-- ── the platform services ───────────────────────────────────────────────────

--- One server resource's state, the host's own word (`running`, `stopped`,
--- `missing`, ...). A host with no reader answers `running`: there is nothing
--- to refuse on.
-- @param name string
-- @return string
local function serviceState(name)
	if type(GetResourceState) ~= 'function' then return 'running' end
	local ran, state = pcall(GetResourceState, name)
	return ran and tostring(state) or 'unknown'
end

--- The first platform resource this piece needs that is not running, or nil.
-- @param entry table
-- @return string|nil name
-- @return string|nil state
local function missingService(entry)
	for _, name in ipairs(M.Ripper.ServicesFor(entry)) do
		local state = serviceState(name)
		if state ~= 'running' then return name, state end
	end
	return nil, nil
end
M.Ripper.MissingService = missingService

-- ── the offer rules ─────────────────────────────────────────────────────────

--- What stands in the way of one piece going into a body, or nil: a full
--- system, the platform slot another implant holds, or the same power on
--- another piece. Only pieces IN the body count; the piece itself never does.
-- @param state table `patientState`
-- @param entry table
-- @return string|nil refusal code
-- @return table|nil refusal args
local function blocked(state, entry)
	local own = state.fitted[entry.id]
	local used = (state.systems[entry.SYSTEM] or 0) - ((own ~= nil and own.inBody) and 1 or 0)
	if used >= M.Ripper.SlotsOf(entry.SYSTEM) then
		return 'systemFull', { system = 'ripperdoc.system.' .. tostring(entry.SYSTEM) }
	end
	for otherId, other in pairs(state.fitted) do
		local otherEntry = otherId ~= entry.id and M.Ripper.Entry(otherId) or nil
		if otherEntry ~= nil and other.inBody then
			if M.Ripper.IsPlatform(entry) and M.Ripper.IsPlatform(otherEntry)
				and otherEntry.SLOT == entry.SLOT then
				return 'slotFilled', { slot = otherEntry.NAME }
			end
			if M.Ripper.IsGrant(entry) and M.Ripper.IsGrant(otherEntry)
				and M.Ripper.GrantKind(otherEntry) == M.Ripper.GrantKind(entry) then
				return 'powerTaken', { name = otherEntry.NAME }
			end
		end
	end
	return nil, nil
end

--- What one intent would do to one patient, or why it may not. The ONE rule
--- book: the offer is priced by it and the acceptance is checked against it
--- again, because the body can change between the two.
-- @param patient number
-- @param entry table
-- @param gradeId string|nil
-- @param mode string `install`, `remove` or `repair`
-- @return table|nil the offer's facts
-- @return string|nil refusal code
-- @return table|nil refusal args
local function rule(patient, entry, gradeId, mode)
	-- A grade the tray does not carry is refused as that, whatever the body
	-- says: nothing about the patient could make it a real grade.
	if mode ~= 'remove' and mode ~= 'repair'
		and M.Ripper.Grade(entry, tostring(gradeId or '')) == nil then
		return nil, 'noSuchGrade', { grade = tostring(gradeId or '') }
	end
	-- A PIECE THAT NEEDS A PLATFORM SERVICE THIS SERVER IS NOT RUNNING is
	-- refused before anybody pays: the platform would accept the order and
	-- nothing would ever reach the body. A pull or a repair is still allowed --
	-- the piece is the patient's either way.
	if mode ~= 'remove' and mode ~= 'repair' then
		-- OFF THE SHELF: chrome nothing on this build can put on the body is
		-- not sold (`VANILLA.SELL_RP`). A patient who wears one already may
		-- still have it pulled or mended.
		if not M.Ripper.Sold(entry) then return nil, 'notSold', { name = entry.NAME } end
		local service = missingService(entry)
		if service ~= nil then return nil, 'serviceDown', { name = service } end
	end
	local state = patientState(patient)
	if M.Ripper.IsPlatform(entry) and not state.ready then
		return nil, 'notReady', notReadyArgs(onNotReady(patient))
	end
	local piece = state.fitted[entry.id]

	if mode == 'remove' then
		if piece == nil then return nil, 'slotEmpty', { slot = entry.NAME } end
		return { mode = 'remove', grade = piece.grade, price = entry.REMOVE, piece = piece }
	end

	if mode == 'repair' then
		if piece == nil then return nil, 'slotEmpty', { slot = entry.NAME } end
		if not piece.broken and piece.points >= 100 then return nil, 'healthy', {} end
		local grade = M.Ripper.Grade(entry, piece.grade)
		if grade == nil then return nil, 'noSuchGrade', { grade = piece.grade } end
		local refit = M.Ripper.IsPlatform(entry) and not piece.inBody
		-- A REFIT puts the implant back in its slot: the slot has to be free,
		-- or the refit would replace whatever the patient wears there now.
		if refit then
			local code, args = blocked(state, entry)
			if code ~= nil then return nil, code, args end
		end
		return { mode = 'repair', grade = piece.grade, price = piece.repair, piece = piece,
			refit = refit }
	end

	local grade = M.Ripper.Grade(entry, tostring(gradeId or ''))
	if grade == nil then return nil, 'noSuchGrade', { grade = tostring(gradeId or '') } end
	if piece ~= nil and piece.grade == grade.id and piece.inBody then
		return nil, 'alreadyFitted', { name = grade.NAME }
	end

	if piece == nil or not piece.inBody then
		-- A PIECE GOING INTO THE BODY -- new, or back in after it broke and
		-- was pulled: the system, the platform slot and the power must all be
		-- free, and each refusal names what is in the way.
		local code, args = blocked(state, entry)
		if code ~= nil then return nil, code, args end
	end

	local old = piece ~= nil and M.Ripper.Grade(entry, piece.grade) or nil
	if M.Ripper.CapacityEnforced() then
		local freed = (piece ~= nil and piece.inBody) and piece.capacity or 0
		local need = state.used - freed + (grade.CAPACITY or 0)
		if need > state.capacity then
			return nil, 'overCapacity', { need = grade.CAPACITY or 0,
				free = math.max(0, state.capacity - state.used + freed) }
		end
	end

	if piece ~= nil then
		-- AN UPGRADE (or a change of grade): the fitted grade is traded in --
		-- a working one. A broken piece is scrap and credits nothing.
		local credit = (old ~= nil and not piece.broken)
			and math.floor((old.PRICE or 0) * M.Ripper.TradeIn()) or 0
		return { mode = 'upgrade', grade = grade.id, price = math.max(0, (grade.PRICE or 0) - credit),
			piece = piece, from = piece.grade }
	end
	return { mode = 'install', grade = grade.id, price = grade.PRICE or 0 }
end
M.Ripper.Rule = rule

-- ── settling ────────────────────────────────────────────────────────────────

--- The sentence a finished job says to the patient.
-- @param mode string
-- @return string
local function doneKey(mode)
	if mode == 'remove' then return 'ripperdoc.done.pull' end
	if mode == 'repair' then return 'ripperdoc.done.repair' end
	if mode == 'upgrade' then return 'ripperdoc.done.upgrade' end
	return 'ripperdoc.done.fit'
end

--- Tells both sides a job is done: the patient what was done, the operator
--- what it paid.
-- @param seat table|nil
-- @param patientKey number|string
-- @param op table
local function announceDone(seat, patientKey, op)
	local flashes = {}
	flashes[patientKey] = { key = doneKey(op.mode), args = { grade = tostring(op.name or op.entry) } }
	if op.operatorPlayer ~= nil then
		flashes[keyOf(op.operatorPlayer)] = {
			key = 'ripperdoc.done.paid', args = { points = M.Ripper.Points() },
		}
	end
	if seat ~= nil then
		refresh(seat, nil, nil, flashes)
	elseif where[patientKey] ~= nil then
		push(patientKey, flashes[patientKey])
	end
end

-- ── making sure it reached the body ─────────────────────────────────────────

--- How long a granted power may stay unprojected before it is taken back
--- and refunded: the platform wants a bound, living, unmounted body and the
--- player's own client to acknowledge it.
local GRANT_READY_MS = 45000
local watchGrant

--- What one grant looks like on the platform right now: `ready`, `pending`,
--- `failed`, `removed`, `absent`, or `unknown` for a shape this reader does
--- not know (which is never refunded on).
-- @param entry table
-- @param player number
-- @return string
local function grantStatus(entry, player)
	local module = M.Ripper.GrantModule(entry)
	if module == nil or type(module.current) ~= 'function' then return 'unknown' end
	local ran, current = pcall(module.current, player)
	if not ran then return 'unknown' end
	if type(current) ~= 'table' then return 'absent' end
	local projection = type(current.projection) == 'table' and current.projection or nil
	local status = projection ~= nil and projection.status or current.status
	if type(status) ~= 'string' or status == '' then return 'unknown' end
	return status
end

--- Tells the patient how to use what they now wear.
-- @param player number
-- @param entry table
local function howTo(player, entry)
	local power = type(entry.POWER) == 'table' and entry.POWER or {}
	local key = (M.Ripper.PowerKey(entry) or (type(power.KEY) == 'string' and power.KEY) or '?'):upper()
	local kind = M.Ripper.GrantKind(entry) or M.Ripper.KindOf(entry)
	if M.Ripper.KindOf(entry) == 'implant' and entry.SLOT == 'arms' then kind = 'arms' end
	if M.Ripper.KindOf(entry) == 'implant' and entry.SLOT == 'legs' then kind = 'legs' end
	-- THE NAME IS TRANSLATED HERE. It went out as its catalogue KEY, so the
	-- patient read "ripperdoc.cw.apogee_sandevistan is live" -- interpolation
	-- puts a parameter in as it is, it does not look it up.
	pcall(OPX.NotifyLocale, player, 'ripperdoc.howto.' .. tostring(kind),
		{ name = locale(entry.NAME), key = key }, 'info')
end
M.Ripper.HowTo = howTo

-- Why a grant that never became usable was taken back, by the last status the
-- platform answered for it: whole keys, so every one is a key the catalogue
-- writes (a key spelt as a prefix plus a status is one no sweep can check).
local GRANT_WHY = {
	pending = 'ripperdoc.why.grant_pending',
	failed = 'ripperdoc.why.grant_failed',
	removed = 'ripperdoc.why.grant_removed',
	absent = 'ripperdoc.why.grant_absent',
}

--- Watches a freshly granted power until the platform says it reached the
--- body. Ready: the patient is told how to use it. Failed, removed, or never
--- ready: it is taken back, the price comes back, and the patient and the
--- journal are told why.
-- @param player number
-- @param citizen string|nil
-- @param entry table
-- @param gradeId string
-- @param price number
watchGrant = function(player, citizen, entry, gradeId, price)
	CreateThread(function()
		local started, last = OPX.Now(), 'pending'
		while OPX.Now() - started < GRANT_READY_MS do
			Wait(500)
			if citizen ~= nil and (data(player) or {}).citizenId ~= citizen then return end
			if not M.Chrome.Armed(player, entry.id) then return end
			last = grantStatus(entry, player)
			if last == 'ready' or last == 'unknown' then
				Open77.log.info(('[ripperdoc] player %d: %s (%s) is live on the body (%s)')
					:format(player, entry.id, tostring(gradeId), last))
				-- A POWER IS EXPLAINED BY THE PATIENT'S OWN MACHINE, because only
				-- it knows the key the power answers to there: the platform's
				-- action carries our default until the player rebinds it, and
				-- then it carries theirs (`client/sandevistan.lua`).
				M.Chrome.PushKit(player, { announce = entry.id })
				return
			end
			if last == 'failed' or last == 'removed' then break end
		end
		Open77.log.warn(('[ripperdoc] player %d: %s (%s) never became usable (%s after %d ms); ' ..
			'taken back and refunded'):format(player, entry.id, tostring(gradeId), last,
				OPX.Now() - started))
		M.Chrome.PullGrant(player, entry)
		compensate(citizen, player, price, 'ripperdoc:refund')
		local key = keyOf(player)
		local flash = { key = Refusal.hostRefused, args = { why = GRANT_WHY[last] or GRANT_WHY.pending } }
		if where[key] ~= nil then push(key, flash)
		else pcall(OPX.NotifyLocale, player, 'ripperdoc.hostRefused', flash.args, 'error') end
	end)
end

--- Stages one platform operation -- an install, an upgrade, a refit, a pull
--- -- and leaves the op carrying its ticket. The charge is NOT touched here:
--- the caller reserved it, and the caller (or `finish`) keeps or returns it.
--- Used for the first try and for the retry after a native failure, which is
--- the same intent with a fresh operation id against the record as it now is.
-- @param source number the patient
-- @param entry table
-- @param op table the staged op; its `facts` say what to do
-- @return boolean staged
-- @return string|nil why not
-- @return boolean|nil the record was not ready (the caller says so in those words)
local function stage(source, entry, op)
	local api = store()
	local record = recordOf(source)
	if api == nil or type(api.install) ~= 'function' or type(api.remove) ~= 'function'
		or type(api.newOperationId) ~= 'function' or type(record) ~= 'table' then
		return false, 'notReady', true
	end
	local facts = op.facts
	-- A fresh operation id per intent, and the revision we actually read: the
	-- two things the wiki says a retry must keep and a new intent must not.
	local okId, operationId = pcall(api.newOperationId)
	operationId = okId and operationId or nil
	local ran, out, reason
	if facts.mode == 'remove' then
		ran, out, reason = pcall(api.remove, source,
			{ slot = entry.SLOT, expectedRevision = record.revision, operationId = operationId })
	else
		-- An install, an upgrade (the platform replaces the slot's implant in
		-- one staging) or the refit of a broken implant from its own grade.
		ran, out, reason = pcall(api.install, source, M.Ripper.DefinitionFor(entry, nil),
			facts.grade, { expectedRevision = record.revision, operationId = operationId,
				slot = entry.SLOT })
	end
	if not ran then out, reason = nil, out end
	if type(out) ~= 'table' or out.ok ~= true then
		return false, tostring(reason or (type(out) == 'table' and (out.reason or out.error))
			or out or 'refused'), false
	end
	op.ticket, op.operationId, op.expectedRevision = out.ticket, operationId, record.revision
	op.at = OPX.Now()
	return true, nil, false
end

--- Takes the price and does or stages the work -- the reserve step of the
--- platform's money rule. The body is checked AGAIN here against the rule book:
--- an offer made a minute ago was priced against a body that may have changed.
-- @param source number the patient
-- @param key number|string the patient's key
-- @param seat table
-- @param offer table
local function settle(source, key, seat, offer)
	if pending[key] ~= nil then
		return refuse(source, 'busy')
	end
	local entry = M.Ripper.Entry(offer.entry)
	if entry == nil then
		return refuse(source, 'noSuchEntry')
	end
	local facts, code, args = rule(source, entry, offer.grade,
		offer.mode == 'upgrade' and 'install' or offer.mode)
	if facts == nil then
		seat.offer = nil
		refresh(seat, { key = Refusal[code] or code, args = args or {} }, key)
		return
	end
	-- The price stands as offered; a body that changed since the offer is
	-- refused here, never re-priced behind the patient's back.
	if facts.mode ~= offer.mode or tostring(facts.grade) ~= tostring(offer.grade) then
		seat.offer = nil
		refresh(seat, { key = Refusal.changed, args = {} }, key)
		return
	end
	local citizen = (data(source) or {}).citizenId

	-- RESERVE, before submission.
	contracts()
	local charged = false
	if (offer.price or 0) <= 0 then
		charged = true
	elseif character ~= nil and type(character.RemoveMoney) == 'function' then
		local ran, ok = pcall(character.RemoveMoney, source, M.Ripper.Money(), offer.price,
			('ripperdoc:%s:%s'):format(offer.mode, offer.entry))
		charged = ran and ok == true
	end
	if not charged then
		seat.offer = nil
		refresh(seat, { key = Refusal.cannotPay, args = { price = offer.price } }, key)
		return
	end
	seat.offer = nil

	local op = {
		mode = facts.mode, entry = entry.id, grade = facts.grade, name = offer.name,
		price = offer.price, patient = source, patientCitizen = citizen,
		operatorPlayer = offer.byPlayer, operatorCitizen = offer.byCitizen,
	}

	-- THE INSTANT PATHS: everything the ledger holds, and a repair of an
	-- implant that is still in the body. Nothing to stage, nothing that can
	-- roll back -- the charge is kept here and the work happens here.
	-- A pull of a piece that is already out of the body (it broke and the
	-- platform took it) is the ledger's alone: staging a remove would pull
	-- whatever the slot holds now.
	local staged = M.Ripper.IsPlatform(entry) and (
		facts.mode == 'install' or facts.mode == 'upgrade'
		or (facts.mode == 'remove' and facts.piece ~= nil and facts.piece.inBody)
		or (facts.mode == 'repair' and facts.refit == true))
	if not staged then
		local ok, why = true, nil
		local grade = M.Ripper.Grade(entry, facts.grade)
		if facts.mode == 'install' or facts.mode == 'upgrade' then
			if M.Ripper.IsGrant(entry) then
				ok, why = M.Chrome.FitGrant(source, entry, grade)
				if ok then watchGrant(source, citizen, entry, facts.grade, offer.price) end
			else
				M.Chrome.Fit(citizen, entry.id, facts.grade)
			end
		elseif facts.mode == 'remove' then
			if M.Ripper.IsGrant(entry) then
				M.Chrome.PullGrant(source, entry)
			else
				M.Chrome.Pull(citizen, entry.id)
			end
		else
			M.Chrome.Repair(citizen, entry.id)
			M.Chrome.Ensure(source)
		end
		if not ok then
			compensate(citizen, source, offer.price, 'ripperdoc:refund')
			refresh(seat, { key = Refusal.hostRefused, args = { why = tostring(why or 'refused') } }, key)
			return
		end
		payOperator(op.operatorCitizen, op.operatorPlayer)
		announceDone(seat, key, op)
		if (facts.mode == 'install' or facts.mode == 'upgrade') and not M.Ripper.IsGrant(entry) then
			Open77.log.info(('[ripperdoc] player %d: %s (%s) fitted'):format(source, entry.id,
				tostring(facts.grade)))
			howTo(source, entry)
		end
		return
	end

	-- THE STAGED PATH: a platform implant.
	op.facts, op.slot = facts, entry.SLOT
	local staged, why, notReady = stage(source, entry, op)
	if not staged then
		compensate(citizen, source, offer.price, 'ripperdoc:refund')
		if notReady then
			refresh(seat, { key = Refusal.notReady, args = notReadyArgs(onNotReady(source)) }, key)
		else
			refresh(seat, { key = Refusal.hostRefused, args = { why = tostring(why) } }, key)
		end
		return
	end
	pending[key] = op
	refresh(seat, nil, nil)
end

local finish

--- Whether a platform failure is the patient's own client failing the native
--- step (as opposed to the record, the definition or a refusal).
-- @param why any
-- @return boolean
local function nativeFailure(why)
	why = tostring(why or '')
	return why == 'native_projection_failed' or why:find('^native_') ~= nil
		or why == 'projection_failed' or why == 'projection_timeout'
end

--- Asks the patient's client what its `open77_cyberware` support says about
--- the projection that just failed -- the reason only that machine knows
--- (`native_leg_slot_owned`, `native_equipment_timeout`...). The answer is
--- journalled and told to the patient in words (the PROBED door).
-- @param player number
-- @param entryId string
local function askWhy(player, entryId)
	player = tonumber(player)
	if player == nil then return end
	local now = OPX.Now()
	local nonce = ('fail:%d:%d'):format(now, player)
	probes[player] = { nonce = nonce, at = now, code = 'nativeFailed', failure = tostring(entryId) }
	pcall(TriggerClientEvent, M.Event.PROBE, player, nonce)
end

--- The retry policy. Never nil.
-- @return table { NATIVE, WAIT_MS }
local function retryPolicy()
	local rules = type(M.Settings.RETRY) == 'table' and M.Settings.RETRY or {}
	return {
		NATIVE = math.max(0, math.floor(tonumber(rules.NATIVE) or 1)),
		WAIT_MS = math.max(0, math.floor(tonumber(rules.WAIT_MS) or 4000)),
	}
end

--- Stages a failed operation again, with the charge still reserved. The slot
--- stays busy while it waits, so nothing else can be sold into it; a patient
--- who leaves in the meantime is refunded (`orphan`), and a retry that cannot
--- be staged settles the op the ordinary way.
-- @param key number|string
-- @param op table
-- @param why string the failure being retried
-- @return boolean whether a retry was started
local function retryNative(key, op, why)
	local rules = retryPolicy()
	if (op.retries or 0) >= rules.NATIVE then return false end
	local entry = M.Ripper.Entry(tostring(op.entry))
	if entry == nil then return false end
	op.retries = (op.retries or 0) + 1
	op.ticket, op.retrying = nil, true
	pending[key] = op
	Open77.log.warn(('[ripperdoc] player %s: the %s of %s (%s) failed natively (%s); trying again ' ..
		'in %d ms (%d of %d)'):format(tostring(op.patient), tostring(op.mode), tostring(op.entry),
		tostring(op.grade), tostring(why), rules.WAIT_MS, op.retries, rules.NATIVE))
	if where[key] ~= nil then
		push(key, { key = 'ripperdoc.retrying', args = { name = entry.NAME } })
	end
	local failedAt = OPX.Now()
	CreateThread(function()
		while pending[key] == op and OPX.Now() - failedAt < rules.WAIT_MS do Wait(250) end
		-- The platform restores the previous record after a failure; the
		-- retry is staged against the record once it reads again.
		while pending[key] == op and recordOf(op.patient) == nil
			and OPX.Now() - failedAt < rules.WAIT_MS + 15000 do
			Wait(500)
		end
		if pending[key] ~= op then return end
		op.retrying = nil
		local staged, again = stage(op.patient, entry, op)
		if not staged then
			pending[key] = op
			return finish(key, op, false, again or why)
		end
		local at = where[key]
		if at ~= nil and seats[at.chair] ~= nil then refresh(seats[at.chair], nil, nil) end
	end)
	return true
end

--- Settles one staged operation, kept or compensated. THE OTHER HALF OF THE
--- MONEY RULE, and the only place a staged charge is kept or given back.
-- @param key number|string
-- @param op table
-- @param done boolean
-- @param why string|nil
function finish(key, op, done, why)
	if key ~= nil then pending[key] = nil end
	if op.ticket ~= nil then orphans[tostring(op.ticket)] = nil end
	if done then
		payOperator(op.operatorCitizen, op.operatorPlayer)
		-- THE LEDGER FOLLOWS THE PLATFORM: the completion is where the piece
		-- becomes the patient's -- or, on a pull, stops being theirs.
		if op.mode == 'remove' then
			M.Chrome.Pull(op.patientCitizen, tostring(op.entry))
		else
			-- A free refit (the one-time reset, an admin) starts its life at
			-- the condition it was given.
			M.Chrome.Fit(op.patientCitizen, tostring(op.entry), tostring(op.grade or ''), op.condition)
		end
		Open77.log.info(('[ripperdoc] player %s: the %s of %s (%s) completed on the platform%s')
			:format(tostring(op.patient), tostring(op.mode), tostring(op.entry), tostring(op.grade),
				op.free ~= nil and (' -- fitted back for free (%s), at %d%%'):format(op.free,
					math.floor(tonumber(op.condition) or 100)) or ''))
		if op.mode ~= 'remove' and key ~= nil and M.Ripper.Entry(tostring(op.entry)) ~= nil then
			howTo(op.patient, M.Ripper.Entry(tostring(op.entry)))
		end
		if key == nil then return end
		local at = where[key]
		announceDone(at ~= nil and seats[at.chair] or nil, key, op)
		return
	end
	-- THE NATIVE STEP FAILED on the patient's own machine: ask it why, and try
	-- once more before giving the money back. The platform's own acceptance
	-- runs record the native equip timing out once and succeeding on the next
	-- try, and a patient who paid should not have to sit down again for that.
	if key ~= nil and op.mode ~= 'remove' and op.facts ~= nil and nativeFailure(why) then
		askWhy(op.patient, op.entry)
		if retryNative(key, op, why) then return end
	end
	-- COMPENSATE: the wiki's word for it, and to the character that paid.
	Open77.log.warn(('[ripperdoc] player %s: the %s of %s (%s) failed on the platform: %s; refunded')
		:format(tostring(op.patient), tostring(op.mode), tostring(op.entry), tostring(op.grade),
			tostring(why or 'rolled_back')))
	compensate(op.patientCitizen, op.patient, op.price, 'ripperdoc:refund')
	if key == nil then return end
	if where[key] ~= nil then
		push(key, { key = Refusal.hostRefused, args = { why = tostring(why or 'rolled_back') } })
	end
	local at = where[key]
	if at ~= nil and seats[at.chair] ~= nil then refresh(seats[at.chair], nil, nil) end
end

--- Takes a staged operation off a slot whose character is going: it is
--- settled against the CHARACTER that paid when its completion comes (or by
--- the sweep), and the slot's next character is not refused as busy by it.
-- @param key number|string
local function orphan(key)
	local op = pending[key]
	if op == nil then return end
	pending[key] = nil
	if op.ticket == nil and op.retrying then
		-- Waiting to be tried again, with nothing staged: there is no
		-- completion to wait for, so the charge goes back now.
		Open77.log.warn(('[ripperdoc] player %s left while the %s of %s waited for its retry; ' ..
			'refunded'):format(tostring(op.patient), tostring(op.mode), tostring(op.entry)))
		CreateThread(function()
			compensate(op.patientCitizen, op.patient, op.price, 'ripperdoc:refund')
		end)
		return
	end
	if op.ticket ~= nil then
		op.orphanedAt = OPX.Now()
		orphans[tostring(op.ticket)] = op
	end
end

--- The platform says the work is done. A ticket that is not one of ours is
--- left for its owner ("never consume someone else's ticket").
-- @param player number|string the host's name for the patient
-- @param ticket any
-- @param encoded string the result, JSON per the wiki
local function onCompleted(player, ticket, encoded)
	local key = keyOf(player)
	local op = pending[key]
	if op == nil or tostring(op.ticket) ~= tostring(ticket) then
		-- A ticket whose character has since gone is still ours to settle,
		-- against the character that paid and with nobody to tell.
		op, key = orphans[tostring(ticket)], nil
		if op == nil then return end
	end
	local done, why = false, nil
	if type(json) == 'table' and type(json.decode) == 'function' then
		local ran, result = pcall(json.decode, tostring(encoded or ''))
		done = ran and type(result) == 'table' and result.ok == true
		why = ran and type(result) == 'table' and (result.error or result.reason) or nil
	end
	finish(key, op, done, why)
end

-- The wiki calls it a server-local event and the example names the same handler
-- as a global entry point. Both doors, one handler: the pending map makes a
-- double delivery a no-op, and neither build of the host can miss the work.
AddEventHandler('onCyberwareOperationCompleted', onCompleted)
onCyberwareOperationCompleted = onCompleted

--- Settles a staged operation that never heard back, by READING what the
--- record now holds rather than guessing: the implant it staged is there (it
--- landed and the event was lost -- keep the charge) or it is not (refund).
--- A pending operation must never wedge a patient's slot for ever.
local function sweepPending()
	local now = OPX.Now()
	-- A ticket whose character went never gets its record read again (the
	-- slot may carry somebody else now): past the long wait it is refunded.
	for ticket, op in pairs(orphans) do
		if now - (op.at or now) >= PENDING_TIMEOUT_MS * 3 then
			Open77.log.warn(('[ripperdoc] the %s of %s for %s never completed after its character ' ..
				'left; refunded'):format(tostring(op.mode), tostring(op.entry), tostring(op.patientCitizen)))
			orphans[ticket] = nil
			finish(nil, op, false, 'timeout')
		end
	end
	for key, op in pairs(pending) do
		-- An op waiting for its native retry has nothing staged to read back;
		-- its own thread stages it or settles it.
		if not op.retrying and now - (op.at or now) >= PENDING_TIMEOUT_MS then
			local same = (data(op.patient) or {}).citizenId == op.patientCitizen
			local record = same and recordOf(op.patient) or nil
			if record ~= nil then
				local implant = implantOf(record, op.slot)
				local entry = M.Ripper.Entry(tostring(op.entry))
				local holds = implant ~= nil and entry ~= nil
					and tostring(implant.definition or '') == M.Ripper.DefinitionFor(entry, nil)
					and (type(implant.grade) ~= 'table' or tostring(implant.grade.id) == tostring(op.grade))
				local landed = (op.mode == 'remove') and implant == nil or (op.mode ~= 'remove' and holds)
				Open77.log.warn(('[ripperdoc] the %s of %s for %s never completed; the record says %s')
					:format(tostring(op.mode), tostring(op.entry), tostring(op.patientCitizen),
						landed and 'it landed' or 'it did not'))
				finish(key, op, landed, 'timeout')
			elseif now - (op.at or now) >= PENDING_TIMEOUT_MS * 3 then
				Open77.log.warn(('[ripperdoc] the %s of %s for %s never completed and the record ' ..
					'cannot be read; refunded'):format(tostring(op.mode), tostring(op.entry),
					tostring(op.patientCitizen)))
				finish(key, op, false, 'timeout')
			end
		end
	end
end

-- ── an implant made whole out of the body ───────────────────────────────────

-- "player|entry" -> { at, revision }: the last pull of a broken implant asked
-- for, and the record revision it was asked against -- so the reconcile does
-- not ask again while that pull is in flight (the record has not moved).
local pullAsked = {}

--- PULLS A BROKEN IMPLANT out of the body through the same remove staging
--- every sale uses, minus the money -- nobody paid for this pull, and its
--- completion is nobody's to settle. Only when the slot holds THIS piece (a
--- remove is by slot) and the character is still the one that broke it. The
--- answer to `ON_BROKEN`, and -- throttled -- to a break the calendar caught up
--- before the patient's record read (`M.Ripper.Refit`).
-- @param player any
-- @param entryId any
-- @param citizen string|nil
-- @param throttle boolean|nil not again while the last pull asked for is in
-- flight (the record has not moved since, for up to 30 s)
-- @return boolean whether a pull was staged
function M.Ripper.PullBroken(player, entryId, citizen, throttle)
	local entry = M.Ripper.Entry(tostring(entryId or ''))
	if entry == nil or not M.Ripper.IsPlatform(entry) then return false end
	player = tonumber(player)
	if player == nil then return false end
	local api = store()
	local record = recordOf(player)
	if api == nil or type(api.remove) ~= 'function' or type(record) ~= 'table' then return false end
	-- THE SLOT MUST HOLD THIS PIECE: a remove is by slot, and a slot that
	-- holds something else now is not this break's to empty.
	local implant = implantOf(record, entry.SLOT)
	if implant == nil or tostring(implant.definition or '') ~= M.Ripper.DefinitionFor(entry, nil) then
		return false
	end
	-- And the character must still be the one that broke it.
	if citizen ~= nil and (data(player) or {}).citizenId ~= citizen then return false end
	local asked = player .. '|' .. entry.id
	local last = pullAsked[asked]
	if throttle and last ~= nil and last.revision == record.revision and OPX.Now() - last.at < 30000 then
		return false
	end
	pullAsked[asked] = { at = OPX.Now(), revision = record.revision }
	local okId, operationId = pcall(api.newOperationId)
	local ran, out, why = pcall(api.remove, player, {
		slot = entry.SLOT, expectedRevision = record.revision,
		operationId = okId and operationId or nil,
	})
	if not (ran and type(out) == 'table' and out.ok == true) then
		Open77.log.warn(('[ripperdoc] the broken %s could not be pulled: %s')
			:format(entry.id, tostring((ran and why) or out or 'refused')))
		return false
	end
	Open77.log.info(('[ripperdoc] %s broke on player %d and was pulled%s'):format(entry.id, player,
		throttle and ' (it broke before the record read)' or ''))
	return true
end

--- FITS BACK, FOR FREE, what the one-time reset or an admin made whole while
--- it was out of the body -- a break pulls an implant, and a ledger that says
--- "whole" over an empty slot would be forgotten by the next frame. Through
--- the same staging every sale uses, and settled by the same completion
--- (`finish`, which starts its life at the condition it was given), one at a
--- time. An implant the record still holds is mended where it is; one whose
--- slot now holds something else stays broken, repairable at a chair. Called
--- on the arrival, every tick and by the admin. Answers how many still wait.
-- @param player number
-- @return integer
function M.Ripper.Refit(player)
	player = tonumber(player)
	local citizen = player ~= nil and (data(player) or {}).citizenId or nil
	if citizen == nil then return 0 end
	-- A BROKEN IMPLANT STILL IN THE BODY -- it ran out while its owner was
	-- away, and was caught up before their record read -- is pulled now.
	for _, entry in ipairs(M.Chrome.BrokenImplants(citizen)) do
		M.Ripper.PullBroken(player, entry.id, citizen, true)
	end
	local waiting = M.Chrome.Refits(citizen)
	if #waiting == 0 then return 0 end
	local key = keyOf(player)
	-- One staged operation per patient: the next waits for this one's end.
	if pending[key] ~= nil then return #waiting end
	local api = store()
	local record = recordOf(player)
	if api == nil or record == nil then return #waiting end
	for _, item in ipairs(waiting) do
		local entry, row = item.entry, item.row
		local implant = implantOf(record, entry.SLOT)
		local definition = implant ~= nil and tostring(implant.definition or '') or ''
		if definition == M.Ripper.DefinitionFor(entry, nil) then
			-- Still in the body (its pull never came): whole where it is.
			Open77.log.info(('[ripperdoc] player %d: %s is still in the body -- made whole there (%s), at %d%%')
				:format(player, entry.id, tostring(row.refit.why), math.floor(tonumber(row.refit.points) or 100)))
			M.Chrome.Mend(citizen, entry.id, row.refit.points)
		elseif implant ~= nil then
			M.Chrome.RefitRefused(citizen, entry.id, 'its slot holds ' .. (definition ~= '' and definition or 'another implant'))
		else
			row.refit.tries = (row.refit.tries or 0) + 1
			local op = {
				mode = 'repair', entry = entry.id, grade = row.grade, name = entry.NAME, price = 0,
				patient = player, patientCitizen = citizen,
				facts = { mode = 'repair', grade = row.grade, refit = true },
				condition = row.refit.points, free = row.refit.why,
			}
			op.slot = entry.SLOT
			local staged, why = stage(player, entry, op)
			if staged then
				pending[key] = op
				Open77.log.info(('[ripperdoc] player %d: %s (%s) is whole again (%s) -- fitted back into the body ' ..
					'for free, at %d%%'):format(player, entry.id, tostring(row.grade), tostring(row.refit.why),
					math.floor(tonumber(row.refit.points) or 100)))
				return #M.Chrome.Refits(citizen)
			end
			Open77.log.warn(('[ripperdoc] player %d: %s could not be fitted back yet (try %d): %s')
				:format(player, entry.id, row.refit.tries, tostring(why)))
		end
	end
	return #M.Chrome.Refits(citizen)
end

-- ── the placement commands ──────────────────────────────────────────────────
--
-- A chair is placed the way `modules/clothing` places a store and
-- `modules/garages` a spot: stand there, look the way the patient should face,
-- run `/opx.clinic.add`. THE CLIENT LOOKS FOR THE CITY'S OWN CHAIR first -- the
-- object under the crosshair, or the nearest chair-like object around -- and
-- sends back where it stands and which way it faces; the server accepts it
-- only within reach of where IT reads the operator standing. Captured on a
-- base-game chair, a chair spawns no prop: the patient sits in the one that is
-- there.

-- The captured chairs by key, and the captures still waiting on the client.
local captures = {}
local captureAsked = {}
-- What an unanswered capture ask is worth waiting for.
local CAPTURE_TIMEOUT_MS = 5000

--- Whether the ACL lets this player run a command. The host resolves
--- `command.<name>` before a COMMAND handler runs, and a net routeway has no
--- such gate of its own -- so the door asks the same question here. An
--- unreadable ACL answers no, and the console is always allowed.
-- @param player number
-- @param name string|nil
-- @return boolean
local function aclAllows(player, name)
	if type(player) == 'number' and player <= 0 then return true end
	if type(name) ~= 'string' or name == '' then return false end
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return false end
	local read, allowed = pcall(acl.isAllowed, player, 'command.' .. name)
	return read and allowed == true
end

--- Rebuilds the captured list every reader merges against.
local function rebuild()
	local rows = {}
	for _, chair in pairs(captures) do rows[#rows + 1] = chair end
	M.Ripper.SetCaptured(rows)
end

-- chair id -> { propId, X, Y, Z, YAW }: the visible chairs, and the row each
-- was spawned from. The prop id stays the STRING the host answered.
local propsOf = {}

--- Spawns and clears the chair props so they match the chairs exactly: one
--- visible chair per chair that needs one -- never on a base-game chair
--- (`PROP = false`), which already stands there.
local function syncProps()
	local api = type(Open77) == 'table' and Open77.props or nil
	local policy = M.Ripper.ChairProp()
	local want = policy.enabled == true and api ~= nil and type(api.create) == 'function'
	local seen = {}
	for _, chair in ipairs(M.Ripper.Chairs()) do
		if chair.PROP ~= false then
			seen[chair.id] = true
			local held = propsOf[chair.id]
			local moved = held ~= nil and (held.X ~= chair.X or held.Y ~= chair.Y
				or held.Z ~= chair.Z or held.YAW ~= chair.YAW)
			if want and (held == nil or moved) then
				if held ~= nil then
					if type(api.remove) == 'function' then pcall(api.remove, held.propId) end
					propsOf[chair.id] = nil
				end
				local offset = type(policy.OFFSET) == 'table' and policy.OFFSET or {}
				local ran, out, refused = pcall(api.create, {
					model = tostring(policy.MODEL or 'furniture.chair.metal'),
					position = {
						x = (chair.X or 0) + (tonumber(offset.X) or 0),
						y = (chair.Y or 0) + (tonumber(offset.Y) or 0),
						z = (chair.Z or 0) + (tonumber(offset.Z) or 0),
					},
					yaw = (chair.YAW or 0) + (tonumber(policy.YAW_OFFSET) or 0),
					streamingRadius = tonumber(policy.STREAMING_RADIUS) or 150.0,
					bucket = tonumber(chair.BUCKET) or 0,
				})
				-- THE ANSWER IS THE PROP ID ITSELF (`wiki/props.md`: "Prop ID as
				-- a decimal string, or nil, reason"); a table is humoured.
				local propId = ''
				if ran then
					if type(out) == 'table' and out.ok == true then
						propId = tostring(out.propId or '')
					elseif type(out) == 'string' or type(out) == 'number' then
						propId = tostring(out)
					end
				end
				if propId ~= '' then
					propsOf[chair.id] = {
						propId = propId, X = chair.X, Y = chair.Y, Z = chair.Z, YAW = chair.YAW,
					}
				else
					local why = (not ran and out)
						or (type(out) == 'table' and (out.reason or out.error)) or refused
					Open77.log.warn(('[ripperdoc] the chair prop for %s was refused: %s')
						:format(tostring(chair.id), tostring(why)))
				end
			end
		end
	end
	for id, held in pairs(propsOf) do
		if not seen[id] or not want then
			if api ~= nil and type(api.remove) == 'function' then
				pcall(api.remove, held.propId)
			end
			propsOf[id] = nil
		end
	end
end

--- The captured chairs as rows, ready for the wire.
-- @return table
local function chairList()
	local rows = {}
	for index, chair in ipairs(M.Ripper.Captured) do rows[index] = chair end
	return rows
end

--- Sends one player every captured chair.
-- @param player number
local function syncChairs(player)
	if type(player) ~= 'number' then return end
	TriggerClientEvent(M.Event.CHAIRS, player, chairList())
end

--- Sends every connected player the chairs. Guarded: a capture must not fail
--- because one connection could not be read.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(syncChairs, tonumber(ids[index]))
		if not sent then
			Open77.log.warn('[ripperdoc] chairs sync failed: ' .. tostring(failure))
		end
	end
end

--- The config line to check in, in the shape `config/ripperdoc.lua` CHAIRS
--- declares: a POSITIONAL row (CHAIRS is walked with `ipairs`, so a keyed
--- `name = {...}` line pasted into it was silently never read), with the seat
--- and what it snapped to when there is one.
-- @param chair table
-- @return string
local function configLine(chair)
	local parts = { ('{ id = %q, NAME = %q, X = %.2f, Y = %.2f, Z = %.2f, YAW = %.1f')
		:format(chair.id, chair.NAME, chair.X, chair.Y, chair.Z, chair.YAW) }
	local seat = type(chair.SEAT) == 'table' and chair.SEAT or nil
	if seat ~= nil and ((seat.FORWARD or 0) ~= 0 or (seat.RIGHT or 0) ~= 0
		or (seat.UP or 0) ~= 0 or (seat.YAW or 0) ~= 0) then
		parts[#parts + 1] = ('SEAT = { FORWARD = %.2f, RIGHT = %.2f, UP = %.2f, YAW = %.1f }')
			:format(seat.FORWARD or 0, seat.RIGHT or 0, seat.UP or 0, seat.YAW or 0)
	end
	if chair.FX ~= nil and chair.FY ~= nil then
		parts[#parts + 1] = ('FX = %.4f, FY = %.4f'):format(chair.FX, chair.FY)
	end
	if (tonumber(chair.BUCKET) or 0) ~= 0 then
		parts[#parts + 1] = ('BUCKET = %d'):format(chair.BUCKET)
	end
	if type(chair.VANILLA) == 'table' then
		parts[#parts + 1] = ('VANILLA = { CLASS = %q, NAME = %q, ENGINE = %q }, PROP = false')
			:format(chair.VANILLA.CLASS or '', chair.VANILLA.NAME or '', chair.VANILLA.ENGINE or '')
	end
	return '  ' .. table.concat(parts, ', ') .. ' },'
end

--- Prints every chair: position, facing, seat, and where it comes from.
-- @param source number
local function report(source)
	local lines = {}
	local capturedCount = 0
	local chairs = M.Ripper.Chairs()
	for _, chair in ipairs(chairs) do
		local fromDatabase = captures[chair.id] ~= nil
		if fromDatabase then capturedCount = capturedCount + 1 end
		local anchor = M.Ripper.Anchor(chair)
		lines[#lines + 1] = ('%s %s pos=%.2f,%.2f,%.2f yaw=%.1f seat=%.2f,%.2f,%.2f yaw=%.1f%s %s')
			:format(chair.id, tostring(chair.NAME), chair.X or 0.0, chair.Y or 0.0, chair.Z or 0.0,
				chair.YAW or 0.0, anchor.x, anchor.y, anchor.z, anchor.yaw,
				type(chair.VANILLA) == 'table' and (' on ' .. tostring(chair.VANILLA.CLASS)) or '',
				fromDatabase and 'captured' or 'config')
	end
	lines[#lines + 1] = ('%d chair(s): %d from config, %d captured')
		:format(#chairs, #chairs - capturedCount, capturedCount)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- The seat policy's numbers.
-- @return table
local function seatPolicy()
	return type(M.Settings.SEAT) == 'table' and M.Settings.SEAT or {}
end

--- What a capture's snap is worth: a base-game chair the client found, inside
--- reach of where the SERVER reads the operator, with finite numbers -- or nil.
-- @param player number
-- @param snap any off the wire
-- @return table|nil
local function snapOf(player, snap)
	if type(snap) ~= 'table' then return nil end
	local finiteNumber = OPX.Math.Finite
	local x, y, z = finiteNumber(snap.x), finiteNumber(snap.y), finiteNumber(snap.z)
	if x == nil or y == nil or z == nil then return nil end
	local position = positionOf(player)
	if position == nil then return nil end
	local radius = tonumber(seatPolicy().SNAP_RADIUS) or 6
	local dx, dy, dz = x - (position.x or 0), y - (position.y or 0), z - (position.z or 0)
	if dx * dx + dy * dy + dz * dz > radius * radius then return nil end
	local function word(value)
		return type(value) == 'string' and value:gsub('%c', ''):sub(1, 96) or ''
	end
	return {
		x = x, y = y, z = z, yaw = finiteNumber(snap.yaw),
		fx = finiteNumber(snap.fx), fy = finiteNumber(snap.fy),
		class = word(snap.class), name = word(snap.name), engine = word(tostring(snap.engine or '')),
		source = word(snap.source), bucket = tonumber(position.bucket) or 0,
	}
end

--- Saves one chair row and its seat. Yields.
-- @param chair table
-- @return boolean
-- @return string|nil
local function persist(chair)
	local saved = M.Storage.Upsert(chair)
	if type(saved) ~= 'table' or saved.ok ~= true then
		return false, type(saved) == 'table' and saved.detail or 'no answer'
	end
	local seat = type(chair.SEAT) == 'table' and chair.SEAT or {}
	local vanilla = type(chair.VANILLA) == 'table' and chair.VANILLA or {}
	local seated = M.Storage.UpsertSeat(chair.id, {
		FORWARD = seat.FORWARD, RIGHT = seat.RIGHT, UP = seat.UP, YAW = seat.YAW,
		FX = chair.FX, FY = chair.FY, CLASS = vanilla.CLASS, NAME = vanilla.NAME,
		ENGINE = vanilla.ENGINE, BUCKET = chair.BUCKET,
	})
	if type(seated) ~= 'table' or seated.ok ~= true then
		return false, type(seated) == 'table' and seated.detail or 'no answer'
	end
	return true, nil
end

--- Saves one captured chair: the position from the server, or the base-game
--- chair the client found near it. Yields.
-- @param player number
-- @param key string
-- @param label string
-- @param yaw any the client's own facing, or nil
-- @param rawSnap any what the client found, or nil
local function capture(player, key, label, yaw, rawSnap)
	local position = positionOf(player)
	local snap = snapOf(player, rawSnap)
	local x, y, z, heading = position ~= nil and position.x or nil,
		position ~= nil and position.y or nil, position ~= nil and position.z or nil, yaw
	local extra = { BUCKET = position ~= nil and tonumber(position.bucket) or 0 }
	local guessed = false
	if snap ~= nil then
		x, y, z = snap.x, snap.y, snap.z
		heading = snap.yaw
		if heading == nil then
			-- THE ENGINE GAVE NO FACING. The operator is at the chair looking
			-- at it, so the chair most likely faces THEM: the patient is posed
			-- looking back at the operator, and the answer says how to turn it.
			local own = OPX.Math.Finite(yaw)
			heading, guessed = own ~= nil and (own + 180.0) % 360.0 or 0.0, true
		end
		extra.FX, extra.FY = snap.fx, snap.fy
		local defaults = type(seatPolicy().VANILLA) == 'table' and seatPolicy().VANILLA or {}
		extra.SEAT = { FORWARD = defaults.FORWARD, RIGHT = defaults.RIGHT, UP = defaults.UP,
			YAW = defaults.YAW }
		if snap.class ~= '' or snap.name ~= '' or snap.engine ~= '' then
			extra.VANILLA = { CLASS = snap.class, NAME = snap.name, ENGINE = snap.engine }
		end
		extra.BUCKET = snap.bucket
	end
	local chair, why = M.Ripper.Row(key, label, x, y, z, heading, extra)
	if chair == nil then
		Open77.log.warn(('[ripperdoc] player %d capture of %s refused: %s')
			:format(player, tostring(key), tostring(why)))
		return OPX.CommandResult(player, false, tostring(why))
	end

	local saved, detail = persist(chair)
	if not saved then
		Open77.log.warn(('[ripperdoc] player %d could not save the capture of %s: %s')
			:format(player, tostring(chair.id), tostring(detail)))
		return OPX.CommandResult(player, false, 'could not save the chair')
	end

	captures[chair.id] = chair
	rebuild()
	syncAll()
	syncProps()
	local found = snap ~= nil and ('snapped to the base-game %s %q (%s)%s')
		:format(snap.class ~= '' and snap.class or 'object', snap.name, snap.source,
			guessed and (' -- its facing could not be read, so it faces you; /opx.clinic.tune '
				.. chair.id .. ' 0 0 0 180 turns it round') or '')
		or (rawSnap ~= nil and 'no base-game chair within reach -- captured where you stand'
		or 'captured where you stand')
	Open77.log.info(('[ripperdoc] %s captured at %.2f,%.2f,%.2f yaw=%.1f by %d: %s')
		:format(chair.id, chair.X, chair.Y, chair.Z, chair.YAW, player, found))
	OPX.CommandResult(player, true,
		('%s saved, %s -- sit in it to check, /opx.clinic.tune %s to adjust, and check it in ' ..
			'to survive a database reset:\n%s'):format(chair.id, found, chair.id, configLine(chair)))
end

--- Watches one capture ask and says so when the client never answered.
-- @param player number
-- @param askedAt number
-- @param key string
local function watchCapture(player, askedAt, key)
	CreateThread(function()
		while true do
			local entry = captureAsked[player]
			if entry == nil or entry.at ~= askedAt then return end
			if OPX.Now() - askedAt >= CAPTURE_TIMEOUT_MS then break end
			Wait(100)
		end
		local entry = captureAsked[player]
		if entry == nil or entry.at ~= askedAt then return end
		captureAsked[player] = nil
		Open77.log.warn(('[ripperdoc] player %d did not answer the capture of %s within %d ms; ' ..
			'nothing was saved'):format(player, tostring(key), CAPTURE_TIMEOUT_MS))
		OPX.NotifyLocale(player, 'ripperdoc.captureNoAnswer', { key = tostring(key) }, 'error')
	end)
end

--- Registers one command from the config, or nothing when it is unnamed.
-- @param name string|nil
-- @param opts table
-- @param handler function
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

--- One chair's seat, moved by the operator. Yields.
-- @param source number
-- @param key string
-- @param args table
local function tune(source, key, args)
	local chair = captures[key]
	local config = chair == nil and M.Ripper.Chair(key) or nil
	if chair == nil and config == nil then
		return OPX.CommandResult(source, false, 'no chair named ' .. tostring(key))
	end
	local numbers = {}
	for index = 2, 5 do
		local value = OPX.Math.Finite(args[index])
		if args[index] ~= nil and value == nil then
			return OPX.CommandResult(source, false,
				'usage: tune <key> <forward> <right> <up> [yaw] -- metres and degrees')
		end
		numbers[#numbers + 1] = value or 0
	end
	local base = chair or config
	local moved, why = M.Ripper.Row(base.id, base.NAME, base.X, base.Y, base.Z, base.YAW, {
		SEAT = { FORWARD = numbers[1], RIGHT = numbers[2], UP = numbers[3], YAW = numbers[4] },
		FX = base.FX, FY = base.FY, BUCKET = base.BUCKET, VANILLA = base.VANILLA,
		PROP = base.PROP,
	})
	if moved == nil then return OPX.CommandResult(source, false, tostring(why)) end
	if chair == nil then
		-- A config chair is the file's: print the line, change nothing.
		return OPX.CommandResult(source, true,
			'that chair comes from config; paste this over its row:\n' .. configLine(moved))
	end
	local saved, detail = persist(moved)
	if not saved then
		return OPX.CommandResult(source, false, 'could not save: ' .. tostring(detail))
	end
	captures[moved.id] = moved
	rebuild()
	syncAll()
	local anchor = M.Ripper.Anchor(moved)
	OPX.CommandResult(source, true,
		('%s seat moved to %.2f,%.2f,%.2f yaw=%.1f -- stand up and sit again to see it:\n%s')
			:format(moved.id, anchor.x, anchor.y, anchor.z, anchor.yaw, configLine(moved)))
end

--- The diagnosis command's answer for one player.
-- @param source number the asker
-- @param target number the patient
local function diagnosisReport(source, target)
	local lines = {}
	local state = patientState(target)
	local code = state.ready and 'ready' or (diagnose(target))
	local _, detail = diagnose(target)
	lines[#lines + 1] = ('player %d citizen=%s record=%s'):format(target,
		tostring(state.citizen), state.ready and 'ready' or ('not ready (' .. code .. ')'))
	lines[#lines + 1] = 'binding ' .. flat(detail.binding)
	-- Capacity is a sum of effect-scaled numbers (a worn piece counts for a
	-- fraction of its effect), so it reaches this line with a fraction in it
	-- -- and `%d` raises on one. The same treatment the points line below
	-- already gives its own number.
	lines[#lines + 1] = ('capacity %d/%d, %d piece(s)'):format(
		math.floor(state.used + 0.5), math.floor(state.capacity + 0.5), #state.list)
	for _, piece in ipairs(state.list) do
		local life = M.Chrome.Life(state.citizen, piece.id)
		local hours = life.left ~= nil and math.floor(life.left / 3600) or nil
		lines[#lines + 1] = ('  %s %s %d%% %s%s%s'):format(piece.id, piece.grade,
			math.floor(piece.points + 0.5), piece.state, piece.inBody and '' or ' (out of the body)',
			hours ~= nil and (', %dd %02dh left, hard use %.1f of %.1f h'):format(hours // 24, hours % 24,
				(life.wear or 0) / 3600, (life.wearCap or 0) / 3600) or '')
	end
	if M.Effects ~= nil then
		lines[#lines + 1] = 'effects ' .. flat(M.Effects.Totals(state.citizen))
		lines[#lines + 1] = 'applied ' .. flat(M.Effects.Snapshot(target))
	end
	local probe = probes[target]
	if probe ~= nil and probe.answer ~= nil then
		lines[#lines + 1] = 'client ' .. tostring(probe.line or flat(probe.answer))
	end
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
	-- Ask the client too; its answer lands in the journal.
	local nonce = tostring(OPX.Now()) .. ':' .. tostring(target)
	probes[target] = { nonce = nonce, at = OPX.Now(), code = code }
	pcall(TriggerClientEvent, M.Event.PROBE, target, nonce)
end

--- Registers the placement, listing, removal, seat, diagnosis and recorder
--- commands.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	-- THE SANDEVISTAN KEY, on the caller's own machine: which key engages the
	-- overdrive, a new one, or `reset` back to POWER_KEYS.reflex. UNRESTRICTED
	-- because it reads and rebinds the caller's own binding and nothing else;
	-- the rebind is the platform's own (`Open77.input.rebind`), persisted on
	-- their machine and kept on every server.
	register(names.key, {
		restricted = false,
		help = 'ripperdoc.help.key',
		params = {
			{ name = 'key', optional = true, help = locale('ripperdoc.help.keyArg') },
		},
	}, function(source, args)
		local player = tonumber(source)
		if player == nil or player <= 0 then
			return OPX.CommandResult(source, false, 'in game only: the key lives on the player\'s machine')
		end
		local wanted = type(args[1]) == 'string' and OPX.String.Trim(args[1]) or ''
		if wanted:lower() == 'reset' or wanted == '' then
			wanted = wanted:lower()
		else
			local key = M.Ripper.PowerKeyValid(wanted)
			if key == nil then
				pcall(OPX.NotifyLocale, player, 'ripperdoc.key.invalid', { key = wanted }, 'error')
				return
			end
			wanted = key:upper()
		end
		pcall(TriggerClientEvent, M.Event.KEYBIND, player, wanted)
	end)

	-- A WHOLE SANDEVISTAN WITHOUT THE OVERDRIVE, on the caller: the look, the
	-- layers, the slowed world and the screen, through the same code as a real
	-- boost. Restricted, because it slows everybody near the caller.
	register(names.test, {
		restricted = true,
		help = 'ripperdoc.help.test',
		params = {
			{ name = 'seconds', optional = true, help = locale('ripperdoc.help.testArg') },
		},
	}, function(source, args)
		local player = tonumber(source)
		if player == nil or player <= 0 then
			return OPX.CommandResult(source, false, 'in game only: the test runs on the caller')
		end
		-- Up to the longest boost a level can make (`M.Ripper.SANDY_MAX_SECONDS`),
		-- so a 40 s boost's presentation can be checked end to end.
		local seconds = math.floor(tonumber(args[1]) or 9)
		seconds = math.max(1, math.min(M.Ripper.SANDY_MAX_SECONDS, seconds))
		local done, why = M.Sandy.Simulate(player, seconds * 1000, 'reflex_heavy')
		OPX.CommandResult(source, done == true, done and
			('a %d s Sandevistan on you, without the overdrive'):format(seconds) or ('refused: ' .. tostring(why)))
	end)

	-- THE ADMIN'S OVERRIDE: every piece of chrome fitted on the CALLER set at
	-- once -- `full` (a fresh life on everything: repaired, re-armed, a broken
	-- implant fitted back), a condition from 1 to 100 (a life with that much
	-- left), or 0 (everything broken, exactly as wear breaks it). Restricted,
	-- and in game only: it is the caller's own body.
	register(names.chrome, {
		restricted = true,
		help = 'ripperdoc.help.chrome',
		params = {
			{ name = 'condition', help = locale('ripperdoc.help.chromeArg') },
		},
	}, function(source, args)
		local player = tonumber(source)
		if player == nil or player <= 0 then
			return OPX.CommandResult(source, false, 'in game only: it sets the chrome fitted on the caller')
		end
		local wanted = type(args[1]) == 'string' and OPX.String.Trim(args[1]):lower() or ''
		local value = wanted == 'full' and 100 or OPX.Math.Finite(tonumber(wanted))
		if value == nil or value < 0 or value > 100 then
			return OPX.CommandResult(source, false,
				'usage: chrome <full|0-100> -- the condition of every piece fitted on you')
		end
		local citizen = (data(player) or {}).citizenId
		if citizen == nil then return OPX.CommandResult(source, false, 'no character is loaded on you') end
		CreateThread(function()
			M.Chrome.Hold(citizen, player)
			M.Chrome.Load(citizen)
			if not M.Chrome.Loaded(citizen) then
				return OPX.CommandResult(source, false, 'your chrome could not be read: try again')
			end
			-- Whatever the platform's record holds and the ledger has not taken
			-- in yet is taken in first, so it is set too.
			patientState(player)
			local set = M.Chrome.SetAll(player, citizen, value)
			if #set == 0 then
				return OPX.CommandResult(source, true, 'you have no chrome fitted: nothing to set')
			end
			local lines = {}
			for _, row in ipairs(set) do
				local entry = M.Ripper.Entry(row.id)
				local life = M.Chrome.Life(citizen, row.id)
				local now = M.Chrome.Row(citizen, row.id)
				local left
				if now.broken and now.refit ~= nil then
					left = 'out of the body: being fitted back for free'
				elseif now.broken and row.refit then
					left = 'still broken: it cannot go back in (its slot holds another implant)'
				elseif now.broken then
					left = 'broken'
				elseif life.left ~= nil then
					local hours = math.floor(life.left / 3600)
					left = ('%dd %02dh left'):format(hours // 24, hours % 24)
				else
					left = 'no clock (durability off)'
				end
				lines[#lines + 1] = ('%s (%s): %d%% -> %d%%, %s'):format(
					entry ~= nil and locale(entry.NAME) or row.id, tostring(row.grade),
					math.floor(row.before + 0.5), math.floor(row.after + 0.5), left)
			end
			Open77.log.info(('[ripperdoc] player %d (%s) set their own chrome to %s: %s'):format(player, citizen,
				wanted == 'full' and 'full' or ('%d%%'):format(math.floor(value + 0.5)), table.concat(lines, '; ')))
			OPX.CommandResult(source, true, ('%d piece(s) set to %s:\n%s'):format(#set,
				wanted == 'full' and 'full' or ('%d%%'):format(math.floor(value + 0.5)), table.concat(lines, '\n')))
		end)
	end)

	register(names.add, {
		restricted = true,
		help = 'ripperdoc.help.add',
		params = {
			{ name = 'key', optional = true, help = locale('ripperdoc.help.addKey') },
			{ name = 'label', optional = true, help = locale('ripperdoc.help.addLabel') },
		},
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key > M.Ripper.MAX_KEY then
			return OPX.CommandResult(source, false,
				('usage: add [key] [label] -- a key is 1 to %d characters'):format(M.Ripper.MAX_KEY))
		end
		if #key == 0 then
			-- Named back in the answer: a chair whose key the operator never
			-- learned could not be removed or checked in afterwards.
			local index = 0
			repeat index = index + 1
				until captures['clinic' .. index] == nil and M.Ripper.Chair('clinic' .. index) == nil
			key = 'clinic' .. index
		end
		local label = ''
		for index = 2, #args do
			label = label .. (index > 2 and ' ' or '') .. tostring(args[index])
		end

		-- The facing and the base-game chair are the client's to find -- a
		-- chat command has neither -- recorded before the ask, so an answer
		-- that arrives immediately cannot be mistaken for an earlier one.
		local at = OPX.Now()
		captureAsked[source] = { at = at }
		TriggerClientEvent(M.Event.CAPTURE, source, key, label)
		Open77.log.info(('[ripperdoc] asked player %d to find the chair %s')
			:format(source, tostring(key)))
		watchCapture(source, at, key)
		OPX.CommandResult(source, true,
			'looking for the base-game chair you are at; aim at it, or stand where the patient sits')
	end)

	register(names.remove, {
		restricted = true,
		help = 'ripperdoc.help.remove',
		params = { { name = 'key', help = locale('ripperdoc.help.removeKey') } },
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then return OPX.CommandResult(source, false, 'usage: remove <key>') end
		if captures[key] == nil then
			return OPX.CommandResult(source, false, M.Ripper.Chair(key) ~= nil
				and 'that chair comes from config; edit config/ripperdoc.lua to remove it'
				or 'no captured chair named ' .. key)
		end
		CreateThread(function()
			local gone = M.Storage.Delete(key)
			if type(gone) ~= 'table' or gone.ok ~= true then
				return OPX.CommandResult(source, false, 'could not delete the chair')
			end
			M.Storage.DeleteSeat(key)
			-- WHOEVER IS AT IT IS STOOD UP FIRST: a chair that vanished under a
			-- patient left them "seated" at a chair that no longer existed,
			-- refused at every other clinic with no panel to stand up from.
			local seat = seats[key]
			if seat ~= nil then
				if seat.sitter ~= nil then unseat(seat.sitter, 'removed', true) end
				if seat.attendant ~= nil then unseat(seat.attendant, 'removed', true) end
				seats[key] = nil
			end
			captures[key] = nil
			rebuild()
			syncAll()
			syncProps()
			Open77.log.info(('[ripperdoc] %s removed by %d'):format(key, source))
			OPX.CommandResult(source, true, key .. ' removed.')
		end)
	end)

	register(names.list, { restricted = true, help = 'ripperdoc.help.list' }, function(source)
		report(source)
	end)

	register(names.tune, {
		restricted = true,
		help = 'ripperdoc.help.tune',
		params = {
			{ name = 'key', help = locale('ripperdoc.help.removeKey') },
			{ name = 'forward', optional = true, help = locale('ripperdoc.help.tuneForward') },
			{ name = 'right', optional = true, help = locale('ripperdoc.help.tuneRight') },
			{ name = 'up', optional = true, help = locale('ripperdoc.help.tuneUp') },
			{ name = 'yaw', optional = true, help = locale('ripperdoc.help.tuneYaw') },
		},
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then
			return OPX.CommandResult(source, false, 'usage: tune <key> <forward> <right> <up> [yaw]')
		end
		CreateThread(function() tune(source, key, args) end)
	end)

	register(names.diag, {
		restricted = true,
		help = 'ripperdoc.help.diag',
		params = { { name = 'player', optional = true, help = locale('ripperdoc.help.diagPlayer') } },
	}, function(source, args)
		local target = tonumber(args[1]) or source
		if target == nil or target <= 0 or data(target) == nil then
			return OPX.CommandResult(source, false, 'usage: diag [playerId] -- a loaded player')
		end
		diagnosisReport(source, target)
	end)

	register(names.records, {
		restricted = true,
		help = 'ripperdoc.help.records',
		params = {
			{ name = 'mode', optional = true, help = locale('ripperdoc.help.recordsMode') },
			{ name = 'player', optional = true, help = locale('ripperdoc.help.diagPlayer') },
		},
	}, function(source, args)
		local mode = type(args[1]) == 'string' and args[1]:lower() or 'read'
		if mode == 'status' then
			CreateThread(function()
				M.Reader.Kept()
				OPX.CommandResult(source, true, M.Reader.Status())
			end)
			return
		end
		if mode ~= 'read' then
			return OPX.CommandResult(source, false, 'usage: records [read|status] [playerId]')
		end
		local target = tonumber(args[2]) or source
		if target == nil or target <= 0 then
			return OPX.CommandResult(source, false, 'the console has no game to read with: name a player')
		end
		local started, why = M.Reader.Start(target)
		if not started then return OPX.CommandResult(source, false, tostring(why)) end
		OPX.CommandResult(source, true, ('reading %d base-game cyberware records through player %d; ' ..
			'/%s status to follow it'):format(M.Reader.Total(), target, names.records))
	end)

	register(names.record, {
		restricted = true,
		help = 'ripperdoc.help.record',
		params = {
			{ name = 'mode', optional = true, help = locale('ripperdoc.help.recordMode') },
			{ name = 'player', optional = true, help = locale('ripperdoc.help.diagPlayer') },
		},
	}, function(source, args)
		local mode = type(args[1]) == 'string' and args[1]:lower() or 'on'
		if mode ~= 'on' and mode ~= 'off' and mode ~= 'dump' and mode ~= 'snap' then
			return OPX.CommandResult(source, false, 'usage: record [on|off|dump|snap] [playerId]')
		end
		local target = tonumber(args[2]) or source
		if target == nil or target <= 0 then
			return OPX.CommandResult(source, false, 'the console records nobody: name a player')
		end
		recording[target] = mode ~= 'off' or nil
		pcall(TriggerClientEvent, M.Event.RECORD, target, mode)
		Open77.log.info(('[ripperdoc] base-game menu recorder %s for player %d (asked by %d)')
			:format(mode, target, source))
		OPX.CommandResult(source, true, ('recorder %s for player %d -- lines land in the server ' ..
			'journal as [ripperdoc:rec]'):format(mode, target))
	end)
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- Whether a net intent from this player may run now: the one floor every
--- intent shares, so a held key or a scripted client cannot turn the clinic
--- into a frame generator.
-- @param source number
-- @param what string
-- @return boolean
local function throttled(source, what)
	return OPX.Cooling(source, 'ripperdoc.' .. what, what == 'ask' and 1000 or 200)
end

--- The sender of a net event, or nil. THE SENDER IS THE `source` GLOBAL,
--- never a parameter: the host delivers payload only and names the
--- connection in `source` around the call.
-- @return number|nil
local function sender()
	local player = tonumber(source)
	if player == nil or player <= 0 then return nil end
	return player
end

--- The operator's standing, checked again at every press: still at the
--- chair, still on duty. An operator who walked away or clocked off is
--- stepped away from the desk rather than left driving it from across the city.
-- @param source number
-- @param key number|string
-- @param at table
-- @return boolean
local function operatorStands(source, key, at)
	local chair = M.Ripper.Chair(at.chair)
	if chair ~= nil and near(source, chair, M.Ripper.Reach() * 2) and operates(data(source)) then
		return true
	end
	unseat(key, 'left', true)
	refuse(source, chair ~= nil and not near(source, chair, M.Ripper.Reach() * 2)
		and 'tooFar' or 'notRipperdoc')
	return false
end

--- Resets the module's world (a reload starts clean).
function M.Init()
	seats, where, pending, orphans, recordedBudget = {}, {}, {}, {}, {}
	reprojects = {}
	offerSeq = 0
	captures, captureAsked, propsOf = {}, {}, {}
	diagnosed, rebound, probes, recording = {}, {}, {}, {}
	pullAsked = {}
	M.Reader.Reset()
	rebuild()
	M.Ripper.ResetCatalog()
	OPX.Schema.Add(M.Storage.SCHEMA)
	M.Chrome.Init()
	M.Effects.Init()
	M.Sandy.Init()
end

--- Wires the doors: the press, the intents, the completion, the commands.
function M.Start()
	-- THE WEAR AND THE GRANTS GO UP FIRST: the movement, hack and ICE shelves
	-- beside the cyberware one, and every host wear event starts counting.
	M.Chrome.Start()
	M.Effects.Start()
	-- The Sandevistan's look on the body, and the overdrive a client lost.
	M.Sandy.Start()

	-- THE SHELF. An install against a definition the store does not know is
	-- refused by the platform itself, so registration is the clinic's
	-- precondition and not decoration. The grade rows are the platform's own
	-- shared schema (each grade's id beside its VALUE fields).
	local api = store()
	if api ~= nil and type(api.define) == 'function' then
		for _, entry in ipairs(M.Ripper.Catalog()) do
			if M.Ripper.IsPlatform(entry) then
				local grades = {}
				for _, grade in ipairs(type(entry.GRADES) == 'table' and entry.GRADES or {}) do
					local row = { id = grade.id }
					for field, value in pairs(type(grade.VALUE) == 'table' and grade.VALUE or {}) do
						row[field] = value
					end
					grades[#grades + 1] = row
				end
				local ran, result, why = pcall(api.define, {
					id = M.Ripper.DefinitionFor(entry, nil),
					version = 1,
					slot = entry.SLOT,
					profile = entry.PROFILE,
					grades = grades,
				})
				-- THE ANSWER IS A TABLE -- the platform's `{ok=...}`.
				local accepted = ran and type(result) == 'table' and result.ok == true
				if accepted then
					Open77.log.info(('[ripperdoc] the definition %s is on the shelf')
						:format(tostring(M.Ripper.DefinitionFor(entry, nil))))
				else
					local reason = (not ran and result)
						or (type(result) == 'table' and (result.reason or result.error))
						or why
					Open77.log.warn(('[ripperdoc] the definition %s was refused: %s')
						:format(tostring(M.Ripper.DefinitionFor(entry, nil)), tostring(reason)))
				end
			end
		end
	else
		Open77.log.warn('[ripperdoc] no cyberware store on this host; nothing can be fitted')
	end
	-- WHAT THE BODY CAN ACTUALLY RECEIVE ON THIS SERVER, said once at boot:
	-- every platform service the tray needs, and the pieces each one carries.
	-- A service left out of `resources.load` is the quiet way to sell chrome
	-- that never reaches anybody.
	local needs, order = {}, {}
	for _, entry in ipairs(M.Ripper.Catalog()) do
		for _, service in ipairs(M.Ripper.ServicesFor(entry)) do
			if needs[service] == nil then
				needs[service] = 0
				order[#order + 1] = service
			end
			needs[service] = needs[service] + 1
		end
	end
	for _, service in ipairs(order) do
		local state = serviceState(service)
		if state == 'running' then
			Open77.log.info(('[ripperdoc] %s is running: %d piece(s) can reach the body through it')
				:format(service, needs[service]))
		else
			Open77.log.warn(('[ripperdoc] %s is %s: %d piece(s) that need it are refused at the ' ..
				'chair until it runs (add it to resources.load)'):format(service, state, needs[service]))
		end
	end
	local count = #M.Ripper.Catalog()
	Open77.log.info(('[ripperdoc] %d piece(s) on the tray across %d body system(s)')
		:format(count, #M.Ripper.Systems()))

	-- THE PRESS AT THE CHAIR. The role decides what it means: an on-duty
	-- ripperdoc operates the chair, anybody else sits in it -- one key, one
	-- event, and the routing is the server's because only it knows the job.
	RegisterNetEvent(M.Event.USE, function(chairId)
		local player = sender()
		if player == nil or throttled(player, 'use') then return end
		local key = keyOf(player)
		local record = data(player)
		if record == nil then return refuse(player, 'noCharacter') end
		local chair = M.Ripper.Chair(tostring(chairId or ''))
		if chair == nil then return refuse(player, 'noSuchChair') end
		reap(chair.id)
		if where[key] ~= nil then return refuse(player, 'seated') end
		if not near(player, chair, M.Ripper.Reach()) then return refuse(player, 'tooFar') end
		if incapacitated(player) then return refuse(player, 'bodyNotReady') end
		local seat = seatOf(chair.id)
		if operates(record) then
			if seat.attendant ~= nil then return refuse(player, 'busy') end
			seat.attendant = key
			where[key] = { chair = chair.id, role = 'attendant', player = player }
			push(key, nil)
			if seat.sitter ~= nil then push(seat.sitter, nil) end
			return
		end
		if seat.sitter ~= nil then return refuse(player, 'taken') end
		sit(player, key, chair, seat)
	end)

	-- THE SITTER LEAVES. A staged transaction is NOT cancelled by standing --
	-- the platform owns its outcome and the money rule still settles it.
	RegisterNetEvent(M.Event.STAND, function()
		local player = sender()
		if player == nil or throttled(player, 'stand') then return end
		local key = keyOf(player)
		local at = where[key]
		if at == nil or at.role ~= 'sitter' then
			return pushTo(player, { mode = 'closed', why = 'noSeat' })
		end
		unseat(key, 'stood', true)
	end)

	-- THE POWERS FITTED IN THE CHAIR, ONCE THE PATIENT IS UP (see `unseat`).
	-- The token is the server's own and good once. Without one the request is
	-- the player's machine saying its overdrive went missing (a respawn on a
	-- new body, a restart of `open77_reflex`), which `M.Sandy.Recover` answers
	-- under its own limits -- never inside the power's cooldown.
	RegisterNetEvent(M.Event.REPROJECT, function(token, kind)
		local player = sender()
		if player == nil then return end
		local key = keyOf(player)
		-- Still in a chair: nothing projected now would stick. The token is
		-- kept, and rides the next kit (`M.Ripper.PendingReproject`).
		if M.Ripper.Seated(player) then return end
		if type(token) == 'string' and token ~= '' then
			local issued = reprojects[key]
			if issued == nil or issued.token ~= token then return end
			reprojects[key] = nil
			local reflex = M.Chrome.ArmedEntry(player, 'reflex')
			local freshReflex = reflex ~= nil and M.Chrome.Stale(player, reflex.id)
			local done = M.Chrome.Reproject(player, 'stale')
			-- A Sandevistan worn BEFORE they sat is not stale -- it was fine
			-- until the chair -- and goes back on through the cooldown gate.
			if reflex ~= nil and not freshReflex then
				local recovered = M.Sandy.Recover(player, true)
				if recovered then done = done + 1 end
			end
			Open77.log.info(('[ripperdoc] player %d is up out of the chair: %d power(s) projected again')
				:format(player, done))
			return
		end
		if throttled(player, 'reproject') then return end
		if kind == 'reflex' then M.Sandy.Recover(player) end
	end)

	-- THE OPERATOR STEPS AWAY. The patient's menu stays -- with nobody at the
	-- desk they may serve themselves. The operator's own offer and invitation
	-- go with them.
	RegisterNetEvent(M.Event.CLOSE, function()
		local player = sender()
		if player == nil or throttled(player, 'close') then return end
		local key = keyOf(player)
		local at = where[key]
		if at == nil or at.role ~= 'attendant' then
			return pushTo(player, { mode = 'closed', why = 'noSeat' })
		end
		unseat(key, 'left', true)
	end)

	-- THE OPTION TO SIT, from the operator to somebody at the chair.
	RegisterNetEvent(M.Event.INVITE, function(target)
		local player = sender()
		if player == nil or throttled(player, 'invite') then return end
		local key = keyOf(player)
		local at = where[key]
		if at == nil or at.role ~= 'attendant' then return refuse(player, 'notRipperdoc') end
		if not operatorStands(player, key, at) then return end
		local seat = seats[at.chair]
		local chair = M.Ripper.Chair(at.chair)
		reap(at.chair)
		if seat.sitter ~= nil then return refuse(player, 'taken') end
		if seat.invite ~= nil then return refuse(player, 'busy') end
		local other = tonumber(target)
		local otherKey = other ~= nil and keyOf(other) or nil
		local record = other ~= nil and data(other) or nil
		if record == nil or otherKey == key then return refuse(player, 'noSuchTarget') end
		if where[otherKey] ~= nil then return refuse(player, 'seatedElsewhere') end
		if not near(other, chair, M.Ripper.Reach() * 4) then return refuse(player, 'tooFar') end
		seat.invite = { by = key, to = otherKey, player = other, at = OPX.Now(),
			name = record.name or tostring(other) }
		push(key, nil)
		pushTo(other, {
			mode = 'invite',
			chair = at.chair,
			name = chair.NAME,
			from = (data(player) or {}).name,
		})
	end)

	-- THE ANSWERS, to the invite and to the offer. Only the addressee may
	-- answer, and an offer answer names the offer it answers.
	RegisterNetEvent(M.Event.ANSWER, function(what, accept, offerId)
		local player = sender()
		if player == nil or throttled(player, 'answer') then return end
		local key = keyOf(player)

		if what == 'invite' then
			for chairId, seat in pairs(seats) do
				local invite = seat.invite
				if invite ~= nil and invite.to == key then
					seat.invite = nil
					local chair = M.Ripper.Chair(chairId)
					if accept ~= true then
						pushTo(player, { mode = 'closed', why = 'declined' })
						if where[invite.by] ~= nil then
							push(invite.by, { key = 'ripperdoc.inviteDeclined', args = {} })
						end
						return
					end
					reap(chairId)
					-- THE ACCEPT IS CHECKED LIKE A PRESS: an invitation is not a
					-- teleport, and a player who walked off, changed bucket, went
					-- down or sat elsewhere is not placed in this chair.
					local refusal = nil
					if OPX.Now() - (invite.at or 0) >= INVITE_TIMEOUT_MS then
						refusal = 'noInvite'
					elseif where[key] ~= nil then
						refusal = 'seated'
					elseif seat.sitter ~= nil or chair == nil then
						refusal = 'taken'
					elseif not near(player, chair, M.Ripper.Reach() * 4) then
						refusal = 'tooFar'
					elseif incapacitated(player) then
						refusal = 'bodyNotReady'
					end
					if refusal ~= nil then
						pushTo(player, { mode = 'closed', why = refusal,
							flash = { key = Refusal[refusal] or refusal, args = {} } })
						if where[invite.by] ~= nil then push(invite.by, nil) end
						return
					end
					sit(player, key, chair, seat)
					if where[invite.by] ~= nil then push(invite.by, nil) end
					return
				end
			end
			-- No invitation stands: close whatever the page is showing, so a
			-- stale card is never a trap with the cursor held.
			return pushTo(player, { mode = 'closed', why = 'noInvite',
				flash = { key = Refusal.noInvite, args = {} } })
		end

		if what == 'offer' then
			local at = where[key]
			if at == nil or at.role ~= 'sitter' then return refuse(player, 'noOffer') end
			local seat = seats[at.chair]
			local offer = seat.offer
			if offer == nil then return refuse(player, 'noOffer') end
			if offerId ~= nil and tonumber(offerId) ~= offer.id then
				return refuse(player, 'noOffer')
			end
			seat.offer = nil
			if accept ~= true then
				local flashes = {}
				flashes[key] = { key = 'ripperdoc.offerWithdrawn', args = {} }
				if seat.attendant ~= nil then
					flashes[seat.attendant] = { key = 'ripperdoc.offerDeclined', args = {} }
				end
				refresh(seat, nil, nil, flashes)
				return
			end
			settle(player, key, seat, offer)
			return
		end

		refuse(player, 'noOffer')
	end)

	-- THE OFFER. Two doors, one funnel: the chair's operator toward their
	-- patient, or -- with nobody operating -- the patient, for themselves.
	RegisterNetEvent(M.Event.OFFER, function(entryId, gradeId, mode)
		local player = sender()
		if player == nil or throttled(player, 'offer') then return end
		local key = keyOf(player)
		local at = where[key]
		if at == nil then return refuse(player, 'noPatient') end
		local entry = M.Ripper.Entry(tostring(entryId or ''))
		if entry == nil then return refuse(player, 'noSuchEntry') end
		mode = mode == 'remove' and 'remove' or mode == 'repair' and 'repair' or 'install'

		local seat = seats[at.chair]
		local patientKey, byPlayer, byCitizen, byName
		if at.role == 'attendant' then
			if not operatorStands(player, key, at) then return end
			if seat.sitter == nil then return refuse(player, 'noPatient') end
			patientKey = seat.sitter
			byPlayer, byCitizen, byName = player,
				(data(player) or {}).citizenId, (data(player) or {}).name
		elseif at.role == 'sitter' and seat.attendant == nil then
			-- Self-service: open only while nobody is operating the chair.
			patientKey = key
		else
			return refuse(player, 'notRipperdoc')
		end
		if pending[patientKey] ~= nil or seat.offer ~= nil then return refuse(player, 'busy') end

		local patientPlayer = (where[patientKey] or {}).player
		local facts, code, args = rule(patientPlayer, entry, gradeId, mode)
		if facts == nil then return refuse(player, code, args) end
		local grade = M.Ripper.Grade(entry, facts.grade)

		offerSeq = offerSeq + 1
		seat.offer = {
			id = offerSeq,
			mode = facts.mode,
			entry = entry.id,
			grade = facts.grade,
			name = entry.NAME,
			gradeName = grade ~= nil and grade.NAME or '',
			from = facts.from,
			price = facts.price,
			by = patientKey ~= key and key or nil,
			byKey = patientKey ~= key and key or nil,
			byPlayer = byPlayer,
			byCitizen = byCitizen,
			byName = byName,
		}
		refresh(seat, nil, nil)
	end)

	-- THE PLACEMENT DOORS.
	registerCommands()

	-- The capture door, gated exactly as the command that opens it: a net event
	-- has no host-side ACL check, so the same question is asked here.
	RegisterNetEvent(M.Event.CAPTURED, function(key, label, yaw, snap)
		local player = tonumber(source)
		if player == nil then return end
		captureAsked[player] = nil
		local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}
		if not aclAllows(player, names.add) then
			Open77.log.warn(('[ripperdoc] player %d tried to capture a chair without %s')
				:format(player, tostring(names.add)))
			return OPX.Refuse(player, 'error.noPermission', M.Operation.CAPTURE)
		end
		CreateThread(function()
			capture(player, tostring(key or ''), tostring(label or ''), yaw, snap)
		end)
	end)

	-- A client that has just come up wants the captured chairs.
	RegisterNetEvent(M.Event.ASK, function()
		local player = sender()
		if player == nil or throttled(player, 'ask') then return end
		syncChairs(player)
		-- And what the server holds on them: a kit armed before this client's
		-- half was listening (a fast arrival) would otherwise never reach it.
		M.Chrome.PushKit(player)
	end)

	-- THE CLIENT HALF OF A DIAGNOSIS: what `open77_cyberware` on the
	-- patient's own machine says about its projection. Only an answer to a
	-- probe this server sent is journalled.
	RegisterNetEvent(M.Event.PROBED, function(nonce, report)
		local player = sender()
		if player == nil then return end
		local probe = probes[player]
		if probe == nil or probe.nonce == nil or probe.nonce ~= tostring(nonce or '') then return end
		-- ONE ANSWER PER PROBE, and a bounded one: the nonce is spent here, so
		-- a client replaying it writes nothing more.
		probe.nonce = nil
		probe.answer = type(report) == 'table' and report or { raw = tostring(report) }
		local line = flat(probe.answer)
		if #line > 1500 then line = line:sub(1, 1500) .. '...' end
		probe.line = line
		Open77.log.warn(('[ripperdoc] player %d client cyberware (%s): %s')
			:format(player, tostring(probe.code), line))
		-- A FAILED FITTING IS EXPLAINED to the patient in the words of the
		-- reason their own machine gave.
		if probe.failure ~= nil then
			local entry = M.Ripper.Entry(probe.failure)
			local reason = M.Ripper.NativeReason(probe.answer, entry)
			if reason ~= nil then
				Open77.log.warn(('[ripperdoc] player %d: %s failed natively because %s')
					:format(player, probe.failure, reason))
				OPX.NotifyLocale(player, M.Ripper.NativeWhyKey(reason),
					{ name = entry ~= nil and locale(entry.NAME) or probe.failure, reason = reason }, 'error')
			end
		end
	end)

	-- THE RECORD READER'S ANSWERS. Only the client a read runs through, only
	-- for the batch it was sent, only the ids that batch named (`Reader.Answer`).
	RegisterNetEvent(M.Event.RESOLVED, function(nonce, batch, rows)
		local player = sender()
		if player == nil then return end
		CreateThread(function() M.Reader.Answer(player, nonce, batch, rows) end)
	end)

	-- THE RECORDER'S LINES. Anyone's client may send them (the recorder
	-- listens to the base game's own menus on its own), but never faster than
	-- the floor and never longer than one journal line.
	RegisterNetEvent(M.Event.RECORDED, function(line)
		local player = sender()
		if player == nil or OPX.Cooling(player, 'ripperdoc.recorded', 100) then return end
		if type(line) ~= 'string' then return end
		-- A BUDGET, not only a floor: lines are heard only while this client's
		-- recorder is on here or the policy records on its own, and never more
		-- than a minute's worth (more for one staff switched on).
		local policy = type(M.Settings.RECORDER) == 'table' and M.Settings.RECORDER or {}
		if not recording[player] and policy.AUTO == false then return end
		local now = OPX.Now()
		local budget = recordedBudget[player]
		if budget == nil or now - budget.at >= 60000 then
			budget = { at = now, count = 0 }
			recordedBudget[player] = budget
		end
		budget.count = budget.count + 1
		if budget.count > (recording[player] and 240 or 40) then return end
		line = line:gsub('[%c]', ' '):sub(1, 1500)
		Open77.log.info(('[ripperdoc:rec] %s (#%d): %s')
			:format(tostring((data(player) or {}).name or 'player'), player, line))
	end)

	-- THE ROWS THE DATABASE HOLDS: the chairs, then their seats.
	CreateThread(function()
		local rows = M.Storage.FetchAll()
		if type(rows) ~= 'table' or rows.ok ~= true then
			Open77.log.error('[ripperdoc] captured chairs could not be read: '
				.. tostring(type(rows) == 'table' and rows.detail or 'no answer'))
			return
		end
		local seatsRead = M.Storage.FetchSeats()
		local seatOfKey = {}
		if type(seatsRead) == 'table' and seatsRead.ok == true then
			for _, row in ipairs(type(seatsRead.value) == 'table' and seatsRead.value or {}) do
				if type(row) == 'table' and type(row.chair_key) == 'string' then
					seatOfKey[row.chair_key] = row
				end
			end
		end
		local loaded = type(rows.value) == 'table' and rows.value or {}
		local accepted = 0
		for index = 1, #loaded do
			local record = loaded[index]
			local seatRow = type(record) == 'table' and seatOfKey[record.chair_key] or nil
			local extra = nil
			if seatRow ~= nil then
				extra = {
					SEAT = { FORWARD = seatRow.seat_forward, RIGHT = seatRow.seat_right,
						UP = seatRow.seat_up, YAW = seatRow.seat_yaw },
					FX = seatRow.forward_x, FY = seatRow.forward_y, BUCKET = seatRow.bucket,
					VANILLA = { CLASS = seatRow.vanilla_class, NAME = seatRow.vanilla_name,
						ENGINE = seatRow.vanilla_engine },
				}
			end
			local chair = M.Ripper.Row(type(record) == 'table' and record.chair_key or nil,
				type(record) == 'table' and record.label or nil,
				type(record) == 'table' and record.x or nil,
				type(record) == 'table' and record.y or nil,
				type(record) == 'table' and record.z or nil,
				type(record) == 'table' and record.yaw or nil, extra)
			if chair ~= nil then
				captures[chair.id] = chair
				accepted = accepted + 1
			else
				Open77.log.warn('[ripperdoc] a captured chair row was refused and skipped')
			end
		end
		rebuild()
		syncAll()
		syncProps()
		Open77.log.info(('[ripperdoc] %d captured chair(s) read from the database')
			:format(accepted))
	end)

	-- A PIECE THAT BREAKS: a durable implant is pulled through the same remove
	-- staging every sale uses, minus the money -- nobody paid for this pull.
	-- The completion of that ticket is nobody's to settle and is left alone.
	-- A grant was disarmed by the ledger; stat chrome simply stops counting.
	AddEventHandler(M.Event.ON_BROKEN, function(payload)
		if type(payload) ~= 'table' then return end
		M.Ripper.PullBroken(payload.player, payload.entry, payload.citizen)
	end)

	-- A departure frees the seat NOW, and a character put down on a
	-- connection that stays does the same: the seat, the desk, the offer and
	-- any invitation to or from them.
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player == nil then return end
		unseat(keyOf(player), 'left', false)
		orphan(keyOf(player))
		reprojects[keyOf(player)] = nil
		diagnosed[player], rebound[player], probes[player], recording[player] = nil, nil, nil, nil
		recordedBudget[player] = nil
		M.Reader.Left(player)
	end)
	-- THE RECORD READER rides the first player who stays (config RECORDS).
	AddEventHandler(OPX.Host.PLAYER_READY, function(rawPlayerId)
		local player = tonumber(rawPlayerId)
		if player ~= nil then M.Reader.Arrived(player) end
	end)
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'unloaded'), function(player)
		player = tonumber(player)
		if player == nil then return end
		unseat(keyOf(player), 'unloaded', true)
		orphan(keyOf(player))
	end)
	-- A character that loads is paid every refund that waited for it.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'loaded'), function(player, info)
		player = tonumber(player)
		local citizenId = type(info) == 'table' and info.citizenId or nil
		if player == nil or type(citizenId) ~= 'string' then return end
		CreateThread(function() payQueued(player, citizenId) end)
	end)

	-- The sweep for operations that never heard back.
	sweeping = true
	CreateThread(function()
		while sweeping do
			Wait(30000)
			if not sweeping then return end
			local ran, failure = pcall(sweepPending)
			if not ran then Open77.log.warn('[ripperdoc] the pending sweep raised: ' .. tostring(failure)) end
		end
	end)

	-- THE CHAIRS THE PATIENT CAN SEE, on every chair that needs one.
	syncProps()
end

--- Takes the clinic down: the chrome's numbers come off every body, the
--- clock stops, and every row that changed is written -- one thread per row,
--- because a shutdown does not resume a yielded loop.
function M.Stop()
	sweeping = false
	-- WORK IN FLIGHT IS GIVEN BACK. The platform cancels a stopping resource's
	-- owned staging (`wiki/cyberware.md`), and the charge it reserved lives
	-- only in this VM: refunded now, to the character that paid, or it is
	-- simply lost. Every one is journalled for staff to reconcile.
	local inflight = {}
	for _, op in pairs(pending) do inflight[#inflight + 1] = op end
	for _, op in pairs(orphans) do inflight[#inflight + 1] = op end
	pending, orphans = {}, {}
	for _, op in ipairs(inflight) do
		Open77.log.warn(('[ripperdoc] stopping with the %s of %s (%s) for %s in flight: %d refunded')
			:format(tostring(op.mode), tostring(op.entry), tostring(op.grade),
				tostring(op.patientCitizen), tonumber(op.price) or 0))
		pcall(compensate, op.patientCitizen, op.patient, op.price, 'ripperdoc:refund')
	end
	M.Sandy.Stop()
	M.Effects.Stop()
	M.Chrome.Stop()
	for _, dirty in ipairs(M.Chrome.Dirty()) do
		CreateThread(function() M.Chrome.Save(dirty.citizen, dirty.entry) end)
	end
end

--- Publishes the read side of the clinic: the chairs and the tray, for a
--- resource that wants to price or place something beside this one.
function M.Api()
	OPX.Api.Provide('ripperdoc', 1, {
		Chairs = M.Ripper.Chairs,
		Catalog = M.Ripper.Catalog,
		--- What one grade would cost at this clinic.
		-- @param entryId string
		-- @param gradeId string
		-- @return number|nil
		Quote = function(entryId, gradeId)
			local entry = M.Ripper.Entry(tostring(entryId or ''))
			local grade = entry ~= nil and M.Ripper.Grade(entry, tostring(gradeId or '')) or nil
			return grade ~= nil and grade.PRICE or nil
		end,
		--- What one player's chrome adds up to (armor, health, stamina...).
		-- @param player number
		-- @return table
		Effects = function(player)
			return M.Effects.Totals((data(player) or {}).citizenId)
		end,
		--- What a character's level is worth to their chrome, for the skill
		-- tree to show: how long a (non-iconic) piece lasts and the most hard
		-- use may take off it, in days, and the shortest and longest
		-- Sandevistan boost the ripperdoc runs, in seconds -- at this level,
		-- at level 1 (`Base`) and at the cap (`Max`).
		-- @param level number
		-- @param cap number
		-- @return table { lifeDays, lifeBaseDays, lifeMaxDays, wearDays, activeSeconds = {lo, hi},
		--   activeBaseSeconds = {lo, hi}, activeMaxSeconds = {lo, hi} }
		ChromeLevel = function(level, cap)
			return M.Ripper.ChromeLevel(level, cap)
		end,
	})
end
