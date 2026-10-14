--- The player audit log, written as greppable platform log lines.
-- @author dop42
--
-- `Open77.log` says what the code does; this says what an operator will have to
-- account for later. The platform log is its only medium: every entry is one line
-- of the same shape, `[audit] event=... severity=... citizen=... user=...
-- player=... message="..." data=...`, so that a `grep` finds it again.
--
-- Everything here may have come from a client. A newline in client-chosen text
-- forges a whole log line, attributed to whatever resource the attacker names, so
-- every message and every data text is stripped of its control characters and
-- bounded. The cut falls between two characters rather than between two bytes:
-- cutting by bytes could split a multi-byte character and leave invalid UTF-8 in
-- the line.

OPX.Audit = {}
local Audit = OPX.Audit

-- The severities an entry may carry; anything else reads info.
local SEVERITIES = { debug = true, info = true, warn = true, error = true }

-- Longest message or data text one entry carries, in characters.
local MAX_MESSAGE = 200

-- Window in which repeated identical entries are collapsed, so that a client
-- looping on a refusal costs one line and a count instead of a screenful.
local DEDUPE_MS = 10000

-- How long a closed window is kept, so that the next entry can report its count.
local RETAIN_MS = DEDUPE_MS * 6

-- Recent entries by key, with their time, count and owner. The owner is stored
-- beside the key rather than parsed back out of it, because a key ends either
-- with the source or with the citizen id.
local recent = {}

-- Event prefixes whose info entries are never collapsed: six purchases in eight
-- seconds are six answers, and collapsing them would destroy the record. A
-- refusal under these prefixes is collapsed anyway, by its severity.
--
-- `export.` IS A LEDGER TOO. `core/server/exports.lua` writes one line per write
-- another resource makes -- money, items, a job -- and those entries carry no
-- player source, so they were all keyed on `-`: ten `AddItem` calls in ten
-- seconds, to ten different players, became one line and `[+9 suppressed]`.
-- That file promises "a write is audited with its caller", and the record of
-- what a third-party resource did is exactly the one an operator reads later.
local LEDGER_PREFIXES = { 'money.', 'character.', 'export.' }

-- The character-boundary cut is `OPX.Text.Span`, a shared script loaded before
-- this one. It was a private copy here, line for line the same loop, which is
-- one copy too many of the one routine whose job is not to split a character.
local span = OPX.Text.Span

--- Turns a value into text without control characters, truncated.
local function bounded(value, maximum)
	local text = tostring(value or '')
	-- CUT BEFORE THE SCAN, not after it. The strip ran over the WHOLE string and
	-- the truncation came second, so `Safe(x, 64)` over a megabyte walked a
	-- megabyte to keep 64 bytes. A generous head -- four bytes per character is
	-- the widest UTF-8 goes, plus room for `span` to find a boundary -- is more
	-- than any bound here needs and is all that is ever touched.
	local head = (maximum or MAX_MESSAGE) * 4 + 16
	if #text > head then text = text:sub(1, head) end
	text = text:gsub('[%c]', ' ')
	local cut = span(text, maximum)
	if cut < #text then text = text:sub(1, cut) .. '...' end
	return text
end

--- Truncates a value and strips its control characters for logging.
-- @author dop42
--
-- Published because any text a caller puts in a log line may have been chosen by
-- a client, and a newline in it forges a whole line.
-- @param value any
-- @param maximum integer|nil characters to keep, 64 by default
-- @return string
function OPX.Audit.Safe(value, maximum)
	return bounded(value, maximum or 64)
end

--- Formats an entry as one key=value audit line.
local function toLine(entry)
	-- BOUNDED LIKE EVERYTHING ELSE ON THE LINE. The header of this file promises
	-- that "every message and every data text is stripped of its control
	-- characters and bounded", and `message`, `data` and an unusable `source`
	-- were -- these three were not. A newline in any of them forges a whole
	-- audit line, which is the risk `core/server/note.lua` describes at length.
	-- It held only by the accident of who calls it: `userId` comes attested by
	-- the host and `citizenId` through `CitizenId.Parse` or a bounded word. A
	-- guarantee the writer states is the writer's to keep, not every caller's.
	local parts = {
		('event=%s'):format(bounded(entry.event, 64)),
		('severity=%s'):format(bounded(entry.severity, 16)),
	}
	if entry.citizenId then
		parts[#parts + 1] = ('citizen=%s'):format(bounded(entry.citizenId, 64))
	end
	if entry.userId then parts[#parts + 1] = ('user=%s'):format(bounded(entry.userId, 64)) end
	if entry.source then
		-- `%d` RAISES ON ANYTHING THAT IS NOT A WHOLE NUMBER -- a float, a string
		-- the host handed over, a table -- and a source arrives from every caller
		-- in the runtime, several of which never normalise it. The line is worth
		-- more than the digit: an unusable source is printed as it came so an
		-- operator can see WHAT was passed.
		local id = tonumber(entry.source)
		if id and id % 1 == 0 then
			parts[#parts + 1] = ('player=%d'):format(id)
		else
			parts[#parts + 1] = ('player=%s'):format(bounded(entry.source, 32))
		end
	end
	if entry.message and entry.message ~= '' then
		parts[#parts + 1] = ('message=%q'):format(entry.message)
	end
	if entry.data then
		-- `json.encode` raises on a cyclic table, and a `data` block is assembled
		-- by a caller that may well have put a live record in it.
		local ok, encoded = pcall(json.encode, entry.data)
		parts[#parts + 1] = ('data=%s'):format(ok
			and bounded(encoded, MAX_MESSAGE)
			or ('<unencodable: %s>'):format(bounded(encoded, 64)))
	end
	return table.concat(parts, ' ')
end

--- Answers whether an entry must be written every time.
local function isLedger(entry)
	if entry.severity ~= 'info' and entry.severity ~= 'debug' then return false end
	for i = 1, #LEDGER_PREFIXES do
		local prefix = LEDGER_PREFIXES[i]
		if entry.event:sub(1, #prefix) == prefix then return true end
	end
	return false
end

-- When the recent entries may next be swept.
local nextSweepAt = 0

--- Drops recent entries past their retention, at most once a window.
local function sweep(now)
	-- Sweeping on every entry would be a full walk per line. This, not `forget`,
	-- is what bounds the table. It only removes keys `pairs` has already yielded,
	-- which Lua defines; adding during the walk is not defined.
	if now < nextSweepAt then return end
	nextSweepAt = now + DEDUPE_MS
	for key, seen in pairs(recent) do
		if now - seen.at >= RETAIN_MS then recent[key] = nil end
	end
end

--- Counts an entry and answers whether its window is still open.
local function repeated(key, owner)
	local now = OPX.Now()
	sweep(now)
	local seen = recent[key]
	if seen and now - seen.at < DEDUPE_MS then
		seen.count = seen.count + 1
		return true, seen.count
	end
	local carried = seen and seen.count or 0
	recent[key] = { at = now, count = 0, owner = owner }
	return false, carried
end

--- Forgets the dedupe windows a departing player or character owns.
-- @author dop42
--
-- A caller that knows the citizen id passes it: an entry logged without a source
-- is keyed by citizen id, which a departing source does not name.
-- @param source Source
-- @param citizenId CitizenId|nil
function OPX.Audit.Forget(source, citizenId)
	local bySource = tostring(source)
	local byCitizen = citizenId ~= nil and tostring(citizenId) or nil
	for key, seen in pairs(recent) do
		if seen.owner == bySource or (byCitizen and seen.owner == byCitizen) then
			recent[key] = nil
		end
	end
end

--- Writes one audit entry, collapsing repeats outside the ledger.
-- @author dop42
--
-- The first entry written after a closed window carries `[+N suppressed]`.
-- @param entry table event, severity, message, data, source, citizenId, userId, and
--   owner: who the dedupe window belongs to when no player does (never printed)
--
-- IT CANNOT TAKE ITS CALLER DOWN. Every audit call sits inside somebody else's
-- net handler, and this whole body used to be unprotected: `('player=%d')
-- :format` raised on a float source, `json.encode` raised on a cyclic `data`
-- table, `tostring` raises on a `__tostring` that does -- and each of those
-- lost the ENTRY and then the OPERATION that was being audited. For a file about
-- what an operator will have to account for later, losing both is the wrong
-- direction; losing neither is the point, so a failure here degrades to a line
-- naming the event and the raise.
function OPX.Audit.Log(entry)
	if type(entry) ~= 'table' or type(entry.event) ~= 'string' then return end

	local ok, failure = pcall(function()
		entry.severity = SEVERITIES[entry.severity] and entry.severity or 'info'
		entry.message = entry.message ~= nil and bounded(entry.message, MAX_MESSAGE) or nil

		if not isLedger(entry) then
			-- `owner` names who the dedupe window belongs to when there is no
			-- player: a caller resource, say. Without it every such entry shared
			-- the one `-` window, so one resource looping on a refusal swallowed
			-- every other resource's refusals of the same event.
			local owner = tostring(entry.owner or entry.source or entry.citizenId or '-')
			local again, carried = repeated(entry.event .. '\1' .. owner, owner)
			if again then return end
			if carried > 0 then
				entry.message = ('%s [+%d suppressed]'):format(entry.message or '', carried)
			end
		end

		Open77.log[entry.severity](('[audit] %s'):format(toLine(entry)))
	end)

	if not ok then
		-- Degraded, not dropped: the event name is the part a `grep` is looking
		-- for, and it is a string this function has already checked.
		pcall(function()
			Open77.log.error(('[audit] event=%s could not be written: %s')
				:format(entry.event, tostring(failure)))
		end)
	end
end

--- Writes an audit entry attributed to a loaded character.
-- @author dop42
--
-- Covers the most common shape: the source, citizen and account of a `Player`.
-- @param player Player|nil
-- @param event string
-- @param message string|nil
-- @param data table|nil
function OPX.Audit.Player(player, event, message, data)
	local playerData = player and player.PlayerData
	Audit.Log({
		event = event,
		message = message,
		data = data,
		source = playerData and playerData.source,
		citizenId = playerData and playerData.citizenId,
		userId = playerData and playerData.userId,
	})
end

--- Writes a warn audit entry for a refused or suspicious request.
-- @author dop42
--
-- Always pass the source: without it the window is keyed by event alone, and one
-- player looping on a refusal swallows the refusals of everybody else.
-- @param event string
-- @param message string|nil
-- @param data table|nil
-- @param source Source|nil who caused it, keying the dedupe window
function OPX.Audit.Security(event, message, data, source)
	Audit.Log({ event = event, severity = 'warn', message = message, data = data,
		source = source })
end
