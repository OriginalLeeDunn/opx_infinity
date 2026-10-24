--- Persistent cosmetic cyberarms, confined to the owner and a surveyed clinic.
-- @author dop42
--
-- The client discovers installed models, but never names a patient or character.
-- The server bounds the snapshot, optionally restricts records, and saves only
-- after native acceptance. No implant, money or ability is granted by this service.
-- op77.152 APIs are documented upstream; the op77.148 devkit predates them.

local M = OPX.Modules.Get('ripperdoc')
local KEY = 'cyberarmStyle'
local pending, last = {}, {}
local serial = 0

local function settings()
	local cfg = type(M.Settings) == 'table' and M.Settings.STYLES or nil
	return type(cfg) == 'table' and cfg or {}
end

local function character() return OPX.Api.Get('character') end
local function dataOf(player)
	local api = character()
	local loaded = api and api.GetPlayer(player)
	return type(loaded) == 'table' and loaded.PlayerData or nil
end

local function rgb(value)
	if type(value) ~= 'table' then return nil end
	local out = {}
	for _, channel in ipairs({ 'r', 'g', 'b' }) do
		local v = value[channel]
		if type(v) ~= 'number' or math.type(v) ~= 'integer' or v < 0 or v > 255 then return nil end
		out[channel] = v
	end
	return out
end

--- Copies only schema-one fields; records remain cosmetic identifiers.
function M.ValidateStyle(value)
	if type(value) ~= 'table' or value.schemaVersion ~= 1 or value.enabled ~= true then return nil end
	local record = value.record
	if type(record) ~= 'string' or #record < 1 or #record > 160 or record:find('[^%w_.%-]') then return nil end
	local records = settings().RECORDS
	if type(records) == 'table' and next(records) ~= nil and records[record] ~= true then return nil end
	local primary, secondary = rgb(value.primary), rgb(value.secondary)
	if not primary or not secondary then return nil end
	return { schemaVersion = 1, enabled = true, record = record, primary = primary, secondary = secondary }
end

local function eligible(player)
	if settings().ENABLED == false or not dataOf(player) or (OPX.Life and OPX.Life.Down(player)) then return false end
	local position = Open77.players.position(player)
	if type(position) ~= 'table' then return false end
	local clinic = M.Model.ChairAt(M.S, position.x, position.y, position.z,
		math.tointeger(position.bucket) or 0, OPX.Spots.ServerReach(0))
	if not clinic then return false end
	local api = Open77.cyberware
	local current = type(api) == 'table' and type(api.current) == 'function' and api.current(player) or nil
	return type(current) == 'table' and type(current.arms) == 'table' and current.arms.profile == 'gorilla_arms'
end

local function restore(player)
	local api = character()
	if not api or not dataOf(player) then return end
	local read, saved = pcall(api.GetMetadata, player, KEY)
	if not read then return end
	TriggerClientEvent(M.Event.STYLE_RESTORE, player, M.ValidateStyle(saved) or false)
end

local start, stop = M.Start, M.Stop
function M.Start()
	start()
	RegisterNetEvent(M.Event.STYLE, function(value)
		local player = math.tointeger(tonumber(source))
		if not player or player <= 0 then return end
		local now = OPX.Now()
		if now - (last[player] or -math.huge) < 1000 then return end
		last[player] = now
		if value == 'restore' then restore(player); return end
		if not eligible(player) then OPX.NotifyLocale(player, 'ripperdoc.style.unavailable', nil, 'error'); return end
		if value == nil then
			TriggerClientEvent(M.Event.STYLE_DATA, player, { records = settings().RECORDS or {}, family = 'strongarms' })
			return
		end
		local style = M.ValidateStyle(value)
		if not style then OPX.NotifyLocale(player, 'ripperdoc.style.invalid', nil, 'error'); return end
		serial = serial + 1
		local token = tostring(serial)
		pending[player] = { token = token, data = dataOf(player), style = style, expires = now + 15000 }
		TriggerClientEvent(M.Event.STYLE_APPLY, player, token, style)
	end)
	RegisterNetEvent(M.Event.STYLE_RESULT, function(token, accepted)
		local player = math.tointeger(tonumber(source))
		local entry = player and pending[player]
		if not entry or token ~= entry.token then return end
		pending[player] = nil
		if accepted ~= true or entry.expires < OPX.Now() or entry.data ~= dataOf(player) or not eligible(player) then
			restore(player)
			return
		end
		local saved = character().SetMetadata(player, KEY, entry.style)
		if saved ~= true then restore(player); return end
		OPX.NotifyLocale(player, 'ripperdoc.style.saved', nil, 'success')
	end)
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'loaded'), function(player)
		pending[tonumber(player)], last[tonumber(player)] = nil, nil
		restore(tonumber(player))
	end)
	AddEventHandler(M.Event.ON_OPERATED, function(player, outcome)
		if type(outcome) ~= 'table' or not outcome.applied then return end
		local chrome = M.S.chrome[outcome.chrome]
		if not chrome or chrome.slot ~= 'arms' then return end
		if outcome.action == 'remove' then TriggerClientEvent(M.Event.STYLE_RESTORE, player, false)
		else restore(player) end
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(player)
		pending[tonumber(player)], last[tonumber(player)] = nil, nil
	end)
end
function M.Stop()
	pending, last = {}, {}
	stop()
end
