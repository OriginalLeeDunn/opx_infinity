--- Server authority over a holocall: who is on it, who may join, and whose
--- eyes are lit.
-- @author dop42
--
-- The rules are in `shared/model.lua` and touch no host. THIS file is the half
-- that does: it asks the platform whether a player is through the gate, whether
-- they are alive, where they are standing and what they are called, hands those
-- answers to the model as predicates, and turns the model's verdicts into wire
-- traffic and into an eye-glow lease.
--
-- The split is worth stating once because it is what every function below
-- obeys. NOTHING HERE DECIDES ANYTHING. `onInvite` reads a player id off the
-- wire, bounds it, checks a cooldown, and asks the model; if the model says no,
-- the refusal is relayed and the function is over. There is no branch in this
-- file that opens a call, and there is no branch in the model that sends one.
--
-- ── the blue eyes ────────────────────────────────────────────────────────────
--
-- `Open77.players.setHoloCallEyes(playerId, enabled, { durationMs })` is the
-- platform's own holocall glow -- the game's authored effect, not a light this
-- resource invented -- and it is a LEASE held by a resource VM rather than a
-- switch on a player. The platform's own words: the glow stays on while ANY
-- resource holds a lease, `false` releases only ours, and it clears by itself
-- on death, disconnect, resource stop and expiry.
--
-- TAKEN WITH A DEADLINE AND RENEWED, never held open, and that decision is
-- borrowed wholesale from `modules/animations/client/walk.lua`, whose header
-- says why at length: a lease is not tied to the thing that justified it, so a
-- call that ends down a path nobody released on leaves a player glowing for
-- the rest of their session with nothing on screen explaining it. With a
-- bounded lease the worst case is EYES.LEASE_MS of glow. The sweep renews
-- every participant's lease, which is what makes a live call keep it.
--
-- AND IT IS READ BACK. `Open77.players.getHoloCallEyes` answers whether any
-- resource holds a lease, so it cannot tell us whether OURS survived -- but it
-- can tell us that NOBODY'S did, and for a participant we believe we are
-- holding one for, that is a lease the platform dropped: a death, a reload, an
-- expiry we mis-timed. The sweep re-acquires it and says so once. That is the
-- same watchdog shape `Walk.Check` has, and it exists for the same reason --
-- the release path is a promise about every exit, and a promise about every
-- exit is the kind that is kept until somebody adds an exit.

local M = OPX.Modules.Get('calls')

local Result = OPX.Result
local Model = M.Model

-- The one-per-player floor, the invite lifetime and the ceiling, settled in
-- `Init` from the config and bounded there rather than read on every request.
local requestMs = 1500
local inviteTtlMs = 30000
local maximum = Model.MAX_PARTICIPANTS
local contactRange = 6.0
local maxContacts = 64
local leaseMs = 30000
local renewMs = 10000
local scanMs = 2000

-- The call registry, built in `Init`.
local registry

-- The character contract, looked up in `Start`.
local character

-- Players we believe are holding OUR eye-glow lease. Our own bookkeeping and
-- not a read of the platform's, because `getHoloCallEyes` answers for every
-- resource at once and so can never say whose lease is whose.
local eyesHeld = {}

-- When each held lease was last taken, so the sweep renews it every RENEW_MS
-- rather than on every pass.
local eyesRenewedAt = {}

-- The metadata key a character's contact list is filed under.
local CONTACTS_KEY = 'callContacts'

-- When each player last offered their contact to each other player, by target
-- id: `contactOffers[from][to] = atMs`. See `onInvite`.
local contactOffers = {}

-- The references the last contact list each player was sent stands for, by
-- player: `ref -> citizen id`. A delete names a reference, never a citizen.
local rosterRefs = {}

-- The floor between two contact offers from one player to the SAME player. A
-- stranger may still ask to be added -- that is the only door to a call now --
-- but asking the same person again and again is a doorbell, not a request.
local CONTACT_REPEAT_MS = 30000

-- Whether the holocall natives exist on this host, resolved on first use. The
-- pair arrived in 2.31.13+op77.63 and this resource ships against op77.75, so
-- they are expected -- but the same promise was made about `players.teleport`
-- and `modules/teleports/server/main.lua` looks it up before every call anyway.
-- A host without them loses the glow and keeps every call.
local function holocall()
	local players = Open77.players
	if type(players) ~= 'table' then return nil end
	if type(players.setHoloCallEyes) ~= 'function' then return nil end
	return players
end

-- One audit line, info when the thing happened and warn when it did not.
local function audit(event, playerId, ok, detail)
	OPX.Audit.Log({
		event = event,
		severity = ok and 'info' or 'warn',
		source = playerId,
		message = detail,
	})
end

-- ── what the host says about a player ────────────────────────────────────────

-- The life phase without the underscore the client spells and the server does
-- not, exactly as `modules/downed/server/main.lua` reads it.
local function phaseOf(life)
	return type(life) == 'table' and (tostring(life.phase or ''):gsub('_', '')) or ''
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

-- The character loaded in a slot, or nil. A slot with no character is the
-- selection screen or a body that belongs to nobody, and a call placed to one
-- would ring a screen that has no player behind it.
local function loadedIn(playerId)
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local loaded = character.GetPlayer(playerId)
	local data = loaded and loaded.PlayerData
	if type(data) ~= 'table' then return nil end
	return loaded, data
end

-- The CHARACTER'S name, never the account's, or nil.
--
-- `Open77.players.name` answers the displayName the Master vouches for -- the
-- account gamertag -- and it used to be the fallback for a slot with no
-- character yet. It is out-of-character, and the account is nobody's contact:
-- there is no fallback now. Who may READ this name is `labelFor`'s question.
local function nameOf(playerId)
	local _, data = loadedIn(playerId)
	local info = type(data) == 'table' and type(data.charInfo) == 'table' and data.charInfo or nil
	if info == nil then return nil end
	local first = type(info.firstName) == 'string' and info.firstName or ''
	local last = type(info.lastName) == 'string' and info.lastName or ''
	local full = (first .. ' ' .. last):gsub('^%s+', ''):gsub('%s+$', '')
	if full == '' then return nil end
	return OPX.Text.Clean(full, 32)
end

-- What one player's screen calls another: see `labelFor` below. Declared here
-- because `stateFor` reads it, and defined after the contact helpers it needs.
local labelFor

--- Whether a player may take part in a call at all, and why not.
---
--- THE MODEL'S `judge`, and every reason it answers is a name in
--- `Model.REASONS`. Four questions in a fixed order, cheapest and most
--- disqualifying first:
---
---   is the slot occupied at all      noSuchPlayer
---   is the readiness gate open       notReady
---   is a character loaded            notReady
---   is the body alive                notAlive
---
--- A host that cannot answer the gate is `unreadable` rather than a refusal
--- naming the player: the distinction between "they are not here" and "we could
--- not find out" is the difference between a player retrying and a player
--- giving up on a feature that is merely having a bad second.
local function judge(playerId)
	local read, name = pcall(Open77.players.name, playerId)
	if not read or type(name) ~= 'string' then return false, 'noSuchPlayer' end

	local ready = Open77.ready
	if type(ready) ~= 'table' or type(ready.isReady) ~= 'function' then
		return false, 'unreadable'
	end
	local asked, open = pcall(ready.isReady, playerId)
	if not asked then return false, 'unreadable' end
	if open ~= true then return false, 'notReady' end

	if loadedIn(playerId) == nil then return false, 'notReady' end

	local got, life = pcall(Open77.players.getLifeState, playerId)
	if not got or type(life) ~= 'table' then return false, 'unreadable' end
	if phaseOf(life) ~= 'alive' then return false, 'notAlive' end

	return true
end

--- Whether two bodies are close enough to hand over a contact.
---
--- The model's `near`, asked for `contact` invites and for nothing else. BOTH
--- HALVES ARE REQUIRED -- the same routing bucket AND the range -- because two
--- players in different buckets can stand on the same coordinates and never see
--- each other, which is exactly what an instance is for. Range alone would let
--- somebody in an apartment hand a contact to a stranger in the street below.
local function near(a, b)
	local here, there = positionOf(a), positionOf(b)
	if here == nil or there == nil then return false end
	if here.bucket ~= there.bucket then return false end
	local dx, dy, dz = here.x - there.x, here.y - there.y, here.z - there.z
	return (dx * dx + dy * dy + dz * dz) <= (contactRange * contactRange)
end

-- ── the eye-glow lease ───────────────────────────────────────────────────────

-- Takes or renews one player's lease. Answers whether the platform took it.
local function lightEyes(playerId)
	local players = holocall()
	if players == nil then return false end
	local ok, reason = pcall(players.setHoloCallEyes, playerId, true, { durationMs = leaseMs })
	-- `pcall` answers (true, false, reason) when the native itself refused, so
	-- the raise and the refusal are two different failures and both land here.
	if not ok then
		audit('calls.eyes', playerId, false, 'raised: ' .. tostring(reason))
		return false
	end
	if reason == false then
		audit('calls.eyes', playerId, false, 'refused')
		return false
	end
	eyesHeld[playerId] = true
	eyesRenewedAt[playerId] = OPX.Now()
	return true
end

-- Whether a lease is due: not held, or held for RENEW_MS since it was taken.
local function eyesDue(playerId)
	if not eyesHeld[playerId] then return true end
	local at = eyesRenewedAt[playerId]
	return at == nil or OPX.Now() - at >= renewMs
end

-- Gives one player's lease back. Safe to call when it is not held, and
-- deliberately cheap enough that no caller has to ask itself whether it is.
local function darkenEyes(playerId)
	if eyesHeld[playerId] == nil then return end
	eyesHeld[playerId] = nil
	eyesRenewedAt[playerId] = nil
	local players = holocall()
	if players == nil then return end
	local ok, reason = pcall(players.setHoloCallEyes, playerId, false)
	if not ok then
		audit('calls.eyes', playerId, false, 'would not release: ' .. tostring(reason))
	end
end

-- ── the voice channel ────────────────────────────────────────────────────────
--
-- THE OWNER: "petit bug quand il repond a l'appel on s'entend pas". Not a bug in
-- what was built -- this half was never built at all, and it was reported as a
-- limitation when the feature landed: the call carried its STATE and its
-- PRESENTATION, and no audio. Two players on a call heard each other exactly as
-- far as ordinary proximity carried, which across the city is not at all.
--
-- A call gets a channel of its own, created on demand and destroyed with the
-- call. The same discipline as the eye-glow above and for the same reason: this
-- is world state the platform holds on our word, and a call that ends down an
-- unreleased path would leave two strangers able to hear each other for the rest
-- of the session. `channelOf` is keyed by call id, `dropChannel` is safe to call
-- for a call that never had one, and the sweep gives back what the wire missed.
--
-- LISTENING IS OURS TO GRANT; SPEAKING IS NOT, ENTIRELY. Membership with
-- `canListen` is what makes the other half audible, and the server owns it. What
-- the server cannot own is which route a speaker's frame takes: the client picks
-- that with `setTransmitting`'s intent, and by default that is proximity. The
-- client half asserts `all` while a call is live -- see `modules/calls/client`
-- -- so the player is heard both by the call and by anyone standing next to
-- them, which is what a phone call in a shared world should sound like.
local voiceChannels = {}

local function voice()
	local api = Open77.voice
	if type(api) ~= 'table' or type(api.createChannel) ~= 'function' then return nil end
	return api
end

-- The channel for a call, creating it on first use. nil when the platform has
-- no voice stack, which costs the call nothing but its audio.
local function channelOf(callId)
	if voiceChannels[callId] ~= nil then return voiceChannels[callId] end
	local api = voice()
	if api == nil then return nil end

	local made, reason = pcall(api.createChannel, {
		name = ('call %s'):format(tostring(callId)),
		-- No effect and no spatial blend: a holocall is the other person in your
		-- head, not a voice in the room. `mode` is left to the platform's default
		-- rather than named, because naming one this build does not know is a
		-- refusal that costs the whole channel.
		persistent = false,
	})
	if not made then
		audit('calls.voice', 0, false, 'raised: ' .. tostring(reason))
		return nil
	end
	local channel = reason
	if type(channel) ~= 'table' or channel.id == nil then
		audit('calls.voice', 0, false, 'refused: ' .. tostring(channel))
		return nil
	end
	voiceChannels[callId] = channel.id
	return channel.id
end

-- Puts one player on a call's channel. Answers whether they are on it.
local function joinVoice(callId, playerId)
	local api = voice()
	local channelId = api ~= nil and channelOf(callId) or nil
	if channelId == nil then return false end
	local ok, reason = pcall(api.addPlayer, channelId, playerId,
		{ canSpeak = true, canListen = true })
	if not ok or reason == false then
		audit('calls.voice', playerId, false, 'not added: ' .. tostring(reason))
		return false
	end
	return true
end

-- Takes one player off a call's channel. Safe when they are not on it.
local function leaveVoice(callId, playerId)
	local channelId = voiceChannels[callId]
	local api = voice()
	if channelId == nil or api == nil or type(api.removePlayer) ~= 'function' then return end
	local ok, reason = pcall(api.removePlayer, channelId, playerId)
	if not ok then
		audit('calls.voice', playerId, false, 'would not remove: ' .. tostring(reason))
	end
end

-- Destroys a call's channel. Called when the call is over, and by the sweep for
-- a channel whose call is no longer in the registry.
local function dropChannel(callId)
	local channelId = voiceChannels[callId]
	if channelId == nil then return end
	voiceChannels[callId] = nil
	local api = voice()
	if api == nil or type(api.removeChannel) ~= 'function' then return end
	local ok, reason = pcall(api.removeChannel, channelId)
	if not ok then
		audit('calls.voice', 0, false, 'would not drop: ' .. tostring(reason))
	end
end

--- Whether the platform currently shows a holocall glow on a player, for ANY
--- resource. Published on the contract, and the sweep's own question.
---
--- IT CANNOT SAY WHOSE LEASE IT IS, which is the whole reason `eyesHeld` exists
--- beside it. What it can say is that there is no lease at all, and for a
--- participant of a live call that is a lease the platform dropped under us.
local function eyesOn(playerId)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.getHoloCallEyes) ~= 'function' then
		return nil, 'unavailable'
	end
	local read, enabled = pcall(players.getHoloCallEyes, playerId)
	if not read then return nil, tostring(enabled) end
	if enabled == nil then return nil, 'unreadable' end
	return enabled == true
end

-- ── the wire ─────────────────────────────────────────────────────────────────

-- One player's whole call world, as their screen draws it. Every clock is
-- RELATIVE, so the two machines never have to agree about what time it is --
-- the same rule `modules/downed/server/main.lua` states for its own push.
local function stateFor(playerId)
	local atMs = OPX.Now()
	local call = registry.CallOf(playerId)
	local invite = registry.IncomingOf(playerId)
	local outgoing = registry.OutgoingOf(playerId)

	local participants
	if call ~= nil then
		participants = {}
		for index = 1, #call.order do
			local id = call.order[index]
			participants[index] = { id = id, name = labelFor(playerId, id), self = id == playerId }
		end
	end

	return {
		call = call ~= nil and {
			id = call.id,
			founder = call.founder,
			elapsedMs = atMs - call.startedAtMs,
			participants = participants,
		} or nil,
		invite = invite ~= nil and {
			id = invite.id,
			kind = invite.kind,
			from = invite.from,
			-- A CONTACT OFFER NAMES ITS SENDER: handing over your contact is the
			-- sender choosing to be known. Anything else is caller id.
			fromName = invite.kind == 'contact' and (nameOf(invite.from) or '?')
				or labelFor(playerId, invite.from),
			expiresInMs = math.max(0, invite.expiresAtMs - atMs),
		} or nil,
		outgoing = outgoing ~= nil and {
			id = outgoing.id,
			kind = outgoing.kind,
			to = outgoing.to,
			-- NEVER the name of the person a contact was offered to: they have not
			-- agreed to anything yet. It used to be sent the moment the offer left.
			toName = labelFor(playerId, outgoing.to),
			expiresInMs = math.max(0, outgoing.expiresAtMs - atMs),
		} or nil,
	}
end

-- Pushes one player their state.
local function push(playerId)
	TriggerClientEvent(M.Event.STATE, playerId, stateFor(playerId))
end

-- Pushes a list of players their state, each built for them.
local function pushAll(ids)
	for index = 1, #ids do push(ids[index]) end
end

-- Tells one player a thing happened, from the catalogue and never in words this
-- file chose.
local function tell(playerId, key, params)
	OPX.NotifyLocale(playerId, key, params, 'info')
end

-- Relays a model refusal to the player who asked. The code IS the locale key's
-- last segment, which is what keeps the two vocabularies from drifting: a
-- reason the model can answer and the catalogue has no line for is caught by
-- the test suite rather than downgraded in front of a player.
local function refuse(playerId, reason, operation)
	OPX.Refuse(playerId, 'calls.error.' .. tostring(reason), operation, 'talk')
end

-- ── contacts ─────────────────────────────────────────────────────────────────

-- One character's contact list, always an array and never nil.
local function contactsOf(playerId)
	if character == nil or type(character.GetMetadata) ~= 'function' then return {} end
	local read, held = pcall(character.GetMetadata, playerId, CONTACTS_KEY)
	if not read or type(held) ~= 'table' then return {} end
	local out = {}
	for _, row in ipairs(held) do
		if type(row) == 'table' and type(row.citizenId) == 'string' then
			out[#out + 1] = { citizenId = row.citizenId, name = tostring(row.name or '?') }
		end
	end
	return out
end

-- Writes one contact into a character's list, replacing a row for the same
-- citizen rather than appending a second. Answers whether anything changed.
local function remember(playerId, citizenId, name)
	if character == nil or type(character.SetMetadata) ~= 'function' then return false end
	if type(citizenId) ~= 'string' or citizenId == '' then return false end
	local held = contactsOf(playerId)
	for index = 1, #held do
		if held[index].citizenId == citizenId then
			held[index].name = name
			return character.SetMetadata(playerId, CONTACTS_KEY, held) == true
		end
	end
	-- BOUNDED, and a full list REFUSES. The list is written into the character's
	-- metadata blob and that blob is read on every load, so an unbounded one is
	-- a row that grows for the life of a character. It used to make room by
	-- dropping the oldest contact without a word; the lead's decision is that
	-- the player deletes one themselves, so a full list answers `contactsFull`.
	if #held >= maxContacts then return false, 'contactsFull' end
	held[#held + 1] = { citizenId = citizenId, name = name }
	return character.SetMetadata(playerId, CONTACTS_KEY, held) == true
end

--- Whether a player's list has no room for this citizen (and does not hold it).
local function contactsFull(playerId, citizenId)
	local held = contactsOf(playerId)
	if #held < maxContacts then return false end
	for index = 1, #held do
		if held[index].citizenId == citizenId then return false end
	end
	return true
end

--- Deletes one contact from a character's list. Answers whether one went.
local function forget(playerId, citizenId)
	if character == nil or type(character.SetMetadata) ~= 'function' then return false end
	local held = contactsOf(playerId)
	for index = 1, #held do
		if held[index].citizenId == citizenId then
			table.remove(held, index)
			return character.SetMetadata(playerId, CONTACTS_KEY, held) == true
		end
	end
	return false
end

-- ── what happened to the calls that did not happen ───────────────────────────
--
-- THE OWNER: "si il repond pas ou refuse note le c'est important". A call that
-- rang out and a call that was refused both ended with the caller looking at a
-- screen that had gone back to normal, and nothing anywhere remembered either.
-- Two people who keep missing each other is the ordinary case, not the edge one.
--
-- WRITTEN WHERE THE CONTACTS ARE, which is the character's metadata blob, and
-- that is not an implementation detail: it is a JSON column on the characters
-- table, written on save and decoded on load, so this survives a reconnect for
-- exactly the same reason the contact list does. The owner asked for the
-- contacts to be in the database and they already were; this joins them.
--
-- BOTH SIDES GET A ROW, and they are different rows. The caller's says "they did
-- not pick up" and the callee's says "you missed one", and a system that only
-- recorded the caller's would be a system where the person who was called never
-- finds out.
local RECENT_KEY = 'callRecent'
local MAX_RECENT = 20

-- One character's recent calls, newest last, always an array.
local function recentOf(playerId)
	if character == nil or type(character.GetMetadata) ~= 'function' then return {} end
	local read, held = pcall(character.GetMetadata, playerId, RECENT_KEY)
	if not read or type(held) ~= 'table' then return {} end
	local out = {}
	for _, row in ipairs(held) do
		if type(row) == 'table' and type(row.outcome) == 'string' then
			out[#out + 1] = { outcome = row.outcome, name = tostring(row.name or '?'),
				citizenId = row.citizenId, atMs = tonumber(row.atMs) or 0 }
		end
	end
	return out
end

-- Files one outcome on one character. Bounded, oldest first out, for the reason
-- the contact list is bounded: the blob is read on every load.
local function fileRecent(playerId, outcome, withName, withCitizen)
	if character == nil or type(character.SetMetadata) ~= 'function' then return false end
	if playerId == nil or playerId <= 0 then return false end
	local held = recentOf(playerId)
	held[#held + 1] = { outcome = outcome, name = tostring(withName or '?'),
		citizenId = withCitizen, atMs = OPX.Now() }
	while #held > MAX_RECENT do table.remove(held, 1) end
	return character.SetMetadata(playerId, RECENT_KEY, held) == true
end

-- The citizen id of the character in a slot, or nil.
local function citizenOf(playerId)
	local _, data = loadedIn(playerId)
	if type(data) ~= 'table' or type(data.citizenId) ~= 'string' then return nil end
	return data.citizenId
end

-- What `viewer`'s screen calls `subject`: their name when the viewer has them as
-- a contact (or is them), and "unknown caller" otherwise.
--
-- NEVER A NAME TO A STRANGER, the owner's decision (#91). Every line and every
-- card here used to carry the character's name to whoever was on the other end:
-- a third person added to a call learnt the names of everybody on it, everybody
-- on it learnt theirs, a contact offer told the SENDER the name of the person
-- they offered it to before that person had said anything, and "X hung up" named
-- X to people who had never exchanged anything with them. A name is known here
-- because the two people exchanged contacts -- by citizen id, which is what a
-- contact row holds -- and for no other reason.
labelFor = function(viewer, subject)
	if viewer == subject then return nameOf(subject) or '?' end
	local wanted = citizenOf(subject)
	if wanted ~= nil then
		for _, row in ipairs(contactsOf(viewer)) do
			if row.citizenId == wanted then return nameOf(subject) or row.name end
		end
	end
	return locale('calls.unknown')
end

-- Tells each of `ids` but `except` that `subject` did something, each in the
-- words their own contact list allows.
local function tellEach(ids, except, key, subject)
	for index = 1, #ids do
		local id = ids[index]
		if id ~= except then tell(id, key, { name = labelFor(id, subject) }) end
	end
end

-- ── the verbs, as the wire asks for them ─────────────────────────────────────

-- Applies the eye-glow to everyone on a call and pushes them all their state.
-- The one place a call's participants are lit, so there is one place that can
-- forget to.
local function callChanged(callId)
	local ids = registry.Participants(callId)
	for index = 1, #ids do
		lightEyes(ids[index])
		-- Idempotent on purpose: this runs on every change to a call, not only
		-- on the join, so a membership the platform dropped is re-taken on the
		-- next one rather than waiting for the sweep.
		joinVoice(callId, ids[index])
	end
	pushAll(ids)
end

-- Releases the glow for anybody who left, and pushes everyone who was involved.
local function callEnded(outcome)
	local callId = outcome.callId
	for index = 1, #outcome.were do
		local id = outcome.were[index]
		if registry.CallOf(id) == nil then
			darkenEyes(id)
			if callId ~= nil then leaveVoice(callId, id) end
			-- AN INVITE TO JOIN A CALL YOU ARE NO LONGER ON IS WITHDRAWN WITH YOU.
			-- It used to ring on the third person's screen until it expired, or
			-- until they answered and were refused `notInCall`, for a call that
			-- no longer had its sender in it. Withdrawn the way `onWithdraw` does
			-- it: audited, filed as missed, and pushed to the target. The sender
			-- is pushed below with everyone else, and on both screens the invite
			-- going is what plays the stop sound.
			local pending = registry.OutgoingOf(id)
			if pending ~= nil and pending.kind == 'join' then
				local withdrawn = registry.Cancel(id)
				if withdrawn ~= nil then
					audit('calls.cancel', id, true, 'join: the sender left the call')
					fileRecent(withdrawn.to, 'missed', labelFor(withdrawn.to, id), citizenOf(id))
					push(withdrawn.to)
				end
			end
		end
	end
	-- THE CHANNEL GOES WITH THE LAST PARTICIPANT AND NOT BEFORE. `callEnded` also
	-- runs when ONE of three hangs up and the other two carry on talking, and
	-- dropping the channel there would silence a call that is still going.
	if callId ~= nil and #registry.Participants(callId) == 0 then dropChannel(callId) end
	pushAll(outcome.were)
end

--- Whether the character on `target` is in the contacts of the one on `playerId`.
-- By citizen id, which is what a contact row holds: a server id is a seat, and
-- whoever sits in it next is not the person who agreed to be reachable.
local function isContact(playerId, target)
	local wanted = citizenOf(target)
	if wanted == nil then return false end
	for _, row in ipairs(contactsOf(playerId)) do
		if row.citizenId == wanted then return true end
	end
	return false
end

local function onInvite(rawTarget, rawKind)
	local playerId = tonumber(source) or 0
	if playerId <= 0 then return end
	if OPX.Cooling(playerId, 'calls:invite', requestMs) then
		return refuse(playerId, 'tooFast', M.Operation.INVITE)
	end

	local target = Model.PlayerId(rawTarget)
	-- The kind is the ONE thing a client may name, and it may name exactly one
	-- value: `contact`. Everything else -- whether this is a fresh call or a
	-- third being added -- the model derives from whether the sender is already
	-- on a call, precisely so that a client cannot claim a `join` against a
	-- call it is not in.
	local kind = rawKind == 'contact' and 'contact' or nil
	if target == nil then return refuse(playerId, 'badRequest', M.Operation.INVITE) end

	-- A CALL GOES TO A CONTACT, AND TO NOBODY ELSE. The owner's decision: any
	-- server id used to be ringable, and the answer said who was behind it
	-- (`calls.placed {name}`) and what they were doing (in a call, down, not
	-- loaded) -- a modified client walking ids 1..N read every character's name
	-- and state, and alternating invite and withdraw rang a stranger's phone
	-- every second and a half. A stranger now goes through the contact hand-over
	-- first. The refusal is the same whoever the id names -- online or not, busy
	-- or not -- so it says nothing about them. Checked before the model judges
	-- anything, because the model's refusals are exactly what would leak.
	if kind ~= 'contact' and target ~= playerId and not isContact(playerId, target) then
		return refuse(playerId, 'notContact', M.Operation.INVITE)
	end

	-- A contact offer from a full list, refused before anybody is asked: the
	-- exchange is both ways, and this half of it could not be written.
	if kind == 'contact' and contactsFull(playerId, citizenOf(target)) then
		return refuse(playerId, 'contactsFull', M.Operation.INVITE)
	end

	-- A contact offer to the same person, again, inside the floor.
	if kind == 'contact' then
		local mine = contactOffers[playerId]
		local last = mine ~= nil and mine[target] or nil
		if last ~= nil and OPX.Now() - last < CONTACT_REPEAT_MS then
			return refuse(playerId, 'contactTooSoon', M.Operation.INVITE)
		end
	end

	local invite, reason = registry.Invite(playerId, target, kind)
	if invite == nil then return refuse(playerId, reason, M.Operation.INVITE) end

	if invite.kind == 'contact' then
		contactOffers[playerId] = contactOffers[playerId] or {}
		contactOffers[playerId][target] = OPX.Now()
	end
	audit('calls.invite', playerId, true, ('%s -> %d (%s)'):format(invite.id, target, invite.kind))
	push(playerId)
	push(target)
	if invite.kind == 'contact' then
		-- The sender's own name: offering a contact is choosing to be known.
		tell(target, 'calls.contact.offered', { name = nameOf(playerId) or '?' })
		-- The offerer is told too, without the other's name: pressing the eye row
		-- did nothing visible, and a stranger's name is not theirs to read yet.
		tell(playerId, 'calls.contact.sent')
	end
	-- NO "X IS CALLING YOU" / "CALLING X..." TOAST. The sphere pops on both
	-- screens with exactly those words; the toast said them a second time.
	-- The outcomes (answered, declined, rang out) are still toasts.
end

--- Says that an invite rang out, to both sides, and files it on both.
-- The sweep's words, kept in one place because an answer that arrives in the
-- gap between the invite expiring and the next sweep rings it out too.
local function rangOut(invite)
	if invite.kind == 'contact' then
		tell(invite.from, 'calls.contact.unanswered')
		return
	end
	tell(invite.from, 'calls.expired', { name = labelFor(invite.from, invite.to) })
	-- BOTH SIDES, AND NOT THE SAME ROW. `unanswered` is what the caller
	-- reads; `missed` is what the person who never looked at their screen
	-- reads, and it is the one that makes the feature worth having.
	fileRecent(invite.from, 'unanswered', labelFor(invite.from, invite.to), citizenOf(invite.to))
	fileRecent(invite.to, 'missed', labelFor(invite.to, invite.from), citizenOf(invite.from))
	audit('calls.unanswered', invite.from, true,
		('%s did not pick up'):format(tostring(nameOf(invite.to) or invite.to)))
end

local function onAccept(rawInvite)
	local playerId = tonumber(source) or 0
	if playerId <= 0 then return end
	if OPX.Cooling(playerId, 'calls:answer', requestMs) then
		-- THE STATE GOES BACK WITH THIS REFUSAL TOO. The client stopped the
		-- ring on the key press; an invite that is still standing after a
		-- refused answer has to ring again, and the push carrying it unchanged
		-- is how the client learns the answer did not take.
		push(playerId)
		return refuse(playerId, 'tooFast', M.Operation.ANSWER)
	end

	local pending = registry.IncomingOf(playerId)
	-- A CONTACT OFFER ACCEPTED INTO A FULL LIST is refused, and the offer left
	-- standing: the player can delete a contact and answer it again.
	if pending ~= nil and pending.kind == 'contact' and contactsFull(playerId, citizenOf(pending.from)) then
		push(playerId)
		return refuse(playerId, 'contactsFull', M.Operation.ANSWER)
	end
	local outcome, reason = registry.Accept(playerId, rawInvite)
	if outcome == nil then
		-- The state goes back with the refusal: an invite refused because it
		-- expired is an invite the screen is still drawing, and a player told
		-- "that already rang out" while the card sits there is being told the
		-- screen is lying.
		push(playerId)
		-- AND TO THE CALLER, WHEN THE REFUSAL DROPPED THE INVITE. Expired in the
		-- gap before the sweep, or a caller who went down while ringing: the
		-- model drops the invite and the sweep can no longer find it, so the
		-- caller's sphere said "Calling..." with no end and nothing filed.
		if pending ~= nil and registry.OutgoingOf(pending.from) == nil then
			push(pending.from)
			if reason == 'expired' then rangOut(pending) end
		end
		return refuse(playerId, reason, M.Operation.ANSWER)
	end

	if outcome.kind == 'contact' then
		local a, b = outcome.between[1], outcome.between[2]
		local citizenA, citizenB = citizenOf(a), citizenOf(b)
		local nameA, nameB = nameOf(a) or '?', nameOf(b) or '?'
		-- BOTH DIRECTIONS, because that is what the owner asked for -- a
		-- contact SHARED, with consent, not a number handed one way. Each write
		-- is checked separately: a metadata write can fail on its own, and half
		-- an exchange is worth a line in the journal.
		local savedA, whyA = remember(a, citizenB, nameB)
		local savedB, whyB = remember(b, citizenA, nameA)
		audit('calls.contact', a, savedA and savedB,
			('%s <-> %s'):format(tostring(citizenA), tostring(citizenB)))
		-- A list that filled up between the offer and the answer is said to
		-- its owner, never solved by dropping somebody else.
		if whyA == 'contactsFull' then refuse(a, 'contactsFull', M.Operation.ANSWER)
		else tell(a, 'calls.contact.saved', { name = nameB }) end
		if whyB == 'contactsFull' then refuse(b, 'contactsFull', M.Operation.ANSWER)
		else tell(b, 'calls.contact.saved', { name = nameA }) end
		push(a)
		push(b)
		return
	end

	audit('calls.accept', playerId, true, ('%s (%s)'):format(outcome.callId, outcome.kind))
	callChanged(outcome.callId)
	local key = outcome.kind == 'join' and 'calls.joined' or 'calls.answered'
	tellEach(outcome.participants, outcome.joined, key, outcome.joined)
end

local function onDecline(rawInvite)
	local playerId = tonumber(source) or 0
	if playerId <= 0 then return end
	if OPX.Cooling(playerId, 'calls:answer', requestMs) then
		-- THE STATE GOES BACK WITH THIS REFUSAL TOO. The client stopped the
		-- ring on the key press; an invite that is still standing after a
		-- refused answer has to ring again, and the push carrying it unchanged
		-- is how the client learns the answer did not take.
		push(playerId)
		return refuse(playerId, 'tooFast', M.Operation.ANSWER)
	end

	local outcome, reason = registry.Decline(playerId, rawInvite)
	if outcome == nil then
		push(playerId)
		return refuse(playerId, reason, M.Operation.ANSWER)
	end

	audit('calls.decline', playerId, true, tostring(outcome.kind))
	push(playerId)
	push(outcome.from)
	if outcome.kind == 'contact' then tell(outcome.from, 'calls.contact.declined') end
	if outcome.kind ~= 'contact' then
		tell(outcome.from, 'calls.declined', { name = labelFor(outcome.from, playerId) })
		-- The refusal, on both sides and named honestly on each: the caller was
		-- refused, and the person who refused turned one down. Neither is a
		-- missed call and calling them one would be a small lie repeated daily.
		fileRecent(outcome.from, 'declined', labelFor(outcome.from, playerId), citizenOf(playerId))
		fileRecent(playerId, 'refused', labelFor(playerId, outcome.from), citizenOf(outcome.from))
	end
end

-- Withdraws the invite this player sent and nobody answered, and nothing else.
-- A call they are on is left alone: that is `onHangUp`'s, and the client's
-- refuse key asks for this one first.
local function withdraw(playerId)
	local withdrawn, why = registry.Cancel(playerId)
	push(playerId)
	if withdrawn == nil then return refuse(playerId, why, M.Operation.WITHDRAW) end
	push(withdrawn.to)
	audit('calls.cancel', playerId, true, tostring(withdrawn.kind))
	if withdrawn.kind ~= 'contact' then
		fileRecent(withdrawn.to, 'missed', labelFor(withdrawn.to, playerId), citizenOf(playerId))
	end
end

local function onWithdraw()
	local playerId = tonumber(source) or 0
	if playerId <= 0 then return end
	if OPX.Cooling(playerId, 'calls:withdraw', requestMs) then
		-- Pushed for the reason `onAccept` gives: the dial tone stopped on the
		-- key, and an invite still out has to say so.
		push(playerId)
		return refuse(playerId, 'tooFast', M.Operation.WITHDRAW)
	end
	withdraw(playerId)
end

local function onHangUp()
	local playerId = tonumber(source) or 0
	if playerId <= 0 then return end
	if OPX.Cooling(playerId, 'calls:hangup', requestMs) then
		return refuse(playerId, 'tooFast', M.Operation.HANG_UP)
	end

	-- NOT ON A CALL BUT RINGING SOMEBODY: hanging up withdraws it. The owner:
	-- "si on stop l'appel" -- both screens stop ringing at once rather than at
	-- the end of INVITE_TTL_S.
	--
	-- ON A CALL, HANGING UP LEAVES IT, whatever is ringing out. Taking back an
	-- invite sent from inside a call is `WITHDRAW`'s job, and the client's
	-- refuse key asks for that first (`M.DeclineOrHangUp`): the two verbs used
	-- to be one, and X on a live call with a third person ringing ended the call.
	if registry.CallOf(playerId) == nil and registry.OutgoingOf(playerId) ~= nil then
		return withdraw(playerId)
	end

	local outcome, reason = registry.HangUp(playerId)
	if outcome == nil then
		push(playerId)
		return refuse(playerId, reason, M.Operation.HANG_UP)
	end

	audit('calls.hangUp', playerId, true, ('%s ended=%s'):format(outcome.callId,
		tostring(outcome.ended)))
	callEnded(outcome)
	tellEach(outcome.were, playerId, outcome.ended and 'calls.ended' or 'calls.left', playerId)
end

-- Answers the caller their own contact list, with each row's reachability
-- worked out HERE and not on the screen that draws it.
--
-- `registry.Consider` is what answers "could I ring this person right now", and
-- it is the same function `Invite` runs -- so a row drawn as available is a row
-- the server will accept, and a row drawn with a reason beside it names the
-- reason the server would have given. The alternative, a client re-deriving
-- "are they busy" from whatever it can see, is the hand-kept second opinion
-- this codebase has been bitten by in five other places, and the copy that
-- drifted would be the one offering a row that refuses when you press it.
--
-- NOTHING ABOUT WHERE ANYBODY IS crosses on this wire, and no row exists for a
-- contact who is not connected. A contact list that reported who was online
-- would be a presence tracker; one that reported who was CALLABLE is the
-- feature, and the difference is that an offline contact is simply absent
-- rather than listed as unavailable.
--- Sends one player their contact list and their recent calls.
local function sendRoster(playerId)
	-- EVERY CONTACT IS LISTED NOW, the ones not connected too, greyed as
	-- `offline`: a contact can be deleted, and a row nobody can see is a row
	-- nobody can delete. Each row carries a REFERENCE, minted for this answer
	-- and kept here, rather than the citizen id it stands for: the page names a
	-- row to delete, and the server alone knows whose it is.
	local refs = {}
	rosterRefs[playerId] = refs
	local rows = {}
	for index, contact in ipairs(contactsOf(playerId)) do
		local ref = 'k' .. tostring(index)
		refs[ref] = contact.citizenId
		local loaded = character ~= nil and type(character.GetPlayerByCitizenId) == 'function'
			and character.GetPlayerByCitizenId(contact.citizenId) or nil
		local data = loaded and loaded.PlayerData or nil
		local id = type(data) == 'table' and Model.PlayerId(data.source) or nil
		if id ~= nil then
			local kind, reason = registry.Consider(playerId, id, nil)
			rows[#rows + 1] = {
				id = id,
				ref = ref,
				-- The name as it is NOW rather than as it was written into the
				-- contact row: a character named after the hand-over would
				-- otherwise be listed under whatever they were called then.
				name = nameOf(id) or contact.name,
				kind = kind,
				refusal = reason,
			}
		else
			rows[#rows + 1] = { id = 0, ref = ref, name = contact.name, refusal = 'offline' }
		end
	end
	table.sort(rows, function(left, right)
		-- Reachable first, then by name. A list whose top row is one you cannot
		-- press is a list that reads as broken.
		if (left.refusal == nil) ~= (right.refusal == nil) then return left.refusal == nil end
		return tostring(left.name) < tostring(right.name)
	end)

	-- A "WHO IS NEARBY" LIST STOOD HERE and lasted one message. It was added when
	-- ALT was taken off this feature -- a contact list you can only add to with
	-- the thing just removed stays empty forever -- and the owner put ALT back
	-- for exactly that job: "du coup plus de arround me vu que tu utilise le
	-- target pour partager le contact". Two ways to do one thing is one too many,
	-- and the eye is the better of them: handing somebody your contact is a thing
	-- you do to a person standing in front of you.

	-- Newest first on the wire, because that is the order it is read in.
	local recent = recentOf(playerId)
	local ordered = {}
	for index = #recent, 1, -1 do ordered[#ordered + 1] = recent[index] end

	TriggerClientEvent(M.Event.ROSTER, playerId, {
		rows = rows,
		recent = ordered,
		onCall = registry.CallOf(playerId) ~= nil,
	})
end

local function onRoster()
	local playerId = tonumber(source) or 0
	if playerId <= 0 then return end
	if OPX.Cooling(playerId, 'calls:roster', 1000) then return end
	sendRoster(playerId)
end

-- Deletes the contact a row of this player's last list stands for, and answers
-- with the list as it is now.
local function onForget(ref)
	local playerId = tonumber(source) or 0
	if playerId <= 0 then return end
	if OPX.Cooling(playerId, 'calls:forget', requestMs) then
		return refuse(playerId, 'tooFast', M.Operation.FORGET)
	end
	local refs = rosterRefs[playerId]
	local citizenId = type(ref) == 'string' and #ref <= 8 and refs ~= nil and refs[ref] or nil
	if citizenId == nil or not forget(playerId, citizenId) then
		return refuse(playerId, 'badRequest', M.Operation.FORGET)
	end
	audit('calls.forget', playerId, true, tostring(citizenId))
	tell(playerId, 'calls.contact.forgotten')
	sendRoster(playerId)
end

-- Pushes the caller their state again. The module starting and the page
-- mounting are the same request: "tell me what is happening to me".
local function onReady()
	local playerId = tonumber(source) or 0
	if playerId <= 0 then return end
	if OPX.Cooling(playerId, 'calls:ready', 1000) then return end
	push(playerId)
end

-- ── the sweep ────────────────────────────────────────────────────────────────

-- Drops a departing player's call and invites, and gives back their glow.
local function departed(rawPlayerId)
	local playerId = Model.PlayerId(rawPlayerId)
	if playerId == nil then return end
	-- Read before the registry forgets the slot: the row filed below names them,
	-- to a viewer who has them as a contact and to nobody else (`labelFor`'s
	-- rule, applied by hand because the leaver may be unloading already).
	local leaverName, leaverCitizen = nameOf(playerId), citizenOf(playerId)
	local function leaverLabel(viewer)
		if leaverCitizen ~= nil then
			for _, row in ipairs(contactsOf(viewer)) do
				if row.citizenId == leaverCitizen then return leaverName or row.name end
			end
		end
		return locale('calls.unknown')
	end
	local left, dropped = registry.Forget(playerId)
	-- Both directions: what this player offered, and what was offered to the
	-- slot, which the next holder of the id must not inherit.
	contactOffers[playerId] = nil
	for _, offered in pairs(contactOffers) do offered[playerId] = nil end
	rosterRefs[playerId] = nil
	-- The platform clears a lease on disconnect by itself; the local record is
	-- cleared so a recycled slot does not inherit a lease nobody holds.
	eyesHeld[playerId], eyesRenewedAt[playerId] = nil, nil
	-- The cooldown windows are NOT cleared here. `core/server/answer.lua` owns
	-- them and purges them from its own handler on the same event, and the
	-- comment there says why it must be the one place: a window left behind
	-- refuses the next holder of a recycled slot their first action.
	for index = 1, #dropped do
		local invite = dropped[index]
		local other = invite.from == playerId and invite.to or invite.from
		push(other)
		-- A RING CUT BY A DISCONNECT IS SAID, AND FILED. The other screen just
		-- went quiet: a caller who quit left no missed call, and a callee who
		-- quit left the caller's dial tone stopping with no word.
		if invite.kind ~= 'contact' and invite.from == playerId then
			fileRecent(invite.to, 'missed', leaverLabel(invite.to), leaverCitizen)
		elseif invite.kind ~= 'contact' then
			tell(invite.from, 'calls.cutOff')
			fileRecent(invite.from, 'unanswered', leaverLabel(invite.from), leaverCitizen)
		end
	end
	if left ~= nil then
		callEnded(left)
		-- What `onHangUp` says, because a disconnect is a hang-up nobody pressed:
		-- in a call of three the other two are still talking, and telling them
		-- "the call ended" was wrong.
		tellEach(left.were, playerId, left.ended and 'calls.ended' or 'calls.left', playerId)
	end
end

-- One pass: expire what rang out, drop anybody who can no longer take a call,
-- and renew the glow of everybody still on one.
local function scan()
	for _, invite in ipairs(registry.Expire()) do
		push(invite.from)
		push(invite.to)
		rangOut(invite)
	end

	-- A PARTICIPANT WHO CAN NO LONGER TAKE A CALL IS TAKEN OFF IT, and this is
	-- the only path that ends a call nobody asked to end. Dying is the case
	-- that matters: the platform drops the eye-glow lease on death by itself,
	-- so without this the call would carry on with a corpse on it whose eyes
	-- had gone dark -- a state no screen could explain.
	--
	-- `unreadable` IS NOT ONE OF THOSE. It means the host could not be asked --
	-- a raise from `getLifeState` or the readiness gate -- and `judge` keeps it
	-- apart from a refusal naming the player for exactly this: one bad second of
	-- the host used to hang up every live call on the server.
	local ending = {}
	for _, callId in ipairs(registry.CallIds()) do
		for _, id in ipairs(registry.Participants(callId)) do
			local reachable, why = judge(id)
			if not reachable and why ~= 'unreadable' then ending[#ending + 1] = id end
		end
	end
	for index = 1, #ending do
		local outcome = registry.HangUp(ending[index])
		if outcome ~= nil then
			audit('calls.hangUp', ending[index], true, 'dropped: no longer reachable')
			callEnded(outcome)
			tellEach(outcome.were, ending[index], outcome.ended and 'calls.ended' or 'calls.left',
				ending[index])
		end
	end

	-- THE WATCHDOG. Every participant should be carrying our lease; the read
	-- answers for every resource at once, so a `false` here means nobody at all
	-- holds one and ours is gone. Re-acquired, and said out loud once per
	-- occurrence -- a lease that had to be swept is a path somebody forgot, and
	-- naming it is the whole point.
	for _, callId in ipairs(registry.CallIds()) do
		for _, id in ipairs(registry.Participants(callId)) do
			if eyesHeld[id] then
				local on = eyesOn(id)
				if on == false then
					Open77.log.warn(('[calls] the eye-glow lease for %d was dropped; re-taking it')
						:format(id))
					eyesHeld[id], eyesRenewedAt[id] = nil, nil
				end
			end
			-- RENEWED EVERY RENEW_MS, NOT EVERY PASS. `EYES.RENEW_MS` was in the
			-- config and read by nothing, so the lease was re-taken every SCAN_MS
			-- -- a native call per participant every two seconds for a lease
			-- that lasts thirty.
			if eyesDue(id) then lightEyes(id) end
		end
	end

	-- And the other direction: a lease we are holding for somebody who is on no
	-- call. `HangUp` and `Forget` both release, so this should find nothing --
	-- it is here because "should find nothing" is the claim, and an assertion
	-- that costs one table walk is cheaper than the claim being wrong quietly.
	for id in pairs(eyesHeld) do
		if registry.CallOf(id) == nil then
			Open77.log.warn(('[calls] an eye-glow lease outlived its call for %d; releasing it')
				:format(id))
			darkenEyes(id)
		end
	end

	-- THE SAME ASSERTION FOR THE CHANNEL, and it matters more than the glow. A
	-- leaked eye-glow is a player who looks odd; a leaked channel is two people
	-- who can still hear each other after the call they agreed to is over, which
	-- is the whole of what consent bought them.
	for callId in pairs(voiceChannels) do
		if #registry.Participants(callId) == 0 then
			Open77.log.warn(('[calls] a voice channel outlived call %s; dropping it')
				:format(tostring(callId)))
			dropChannel(callId)
		end
	end
end

-- ── the contract ─────────────────────────────────────────────────────────────

--- Whether a player is on a call, and with whom.
-- @author dop42
-- @param playerId integer
-- @return Result
local function isOnCall(playerId)
	local id = Model.PlayerId(playerId)
	if id == nil then return Result.Err('calls.error.badRequest') end
	local call = registry.CallOf(id)
	if call == nil then return Result.Ok({ onCall = false }) end
	return Result.Ok({ onCall = true, callId = call.id, founder = call.founder,
		participants = call.order, elapsedMs = OPX.Now() - call.startedAtMs })
end

--- Every live call, for a dispatch screen or a diagnostic dump.
-- @author dop42
-- @return Result
local function list()
	local rows = {}
	for _, callId in ipairs(registry.CallIds()) do
		local ids = registry.Participants(callId)
		local named = {}
		for index = 1, #ids do named[index] = { id = ids[index], name = nameOf(ids[index]) } end
		rows[#rows + 1] = { id = callId, participants = named }
	end
	return Result.Ok({ calls = rows })
end

--- Takes a player off whatever call they are on, as a moderator or another
--- module would. Answers `notInCall` when there is nothing to end.
-- @author dop42
-- @param playerId integer
-- @param caller string the name the hang-up is audited under
-- @return Result
local function hangUp(playerId, caller)
	local id = Model.PlayerId(playerId)
	if id == nil then return Result.Err('calls.error.badRequest') end
	local outcome, reason = registry.HangUp(id)
	if outcome == nil then return Result.Err('calls.error.' .. tostring(reason)) end
	audit('calls.hangUp', id, true, 'by ' .. tostring(caller))
	callEnded(outcome)
	return Result.Ok({ callId = outcome.callId, ended = outcome.ended })
end

--- Whether the platform is showing a holocall glow on a player, for any
--- resource at all. Published because it is the one question this module can
--- answer about the world rather than about its own bookkeeping.
-- @author dop42
-- @param playerId integer
-- @return Result
local function eyes(playerId)
	local id = Model.PlayerId(playerId)
	if id == nil then return Result.Err('calls.error.badRequest') end
	local on, why = eyesOn(id)
	if on == nil then return Result.Err('calls.error.unreadable', why) end
	return Result.Ok({ lit = on, ours = eyesHeld[id] == true })
end

--- A character's contact list.
-- @author dop42
-- @param playerId integer
-- @return Result
local function contacts(playerId)
	local id = Model.PlayerId(playerId)
	if id == nil then return Result.Err('calls.error.badRequest') end
	return Result.Ok({ contacts = contactsOf(id) })
end

-- Names every key present in one catalogue and missing from the other, and
-- every refusal the model can answer that neither catalogue carries.
local function checkLocales()
	local catalogs = M.Catalogs or {}
	local english, french = catalogs.en or {}, catalogs.fr or {}
	for key in pairs(english) do
		if french[key] == nil then Open77.log.warn('[calls] the fr catalogue is missing ' .. key) end
	end
	for key in pairs(french) do
		if english[key] == nil then Open77.log.warn('[calls] the en catalogue is missing ' .. key) end
	end
	for reason in pairs(Model.REASONS) do
		local key = 'calls.error.' .. reason
		if english[key] == nil then
			Open77.log.warn('[calls] no catalogue line for the refusal ' .. reason)
		end
	end
end

--- Builds the registry and settles every bound out of the config.
-- @author dop42
function M.Init()
	contactOffers = {}
	local settings = M.Settings
	local clamp = OPX.Math.Clamp
	-- Named for what it RETURNS, and the suite holds every file to it. The header
	-- of `modules/downed/server/main.lua` says why: four files used a local called
	-- `finite` for the PREDICATE, and one name for both is an `if finite(x) then`
	-- that is true for nil.
	local finiteNumber = OPX.Math.Finite

	requestMs = math.floor(clamp(finiteNumber(settings.REQUEST_MS) or 1500, 0, 60000))
	inviteTtlMs = math.floor(clamp(finiteNumber(settings.INVITE_TTL_S) or 30, 5, 300) * 1000)
	maximum = math.floor(clamp(finiteNumber(settings.MAX_PARTICIPANTS) or Model.MAX_PARTICIPANTS,
		2, Model.MAX_PARTICIPANTS))
	contactRange = clamp(finiteNumber(settings.CONTACT_RANGE) or 6.0, 0.5, 50.0)
	maxContacts = math.floor(clamp(finiteNumber(settings.MAX_CONTACTS) or 64, 1, 512))
	scanMs = math.floor(clamp(finiteNumber(settings.SCAN_MS) or 2000, 250, 30000))

	local eyesConfig = type(settings.EYES) == 'table' and settings.EYES or {}
	-- Bounded at the platform's own ceiling: `setHoloCallEyes` takes
	-- `durationMs` in 0..600000 and refuses `invalid_options` outside it, and a
	-- config that wandered past would refuse every renewal for the life of the
	-- server while logging nothing a player could see.
	leaseMs = math.floor(clamp(finiteNumber(eyesConfig.LEASE_MS) or 30000, 1000, 600000))
	-- At most half the lease, so one missed sweep still renews before it lapses.
	renewMs = math.floor(clamp(finiteNumber(eyesConfig.RENEW_MS) or 10000, 250,
		math.floor(leaseMs / 2)))

	eyesHeld, eyesRenewedAt = {}, {}
	registry = Model.New{
		now = OPX.Now,
		judge = judge,
		near = near,
		ttlMs = inviteTtlMs,
		maximum = maximum,
	}
end

--- Publishes who is on a call, and the one way to end one from outside.
-- @author dop42
function M.Api()
	OPX.Api.Provide('calls', 1, {
		IsOnCall = isOnCall,
		List = list,
		HangUp = hangUp,
		Eyes = eyes,
		Contacts = contacts,
	})
end

--- Wires the five verbs and starts the sweep.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.warn('[calls] no character contract: no call can name who is on it')
	end

	RegisterNetEvent(M.Event.READY, onReady)
	RegisterNetEvent(M.Event.ASK_ROSTER, onRoster)
	RegisterNetEvent(M.Event.INVITE, onInvite)
	RegisterNetEvent(M.Event.ACCEPT, onAccept)
	RegisterNetEvent(M.Event.DECLINE, onDecline)
	RegisterNetEvent(M.Event.HANG_UP, onHangUp)
	RegisterNetEvent(M.Event.WITHDRAW, onWithdraw)
	RegisterNetEvent(M.Event.FORGET, onForget)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)

	-- The fast path off a death, so a flatlined participant is off the call in
	-- the same tick rather than at the next sweep. The sweep still does it: a
	-- death that happened while this module was stopped raises nothing.
	AddEventHandler('onPlayerLifeStateChanged', function(rawPlayerId)
		local id = Model.PlayerId(rawPlayerId)
		if id == nil or registry.CallOf(id) == nil then return end
		CreateThread(function()
			local ok, failure = pcall(scan)
			if not ok then Open77.log.error('[calls] life scan failed: ' .. tostring(failure)) end
		end)
	end)

	OPX.Scheduler.Every('calls:scan', scanMs, scan)

	checkLocales()

	if holocall() == nil then
		-- SAID AT START AND NOT AT THE FIRST REFUSAL, the way
		-- `modules/teleports/server/main.lua` says the same thing about its own
		-- native: a host without the pair loses the glow and keeps every call,
		-- and that is worth one line at boot rather than a warning per
		-- participant per sweep for the life of the server.
		Open77.log.warn('[calls] this host has no holocall eye-glow: calls will run unlit')
	end
	Open77.log.info(('calls: up to %d on a call, ringing for %ds')
		:format(maximum, math.floor(inviteTtlMs / 1000)))
end

--- Gives every lease back on the way out.
---
--- The platform releases this VM's leases when the resource stops, so this is
--- belt and braces -- but a RELOAD is the case it really covers, and a player
--- left glowing across one has no way to work out why.
-- @author dop42
function M.Stop()
	for id in pairs(eyesHeld) do darkenEyes(id) end
	eyesHeld = {}
	-- A non-persistent channel is released with its owning resource, so this is
	-- belt and braces -- but a reload is exactly when a channel would otherwise
	-- survive its call, and the platform's promise is not this module's to lean
	-- on when giving it back costs one call each.
	for callId in pairs(voiceChannels) do dropChannel(callId) end
	voiceChannels = {}
end
