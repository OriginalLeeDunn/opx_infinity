--- The call object and every rule about it, with no host call of its own.
-- @author dop42
--
-- Deliberately pure, for the reason `modules/target/shared/model.lua` gives at
-- its head: every question that needs the host -- is this player through the
-- gate, are these two bodies within arm's reach, what time is it -- is asked by
-- the caller and handed in. That is what makes `judge`, `near` and `now`
-- parameters of `Model.New` rather than calls from inside the verbs here.
--
-- It is also what makes the rules TESTABLE. A holocall needs two connected
-- machines, a readiness gate, a life state and an eye-glow lease to exercise
-- for real; it needs none of those to answer "may a player who is already in a
-- call place a second one". The second question is the one that has an
-- interesting answer, so it lives where a test can reach it.
--
-- ── the object ───────────────────────────────────────────────────────────────
--
--   call    { id, startedAtMs, founder, order = { playerId... } }
--   invite  { id, kind, from, to, callId, atMs, expiresAtMs }
--
-- `order` is a LIST and not a set, and that is a display decision made once:
-- the founder is first and everybody else follows in the order they joined, so
-- the three participants of a call read the same way on all three screens. A
-- set would have been iterated by `pairs`, which orders by nothing.
--
-- ── one call, one invite out, one invite in ──────────────────────────────────
--
-- Three indexes hold the whole of that rule, and each is a single value rather
-- than a list, which is what makes it enforceable by assignment rather than by
-- counting:
--
--   callOf[playerId]    the call they are in, or nil
--   outgoing[playerId]  the invite they are waiting on an answer to, or nil
--   incoming[playerId]  the invite waiting for THEIR answer, or nil
--
-- The third is the one that is a screen decision made honest. The incoming card
-- shows ONE call. A second arriving while the first is up would have to be
-- queued, stacked or silently dropped, and a queue of calls a player never sees
-- is worse for the caller than a refusal they read at once.
--
-- ── the three kinds, and why they are one object ─────────────────────────────
--
-- Placing a call, adding a third and handing over a contact are the same shape:
-- somebody asks, somebody else agrees or does not, and until they agree nothing
-- has happened. Written as three verb families they were three cooldowns,
-- three expiry rules and three spellings of "that player is busy", and they
-- disagreed with each other within an hour of being written. One invite with a
-- `kind` is one accept path and one decline path.
--
-- ── the ids ──────────────────────────────────────────────────────────────────
--
-- Minted from a counter, so they are short, greppable in a journal, and the
-- same across a test run. NOT SECRET, and nothing rests on them being secret:
-- `Accept` and `Decline` check that the invite named IS the caller's own
-- `incoming` one, so a player who guesses somebody else's id learns nothing and
-- can do nothing with it. An id that carried authority would have to be
-- unguessable and this one carries none.

local M = OPX.Modules.Get('calls')

M.Model = {}
local Model = M.Model

--- Every refusal this module can answer, as a CLOSED set.
---
--- IT IS A SET AND NOT A CONVENTION, and the reason is `OPX.RefusalKey`: a code
--- reaching a player is looked up in the locale catalogue, and one that is not
--- there is downgraded to `error.unavailable` with a warning nobody reads. So a
--- refusal invented at a call site is a refusal the player is never told. Every
--- name here has an `calls.error.<name>` entry in `locales.lua`, and the test
--- suite holds the two lists against each other.
---
--- The pairs that look redundant are not. `notReady` is about the player who
--- ASKED and `targetNotReady` about the player they asked for, and a caller who
--- cannot tell those apart is told "that did not work" for two situations with
--- two different remedies -- wait a moment, versus that person is not here.
--- `disabled` IS NOT IN IT, and its absence was a deliberate removal rather
--- than an oversight. It was written here first, for a module switched off in
--- the config -- and nothing can ever answer it: `OPX.Modules.Declare` reads
--- `enabled == false` and the module never reaches a phase, so there is no
--- handler to refuse with it and no contract to refuse through. A name in a
--- closed set that nothing can answer is a refusal the next author will reach
--- for and a sentence in two catalogues nobody will ever read.
Model.REASONS = {
	-- the shape of the request. Both of these are the SERVER's rather than this
	-- file's -- `badRequest` is answered here as well, `tooFast` only there --
	-- and they are in this table because the set is every refusal the MODULE
	-- can give a player, not every refusal this file produces.
	badRequest = true,
	tooFast = true,

	-- who is being asked
	self = true,
	noSuchPlayer = true,

	-- the state of the two bodies
	notReady = true,
	targetNotReady = true,
	notAlive = true,
	targetNotAlive = true,

	-- what each of them is already doing
	alreadyInCall = true,
	targetInCall = true,
	alreadyPending = true,
	targetPending = true,

	-- the call itself
	notInCall = true,
	callFull = true,
	alreadyParticipant = true,

	-- answering one
	noSuchInvite = true,
	expired = true,

	-- sharing a contact, and calling only who you have shared with
	tooFar = true,
	contactTooSoon = true,
	notContact = true,

	-- a host read this module needs and did not get
	unreadable = true,

	-- the contact list: a contact not connected (a row status, not a refusal
	-- of anything asked), and a list with no room for one more
	offline = true,
	contactsFull = true,
}

--- The invite kinds, as a closed set. `call` opens one, `join` adds to one,
--- `contact` involves no call at all.
Model.KINDS = { call = true, join = true, contact = true }

--- Participants one call may hold. THREE, and it is the owner's number: two
--- parties plus the third the spec asks for. It is a hard ceiling here as well
--- as a config value, because the config is an operator's and this is an
--- invariant of the object -- `order` is sent whole to three screens and read
--- as a fixed-size row on each.
Model.MAX_PARTICIPANTS = 3

--- Whether a value is a connected player id: a whole number in the host's range.
--- Written once here because five call sites asked it and two of them let a
--- float through, and `callOf[2.5]` is a slot nothing ever clears.
-- @author dop42
-- @param value any
-- @return integer|nil
function Model.PlayerId(value)
	local id = tonumber(value)
	if id == nil or id ~= id or id < 1 or id > 2147483647 or id % 1 ~= 0 then return nil end
	return math.floor(id)
end

--- Whether a value is an id this model minted: `c12` or `i12`, nothing else.
-- @author dop42
-- @param value any
-- @return boolean
function Model.Id(value)
	return type(value) == 'string' and #value >= 2 and #value <= 24
		and value:match('^[ci]%d+$') ~= nil
end

-- A shallow copy of a list of numbers. Every list this model hands out is a
-- copy: a caller that kept the live `order` and a caller that added a
-- participant would be the same table, and the first would find its snapshot
-- had changed under it between building a payload and sending it.
local function copyList(list)
	local out = {}
	for index = 1, #list do out[index] = list[index] end
	return out
end

--- Makes an empty call registry.
---
--- Every host question is a parameter, and each answers the same way a native
--- does -- true, or false plus a reason -- so the verbs below can pass a
--- refusal straight through instead of inventing one.
---
--- @param options table
---   now      fun(): integer         monotonic milliseconds
---   judge    fun(playerId): boolean, string|nil
---                                   whether this player may take part at all:
---                                   through the gate, with a character, alive.
---                                   The reason is one of `notReady`,
---                                   `notAlive`, `noSuchPlayer`, `unreadable`.
---   near     fun(a, b): boolean     whether two bodies are within contact
---                                   range of each other, in the same bucket.
---                                   Asked for `contact` invites and nothing
---                                   else -- a holocall between two people on
---                                   opposite sides of the city is the feature.
---   ttlMs    integer                how long an unanswered invite lives
---   maximum  integer|nil            participants per call, bounded by
---                                   `Model.MAX_PARTICIPANTS`
-- @author dop42
-- @return table
function Model.New(options)
	local now = options.now
	local judge = options.judge
	local near = options.near
	local ttlMs = options.ttlMs
	local maximum = math.min(options.maximum or Model.MAX_PARTICIPANTS, Model.MAX_PARTICIPANTS)

	local registry = {}

	-- callId -> call. Every other table below is an index into this one or into
	-- `invites`, and `Forget` is the one place that has to clear all of them.
	local calls = {}
	local invites = {}

	local callOf, incoming, outgoing = {}, {}, {}
	local sequence = 0

	-- The verdict on one player, with the reason mapped into the caller's half
	-- of the vocabulary. `side` is 'target' when the player being judged is the
	-- one being asked, which is what turns `notReady` into `targetNotReady`.
	local function admits(playerId, side)
		local ok, reason = judge(playerId)
		if ok then return true end
		reason = Model.REASONS[reason] and reason or 'unreadable'
		if side ~= 'target' then return false, reason end
		if reason == 'notReady' then return false, 'targetNotReady' end
		if reason == 'notAlive' then return false, 'targetNotAlive' end
		return false, reason
	end

	--- The call a player is in, or nil. A COPY, for the reason `copyList` gives.
	-- @param playerId integer
	-- @return table|nil
	function registry.CallOf(playerId)
		local call = calls[callOf[playerId] or false]
		if call == nil then return nil end
		return {
			id = call.id,
			startedAtMs = call.startedAtMs,
			founder = call.founder,
			order = copyList(call.order),
		}
	end

	--- The invite waiting for a player's answer, or nil. A copy.
	-- @param playerId integer
	-- @return table|nil
	function registry.IncomingOf(playerId)
		local invite = invites[incoming[playerId] or false]
		if invite == nil then return nil end
		return { id = invite.id, kind = invite.kind, from = invite.from, to = invite.to,
			callId = invite.callId, atMs = invite.atMs, expiresAtMs = invite.expiresAtMs }
	end

	--- The invite a player is waiting on an answer to, or nil. A copy.
	-- @param playerId integer
	-- @return table|nil
	function registry.OutgoingOf(playerId)
		local invite = invites[outgoing[playerId] or false]
		if invite == nil then return nil end
		return { id = invite.id, kind = invite.kind, from = invite.from, to = invite.to,
			callId = invite.callId, atMs = invite.atMs, expiresAtMs = invite.expiresAtMs }
	end

	--- Every player in one call, in display order. Empty for a call that is not
	--- there, never nil: a caller fanning out over it must not have to check.
	-- @param callId string|nil
	-- @return integer[]
	function registry.Participants(callId)
		local call = calls[callId or false]
		if call == nil then return {} end
		return copyList(call.order)
	end

	--- Every live call id. What a diagnostic line counts.
	-- @return string[]
	function registry.CallIds()
		local out = {}
		for id in pairs(calls) do out[#out + 1] = id end
		table.sort(out)
		return out
	end

	-- Drops an invite from both indexes and from the table.
	local function drop(invite)
		if invite == nil then return end
		invites[invite.id] = nil
		if incoming[invite.to] == invite.id then incoming[invite.to] = nil end
		if outgoing[invite.from] == invite.id then outgoing[invite.from] = nil end
	end

	--- Whether one player could invite another right now, and as what.
	---
	--- EVERY RULE `Invite` ENFORCES, WITH NOTHING BUILT AND NOTHING CHANGED.
	--- It exists because there are two callers who need the same answer and
	--- only one of them wants the side effects: raising the invite, and DRAWING
	--- A MENU ROW for a person you might call -- greyed out, with the reason
	--- beside it, which is the difference between a list that tells you why
	--- somebody is unreachable and a list that refuses when you press it.
	---
	--- `Invite` calls this and does nothing else with the rules, so there is
	--- one copy. The obvious alternative -- a menu that re-derives "is that
	--- player busy" from `CallOf` and `IncomingOf` -- is the hand-kept second
	--- opinion this codebase has been bitten by in five other places, and the
	--- copy that drifted would be the one offering a row the server refuses.
	---
	--- `kind` is not the caller's to choose freely either: it is DERIVED from
	--- whether the sender is in a call, because those are the same intent --
	--- "I want to talk to that person" -- and letting a client name the kind
	--- would let it name a `join` against a call it is not in. The caller
	--- passes `contact` or nothing, and nothing means "a call, whichever sort
	--- applies".
	-- @author dop42
	-- @param from integer
	-- @param to integer
	-- @param wanted string|nil 'contact', or nil for a call
	-- @return string|nil the kind it would be
	-- @return string|nil the refusal
	function registry.Consider(from, to, wanted)
		local sender, target = Model.PlayerId(from), Model.PlayerId(to)
		if sender == nil or target == nil then return nil, 'badRequest' end
		if wanted ~= nil and wanted ~= 'contact' then return nil, 'badRequest' end
		if sender == target then return nil, 'self' end

		-- WHERE THE TWO BODIES ARE COMES FIRST FOR A CONTACT, before anything is
		-- said about the target. The reach used to be the LAST question, so a
		-- contact offer aimed at any id on the server answered `targetNotAlive`,
		-- `targetNotReady`, `targetPending` or `targetInCall` from across the
		-- map: a stranger could poll whether a given player was down, still
		-- loading or on a call, one id at a time. Out of reach, the only answer
		-- is `tooFar`, which says nothing the asker cannot see for themselves.
		if wanted == 'contact' and not near(sender, target) then return nil, 'tooFar' end

		local ok, reason = admits(sender, 'caller')
		if not ok then return nil, reason end
		ok, reason = admits(target, 'target')
		if not ok then return nil, reason end

		-- ONE OUT AND ONE IN. A second invite from the same player would
		-- overwrite `outgoing` and leave the first in `invites` with nothing
		-- pointing at it: a ghost the target could still accept, into a call
		-- the sender had forgotten placing.
		if outgoing[sender] ~= nil then return nil, 'alreadyPending' end
		if incoming[target] ~= nil then return nil, 'targetPending' end

		local kind = wanted or (callOf[sender] ~= nil and 'join' or 'call')

		if kind == 'contact' then
			-- The one rule about where the two bodies are, and the only one,
			-- asked at the top. Handing somebody your number is something you do
			-- standing in front of them; a CALL is the opposite -- reaching
			-- somebody who is not there is the whole point of the feature -- so
			-- no other kind asks this question.
			if incoming[sender] ~= nil then return nil, 'alreadyPending' end
			return kind
		end

		if kind == 'join' then
			local call = calls[callOf[sender] or false]
			if call == nil then return nil, 'notInCall' end
			if #call.order >= maximum then return nil, 'callFull' end
			if callOf[target] == call.id then return nil, 'alreadyParticipant' end
			if callOf[target] ~= nil then return nil, 'targetInCall' end
			return kind
		end

		if callOf[sender] ~= nil then return nil, 'alreadyInCall' end
		if callOf[target] ~= nil then return nil, 'targetInCall' end
		return kind
	end

	--- Raises an invite. The verb behind every consent in this module.
	---
	--- The rules are `Consider`'s, every one of them, and this adds only the
	--- object: an id, the two ends, the call it joins and a deadline.
	-- @author dop42
	-- @param from integer
	-- @param to integer
	-- @param wanted string|nil 'contact', or nil for a call
	-- @return table|nil the invite
	-- @return string|nil the refusal
	function registry.Invite(from, to, wanted)
		local kind, reason = registry.Consider(from, to, wanted)
		if kind == nil then return nil, reason end

		-- Re-bounded rather than carried out of `Consider`: it answers a kind
		-- and a refusal, and a second return value that callers could forget to
		-- use is how an unchecked id gets into a table key.
		local sender, target = Model.PlayerId(from), Model.PlayerId(to)
		local callId = kind == 'join' and callOf[sender] or nil

		local atMs = now()
		sequence = sequence + 1
		local invite = {
			id = 'i' .. tostring(sequence),
			kind = kind,
			from = sender,
			to = target,
			callId = callId,
			atMs = atMs,
			expiresAtMs = atMs + ttlMs,
		}
		invites[invite.id] = invite
		outgoing[sender] = invite.id
		incoming[target] = invite.id
		return registry.IncomingOf(target)
	end

	--- Accepts the invite waiting for a player.
	---
	--- THE INVITE IS RE-JUDGED HERE AND NOT ONLY WHEN IT WAS RAISED. Seconds
	--- pass between a card appearing and somebody pressing accept, and in those
	--- seconds the caller can die, disconnect, or be pulled into another call
	--- by a third party. A model that only checked at `Invite` would open a
	--- call with a participant who is not there, and the first thing anyone
	--- would notice is a blue-eyed corpse.
	-- @author dop42
	-- @param playerId integer
	-- @param inviteId string
	-- @return table|nil what changed
	-- @return string|nil the refusal
	function registry.Accept(playerId, inviteId)
		local target = Model.PlayerId(playerId)
		if target == nil or not Model.Id(inviteId) then return nil, 'badRequest' end
		-- THE OWNERSHIP CHECK IS THE ONLY ONE THAT MATTERS, and it is why the
		-- ids need not be secret: the invite has to be the one waiting for THIS
		-- player, so naming somebody else's is `noSuchInvite` and nothing more.
		if incoming[target] ~= inviteId then return nil, 'noSuchInvite' end
		local invite = invites[inviteId]
		if invite == nil then return nil, 'noSuchInvite' end
		if now() >= invite.expiresAtMs then
			drop(invite)
			return nil, 'expired'
		end

		local ok, reason = admits(target, 'caller')
		if not ok then return nil, reason end
		-- The SENDER judged as a target: from the answering player's side the
		-- person who is missing is the other one.
		ok, reason = admits(invite.from, 'target')
		if not ok then
			drop(invite)
			return nil, reason
		end

		drop(invite)

		if invite.kind == 'contact' then
			return { kind = 'contact', between = { invite.from, invite.to } }
		end

		if invite.kind == 'join' then
			local call = calls[invite.callId or false]
			-- The call can END between the invite and the answer -- the other two
			-- hang up, or one of them drops and the survivor is released. There
			-- is nothing to join, and saying so is better than silently opening
			-- a new call between the inviter and a person who agreed to a
			-- different thing.
			if call == nil or callOf[invite.from] ~= call.id then return nil, 'notInCall' end
			if #call.order >= maximum then return nil, 'callFull' end
			if callOf[target] ~= nil then return nil, 'alreadyInCall' end
			call.order[#call.order + 1] = target
			callOf[target] = call.id
			return { kind = 'join', callId = call.id, joined = target,
				participants = copyList(call.order) }
		end

		if callOf[invite.from] ~= nil then return nil, 'targetInCall' end
		if callOf[target] ~= nil then return nil, 'alreadyInCall' end

		sequence = sequence + 1
		local call = {
			id = 'c' .. tostring(sequence),
			startedAtMs = now(),
			founder = invite.from,
			order = { invite.from, target },
		}
		calls[call.id] = call
		callOf[invite.from] = call.id
		callOf[target] = call.id
		return { kind = 'call', callId = call.id, joined = target,
			participants = copyList(call.order) }
	end

	--- Refuses the invite waiting for a player. Answers who was refused, so the
	--- caller's screen can say so rather than simply going quiet.
	-- @author dop42
	-- @param playerId integer
	-- @param inviteId string
	-- @return table|nil
	-- @return string|nil the refusal
	function registry.Decline(playerId, inviteId)
		local target = Model.PlayerId(playerId)
		if target == nil or not Model.Id(inviteId) then return nil, 'badRequest' end
		if incoming[target] ~= inviteId then return nil, 'noSuchInvite' end
		local invite = invites[inviteId]
		if invite == nil then return nil, 'noSuchInvite' end
		drop(invite)
		return { kind = invite.kind, from = invite.from, to = invite.to }
	end

	--- Withdraws the invite a player is waiting on, before anybody answered it.
	---
	--- THE CALLER'S HALF OF `Decline`. Without it the only way to stop a call
	--- you placed was to let it ring out, and the other screen rang for the
	--- whole INVITE_TTL_S after you had given up.
	-- @author dop42
	-- @param playerId integer
	-- @return table|nil
	-- @return string|nil the refusal
	function registry.Cancel(playerId)
		local sender = Model.PlayerId(playerId)
		if sender == nil then return nil, 'badRequest' end
		local invite = invites[outgoing[sender] or false]
		if invite == nil then return nil, 'noSuchInvite' end
		drop(invite)
		return { kind = invite.kind, from = invite.from, to = invite.to }
	end

	--- Takes a player out of their call, ending it when too few are left.
	---
	--- A CALL OF ONE IS NOT A CALL. Two people talking, one hangs up: the
	--- survivor is not left holding a line to nobody with the glow still on
	--- them, they are released with everyone else. Three people talking, one
	--- hangs up: the other two carry on, which is the whole reason a third
	--- participant is worth having.
	-- @author dop42
	-- @param playerId integer
	-- @return table|nil
	-- @return string|nil the refusal
	function registry.HangUp(playerId)
		local leaver = Model.PlayerId(playerId)
		if leaver == nil then return nil, 'badRequest' end
		local call = calls[callOf[leaver] or false]
		if call == nil then return nil, 'notInCall' end

		local were = copyList(call.order)
		local remaining = {}
		for index = 1, #call.order do
			if call.order[index] ~= leaver then remaining[#remaining + 1] = call.order[index] end
		end
		callOf[leaver] = nil

		if #remaining < 2 then
			for index = 1, #remaining do callOf[remaining[index]] = nil end
			calls[call.id] = nil
			return { callId = call.id, left = leaver, ended = true, were = were, participants = {} }
		end

		call.order = remaining
		-- The founder leaving does not end the call, and the field still has to
		-- name somebody who is in it: a payload naming an absent founder is a
		-- screen drawing a name nobody can see.
		if call.founder == leaver then call.founder = remaining[1] end
		return { callId = call.id, left = leaver, ended = false, were = were,
			participants = copyList(remaining) }
	end

	--- Drops every invite whose deadline has passed, and answers them so the
	--- two screens involved can be told.
	---
	--- SWEPT RATHER THAN CHECKED LAZILY, and the reason is the other half of
	--- the rule: an invite nobody answers holds `outgoing` against the caller
	--- and `incoming` against the target, so a call that is never picked up
	--- would lock both of them out of the feature until one of them
	--- disconnected. `Accept` checks the deadline too, because a sweep runs on
	--- an interval and the moment between is real.
	-- @author dop42
	-- @return table[] each { id, kind, from, to }
	function registry.Expire()
		local atMs = now()
		local gone = {}
		for _, invite in pairs(invites) do
			if atMs >= invite.expiresAtMs then gone[#gone + 1] = invite end
		end
		-- Sorted so a fan-out over them is the same order on every run: `pairs`
		-- over a table keyed by string orders by nothing, and a test asserting
		-- on the list would pass or fail on the hash.
		table.sort(gone, function(left, right) return left.id < right.id end)
		local out = {}
		for index = 1, #gone do
			local invite = gone[index]
			drop(invite)
			out[index] = { id = invite.id, kind = invite.kind, from = invite.from, to = invite.to }
		end
		return out
	end

	--- Forgets a player entirely: their call, both their invites, every index.
	--- What a disconnect does, and what a death does.
	---
	--- It answers the same shape `HangUp` does when they were in a call, so the
	--- caller has ONE fan-out path rather than two that must be kept in step.
	-- @author dop42
	-- @param playerId integer
	-- @return table|nil what leaving did, nil when they were in no call
	-- @return table[] the invites dropped, each { id, kind, from, to }
	function registry.Forget(playerId)
		local id = Model.PlayerId(playerId)
		if id == nil then return nil, {} end

		local dropped = {}
		for _, slot in ipairs({ outgoing[id], incoming[id] }) do
			local invite = invites[slot or false]
			if invite ~= nil then
				dropped[#dropped + 1] = { id = invite.id, kind = invite.kind,
					from = invite.from, to = invite.to }
				drop(invite)
			end
		end

		-- AND THE INVITES POINTING AT THEM, which the two indexes above do NOT
		-- cover: `outgoing[id]` and `incoming[id]` are the invites this player
		-- is an end of, and both are found. This loop exists because the first
		-- version stopped there and was right by luck -- every invite has this
		-- player at one end or the other, so there is nothing left to find. It
		-- is kept as an assertion rather than deleted: an invite that survived
		-- its own participant is a card on a screen for a player who has gone.
		for _, invite in pairs(invites) do
			if invite.from == id or invite.to == id then
				dropped[#dropped + 1] = { id = invite.id, kind = invite.kind,
					from = invite.from, to = invite.to }
				drop(invite)
			end
		end

		if callOf[id] == nil then return nil, dropped end
		local left = registry.HangUp(id)
		return left, dropped
	end

	--- How many calls and how many invites are held. For the diagnostic line.
	-- @return integer calls
	-- @return integer invites
	function registry.Size()
		local liveCalls, liveInvites = 0, 0
		for _ in pairs(calls) do liveCalls = liveCalls + 1 end
		for _ in pairs(invites) do liveInvites = liveInvites + 1 end
		return liveCalls, liveInvites
	end

	return registry
end
