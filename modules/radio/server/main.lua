--- Server half: who is on which channel, who may speak, and the handset.
-- @author dop42
--
-- ONE FUNCTION DECIDES MEMBERSHIP: `reconcile(player)`. It reads the character
-- from the character contract (never from an event payload), the handset from
-- the inventory contract, and the player's own choices from `states`, asks the
-- pure model which channels they should be on, and moves the platform's voice
-- memberships to match -- remove what should go, add what should come, change
-- what is heard. Every trigger ends there: a job or duty change, a gang change,
-- a login, the bag gaining or losing the handset, a menu request, a contract
-- call, and a sweep every SWEEP_MS for whatever no event announced.
--
-- THE RIGHT TO SPEAK is lifted on ONE channel, the selected one, while the key
-- is held (`M.Talk`), and put back on release, on a channel change, on a
-- downed character, and after MAX_TALK_MS whatever the client says. See
-- modules/radio/module.lua for why a member is a listener the rest of the time.
--
-- THE VOICE CHANNELS are created on first use, one per config entry, owned by
-- this resource and non-persistent (the platform drops them with the resource),
-- and removed in `Stop` anyway.

local M = OPX.Modules.Get('radio')
local Model = M.Model
local Result = OPX.Result

local OWNER = 'radio'

-- What `Model.Build` made of the config.
local built = nil
-- channel key -> voice channel id.
local voiceIds = {}
-- player -> { power, off, extra, muted, active, joined = { key -> { listen,
-- speak } }, sig, talking = { key, sinceMs }|nil, sent, citizenId, handset }
local states = {}
local tickJob, sweepJob = nil, nil
-- Whether the handset can be checked at all (an inventory contract exists).
local handsetChecked = true

-- ── reading the world ───────────────────────────────────────────────────────

local function character() return OPX.Api.Get('character') end
local function inventory() return OPX.Api.Get('inventory') end

local function playerOf(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, value = pcall(api.GetPlayer, player)
	if not read or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return value
end

--- The group fields of a loaded character, stamped now, for `OPX.JobGate`.
local function snapshotOf(loaded)
	local data = loaded.PlayerData
	return {
		job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		gang = type(data.gang) == 'table' and data.gang or nil,
		gangs = type(data.gangs) == 'table' and data.gangs or nil,
		atMs = OPX.Now(),
	}
end

--- What a character's job and gang ARE, as one string. A change of it is a
--- new shift: the channels they left by hand on the last one come back.
local function signatureOf(snapshot)
	local job, gang = snapshot.job or {}, snapshot.gang or {}
	local grade = type(job.grade) == 'table' and job.grade.level or ''
	return ('%s|%s|%s|%s'):format(tostring(job.name), tostring(grade), tostring(job.onDuty == true),
		tostring(gang.name))
end

--- Whether the bag holds a handset. nil when the bag could not be read.
local function handsetOf(player)
	if not built.requireItem or not handsetChecked then return true end
	local api = inventory()
	if api == nil or type(api.GetItemCount) ~= 'function' then return true end
	local read, answer = pcall(api.GetItemCount, player, built.item.name)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return nil end
	return (math.tointeger(answer.value) or 0) >= 1
end

local function isDown(player)
	local api = OPX.Api.Get('downed')
	if api == nil or type(api.IsDown) ~= 'function' then return false end
	local read, answer = pcall(api.IsDown, player)
	return read and type(answer) == 'table' and answer.ok == true and type(answer.value) == 'table'
		and answer.value.down == true
end

local function audit(event, player, message)
	pcall(OPX.Audit.Log, { event = event, source = player, message = message })
end

-- ── the platform's voice ────────────────────────────────────────────────────

local function voice()
	local api = Open77.voice
	if type(api) ~= 'table' or type(api.createChannel) ~= 'function' then return nil end
	return api
end

--- The voice channel of a config entry, created on first use. nil when the
--- platform has no voice stack or refused it (said once, in the journal).
local refusedOnce = {}
local function channelOf(key)
	if voiceIds[key] ~= nil then return voiceIds[key] end
	local api = voice()
	local channel = built.channels[key]
	if api == nil or channel == nil then return nil end
	local options = { name = ('radio %s'):format(channel.short), mode = 'radio', persistent = false,
		effect = next(built.effect) ~= nil and built.effect or nil }
	local read, made, reason = pcall(api.createChannel, options)
	if not read or type(made) ~= 'table' or made.id == nil then
		-- ONE RETRY WITHOUT THE NAMED MODE AND EFFECT: a build that does not know
		-- one of them refuses the whole channel, and a radio with no hiss beats
		-- no radio. The first refusal is in the journal either way.
		local first = read and reason or made
		options.mode, options.effect = nil, nil
		read, made, reason = pcall(api.createChannel, options)
		if not read or type(made) ~= 'table' or made.id == nil then
			if not refusedOnce[key] then
				refusedOnce[key] = true
				Open77.log.warn(('[radio] the voice channel for %s was refused: %s / %s')
					:format(key, tostring(first), tostring(read and reason or made)))
			end
			return nil
		end
		Open77.log.warn(('[radio] %s runs without the radio mode/effect: %s'):format(key, tostring(first)))
	end
	voiceIds[key] = made.id
	return made.id
end

local function voiceCall(name, ...)
	local api = voice()
	if api == nil or type(api[name]) ~= 'function' then return false, 'voice_unavailable' end
	local read, ok, reason = pcall(api[name], ...)
	if not read then return false, tostring(ok) end
	if ok == false or ok == nil then return false, tostring(reason) end
	return true
end

local function addMember(player, key, listen, speak)
	local id = channelOf(key)
	if id == nil then return false end
	local ok, reason = voiceCall('addPlayer', id, player, { canSpeak = speak == true, canListen = listen ~= false })
	if not ok then audit('radio.voice', player, ('not added to %s: %s'):format(key, reason)) end
	return ok
end

local function removeMember(player, key)
	local id = voiceIds[key]
	if id == nil then return end
	local ok, reason = voiceCall('removePlayer', id, player)
	if not ok then audit('radio.voice', player, ('not removed from %s: %s'):format(key, reason)) end
end

--- Changes what a member hears and may say. Falls back to re-adding them on a
--- build without `setChannelPlayerPermissions`.
local function setMember(player, key, listen, speak)
	local id = voiceIds[key]
	if id == nil then return false end
	local api = voice()
	if api ~= nil and type(api.setChannelPlayerPermissions) == 'function' then
		local ok, reason = voiceCall('setChannelPlayerPermissions', id, player,
			{ canSpeak = speak == true, canListen = listen ~= false })
		if not ok then audit('radio.voice', player, ('rights on %s refused: %s'):format(key, reason)) end
		return ok
	end
	removeMember(player, key)
	return addMember(player, key, listen, speak)
end

-- ── a player's radio ────────────────────────────────────────────────────────

local function stateOf(player)
	local state = states[player]
	if state == nil then
		state = { power = true, off = {}, extra = {}, muted = {}, joined = {} }
		states[player] = state
	end
	return state
end

local function sendKeyed(player, on, code)
	local state = states[player]
	local channel = nil
	if on and state and state.talking then
		channel = built.channels[state.talking.key] and built.channels[state.talking.key].short or nil
	end
	TriggerClientEvent(M.Event.KEYED, player, { on = on == true, channel = channel, code = code })
end

--- Takes the right to speak back. Safe when the player is not talking.
local function stopTalking(player, code)
	local state = states[player]
	if state == nil or state.talking == nil then return false end
	local key = state.talking.key
	state.talking = nil
	local member = state.joined[key]
	if member ~= nil then
		member.speak = false
		setMember(player, key, member.listen, false)
	end
	sendKeyed(player, false, code)
	return true
end

local function keysOf(joined)
	local out = {}
	for key in pairs(joined) do out[#out + 1] = key end
	table.sort(out)
	return out
end

--- What this player's radio looks like, for the client.
local function payloadOf(player, allowed)
	local state = states[player]
	return {
		power = state.power,
		handset = state.handset ~= false,
		needsHandset = built.requireItem,
		active = state.active,
		talking = state.talking ~= nil,
		talkKey = built.talkKey ~= false,
		channels = Model.Rows(built, allowed, state.joined, state.active),
	}
end

-- A cheap fingerprint of a payload, so an unchanged radio is not re-sent.
local function fingerprint(payload)
	local parts = { tostring(payload.power), tostring(payload.handset), tostring(payload.active),
		tostring(payload.talking) }
	for _, row in ipairs(payload.channels) do
		parts[#parts + 1] = ('%s:%s:%s'):format(row.key, tostring(row.joined), tostring(row.muted))
	end
	return table.concat(parts, ',')
end

--- Leaves every channel and forgets the player (logout, disconnect).
local function dropPlayer(player)
	local state = states[player]
	if state == nil then return end
	stopTalking(player, nil)
	for key in pairs(state.joined) do removeMember(player, key) end
	states[player] = nil
	if next(state.joined) ~= nil then
		OPX.Publish(M.Event.ON_CHANGED, player, { citizenId = state.citizenId, channels = {}, active = nil })
	end
end

--- Moves one player's memberships to what they should be. The whole module
--- ends here.
-- @author dop42
-- @param player integer
-- @param open boolean|nil send the state with the menu open
-- @param quiet boolean|nil send the state only when a membership moved (the
--   sweep: a clock must not chatter at every loaded player)
-- @return string[]|nil the allowed channel keys, nil for a player not loaded
local function reconcile(player, open, quiet)
	local loaded = playerOf(player)
	if loaded == nil then
		dropPlayer(player)
		return nil
	end
	local state = stateOf(player)
	state.citizenId = loaded.PlayerData.citizenId
	local snapshot = snapshotOf(loaded)
	local signature = signatureOf(snapshot)
	if state.sig ~= signature then
		-- A NEW SHIFT, a new job, a new grade: the channels left by hand last
		-- time come back, the ones joined by hand are dropped. Mutes stay -- a
		-- player who silenced the interagency band meant it.
		state.sig = signature
		state.off, state.extra = {}, {}
	end
	local handset = handsetOf(player)
	if handset ~= nil then state.handset = handset end

	local allowed = Model.Allowed(built, snapshot, OPX.Now())
	local desired = Model.Desired(built, allowed, {
		power = state.power, handset = state.handset ~= false,
		off = state.off, extra = state.extra, muted = state.muted, active = state.active,
	})
	local active = Model.Active(desired, state.active)
	local wasActive = state.active
	if state.talking ~= nil and state.talking.key ~= active then stopTalking(player, 'channel_changed') end

	local want = {}
	for _, row in ipairs(desired) do want[row.key] = row end
	local changed = false
	for key in pairs(state.joined) do
		if want[key] == nil then
			if state.talking and state.talking.key == key then stopTalking(player, 'channel_left') end
			removeMember(player, key)
			state.joined[key] = nil
			changed = true
		end
	end
	for _, row in ipairs(desired) do
		local member = state.joined[row.key]
		if member == nil then
			if addMember(player, row.key, row.listen, false) then
				state.joined[row.key] = { listen = row.listen, speak = false }
				changed = true
			end
		elseif member.listen ~= row.listen then
			member.listen = row.listen
			setMember(player, row.key, row.listen, member.speak)
		end
	end
	-- What the key talks into is only ever a channel actually joined.
	state.active = state.joined[active] ~= nil and active or nil
	if state.active == nil then
		for _, row in ipairs(desired) do
			if state.joined[row.key] then state.active = row.key break end
		end
	end

	if state.active ~= wasActive then changed = true end
	if changed then
		OPX.Publish(M.Event.ON_CHANGED, player, { citizenId = state.citizenId, channels = keysOf(state.joined),
			active = state.active })
	end
	local payload = payloadOf(player, allowed)
	local mark = fingerprint(payload)
	if open or (mark ~= state.sent and (changed or not quiet)) then
		state.sent = mark
		payload.open = open == true or nil
		TriggerClientEvent(M.Event.STATE, player, payload)
	end
	return allowed
end
M.Reconcile = reconcile

local function contains(list, value)
	for _, item in ipairs(list or {}) do
		if item == value then return true end
	end
	return false
end

local function count(map)
	local n = 0
	for _ in pairs(map) do n = n + 1 end
	return n
end

-- ── requests ────────────────────────────────────────────────────────────────

--- Joins a channel the player may be on. Answers `(ok, code)`.
local function join(player, key)
	if built.channels[key] == nil then return false, 'unknown_channel' end
	local state = stateOf(player)
	local allowed = reconcile(player)
	if allowed == nil then return false, 'not_loaded' end
	if not contains(allowed, key) then
		audit('radio.refused', player, ('asked for %s, which this character may not hear'):format(key))
		return false, 'not_allowed'
	end
	if state.joined[key] ~= nil then return true, 'already_joined' end
	if state.power == false then return false, 'power_off' end
	if state.handset == false then return false, 'no_handset' end
	if count(state.joined) >= built.maxJoined then return false, 'full' end
	state.off[key] = nil
	if not built.channels[key].auto then state.extra[key] = true end
	reconcile(player)
	if state.joined[key] == nil then return false, 'voice_refused' end
	return true, 'joined'
end

--- Leaves a channel. Answers `(ok, code)`.
local function leave(player, key)
	if built.channels[key] == nil then return false, 'unknown_channel' end
	local state = stateOf(player)
	state.extra[key] = nil
	if built.channels[key].auto then state.off[key] = true end
	if reconcile(player) == nil then return false, 'not_loaded' end
	return true, 'left'
end

--- Handles one menu request. Answers `(ok, code)`; refusals are toasted.
-- @author dop42
-- @param player integer
-- @param payload table { verb, channel?, on? }
-- @return boolean, string
function M.Request(player, payload)
	if type(payload) ~= 'table' or type(payload.verb) ~= 'string' or not M.Verbs[payload.verb] then
		return false, 'invalid'
	end
	local verb, key = payload.verb, payload.channel
	if verb == 'join' or verb == 'leave' or verb == 'select' or verb == 'mute' then
		if not Model.Key(key) then return false, 'invalid' end
	end
	if (verb == 'mute' or verb == 'power') and type(payload.on) ~= 'boolean' then return false, 'invalid' end
	if OPX.Cooling(player, 'radio.request', built.requestMs) then
		pcall(OPX.NotifyLocale, player, 'radio.error.too_fast', nil, 'warning')
		return false, 'too_fast'
	end

	local ok, code = true, 'done'
	if verb == 'ask' then
		if reconcile(player, true) == nil then ok, code = false, 'not_loaded' end
	elseif verb == 'join' then
		ok, code = join(player, key)
	elseif verb == 'leave' then
		ok, code = leave(player, key)
	elseif verb == 'select' then
		local state = stateOf(player)
		if state.joined[key] == nil then
			ok, code = false, 'not_joined'
		else
			if state.talking and state.talking.key ~= key then stopTalking(player, 'channel_changed') end
			state.active = key
			reconcile(player)
			code = 'selected'
		end
	elseif verb == 'mute' then
		local state = stateOf(player)
		state.muted[key] = payload.on or nil
		reconcile(player)
		code = payload.on and 'muted' or 'unmuted'
	elseif verb == 'power' then
		local state = stateOf(player)
		state.power = payload.on
		if not payload.on then stopTalking(player, 'power_off') end
		reconcile(player)
		code = payload.on and 'power_on' or 'power_off'
	end
	if not ok then pcall(OPX.NotifyLocale, player, 'radio.error.' .. code, nil, 'error') end
	return ok, code
end

--- The talk key went down (`on`) or up. Answers `(ok, code)`.
-- @author dop42
-- @param player integer
-- @param on boolean
-- @return boolean, string
function M.Talk(player, on)
	if on ~= true then
		-- A RELEASE IS NEVER REFUSED, rate-limited or questioned: it can only
		-- take a right away.
		stopTalking(player, nil)
		return true, 'released'
	end
	if OPX.Cooling(player, 'radio.talk', built.talkMs) then return false, 'too_fast' end
	local state = states[player]
	local key = state and state.active or nil
	local member = key and state.joined[key] or nil
	if member == nil then
		sendKeyed(player, false, 'no_channel')
		return false, 'no_channel'
	end
	if built.blockWhenDown and isDown(player) then
		sendKeyed(player, false, 'down')
		return false, 'down'
	end
	if state.talking ~= nil and state.talking.key == key then return true, 'talking' end
	if not setMember(player, key, member.listen, true) then
		sendKeyed(player, false, 'voice_refused')
		return false, 'voice_refused'
	end
	member.speak = true
	state.talking = { key = key, sinceMs = OPX.Now() }
	sendKeyed(player, true)
	return true, 'talking'
end

-- ── the clocks ──────────────────────────────────────────────────────────────

--- Lets go of a key held past MAX_TALK_MS, and of a downed player's.
-- @author dop42
function M.Tick()
	local now = OPX.Now()
	local release = {}
	for player, state in pairs(states) do
		if state.talking ~= nil then
			if now - state.talking.sinceMs > built.maxTalkMs then
				release[#release + 1] = { player, 'held_too_long' }
			elseif built.blockWhenDown and isDown(player) then
				release[#release + 1] = { player, 'down' }
			end
		end
	end
	for _, row in ipairs(release) do stopTalking(row[1], row[2]) end
end

--- Re-checks every player the radio knows: what no event announced.
-- @author dop42
--
-- THE ROSTER IS NOT WALKED. `character.GetPlayers` prunes entries it judges
-- stale as it goes, and a clock in another module must not be the thing that
-- drops somebody's character. Every loaded character reaches `states` through
-- `opx:on:character:loaded` anyway.
function M.Sweep()
	local players = {}
	for player in pairs(states) do players[#players + 1] = player end
	table.sort(players)
	for _, player in ipairs(players) do pcall(reconcile, player, false, true) end
end

-- ── the handset ─────────────────────────────────────────────────────────────

local function onHandsetUsed(source)
	local player = math.tointeger(tonumber(source))
	if player ~= nil then reconcile(player, true) end
	return { ok = true, consume = 0 }
end

local function registerItem()
	if built.item == nil then return end
	local api = inventory()
	if api == nil or type(api.RegisterItem) ~= 'function' then
		if built.requireItem then
			handsetChecked = false
			Open77.log.warn('[radio] no inventory contract: REQUIRE_ITEM cannot be honoured, the radio needs no handset')
		end
		return
	end
	local item = built.item
	local known = false
	if type(api.GetItem) == 'function' then
		local read, held = pcall(api.GetItem, item.name)
		known = read and held ~= nil
	end
	if not known then
		local read, done = pcall(api.RegisterItem, item.name, {
			label = item.label, description = item.description, weight = item.weight, stack = false,
			category = 'tool', model = item.model, use = { consume = 0, close = true },
		}, OWNER)
		if not read or type(done) ~= 'table' or done.ok ~= true then
			Open77.log.warn(('[radio] the handset item %s could not be registered: %s'):format(item.name,
				tostring(read and type(done) == 'table' and done.error or done)))
			return
		end
	end
	if type(api.RegisterUsable) == 'function' then pcall(api.RegisterUsable, item.name, onHandsetUsed, OWNER) end
end

-- ── commands ────────────────────────────────────────────────────────────────

local function report(source)
	local lines = {}
	for _, key in ipairs(built.order) do
		local channel = built.channels[key]
		local members = 0
		for _, state in pairs(states) do
			if state.joined[key] then members = members + 1 end
		end
		local gate = {}
		for name, grade in pairs(channel.jobs or {}) do gate[#gate + 1] = ('%s>=%s'):format(name, tostring(grade)) end
		for name, grade in pairs(channel.gangs or {}) do gate[#gate + 1] = ('gang %s>=%s'):format(name, tostring(grade)) end
		table.sort(gate)
		lines[#lines + 1] = ('  %-14s %-40s %d on air  [%s]%s%s'):format(key, channel.label, members,
			table.concat(gate, ', '), channel.onDuty and ' on duty' or '', channel.auto and ' auto' or '')
	end
	if #built.disabled > 0 then lines[#lines + 1] = '  disabled: ' .. table.concat(built.disabled, ', ') end
	for _, line in ipairs(built.problems) do lines[#lines + 1] = '  refused: ' .. line end
	OPX.CommandResult(source, true, 'radio channels:\n' .. table.concat(lines, '\n'))
end

local function registerCommands()
	OPX.Command.Register(M.Command.RADIO, { help = 'radio.help.radio', cooldownMs = 1000, key = 'radio.menu' },
		function(source)
			local player = math.tointeger(tonumber(source))
			if player == nil or player <= 0 then return end
			if reconcile(player, true) == nil then pcall(OPX.NotifyLocale, player, 'radio.error.not_loaded', nil, 'error') end
		end)
	OPX.Command.Register(M.Command.CHANNELS, { restricted = true, help = 'radio.help.channels' },
		function(source) report(source) end)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the channels out of the config. Never yields.
-- @author dop42
function M.Init()
	built = Model.Build(OPX.Config.MODULES.radio)
	M.Built = built
	voiceIds, states, refusedOnce, handsetChecked = {}, {}, {}, true
end

--- Publishes the `radio` v1 contract (docs: SHARED_CONTRACTS.md).
-- @author dop42
function M.Api()
	OPX.Api.Provide('radio', 1, {
		--- `Join(player, channel)` -> Result{ channels }: joins a channel the
		--- character may be on, on the same rules as the menu.
		Join = function(player, key)
			player = math.tointeger(tonumber(player))
			if player == nil or not Model.Key(key) then return Result.Err('radio.error.invalid') end
			local ok, code = join(player, key)
			if not ok then return Result.Err('radio.error.' .. code) end
			return Result.Ok({ channels = keysOf(states[player] and states[player].joined or {}) })
		end,
		--- `Leave(player, channel)` -> Result{ channels }.
		Leave = function(player, key)
			player = math.tointeger(tonumber(player))
			if player == nil or not Model.Key(key) then return Result.Err('radio.error.invalid') end
			local ok, code = leave(player, key)
			if not ok then return Result.Err('radio.error.' .. code) end
			return Result.Ok({ channels = keysOf(states[player] and states[player].joined or {}) })
		end,
		--- `Channels(player)` -> Result{ rows = { { key, label, short, auto,
		--- joined, muted, active } }, active }: every channel the character may
		--- be on, and where they stand on each.
		Channels = function(player)
			player = math.tointeger(tonumber(player))
			if player == nil then return Result.Err('radio.error.invalid') end
			local allowed = reconcile(player)
			if allowed == nil then return Result.Err('radio.error.not_loaded') end
			local state = states[player]
			return Result.Ok({ rows = Model.Rows(built, allowed, state.joined, state.active), active = state.active })
		end,
		--- The voice channel id behind a config entry, or nil (created on use).
		VoiceChannel = function(key) return voiceIds[key] end,
	})
end

--- Registers the handset, listens to the character and the bag, starts the
--- clocks.
-- @author dop42
function M.Start()
	for _, line in ipairs(built.problems) do Open77.log.warn('[radio] config: ' .. line) end
	if #built.disabled > 0 then
		Open77.log.info(('[radio] disabled channels: %s'):format(table.concat(built.disabled, ', ')))
	end
	if voice() == nil then
		Open77.log.warn('[radio] this server has no voice stack (Open77.voice): the radio carries no audio')
	end
	-- Names config/character.lua does not know: said once, the channel stays shut.
	local api = character()
	if api ~= nil then
		for _, key in ipairs(built.order) do
			local channel = built.channels[key]
			for name in pairs(channel.jobs or {}) do
				local read, known = pcall(api.GetJob, name)
				if type(api.GetJob) == 'function' and read and known == nil then
					Open77.log.warn(('[radio] config: CHANNELS.%s names the job %s, which config/character.lua does not have')
						:format(key, name))
				end
			end
			for name in pairs(channel.gangs or {}) do
				local read, known = pcall(api.GetGang, name)
				if type(api.GetGang) == 'function' and read and known == nil then
					Open77.log.warn(('[radio] config: CHANNELS.%s names the gang %s, which config/character.lua does not have')
						:format(key, name))
				end
			end
		end
	end
	registerItem()

	RegisterNetEvent(M.Event.REQUEST, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		M.Request(player, payload)
	end)
	RegisterNetEvent(M.Event.TALK, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		M.Talk(player, type(payload) == 'table' and payload.on == true)
	end)

	-- The public character bus: the payload is a hint, the roster is the truth.
	-- ON A THREAD OF ITS OWN: the bag read may yield, and the announcer (a
	-- `SetDuty` answering inline, a login) must never wait on the radio.
	local function onCharacter(player)
		player = math.tointeger(tonumber(player))
		if player ~= nil and player > 0 then
			CreateThread(function() pcall(reconcile, player) end)
		end
	end
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'job'), onCharacter)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'gang'), onCharacter)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'loaded'), onCharacter)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded'), function(player)
		player = math.tointeger(tonumber(player))
		if player ~= nil then dropPlayer(player) end
	end)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'inventory', 'items'), function(player, payload)
		if not built.requireItem or built.item == nil or type(payload) ~= 'table' then return end
		for _, change in ipairs(type(payload.changes) == 'table' and payload.changes or {}) do
			if type(change) == 'table' and change.name == built.item.name then return onCharacter(player) end
		end
	end)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed'), function(player)
		player = math.tointeger(tonumber(player))
		if player ~= nil and built.blockWhenDown and states[player] and states[player].talking and isDown(player) then
			stopTalking(player, 'down')
		end
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = math.tointeger(tonumber(playerId))
		if player ~= nil then dropPlayer(player) end
	end)

	registerCommands()
	tickJob = OPX.Scheduler.Every('radio:tick', 1000, M.Tick)
	sweepJob = OPX.Scheduler.Every('radio:sweep', built.sweepMs, M.Sweep)
end

--- Takes everybody off the air and gives the channels back.
-- @author dop42
function M.Stop()
	for _, job in ipairs({ tickJob, sweepJob }) do
		if job ~= nil and OPX.Scheduler.Cancel ~= nil then pcall(OPX.Scheduler.Cancel, job) end
	end
	tickJob, sweepJob = nil, nil
	local players = {}
	for player in pairs(states) do players[#players + 1] = player end
	for _, player in ipairs(players) do pcall(dropPlayer, player) end
	for key, id in pairs(voiceIds) do
		voiceCall('removeChannel', id)
		voiceIds[key] = nil
	end
	local api = inventory()
	if built.item ~= nil and api ~= nil and type(api.UnregisterUsable) == 'function' then
		pcall(api.UnregisterUsable, built.item.name, OWNER)
	end
end
