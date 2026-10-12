--- The native link: the definitions, the identity bind, and whether any of it works.
-- @author dop42
--
-- THE GAP THIS FILE CLOSES. `Open77.cyberware.current/install/remove` work on a
-- player the platform has BOUND to a durable character. `open77_appearance`
-- binds when it runs; this resource's own `appearance` module stands aside from
-- it and binds nothing. So with the platform package stopped, nobody binds and
-- every native call answers nil. `bind` is exclusive per resource, which is why
-- this adapter binds ONLY when `open77_appearance` is not running -- checked on
-- every character load, not once -- and releases exactly what it bound.
--
-- The key is the character's citizen id, read off the server's own roster on
-- the INTERNAL `character:loaded` event, never anything a client sent.
--
-- DEGRADED IS A MODE, NOT A FAILURE. No `Open77.cyberware` table, a refused
-- definition, a missing permission: the affected chrome is installed as
-- roleplay metadata (NATIVE.FALLBACK_RP) and the boot log says so once.

local M = OPX.Modules.Get('ripperdoc')

M.Native = {}
local Native = M.Native

local Model = M.Model

-- chrome key -> true when its definition was accepted this boot.
local defined = {}
-- player -> citizen id this adapter bound.
local bound = {}
-- reasons already logged, so a refused bind is one line and not one per login.
local said = {}

local function api()
	local cyberware = Open77.cyberware
	if type(cyberware) ~= 'table' or type(cyberware.install) ~= 'function'
		or type(cyberware.current) ~= 'function' then
		return nil
	end
	return cyberware
end
Native.Api = api

local function once(key, line)
	if said[key] then return end
	said[key] = true
	Open77.log.warn('[ripperdoc] ' .. line)
end

--- Whether a chrome's definition is live, so an install can go native.
-- @author dop42
function Native.Defined(chromeKey)
	return defined[chromeKey] == true and api() ~= nil
end

--- Whether this adapter should hold the identity binding right now.
-- @author dop42
function Native.ShouldBind(S)
	if not S.native.bind or api() == nil or type(Open77.cyberware.bind) ~= 'function' then return false end
	local read, state = pcall(GetResourceState, M.OFFICIAL_IDENTITY)
	return not (read and state == 'running')
end

--- Binds one loaded player to their character, when this adapter should.
-- @author dop42
function Native.Bind(S, player, citizenId)
	if bound[player] == citizenId then return true end
	if type(citizenId) ~= 'string' or citizenId == '' or not Native.ShouldBind(S) then return false end
	local called, result, reason = pcall(Open77.cyberware.bind, player, citizenId)
	if not called or type(result) ~= 'table' then
		once('bind:' .. tostring(called and reason or result),
			('the cyberware identity bind was refused (%s): native chrome stays roleplay-only for those players')
				:format(tostring(called and reason or result)))
		return false
	end
	bound[player] = citizenId
	return true
end

--- Releases one player this adapter bound.
-- @author dop42
function Native.Unbind(player)
	if bound[player] == nil then return end
	bound[player] = nil
	local cyberware = api()
	if cyberware ~= nil and type(cyberware.unbind) == 'function' then pcall(cyberware.unbind, player) end
end

--- Whether this adapter holds a player's binding.
-- @author dop42
function Native.Bound(player)
	return bound[player]
end

--- Registers every native chrome's definition. Says once what is degraded.
-- @author dop42
function Native.Define(S)
	defined = {}
	local cyberware = api()
	local natives = 0
	for _, chrome in ipairs(S.chromeList) do
		if chrome.kind == 'native' then natives = natives + 1 end
	end
	if natives == 0 then return 0 end
	if cyberware == nil or type(cyberware.define) ~= 'function' then
		Open77.log.warn(('[ripperdoc] no native cyberware on this host: %d native chrome run roleplay-only ' ..
			'(metadata, no Gorilla punch, no double jump)'):format(natives))
		return 0
	end
	local live = 0
	for _, chrome in ipairs(S.chromeList) do
		if chrome.kind == 'native' then
			local called, result, reason = pcall(cyberware.define, Model.Definition(chrome))
			if called and type(result) == 'table' then
				defined[chrome.key] = true
				live = live + 1
			else
				Open77.log.warn(('[ripperdoc] the native definition of %s was refused (%s): it runs roleplay-only')
					:format(chrome.key, tostring(called and reason or result)))
			end
		end
	end
	Open77.log.info(('[ripperdoc] native cyberware: %d of %d definitions live; identity bind by %s')
		:format(live, natives, Native.ShouldBind(S) and 'this resource' or M.OFFICIAL_IDENTITY))
	return live
end

--- Wires the bind to the character lifecycle and binds who is already in.
-- @author dop42
function Native.Start(S, character)
	bound, said = {}, {}
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'loaded'), function(source, data)
		local player = math.tointeger(tonumber(source))
		if player == nil or type(data) ~= 'table' then return end
		Native.Unbind(player)
		Native.Bind(S, player, data.citizenId)
	end)
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'unloaded'), function(source)
		local player = math.tointeger(tonumber(source))
		if player ~= nil then Native.Unbind(player) end
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = math.tointeger(tonumber(playerId))
		if player ~= nil then bound[player] = nil end
	end)
	if character ~= nil and type(character.GetPlayers) == 'function' then
		local read, players = pcall(character.GetPlayers)
		-- `GetPlayers` answers the loaded Player objects, not ids.
		for _, loaded in ipairs(read and type(players) == 'table' and players or {}) do
			local data = type(loaded) == 'table' and loaded.PlayerData or nil
			local player = type(data) == 'table' and math.tointeger(tonumber(data.source)) or nil
			if player ~= nil then Native.Bind(S, player, data.citizenId) end
		end
	end
end

--- Releases every binding this adapter holds.
-- @author dop42
function Native.Stop()
	local players = {}
	for player in pairs(bound) do players[#players + 1] = player end
	for _, player in ipairs(players) do Native.Unbind(player) end
	defined = {}
end
