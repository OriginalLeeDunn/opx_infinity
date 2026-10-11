--- Telling a player something, and refusing them politely.
-- @author dop42
--
-- These are runtime services rather than anything a module owns: a refusal code
-- has to be renderable by whatever draws it, and a cooldown has to be shared
-- between every door into the same operation.

local ANSWER_DEDUPE_MS = 2000
local MAX_TEXTS = 32

local NOTIFY = OPX.Event(OPX.Channel.NET, 'runtime', 'notify')
local TOAST = OPX.Event(OPX.Channel.NET, 'runtime', 'toast')
local ANSWER = OPX.Event(OPX.Channel.NET, 'runtime', 'commandAnswer')

-- A command's read-back answer -- a list, a dump, a block of configuration -- for
-- whatever draws a chat log. It is on the runtime channel rather than a chat one
-- because core must not name a module: anything may listen, and if nothing does
-- the answer is simply not drawn.
local RESULT = OPX.Event(OPX.Channel.NET, 'runtime', 'commandResult')

local lastAnswer = {}
local cooldowns = {}

-- How long a message may be, and how long it may stay. The page wraps a long
-- message rather than cutting it, so the bound is about the wire and the screen,
-- not a layout: 384 bytes is three toast lines, and a toast that stays longer than
-- half a minute is a panel, not a notice.
local MAX_MESSAGE_BYTES = 384
local DEFAULT_MS = 5000
local MIN_MS, MAX_MS = 1000, 30000
local KINDS = { info = true, success = true, warning = true, error = true }

--- Whether this exact text just went to this player.
local function repeated(source, text)
	local bucket = lastAnswer[source]
	if not bucket then
		bucket = {}
		lastAnswer[source] = bucket
	end

	local now = OPX.Now()
	if bucket[text] and now - bucket[text] < ANSWER_DEDUPE_MS then return true end
	return false, bucket
end

--- Records that this text has gone out, so an exact repeat is swallowed.
--- SEPARATE FROM THE TEST ABOVE, and it was the same call. `repeated` wrote
--- `bucket[text] = now` BEFORE the send, so a toast the host dropped was recorded
--- as delivered and the identical retry -- which is the one a caller makes when
--- it learns the send failed -- was swallowed for the whole window.
local function remember(bucket, text)
	local now = OPX.Now()

	-- Bounded, or a client that provokes a new text every message grows this for
	-- the whole session. Closed windows go first; only if that frees nothing does
	-- the oldest open one go, because clearing the table wholesale would let an
	-- identical toast through before its window had passed.
	local count = OPX.Table.Count(bucket)
	if count >= MAX_TEXTS then
		local oldestKey, oldestAt
		for key, at in pairs(bucket) do
			if now - at >= ANSWER_DEDUPE_MS then
				bucket[key] = nil
				count = count - 1
			elseif oldestAt == nil or at < oldestAt then
				oldestKey, oldestAt = key, at
			end
		end
		if count >= MAX_TEXTS then bucket[oldestKey] = nil end
	end

	bucket[text] = now
end

--- Sends a toast to one player, drawn by OUR overlay. An exact repeat inside the
--- dedupe window is swallowed; two different toasts are two things the player
--- has to learn, so only an exact repeat counts.
---
--- IT USED TO GO TO THE PLATFORM. This handed every server toast -- 47 call
--- sites, every `NotifyLocale` a garage, a key, a dealership or a refusal makes --
--- to the `open77_notifications` package, which draws its own box in its own
--- corner in its own style. So a server running this resource showed two kinds of
--- notification side by side: ours, from anything raised on the client, and the
--- platform's, from anything raised here, and neither the theme nor the minimal
--- style reached the second. It now travels on the runtime's own channel to
--- `core/client/notify.lua`, which raises it through `OPX.Toast.Show` exactly as
--- a client-side toast is raised.
---
--- NO ICON, still. A glyph is a name from a closed set the client validates;
--- the two paths that carry one are `OPX.Refuse` and `OPX.CommandNotice`.
-- @author dop42
-- @param source Source
-- @param message string
-- @param kind string|nil info, success, warning or error
-- @param durationMs integer|nil
-- @return boolean whether it was sent
-- @return string|nil why it was not, or 'duplicate' for one swallowed here
function OPX.Notify(source, message, kind, durationMs)
	source = tonumber(source)
	if not source or source <= 0 then return false, 'invalid_source' end
	if type(message) ~= 'string' or message == '' then return false, 'invalid_message' end

	local text = ('%s:%s'):format(tostring(kind), message)
	local again, bucket = repeated(source, text)
	if again then return false, 'duplicate' end

	local duration = tonumber(durationMs)
	if duration == nil or not OPX.Math.IsFinite(duration) then duration = DEFAULT_MS end

	TriggerClientEvent(TOAST, source, {
		kind = KINDS[kind] and kind or 'info',
		message = OPX.Text.Bytes(message, MAX_MESSAGE_BYTES),
		durationMs = math.floor(OPX.Math.Clamp(duration, MIN_MS, MAX_MS)),
	})

	remember(bucket, text)
	return true
end

--- Guarantees a code a player is shown exists in the catalogue. Storage answers
--- `query-failed`, a validator answers `too-short`: those are for the log, not
--- for a player, and they become `error.unavailable` with the real code logged.
-- @author dop42
-- @param code any
-- @return string
--- The params a refusal may carry: plain strings and numbers under plain keys,
--- bounded, so a refusal still carries no internals by accident -- a table, a
--- function or a 4 KB exception string is dropped rather than shown.
-- @author dop42
-- @param params any
-- @return table|nil
local function refusalParams(params)
	if type(params) ~= 'table' then return nil end
	local out, kept = {}, 0
	for key, value in pairs(params) do
		if type(key) == 'string' and key:match('^[%w_]+$') and kept < 8 then
			if type(value) == 'number' and value == value then
				out[key], kept = value, kept + 1
			elseif type(value) == 'string' then
				out[key], kept = OPX.Text.Bytes(value, 64), kept + 1
			end
		end
	end
	return kept > 0 and out or nil
end

function OPX.RefusalKey(code)
	if type(code) == 'string' and OPX.Locale.Exists(code) then return code end
	Open77.log.warn(('[answer] %q has no catalogue entry; answering error.unavailable')
		:format(tostring(code)))
	return 'error.unavailable'
end

--- Sends a toast rendered from a locale key.
-- @author dop42
-- @param source Source
-- @param key string
-- @param params table|nil
-- @param kind string|nil
-- @return boolean whether the host took it
-- @return string|nil why it did not
function OPX.NotifyLocale(source, key, params, kind)
	-- An error or a warning takes the kind its situation calls for (too fast and
	-- busy warn, too far and not allowed are errors): see `OPX.Result.Kind`.
	if kind == 'error' or kind == 'warning' then kind = OPX.Result.Kind(key, kind) end
	-- Relayed rather than swallowed: this is the door 45 of the 47 call sites use,
	-- so dropping the answer here would put the read back where it was.
	return OPX.Notify(source, locale(OPX.RefusalKey(key), params), kind)
end

-- What a dump may be, and what a single-line toast may be.
--
-- THE TWO DOORS ARE NOT THE SAME DOOR. `CommandResult` answers a command that
-- asked to READ something back -- a stock list, a dealer list, a block of
-- configuration -- so its newlines are the answer and stripping them would
-- destroy it; it gets a ceiling and nothing else. `CommandNotice` is one line
-- in a toast, where a newline is somebody else's forged line.
--
-- Neither had anything at all. `OPX.Refuse` carries no internals -- its code
-- goes through `RefusalKey`, so only catalogue keys reach a player -- but these
-- two carry a STRING the caller chose, and the hardening pass that made
-- refusals stop carrying internals touched four modules and neither of these.
-- Six live call sites still send `tostring(saved.detail)`, which is
-- `lib/server/storage.lua`'s `query-failed`: the raw MySQL exception with its
-- table and column names, or a Lua error with an absolute path. The recipient
-- has passed an ACL, but they are a client and none of that is theirs.
--
-- The ceiling and the strip are what the door owes. Naming a catalogue key
-- instead of an exception is what those six call sites owe, and every one of
-- them already logs the detail where it belongs.
local MAX_COMMAND_DUMP = 8192
local MAX_COMMAND_LINE = 240

--- Bounds a multi-line dump without touching what makes it readable.
---
--- CUT ON A CHARACTER BOUNDARY, AND SAID OUT LOUD. The first version of this
--- cut on a raw byte, so a stock list carrying an accented vehicle name could be
--- severed mid-sequence and handed to CEF as invalid UTF-8 -- while `lineText`
--- beside it went through `OPX.Audit.Safe`, which looks for a boundary. And it
--- cut in silence: a dealer list past the ceiling simply ended, with an ellipsis
--- and no reason anywhere. The operator asking for the list is exactly the
--- person who needs to know it was not all of it.
local function dumpText(message)
	local text = tostring(message or '')
	if #text <= MAX_COMMAND_DUMP then return text end

	-- `OPX.Text.Bytes` is the boundary-safe byte cut; this was a second copy of
	-- its loop.
	local kept = OPX.Text.Bytes(text, MAX_COMMAND_DUMP)

	Open77.log.warn(('[answer] a command answer of %d bytes was cut to %d')
		:format(#text, #kept))
	return kept .. '...'
end

--- Bounds and strips a single line on its way into a toast.
local function lineText(message)
	local text = tostring(message or '')
	if type(OPX.Audit) == 'table' and type(OPX.Audit.Safe) == 'function' then
		return OPX.Audit.Safe(text, MAX_COMMAND_LINE)
	end
	return (text:sub(1, MAX_COMMAND_LINE):gsub('[%c]', ' '))
end

--- Answers a command that asked to read something back -- a list, a dump, a
--- block of configuration. Source nil or 0 is the console, which reads a print.
-- @author dop42
-- @param source Source|nil
-- @param accepted boolean
-- @param message string
function OPX.CommandResult(source, accepted, message)
	-- NORMALISED LIKE EVERY OTHER SOURCE IN THIS FILE, and it was not. Four
	-- functions here open with `source = tonumber(source)` and this one went
	-- straight to the comparison, so a source arriving as a string -- which is
	-- how a console and some host paths hand it over -- raised `attempt to
	-- compare string with number` instead of printing to the console.
	source = tonumber(source)
	if source and source > 0 then
		-- `kind`, the field every chat line carries and the one `ChatLog.vue`
		-- styles a line by. This sent `type`, which the page never read, so a
		-- refused read-back defaulted to `say` and drew like something a player
		-- had said instead of in the error colour.
		TriggerClientEvent(RESULT, source, {
			kind = accepted and 'info' or 'error',
			author = OPX.Config.SHARED.SERVER_NAME,
			text = dumpText(message),
		})
	else
		print(message)
	end
end

--- Answers what a command *did*, as a toast the client half raises. `toasted`
--- means the action already raised the same toast itself, so a client that can
--- draw toasts shows one rather than two.
-- @author dop42
-- @param source Source|nil
-- @param raw string|nil
-- @param kind string success, warning or error
-- @param message string
-- @param toasted boolean|nil
-- @param icon string|nil a glyph name from `OPX.Toast.ICONS`
function OPX.CommandNotice(source, raw, kind, message, toasted, icon)
	-- Normalised for the same reason as `CommandResult` above.
	source = tonumber(source)
	if source and source > 0 then
		-- `icon` is a trailing argument: every caller that predates it sends five
		-- and the client half reads a nil sixth.
		--
		-- THE NAME IS CHECKED HERE NOW. It used to be type-checked only, because
		-- the closed set lived on the client and core could not reach into a
		-- module to borrow one -- true when it was written, and no longer: the
		-- set is `OPX.Glyphs`, in a shared script, so the server holds the same
		-- list the page draws from. Checking at the SENDING side is what names
		-- the culprit; the client still drops an unknown name and logs it rather
		-- than losing the sentence, because this is not the only door in.
		TriggerClientEvent(ANSWER, source, raw or '', kind, lineText(message),
			toasted == true,
			type(icon) == 'string' and OPX.Glyphs[icon] and icon or nil)
	else
		print(message)
	end
end

--- Whether an operation is cooling for this player, recording the attempt when
--- it is not. The window is per player AND per operation, never per door: the
--- same operation reached by a net event and by a command shares one window.
--- This is not a security boundary -- ownership checks are.
-- @author dop42
-- @param source Source
-- @param key string
-- @param everyMs integer
-- @return boolean
function OPX.Cooling(source, key, everyMs)
	source = tonumber(source)
	-- The console is never cooled.
	if not source or source <= 0 then return false end

	local now = OPX.Now()
	local bucket = cooldowns[source]
	if not bucket then
		bucket = {}
		cooldowns[source] = bucket
	end
	if bucket[key] and now - bucket[key] < everyMs then return true end
	bucket[key] = now
	return false
end

--- Drops a departing player's cooldowns and toast windows. A player id is
--- recycled, and a window left behind would refuse the next holder's first
--- action or swallow their first toast.
-- @author dop42
-- @param source Source
function OPX.ForgetCooldowns(source)
	source = tonumber(source) or -1
	cooldowns[source] = nil
	lastAnswer[source] = nil
end

--- Tells a client which request was refused and with what code, and nothing
--- else: a refusal that explains itself tells an attacker which half of their
--- guess was right. The operation is not optional -- without it a client waiting
--- on one of several requests cannot tell which `error.tooFast` is its own.
-- @author dop42
-- @param source Source
-- @param code string a locale key
-- @param operation string|nil
-- @param icon string|nil a glyph name from `OPX.Toast.ICONS`
-- @param params table|nil the sentence's `{placeholders}`: strings and numbers only
function OPX.Refuse(source, code, operation, icon, params)
	source = tonumber(source)
	if not source or source <= 0 then return end
	TriggerClientEvent(NOTIFY, source, {
		-- A refusal is an error, unless its situation is one the owner made a
		-- warning (too fast, busy): see `OPX.Result.Kind`.
		kind = OPX.Result.Kind(code, 'error'),
		code = OPX.RefusalKey(code),
		-- PARAMS, SO ONE DOOR IS ENOUGH. A refusal could not carry them, so a
		-- module whose sentence names something (`Every exit at {garage} is
		-- blocked`) followed this with `OPX.NotifyLocale` -- and the player read
		-- the sentence twice, once with the placeholder left in it.
		params = refusalParams(params),
		operation = type(operation) == 'string' and operation or 'unknown',
		-- A refusal is the one toast a player MUST read, so the glyph is the part
		-- of it that is allowed to go missing: the client validates the name
		-- against its closed set and drops one it cannot draw, and the words go up
		-- either way. Checked against `OPX.Glyphs` here too, as `CommandNotice`
		-- does: this said "type-checked only, for the reason `CommandNotice`
		-- gives", and that reason had been withdrawn there -- the set is a shared
		-- script and the server holds the same list the page draws from.
		icon = type(icon) == 'string' and OPX.Glyphs[icon] and icon or nil,
	})
end

-- Its own table, purged in its own file, the way `core/server/note.lua` already
-- does it. Every call to `OPX.ForgetCooldowns` on the departure path lived in
-- the character module, so a build without it -- or one where it failed to
-- start -- leaked both tables for the life of the process and left a spent
-- window that refuses the next holder of a recycled slot their first action.
-- Calling it twice costs nothing: it only clears.
AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(rawPlayerId)
	OPX.ForgetCooldowns(tonumber(rawPlayerId))
end)
