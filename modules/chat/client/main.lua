--- The client half: the box's state, the typed command path, and the seam a
--- view attaches to.
-- @author dop42

local M = OPX.Modules.Get('chat')

local Result = OPX.Result

local EVENT_VIEW = M.Event.VIEW

-- Fragment both known queue acknowledgement wordings share. The dispatcher
-- carries no field that tells its own acknowledgement from a command's answer,
-- so it is recognised by the English text the platform writes.
local QUEUE_ACK = 'queued by '

-- Most arguments the dispatcher takes, the command name included.
local MAX_ARGUMENTS = 32

-- How many completion entries travel in one payload.
--
-- NOT ONE PAYLOAD FOR THE WHOLE LIST, and the reason is the seam rather than
-- taste: `WebUI.Page.send` bounds both the event name and the payload, and a
-- payload over the bound is REFUSED -- not truncated, not split. This server
-- answers `chat:ready` with every command a player may be shown, each with a
-- localised help string and its parameter tables, and that is the one payload
-- on this seam whose size grows with the RUNTIME rather than with anything a
-- player did: 73 commands today, and nothing stops the next module adding ten.
--
-- Eight is small enough that the number of commands stops mattering at all,
-- and the whole list is nine payloads on local IPC, twice a session.
local SUGGESTIONS_PER_PAYLOAD = 8

-- Which view has reported ready. Nothing is sent to one that has not: a payload
-- sent earlier is dropped, not queued.
local ready

-- Whether the input line is open and holds the keyboard.
local opened

-- The one enabled flag for the whole box, not one per caller.
local enabled

-- The last command list the server answered, held so it can be replayed to a view
-- that was not ready when it arrived. See `onSuggestions`.
local suggestions

-- Forward-declared: `openChat` replays the held list and is written above the
-- function that does it. A `local function` further down would be a DIFFERENT
-- local, and the call above it would reach for a global that does not exist.
local republishSuggestions

-- Whether the player is down, kept apart from `enabled`: standing up gives back
-- whatever `SetEnabled` last said, and `IsEnabled` does not lie meanwhile.
local down

-- Down states heard, so that a late catch-up read never overrides a newer one.
local downHeard

-- Whether a toast that did not appear has already been logged once.
local toastReported

-- ── the view seam ───────────────────────────────────────────────────────────
-- This module owns the state and nothing else: no surface is created here.
-- Everything it has to say to whatever draws the box leaves on EVENT_VIEW, and
-- everything a view has to say comes back through the one function `M.FromView`.
-- A view module attaches by listening to the first and calling the second.
--
-- Every payload names the surface it belongs to, because the box is two
-- concerns on two surfaces: the LOG is drawn on the always-on overlay, and the
-- INPUT line on the interactive layer, which is the only one that may take the
-- keyboard. A view drawing one of them ignores the other's payloads.

--- Tells one view something. `kind` is, for the overlay, 'config', 'line',
--- 'clear' or 'visible'; for the interactive layer, 'config', 'open', 'close',
--- 'focus', 'suggest', 'unsuggest' or 'suggestions'.
local function publish(surface, kind, payload)
	if not ready[surface] then return false end
	payload = payload or {}
	payload.kind = kind
	payload.surface = surface
	TriggerEvent(EVENT_VIEW, payload)
	return true
end

--- The settings the log half of a view needs.
local function logConfig()
	return {
		anchor = M.Settings.ANCHOR,
		offset = M.Settings.OFFSET,
		width = M.Settings.WIDTH,
		history = M.Settings.HISTORY,
		fadeMs = M.Settings.FADE_MS,
		visible = not down,
	}
end

--- The settings the input half of a view needs.
local function inputConfig()
	return {
		anchor = M.Settings.ANCHOR,
		offset = M.Settings.OFFSET,
		width = M.Settings.WIDTH,
		maxLength = M.Settings.MAX_LENGTH,
		placeholder = locale('chat.placeholder'),
	}
end

--- Puts one line in this player's log.
-- Answers a Result: a line nothing can draw is refused rather than silently
-- dropped, exactly as the old export refused `page_not_ready`.
local function addLine(message)
	if type(message) == 'string' then message = { text = message } end
	if type(message) ~= 'table' then return Result.Err('chat.invalidMessage') end
	if not publish('overlay', 'line', { line = message }) then
		return Result.Err('chat.noView')
	end
	return Result.Ok(true)
end

--- Puts one error line, tagged with an author, in the log.
-- No colour is sent with it: the view paints `error` from its own tokens, and a
-- colour written into the line would freeze it outside the stylesheet.
local function addErrorLine(author, text)
	addLine({ kind = 'error', author = author, text = text })
end

--- Tells the player why a command went nowhere, as a toast or a red line.
local function commandRefused(kind, text)
	if M.Settings.NOTIFY == false then
		return addErrorLine(locale('chat.author.command'), text)
	end

	-- One replaced toast, addressed by id: a player who runs a refused command
	-- twice sees one answer, not a pile.
	local raised = OPX.Toast.Show({
		id = 'opx.chat.command',
		kind = kind,
		title = locale('chat.author.command'),
		message = text,
		durationMs = 5000,
	})
	if raised ~= nil then return end

	if not toastReported then
		toastReported = true
		Open77.log.warn('[chat] no toast: command refusals go to the chat box instead')
	end
	addErrorLine(locale('chat.author.command'), text)
end

--- Words a dispatcher refusal for the player and grades it.
-- The codes and the older English phrasings are both recognised; anything else
-- is a refusal a command wrote itself and is already in words.
local function refusalText(name, message)
	if message == 'unknown_command' or message:find("unknown command '", 1, true) == 1 then
		return locale('chat.command.unknown', { command = name }), 'warning'
	end
	if message:find('permission_denied:', 1, true) == 1
		or message:find("permission denied for command '", 1, true) == 1 then
		return locale('chat.command.denied', { command = name }), 'error'
	end
	local lowered = message:lower()
	if lowered:find('rate_limit', 1, true) or lowered:find('rate limit', 1, true) then
		return locale('chat.command.tooFast'), 'warning'
	end
	if message == '' then return locale('chat.command.failed', { command = name }), 'error' end
	return message, 'error'
end

-- The bytes that mean something to the tokeniser, by what it is inside: out of
-- quotes a backslash, either quote and any space; inside one, a backslash and
-- the quote that closes it. Every other byte is copied as it stands.
local SPECIAL = { [''] = '[\\"\'%s]', ['"'] = '[\\"]', ["'"] = "[\\']" }

--- Splits a typed command into dispatcher tokens, honouring quotes and escapes.
-- Each token is accumulated in a table and joined once: appending to a string a
-- character at a time is quadratic.
--
-- A RUN AT A TIME, NOT A CHARACTER AT A TIME. This runs inside the page
-- callback's one resume, and walking the line a byte per iteration cost ~19 VM
-- instructions a byte: a full 240-character command was ~4,700, and the cut of
-- an unbounded line plus its walk ~6,900 -- the budget meter's 9,000 for the
-- submit, against a budget of ~10,000 whose overrun makes the command vanish
-- with no answer. `find` skips each run of ordinary bytes natively, so the Lua
-- work is per special byte; the tokens are the same.
local function commandTokens(text)
	local line = text:sub(2)
	local tokens, buffer, quote, escaped, started = {}, {}, nil, false, false
	local index, size = 1, #line
	while index <= size do
		if escaped then
			buffer[#buffer + 1], escaped, started = line:sub(index, index), false, true
			index = index + 1
		else
			local stop = line:find(SPECIAL[quote or ''], index) or size + 1
			if stop > index then
				buffer[#buffer + 1], started = line:sub(index, stop - 1), true
				index = stop
			else
				local character = line:sub(index, index)
				index = index + 1
				if character == '\\' then
					escaped, started = true, true
				elseif quote ~= nil then
					-- Inside a quote only its own closing quote stops the run.
					quote, started = nil, true
				elseif character == '"' or character == "'" then
					quote, started = character, true
				elseif started then
					tokens[#tokens + 1] = table.concat(buffer)
					buffer, started = {}, false
					if #tokens > MAX_ARGUMENTS then
						return nil, locale('chat.tooManyArgs', { max = MAX_ARGUMENTS })
					end
				end
			end
		end
	end
	if escaped then return nil, locale('chat.escapeAtEnd') end
	if quote ~= nil then return nil, locale('chat.unterminatedQuote') end
	if started then
		tokens[#tokens + 1] = table.concat(buffer)
		if #tokens > MAX_ARGUMENTS then
			return nil, locale('chat.tooManyArgs', { max = MAX_ARGUMENTS })
		end
	end
	if #tokens == 0 or tokens[1] == '' then return nil, locale('chat.commandExpected') end
	return tokens
end

--- Hands the keyboard back, then tells the view to close.
-- In that order: a close the view paints before the keyboard goes back is not
-- seen. A box that is already closed is not told twice, because closing it again
-- would fade every line in the log back in.
-- When the input line opened, for Escape's layer order.
local openedAtMs = 0

local function closeChat(asked)
	if opened then
		opened = false
		publish('interactive', 'focus', { hold = false })
	elseif asked ~= true then
		return
	end
	publish('interactive', 'close', {})
end

--- Opens the input line and takes the keyboard, logging every refusal.
local function openChat()
	if not enabled then
		Open77.log.warn('[chat] open refused: the chat is disabled by the server')
		return
	end
	if down then
		Open77.log.warn('[chat] open refused: the player is down')
		return
	end
	if not ready.interactive then
		-- Taking the keyboard before the view can draw the input line would
		-- capture it with nowhere to type. `opened` stays false, so the next
		-- press succeeds as soon as a view reports ready.
		Open77.log.warn('[chat] open refused: no view has reported ready')
		return
	end
	if opened then return end
	opened = true
	openedAtMs = OPX.Now()

	-- The focus is asked for BEFORE the open: both travel on one ordered
	-- channel, and the element focus has to land in a surface that already holds
	-- the keyboard.
	publish('interactive', 'focus', { hold = true })
	publish('interactive', 'open', {})
	-- The held list first, so the box opens with completions already in it rather
	-- than with whatever the cooldown decides to let through.
	republishSuggestions()
	TriggerServerEvent(M.Event.READY)
end

--- Adds or replaces one completion entry.
-- Accepts three positional arguments or one whole entry, and reads `command` or
-- `name` and `parameters` or `params`, because both spellings are written by the
-- packets that used to carry them.
local function addSuggestion(command, help, parameters)
	if type(command) == 'table' then
		local entry = command
		command = entry.command or entry.name
		help = entry.help
		parameters = entry.parameters or entry.params
	end
	local name = tostring(command or '')
	if name == '' then return Result.Err('chat.invalidCommand') end
	local sent = publish('interactive', 'suggest', {
		suggestion = {
			name = name,
			help = tostring(help or ''),
			params = type(parameters) == 'table' and parameters or {},
		},
	})
	if not sent then return Result.Err('chat.noView') end
	return Result.Ok(true)
end

--- Takes one completion entry back down.
local function removeSuggestion(command)
	local name = tostring(command or '')
	if name == '' then return Result.Err('chat.invalidCommand') end
	if not publish('interactive', 'unsuggest', { name = name }) then
		return Result.Err('chat.noView')
	end
	return Result.Ok(true)
end

--- Empties the visible log, leaving the suggestions alone.
local function clearMessages()
	if not publish('overlay', 'clear', {}) then return Result.Err('chat.noView') end
	return Result.Ok(true)
end

--- Closes and hides the whole box while down, and opens nothing after.
local function setDown(value)
	if down == value then return end
	down = value
	if down then closeChat() end
	-- The whole box, log included: lines keep arriving in the hidden log, so
	-- nothing said while down is lost.
	publish('overlay', 'visible', { visible = not down })
end

--- Catches up once with a player who went down before this module started.
-- A state heard while the read was in flight is newer than the read, and wins.
local function adoptDownState()
	local downed = OPX.Api.Get('downed')
	if downed == nil then return end

	local heard = downHeard
	local answer = downed.IsDown()
	if not answer.ok then
		Open77.log.warn(('[chat] the downed contract did not answer: %s')
			:format(tostring(answer.error)))
		return
	end
	if downHeard ~= heard then return end
	setDown(answer.value.down == true)
end

--- Puts a line another module sent in this player's log.
local function onMessage(message)
	addLine(message)
end

--- Hands the held list to the input line, in payloads the host will carry.
--
-- The FIRST payload carries `reset`, so the page replaces whatever it holds;
-- every one after it is appended. A page that receives the first and misses the
-- rest is short a few completions -- it is never left holding half of one list
-- and half of another.
--
-- ONE PAYLOAD PER RESUME. Every chunk is a local event and a page send, and the
-- list is every command the player may see -- seventy-odd today, ten chunks,
-- growing with every module -- which went out in one go from whichever handler
-- asked: the box opening (a key), the page reporting ready, the server's answer.
-- The chunks now go out on a thread of their own, one a frame, and a newer send
-- abandons an older one: its first chunk resets the page anyway.
local sendGeneration = 0

local function sendChunks(list, mine, paced)
	local total = #list
	local at, first = 1, true
	while at <= total do
		if not first and paced then
			Wait(0)
			if sendGeneration ~= mine then return false end
		end
		local chunk = {}
		for index = at, math.min(at + SUGGESTIONS_PER_PAYLOAD - 1, total) do
			chunk[#chunk + 1] = list[index]
		end
		if not publish('interactive', 'suggestions', { suggestions = chunk, reset = first }) then
			return false
		end
		first = false
		at = at + SUGGESTIONS_PER_PAYLOAD
	end
	return true
end

local function sendSuggestions(list)
	sendGeneration = sendGeneration + 1
	local mine = sendGeneration
	if #list == 0 then
		return publish('interactive', 'suggestions', { suggestions = {}, reset = true })
	end
	if type(CreateThread) ~= 'function' then return sendChunks(list, mine, false) end
	CreateThread(function() sendChunks(list, mine, true) end)
	return true
end

--- Takes a whole list of completion entries and hands it to the view.
--
-- KEPT, NOT JUST FORWARDED. `publish` DROPS a payload the layer is not ready
-- for -- it does not queue it -- and the command list is answered by the server
-- on its own schedule, behind a five-second cooldown it shares with nothing. So
-- a list that arrives a frame before the input line reports ready is a list the
-- player never sees, and the next one cannot be asked for until the cooldown
-- lets go. That is not a race worth winning once: it is a race worth removing,
-- so the last list is held here and replayed whenever the view can take it.
local function onSuggestions(payload)
	local list = type(payload) == 'table' and payload.suggestions or nil
	suggestions = type(list) == 'table' and list or {}
	sendSuggestions(suggestions)
end

--- Replays the held list. Called the moment the input line can receive one, and
--- again every time the box opens: the second costs a few messages and means a
--- player who reconnected into a stale list gets the current one.
--
-- Nothing held sends nothing: an empty resetting payload would take away a list
-- the page already has, and this is called on every open.
republishSuggestions = function()
	if type(suggestions) ~= 'table' or #suggestions == 0 then return end
	sendSuggestions(suggestions)
end

--- Toasts a refused command and prints nothing for an accepted one.
-- The box is for what players say and for reports someone asked to read, not
-- for command bookkeeping.
local function onCommandResult(raw, accepted, message)
	raw, message = tostring(raw or ''), tostring(message or '')
	if message:find(QUEUE_ACK, 1, true) ~= nil then return end
	if accepted then return end
	local text, kind = refusalText(raw:match('^/?(%S+)') or raw, message)
	commandRefused(kind, text)
end

--- Sends one typed line, as a command or as a message.
local function submit(text)
	-- The box closes first whatever happens next: nothing below may leave the
	-- keyboard held, and a command that answers nothing gives the view no other
	-- reason to redraw.
	closeChat(true)
	-- BOUNDED HERE, NOT ONLY ON THE PAGE. `MAX_LENGTH` is handed to the input
	-- box and the server cuts what it relays, but a command is tokenised on
	-- this side a character at a time, inside the page callback's one resume:
	-- a line the page did not bound -- a paste into an older view, a forged
	-- emit -- was an unbounded walk on the per-resume budget, and the command
	-- would vanish with no answer. Cut at a character, never mid-sequence.
	local limit = tonumber(M.Settings.MAX_LENGTH) or 240
	if #text > limit then text = text:sub(1, OPX.Text.Span(text, limit)) end
	if #text == 0 then return end

	if text:sub(1, 1) ~= '/' then
		-- The host answers whether the event left, and why it did not: a line
		-- the transport dropped must say so rather than vanish.
		local sent, why = TriggerServerEvent(M.Event.SAY, text)
		if not sent then
			Open77.log.warn('[chat] message not sent: ' .. tostring(why))
			addErrorLine(locale('chat.author.network'), locale('chat.messageNotSent'))
		end
		return
	end

	-- An unusable line concerns a command and not a message, so it is answered
	-- like any other command refusal.
	local tokens, failure = commandTokens(text)
	if tokens == nil then
		commandRefused('warning', failure)
		return
	end

	local sent, why = TriggerServerEvent(M.Host.COMMAND_EXECUTE, table.unpack(tokens))
	if not sent then
		Open77.log.warn('[chat] command not sent: ' .. tostring(why))
		commandRefused('error', locale('chat.commandNotSent'))
	end
end

--- What a view module calls. `action` is 'ready', 'submit', 'close' or 'diag'.
-- @author dop42
--
-- The other half of the seam. `ready` says which surface can be drawn on and
-- answers with that surface's settings; `submit` carries one typed line; `close`
-- is the view asking to be closed, which it may do whether or not Lua thinks the
-- box is open; `diag` carries a view-side failure to the client log, which it
-- could not otherwise reach.
-- @param action string
-- @param payload table|nil surface, text
function M.FromView(action, payload)
	payload = type(payload) == 'table' and payload or {}
	local surface = payload.surface == 'interactive' and 'interactive' or 'overlay'

	if action == 'ready' then
		ready[surface] = true
		if surface == 'overlay' then
			publish('overlay', 'config', logConfig())
		else
			publish('interactive', 'config', inputConfig())
			-- ASKED FOR BY THE INPUT LINE ONLY, and that is not tidiness.
			--
			-- The server rate-limits this signal (`READY_MS`, five seconds), and the
			-- answer is published to `interactive` -- which is dropped, not queued,
			-- while that layer has not reported ready. Asking from the overlay's
			-- ready meant the list arrived before the input line existed, went
			-- nowhere, and the input line's own ask was then swallowed by the very
			-- cooldown the first ask had started. The completion list was empty for
			-- the life of the session.
			--
			-- The log has no use for a command list anyway; only the line that can
			-- be typed into does.
			-- Whatever the server last answered, before asking for a newer one: the
			-- ask is behind a cooldown and may go nowhere, and a list held from
			-- earlier in the session is worth more than an empty box.
			republishSuggestions()
			TriggerServerEvent(M.Event.READY)
		end
	elseif action == 'submit' then
		submit(tostring(payload.text or ''))
	elseif action == 'close' then
		closeChat(true)
	elseif action == 'diag' then
		Open77.log.info('[chat] view: ' .. tostring(payload.text or ''))
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state. Never yields.
-- @author dop42
function M.Init()
	ready = { overlay = false, interactive = false }
	opened = false
	enabled = true
	suggestions = {}
	down = false
	downHeard = 0
	toastReported = false
end

--- Publishes what another module may do to the box.
-- @author dop42
function M.Api()
	OPX.Api.Provide('chat', 1, {
		AddMessage = addLine,
		AddSuggestion = addSuggestion,
		RemoveSuggestion = removeSuggestion,
		ClearMessages = clearMessages,
		SetEnabled = function(value)
			-- Anything but false enables, and the flag is real before any view
			-- exists: this is the one call that does not need one.
			enabled = value ~= false
			if not enabled then closeChat() end
			return Result.Ok(enabled)
		end,
		IsEnabled = function() return Result.Ok(enabled) end,
	})
end

--- Wires the events and catches up with a player who is already down.
-- @author dop42
function M.Start()
	-- First, so that the seam has somewhere to go before anything below can
	-- publish on it. `client/view.lua` is the only file that knows the other end
	-- is a CEF page; without it this module still holds its state and simply
	-- never draws, which is exactly what it did before that file existed.
	M.View.Start()

	RegisterNetEvent(M.Event.MESSAGE, onMessage)
	RegisterNetEvent(M.Event.SUGGESTIONS, onSuggestions)
	RegisterNetEvent(M.Host.COMMAND_RESULT, onCommandResult)

	-- Core answers a command that asked to read something back on its own name.
	-- It belongs to `core/server/answer.lua` and cannot be renamed from here.
	RegisterNetEvent(M.CORE_MESSAGE, onMessage)

	-- The key belongs to the host, which raises this when the player presses it;
	-- this module has no binding of its own. Escape is swallowed before any
	-- surface sees it, and arrives as the pause key instead.
	AddEventHandler(M.Host.CHAT_KEY, openChat)
	-- Escape closes the TOP layer only: see `OPX.Spots.Key.Layer`.
	local layer = OPX.Spots.Key.Layer('chat', function() return opened and openedAtMs or nil end)
	AddEventHandler(M.Host.PAUSE_KEY, function()
		if not OPX.Spots.Key.TopLayer(layer) then return end
		closeChat()
	end)

	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed'), function(payload)
		if type(payload) ~= 'table' then return end
		downHeard = downHeard + 1
		setDown(payload.down == true)
	end)

	adoptDownState()
end

--- Gives the keyboard back and forgets what was on screen.
-- A focus held across a stop leaves the player unable to move.
-- @author dop42
function M.Stop()
	closeChat()
	ready = { overlay = false, interactive = false }
	opened = false
	M.View.Shutdown()
end
