--- Server half: the tunables, the inbound requests and the boot banner.
-- @author dop42

local M = OPX.Modules.Get('animations')
local Common = M.Common
local Opt = M.Opt
local Service = M.Service

-- Last hello per player, for the one-second floor: a hello costs a whole offer
-- on the wire.
local lastHelloMs = {}

-- Forgets a departing player's hello floor, rate windows and lock.
local function forget(playerId)
	lastHelloMs[tonumber(playerId) or 0] = nil
	Service.Forget(playerId)
	M.Duo.Forget(playerId)
end

-- Reports what this build offers, once the host has installed the API.
local function banner()
	local offered = Service.Wire()
	local variants = 0
	for index = 1, #offered do
		local row = offered[index]
		variants = variants + #(row.variants or row.clips)
	end
	local duo = M.Duo.Offered()
	Open77.log.info(('[animations] ready: %d animations (%d from the platform catalogue), %d ' ..
		'variants offered; with a nearby player: %d paired kinds, %d shortcuts, any two ' ..
		'profiles %s (%d ways in all); presenter %s'):format(#offered,
		M.Catalogue.AdoptedCount(), variants, #duo.kinds, #duo.pairs, duo.any and 'yes' or 'no',
		M.Duo.Count(), Opt.PRESENTER))
end

-- Reads the platform's catalogue, then sends the grown offer to every client
-- that already asked for the smaller one.
local function adopt()
	if not Service.Adopt() then return end
	for player in pairs(lastHelloMs) do Service.SendOffer(player) end
end

-- Warns when the platform package is also running. Checked on a thread and not
-- at load: a resource listed after this one is still `discovered` here.
local function warnAboutOfficial()
	local official = tostring(GetResourceState(M.OFFICIAL) or ''):lower()
	if official ~= 'running' and official ~= 'starting' then
		if Opt.PRESENTER == 'never' then
			Open77.log.warn(('[animations] PRESENTER is "never" and %s is not running: the service')
				:format(M.OFFICIAL))
			Open77.log.warn('  accepts animations and no client poses a body for them.')
		end
		return
	end
	if Opt.PRESENTER == 'always' then
		Open77.log.warn(('[animations] %s is running and PRESENTER is "always": both pose every')
			:format(M.OFFICIAL))
		Open77.log.warn("  body, restarting each other's clip. Set PRESENTER to \"auto\" or drop one")
		Open77.log.warn('  from resources.load in server.jsonc.')
	else
		Open77.log.info(('[animations] %s is running; its client poses the bodies and this')
			:format(M.OFFICIAL))
		Open77.log.info('  module only asks for animations (PRESENTER ' .. Opt.PRESENTER .. ')')
	end
end

--- Declares the operator numbers and reports what config got wrong.
-- @author dop42
function M.Init()
	lastHelloMs = {}

	OPX.Tune.Declare{
		ANIM_RATE_WINDOW_MS = { value = Opt.WINDOW_MS, type = 'integer', min = 250, max = 600000 },
		ANIM_RATE_REQUESTS = { value = Opt.REQUESTS, type = 'integer', min = 1, max = 1000 },
		ANIM_ONE_SHOT_MS = { value = Opt.ONE_SHOT_MS, type = 'integer',
			min = M.MIN_DURATION_MS, max = M.SERVICE_MAX_MS },
		ANIM_MAX_DURATION_MS = { value = Opt.MAX_DURATION_MS, type = 'integer',
			min = M.MIN_DURATION_MS, max = M.SERVICE_MAX_MS },
	}

	for index = 1, #M.Problems do
		Open77.log.warn('[animations] config: ' .. M.Problems[index])
	end
end

--- Wires the inbound requests, the commands and the banner.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.PLAY, function(requestId, name, variant, options)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		requestId = Common.Integer(requestId, 1, M.MAX_REQUEST_ID)
		if requestId == nil then return end
		Service.Answer(player, requestId, 'play', Service.Play(player, name, variant, options))
	end)

	RegisterNetEvent(M.Event.STOP, function(requestId, override)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		requestId = Common.Integer(requestId, 1, M.MAX_REQUEST_ID)
		if requestId == nil then return end
		Service.Answer(player, requestId, 'stop', Service.Stop(player, override == true))
	end)

	RegisterNetEvent(M.Event.HELLO, function()
		local player = tonumber(source) or 0
		if player <= 0 then return end
		local atMs = OPX.Now()
		if lastHelloMs[player] ~= nil and atMs - lastHelloMs[player] < 1000 then return end
		lastHelloMs[player] = atMs
		Service.SendOffer(player)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, forget)

	M.Duo.Start()
	M.Commands.Register()

	if not Service.Available() then
		Open77.log.error('[animations] Open77.animations.play/stop are unavailable (a build ' ..
			'without the animation service, or players.animations.control not granted); every ' ..
			'request is refused')
	end

	-- One-shot threads: the banner has to wait for the API to be installed, and
	-- the conflict check for the other resource to leave `discovered`.
	-- The platform's catalogue is read first, so the banner counts it.
	CreateThread(function()
		Wait(0)
		local adopted, failure = pcall(adopt)
		if not adopted then
			Open77.log.error('[animations] reading the platform catalogue raised: ' ..
				tostring(failure))
		end
		local reported, broken = pcall(banner)
		if not reported then Open77.log.error('[animations] banner failed: ' .. tostring(broken)) end
	end)

	CreateThread(function()
		Wait(0)
		local warned, failure = pcall(warnAboutOfficial)
		if not warned then
			Open77.log.error('[animations] the conflict check raised: ' .. tostring(failure))
		end
	end)
end

--- Forgets every player's windows.
-- @author dop42
function M.Stop()
	M.Duo.Stop()
	for playerId in pairs(lastHelloMs) do Service.Forget(playerId) end
	lastHelloMs = {}
end
