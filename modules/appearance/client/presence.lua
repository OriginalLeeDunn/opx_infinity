--- Publishes this player's look, and dresses every other player's proxy.
-- @author dop42
--
-- The engine replicates a position, a vehicle and an action; it does NOT
-- replicate a look. A proxy nobody dresses is never drawn at all, so without this
-- file every other player is simply absent -- while the car they are driving is
-- not. This is why the module is fatal twice over.
--
-- What goes out is the body (the family and its customization groups), the nine
-- equipment slots, and the active outfit. Nothing is stored anywhere: a look
-- lives in the server's memory until the player leaves.

local M = OPX.Modules.Get('appearance')

local State = M.Face
local Runtime = M.Runtime
local Clothing = M.Clothing

M.Presence = {}
local Presence = M.Presence

-- Milliseconds a publication or a replay request waits for its answer.
local RETRY_MS = 3000

local SLOTS = Clothing.SLOTS
local OUTFIT_SLOTS = Clothing.OUTFIT_SLOTS

-- What observers get when the registry cannot be read: being drawn in the
-- default record beats not being drawn.
local DEFAULT_EQUIPMENT = Clothing.DEFAULT.equipment

-- Wardrobe outfits, indexed 0 to 6.
local OUTFITS = 7

-- The look last sent to the server.
local sent = nil

-- The request sequence, the last acknowledged, the last sent, and when: an answer
-- is only ever taken for the last request.
local sequence, acknowledged, sentSequence, sentAtMs = 0, 0, 0, 0

-- This world entry still needs a replay, the request that asked for it, and when.
local replayWanted, replaySequence, replayAtMs = true, 0, 0

-- Failures already said in the log, by key.
local warned = {}

-- The players this client has dressed a proxy for, in this world.
local drawn = {}

-- When the look request was answered, and whether the "nothing to draw" verdict
-- has been said for this world entry. A look is the only thing that draws a peer
-- and its absence is otherwise silent, so this is the one line that separates
-- "the server holds nothing for me" from "the body was refused".
local replayAnsweredAtMs, verdictSaid = 0, false

-- How long after the answer to wait before concluding the server holds nothing.
local VERDICT_MS = 10000

-- How long between roster reports, when the last was said, and whether the
-- missing library has already been reported.
local ROSTER_MS = 5000
local ROSTER_RADIUS = 60.0
-- How long before this client asks for the looks again on behalf of a peer the
-- platform reports and it still cannot draw. Bounds the retry a player held in
-- another routing bucket costs.
local HEAL_MS = 30000
local rosterAtMs = 0
local rosterWarned = false
local rosterNear = nil
-- When each undrawable peer was last asked about.
local healedAt = {}

--- Logs a warning once per key.
local function warnOnce(key, line)
	if warned[key] then return end
	warned[key] = true
	Open77.log.warn('[appearance] ' .. line)
end

--- Whether this client hands its look out and puts other looks on.
local function enabled()
	if M.Settings.PRESENT_BODIES == false then return false end
	return GetResourceState(M.OFFICIAL) ~= 'running'
end

--- An item this body can wear, or false.
local function wearable(record, family)
	if type(record) ~= 'string' or record == '' then return false end
	record = Clothing.Resolve(record)
	local equipment = Open77.equipment
	if family == nil or type(equipment) ~= 'table' or type(equipment.info) ~= 'function' then
		return record
	end
	local read, info = pcall(equipment.info, record)
	if not read or type(info) ~= 'table' then return record end
	return Clothing.Fits(info, family) and record or false
end

--- Reads every equipment slot and the active outfit for a look.
local function readClothing(family)
	local equipment = type(Open77.equipment) == 'table' and Open77.equipment or nil
	local called, registry, reason = false, nil, 'Open77.equipment is not on this client'
	if equipment and type(equipment.registry) == 'function' then
		called, registry, reason = pcall(equipment.registry)
	end
	local slots = {}
	if called and type(registry) == 'table' then
		for _, slot in ipairs(SLOTS) do slots[slot] = wearable(registry[slot], family) end
	else
		warnOnce('equipment', ('the equipment registry cannot be read (%s): observers get the ' ..
			'default one'):format(tostring(called and reason or registry or reason)))
		for slot, value in pairs(DEFAULT_EQUIPMENT) do slots[slot] = value end
	end

	local wardrobe = { outfits = {} }
	local outfits = type(Open77.wardrobe) == 'table' and Open77.wardrobe or nil
	if outfits and type(outfits.active) == 'function' then
		local read, active = pcall(outfits.active)
		if read and type(active) == 'number' and active % 1 == 0 and active >= 0 and
			active < OUTFITS then
			wardrobe.active = active
			if type(outfits.outfit) == 'function' then
				local opened, outfit = pcall(outfits.outfit, active)
				if opened and type(outfit) == 'table' and type(outfit.registry) == 'function' then
					local listed, overrides = pcall(outfit.registry)
					if listed and type(overrides) == 'table' then
						local shown = {}
						for _, slot in ipairs(OUTFIT_SLOTS) do
							if overrides[slot] ~= nil then shown[slot] = wearable(overrides[slot], family) end
						end
						wardrobe.outfits[tostring(active)] = shown
					end
				end
			end
		end
	end
	return slots, wardrobe
end

--- Whether this player's look may be published now.
-- The clothing gate is part of it: publishing before the stored record read back
-- would draw this player in the pristine puppet's clothes first.
local function presentable()
	if not (State.citizenId ~= nil and State.gameplayAnnounced and State.worldEligible and
		not State.bodyReloading and not State.editing and not State.creatorUp and
		State.AppearanceSettled() and Runtime.InGameplay()) then
		return false
	end
	if Clothing.Previewing() then return false end
	return Clothing.Settled()
end

--- Asks for everybody else's look, once per world entry, until answered.
-- Asked whatever state this client's own look is in: a player whose own body
-- cannot be read still has to see the others.
local function askReplay()
	if not replayWanted or not State.worldEligible then return end
	local now = Runtime.NowMs()
	if replaySequence ~= 0 and now - replayAtMs < RETRY_MS then return end
	sequence = sequence + 1
	if TriggerServerEvent(M.Event.REPLAY, sequence) then replaySequence, replayAtMs = sequence, now end
end

--- Publishes the look when it changed, or when the last one went unanswered.
local function publish()
	if not presentable() then return end
	local read, body, reason = pcall(Open77.appearance.captureBody)
	if not read or type(body) ~= 'table' then
		warnOnce('body', ('the body cannot be read (%s): other players cannot draw this one')
			:format(tostring(read and reason or body)))
		return
	end
	warned.body = nil
	local equipment, wardrobe = readClothing(body.family)
	local look = { body = body, equipment = equipment, wardrobe = wardrobe }

	local now = Runtime.NowMs()
	if sent ~= nil and Clothing.Same(look, sent) and
		(acknowledged == sentSequence or now - sentAtMs < RETRY_MS) then
		return
	end
	sequence = sequence + 1
	local dispatched, failure = TriggerServerEvent(M.Event.PRESENT, body, equipment, wardrobe,
		sequence)
	if not dispatched then
		warnOnce('send', 'the look was not sent: ' .. tostring(failure))
		return
	end
	sent, sentSequence, sentAtMs = look, sequence, now
	Open77.log.debug(('[appearance] look published: %s, %d groups, sequence %d')
		:format(tostring(body.family), type(body.groups) == 'table' and #body.groups or 0, sequence))
end

--- Says what this client can actually see, because "nobody is drawn" has three
-- different faults and this is the only line that separates them: how many
-- players are near, how many of them have an entity this client was given, and
-- how many this client has dressed a body on. Nobody near is the transport or
-- the routing bucket; near with no entity is a proxy that never spawned;
-- dressed and still invisible is a rendering or visibility flag.
--
-- IT CALLS THE HOST, NOT `OPX.Lib`. The library's validator calls `getmetatable`,
-- which this resource's sandbox does not expose, so every `OPX.Lib` call that
-- validates raised here -- once a second, from inside this pass, which aborted
-- the rest of the pass with it. A diagnostic may never be what breaks what it
-- measures, so this reads the host surface directly and is called under `pcall`.
local function reportRoster()
	local players = Open77.players
	local nearby = type(players) == 'table' and players.nearby or nil
	if type(nearby) ~= 'function' then
		rosterNear = nil
		if not rosterWarned then
			rosterWarned = true
			Open77.log.warn('[appearance] Open77.players.nearby is not on this client: the remote ' ..
				'roster cannot be read, so "nobody is drawn" cannot be told from "nobody is near"')
		end
		return false
	end
	local called, list, reason = pcall(nearby, ROSTER_RADIUS, { includeSelf = false, limit = 32 })
	if not called or type(list) ~= 'table' then
		rosterNear = nil
		Open77.log.warn(('[appearance] the roster could not be read: %s')
			:format(tostring(called and reason or list)))
		return false
	end
	local near, bodied, dressed, undrawn = 0, 0, 0, 0
	local nowMs = Runtime.NowMs()
	for _, entry in ipairs(list) do
		if type(entry) == 'table' then
			near = near + 1
			local id = tonumber(entry.playerId)
			if entry.entity ~= nil then bodied = bodied + 1 end
			local isDrawn = id ~= nil and drawn[id] == true
			if isDrawn then dressed = dressed + 1 end
			-- A peer this client cannot actually draw: no look ever reached it, or
			-- one did and the platform held no place for them -- a routing bucket,
			-- an interest edge -- so every `puppets` call was a no-op on a player
			-- this world does not carry. `project` cannot see that: it reports
			-- accepted for a call that stored nothing. The two cases look identical
			-- from here and want the same answer.
			if (not isDrawn or entry.entity == nil) and id ~= nil then
				undrawn = undrawn + 1
				-- ASK AGAIN, SLOWLY, RATHER THAN TRUSTING `drawn`. One look is not
				-- evidence the peer is drawable, and this is the only state from which
				-- the peer was previously never asked for again: the client marked
				-- them drawn off a call that landed nowhere and stayed silent until a
				-- world re-enter. Bounded to HEAL_MS per peer so a player the platform
				-- genuinely holds elsewhere costs two requests a minute, not a flood,
				-- and the asking stops the moment that peer has an entity.
				if nowMs - (healedAt[id] or 0) >= HEAL_MS then
					healedAt[id] = nowMs
					replayWanted = true
				end
			end
		end
	end
	rosterNear = near
	Open77.log.info(('[appearance] roster: %d near, %d with an entity, %d dressed by this ' ..
		'client, %d undrawn'):format(near, bodied, dressed, undrawn))
	return true
end

--- Runs one presence pass: the replay request and the publication.
-- @author dop42
function M.Presence.Check()
	if not enabled() then return end
	askReplay()
	publish()
	local nowMs = Runtime.NowMs()
	if nowMs - rosterAtMs >= ROSTER_MS then
		rosterAtMs = nowMs
		-- Under `pcall` once more, and switched off when it raises: a report that
		-- repeats an error every five seconds is worse than no report at all.
		local reported, failure = pcall(reportRoster)
		if not reported then
			rosterAtMs = math.huge
			Open77.log.warn('[appearance] the roster report is off: ' .. tostring(failure))
		end
	end
	-- The answer to the look request is the last thing that can explain a world
	-- with nobody in it: the server says how many looks it holds, and this says
	-- whether any of them ever reached this client.
	if replayAnsweredAtMs ~= 0 and not verdictSaid and next(drawn) == nil and
		type(rosterNear) == 'number' and rosterNear > 0 and
		Runtime.NowMs() - replayAnsweredAtMs > VERDICT_MS then
		verdictSaid = true
		Open77.log.warn('[appearance] the look request was answered and no look has arrived: ' ..
			'this client can draw nobody else. Compare the server line "asked for looks: holding ' ..
			'N": if N counts only this player, nobody has published a body for others to draw.')
	end
end

--- Starts over for a new world: publish and ask again.
-- @author dop42
function M.Presence.Renew()
	sequence = sequence + 1
	sent, acknowledged, sentSequence = nil, 0, 0
	replayWanted, replaySequence, replayAtMs = true, 0, 0
	drawn = {}
	healedAt = {}
	replayAnsweredAtMs, verdictSaid = 0, false
	rosterNear = nil
end

--- Withdraws this player's body until the next publication.
-- What a body reload and a character unload both do first, so observers drop
-- their proxy instead of keeping the old body until a new one arrives.
-- @author dop42
function M.Presence.Withdraw()
	if not enabled() then return end
	sequence = sequence + 1
	sent, acknowledged, sentSequence = nil, 0, 0
	TriggerServerEvent(M.Event.ABSENT)
end

--- Makes one puppets call on a proxy, logging a refusal.
local function project(name, ...)
	local puppets = Open77.puppets
	if type(puppets) ~= 'table' or type(puppets[name]) ~= 'function' then
		warnOnce('puppets.' .. name, ('Open77.puppets.%s is not on this client: other ' ..
			'players are not drawn'):format(name))
		return false
	end
	local called, accepted, reason = pcall(puppets[name], ...)
	if not called or not accepted then
		Open77.log.debug(('[appearance] puppets.%s refused: %s')
			:format(name, tostring(called and reason or accepted)))
		return false
	end
	return true
end

--- Builds the held state. Never yields.
-- @author dop42
function M.Presence.Init()
	sent = nil
	sequence, acknowledged, sentSequence, sentAtMs = 0, 0, 0, 0
	replayWanted, replaySequence, replayAtMs = true, 0, 0
	warned = {}
	drawn = {}
	healedAt = {}
	replayAnsweredAtMs, verdictSaid = 0, false
	rosterNear = nil
end

--- Registers the look traffic.
-- @author dop42
function M.Presence.Wire()
	RegisterNetEvent(M.Event.PRESENT_ACK, function(value, accepted)
		if value ~= sentSequence then return end
		acknowledged = value
		if accepted == false then
			warnOnce('refused', "the server could not read this player's body: others cannot draw it")
		end
	end)

	RegisterNetEvent(M.Event.REPLAYED, function(value)
		if value == replaySequence then
			replayWanted = false
			replayAnsweredAtMs = Runtime.NowMs()
		end
	end)

	-- The server half restarted and holds nothing any more.
	RegisterNetEvent(M.Event.RESEND, Presence.Renew)

	RegisterNetEvent(M.Event.LOOK, function(player, look)
		player = tonumber(player)
		if not enabled() or player == nil then return end
		if look == false then
			drawn[player] = nil
			return project('setBody', player, false)
		end
		if type(look) ~= 'table' or type(look.body) ~= 'table' then return end
		local refused = 0
		local equipment = type(look.equipment) == 'table' and look.equipment or DEFAULT_EQUIPMENT
		for _, slot in ipairs(SLOTS) do
			local value = equipment[slot]
			if not project('setSlot', player, slot, type(value) == 'string' and value or false) then
				refused = refused + 1
			end
		end
		local wardrobe = type(look.wardrobe) == 'table' and look.wardrobe or {}
		local outfits = {}
		for index, items in pairs(type(wardrobe.outfits) == 'table' and wardrobe.outfits or {}) do
			index = tonumber(index)
			if index ~= nil and type(items) == 'table' then outfits[index] = items end
		end
		if not project('setWardrobe', player, { active = tonumber(wardrobe.active), outfits = outfits }) then
			refused = refused + 1
		end
		-- The body goes on LAST: the slots and the wardrobe are what it is dressed
		-- in, and a body set first is drawn undressed for a frame.
		local bodied = project('setBody', player, look.body)
		if bodied then drawn[player] = true end
		Open77.log.debug(('[appearance] look received for player %d: %s, %d group(s), body %s, ' ..
			'%d refusal(s)'):format(player, tostring(look.body.family),
			type(look.body.groups) == 'table' and #look.body.groups or 0,
			bodied and 'drawn' or 'REFUSED', refused))
	end)

	AddEventHandler(OPX.Host.WORLD_READY, Presence.Renew)

	if M.Settings.PRESENT_BODIES ~= false and GetResourceState(M.OFFICIAL) == 'running' then
		Open77.log.warn(('[appearance] %s is running and hands looks out itself; this module ' ..
			'does not'):format(M.OFFICIAL))
	end
	Presence.Renew()
end
