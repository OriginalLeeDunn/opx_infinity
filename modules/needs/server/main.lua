--- Server half: the authority on every need, its decay, and the save paths.
-- @author dop42
--
-- THE SERVER OWNS THE VALUES. This header used to say the opposite: the client
-- held the needs during play, decayed them itself and pushed them here, and the
-- guards were "ownership and bounds rather than simulation" -- the owner's
-- ruling at the time. It meant a client that pushed `{ hunger = 100 }` every two
-- minutes was never hungry, and nothing here could tell. The owner reversed it
-- (2026-10, after the hostile-net-events audit, PR #99): needs are
-- server-authoritative.
--
-- So, now:
--   * the decay runs HERE, on `DECAY_MS`, at each need's `DECAY_PER_MINUTE`;
--   * a need goes up only through this module's contract -- an item used
--     (`modules/inventory`, server side, after the unit is consumed), a staff
--     command (`/opx.needs.set`) or a creator export (`AddNeeds`, `SetNeeds`);
--   * the client is a display. It asks for the values once (`pull`) and is sent
--     them every time they move (`values`). There is no push: the event is gone,
--     so a value a client sends has nowhere to land.
--
-- There is no starvation. A need at its MIN stays at its MIN; nothing in this
-- runtime downs or kills a body for it.

local M = OPX.Modules.Get('needs')
local Bounds = M.Bounds
local Result = OPX.Result

local EVENT_PULL = OPX.Event(OPX.Channel.NET, 'needs', 'pull')
local EVENT_VALUES = OPX.Event(OPX.Channel.NET, 'needs', 'values')

-- The server bus, for other resources: `(source, { citizenId, values, changed,
-- source })`, the same shape the client raises under the same name.
local ON_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'needs', 'changed')

-- Length of one rate-limit window, in milliseconds, and the pulls one player may
-- send in it. A guard against flooding, not a budget a correct client reaches.
local WINDOW_MS = 10000
local PULLS_PER_WINDOW = 4

-- Per loaded player: citizenId, values, dirty, and when the decay last ran.
local held = {}

-- Players whose load is in flight, so two loads for one slot do not race.
local loading = {}

-- Rate-limit windows per player.
local pullWindows = {}

-- The character contract, looked up in `Start`.
local character

--- Counts one event against a player's window and answers whether it fits.
local function within(windows, player, limit, spanMs)
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= spanMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limit then return false end
	window.count = window.count + 1
	return true
end

--- The citizen id the character module has loaded for a player, or nil.
local function loadedCitizenOf(player)
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local loaded = character.GetPlayer(player)
	local data = loaded and loaded.PlayerData
	if type(data) ~= 'table' or type(data.citizenId) ~= 'string' then return nil end
	return data.citizenId
end

--- Whether the schema settled, so nothing is read or written before the table
--- exists.
local function usable()
	return OPX.BootError == nil
end

--- A copy of a record's values, so nobody holding an answer can edit the record.
local function copyOf(values)
	local copy = {}
	for key, value in pairs(values) do copy[key] = value end
	return copy
end

--- Writes a player's unsaved values, now or on a new thread.
-- @param now boolean|nil write on this stack, for a stopping resource
local function flush(player, forget, now)
	local record = held[player]
	if forget then held[player] = nil end
	if record == nil or not record.dirty then return end
	record.dirty = false

	local function write()
		if not M.Storage.Save(record.citizenId, record.values) then
			record.dirty = not forget
		end
	end

	if now then write() else CreateThread(write) end
end

--- Tells the player's client, and the server bus, what the values are now.
local function announce(player, record, changed, reason)
	TriggerClientEvent(EVENT_VALUES, player, record.citizenId, copyOf(record.values), reason)
	OPX.Publish(ON_CHANGED, player, {
		citizenId = record.citizenId,
		values = copyOf(record.values),
		changed = changed,
		source = reason,
	})
end

--- Loads the stored needs of the character a player has loaded, once. Yields.
-- @return table|nil the record
local function load(player)
	local id = loadedCitizenOf(player)
	if id == nil or not usable() then return nil end
	local record = held[player]
	if record ~= nil and record.citizenId == id then return record end
	if loading[player] == id then return nil end
	loading[player] = id

	local values, reason = M.Storage.Load(id)
	if loading[player] == id then loading[player] = nil end
	if values == nil then
		Open77.log.warn(('%s could not be read: %s'):format(OPX.Audit.Safe(id), tostring(reason)))
		return nil
	end
	-- The slot may have moved on while the row was read.
	if loadedCitizenOf(player) ~= id then return nil end
	record = held[player]
	if record ~= nil and record.citizenId == id then return record end
	if record ~= nil then flush(player, false) end

	record = { citizenId = id, values = values, dirty = false, decayedAt = OPX.Now() }
	held[player] = record
	return record
end

--- Applies an absolute or relative patch to a held record. Never yields.
-- @return Result `{ values, changed }`
local function apply(player, patch, relative, reason)
	local record = held[player]
	if record == nil then return Result.Err('not_loaded') end
	if type(patch) ~= 'table' then return Result.Err('spec_must_be_a_table') end

	local wanted, count = {}, 0
	for key, raw in pairs(patch) do
		if not Bounds.IsField(key) then return Result.Err('unknown_need') end
		local value = tonumber(raw)
		if not OPX.Math.IsFinite(value) then return Result.Err('invalid_need_value') end
		if relative then value = record.values[key] + value end
		wanted[key] = Bounds.Clamp(key, value)
		count = count + 1
	end
	if count == 0 then return Result.Err('empty_patch') end

	local changed = {}
	for key, value in pairs(wanted) do
		if record.values[key] ~= value then
			record.values[key] = value
			changed[#changed + 1] = key
		end
	end
	table.sort(changed)
	if #changed > 0 then
		record.dirty = true
		announce(player, record, changed, reason)
	end
	return Result.Ok({ values = copyOf(record.values), changed = changed })
end

--- Charges DECAY_PER_MINUTE for the time since the record last decayed.
local function decay(player, record, atMs)
	local minutes = (atMs - record.decayedAt) / 60000
	record.decayedAt = atMs
	if minutes <= 0 then return end
	local patch, any = {}, false
	for key, field in pairs(M.Fields) do
		local rate = field.DECAY_PER_MINUTE
		-- Finiteness, not `~= nil`: a NaN or an infinity in the configuration
		-- would pass a plain `> 0`.
		if OPX.Math.IsFinite(rate) and rate > 0 then
			patch[key] = -(rate * minutes)
			any = true
		end
	end
	if any then apply(player, patch, true, 'decay') end
end

--- One decay pass over every held player.
local function decayAll()
	local atMs = OPX.Now()
	for player, record in pairs(held) do
		if loadedCitizenOf(player) == record.citizenId then decay(player, record, atMs) end
	end
end

--- Answers a client's pull with the values the server holds, loading them first
--- when needed. The id the client names is only compared, never trusted.
local function onPull(rawCitizenId)
	local player = tonumber(source) or 0
	if player <= 0 then return end
	if not within(pullWindows, player, PULLS_PER_WINDOW, WINDOW_MS) then return end
	if type(rawCitizenId) ~= 'string' or #rawCitizenId > 16 then return end

	CreateThread(function()
		local loaded = loadedCitizenOf(player)
		if loaded == nil then return end
		if loaded ~= rawCitizenId then
			OPX.Audit.Security('needs.pull.refused',
				('%s is not their loaded character'):format(OPX.Audit.Safe(rawCitizenId)), nil, player)
			return
		end
		local record = load(player)
		if record == nil then return end
		TriggerClientEvent(EVENT_VALUES, player, record.citizenId, copyOf(record.values), 'loaded')
	end)
end

--- Saves and forgets a departing player.
local function departed(rawPlayerId)
	local player = tonumber(rawPlayerId) or 0
	if player <= 0 then return end
	local record = held[player]
	flush(player, true)
	loading[player] = nil
	pullWindows[player] = nil
	OPX.Audit.Forget(player, record and record.citizenId or nil)
end

--- Runs one autosave pass over every held player.
local function autosave()
	for player in pairs(held) do flush(player, false) end
end

-- ── the contract ─────────────────────────────────────────────────────────────

--- A player's needs, loading them when they are not held yet. Yields.
-- @param player any
-- @return Result `{ values, citizenId }`
local function getNeeds(player)
	player = math.tointeger(tonumber(player))
	if player == nil or player <= 0 then return Result.Err('bad_player') end
	local record = load(player)
	if record == nil then return Result.Err('not_loaded') end
	return Result.Ok({ values = copyOf(record.values), citizenId = record.citizenId })
end

--- Moves a player's needs, absolutely or by a delta, clamped. Yields on a first
--- load.
local function writer(relative, defaultReason)
	return function(player, patch, reason)
		player = math.tointeger(tonumber(player))
		if player == nil or player <= 0 then return Result.Err('bad_player') end
		if load(player) == nil then return Result.Err('not_loaded') end
		local why = type(reason) == 'string' and reason:match('^[%w_%.:%-]+$') and #reason <= 64
			and reason or defaultReason
		return apply(player, patch, relative, why)
	end
end

local setNeeds = writer(false, 'set')
local addNeeds = writer(true, 'add')

-- ── the staff door ───────────────────────────────────────────────────────────

--- `/opx.needs.set <player> <need> <value>`, ACL-gated: the staff path the
--- owner's ruling names, and the only way a need goes up by hand.
local function registerCommands()
	OPX.Command.Register('opx.needs.set', {
		restricted = true,
		help = 'needs.help.set',
		params = {
			{ name = 'player', help = locale('needs.help.player') },
			{ name = 'need', help = locale('needs.help.need') },
			{ name = 'value', help = locale('needs.help.value') },
		},
	}, function(caller, args)
		local target = math.tointeger(tonumber(args[1]))
		local need, value = args[2], tonumber(args[3])
		if target == nil or not Bounds.IsField(need) or not OPX.Math.IsFinite(value) then
			return OPX.CommandResult(caller, false, locale('needs.usage.set'))
		end
		CreateThread(function()
			local done = setNeeds(target, { [need] = value }, 'staff')
			if not done.ok then
				return OPX.CommandResult(caller, false, locale('needs.refused',
					{ reason = tostring(done.error) }))
			end
			OPX.Audit.Log({ event = 'needs.set', source = caller,
				message = ('%s=%s on player %d'):format(need, tostring(done.value.values[need]), target) })
			OPX.CommandResult(caller, true, locale('needs.done.set',
				{ need = need, value = done.value.values[need], player = target }))
		end)
	end)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state and contributes the table.
-- @author dop42
function M.Init()
	M.ReadSettings()
	held, loading = {}, {}
	pullWindows = {}
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server contract: the one way anything in this runtime moves a
--- need.
-- @author dop42
function M.Api()
	OPX.Api.Provide('needs', 1, {
		GetNeeds = getNeeds,
		SetNeeds = setNeeds,
		AddNeeds = addNeeds,
	})
end

--- Wires the pull, the character's arrival and departure, the decay and the
--- autosave.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.warn('no character contract: no needs will be loaded or saved')
	end

	-- A DELETED CHARACTER TAKES ITS NEEDS WITH IT. This table carries no foreign
	-- key at all -- the header in `storage.lua` says why -- and one would not have
	-- helped anyway, because a character delete is a soft one and no cascade fires
	-- for an UPDATE. See `character.Event.IN_DELETED`, whose name is rebuilt here
	-- the way every module rebuilds another's.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			M.Storage.PurgeCharacter(citizenId)
		end)

	-- Loaded on the server's own word that a character arrived: the decay must
	-- not wait for a client to ask.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'loaded'), function(rawPlayer)
		local player = tonumber(rawPlayer)
		if player == nil or player <= 0 then return end
		CreateThread(function()
			local record = load(player)
			if record ~= nil then
				TriggerClientEvent(EVENT_VALUES, player, record.citizenId, copyOf(record.values), 'loaded')
			end
		end)
	end)
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'unloaded'), function(rawPlayer)
		local player = tonumber(rawPlayer)
		if player ~= nil then flush(player, true) end
	end)

	RegisterNetEvent(EVENT_PULL, onPull)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)
	registerCommands()

	local decayMs = math.max(1000, math.floor(tonumber(M.Settings.DECAY_MS) or 60000))
	OPX.Scheduler.Every('needs:decay', decayMs, decayAll)
	local interval = math.max(1000, math.floor(tonumber(M.Settings.AUTOSAVE_MS) or 300000))
	OPX.Scheduler.Every('needs:autosave', interval, autosave)
end

--- Writes every held record on this stack.
-- @author dop42
--
-- A stopping resource sees no further tick, so a `CreateThread` here would write
-- nothing: this runs on the stop handler's own stack.
function M.Stop()
	for player in pairs(held) do flush(player, false, true) end
end
