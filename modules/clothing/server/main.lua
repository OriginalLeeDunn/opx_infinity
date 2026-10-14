--- Server half: the stores, their buckets, and the three placement commands.
-- @author XEROX710
--
-- WHAT IS DECIDED HERE IS ONE THING: which stores a player may see. The client
-- draws markers from a list it is sent and asks for that list again on its own
-- cadence; this half filters it to the connection's own routing bucket and sends
-- it. Nothing is charged, created or destroyed, so there is no request to answer
-- and no verdict to publish -- the dressing happens in the fitting room, which
-- `appearance` owns.
--
-- NO CAPTURE ROUND-TRIP, unlike the garages. `add` needs a position and nothing
-- else, and a position is the one thing the server can read for itself
-- (`Open77.players.position`): the garages ask their own client back for a
-- HEADING because a chat line has no facing and a vehicle needs one. A store has
-- no facing -- so the ask, the answer, its deadline, the warning for an answer
-- that never came and the ACL check on the answer's own door are all machinery
-- this module does not have.
--
-- `character` is not required and not consulted. A store belongs to no
-- character: ownership is the fitting room's question, asked by the module that
-- owns the puppet.

local M = OPX.Modules.Get('clothing')
local Access = M.Access
local Store = M.Storage
local Result = OPX.Result

-- The stores from config and the ones read back from the database, merged into
-- `spots` on every change. `spots` is what is listed, filtered and sent.
local configSpots, captured = {}, {}
local spots = {}

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

local coordinate = Access.Coordinate

-- Cleans and caps a wire value before it reaches a log line.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

--- Reads a connection's position and bucket, or nil.
-- Z is part of the one read rather than a second one: a marker placed at no
-- height is a store under the world, and a store under the world is a marker
-- nobody can stand on.
-- @author XEROX710
-- @param source Source
-- @return table|nil x, y, z, bucket
local function pointOf(source)
	local position = Open77.players.position(source)
	if type(position) ~= 'table' then return nil end
	local x, y, z = coordinate(position.x), coordinate(position.y), coordinate(position.z)
	if x == nil or y == nil or z == nil then return nil end
	local bucket = Access.Integer(position.bucket)
	return { x = x, y = y, z = z, bucket = bucket or 0 }
end

--- Rebuilds the merged list. Called once at load and after every change.
local function rebuild()
	spots = {}
	for key, store in pairs(configSpots) do spots[key] = store end
	for key, store in pairs(captured) do spots[key] = store end
end

--- The stores of one bucket, ready for the wire.
local function payloadFor(bucket)
	local list = Access.InBucket(spots, bucket)
	local out = {}
	for index = 1, #list do out[index] = Access.Serialise(list[index]) end
	return out
end

--- Sends one player the stores of their own bucket.
local function sync(player)
	if type(player) ~= 'number' then return end
	local at = pointOf(player)
	if at == nil then return end
	TriggerClientEvent(M.Event.SYNC, player, { spots = payloadFor(at.bucket) })
end

--- Sends every connected player their own list. Guarded: a capture must not
--- fail because one connection could not be read.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(sync, tonumber(ids[index]))
		if not sent then
			Open77.log.warn('[clothing] sync failed: ' .. tostring(failure))
		end
	end
end

-- ── the commands ────────────────────────────────────────────────────────────

--- Registers one command from the config, or nothing when it is unnamed.
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

-- Prints every store: position, bucket, and whether it came from config or the
-- database.
local function report(source)
	local lines = {}
	local keys, capturedCount = {}, 0
	for key in pairs(spots) do keys[#keys + 1] = key end
	table.sort(keys)
	for index = 1, #keys do
		local store = spots[keys[index]]
		local fromDatabase = captured[store.key] ~= nil
		if fromDatabase then capturedCount = capturedCount + 1 end
		lines[#lines + 1] = ('%s %s pos=%.2f,%.2f,%.2f bucket=%d %s'):format(
			store.key, store.label, store.x, store.y, store.z, store.bucket,
			fromDatabase and 'captured' or 'config')
	end
	lines[#lines + 1] = ('%d store(s): %d from config, %d captured')
		:format(#keys, #keys - capturedCount, capturedCount)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- Saves one captured store, at the position this half read for itself.
-- Runs on a thread: the write yields. Nothing about the store comes off the
-- wire, so there is no claim to check and no field a client could have invented.
local function capture(player, key, label)
	local at = pointOf(player)
	if at == nil then
		return OPX.NotifyLocale(player, 'clothing.noPosition', nil, 'error')
	end

	local store, why = Access.FromDefinition(key, {
		LABEL = label, X = at.x, Y = at.y, Z = at.z, BUCKET = at.bucket,
	})
	if store == nil then
		-- Said in the node's log as well as to the player: a refusal only the
		-- player can see leaves whoever reads the log unable to tell a capture
		-- that was turned down from one that never arrived.
		Open77.log.warn(('[clothing] player %d capture of %s refused: %s')
			:format(player, safe(key), safe(why)))
		OPX.NotifyLocale(player, 'clothing.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, tostring(why))
	end

	local saved = Store.Upsert(store)
	if not saved.ok then
		Open77.log.warn(('[clothing] player %d could not save the capture of %s: %s')
			:format(player, safe(key), safe(saved.detail)))
		OPX.NotifyLocale(player, 'clothing.captureFailed', nil, 'error')
		return OPX.CommandResult(player, false, 'could not save; the reason is in the server log')
	end
	captured[key] = store
	rebuild()
	-- The operator first and directly: they are looking at the marker they just
	-- placed, and a fan-out that cannot read the roster would otherwise leave
	-- the one person who cares without it.
	sync(player)
	syncAll()
	Open77.log.info(('[clothing] %s captured at %.2f,%.2f,%.2f bucket=%d by %d')
		:format(key, store.x, store.y, store.z, store.bucket, player))
	OPX.CommandResult(player, true, ('%s saved; check it in to survive a database reset:\n  %s = ' ..
		'{ LABEL = %q, X = %.2f, Y = %.2f, Z = %.2f, BUCKET = %d },')
		:format(key, key, store.label, store.x, store.y, store.z, store.bucket))
end

--- Registers the capture and diagnostic commands.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.add, {
		restricted = true,
		help = 'clothing.help.add',
		params = {
			{ name = 'key', optional = true, help = locale('clothing.help.addKey') },
			{ name = 'label', optional = true, help = locale('clothing.help.addLabel') },
		},
	}, function(source, args)
		-- BOTH POSITIONALS ARE OPTIONAL, and the bare command is the shape the
		-- config file advertises: it captures a store where the operator stands,
		-- under a key it names back to them.
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key > Access.MAX_KEY then
			Open77.log.warn(('[clothing] player %d add refused: the key is %d characters, over %d')
				:format(source, #key, Access.MAX_KEY))
			return OPX.CommandResult(source, false,
				('usage: add [key] [label] -- a key is 1 to %d characters'):format(Access.MAX_KEY))
		end
		if #key == 0 then
			-- Named back in the answer: a store whose key the operator never
			-- learned could not be removed or checked in afterwards.
			local index = 0
			repeat index = index + 1 until spots['store' .. index] == nil
			key = 'store' .. index
		end
		local label = ''
		for index = 2, #args do
			label = label .. (index > 2 and ' ' or '') .. tostring(args[index])
		end
		label = OPX.Text.Clean(label, 64)

		CreateThread(function()
			capture(source, key, label)
		end)
	end)

	register(names.remove, {
		restricted = true,
		help = 'clothing.help.remove',
		params = { { name = 'key', help = locale('clothing.help.removeKey') } },
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or ''
		if #key == 0 then return OPX.CommandResult(source, false, 'usage: remove <key>') end
		if captured[key] == nil then
			return OPX.CommandResult(source, false, configSpots[key] ~= nil
				and 'that store comes from config; edit config/clothing.lua to remove it'
				or 'no captured store named ' .. key)
		end
		CreateThread(function()
			local gone = Store.Delete(key)
			if not gone.ok then
				return OPX.CommandResult(source, false, 'could not delete; the reason is in the server log')
			end
			captured[key] = nil
			rebuild()
			syncAll()
			Open77.log.info(('[clothing] %s removed by %d'):format(key, source))
			OPX.CommandResult(source, true, key .. ' removed.')
		end)
	end)

	register(names.list, { restricted = true, help = 'clothing.help.list' }, function(source)
		report(source)
	end)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state from config and contributes this module's table. Never yields.
-- @author XEROX710
function M.Init()
	configSpots = Access.SPOTS
	captured = {}
	rebuild()
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server half of the clothing contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('clothing', 1, {
		Spots = function() return spots end,
		State = function()
			local listed = {}
			for key, store in pairs(spots) do
				listed[key] = { label = store.label, bucket = store.bucket,
					captured = captured[key] ~= nil }
			end
			return Result.Ok({ stores = listed })
		end,
	})
end

--- Reads the captured stores back and wires the one door.
-- @author XEROX710
--
-- The commands are registered whatever the database answered: an operator has to
-- be able to read back what the configuration says, and `add` is how a database
-- that answered nothing gets filled.
function M.Start()
	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[clothing] config: ' .. line)
	end

	registerCommands()

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		-- A FLOOR, the garages one, and this was the one ask without it: each is a
		-- position read, a bucket filter, a serialise and a payload, and a client
		-- polls every POLL_MS (15 s). A loop on this event cost all four per
		-- packet.
		if OPX.Cooling(player, 'clothing.ask', 1000) then return end
		sync(player)
	end)

	-- THE KEY, AS A THING THE SERVER HAS AN OPINION ABOUT. It opened the room
	-- locally and told this half nothing, which was fine while the room was only
	-- a mirror: a fitting room opened from the wrong place was a cosmetic lie.
	-- It stopped being fine when the room acquired a save `appearance` will only
	-- write for a door the server opened, and `config/clothing.lua` already said
	-- what the answer had to be -- the distance measured HERE, the shape
	-- `modules/shops` uses in `shopAt`.
	--
	-- NOTHING IS SENT BACK and nothing is refused out loud. The client has
	-- already decided whether to put a room up and has already said so to the
	-- player; this only decides whether what comes out of that room may be
	-- stored, and a second refusal on the same key press would be two answers to
	-- one question. A player who is not at a store gets the room their own
	-- client chose to draw and cannot save a stitch of it.
	RegisterNetEvent(M.Event.OPEN, function()
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		-- The same floor the list is asked on: a key that can be held down is a
		-- key that can be a request per frame.
		if OPX.Cooling(player, 'clothing.open', 1000) then return end
		-- Nor from the floor: a downed player's client still sends the key, and
		-- the room it opens would be a save granted to somebody waiting for help.
		if OPX.Life.Down(player) then return end

		local point = pointOf(player)
		if point == nil then return end
		-- With the server's slack (`REACH_SLACK`): the room went up from where
		-- the client stood, and a save refused for a metre of latency is a save
		-- the player never hears was refused.
		local here = Access.Nearest(Access.InBucket(spots, point.bucket), point.x, point.y,
			OPX.Spots.ServerReachSq(Access.USE_RADIUS))
		if here == nil then
			Open77.log.debug(('[clothing] player %d asked for a store they are not standing on')
				:format(player))
			return
		end

		local appearance = OPX.Api.Get('appearance')
		if type(appearance) ~= 'table' or type(appearance.AllowClothingSave) ~= 'function' then
			-- Not an error. `appearance` is declared optional by this module, and a
			-- host running the platform's own package has no contract to tell.
			return
		end
		appearance.AllowClothingSave(player, 'clothing')
	end)

	CreateThread(function()
		local rows = Store.FetchAll()
		if not rows.ok then
			Open77.log.error('[clothing] captured stores could not be read: ' ..
				tostring(rows.detail))
			return
		end
		local loaded = type(rows.value) == 'table' and rows.value or {}
		local accepted, refused = 0, 0
		for index = 1, #loaded do
			local row = loaded[index]
			local store, why = Access.FromDefinition(row.spot_key, {
				LABEL = row.label, X = row.x, Y = row.y, Z = row.z, BUCKET = row.bucket,
			})
			if store == nil then
				refused = refused + 1
				Open77.log.warn('[clothing] captured row refused: ' .. tostring(why))
			else
				accepted = accepted + 1
				captured[store.key] = store
			end
		end
		rebuild()
		-- A player who connected while the database was being read asked too
		-- early and was told nothing; they ask again on their own cadence.
		syncAll()
		local fromConfig = OPX.Table.Count(configSpots)
		Open77.log.info(('[clothing] ready: %d config, %d captured, %d refused')
			:format(fromConfig, accepted, refused))
	end)
end
