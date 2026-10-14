--- The spawn menu: what the server offered, and what the player clicked.
-- @author dop42
--
-- Nothing here is authoritative. The page is told a list of places to draw and a
-- duration to count down, and it answers with the ID of one of them; every value
-- that decides where a body actually goes is re-derived on the server from its own
-- copy of the same catalogue. A modified client can send any ID it likes and gets
-- either a place the server already knows or a refusal.
--
-- WHY THIS WAITS FOR THE ENTRY MODULE. A brand new character is asked two things
-- at the same moment: the entry module's form, which asks for a name, and this
-- menu, which the server offers the instant the platform announces a living body.
-- Two modals on one keyboard is one modal losing its focus, so with
-- `WAIT_FOR_ENTRY` the menu stands aside while entry is asking something and opens
-- when entry reports itself idle. The deferral cannot strand anyone: the server is
-- counting the same choice down, and its deadline places the body either way.
--
-- AND WHY IT WAITS FOR THE SCREEN. The page takes an open as soon as its surface
-- is up, but nobody can see it yet. At join, the server's loading screen covers
-- every surface until the platform has reset the body. During play, a native
-- load covers it for as long as the load runs. The bot lab, 2026-10-07: the offer
-- came at 11:18:17, but the platform finished its reset at 11:18:27.5 and the
-- loading screen came down at 11:18:27.8. The menu reported itself open, and the
-- server started the window, ten seconds before the player could see it. So with
-- `WAIT_FOR_SCREEN` the menu also waits while a native load is up
-- (`modules/loading`). At join it waits until the platform has finished its first
-- reset of the body. Both waits are bounded by `SCREEN_WAIT_SECONDS`, so a screen
-- that never reports itself clear costs the player that wait, never the choice.

local M = OPX.Modules.Get('spawn')

local LOCAL = OPX.Channel.LOCAL

-- The surface every view on this resource draws on. Both names answer the same
-- page; `interactive` is the one the form module uses for a modal, and the name is
-- now a layer hint rather than a second browser.
local SURFACE = 'interactive'

-- This view's focus owner. The page names the same string when it acquires, and
-- the two have to agree: a name that drifts is a modal nobody can click.
local OWNER = 'spawn'

--- What this module's focus owner is given.
-- The page names an owner and never says what it wants -- asking for the cursor
-- is not the page's decision. The menu is clicked AND arrowed, so it takes both.
local FOCUS = { keyboard = true, cursor = true }

-- The entry module's public local bus, built the same way the module that raises
-- it builds it: a bare name would be a typo waiting to happen.
local EVENT_ENTRY = OPX.Event(LOCAL, 'entry', 'state')

-- The loading module's public local bus: a native load starting or ending.
local EVENT_LOADING = OPX.Event(LOCAL, 'loading', 'state')

-- The platform says it has finished resetting the body it put in the world, or
-- has given up. At join, this event hands the screen over. The server's loading
-- screen stays up, and no resource surface is shown, until it lands. The client
-- log then reads "server WebUI presentation opened:
-- reason=player_bootstrap_complete". These are host-owned names, the same two
-- `modules/appearance` listens to.
local HOST_RESET_COMPLETE = 'open77:playerReset:complete'
local HOST_RESET_FAILED = 'open77:playerReset:failed'

-- The reset phases that mean the reset is over. Any other phase the projection
-- names is a reset still under way. No phase at all means a client that does not
-- project one.
local RESET_OVER = { complete = true, failed = true }

-- How long one offer waits for the screen, in seconds, when the config does not
-- say, and the most the config may set.
local SCREEN_WAIT_DEFAULT_SECONDS = 60
local SCREEN_WAIT_MAX_SECONDS = 120

-- How often the open is re-sent while the page has not taken it yet. The surface
-- is built at boot and this menu arrives much later, so this is a floor rather
-- than the common case -- but it is the one screen the player MUST see, and a
-- dropped open would otherwise cost them the choice.
local UPKEEP_MS = 250

-- How often a join busy ahead of the menu tells the server it still is.
local WAITING_MS = 30000

-- Milliseconds a second click inside is swallowed. The click is a click: two in a
-- flick are one intent, and without this the second one reaches the server after
-- the first has settled and draws a refusal about a choice that went through.
local CLICK_MS = 400

-- The offer the server made and has not settled yet, or nil.
local offer

-- Whether the menu is up.
local open

-- True while the open has not reached the page. Re-sent from the upkeep tick: a
-- send made before the page reports ready is dropped, not queued.
local pendingOpen

-- Whether this offer's arrival has been reported to the server. The clock starts
-- on that report, so it goes out once per offer and never again -- a menu that
-- reported twice would be asking for a longer window than it was given.
local announcedOpen

-- Whether the page channels have been wired. Wiring builds the surface, so it
-- waits for the first offer.
local wired

-- When the last click went out.
local lastClickAt

-- Whether the entry module is asking the player something right now.
local entryWaiting

-- Whether the platform has said, in this resource generation, that its reset of
-- the body is over. After that the reset projection is no longer read. Waiting
-- for the reset is the join's job. A later reset, such as a body reload, runs
-- under a native load, and that load is waited for on its own.
local resetHeard

-- This offer's wait for the screen: when the wait began, whether the last
-- attempt to open stopped on it, and whether it ran out.
local screenSinceMs, screenHeld, screenLapsed

--- Every string this module draws, resolved on the client.
-- Sent with the open rather than looked up per label: the page has no way to ask
-- for one, and the catalogue it does hold is keyed by the player's language.
local function strings()
	return {
		title = locale('spawn.title'),
		about = locale('spawn.about'),
		hint = locale('spawn.hint'),
	}
end

--- A place's words in the player's language: `spawn.place.<id><suffix>` when
--- the catalogue has it, the config's own text otherwise. The config is written
--- in one language, and a French player read "King Stoop forecourt".
local function placeLabel(id, fallback, suffix)
	local key = ('spawn.place.%s%s'):format(tostring(id), suffix or '')
	if OPX.Locale.Exists(key) then return locale(key) end
	return fallback
end

--- Every location, as the page needs it.
-- Label and district only: the coordinates never leave the server's copy of the
-- catalogue in either direction, so there is nothing here for a page to be
-- tempted to act on.
local function places()
	local rows = {}
	-- WHERE I LEFT OFF FIRST, when the server says there is somewhere to go back
	-- to: a card like the others, so the page draws it without knowing it is
	-- special, and the server knows its id.
	if offer ~= nil and offer.resume == true then
		rows[1] = { id = M.RESUME_ID, label = locale('spawn.resume'),
			district = locale('spawn.resumeHint') }
	end
	local catalogue = M.Catalogue()
	for index = 1, #catalogue do
		local point = catalogue[index]
		rows[#rows + 1] = { id = point.id, label = placeLabel(point.id, point.label),
			district = placeLabel(point.id, point.district, '.district') }
	end
	return rows
end

--- Whether the menu may be drawn yet.
local function entryHoldsTheFloor()
	if M.Settings.WAIT_FOR_ENTRY == false then return false end
	-- A world with no entry module never asks anything, so waiting on one would
	-- be waiting for ever.
	if not OPX.Modules.IsRunning('entry') then return false end
	return entryWaiting == true
end

--- Whether a native load is up, as `modules/loading` last read it. A world without
--- that module never waits here, and neither does a client too old to read loads,
--- because there the module reports no load.
local function loadUp()
	if not OPX.Modules.IsRunning('loading') then return false end
	local contract = OPX.Api.Get('loading')
	if type(contract) ~= 'table' or type(contract.State) ~= 'function' then return false end
	local ok, answer = pcall(contract.State)
	if not ok or type(answer) ~= 'table' or answer.ok ~= true or type(answer.value) ~= 'table' then
		return false
	end
	return answer.value.active == true
end

--- Whether the platform's first reset of the body is still under way.
local function resetUnderway()
	if resetHeard then return false end
	local session = type(Open77) == 'table' and Open77.session or nil
	local read = type(session) == 'table' and session.characterBootstrap or nil
	if type(read) ~= 'function' then return false end
	local ok, bootstrap = pcall(read)
	if not ok or type(bootstrap) ~= 'table' then return false end
	local phase = bootstrap.playerReset
	if type(phase) ~= 'string' or phase == '' then return false end
	return not RESET_OVER[phase]
end

--- What is covering the screen, or nil when the player can see it.
local function screenCovered()
	if loadUp() then return 'a native load is up' end
	if resetUnderway() then return 'the platform is still resetting the body' end
	return nil
end

--- How long one offer may wait for the screen, in milliseconds.
local function screenWaitMs()
	local raw = M.Settings.SCREEN_WAIT_SECONDS
	local seconds = raw == nil and SCREEN_WAIT_DEFAULT_SECONDS or M.Number(raw, 5)
	return math.floor(math.min(seconds, SCREEN_WAIT_MAX_SECONDS) * 1000)
end

--- Whether the menu stands aside for the screen right now.
-- Logs once per offer when the wait starts and once when the screen clears, with
-- how long it took. Gives up, with a warning, after `SCREEN_WAIT_SECONDS`.
local function screenHolds()
	if M.Settings.WAIT_FOR_SCREEN == false or screenLapsed then return false end
	local now = OPX.Now()
	local why = screenCovered()
	if why == nil then
		if screenSinceMs ~= nil then
			Open77.log.info(('[spawn] the screen is clear after %.1fs: the menu opens')
				:format((now - screenSinceMs) / 1000))
			screenSinceMs = nil
		end
		return false
	end
	if screenSinceMs == nil then
		screenSinceMs = now
		Open77.log.info(('[spawn] the menu waits for the screen: %s'):format(why))
	elseif now - screenSinceMs >= screenWaitMs() then
		screenLapsed = true
		Open77.log.warn(('[spawn] the screen is still covered after %ds (%s): the menu ' ..
			'opens anyway'):format(math.floor((now - screenSinceMs) / 1000), why))
		return false
	end
	return true
end

--- Puts the open payload on the wire, or answers false while the page is not up.
-- THE WINDOW IS NOT ON IT, and that is deliberate rather than an omission. The
-- page used to be handed the duration so it could draw a countdown beside the
-- title; that countdown was display only -- it reached zero and did nothing,
-- because the server counts the same window against its own clock and only that
-- count ends the choice -- so it put a deadline in front of a one-press decision
-- and bought nothing. Running out is still handled, and always was, by the
-- `spawn:close` the server sends with `reason = 'timeout'`.
local function sendOpen()
	local payload = { locations = places() }
	local labels = strings()
	for key, value in pairs(labels) do payload[key] = value end
	return OPX.UI.Send(SURFACE, 'spawn:open', payload)
end

--- Sends the open, or the same thing again until it lands.
local function draw()
	if not open then return end
	pendingOpen = not sendOpen()
	if not pendingOpen and not announcedOpen then
		-- THE CLOCK STARTS HERE, and nowhere earlier. This is the moment the menu
		-- is on screen, and the server counts the player's window from this report
		-- rather than from when it queued the offer -- otherwise the menu spends
		-- its window standing aside behind the entry module's name form, and the
		-- player is handed the few seconds that are left.
		--
		-- Sent only once per offer, because the server honours only the first
		-- report: a client that says so twice does not get a longer window.
		announcedOpen = true
		TriggerServerEvent(M.Event.OPENED, {})
	end
end

--- Draws the menu, if there is an offer to draw and nothing ahead of it.
local function tryOpen()
	if open or offer == nil then return end
	if entryHoldsTheFloor() then return end
	-- After entry: a question entry is asking is the next screen anyway. The
	-- upkeep tick asks again while this holds, and that is what notices the
	-- screen clear when no event says so, or the wait run out.
	screenHeld = screenHolds()
	if screenHeld then return end

	if OPX.UI.Interactive() == nil then
		-- No surface: the choice cannot be put to the player at all. The server's
		-- deadline is what places them, and this line is the only trace of why
		-- they were never asked.
		Open77.log.error('[spawn] no surface answers: the choice will time out to the ' ..
			'default spawn')
		return
	end

	open = true
	pendingOpen = true
	draw()
	-- After `draw`, so a listener that reads the page sees what is on it. Raised
	-- from here and from `takeDown` and nowhere else: those are the only two
	-- places `open` moves.
	TriggerEvent(M.Event.ON_STATE, { open = true, phase = 'spawn' })
end

--- Takes the menu down and gives the keyboard back.
local function takeDown()
	local was = open
	offer, open, pendingOpen, announcedOpen = nil, false, false, false
	screenSinceMs, screenHeld, screenLapsed = nil, false, false
	OPX.UI.Send(SURFACE, 'spawn:close', {})
	-- Only when there was one. `takeDown` is reached from a close for an offer
	-- that was never drawn and from `Stop`, and an idle said twice is a listener
	-- being told the screen is free by something that never took it.
	if was then TriggerEvent(M.Event.ON_STATE, { open = false, phase = 'idle' }) end
	-- Released here rather than waited for: the page announces the release on
	-- `focus:set` too, but a page that is gone never will, and a focus held across
	-- a close is a player who cannot move.
	OPX.UI.ReleaseFocus(OWNER)
end

--- What the server said about the choice that has just ended.
--
-- TWO OF THEM PER CHOICE. The first takes the menu down before the body moves
-- and says nothing; the second, `result`, says where the body went once it has
-- -- or that it could not be moved. The second never takes a screen down: the
-- respawn may already have brought the next offer.
local function onClosed(payload)
	if type(payload) ~= 'table' then return end
	local reason = payload.reason
	if payload.result ~= true then
		takeDown()
		return
	end
	if payload.placed ~= true then
		OPX.Toast.Locale('spawn.placeFailed', nil, 'error')
		return
	end

	if reason == 'chosen' then
		OPX.Toast.Locale('spawn.placed',
			{ place = placeLabel(payload.placeId, payload.place or '') }, 'success')
	elseif reason == 'resumed' then
		OPX.Toast.Locale('spawn.resumed', nil, 'success')
	elseif reason == 'timeout' then
		OPX.Toast.Locale('spawn.timeout', nil, 'info')
	end
end

--- The offer, or a second one while the first stands.
local function onOffered(payload)
	if type(payload) ~= 'table' then return end
	-- A choice is already up. The server holds one outstanding offer per player,
	-- so a second one is a reconnect or a duplicate inside the window rather than
	-- a normal path -- and replacing the first would move its deadline.
	if offer ~= nil then return end

	-- A MARKER, not a copy of the offer. The payload carries the window the server
	-- granted and nothing here reads it any more: the page draws no clock, and the
	-- window is the SERVER's to count -- see `sendOpen`. What this side needs to
	-- know is only that a choice is outstanding, which is this table existing.
	offer = { resume = payload.resume == true }
	screenSinceMs, screenHeld, screenLapsed = nil, false, false
	tryOpen()
end

--- The player clicked a location.
local function onChoose(payload)
	if not open or type(payload) ~= 'table' then return end
	local id = payload.id
	if type(id) ~= 'string' or id == '' then return end

	local atMs = OPX.Now()
	if lastClickAt ~= nil and atMs - lastClickAt < CLICK_MS then return end
	lastClickAt = atMs

	-- The ID alone. Which place that is, and whether it is a place at all, is the
	-- server's to decide from its own catalogue.
	TriggerServerEvent(M.Event.CHOOSE, { id = id })
end

--- Answers the surface-wide focus broadcast for this module's own owner.
--
-- THE BROADCAST NAMES THE WHOLE STACK'S TOP, NOT JUST "EMPTY OR NOT", and
-- reading only the empty case was the incomplete half of this idiom.
-- `ui/src/bridge/focus.ts` announces on EVERY change to the page's focus stack,
-- carrying the one owner now on top -- so a top that moved from this module's
-- owner to somebody else's arrived here as `focus = true` with another name, and
-- the old shape did nothing at all with it. This module's stale Lua entry then
-- sat above the module actually on screen, and `applyFocus` applied ITS wants
-- over theirs. Six copies of this handler had the same hole; this is the same
-- correction, written for the one owner this module has.
local function onFocus(payload)
	if type(payload) ~= 'table' then return end
	if payload.focus ~= true or payload.owner ~= OWNER then
		OPX.UI.ReleaseFocus(OWNER)
		return
	end
	OPX.UI.AcquireFocus(OWNER, FOCUS)
end

--- Wires the page channels once, on the first offer.
local function wire()
	if wired then return end
	wired = true
	OPX.UI.On(SURFACE, 'spawn:choose', onChoose)
	OPX.UI.On(SURFACE, 'focus:set', onFocus)
end

--- Names a key one catalogue carries and the other does not.
local function compareCatalogs()
	local en, fr = M.Catalogs.en, M.Catalogs.fr
	for key in pairs(en) do
		if fr[key] == nil then Open77.log.warn('[spawn] fr is missing ' .. key) end
	end
	for key in pairs(fr) do
		if en[key] == nil then Open77.log.warn('[spawn] en is missing ' .. key) end
	end
end

--- Builds the held state.
-- @author dop42
function M.Init()
	offer, open, pendingOpen, announcedOpen = nil, false, false, false
	wired, lastClickAt, entryWaiting = false, nil, false
	resetHeard = false
	screenSinceMs, screenHeld, screenLapsed = nil, false, false
end

--- Registers the wire, the entry module's bus and the upkeep pass.
-- @author dop42
function M.Start()
	compareCatalogs()

	RegisterNetEvent(M.Event.OFFER, function(payload)
		wire()
		onOffered(payload)
	end)

	RegisterNetEvent(M.Event.CLOSE, onClosed)

	-- The entry module's own state, which is what says whether a form is up. It is
	-- raised on the LOCAL channel and read with a bare AddEventHandler, the way
	-- anything public on that bus is.
	AddEventHandler(EVENT_ENTRY, function(payload)
		if type(payload) ~= 'table' then return end
		entryWaiting = payload.open == true
		-- A form that has just come down is this menu's turn: the player answered
		-- the question ahead of it, or dismissed it, and either way the choice is
		-- still theirs to make until the server's deadline.
		if not entryWaiting then tryOpen() end
	end)

	-- A load that has just ended may be what the menu was waiting for.
	AddEventHandler(EVENT_LOADING, function(payload)
		if type(payload) ~= 'table' or payload.active == true then return end
		if screenHeld then tryOpen() end
	end)

	-- The platform's reset of the body is over, whichever way it ended. At join
	-- this is the moment the screen is handed over.
	local function resetOver()
		resetHeard = true
		if screenHeld then tryOpen() end
	end
	AddEventHandler(HOST_RESET_COMPLETE, resetOver)
	AddEventHandler(HOST_RESET_FAILED, resetOver)

	-- WHILE THE JOIN IS BUSY AHEAD OF THE MENU, THE SERVER IS TOLD SO, so its
	-- hold on the choice does not run out under the name form, the fitting room
	-- or a loading screen (see `M.Waiting` on the server). Every half minute is
	-- far inside the shortest hold the server allows. This runs on the upkeep job
	-- rather than a job of its own: one comparison does not earn a slot in the
	-- scheduler's rotation.
	local waitedAtMs = nil
	OPX.Scheduler.Every('spawn:upkeep', UPKEEP_MS, function()
		if pendingOpen then draw() end
		-- Asked again while the screen holds the menu: a projection that moves
		-- without an event, and the wait running out, are both seen here.
		if screenHeld and offer ~= nil and not open then tryOpen() end
		if offer ~= nil and not open and (entryWaiting or screenHeld) then
			local now = OPX.Now()
			if waitedAtMs == nil or now - waitedAtMs >= WAITING_MS then
				waitedAtMs = now
				TriggerServerEvent(M.Event.WAITING)
			end
		end
	end)
end

--- Takes the menu down. The choice dies with the resource rather than being
--- half-answered; the server's deadline settles the character.
-- @author dop42
function M.Stop()
	takeDown()
end
