--- The server half: it relays what a player says, and answers the box's one
--- question with the commands that player may be shown.
-- @author dop42

local M = OPX.Modules.Get('chat')

-- When each player last spoke, for the floor between two messages.
local lastSaidMs

-- The last good clock reading, kept when the clock cannot be read.
local lastMs = 0

--- Milliseconds on the monotonic clock, never a reading that is not finite.
-- Differs from `OPX.Now` in rejecting a non-finite reading and answering the
-- last good one instead: `lastSaidMs` is compared against this clock, so a NaN
-- would make `at - previous` fail every comparison and drop every message from
-- everyone who had already spoken, in silence, until the process ended.
local function nowMs()
	local read, ms = pcall(OPX.Now)
	if read and OPX.Math.IsFinite(ms) and ms >= 0 then lastMs = math.floor(ms) end
	return lastMs
end

-- Longest author a line may carry; a player's own name is bounded the same way
-- by the character module. Declared up here because a player's line uses it
-- too: it was declared below that, so a player's name was cut at the message
-- length (240) instead.
local MAX_AUTHOR = 64

-- The three settings every line reads, resolved once in Init from the config.
--
-- READ BOUNDED, WITH A DEFAULT. They were read raw on every line, so a config
-- block missing MAX_LENGTH raised on every message (`maximum * 4` on nil) and
-- one missing RATE_MS raised comparing against nil: the chat went silent for
-- everybody, with a stack trace per line as the only clue. `MAX_LENGTH = 0`
-- turned every message into "...".
local tuning = {}

local function bounded(value, low, high, default)
	local number = OPX.Math.Finite(value)
	if number == nil or number < low or number > high then return default end
	return math.floor(number)
end

--- Cleans display text to MAX_LENGTH characters, never nil.
local function clean(value)
	return OPX.Text.Clean(value, tuning.maxLength, '...') or ''
end

--- Whether a connection may put a line in front of everybody: a loaded
--- character, or a staff grant.
local function mayBroadcast(player)
	local character = OPX.Api.Get('character')
	if character == nil or type(character.GetPlayer) ~= 'function' then return true end
	if character.GetPlayer(player) ~= nil then return true end
	local right = tuning.staffPermission
	local read, allowed = pcall(function() return Open77.acl.isAllowed(player, right) end)
	return read and allowed == true
end

--- Relays a player's message to everyone, attributed to its connection.
local function onSaid(text)
	local player = tonumber(source) or 0
	if player <= 0 then return end

	-- The floor is checked before the text is touched: a burst must not buy
	-- itself a walk of the message per packet. It moves for a REFUSED message
	-- too -- recording it only after the blank test let a burst of spaces never
	-- advance it, and pay for a bounded walk every time.
	local at = nowMs()
	local previous = lastSaidMs[player]
	if previous ~= nil and at - previous < tuning.rateMs then
		-- SAID, ONCE A BURST. The box has already closed and cleared on the
		-- client, so a second line typed quickly simply never appeared for
		-- anyone. The toast is cooled itself: a flood earns one, not one each.
		if not OPX.Cooling(player, 'chat:tooFast', 2000) then OPX.Refuse(player, 'chat.tooFast') end
		return
	end
	lastSaidMs[player] = at

	-- A CONNECTION WITH NO CHARACTER DOES NOT SPEAK TO THE SERVER, the owner's
	-- ruling (2026-10, after the hostile-net-events audit). This line goes to
	-- every client, and it went out for any slot the host had admitted: one on
	-- the character screen, or one whose entry failed and left it behind the
	-- gate. Staff (`STAFF_PERMISSION`) still may -- they are the people a player
	-- stuck on that screen needs to reach -- and the console never comes through
	-- here at all: it speaks through the `chat` contract. With no character
	-- contract there is nobody to ask, and the chat keeps working.
	if not mayBroadcast(player) then
		if not OPX.Cooling(player, 'chat:notLoaded', 2000) then
			OPX.Refuse(player, 'chat.notLoaded')
		end
		return
	end

	local said = clean(text)
	if said:match('^%s*$') then return end

	-- `source` is the authenticated connection: a client cannot speak for
	-- another.
	--
	-- NEVER A NAME TO A STRANGER, the owner's decision (#91). This line goes to
	-- EVERY client on the server, and it was signed with the character's name --
	-- and before that with the account's gamertag, and with the first eight
	-- characters of the durable account id when neither was known. Each told the
	-- whole city something only people who have met the speaker should know. The
	-- line is signed with the server id instead: what a report to staff needs,
	-- the same `#12` the give list shows, and nothing a stranger can put a name to.
	TriggerClientEvent(M.Event.MESSAGE, -1, {
		kind = 'chat',
		author = OPX.Text.Clean(locale('chat.author.player', { id = player }), MAX_AUTHOR, '...') or '',
		text = said,
	})
end

--- Answers the box with every command this player may be shown.
-- Anyone can raise this name and the answer is kilobytes, so it keeps its own
-- cooldown rather than sharing one with anything else.
local function onReady()
	local player = tonumber(source) or 0
	if player <= 0 then return end
	if OPX.Cooling(player, 'chat.ready', tuning.readyMs) then return end

	-- Core owns the list, and with it the rule that a restricted command is only
	-- offered to a player the ACL would let run it.
	local list = OPX.Command.Suggestions(player)
	TriggerClientEvent(M.Event.SUGGESTIONS, player, { suggestions = list })

	-- Said out loud because the alternative is guessing. An empty completion list
	-- has two very different causes -- the server had nothing to offer, or the
	-- page never received what it sent -- and they are indistinguishable from the
	-- player's side. This line tells them apart from the journal.
	Open77.log.debug(('[chat] %d completion(s) sent to player %d')
		:format(type(list) == 'table' and #list or -1, player))
end

--- Forgets an admitted player's message floor when they leave.
-- `source` is not set on a broadcast the host raises, so the id comes from the
-- argument; one that will not convert is a log line rather than a ghost key.
local function departed(rawPlayerId)
	local player = tonumber(rawPlayerId)
	if player == nil then
		Open77.log.warn(('[chat] unusable player id %q on disconnect'):format(tostring(rawPlayerId)))
		return
	end
	lastSaidMs[player] = nil
end

--- Warns about a resource that also draws a box and answers the same names.
local function warnAboutDuplicates()
	for _, name in ipairs({ 'opx77_chat', 'open77_chat' }) do
		local read, state = pcall(GetResourceState, name)
		state = read and tostring(state or ''):lower() or ''
		if state == 'running' or state == 'starting' then
			Open77.log.warn(('%s is running and is a package this module replaces'):format(name))
			Open77.log.warn('  both draw a chat box, both answer chat:addMessage and both take')
			Open77.log.warn('  focus on the open key, so every message is rendered twice. Drop one')
			Open77.log.warn('  from resources.load in server.jsonc.')
		end
	end
end

-- ── the server's own voice ───────────────────────────────────────────────────

-- The line kinds the log draws a style for, from `ChatLog.vue`. Anything else
-- would arrive as a class the stylesheet has no rule for and read like a player.
local LINE_KINDS = { chat = true, system = true, info = true, warning = true, error = true }


-- Largest radius a broadcast may name, in metres. A bigger one is "everybody",
-- which is what leaving `radius` out already says.
local MAX_RADIUS = 10000

--- A caller's message as the line the box draws, or nil and the reason.
local function lineOf(message)
	if type(message) == 'string' then message = { text = message } end
	if type(message) ~= 'table' then return nil, 'chat.invalidMessage' end
	if type(message.text) ~= 'string' then return nil, 'chat.invalidMessage' end
	local text = clean(message.text)
	if text:match('^%s*$') then return nil, 'chat.invalidMessage' end
	local kind = message.kind == nil and 'system' or message.kind
	if type(kind) ~= 'string' or not LINE_KINDS[kind] then return nil, 'chat.invalidKind' end
	local author = nil
	if message.author ~= nil then
		if type(message.author) ~= 'string' then return nil, 'chat.invalidMessage' end
		author = OPX.Text.Clean(message.author, MAX_AUTHOR, '...')
	end
	return { kind = kind, author = author, text = text }
end

--- A player id that names an authenticated connection, or nil.
-- Checked BEFORE the position reader is reached: the devkit card for
-- `Open77.players.position` says a 0 or a negative id throws past any pcall and
-- stops the resource, so a caller's bad number must never get that far.
local function connected(value)
	local id = math.tointeger(tonumber(value))
	if id == nil or id < 1 or id > 2147483647 then return nil end
	if OPX.UserIdOf(id) == nil then return nil end
	return id
end

--- Puts one line in one player's chat box.
-- @author dop42
--
-- THE SERVER SPEAKING, not a player: the line is attributed to whatever
-- `author` the caller names, or to nobody, and it bypasses the per-player
-- floor because no player sent it. Text is cleaned and bounded exactly as a
-- player's own is.
-- @param target integer a connected player id
-- @param message string|table text, or `{ text, author?, kind? }`
-- @return Result
function M.Send(target, message)
	local id = connected(target)
	if id == nil then return OPX.Result.Err('chat.noPlayer', tostring(target)) end
	local line, why = lineOf(message)
	if line == nil then return OPX.Result.Err(why) end
	TriggerClientEvent(M.Event.MESSAGE, id, line)
	return OPX.Result.Ok(true)
end

--- Puts one line in the chat box of everybody, or of everybody near something.
-- @author dop42
--
-- `bucket` limits it to one routing bucket; `radius` (metres) with `origin` --
-- a player id or `{ x, y, z }` -- to everybody that close to it, and in the
-- origin's bucket when it is a player. Distance is measured on the server's own
-- positions, never on anything a client said.
-- @param message string|table
-- @param options table|nil bucket, radius, origin
-- @return Result integer how many players were sent the line
function M.Broadcast(message, options)
	local line, why = lineOf(message)
	if line == nil then return OPX.Result.Err(why) end
	options = type(options) == 'table' and options or {}

	local bucket = nil
	if options.bucket ~= nil then
		bucket = math.tointeger(tonumber(options.bucket))
		if bucket == nil or bucket < 0 then return OPX.Result.Err('chat.invalidScope', 'bucket') end
	end

	local radius, origin = nil, nil
	if options.radius ~= nil then
		radius = tonumber(options.radius)
		if not OPX.Math.IsFinite(radius) or radius <= 0 or radius > MAX_RADIUS then
			return OPX.Result.Err('chat.invalidScope', 'radius')
		end
		if type(options.origin) == 'table' then
			local x, y, z = tonumber(options.origin.x), tonumber(options.origin.y),
				tonumber(options.origin.z)
			if not (OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)) then
				return OPX.Result.Err('chat.invalidScope', 'origin')
			end
			origin = { x = x, y = y, z = z }
		else
			local id = connected(options.origin)
			local at = id and Open77.players.position(id) or nil
			if type(at) ~= 'table' then return OPX.Result.Err('chat.invalidScope', 'origin') end
			origin = { x = at.x, y = at.y, z = at.z }
			if bucket == nil then bucket = math.tointeger(tonumber(at.bucket)) end
		end
	end

	if bucket == nil and radius == nil then
		TriggerClientEvent(M.Event.MESSAGE, -1, line)
		return OPX.Result.Ok(#(Open77.players.all() or {}))
	end

	local sent = 0
	for _, id in ipairs(Open77.players.all() or {}) do
		local at = (math.tointeger(id) or 0) >= 1 and Open77.players.position(id) or nil
		local inBucket = bucket == nil or (at ~= nil and math.tointeger(tonumber(at.bucket)) == bucket)
		local inRange = radius == nil or (at ~= nil and OPX.Math.IsFinite(tonumber(at.x))
			and ((at.x - origin.x) ^ 2 + (at.y - origin.y) ^ 2 + (at.z - origin.z) ^ 2) <= radius * radius)
		if at ~= nil and inBucket and inRange then
			TriggerClientEvent(M.Event.MESSAGE, id, line)
			sent = sent + 1
		end
	end
	return OPX.Result.Ok(sent)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state. Never yields.
-- @author dop42
function M.Init()
	lastSaidMs = {}
	local settings = type(OPX.Config.MODULES.chat) == 'table' and OPX.Config.MODULES.chat or {}
	tuning = {
		maxLength = bounded(settings.MAX_LENGTH, 1, 2000, 240),
		rateMs = bounded(settings.RATE_MS, 0, 60000, 800),
		readyMs = bounded(settings.READY_MS, 0, 600000, 5000),
		staffPermission = type(settings.STAFF_PERMISSION) == 'string'
			and settings.STAFF_PERMISSION ~= '' and settings.STAFF_PERMISSION or 'command.opx.admin',
	}
end

--- Publishes the server's voice: one line to one player, or to many.
-- @author dop42
function M.Api()
	OPX.Api.Provide('chat', 1, {
		Send = M.Send,
		Broadcast = M.Broadcast,
	})
end

--- Wires the two doors.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.SAY, onSaid)
	RegisterNetEvent(M.Event.READY, onReady)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)

	-- On a thread, not inline: a resource that starts after this one has not
	-- been launched yet at the moment this runs.
	CreateThread(warnAboutDuplicates)
end
