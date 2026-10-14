--- The creator for a character with no body, and the form for one with no name.
-- @author dop42
--
-- Both are answers to a character the server made EMPTY, and both are asked in
-- the order the platform allows: the creator belongs to the pre-game menu, where
-- the character bootstrap is still open, and the name to the world afterwards,
-- where a modal can be drawn at all.
--
-- Everything here is driven by one pass rather than by a thread. The per-resume
-- instruction budget unwinds out of a coroutine body, and a `while true` loop
-- that hits it is never resumed again, silently -- which here would mean a
-- character nobody ever asks the name of.

local M = OPX.Modules.Get('entry')
local Result = OPX.Result

local LOCAL = OPX.Channel.LOCAL
local NET = OPX.Channel.NET

-- This module's name to the form module, and the form's own id.
local OWNER = 'entry'
local FORM = 'entry.name'

-- The character module's public local bus, built the same way the module that
-- raises it builds it: a bare name would be a typo waiting to happen.
local EVENT_LOADED = OPX.Event(LOCAL, 'character', 'loaded')
local EVENT_UNLOADED = OPX.Event(LOCAL, 'character', 'unloaded')
local EVENT_CHANGED = OPX.Event(LOCAL, 'character', 'changed')

-- The appearance module's public decision bus, which is where `needsCreation` is
-- announced. Public: a bare AddEventHandler is the documented way to hear it.
local EVENT_APPEARANCE = OPX.Event(LOCAL, 'appearance', 'decision')

-- Where every server refusal arrives, with the operation it answers.
-- AddEventHandler and not RegisterNetEvent: `core/client/notify.lua` has already
-- registered this name for the wire, the dispatcher matches on the name alone,
-- and a second RegisterNetEvent would be a second registration of a name that is
-- already allowed. This handler is additive -- the runtime's own toast still goes
-- up; this one is what puts the player back in front of the form.
local EVENT_REFUSED = OPX.Event(NET, 'runtime', 'notify')

-- Period of this module's one pass.
local TICK_MS = 500

-- The contracts this module is built on, resolved once the Api phase has ended.
local Character
local Appearance
local Form

-- Whether this module is running, and the citizen id it is working on.
local running = false
local citizenId

-- The appearance module has asked for a creation and not taken the ask back, a
-- creator is open for it, and when a refused one may be asked for again.
local creationAsked = false
local creating = false
local creationRetryAtMs = 0

-- The form asking for a name: its handle while it is up, and when it may be
-- asked for again after a refusal or a cancellation.
local naming
local retryAtMs = 0

-- When a name was sent and not yet answered (0 when none is in flight). The
-- answer is the mirrored PlayerData coming back named, or a refusal -- both take
-- a round trip, and the form must not be put up again inside it.
local sentAtMs = 0

-- What the player typed and the server refused, so the form comes back filled in
-- rather than blank under the message that refused it.
local draft = { firstName = '', lastName = '' }
local refusal

-- Whether the appearance module still owes this character a fitting room.
--
-- THE THIRD THING A NEW CHARACTER ANSWERS FOR, and the reason it is held here
-- rather than in the module that owns it. This module is already what speaks for
-- "the player is still being asked something": it raises `M.Event.ON_STATE`, and
-- the spawn menu stands aside for the whole time that says open, because two
-- modals on one keyboard is one modal losing its focus. The clothes are a third
-- modal on the same keyboard at the same instant, so they belong in the same
-- answer -- which is all this flag does. Nothing here opens a fitting room or
-- decides whether one is owed: `WARDROBE.OFFER_POLICY` decides that, the
-- appearance module acts on it, and this listens.
--
-- The ORDER falls out of it. The name form takes the keyboard, so the appearance
-- module's own retry loop cannot open the room until the form is answered; the
-- room then reports itself through here, so the spawn menu cannot open until the
-- room is closed. Name, then clothes, then where you land -- held by two modules
-- each standing aside for the one in front, and by nothing else.
local wardrobeOwed = false

-- Milliseconds before a form that was cancelled, or refused, is offered again.
local RETRY_MS = 1500

-- Milliseconds before a creator that was refused is asked for again. A refusal
-- here is never final -- `appearance_busy` while another modal settles, a player
-- who is down, a contract that is not up yet -- and a creation that is never
-- opened is a character nobody can play.
local CREATION_RETRY_MS = 2000

-- How long a name that was sent is waited on before the form is offered again.
-- It covers the round trip and the refusal that may come back instead; past it,
-- something was lost and asking again is better than a character with no name.
local SENT_WAIT_MS = 8000

--- Announces what this module is waiting for, on the public local bus.
-- A nil `what` means "nothing of MINE is up", which is not the same as idle: a
-- fitting room still owed is the join still asking, so it is resolved here
-- rather than at each of the five call sites -- every one of which would
-- otherwise have to remember the third question exists.
local function announce(what)
	if what == nil and wardrobeOwed then what = 'wardrobe' end
	TriggerEvent(M.Event.ON_STATE, { open = what ~= nil, phase = what or 'idle' })
end

-- ── the body and the face ────────────────────────────────────────────────────

--- What the appearance module is waiting for, or nil.
local function appearanceWaiting()
	if Appearance == nil or type(Appearance.IsSettled) ~= 'function' then return nil end
	local ok, answer = pcall(Appearance.IsSettled)
	if not ok or type(answer) ~= 'table' or not answer.ok then return nil end
	return type(answer.value) == 'table' and answer.value.waiting or nil
end

--- Hands the player to the game's own creator.
-- Nothing is chosen here. The creator asks for the body, builds the face in the
-- same flow, and the appearance module writes what it confirmed to the character
-- row; this module only says yes -- and says it again when it was refused.
local function openCreator()
	if Appearance == nil or type(Appearance.OpenCreator) ~= 'function' then
		creationAsked = false
		Open77.log.warn('[entry] no appearance contract answers `needsCreation`: ' ..
			'the character enters on the default face')
		return
	end

	local ok, answer = pcall(Appearance.OpenCreator)
	if ok and type(answer) == 'table' and answer.ok then
		creating = true
		announce('creator')
		return
	end

	creating = false
	creationRetryAtMs = OPX.Now() + CREATION_RETRY_MS
	Open77.log.warn('[entry] the character creator was refused, asking again: ' ..
		tostring(type(answer) == 'table' and answer.error or answer))
end

--- Records that a character is owed a body and a face, or that it no longer is.
local function onAppearance(payload)
	if type(payload) ~= 'table' then return end

	-- THE FITTING ROOM'S CLAIM. One event carrying both states, because what is
	-- held here is a boolean and a pair of event names would have to be kept in
	-- step by whoever read them. `ok` is true from the moment the appearance
	-- module decides a room is coming -- before it can open one, which is the
	-- gap that matters: the room is refused while the name form holds the
	-- keyboard, and the spawn menu would otherwise walk into that gap.
	if payload.event == 'wardrobeWanted' then
		local owed = payload.ok == true
		if wardrobeOwed == owed then return end
		wardrobeOwed = owed
		-- Only when nothing of this module's own is on screen. A form up now is
		-- still the honest answer, and re-announcing under it would say the join
		-- had moved on to the clothes while the player was typing a name.
		if naming == nil and not creating then announce(nil) end
		return
	end

	if payload.event == 'created' or payload.event == 'settled' then
		creationAsked, creating = false, false
		announce(nil)
		return
	end
	if payload.event ~= 'needsCreation' then return end

	-- Opened from this module's own pass rather than here: this handler runs
	-- inside the appearance module's publication, and a refusal needs somewhere
	-- to come back to.
	creationAsked, creating, creationRetryAtMs = true, false, 0
end

--- Whether the appearance module says this world entry's face work has finished.
-- Answers true when there is no appearance module at all: nothing will settle,
-- and a name is still worth asking for.
local function appearanceSettled()
	if Appearance == nil or type(Appearance.IsSettled) ~= 'function' then return true end
	local ok, answer = pcall(Appearance.IsSettled)
	if not ok or type(answer) ~= 'table' or not answer.ok then return false end
	return type(answer.value) == 'table' and answer.value.settled == true
end

--- Whether a creator is owed to the loaded character and can be asked for now.
local function creationWanted(atMs)
	if not running or citizenId == nil then return false end
	if not creationAsked or creating then return false end
	if atMs < creationRetryAtMs then return false end
	-- The appearance module gives up on its own after a while and settles the
	-- character on a default face. `creation` is the only phase that still wants
	-- a creator; anything else is a player who is already being dealt with.
	return appearanceWaiting() == 'creation'
end

-- ── the name ────────────────────────────────────────────────────────────────

--- The bounds each half of a name is held to, mirrored from the server's own.
-- A module may not read another module's settings, so the two are kept in step by
-- hand; raising these past the server's only moves the refusal from the form to
-- the server.
local function nameBounds()
	local bounds = type(M.Settings.NAME) == 'table' and M.Settings.NAME or {}
	local minimum = math.floor(M.Number(bounds.MIN, 1))
	local maximum = math.floor(M.Number(bounds.MAX, minimum))
	if maximum < minimum then maximum = minimum end
	return minimum, maximum
end

--- Sends what the player typed, and keeps it in case the server refuses it.
local function submit(values)
	draft.firstName = type(values.firstName) == 'string' and values.firstName or ''
	draft.lastName = type(values.lastName) == 'string' and values.lastName or ''

	local sent, code = Character.SetName(draft.firstName, draft.lastName)
	if sent then
		-- NOTHING IS ASKED AGAIN UNTIL THIS IS ANSWERED. The name is only known to
		-- have landed when the mirrored PlayerData comes back carrying it, and
		-- that is a round trip: a form put up again inside it is a player who
		-- typed a name, saw the same form return, typed it again -- and had the
		-- second one refused by name, because a character is named once.
		sentAtMs = OPX.Now()
		return
	end

	-- Refused before anything left this client. Its codes are the server's own,
	-- so the message reads the same either way.
	refusal = code
	retryAtMs = OPX.Now() + RETRY_MS
end

--- Puts the name form up for the character that is loaded.
local function askName()
	if Form == nil or type(Form.Open) ~= 'function' then return end
	local _, maximum = nameBounds()

	local opened = Form.Open{
		owner = OWNER,
		id = FORM,
		title = locale('entry.name.title'),
		description = refusal ~= nil and M.Refusal(refusal) or locale('entry.name.about'),
		fields = {
			{
				id = 'firstName',
				label = locale('entry.name.firstName'),
				placeholder = locale('entry.name.firstHint'),
				value = draft.firstName,
				maxLength = maximum,
				required = true,
			},
			{
				id = 'lastName',
				label = locale('entry.name.lastName'),
				placeholder = locale('entry.name.lastHint'),
				value = draft.lastName,
				maxLength = maximum,
				required = true,
			},
		},
		on = function(payload)
			naming = nil
			announce(nil)
			if payload.action ~= 'submit' or type(payload.values) ~= 'table' then
				-- A cancelled form is not a character that stays nameless: the city
				-- has to be able to call them something, so it comes back.
				retryAtMs = OPX.Now() + RETRY_MS
				return
			end
			submit(payload.values)
		end,
	}

	if type(opened) == 'table' and opened.ok then
		naming = opened.value.handle
		refusal = nil
		announce('name')
		return
	end

	-- `form_busy`, `player_down`, no surface yet: all of them are reasons to ask
	-- again in a moment rather than to give up on naming this character.
	retryAtMs = OPX.Now() + RETRY_MS
end

--- Whether the loaded character is still owed a name, and can be asked now.
local function nameWanted(atMs)
	if not running or citizenId == nil then return false end
	if naming ~= nil or creating then return false end
	if Character.IsNamed() then return false end

	-- A name is in flight. Nothing is asked until it has been answered, and past
	-- the deadline it counts as lost rather than as answered.
	if sentAtMs ~= 0 then
		if atMs - sentAtMs < SENT_WAIT_MS then return false end
		Open77.log.warn('[entry] the name sent for this character was never answered: asking again')
		sentAtMs = 0
	end

	if atMs < retryAtMs then return false end
	return appearanceSettled()
end

-- ── what the server says ────────────────────────────────────────────────────

--- Shows a refusal meant for this module, and nothing else.
-- BRANCHED ON THE OPERATION, never on the code: `error.tooFast` is raised by
-- every request the server rate limits, and without the operation this would take
-- a vehicle's refusal for its own.
local function onRefused(payload)
	if type(payload) ~= 'table' then return end
	if payload.operation ~= M.Operation.NAME then return end

	-- The answer to what was in flight, whatever it says.
	sentAtMs = 0

	-- `character.nameSet` is the server saying this character is already named,
	-- which is not something to ask again: the mirror is a message behind, and
	-- the next one carries the name.
	if payload.code == 'character.nameSet' then
		refusal, retryAtMs = nil, OPX.Now() + SENT_WAIT_MS
		return
	end

	refusal = payload.code
	retryAtMs = OPX.Now() + RETRY_MS
end

--- Takes up a character the server loaded.
local function onLoaded(playerData)
	if type(playerData) ~= 'table' then return end
	local citizen = playerData.citizenId
	if type(citizen) ~= 'string' or citizen == '' then return end
	if citizen == citizenId then return end

	citizenId = citizen
	creationAsked, creating, creationRetryAtMs = false, false, 0
	draft.firstName, draft.lastName = '', ''
	refusal, retryAtMs, sentAtMs = nil, 0, 0
	-- The claim belongs to the character that left. The appearance module raises
	-- its own for this one, and until it does the join is not waiting on clothes.
	wardrobeOwed = false
end

--- Forgets the character that left, and the question it had not answered.
local function onUnloaded()
	citizenId = nil
	creationAsked, creating, creationRetryAtMs = false, false, 0
	refusal, retryAtMs, sentAtMs = nil, 0, 0
	draft.firstName, draft.lastName = '', ''
	-- Cleared before the announce below, so the join is reported IDLE rather than
	-- still waiting on a fitting room for a character that has gone. A claim left
	-- standing here is the one failure that costs a player their spawn choice
	-- without anything going wrong anywhere: the menu would stand aside for ever.
	wardrobeOwed = false
	if naming ~= nil and Form ~= nil and type(Form.Close) == 'function' then
		pcall(Form.Close, naming)
	end
	naming = nil
	announce(nil)
end

-- ── the contract ────────────────────────────────────────────────────────────

--- What this module is waiting for, if anything.
-- @author dop42
-- @return Result
local function state()
	return Result.Ok({
		citizenId = citizenId,
		creating = creating,
		naming = naming ~= nil,
		named = citizenId ~= nil and Character.IsNamed() or false,
		-- Not this module's to answer for, and reported anyway: this is the
		-- contract for "what is the join still waiting on", and the clothes are
		-- part of that answer whoever owns them.
		wardrobe = wardrobeOwed,
	})
end

--- Asks for the name again now, whatever the retry window said.
-- For a player who dismissed the form and wants it back without waiting.
-- @author dop42
-- @return Result
local function askAgain()
	if citizenId == nil then return Result.Err('no_character') end
	if naming ~= nil then return Result.Err('already_asking') end
	if Character.IsNamed() then return Result.Err('already_named') end
	retryAtMs = 0
	return Result.Ok({ asked = true })
end

-- ── the lifecycle ───────────────────────────────────────────────────────────

--- Renders a refusal code, or names one the catalogues do not carry.
-- The code IS the key: every refusal the server answers is a catalogue key, so
-- there is no table of codes here to fall out of step.
-- @author dop42
-- @param code any
-- @return string
function M.Refusal(code)
	local key = type(code) == 'string' and code or 'error.unavailable'
	if OPX.Locale.Exists(key) then
		-- The name's bounds, for the one sentence that names them.
		local minimum, maximum = nameBounds()
		return locale(key, { min = minimum, max = maximum })
	end
	-- THE CODE GOES TO THE LOG AND NOT ON SCREEN. This sentence used to end in
	-- `({code})`, which put `name_taken_v2` or whatever the server invented in
	-- front of a player who can do nothing with it; the operator who can is the
	-- one reading the client log.
	Open77.log.warn(('[entry] a refusal with no wording reached the player: %s'):format(key))
	return locale('entry.refusal.unknown')
end

--- Builds the held state.
-- @author dop42
function M.Init()
	citizenId, naming, refusal = nil, nil, nil
	creationAsked, creating, running = false, false, false
	retryAtMs, creationRetryAtMs, sentAtMs = 0, 0, 0
	draft = { firstName = '', lastName = '' }
	wardrobeOwed = false
end

--- Publishes what this module knows and what it can be asked to redo.
-- @author dop42
function M.Api()
	OPX.Api.Provide('entry', 1, {
		State = state,
		AskName = askAgain,
	})
end

--- Names a key one catalogue carries and the other does not.
local function compareCatalogs()
	local en, fr = M.Catalogs.en, M.Catalogs.fr
	for key in pairs(en) do
		if fr[key] == nil then Open77.log.warn('[entry] fr is missing ' .. key) end
	end
	for key in pairs(fr) do
		if en[key] == nil then Open77.log.warn('[entry] en is missing ' .. key) end
	end
end

--- Resolves the contracts, wires the events and reads what is already known.
-- @author dop42
function M.Start()
	running = true
	Character = OPX.Api.Require('character')

	-- OPTIONAL, both of them, and the module runs without either: with no
	-- appearance contract a character enters on the default face, and with no form
	-- module nothing asks for a name. Both are said once, at start, because a
	-- missing name has no other symptom.
	Appearance = OPX.Api.Get('appearance')
	if Appearance == nil then
		Open77.log.info('[entry] no appearance contract: a new character enters on the ' ..
			'default face and is never handed to the creator')
	end
	Form = OPX.Api.Get('form')
	if Form == nil then
		Open77.log.warn('[entry] no form module: nothing will ask a new character for a name')
	end

	compareCatalogs()

	AddEventHandler(EVENT_LOADED, onLoaded)
	AddEventHandler(EVENT_CHANGED, onLoaded)
	AddEventHandler(EVENT_UNLOADED, onUnloaded)
	AddEventHandler(EVENT_APPEARANCE, onAppearance)
	AddEventHandler(EVENT_REFUSED, onRefused)

	-- A restart mid-session misses every broadcast and there is no replay, so a
	-- character already loaded is picked up here.
	onLoaded(Character.GetPlayerData())

	OPX.Scheduler.Every('entry:tick', TICK_MS, function()
		local atMs = OPX.Now()
		if creationWanted(atMs) then return openCreator() end
		if nameWanted(atMs) then askName() end
	end)
end

--- Takes the form down and stops asking.
-- @author dop42
function M.Stop()
	running = false
	onUnloaded()
end
