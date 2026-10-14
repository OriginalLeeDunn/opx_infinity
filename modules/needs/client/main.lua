--- Client half: the effect registry, the needs as the server last sent them, and
--- the contract.
-- @author dop42
--
-- THE SERVER OWNS THE NEEDS (the owner's ruling, 2026-10; see the header of
-- server/main.lua). This half decays nothing and sends nothing back: it asks for
-- the values once, adopts every `values` the server sends, and publishes them
-- for a view. Effects live here only: a chip is added by whoever wants one
-- drawn, and this half orders them, expires them and publishes the strip.

local M = OPX.Modules.Get('needs')
local Bounds = M.Bounds

local Result = OPX.Result

-- Server to client: the values, on a pull and every time they move.
local EVENT_VALUES = OPX.Event(OPX.Channel.NET, 'needs', 'values')

-- Client to server: "send me the values". The only thing this half says.
local EVENT_PULL = OPX.Event(OPX.Channel.NET, 'needs', 'pull')

-- The client local bus, which is what a view and any third party listen on.
-- These must stay on the LOCAL channel: the host dispatcher matches on the name
-- alone, so a local raise on a NET name would re-enter the handlers above.
local EVENT_EFFECTS = OPX.Event(OPX.Channel.LOCAL, 'needs', 'effects')
local EVENT_EFFECT = OPX.Event(OPX.Channel.LOCAL, 'needs', 'effect')
local EVENT_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'needs', 'changed')

-- The character module's own local events, the two moments a character arrives
-- and leaves.
local EVENT_CHARACTER_LOADED = OPX.Event(OPX.Channel.LOCAL, 'character', 'loaded')
local EVENT_CHARACTER_UNLOADED = OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded')

-- Longest effect id a caller may choose, and longest owner name.
local MAX_ID = 64
local MAX_OWNER = 64

-- Longest label and icon, in characters, and longest event name an effect carries.
local MAX_LABEL = 32
local MAX_ICON = 2
local MAX_EVENT = 96

-- Longest effect duration, in milliseconds.
local MAX_DURATION_MS = 3600000

-- Most nodes, and deepest nesting, a caller's opaque data table may have.
local MAX_DATA_NODES = 64
local MAX_DATA_DEPTH = 4

-- Most effects one owner may hold.
local MAX_PER_OWNER = 24

-- Milliseconds between two sweeps of expired effects, and between two checks of
-- every owner against the host.
local TICK_MS = 250
local OWNER_SWEEP_MS = 1000

-- Milliseconds before asking again for a character with no values.
local PULL_RETRY_MS = 10000

-- The tones an effect may carry: a presentation role, or one of 2077's damage
-- types.
local TONES = {
	ok = true, warn = true, bad = true, accent = true,
	bleed = true, burn = true, shock = true, chem = true,
}

M.Effects = {}
local Effects = M.Effects

M.Needs = {}
local Needs = M.Needs

-- Signature of the last published strip, nil before the first.
local drawn = nil

-- When the next owner sweep is due, on the monotonic clock.
local nextOwnerSweepMs = 0

-- When the last pull went.
local lastPullAtMs = 0

-- Whether a value is a short name of word characters and punctuation.
local function validName(value, maximum)
	return type(value) == 'string' and #value > 0 and #value <= maximum
		and value:match('^[%w_:%-%.]+$') ~= nil
end

-- Counts a caller's opaque table against the node and depth budgets. `data`
-- travels in every event raised for the effect and the host silently drops a
-- payload past 1024 nodes, so an oversized one is refused rather than cut.
local function fitsInPayload(value, depth, budget)
	budget.data = budget.data + 1
	if budget.data > MAX_DATA_NODES then return false end
	if type(value) ~= 'table' then return true end
	if depth > MAX_DATA_DEPTH then return false end
	for key, nested in pairs(value) do
		if not fitsInPayload(key, depth + 1, budget) then return false end
		if not fitsInPayload(nested, depth + 1, budget) then return false end
	end
	return true
end

--- Validates an effect spec and builds the stored effect, or refuses it.
-- @author dop42
--
-- The whole effect is built or none of it is; only a label is cleaned rather
-- than refused. `expiresAtMs` is a date on the monotonic clock and not a
-- remainder, so a view counts down on its own and a countdown costs no traffic.
-- @param owner string
-- @param spec table
-- @param atMs integer
-- @return table|nil, string|nil
function M.Effects.Normalize(owner, spec, atMs)
	if type(spec) ~= 'table' then return nil, 'spec_must_be_a_table' end

	local id = spec.id
	if id == nil then return nil, 'missing_id' end
	if not validName(id, MAX_ID) then return nil, 'invalid_id' end

	local label = OPX.Text.Clean(spec.label, MAX_LABEL)
	if label == nil or label == '' then return nil, 'invalid_label' end

	if spec.event ~= nil and not validName(spec.event, MAX_EVENT) then
		return nil, 'invalid_event'
	end

	local tone = spec.tone
	if tone ~= nil and not TONES[tone] then return nil, 'invalid_tone' end

	local duration = spec.durationMs
	if duration ~= nil then
		if not OPX.Math.IsFinite(duration) or duration <= 0 or duration > MAX_DURATION_MS then
			return nil, 'invalid_duration'
		end
	end

	if spec.data ~= nil then
		if type(spec.data) ~= 'table' then return nil, 'invalid_data' end
		if not fitsInPayload(spec.data, 1, { data = 0 }) then return nil, 'data_too_large' end
	end

	local progress = spec.progress
	if progress ~= nil then
		if not OPX.Math.IsFinite(progress) then return nil, 'invalid_progress' end
		progress = OPX.Math.Clamp(progress, 0, 1)
	end

	return {
		owner = owner,
		id = id,
		label = label,
		icon = OPX.Text.Clean(spec.icon, MAX_ICON),
		tone = tone,
		expiresAtMs = duration and (atMs + math.floor(duration)) or nil,
		startedAtMs = atMs,
		progress = progress,
		priority = OPX.Math.IsFinite(spec.priority) and spec.priority or 0,
		event = spec.event,
		data = spec.data,
	}
end

-- One owner's effect by id, or nil.
local function get(owner, id)
	local mine = Effects.byOwner[owner]
	return mine and mine[id] or nil
end

-- Stores an effect under its owner, replacing one with its id.
local function put(effect)
	local mine = Effects.byOwner[effect.owner]
	if mine == nil then
		mine = {}
		Effects.byOwner[effect.owner] = mine
	end
	mine[effect.id] = effect
end

-- How many effects one owner holds.
local function count(owner)
	local mine = Effects.byOwner[owner]
	if mine == nil then return 0 end
	local total = OPX.Table.Count(mine)
	return total
end

-- Removes one owner's effect and answers whether it existed.
local function remove(owner, id)
	local mine = Effects.byOwner[owner]
	if mine == nil or mine[id] == nil then return false end
	mine[id] = nil
	return true
end

-- Removes every effect of one owner and answers how many.
local function removeOwner(owner)
	local mine = Effects.byOwner[owner]
	if mine == nil then return 0 end
	local removed = count(owner)
	Effects.byOwner[owner] = nil
	return removed
end

--- Lists every live effect, highest priority then newest first.
-- @author dop42
--
-- A total order, down to owner and id: on equal keys the order of `pairs` would
-- reshuffle the strip between two publications, and the urgent effect is never
-- pushed past MAX_VISIBLE by the trivial one.
-- @return table[]
function M.Effects.Ordered()
	local all = {}
	for _, mine in pairs(Effects.byOwner) do
		for _, effect in pairs(mine) do all[#all + 1] = effect end
	end
	table.sort(all, function(a, b)
		if a.priority ~= b.priority then return a.priority > b.priority end
		if a.startedAtMs ~= b.startedAtMs then return a.startedAtMs > b.startedAtMs end
		return a.owner .. '\1' .. a.id < b.owner .. '\1' .. b.id
	end)
	return all
end

--- Builds the visible chips and the count of effects left out.
-- @author dop42
-- @param atMs integer
-- @return table
function M.Effects.View(atMs)
	local all = Effects.Ordered()
	local chips = {}
	local limit = M.Settings.MAX_VISIBLE
	for index = 1, math.min(#all, limit) do
		local effect = all[index]
		chips[index] = {
			id = effect.owner .. ':' .. effect.id,
			label = effect.label,
			icon = effect.icon,
			tone = effect.tone,
			progress = effect.progress,
			remainingMs = effect.expiresAtMs and math.max(0, effect.expiresAtMs - atMs) or nil,
			totalMs = effect.expiresAtMs and (effect.expiresAtMs - effect.startedAtMs) or nil,
		}
	end
	return { chips = chips, hidden = math.max(0, #all - limit) }
end

-- Effects whose deadline has passed, or nil when none. The list is built lazily
-- because almost every pass has nothing to collect.
local function expired(atMs)
	local due = nil
	for _, mine in pairs(Effects.byOwner) do
		for _, effect in pairs(mine) do
			if effect.expiresAtMs ~= nil and atMs >= effect.expiresAtMs then
				due = due or {}
				due[#due + 1] = effect
			end
		end
	end
	return due
end

-- Tells an effect's owner it was removed or expired. No call ever answers into a
-- caller, so an owner learns what happened to its effect by event.
local function emit(effect, action)
	local payload = {
		status = effect.id,
		owner = effect.owner,
		action = action,
		label = effect.label,
		tone = effect.tone,
		data = effect.data,
	}
	if effect.event then TriggerEvent(effect.event, payload) end
	-- Raised in addition to the effect's own event so that one listener sees them
	-- all, and only once when the owner named this event as its own.
	if EVENT_EFFECT ~= effect.event then TriggerEvent(EVENT_EFFECT, payload) end
end

-- Summarises a strip without the countdowns a view animates, so that a ticking
-- timer republishes nothing.
local function signature(view)
	local chips = view.chips
	local parts = { tostring(view.hidden) }
	for index = 1, #chips do
		local chip = chips[index]
		parts[index + 1] = table.concat({
			chip.id, chip.label, chip.icon or '', chip.tone or '',
			tostring(chip.progress or ''), tostring(chip.totalMs or ''),
		}, '\1')
	end
	return table.concat(parts, '\2')
end

-- Publishes the strip when it changed, or when forced.
local function draw(force)
	local view = Effects.View(OPX.Now())
	local current = signature(view)
	if not force and current == drawn then return end
	drawn = current
	TriggerEvent(EVENT_EFFECTS, {
		anchor = M.Settings.ANCHOR,
		offset = M.Settings.OFFSET,
		chips = view.chips,
		hidden = view.hidden,
	})
end

-- Notes the generation of an owner the host knows as a resource, dropping its
-- effects when it reloaded. An owner the host does not know -- another module of
-- this runtime -- carries no generation and is never swept.
local function noteOwner(owner)
	local resource = Open77.resource
	if type(resource) ~= 'table' or type(resource.generation) ~= 'function' then return end
	local read, generation = pcall(resource.generation, owner)
	if not read or type(generation) ~= 'number' or generation == 0 then return end
	if Effects.generations[owner] ~= nil and Effects.generations[owner] ~= generation then
		if removeOwner(owner) > 0 then draw() end
	end
	Effects.generations[owner] = generation
end

-- Drops the effects of owners that stopped or reloaded. Called before the
-- expiry test and not inside it: an expiry must not put the sweep off.
local function sweepOwners(atMs)
	if atMs < nextOwnerSweepMs then return 0 end
	nextOwnerSweepMs = atMs + OWNER_SWEEP_MS

	-- Read once per pass rather than twice per owner.
	local generationOf = Open77.resource.generation

	local stopped, stoppedCount = nil, 0
	for owner, generation in pairs(Effects.generations) do
		local state = GetResourceState(owner)
		-- `starting` counts as alive: a resource that adds a chip from its own
		-- start handler is still starting, and keeping only `running` would take
		-- its chips away on the next sweep.
		local alive = state == 'running' or state == 'starting'
		local current = generationOf(owner)
		-- An unknown generation removes nothing: the client reader answers nil
		-- for an absent resource and 0 for 'unavailable', and only a generation
		-- that was read and differs means the code that placed those effects is
		-- gone.
		if not alive or (current ~= nil and current ~= 0 and current ~= generation) then
			stoppedCount = stoppedCount + 1
			stopped = stopped or {}
			stopped[stoppedCount] = owner
		end
	end

	-- Collected first, because removing them changes the table being walked.
	for index = 1, stoppedCount do
		local owner = stopped[index]
		removeOwner(owner)
		Effects.generations[owner] = nil
	end
	return stoppedCount
end

-- Removes expired effects and those of stopped or reloaded owners.
local function tick()
	local atMs = OPX.Now()

	local due = expired(atMs)
	local expiredCount = due and #due or 0
	for index = 1, expiredCount do
		local effect = due[index]
		remove(effect.owner, effect.id)
		emit(effect, 'expired')
	end

	local swept = sweepOwners(atMs)
	if expiredCount > 0 or swept > 0 then draw() end
end

--- A shallow copy of the held values.
-- @author dop42
-- @return table
function M.Needs.Snapshot()
	local copy = {}
	for key, value in pairs(Needs.values) do copy[key] = value end
	return copy
end

--- Starts over on a character, with nothing to show until the server answers.
-- @author dop42
-- @param citizenId string
function M.Needs.Begin(citizenId)
	Needs.citizenId = citizenId
	Needs.ready = false
	Needs.values = Bounds.Defaults()
end

--- Adopts what the server sent, defaults filling the gaps, and answers the keys
--- that moved.
-- @author dop42
-- @param raw any
-- @return table
function M.Needs.Receive(raw)
	local values = Bounds.Read(raw)
	local changed = {}
	for key, value in pairs(values) do
		if not Needs.ready or Needs.values[key] ~= value then changed[#changed + 1] = key end
	end
	table.sort(changed)
	Needs.values = values
	Needs.ready = true
	return changed
end

--- Drops the character and everything held for it.
-- @author dop42
function M.Needs.Forget()
	Needs.citizenId = nil
	Needs.ready = false
	Needs.values = {}
end

-- Raises the needs event a view redraws from.
local function publishNeeds(origin, changed)
	TriggerEvent(EVENT_CHANGED, {
		values = Needs.Snapshot(),
		changed = changed,
		source = origin,
		citizenId = Needs.citizenId,
		ready = Needs.ready,
	})
end

-- Asks the server half for this character's values.
local function pull(atMs)
	lastPullAtMs = atMs
	local accepted, reason = TriggerServerEvent(EVENT_PULL, Needs.citizenId)
	if not accepted then
		Open77.log.debug(('needs not requested: %s'):format(tostring(reason)))
	end
end

-- Adopts a character and asks for its values, once per id.
local function bindCharacter(citizenId)
	if type(citizenId) ~= 'string' or citizenId == '' then return end
	if Needs.citizenId == citizenId then return end
	Needs.Begin(citizenId)
	pull(OPX.Now())
end

-- Forgets the character and publishes empty needs. Nothing is sent: the server
-- holds the values and saves them itself.
local function unloadCharacter()
	if Needs.citizenId == nil then return end
	Needs.Forget()
	publishNeeds('unloaded', {})
end

-- Retries an unanswered pull.
local function needsTick()
	if Needs.citizenId == nil or Needs.ready then return end
	local atMs = OPX.Now()
	if atMs - lastPullAtMs >= PULL_RETRY_MS then pull(atMs) end
end

-- Adopts the server's values for the bound character. A late answer for a
-- character already replaced is ignored. The reason travels with them: `loaded`,
-- `decay`, `use`, `staff`, or whatever a creator export named.
local function onValues(citizenId, values, reason)
	if citizenId ~= Needs.citizenId then return end
	local first = not Needs.ready
	local changed = Needs.Receive(values)
	if #changed == 0 and not first then return end
	publishNeeds(first and 'loaded' or (type(reason) == 'string' and reason or 'server'), changed)
end

-- Drops the effects of another resource that stopped, at once rather than on the
-- next tick.
local function onResourceStopped(name)
	if name == GetCurrentResourceName() then return end
	if removeOwner(name) > 0 then draw() end
	Effects.generations[name] = nil
end

-- Reads the owner of a call and refuses an unusable name.
local function ownerOf(owner)
	if not validName(owner, MAX_OWNER) then return nil end
	noteOwner(owner)
	return owner
end

--- Adds or replaces one of the owner's effects, within its limit.
-- @author dop42
--
-- Replacing is not adding: the per-owner limit only holds back new ids, so
-- rewriting one of its own always goes through.
-- @param owner string
-- @param spec table
-- @return Result
local function addEffect(owner, spec)
	if ownerOf(owner) == nil then return Result.Err('invalid_owner') end
	local effect, reason = Effects.Normalize(owner, spec, OPX.Now())
	if effect == nil then return Result.Err(reason) end
	if get(owner, effect.id) == nil and count(owner) >= MAX_PER_OWNER then
		return Result.Err('owner_limit')
	end
	put(effect)
	draw()
	return Result.Ok({ id = effect.id })
end

-- The patched value, or the held one when none was given. An `if`, because
-- `given ~= nil and given or held` collapses on false.
local function pick(given, held)
	if given ~= nil then return given end
	return held
end

--- Patches one of the owner's effects, keeping its deadline unless a new
--- duration is given.
-- @author dop42
-- @param owner string
-- @param id string
-- @param patch table
-- @return Result
local function updateEffect(owner, id, patch)
	if ownerOf(owner) == nil then return Result.Err('invalid_owner') end
	if not validName(id, MAX_ID) then return Result.Err('invalid_id') end
	local current = get(owner, id)
	if current == nil then return Result.Err('not_found') end
	if type(patch) ~= 'table' then return Result.Err('spec_must_be_a_table') end

	local merged = {
		id = id,
		label = pick(patch.label, current.label),
		icon = pick(patch.icon, current.icon),
		tone = pick(patch.tone, current.tone),
		progress = pick(patch.progress, current.progress),
		priority = pick(patch.priority, current.priority),
		event = pick(patch.event, current.event),
		data = pick(patch.data, current.data),
		durationMs = patch.durationMs,
	}
	local effect, reason = Effects.Normalize(owner, merged, OPX.Now())
	if effect == nil then return Result.Err(reason) end
	if patch.durationMs == nil then
		effect.expiresAtMs = current.expiresAtMs
		effect.startedAtMs = current.startedAtMs
	end
	put(effect)
	draw()
	return Result.Ok(true)
end

--- Removes one of the owner's effects and tells the owner.
-- @author dop42
-- @param owner string
-- @param id string
-- @return Result
local function removeEffect(owner, id)
	if ownerOf(owner) == nil then return Result.Err('invalid_owner') end
	if not validName(id, MAX_ID) then return Result.Err('invalid_id') end
	local effect = get(owner, id)
	if effect == nil then return Result.Err('not_found') end
	remove(owner, id)
	emit(effect, 'removed')
	draw()
	return Result.Ok(true)
end

--- Removes every effect of the owner and answers how many. Never touches
--- another owner's.
-- @author dop42
-- @param owner string
-- @return Result
local function clearEffects(owner)
	if ownerOf(owner) == nil then return Result.Err('invalid_owner') end
	local removed = removeOwner(owner)
	if removed > 0 then draw() end
	return Result.Ok({ removed = removed })
end

--- The character's needs as the server last sent them.
-- @author dop42
-- @return Result
local function getNeeds()
	if Needs.citizenId == nil then return Result.Err('no_character') end
	if not Needs.ready then return Result.Err('not_loaded', Needs.citizenId) end
	return Result.Ok({
		values = Needs.Snapshot(),
		citizenId = Needs.citizenId,
		ready = true,
	})
end

--- Builds the registry and the held needs.
-- @author dop42
function M.Init()
	M.ReadSettings()

	-- Live effects by owner, then by effect id, and the generation each owner
	-- carrying one was last seen at.
	Effects.byOwner = {}
	Effects.generations = {}

	Needs.citizenId = nil
	Needs.ready = false
	Needs.values = {}
end

--- Publishes the effects and the needs.
-- @author dop42
function M.Api()
	OPX.Api.Provide('needs', 1, {
		-- Read only. A need moves on the SERVER (its `needs` contract, a staff
		-- command or a creator export); `SetNeeds` and `AddNeeds` were here and
		-- wrote the values a client then pushed, which is what the owner ruled out.
		GetNeeds = getNeeds,
		AddEffect = addEffect,
		UpdateEffect = updateEffect,
		RemoveEffect = removeEffect,
		ClearEffects = clearEffects,
	})
end

--- Wires the events and registers the two loops.
-- @author dop42
function M.Start()
	RegisterNetEvent(EVENT_VALUES, onValues)

	AddEventHandler(EVENT_CHARACTER_LOADED, function(payload)
		if type(payload) ~= 'table' then return end
		bindCharacter(payload.citizenId)
	end)
	AddEventHandler(EVENT_CHARACTER_UNLOADED, unloadCharacter)
	AddEventHandler(OPX.Host.CLIENT_RESOURCE_STOP, onResourceStopped)

	-- A character may already be loaded when this module starts, and the loaded
	-- event is then long past.
	local character = OPX.Api.Get('character')
	if character ~= nil and type(character.GetCitizenId) == 'function' then
		bindCharacter(character.GetCitizenId())
	end

	OPX.Scheduler.Every('needs:effects', TICK_MS, tick)
	OPX.Scheduler.Every('needs:tick', PULL_RETRY_MS, needsTick)
end

--- Takes the strip down.
-- @author dop42
--
-- The strip is emptied and republished by force: no later publication would
-- correct an abandoned one. No `emit` here -- an owner's handler could call back
-- into a VM that is half stopped. Nothing is sent: the server holds the needs.
function M.Stop()
	Effects.byOwner = {}
	Effects.generations = {}
	draw(true)
end
