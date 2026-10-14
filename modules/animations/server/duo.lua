--- Emotes with a nearby player: the invitation, the answer and the pair.
-- @author dop42
--
-- THE PLATFORM PLAYS THE PAIR; THIS FILE ONLY ASKS. `Open77.playerInteractions`
-- is the platform's two-player coordinator: it reserves both players, checks
-- the distance against the positions the server observes, schedules one start
-- for both bodies and cancels on death, a vehicle, a bucket change, separation
-- or a presentation failure.
--
-- EVERYTHING IT CAN PLAY IS OFFERED, in three shapes a request may take:
--
--   { kind = id }               one of `Catalogue.DUO_KINDS`: the coordinator's
--                               own `carry`, `escort`, `give` and `heal`, from
--                               either side (`carried` is a carry the invited
--                               player performs);
--   { actor = a, target = b }   kind `custom` with ANY two offered profiles, one
--                               per body -- the asker plays `a`, the invited
--                               player `b`, and `a == b` is "the same together";
--   { pair = id }               a configured shortcut, which is the same thing
--                               with a name and a length of its own.
--
-- The coordinator validates every profile id against the RP catalogue, so a
-- name this module offers is a name it accepts; DISABLED withholds a profile
-- here exactly as it does for a solo emote.
--
-- WHAT IT DOES NOT DO is ask the other player in this resource's voice. Its own
-- invitation is a chat line ("/interaction accept"), so the consent is taken
-- here instead -- an invitation on the invited player's screen, answered from
-- the picker's menu or `/e accept` -- and the coordinator is called with
-- `consent = false` only once that answer is in, which is the case its guide
-- names: "gameplay whose authorization is already established".
--
-- Every player id here comes from an authenticated connection; the invited
-- player is chosen by the server, as the nearest one in range, never named by
-- the client asking.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common
local Opt = M.Opt
local Service = M.Service

M.Duo = {}
local Duo = M.Duo

-- Invitations by id, and the invitation each player is part of, either side.
local invites, inviteOf = {}, {}

-- Pairs the coordinator accepted, by interaction id, and each player's.
local running, runningOf = {}, {}

-- Last invitation serial handed out.
local serial = 0

-- The sweep that expires unanswered invitations.
local sweepJob = nil

-- Read at the moment of use: at load the host may not have installed the API.
local function coordinator()
	local native = Open77.playerInteractions
	return type(native) == 'table' and type(native.request) == 'function' and native or nil
end

--- Whether emotes with a nearby player can be offered at all.
-- @author dop42
-- @return boolean
function Duo.Available()
	return Opt.SHARED and coordinator() ~= nil
end

-- Whether a profile may be put on a body of a pair: offered on this build and
-- not DISABLED, which `Service.Offered` already answers.
local function pairable(name)
	return type(name) == 'string' and Service.Offered(name) ~= nil
end

-- Whether one of the paired kinds is offered: the kind on in config, its own
-- id and none of its profiles in DISABLED.
local function kindOffered(row)
	if row == nil or not Opt.SHARED_KINDS[row.kind].enabled or Opt.DISABLED[row.id] then
		return false
	end
	for index = 1, #row.profiles do
		if Opt.DISABLED[row.profiles[index]] then return false end
	end
	return true
end

-- A configured shortcut whose two profiles this build offers, or nil.
local function pairOf(id)
	for _, pair in ipairs(Opt.SHARED_PAIRS) do
		if pair.id == id then
			if pairable(pair.actor) and pairable(pair.target) then return pair end
			return nil
		end
	end
	return nil
end

-- How long two profiles play together: the configured length, or -- when
-- both are one-shot gestures -- the longer of their measured clips, so a
-- shared wave is not a ten-second pose after the hands came down.
local function lengthOf(actor, target)
	if actor.once and target.once then
		local longest = 0
		for _, entry in ipairs({ actor, target }) do
			for _, measured in pairs(entry.durations or {}) do
				if measured > longest then longest = measured end
			end
		end
		if longest > 0 then
			return math.min(math.max(longest, M.MIN_DURATION_MS), M.SERVICE_MAX_MS)
		end
	end
	return Opt.SHARED_DURATION_MS
end

--- Resolves a request into what the coordinator is asked for, or nil.
--- The answer carries the coordinator kind, whether the asker is its target,
--- the two profiles when the kind takes them, the length, and `what` -- the
--- shape the invited player's screen reads.
-- @author dop42
-- @param spec any a request off the wire or a typed command
-- @return table|nil
function Duo.Resolve(spec)
	if type(spec) ~= 'table' then return nil end
	if spec.kind ~= nil then
		local row = Catalogue.DuoKind(spec.kind)
		if not kindOffered(row) then return nil end
		return { kind = row.kind, swap = row.swap,
			durationMs = Opt.SHARED_KINDS[row.kind].durationMs,
			what = { kind = row.id } }
	end
	if spec.pair ~= nil then
		local pair = type(spec.pair) == 'string' and pairOf(spec.pair) or nil
		if pair == nil then return nil end
		return { kind = 'custom', swap = false, actor = pair.actor, target = pair.target,
			durationMs = pair.durationMs,
			what = { pair = pair.id, actor = pair.actor, target = pair.target } }
	end
	if not Opt.SHARED_ANY or not pairable(spec.actor) or not pairable(spec.target) then
		return nil
	end
	local actor, target = Service.Offered(spec.actor), Service.Offered(spec.target)
	return { kind = 'custom', swap = false, actor = actor.name, target = target.name,
		durationMs = lengthOf(actor, target),
		what = { actor = actor.name, target = target.name } }
end

--- Answers what this build offers with a nearby player, in the shape a client
--- is sent: the paired kinds' ids, the shortcuts with their two profiles, and
--- whether any two profiles may be asked for. Empty when the coordinator is
--- absent.
-- @author dop42
-- @return table
function Duo.Offered()
	local offered = { kinds = {}, pairs = {}, any = false }
	if not Duo.Available() then return offered end
	for _, row in ipairs(Catalogue.DUO_KINDS) do
		if kindOffered(row) then offered.kinds[#offered.kinds + 1] = row.id end
	end
	for _, pair in ipairs(Opt.SHARED_PAIRS) do
		if pairOf(pair.id) then
			offered.pairs[#offered.pairs + 1] = { id = pair.id, actor = pair.actor,
				target = pair.target }
		end
	end
	offered.any = Opt.SHARED_ANY
	return offered
end

--- How many ways to play with a nearby player this build offers: the paired
--- kinds, the shortcuts and every ordered pair of two offered profiles.
-- @author dop42
-- @return integer
function Duo.Count()
	local offered = Duo.Offered()
	local profiles = 0
	if offered.any then
		local entries = Catalogue.Entries()
		for index = 1, #entries do
			if Service.Offered(entries[index].name) ~= nil then profiles = profiles + 1 end
		end
	end
	return #offered.kinds + #offered.pairs + profiles * profiles
end

-- A player's finite position and bucket, or nil.
local function positionOf(playerId)
	local read, position = pcall(Open77.players.position, playerId)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y),
		OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.floor(OPX.Math.Finite(position.bucket) or 0) }
end

-- Squared distance between two positions, or nil across buckets: two players
-- in different buckets can stand on the same coordinates and never see each
-- other.
local function apart(here, there)
	if here == nil or there == nil or here.bucket ~= there.bucket then return nil end
	local dx, dy, dz = here.x - there.x, here.y - there.y, here.z - there.z
	return dx * dx + dy * dy + dz * dz
end

-- Whether two players stand within range of each other right now.
local function near(a, b)
	local squared = apart(positionOf(a), positionOf(b))
	return squared ~= nil and squared <= Opt.SHARED_RANGE * Opt.SHARED_RANGE
end

-- NO NAME CROSSES IN EITHER DIRECTION. The invitation carried the asker's
-- character name (the account gamertag as a fallback) to whoever happened to
-- stand nearest, and "sent / accepted / declined" carried theirs back: two
-- strangers who had never spoken were told each other's names by asking for a
-- hug. Never a name to a stranger, the owner's decision (#91); the other person
-- is the one standing next to you, and the words say so.

-- Tells one player how their emote with somebody went.
local function notify(player, kind, code, params)
	-- Too far and not allowed are errors, too fast and busy warnings, whatever
	-- the call site passed: see `OPX.Result.Kind`.
	TriggerClientEvent(M.Event.NOTICE, player, OPX.Result.Kind(code, kind), code, params or {})
end

-- The nearest player who may be invited, or nil.
local function nearest(player)
	local here = positionOf(player)
	if here == nil then return nil end
	local read, everyone = pcall(Open77.players.all)
	if not read or type(everyone) ~= 'table' then return nil end
	local best, bestSquared = nil, Opt.SHARED_RANGE * Opt.SHARED_RANGE
	for _, value in ipairs(everyone) do
		local other = tonumber(value)
		if other ~= nil and other ~= player and inviteOf[other] == nil and runningOf[other] == nil
			and Service.Ready(other) then
			local squared = apart(here, positionOf(other))
			if squared ~= nil and squared <= bestSquared then
				best, bestSquared = other, squared
			end
		end
	end
	return best
end

-- Forgets an invitation on both sides.
local function drop(invite)
	invites[invite.id] = nil
	if inviteOf[invite.actor] == invite.id then inviteOf[invite.actor] = nil end
	if inviteOf[invite.target] == invite.id then inviteOf[invite.target] = nil end
end

-- Forgets a running pair on both sides.
local function release(id)
	local pair = running[id]
	if pair == nil then return nil end
	running[id] = nil
	if runningOf[pair.actor] == id then runningOf[pair.actor] = nil end
	if runningOf[pair.target] == id then runningOf[pair.target] = nil end
	return pair
end

--- Invites the nearest player to an emote together.
-- @author dop42
-- @param player Source the authenticated requester
-- @param spec any `{ kind }`, `{ pair }` or `{ actor, target }` (see the top)
-- @return table result: ok, error, quiet, name
function Duo.Request(player, spec)
	if not Duo.Available() then return { ok = false, error = 'duo_unavailable' } end
	-- THE WINDOW FIRST, as for a solo play: a client sending nothing but bad
	-- requests gets no unthrottled answer to each.
	local allowed, first = Service.Within(player)
	if not allowed then return { ok = false, error = 'rate_limited', quiet = not first } end
	local plan = Duo.Resolve(spec)
	if plan == nil then return { ok = false, error = 'unknown_animation' } end
	if not Service.Ready(player) then return { ok = false, error = 'player_not_ready' } end
	if inviteOf[player] ~= nil or runningOf[player] ~= nil then
		return { ok = false, error = 'duo_busy' }
	end
	local target = nearest(player)
	if target == nil then return { ok = false, error = 'no_player_nearby' } end

	serial = serial + 1
	if serial > M.MAX_REQUEST_ID then serial = 1 end
	local invite = { id = serial, actor = player, target = target, plan = plan,
		untilMs = OPX.Now() + Opt.SHARED_INVITE_MS }
	invites[invite.id], inviteOf[player], inviteOf[target] = invite, invite.id, invite.id
	TriggerClientEvent(M.Event.INVITE, target, invite.id, plan.what, Opt.SHARED_INVITE_MS)
	return { ok = true }
end

-- The coordinator's options for a plan. `carry` and `escort` reject a profile
-- override (`paired_animation_fixed`) and `give`/`heal` play their own, so
-- only `custom` names the two profiles.
local function optionsOf(plan)
	local range = Opt.SHARED_RANGE
	local options = {
		durationMs = plan.durationMs,
		startDistance = range,
		breakDistance = math.min(20, range + 2),
		consent = false,
	}
	if plan.kind == 'custom' then
		options.actorAnimation, options.targetAnimation = plan.actor, plan.target
	end
	return options
end

--- Invites, and tells the asker how it went: the picker's request and the
--- typed `/e with` both end here.
-- @author dop42
-- @param player Source
-- @param spec any
-- @return table the `Request` result
function Duo.Ask(player, spec)
	return Duo.Tell(player, Duo.Request(player, spec))
end

--- Tells the asker what a `Request` answered, unless it is quiet.
-- @author dop42
-- @param player Source
-- @param result table
-- @return table the same result
function Duo.Tell(player, result)
	if result.quiet then return result end
	if result.ok then
		notify(player, 'info', 'sent')
	else
		notify(player, 'warning', result.error)
	end
	return result
end

--- Reads the words typed after `/e with` into a request: one paired kind or
--- shortcut id, one profile both play, or two profiles -- the asker's, then
--- the invited player's. A paired kind's id is read before a profile of the
--- same word (`carry`, `give`); `/e with carry carry` is the profile on both.
-- @author dop42
-- @param first string
-- @param second string|nil
-- @return table
function Duo.Spec(first, second)
	if second == nil and Catalogue.DuoKind(first) ~= nil then return { kind = first } end
	if second == nil then
		for _, pair in ipairs(Opt.SHARED_PAIRS) do
			if pair.id == first then return { pair = first } end
		end
	end
	return { actor = first, target = second or first }
end

--- Takes the invited player's answer and, on a yes, starts the pair.
-- @author dop42
-- @param target Source the authenticated answerer
-- @param inviteId any
-- @param accepted any
function Duo.Reply(target, inviteId, accepted)
	local invite = invites[Common.Integer(inviteId, 1, M.MAX_REQUEST_ID) or 0]
	-- Somebody else's invitation is not theirs to answer.
	if invite == nil or invite.target ~= target then
		if accepted == true then notify(target, 'warning', 'expired') end
		return
	end
	drop(invite)
	local actor = invite.actor
	if OPX.Now() > invite.untilMs then
		notify(target, 'warning', 'expired')
		notify(actor, 'info', 'expired')
		return
	end
	if accepted ~= true then
		notify(actor, 'info', 'declined')
		return
	end
	-- MEASURED AGAIN AT THE YES: the invitation can wait fifteen seconds, and
	-- whoever walked off in that time is not dragged into a pose.
	if not near(actor, target) then
		notify(actor, 'warning', 'too_far')
		notify(target, 'warning', 'too_far')
		return
	end
	local native = coordinator()
	if native == nil or not Opt.SHARED then
		notify(actor, 'warning', 'duo_unavailable')
		notify(target, 'warning', 'duo_unavailable')
		return
	end
	local plan = invite.plan
	-- A swapped kind is the invited player performing it: "be carried" is a
	-- carry whose coordinator actor is the one who accepted.
	local first, second = actor, target
	if plan.swap then first, second = target, actor end
	local called, state, reason = pcall(native.request, first, second, plan.kind, optionsOf(plan))
	if not called or type(state) ~= 'table' or type(state.id) ~= 'string' then
		local code = called and Common.Code(reason) or 'play_raised'
		Open77.log.warn(('[animations] %s pair for %d and %d refused: %s'):format(plan.kind,
			actor, target, tostring(called and reason or state)))
		notify(actor, 'warning', code or 'play_refused')
		notify(target, 'warning', code or 'play_refused')
		return
	end
	running[state.id] = { actor = actor, target = target }
	runningOf[actor], runningOf[target] = state.id, state.id
	notify(actor, 'success', 'accepted')
end

--- Answers the invitation a player has been sent, from a typed command.
-- @author dop42
-- @param player Source
-- @param accepted boolean
-- @return boolean whether there was one to answer
function Duo.Answer(player, accepted)
	local invite = invites[inviteOf[player] or 0]
	if invite == nil or invite.target ~= player then return false end
	Duo.Reply(player, invite.id, accepted)
	return true
end

--- Withdraws a player's invitation and ends their pair, whichever side they are.
-- @author dop42
-- @param player Source
-- @param reason string
function Duo.Cancel(player, reason)
	local invite = invites[inviteOf[player] or 0]
	if invite ~= nil then
		drop(invite)
		if player == invite.actor then
			TriggerClientEvent(M.Event.UNINVITE, invite.target, invite.id)
		else
			notify(invite.actor, 'info', 'declined')
			-- AND THE INVITED SCREEN IS TAKEN DOWN TOO, unless the connection is
			-- gone: an emote stop drops the invitation, and the Accept / Decline
			-- menu stayed up over a dead one until closed by hand.
			if reason ~= 'disconnected' then
				TriggerClientEvent(M.Event.UNINVITE, invite.target, invite.id)
			end
		end
	end
	local id = runningOf[player]
	if id ~= nil then
		release(id)
		local native = Open77.playerInteractions
		if type(native) == 'table' and type(native.cancel) == 'function' then
			local called, _, refused = pcall(native.cancel, id, reason)
			if not called or refused ~= nil then
				Open77.log.debug(('[animations] pair %s not cancelled: %s'):format(id,
					tostring(refused)))
			end
		end
	end
end

--- Forgets a departing player, ending what they were part of.
-- @author dop42
-- @param playerId any
function Duo.Forget(playerId)
	local player = tonumber(playerId)
	if player ~= nil then Duo.Cancel(player, 'disconnected') end
end

-- Reads a coordinator state, a table or the JSON the server events may carry.
local function stateOf(value)
	if type(value) == 'string' and type(json) == 'table' then
		local read, decoded = pcall(json.decode, value)
		value = read and decoded or nil
	end
	return type(value) == 'table' and type(value.id) == 'string' and value or nil
end

-- A pair ended on the coordinator's side. Only one this resource started is
-- ours to follow; one ended by something other than a stop says so to both.
local function ended(value)
	local state = stateOf(value)
	if state == nil then return end
	local pair = release(state.id)
	if pair == nil then return end
	local reason = Common.Code(state.reason)
	if state.phase == 'completed' or reason == 'completed' or reason == 'stopped'
		or reason == 'disconnected' then
		return
	end
	notify(pair.actor, 'warning', reason or 'interrupted')
	notify(pair.target, 'warning', reason or 'interrupted')
end

-- Expires invitations nobody answered.
local function sweep()
	local atMs = OPX.Now()
	for id, invite in pairs(invites) do
		if atMs > invite.untilMs then
			drop(invite)
			TriggerClientEvent(M.Event.UNINVITE, invite.target, id)
			notify(invite.actor, 'info', 'expired')
		end
	end
end

--- Wires the two inbound requests, the coordinator's events and the sweep.
-- @author dop42
function Duo.Start()
	invites, inviteOf, running, runningOf = {}, {}, {}, {}

	RegisterNetEvent(M.Event.DUO, function(spec)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		Duo.Ask(player, spec)
	end)

	RegisterNetEvent(M.Event.REPLY, function(inviteId, accepted)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		Duo.Reply(player, inviteId, accepted == true)
	end)

	AddEventHandler('onPlayerInteractionCompleted', ended)
	AddEventHandler('onPlayerInteractionCancelled', ended)

	sweepJob = OPX.Scheduler.Every('animations:duo', 1000, sweep)

	if Opt.SHARED and coordinator() == nil then
		Open77.log.warn('[animations] Open77.playerInteractions is unavailable (a build without ' ..
			'open77_player_interactions, or players.interactions.control not granted); no ' ..
			'emote with a nearby player is offered')
	end
end

--- Ends every pair and invitation this resource holds.
-- @author dop42
function Duo.Stop()
	if sweepJob ~= nil then
		OPX.Scheduler.Cancel(sweepJob)
		sweepJob = nil
	end
	for player in pairs(inviteOf) do Duo.Cancel(player, 'stopped') end
	for player in pairs(runningOf) do Duo.Cancel(player, 'stopped') end
	invites, inviteOf, running, runningOf = {}, {}, {}, {}
end
