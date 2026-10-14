--- The two views this module owns -- the appearance panel and the fitting room --
--- and the one seam a view module attaches to.
-- @author dop42
--
-- Neither of these drew itself: the panel was a list drawn by a menu resource and
-- the fitting room a page drawn by a panel resource. Both of those resources have
-- since been rebuilt as modules in here, and `client/view.lua` is what attaches
-- the seam below to them -- the panel to `menu`, the fitting room to `panel`. The
-- state machines are here; the drawing is not, and must not be.
--
-- THE JOIN ALSO WAITS ON THIS FILE, which is the one thing here that is not a
-- view. A brand new character is asked for a name, an outfit and a spawn point at
-- one instant, and the order between them is held by each view standing aside for
-- the one in front: `roomOwed` is what this module reports on its decision bus,
-- the entry module folds it into its own "the join is busy", and the spawn menu
-- already waits on that. See `claim`.

local M = OPX.Modules.Get('appearance')

local Snapshot = M.Snapshot
local State = M.Face
local Runtime = M.Runtime
local Clothing = M.Clothing
local Garments = M.Garments

M.Panel = {}
M.Wardrobe = {}
local Panel = M.Panel
local Wardrobe = M.Wardrobe

-- ── the view seam ───────────────────────────────────────────────────────────
-- This module owns the state, the rules and the puppet; it creates no surface.
-- Everything it has to say to whatever draws these two views leaves on
-- `M.Event.ON_VIEW` with a `kind`, and everything a view has to say comes back
-- through the one function `M.FromView`. A view module attaches by listening to
-- the first and calling the second.
--
--   out  kind = 'config'      every string a view draws, sent when it reports ready
--        kind = 'panel'       the panel's rows; draw or redraw it
--        kind = 'panelClosed' take the panel down, with a `reason`
--        kind = 'status'      a transient line under the open panel
--        kind = 'room'        the fitting room's first frame; draw it
--        kind = 'roomState'   the room's sliders, tabs or status line changed
--        kind = 'roomTiles'   one window of the open category's grid: `payload.tiles`
--        kind = 'roomClosed'  take the room down, with a `reason`
--        kind = 'confirm'     ask the player a yes/no question
--
--   in   'ready'              the view can be drawn on; answers config and state
--        'panel.select'       a panel row was chosen: `payload.item`
--        'panel.close'        the player took the panel down: `payload.reason`
--        'room.slide'         a slot's slider moved: `payload.slot`, `payload.index`,
--                             `payload.commit` -- false previews, true chooses
--        'room.tab'           a category was opened: `payload.slot`
--        'room.tiles'         the grid wants the window starting at `payload.from`
--                             of `payload.slot`
--        'room.action'        a button was pressed: `payload.value`
--        'room.dismiss'       the player asked to leave the room
--        'room.confirm'       an answer to a confirm: `payload.item`, `payload.value`
--        'room.close'         the view took the room down: `payload.reason`
--        'diag'               a view-side failure, for the client log

--- Tells whatever draws these views something.
local function publish(kind, payload)
	payload = payload or {}
	payload.kind = kind
	TriggerEvent(M.Event.ON_VIEW, payload)
end

-- Every string a view draws, read from the active catalogue when it reports ready.
local TEXT_KEYS = {
	'appearance.panel.title', 'appearance.panel.looks', 'appearance.panel.openRoom',
	'appearance.panel.bodyType',
	'appearance.panel.savedLook', 'appearance.panel.worn', 'appearance.panel.stored',
	'appearance.panel.none', 'appearance.panel.otherBuild', 'appearance.panel.noLook',
	'appearance.panel.oneLook', 'appearance.panel.wear', 'appearance.panel.editFace',
	'appearance.panel.editHair', 'appearance.panel.editNote', 'appearance.panel.bodyNote',
	'appearance.panel.wearing', 'appearance.panel.wornNow',
	'appearance.panel.alreadyWorn', 'appearance.panel.busy',
	'wardrobe.title', 'wardrobe.ui.heading', 'wardrobe.ui.eyebrow',
	'wardrobe.ui.eyebrowCreation', 'wardrobe.ui.intro', 'wardrobe.ui.introCreation',
	'wardrobe.ui.female', 'wardrobe.ui.male', 'wardrobe.ui.nothing',
	'wardrobe.ui.save', 'wardrobe.ui.saveCreation', 'wardrobe.ui.cancel', 'wardrobe.ui.skip',
	'wardrobe.ui.front', 'wardrobe.ui.left', 'wardrobe.ui.right', 'wardrobe.ui.back',
	'wardrobe.ui.confirmTitle',
	'wardrobe.ui.confirmText', 'wardrobe.ui.confirmTitleCreation',
	'wardrobe.ui.confirmTextCreation', 'wardrobe.ui.confirmYes', 'wardrobe.ui.confirmNo',
}

-- ── the appearance panel ────────────────────────────────────────────────────
-- The frame around the face, not the face: there is no face editor here and there
-- cannot be one. An option is an opaque 64-bit catalogue hash with no human label
-- anywhere on the platform, so the engine's own mirror is the only editor there
-- is and this panel's job is to open it.

-- The module or resource the open panel belongs to, and the panel session, moved
-- on by every open and every close so a stale thread stops.
local panelOwner = nil
local panelSession = 0

--- Whether a panel is up for any caller.
-- @author dop42
-- @return boolean
function M.Panel.IsOpen()
	return panelOwner ~= nil
end

--- The caller the open panel belongs to.
-- @author dop42
-- @return string|nil
function M.Panel.Owner()
	return panelOwner
end

--- Whether a native modal is on screen, an unreadable answer counting as one.
local function nativeUp()
	return State.editing or State.creating or Runtime.ModalOnScreen()
end
M.Panel.NativeUp = nativeUp

--- The player-facing condition of the stored face.
local function storedText()
	if type(State.canonical) ~= 'table' then return locale('appearance.panel.none') end
	if State.Wearing() then return locale('appearance.panel.worn') end
	return locale('appearance.panel.stored')
end

--- The player-facing body family of the character.
local function familyText()
	return State.family ~= nil and Runtime.FamilyText(State.family) or '-'
end

--- The saved-look rows and the two ways into the native editor.
-- A row that cannot be used carries the reason as its value rather than being
-- greyed out with nothing beside it.
local function looksItems()
	local stored = type(State.canonical) == 'table' and State.canonical or nil
	local fits = stored ~= nil and M.BuildAccepted(stored.gameBuild)
	local busy = State.commit ~= nil or nativeUp()

	local blocked
	if stored == nil then
		blocked = locale('appearance.panel.none')
	elseif not fits then
		blocked = locale('appearance.panel.otherBuild')
	elseif State.Wearing() then
		blocked = locale('appearance.panel.worn')
	elseif busy then
		blocked = locale('appearance.panel.busy')
	end

	return {
		{ separator = true, label = locale('appearance.panel.oneLook') },
		{ id = 'saved', label = locale('appearance.panel.savedLook'), value = storedText(),
			disabled = true },
		{ id = 'wear', label = locale('appearance.panel.wear'), value = blocked,
			disabled = blocked ~= nil },
		{ separator = true },
		{ id = 'editFace', label = locale('appearance.panel.editFace'),
			description = locale('appearance.panel.editNote'),
			value = busy and locale('appearance.panel.busy') or nil, disabled = busy },
		{ id = 'editHair', label = locale('appearance.panel.editHair'),
			value = busy and locale('appearance.panel.busy') or nil, disabled = busy },
	}
end

--- The panel's whole content: the three levels and their rows.
local function panelSpec()
	local roomBusy = Wardrobe.IsOpen() or not Clothing.Ready()
	return {
		title = locale('appearance.panel.title'),
		items = {
			{ id = 'looks', label = locale('appearance.panel.looks'), value = storedText(),
				items = looksItems() },
			-- ONE ROW EACH, NOT A LEVEL EACH. `Body` opened a level holding one
			-- disabled row, and `Outfits` a level holding one row whose label was a
			-- sentence: two presses to read a fact and two to open a room.
			-- Stated and not offered: the body family belongs to the character.
			{ id = 'family', label = locale('appearance.panel.bodyType'), value = familyText(),
				description = locale('appearance.panel.bodyNote'), disabled = true },
			{ id = 'wardrobe', label = locale('appearance.panel.openRoom'),
				value = roomBusy and locale('appearance.panel.busy') or nil,
				disabled = roomBusy },
		},
	}
end

--- Redraws the open panel where the player stands in it.
-- @author dop42
function M.Panel.Refresh()
	if panelOwner == nil then return end
	publish('panel', panelSpec())
end

--- Shows a transient status line under the open panel.
local function status(text, ok)
	if panelOwner == nil then return end
	publish('status', { text = text, ok = ok == true })
end

--- Takes the panel down for a reason of this module's own.
-- @author dop42
-- @param reason string
function M.Panel.Close(reason)
	if panelOwner == nil then return end
	panelSession = panelSession + 1
	panelOwner = nil
	publish('panelClosed', { reason = reason })
	Runtime.Publish({ ok = true, event = 'panelClosed', citizenId = State.citizenId,
		reason = reason })
end

--- Puts the panel up for a caller, or redraws it.
-- @author dop42
--
-- One panel at a time, keyed on the caller's own name: a second caller is refused
-- and the owner asking again redraws its own.
-- @param owner string the caller's own name
-- @return boolean
-- @return string|nil the refusal
function M.Panel.Open(owner)
	if type(owner) ~= 'string' or owner == '' then return false, 'invalid_caller' end
	if Runtime.IsDown() then return false, 'player_down' end
	if State.citizenId == nil then return false, 'no_character' end
	if nativeUp() then return false, 'appearance_busy' end
	if panelOwner ~= nil and panelOwner ~= owner then return false, 'panel_busy' end

	if panelOwner == owner then
		Panel.Refresh()
		return true
	end

	panelSession = panelSession + 1
	panelOwner = owner
	publish('panel', panelSpec())
	Runtime.Publish({ ok = true, event = 'panelOpened', citizenId = State.citizenId })
	return true
end

--- Puts the stored face back on the puppet from the panel.
local function wearStored()
	if type(State.canonical) ~= 'table' then
		return status(locale('appearance.panel.noLook'), false)
	end
	if not M.BuildAccepted(State.canonical.gameBuild) then
		return status(locale('appearance.buildMismatch'), false)
	end
	if State.Wearing() then
		return status(locale('appearance.panel.alreadyWorn'), true)
	end
	if State.commit ~= nil or nativeUp() then
		return status(locale('appearance.panel.busy'), false)
	end

	-- Both captured: the wait ends if either the character or its stored face
	-- changed while the mirror was working.
	local snapshot, citizen = State.canonical, State.citizenId
	status(locale('appearance.panel.wearing'), true)
	CreateThread(function()
		local ok, failure = Runtime.ApplySnapshot(snapshot, 8, nil)
		if State.citizenId ~= citizen or State.canonical ~= snapshot then return end
		if ok then State.Wore() end
		Runtime.Publish({ ok = ok, event = 'applied', citizenId = citizen,
			error = (not ok) and tostring(failure) or nil })
		if ok then
			status(locale('appearance.panel.wornNow'), true)
		else
			status(locale('appearance.restoreFailed', { reason = tostring(failure) }), false)
		end
	end)
end

--- Takes the panel down, then asks for the native editor.
-- The panel goes first and is not reopened: the mirror must never be drawn over.
local function openNative(mode)
	Panel.Close('caller')
	local ok, reason = M.Editor.Open(mode)
	if ok then return end
	Runtime.Notify('error', 'appearance.editorUnavailable', { reason = tostring(reason) })
end

--- Runs one pass over an open panel: a native modal or a gone owner closes it.
local function panelTick()
	if panelOwner == nil then return end
	if nativeUp() then return Panel.Close('appearance_busy') end
	if not OPX.Modules.IsRunning(panelOwner) and GetResourceState(panelOwner) ~= 'running' then
		Panel.Close('owner_stopped')
	end
end

-- ── the fitting room ────────────────────────────────────────────────────────
-- It borrows the puppet from the clothing half rather than dressing it behind its
-- back: while the puppet is lent, nothing is saved and no look is published, so a
-- jacket the player is only trying on never reaches the database or anybody else.

-- The seven visible slots the room dresses, in the order the tabs show them, and
-- the nine a put-on states.
local SLOTS = Clothing.OUTFIT_SLOTS
local EQUIPMENT_SLOTS = Clothing.SLOTS

local IS_SLOT = {}
for index = 1, #SLOTS do IS_SLOT[SLOTS[index]] = true end

-- Records asked of the catalogue per slot. `Open77.equipment.records` caps its
-- `limit` at this, so it is the API's ceiling and not a choice of ours -- which
-- is why an answer that REACHES it is written to the journal below: a truncation
-- nobody is told about is the class of defect this room was.
local RECORD_LIMIT = 2000

-- Catalogue entries handled between two frames.
--
-- THE NUMBER THIS WHOLE EPISODE WAS ABOUT, and the owner is the one who found
-- it: their client raised `Open77 script execution budget exceeded` at the
-- `readCatalogue` call. That error is written on the PLAYER'S machine and never
-- reaches the server journal, which is why five diagnoses ran on a silence that
-- was not silent at all -- somebody was just reading it in the wrong place.
--
-- `readCatalogue` yielded once per SLOT, so one slot's work had to fit in one
-- resume: up to 2000 records filtered, sorted, then indexed twice. The largest
-- slot is around 650 and that is already past the per-resume budget. Exceeding
-- it "unwinds straight out of the coroutine body -- it does not crash the
-- resource, it does not repeat, and it logs nothing" (`core/client/scheduler.lua`).
-- So `begin` never returned, `phase` stayed 'opening', and the fitting room was
-- a feature that silently did not exist.
--
-- 64 is deliberately small. The cost of an extra frame here is invisible -- the
-- room is opening, the player is looking at a loading world -- and the cost of
-- being wrong the other way is this bug.
local CATALOGUE_CHUNK = 64

-- Milliseconds between two tries at opening the room after a creation, and how
-- long a kept outfit's save is listened for.
local RETRY_MS = 500
local SAVE_WAIT_MS = 30000

-- How long `begin` may be part way through before the upkeep pass decides its
-- thread is gone.
--
-- THIS IS WHAT IS LEFT OF THE LOADING DEADLINE, and it is pointed at the risk
-- that is still here rather than at the one that was. The room used to stream a
-- formatted catalogue to the page over some sixty resumes and could die in any
-- of them, silently, leaving a spinner; it now reads seven slot queries in seven
-- and publishes one finished frame, so there is no loading state left to be
-- stuck in. What remains is `begin` itself, which runs on a coroutine and holds
-- `phase = 'opening'` while it works: a resume that unwinds there leaves the
-- room neither open nor closed and every later open refused `wardrobe_busy` for
-- the session. Checked from the UPKEEP pass for the same reason as before -- it
-- is the thing that still runs when the thread is what went.
-- RAISED WITH THE CHUNKING ABOVE. The catalogue now takes a frame per 64
-- entries instead of one per slot -- roughly a hundred frames rather than seven
-- -- and those frames are spent during the world load, where a frame is not
-- 16 ms. Ten seconds was a comfortable ceiling for the old shape and a trap for
-- this one: it would fire on an open that was working. The watchdog exists to
-- unstick `phase`, not to race the thing it is watching.
local OPENING_DEADLINE_MS = 25000

-- Degrees one turn of the camera moves.
local TURN_DEGREES = 45

-- Shipped WARDROBE.CREATION_WAIT_MS, for a configuration that lost it.
local CREATION_WAIT_MS = 60000

--- Whether the join's name form is up, read off the entry contract.
-- Without the contract nobody is being asked for a name.
local function joinIsNaming()
	local entry = OPX.Api.Get('entry')
	if entry == nil or type(entry.State) ~= 'function' then return false end
	local read, answer = pcall(entry.State)
	return read and type(answer) == 'table' and answer.ok == true
		and type(answer.value) == 'table' and answer.value.naming == true
end

-- Refusals that mean 'not yet' while a created character settles.
local RETRYABLE = {
	clothing_not_ready = true,
	clothing_saving = true,
	player_unavailable = true,
	player_down = true,
	input_captured = true,
	no_view = true,
	-- RETRIED, AND ITS CLOCK DOES NOT RUN -- see `awaitRoom`. The spawn selector
	-- gives the player forty-five seconds to choose and the room's own window is
	-- sixty, so a room that merely waited would be timed out by somebody else's
	-- deliberation rather than by anything about the room.
	spawn_up = true,
}

-- closed, opening while the puppet is asked for, or open; and the room
-- generation, so a stale opening or catalogue stream stops.
local phase = 'closed'
local generation = 0

-- The module or resource the open room belongs to.
local roomOwner = nil

-- The nine slots the puppet wore when the room opened, and the nine the player
-- chose. The difference between them is what `save` means.
local baseline, draft = nil, nil

-- The slot and the record put on over the draft without being chosen, or nil for
-- nothing tried on.
--
-- THE SLOT IS HALF OF THE KEY AND HAS TO BE. The record may legitimately be
-- `false` -- a slider standing on 0 is a preview of an EMPTY slot, which is a
-- thing to try on like any other -- so a record alone cannot say whether
-- anything is being tried, and two slots previewing `false` in turn would read
-- as the same preview twice.
local hoverSlot, hoverRecord = nil, nil

-- THE CATALOGUE, AND IT IS NOT A LIST OF ROWS. Per visible slot: the record
-- names this body may wear, sorted; where that slot's slider is standing, 0 for
-- nothing; and the label under it. Plus two reverse lookups -- record to its
-- slot, and record to its position in that slot's list -- because both the
-- put-on check and the slider need to go the other way in constant time.
--
-- `shownName` IS FORMATTED WHEN THE SLIDER MOVES AND AT NO OTHER TIME. It is the
-- only human-readable string this room produces once it is open, and holding it
-- rather than computing it in `roomState` is what keeps a publish free of
-- `title`: the room publishes its whole state on every move, and formatting
-- seven labels to change one is seven times the work for no answer anybody reads.
local pieces, shown, shownName = {}, {}, {}
local known, at = {}, {}

-- The category the player has open, and how far down its grid they have asked to
-- see. `category` is one of `SLOTS`; `tileTo` is the LAST index the page has been
-- sent for it.
--
-- WHY THE ROOM HOLDS A SCROLL POSITION AT ALL, given that nothing else about the
-- page is its business. The screen is no longer seven tracks along the bottom: it
-- is one category at a time, drawn as a grid of boxes the player scrolls, which
-- is what the owner asked for -- "des box avec l'image du vetement uniquement, de
-- sorte a rendre le choix plus facile". A grid needs NAMES, and the largest
-- category is 677 of them. Sending all 677 is the stream this room was rewritten
-- to delete; sending none is a grid of blanks. So the page is sent a WINDOW and
-- asks for the next one when it reaches the bottom of what it has, and this is
-- how far that has got. It is reset whenever the category changes, because the
-- new grid starts at the top.
--
-- THE SLIDER MECHANISM IS UNTOUCHED UNDERNEATH. A box carries the index it would
-- have had on the track, a press comes back as the same `slide` a thumb sends,
-- and `slide` still turns an index into a record against the list THIS side
-- holds. The grid is a new way to point at a position, not a new way to choose.
local category, tileTo = nil, 0

-- The status line under the grid, whether this room follows a creation, the
-- character the puppet was lent for, and the family the catalogue is read for.
local statusText, creating, citizen, family = nil, false, nil, nil

-- Whether the room turned the active outfit off, the perspective requested before
-- it took the camera, and the camera's orbit in degrees.
local outfitCleared, savedPerspective, orbit = false, nil, 180

-- The field of view the player had before the room widened it, or nil when the
-- room never touched it. Read from `Open77.camera.view` rather than assumed, so
-- a player running a custom FOV gets their own value back and not ours.
local savedFov = nil

-- Whether the room took the camera off the body with `Open77.camera.detach`.
--
-- A FLAG AND NOT A RE-READ, because there is nothing to read: the platform will
-- say where the camera IS, not who moved it, and a room that put the camera back
-- on the strength of "it looks detached" would fight any other resource that had
-- detached it for its own reasons. This is set by the one call that detaches and
-- cleared by the one that undoes it, so the room only ever puts back what it
-- itself took.
local detached = false

-- The category buttons other modules have offered this room, keyed by the name
-- of the module that offered them, and the flattened row the view is sent.
--
-- OFFERED INWARDS, WHICH IS THE ONLY DIRECTION THAT WORKS. Saved outfits and
-- share codes live in `modules/shops` -- the table, the codes and the job gate
-- are all there -- and `shops` already REQUIRES `appearance` for the fitting
-- room. Reaching back the other way for its outfit list would be a dependency
-- cycle between two modules the registry starts in one order. So the room offers
-- a strip and `shops` fills it: this half knows only that somebody has rows and
-- wants to be told when one is pressed, and could not name an outfit if it tried.
local groupsBy, groupRows = {}, {}

-- WHAT THE ROOM COSTS SO FAR, asked of whoever prices it: `{ owner, fn }`, where
-- `fn(slots, draft)` answers the sentence the status line shows (or nil for
-- none). The room showed no price anywhere, so the first amount a player saw
-- was "Paid X". Dropped with the room, like the strip.
local pricer = nil
local priceLine

-- When the server was last told the room is still up, and how often it is.
local ROOM_ALIVE_MS = 120000
local roomAliveAtMs = -math.huge

-- Creation handoff generation, so an older wait stops, and the kept outfit whose
-- save is listened for.
local creationWatch, awaitSave = 0, nil

-- Whether the spawn selector owns the screen right now.
--
-- THE JOIN HAS THREE SCREENS AND THEY WERE NEVER SEQUENCED. `modules/spawn`
-- already writes this problem down in its own manifest, about the other two:
-- "a brand new character is asked for a name and a spawn at the same moment,
-- and two modals on one keyboard is one modal losing its focus". The fitting
-- room is the third, and nothing ordered it against the spawn menu -- so a
-- creation offered its room into a screen that was already up, every time.
--
-- Tracked rather than asked, because `spawn` publishes the state and exposes no
-- reader; the event is on the local bus and carries `{ open, phase }`.
local spawnUp = false

-- The character the live retry watch is owed to, or nil when none is running.
-- Read by the `characterChanged` handler, which otherwise cannot tell the
-- character it is ANNOUNCING from a different one ARRIVING -- see the comment
-- there, and `WORLD_READY` below it for the same mistake one event over.
local watchCitizen = nil

-- When `begin` stops being allowed to still be working, or 0 when nothing is
-- opening.
local openingUntilMs = 0

-- HOW FAR `begin` GOT, for the watchdog below it. The 10 s watchdog has now
-- fired on a real creation -- "the fitting room never finished opening after
-- 10000 ms" -- which proves the open enters and never completes, but says
-- nothing about where. `begin` has a dozen steps and exactly one of them yields
-- (`readCatalogue`, a frame per slot), so naming the step turns the next
-- occurrence from a fact into a location.
local openingStage = nil

-- This module's own name when it opens the room for the JOIN rather than for a
-- caller. `Clothing.BeginPreview` refuses an unnamed borrower and the upkeep pass
-- closes a room whose owner has stopped, so the borrow has to be under a name the
-- registry knows -- and until this constant existed the join-time open passed
-- `M.Id`, which nothing ever assigns: the registry hands a module a namespace
-- carrying `Settings` and the four phase functions and no id at all. Every
-- fitting room a creation ever asked for was therefore refused with
-- `invalid_caller` before it reached the puppet, once, silently, because that
-- code is not retryable.
local OWNER = 'appearance'

-- Whether this world entry has already been offered a fitting room, and whether
-- one is still owed to the player.
--
-- THE SECOND IS THE JOIN SEQUENCE'S ONLY HANDLE ON THIS MODULE. A brand new
-- character is asked three things at one instant -- a name, an outfit and a
-- spawn point -- and the order between them is not held by a scheduler anywhere:
-- each view stands aside while the one before it reports itself busy. `owed` is
-- what this module reports, from the moment the policy says a room is coming
-- until the room has closed or been given up on, and it covers the gap the room
-- being OPEN does not: the retry window, where the room is owed and nothing is
-- on screen, is exactly when the spawn menu would otherwise take the keyboard
-- and make the room unopenable for the rest of the window.
local roomOffered, roomOwed = false, false

-- A CREATION'S ROOM THAT RAN OUT OF ITS WINDOW WITHOUT EVER OPENING:
-- `{ citizenId, reason, resumed }`, or nil for no such thing.
--
-- AN EXPIRY IS NOT A POLICY DECISION, and holding nothing to say which one
-- happened is how the two were confused on the wire. Under 'first' the policy
-- test reads a single boolean -- was this a creation -- so the offer that comes
-- round again after an expiry answers "the policy is first and this is not a
-- creation", which is a sentence about the OPERATOR'S CHOICE describing a
-- timeout. Measured on 2026-09-20: owed to ZXX-GAE6 at 14:47:57, declined as
-- "not a creation" at 14:48:10, same character, same join, same creation.
--
-- `resumed` is what keeps this from being a loop: a resumed offer that expires
-- again is recorded, reported and never resumed a second time.
local roomExpired = nil

--- Whether the room is up or opening.
-- @author dop42
-- @return boolean
function M.Wardrobe.IsOpen()
	return phase ~= 'closed'
end

--- Whether the open room follows a character creation.
-- @author dop42
-- @return boolean
function M.Wardrobe.Creation()
	return creating
end

--- Whether the join is still owed a fitting room nobody has closed yet.
-- True from the moment the policy says one is coming until it has been closed or
-- given up on -- open or not. Read by anything sequencing the join.
-- @author dop42
-- @return boolean
function M.Wardrobe.Owed()
	return roomOwed
end

--- Says on the public bus that a fitting room is owed, or is not any more.
-- One event with two states rather than two events: a listener holding a boolean
-- wants one name to watch, and a pair would have to be kept in step by whoever
-- reads them. Deduplicated, because it is reached from a retry loop.
-- @param owed boolean
-- @param reason string|nil why it is no longer owed
local function claim(owed, reason)
	if roomOwed == owed then return end
	roomOwed = owed
	Runtime.Publish({ ok = owed, event = 'wardrobeWanted', citizenId = State.citizenId,
		error = (not owed) and tostring(reason or 'done') or nil })
end

--- The caller the open room belongs to.
-- @author dop42
-- @return string|nil
function M.Wardrobe.Owner()
	return roomOwner
end

--- The display name of a record: its own item name when the garment data has one
--- (`client/garments.lua`), and otherwise the record made readable --
--- `Items.Jacket_01_basic` reads 'Jacket 01 basic'. A player choosing a jacket is
--- looking for "Kitsch bomber", not for a TweakDB id, and the id is all the
--- engine's catalogue answers.
--
-- KEPT ONCE MADE. A caption is asked for on the scroll path, sixty to a window,
-- and the readable fallback is three `gsub`s; the cache is bounded by the
-- catalogue (about two thousand records) and never wrong, because neither the
-- data nor a record name changes while the resource runs.
local captions = {}

local function title(record)
	local known = captions[record]
	if known ~= nil then return known end
	local named = Garments.Describe(record, family)
	if named == nil then
		local text = tostring(record):gsub('^Items%.', ''):gsub('_', ' '):gsub('(%l)(%u)', '%1 %2')
		named = OPX.String.Trim((text:gsub('%s+', ' ')))
	end
	captions[record] = named
	return named
end

--- Whether the puppet is alive on foot in the world and the player is not down.
local function playable()
	if Runtime.IsDown() then return false end
	local character = Open77.character
	if type(character) ~= 'table' or type(character.state) ~= 'function' then return false end
	local read, value = pcall(character.state)
	if not read or type(value) ~= 'table' then return false end
	if value.attached == false or value.alive ~= true then return false end
	-- Never in a vehicle: the room turns the body around in front of a camera.
	if type(value.vehicle) == 'table' and value.vehicle.mounted then return false end
	return true
end

-- Reasons `refusal()` has already named this world entry, so a gate polled four
-- times a second costs one journal line rather than a note budget.
local refusalTold = {}

--- Forgets what the gate has reported, for a new world entry.
local function forgetRefusals()
	refusalTold = {}
end

--- Why the room cannot open now, or nil.
---
--- EVERY BRANCH REPORTS ITSELF, once. This gate is the first line of `begin`,
--- and until now a refusal here returned with nothing written anywhere: the
--- journal showed a room owed, the clothes going on, and then silence, because
--- the retry was being turned away by a door that never said which one it was.
--- That is the shape of failure this whole module has now been debugged out of
--- three times, and the cure each time was a line naming the clause.
---
--- `input_captured` is the one to suspect first, and it is worth knowing why.
--- `OPX.Lib.Input.IsCaptured` answers CAPTURED when its own read raises -- the
--- safe value for a keybind, because a key firing while another surface owns
--- the keyboard types into somebody else's box. For this gate that safe value
--- is the blocking one: it means the room can never open. The library is right
--- and so is this caller; they just want opposite defaults, which is exactly
--- why `modules/animations/client/keys.lua` keeps a local reader of its own.
-- @return string|nil
local function refusal()
	local why = nil
	if phase ~= 'closed' then why = 'wardrobe_busy'
	elseif type(Open77.equipment) ~= 'table' or type(Open77.equipment.apply) ~= 'function' or
		type(Open77.equipment.records) ~= 'function' then why = 'equipment_api_unavailable'
	elseif Runtime.IsDown() then why = 'player_down'
	elseif not playable() then why = 'player_unavailable'
	elseif spawnUp then why = 'spawn_up'
	elseif OPX.Lib.Input.IsCaptured() then why = 'input_captured'
	end

	if why ~= nil and not refusalTold[why] then
		refusalTold[why] = true
		Runtime.Note(('the fitting room cannot open: %s'):format(why))
	end
	return why
end

--- The nine equipment slots of a clothing record, false for empty.
local function slotsOf(clothing)
	local equipment = type(clothing) == 'table' and type(clothing.equipment) == 'table' and
		clothing.equipment or {}
	local out = {}
	for index = 1, #EQUIPMENT_SLOTS do
		local slot = EQUIPMENT_SLOTS[index]
		local item = equipment[slot]
		out[slot] = type(item) == 'string' and item ~= '' and item or false
	end
	return out
end

--- A shallow copy of a slot table.
local function copy(slots)
	local out = {}
	for slot, item in pairs(slots) do out[slot] = item end
	return out
end

--- Whether the player chose something other than what was worn when it opened.
--- Which slots the draft moved, in the canonical order.
--
-- PUBLISHED ON `wardrobeClosed`, because a caller that wants to BILL for a
-- change cannot work this out for itself: the baseline and the draft live here
-- and are gone the moment the room closes. A clothing shop asking "what did
-- they change" from outside would have to re-read the body and race the save.
--
-- `outfitCleared` is not a slot and is deliberately not folded in here. It says
-- a covering wardrobe outfit was switched off, which is a change -- `changed`
-- below still answers true for it -- but it is not a garment anybody bought.
local function changedSlots()
	local moved = {}
	if baseline == nil or draft == nil then return moved end
	for index = 1, #EQUIPMENT_SLOTS do
		local slot = EQUIPMENT_SLOTS[index]
		if baseline[slot] ~= draft[slot] then moved[#moved + 1] = slot end
	end
	return moved
end

local function changed()
	if baseline == nil or draft == nil then return false end
	if outfitCleared then return true end
	return #changedSlots() > 0
end

--- The status line's price, from the room's pricer, or nil.
-- Asked on every state the room publishes, which is a change, not a frame.
priceLine = function()
	if pricer == nil or draft == nil then return nil end
	local ran, text = pcall(pricer.fn, changedSlots(), draft)
	if not ran then
		Runtime.Note(('the %s pricer raised: %s'):format(pricer.owner, tostring(text)))
		return nil
	end
	if type(text) ~= 'string' or text == '' then return nil end
	return { text = OPX.Text.Bytes(text, 120), kind = 'info' }
end


--- States the nine slots on the puppet, turning a covering outfit off first.
local function putOn(slots)
	local wardrobe = Open77.wardrobe
	if not outfitCleared and type(wardrobe) == 'table' and type(wardrobe.active) == 'function' then
		local read, active = pcall(wardrobe.active)
		if read and type(active) == 'number' then
			local called, ok, reason = pcall(wardrobe.activate, false)
			if not called then return false, tostring(ok) end
			if not ok then return false, tostring(reason or 'outfit_not_cleared') end
			outfitCleared = true
		end
	end
	local called, ok, reason = pcall(Open77.equipment.apply, slots, { allowRestricted = true })
	if not called then return false, tostring(ok) end
	if not ok then return false, tostring(reason or 'apply_failed') end
	return true
end

--- The draft with one piece in its slot, uncovered by a full-body suit.
local function wearing(slot, record)
	local wanted = copy(draft)
	wanted[slot] = record
	if slot ~= 'Outfit' and record ~= false then wanted.Outfit = false end
	return wanted
end

--- States the camera's orbit around the puppet; the host may have reset its rig.
-- NOT the library's camera module, and the manifest is the reason. That one
-- wraps the `camera.script` rig -- create, attach, shake, the held shot -- and
-- never touches `orbit`, which belongs to the `camera.preview` family. Adopting
-- it would oblige this resource to declare `camera.script` for natives it does
-- not call. `Native` is the half that does apply: one lookup-and-guard written
-- once, and a `permission_denied` rewritten into the line to add.
local function orbitCamera()
	return OPX.Lib.Native.Call('camera.orbit', 'camera.preview', orbit).ok
end

--- Whether this client can orbit the camera around the puppet.
local function hasOrbit()
	return OPX.Lib.Native.Reach('camera.orbit') ~= nil
end

--- Whether this client can take the camera off the body and frame the puppet.
local function hasDetach()
	return OPX.Lib.Native.Reach('camera.detach') ~= nil
end

--- Whether the room can point its view at the puppet from a chosen side at all.
-- EITHER MECHANISM COUNTS, which is why this is not `hasOrbit` any more. A build
-- that can detach turns the puppet by moving the camera around it and never
-- touches `orbit`; a build that cannot falls back to the yaw. The turn buttons
-- are drawn when either one is there, and used to be drawn only for the yaw --
-- so on a host with `detach` and no `orbit` the room silently lost them.
local function canTurn()
	return hasOrbit() or hasDetach()
end

--- The WARDROBE block of this module's settings, never nil.
local function wardrobeConfig()
	return type(M.Settings.WARDROBE) == 'table' and M.Settings.WARDROBE or {}
end

--- WARDROBE.CAMERA_FOV, or nil to leave the player's lens alone.
local function wardrobeFov()
	local wanted = tonumber(wardrobeConfig().CAMERA_FOV)
	-- The platform validates the degrees itself; this only refuses a value that
	-- is not a number at all, so a mistyped config leaves the lens untouched
	-- rather than sending nonsense at the backend once per room.
	if wanted == nil or wanted < 5 or wanted > 170 then return nil end
	return wanted
end

-- How far from the puppet a configured offset may put the camera, in metres. A
-- BOUND ON A TYPO AND NOTHING ELSE: `Open77.camera.detach` is happy to place the
-- view in the next district, and a stray zero in `CAMERA_OFFSET` would then look
-- exactly like the room failing to open -- a black frame with a working menu on
-- it. Twelve metres is further back than any clothing shot wants and near enough
-- that the puppet is still on screen.
local FRAMING_REACH = 12.0

-- The orbit the configured offset is written for. `CAMERA_OFFSET.Y` is metres IN
-- FRONT of the puppet, and the room's own `orbit` calls the front 180 -- because
-- orbit is a yaw against a rig that sits BEHIND the player and 180 swings it
-- round. So the rotation applied below is `orbit - FRAMING_FRONT`, which is zero
-- for the front view and leaves the configured numbers meaning what they say.
local FRAMING_FRONT = 180

--- Where the camera stands to see the puppet from `degrees` around it.
-- @author dop42
--
-- PURE, AND SEPARATE FROM THE NATIVE, because this is the arithmetic that was
-- wrong and arithmetic is the one part of a camera a test can hold. It answers
-- an offset in the puppet's own space -- X across, Y in front, Z up -- or nil
-- when the operator has said not to move the camera at all.
--
-- THE TURN IS A ROTATION OF THE OFFSET, not a yaw of a rig. Once the camera is
-- off the body there is no third-person rig left for `camera.orbit` to yaw, so
-- the front/left/right/back buttons walk the camera around the puppet instead:
-- the offset is rotated about the puppet's own up axis by however far round the
-- room has been turned. Z is untouched -- turning around somebody does not
-- change how high you are standing.
-- @param config table|nil the WARDROBE settings block
-- @param degrees number|nil the room's orbit, 180 being the front
-- @return number|nil x, number y, number z
function Wardrobe.Framing(config, degrees)
	if type(config) ~= 'table' then return nil end
	local offset = config.CAMERA_OFFSET
	if type(offset) ~= 'table' then return nil end

	local x, y, z = tonumber(offset.X), tonumber(offset.Y), tonumber(offset.Z)
	-- ALL THREE OR NONE. A half-written offset is a mistake and not a request for
	-- two of the axes: filling the third in with a zero would answer a shot
	-- nobody asked for, and the operator would have no way to tell which of the
	-- three numbers the runtime actually read.
	if x == nil or y == nil or z == nil then return nil end
	if math.abs(x) > FRAMING_REACH or math.abs(y) > FRAMING_REACH or
		math.abs(z) > FRAMING_REACH then
		return nil
	end

	-- A camera standing INSIDE the puppet is not a shot, it is the bug with extra
	-- steps, so an all-but-zero offset is read as "leave the camera on the body"
	-- and takes the lens-widening fallback instead of rendering the inside of
	-- somebody's chest.
	if math.abs(x) < 0.01 and math.abs(y) < 0.01 and math.abs(z) < 0.01 then return nil end

	local radians = math.rad((tonumber(degrees) or FRAMING_FRONT) - FRAMING_FRONT)
	local cos, sin = math.cos(radians), math.sin(radians)
	return x * cos - y * sin, x * sin + y * cos, z
end

--- Puts the camera where the framing says, for the orbit the room is on.
-- Answers whether the camera is now off the body.
local function standCamera()
	local x, y, z = Wardrobe.Framing(wardrobeConfig(), orbit)
	if x == nil then return false end

	-- THE ANSWER IS CHECKED, and it is the one answer in this file that has to
	-- be. A refused detach is the difference between the centred shot the owner
	-- asked for and the off-centre one they reported, and it is otherwise
	-- completely silent -- the room still opens, the sliders still work, and the
	-- character is still standing in the wrong third of the screen.
	local moved = OPX.Lib.Native.Call('camera.detach', nil, x, y, z)
	if not moved.ok then
		-- Once per room and not once per turn: `detached` is already true by the
		-- time a turn button is pressed, so a refusal here on a later call leaves
		-- the camera where it was rather than re-announcing itself every press.
		if detached then return true end
		Open77.log.warn(('[appearance] the fitting room could not stand the camera ' ..
			'off the body (%s); falling back to a wider lens'):format(tostring(moved.error)))
		return false
	end
	detached = true
	return true
end

--- Points the room's view at the puppet from whichever side `orbit` names.
-- The dolly first, the yaw only when there is no dolly: see `Wardrobe.Framing`.
local function faceCamera()
	if standCamera() then return true end
	return orbitCamera()
end

--- Remembers the perspective, goes third person and frames the puppet.
local function holdCamera()
	orbit = FRAMING_FRONT

	-- THIRD PERSON FIRST. `detach` moves the view off the body; the perspective
	-- is what decides there is a body to look at in the first place, and a room
	-- that detached out of a first-person view would frame a puppet the client
	-- was not drawing.
	local perspective = Open77.perspective
	if type(perspective) == 'table' then
		local requested
		if type(perspective.state) == 'function' then
			local read, value = pcall(perspective.state)
			if read and type(value) == 'table' then requested = value.requested end
		end
		if requested == nil and type(perspective.get) == 'function' then
			local read, value = pcall(perspective.get)
			if read then requested = value end
		end
		savedPerspective = requested
		if type(perspective.set) == 'function' then pcall(perspective.set, 'tps') end
	end

	-- THE LENS IS ONLY WIDENED WHEN THE CAMERA COULD NOT STAND BACK, and that
	-- ordering is the fix. Widening used to be unconditional and was the whole of
	-- the framing; on a rig still pinned over the player's shoulder it pushed the
	-- character further towards the edge rather than nearer the middle, which is
	-- the defect that was reported. A camera that really has stood back needs no
	-- help from the lens, so the player's own FOV is left exactly alone -- and
	-- `savedFov` stays nil, which is what tells the way out not to touch it.
	if not standCamera() then
		local fov = wardrobeFov()
		if fov ~= nil then
			-- Read first so the player's own value goes back exactly on the way out,
			-- rather than being restored to a guess.
			local view = OPX.Lib.Native.Call('camera.view', nil)
			savedFov = view.ok and type(view.value) == 'table' and tonumber(view.value.fov) or nil
			OPX.Lib.Native.Call('camera.setFov', nil, fov)
		end
		orbitCamera()
	end
end

--- Puts the camera back on the body and the remembered perspective back on.
local function freeCamera()
	-- THE SAME NATIVE PUTS IT BACK, with a zero offset: the puppet's own space
	-- offset by nothing IS the body, so this is "the camera goes back where it
	-- was" written in the only call that needs no permission. The inverse the
	-- platform names for it -- `Open77.camera.attach()` with no arguments -- is
	-- gated on `camera.script`, and a room that had to ask for a permission in
	-- order to LET GO of the view is a room that can strand a player behind a
	-- camera they cannot get out from behind. Guarded on the flag so a room that
	-- never moved the camera does not move it on the way out.
	if detached then
		OPX.Lib.Native.Call('camera.detach', nil, 0.0, 0.0, 0.0)
		detached = false
	end
	-- The answer is dropped on purpose: this runs on the way out, and there is
	-- nothing a caller could do about a preview it has already stopped wanting.
	OPX.Lib.Native.Call('camera.clearOrbit', 'camera.preview')
	-- The player's own lens, read on the way in rather than assumed. Nil means
	-- the room never touched it -- which is now the ordinary case, because a
	-- camera that stood back never widened anything -- or the read failed, and in
	-- both cases leaving it alone is right: the room does not know what to put back.
	if savedFov ~= nil then
		OPX.Lib.Native.Call('camera.setFov', nil, savedFov)
		savedFov = nil
	end
	local perspective = Open77.perspective
	if savedPerspective ~= nil and type(perspective) == 'table' and
		type(perspective.set) == 'function' then
		pcall(perspective.set, savedPerspective)
	end
	savedPerspective = nil
end

--- Stands one slot's slider on an index and formats the label under it.
-- The one place `title` is called after the room has opened. See `shownName`.
local function place(slot, index)
	shown[slot] = index
	local record = index > 0 and pieces[slot][index] or nil
	shownName[slot] = record ~= nil and title(record) or locale('wardrobe.ui.nothing')
end

-- How many category rows one module may put on the strip, and how many
-- characters one of their labels may be. THE STRIP IS A ROW OF BUTTONS ACROSS
-- THE TOP OF A PANEL, not a menu: past about half a dozen it wraps into a second
-- line and stops reading as one control. Bounded here rather than trusted,
-- because the offer comes from another module and a module with a loop in it
-- would otherwise push a thousand buttons through `roomState` on every slider
-- move -- which is the publish this room was rewritten to keep cheap.
local MAX_GROUPS, MAX_GROUP_LABEL = 6, 32

-- Forward-declared because `OfferGroups` below has to republish the room and
-- `refresh` is written further down, next to the state it sends. A STRIP THAT IS
-- STORED AND NOT PUBLISHED IS A STRIP NOBODY EVER SEES, and that is not
-- hypothetical: the offer lands AFTER the room has drawn its first frame, always
-- -- `shops` cannot offer until it hears `wardrobeOpened`, and the room publishes
-- that only once the frame has gone out -- so without this the categories would
-- have appeared on the second fitting and never on the first.
local refresh

--- Flattens the offered categories into the row the view is sent.
-- Sorted by the offering module's name so two modules offering rows produce the
-- same strip on every boot; a strip that reordered itself between two opens
-- would move a button out from under a player's cursor for no reason.
local function rebuildGroups()
	local owners = {}
	for owner in pairs(groupsBy) do owners[#owners + 1] = owner end
	table.sort(owners)

	local rows = {}
	for index = 1, #owners do
		local offered = groupsBy[owners[index]]
		for entry = 1, #offered do rows[#rows + 1] = offered[entry] end
	end
	groupRows = rows
end

--- Offers the open room a strip of category buttons under one module's name.
-- @author dop42
--
-- Replaces whatever that module offered before, so the caller states its whole
-- strip every time rather than having to withdraw a row it no longer wants. An
-- empty list is how a module takes its strip down.
-- @param owner string the offering module's own name
-- @param groups table|nil an array of { id, label, disabled }
-- @return boolean, string|nil
function Wardrobe.OfferGroups(owner, groups)
	if type(owner) ~= 'string' or owner == '' then return false, 'invalid_caller' end
	if groups ~= nil and type(groups) ~= 'table' then return false, 'invalid_groups' end

	local offered = groups or {}
	local kept = {}
	for index = 1, math.min(#offered, MAX_GROUPS) do
		local row = offered[index]
		local id = type(row) == 'table' and row.id or nil
		local label = type(row) == 'table' and row.label or nil
		-- ID AND LABEL BOTH, OR THE ROW IS DROPPED. An id-less button cannot be
		-- reported back when it is pressed and a label-less one is a blank
		-- rectangle the player is invited to click: neither is worth drawing, and
		-- dropping the row is better than drawing a broken one over a room that
		-- otherwise works.
		if type(id) == 'string' and id ~= '' and type(label) == 'string' then
			label = OPX.String.Trim(label)
			if label ~= '' then
				kept[#kept + 1] = {
					-- NAMESPACED BY ITS OFFERER, so two modules may both call a button
					-- `save` and the press still reaches the right one. The caller never
					-- sees this: it is unwrapped again before the press is reported.
					id = owner .. ':' .. id,
					label = OPX.Text.Bytes(label, MAX_GROUP_LABEL),
					disabled = row.disabled == true,
				}
			end
		end
	end

	if #kept == 0 then groupsBy[owner] = nil else groupsBy[owner] = kept end
	rebuildGroups()
	-- Published straight away, because the offer always arrives after the frame.
	refresh()
	return true
end

--- Lets one module price the open room: its line is drawn as the room's status.
-- @author dop42
-- @param owner string
-- @param fn function|nil `fn(slots, draft)` answering a sentence; nil removes it
-- @return boolean, string|nil
function Wardrobe.PriceWith(owner, fn)
	if type(owner) ~= 'string' or owner == '' then return false, 'invalid_caller' end
	if fn ~= nil and type(fn) ~= 'function' then return false, 'invalid_pricer' end
	if fn == nil then
		if pricer ~= nil and pricer.owner == owner then pricer = nil end
	else
		pricer = { owner = owner, fn = fn }
	end
	-- Drawn on the room's next state rather than republished here: a caller
	-- prices the room as it opens, when the room is about to publish anyway,
	-- and a second full state for one line is a resume's budget spent twice.
	return true
end

-- How many boxes one window of the grid carries. It is `panel`'s own `MAX_TILES`
-- and it has to be: that module refuses a longer window whole, and a room that
-- sent 61 would have its grid silently refused rather than half drawn. Written
-- down here rather than reached for because a module may not read another's
-- internals -- the same bargain `shops.SLOTS` is on, and `tests/` holds this one
-- against the panel's the same way.
local TILE_CHUNK = 60

-- Cold garment lookups one frame may make. See `warmTiles`.
local TILE_LOOKUPS = 20

-- Boxes one PUBLICATION carries, each on a resume of its own. A window is still
-- `TILE_CHUNK` boxes -- what is warmed, and what one scroll is answered with --
-- but it goes to the page in slices, because the page's contract checks every
-- box it is handed: `panel` cleans each name, caption and picture, and a
-- sixty-box window cost ~16,000 VM instructions in the one resume that
-- published it (the meter's 22,900 for `sendTiles`) against a budget of
-- ~10,000 that unwinds the thread without a word. A slice of ten is ~2,300.
-- The page appends a slice that starts where its grid ends, so the grid it
-- draws is the same sixty boxes.
local TILE_SLICE = 10

--- Works out the caption and picture of one window's boxes, TILE_LOOKUPS a frame,
--- so `tileWindow` finds them all warm. Answers false when `breathe` says the
--- window is no longer wanted.
-- @param names table the category's sorted records
-- @param from integer
-- @param breathe function yields a frame; false when the work is no longer wanted
local function warmTiles(names, from, breathe)
	local last = math.min(from + TILE_CHUNK - 1, #names)
	for index = from, last do
		if index > from and (index - from) % TILE_LOOKUPS == 0 and not breathe() then
			return false
		end
		title(names[index])
		Garments.Describe(names[index], family)
	end
	return true
end

-- Bumped by every window started. See `sendTiles`.
local tilesBuild = 0

--- One window of the open category's records, or false when there is no grid.
--
-- THREE PARALLEL LISTS: the record names, the caption under each box and the
-- picture in it. The record name is still what keys a box, and `from` is still
-- what ties a box back to a position on the track, which is what a press is
-- reported as. The caption is the item's own name (`title`) and the picture is
-- a file under `images/clothing/` for THIS body family, or '' for none -- in
-- which case the page draws a monogram without asking for a file that is not
-- there. Both come out of `client/garments.lua`, which is the only reader of the
-- generated data; the page decides nothing about which picture a record has.
--
-- PARALLEL LISTS AND NOT A TABLE PER BOX, for the wire: a box as `{ name, label,
-- image }` costs seven value nodes where three strings under three indices cost
-- six, and the host counts every one against a 1024 ceiling.
--
-- FROM A SLICE AND NOT A FILTER, so the cost of answering a scroll is the sixty
-- entries looked up and nothing else: no sort, no walk of the 677 this category
-- may hold. `readCatalogue` already sorted the list once, at open time, on its
-- own frames.
--
-- WARM, OR IT IS NOT CALLED. A garment row and a caption are worked out the
-- first time they are asked for -- about two hundred instructions a box cold, a
-- dozen warm -- and sixty cold boxes in the resume that also publishes the
-- window is a cost nobody can measure off-platform against a budget that kills
-- the coroutine without a word. So every caller warms the window first, on
-- frames of its own: `readCatalogue` warms each category's first window while
-- the room is opening, and `sendTiles` warms the next one before it sends it.
-- @param from integer the 1-based index the window starts at
-- @param count integer how many boxes, `TILE_SLICE` at most; see there
local function tileWindow(from, count)
	if category == nil then return false end
	local names = pieces[category]
	if type(names) ~= 'table' or #names == 0 then return false end
	if from < 1 then from = 1 end
	if from > #names then return false end

	local entries, labels, images = {}, {}, {}
	local last = math.min(from + count - 1, #names)
	for index = from, last do
		local record = names[index]
		local at = #entries + 1
		local _, image = Garments.Describe(record, family)
		entries[at] = record
		labels[at] = title(record)
		images[at] = image or ''
	end
	if last > tileTo then tileTo = last end
	return { slot = category, from = from, entries = entries, labels = labels, images = images }
end

--- The part of the room that follows the draft: seven sliders and the status.
--
-- SEVEN INTEGERS AND SEVEN LABELS, which is the whole of what crosses the seam
-- now. It used to be 1968 rows, formatted, sorted and pushed over some
-- twenty-six batches into a page that then re-parsed and re-counted every one of
-- them; the player reached one tab of the seven before the stream died and the
-- room said nothing. A slider needs a COUNT, not a list: the names live in Lua,
-- the page draws a track from 0 to the count, and the only name it is ever told
-- is the one under the thumb.
local function roomState()
	local sliders, tabs = {}, {}
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		sliders[index] = {
			id = slot,
			label = locale('wardrobe.slot.' .. slot),
			count = #pieces[slot],
			index = shown[slot],
			value = shownName[slot],
		}
		-- THE SEVEN SLOTS ARE THE CATEGORIES. They were seven tracks along the
		-- bottom of the screen; they are now seven tabs down the left of it, one
		-- open at a time with its own grid under it. `marked` is the dot that says
		-- something is on that slot, which is the one fact a closed category still
		-- has to state -- otherwise a player has to open all seven to find out what
		-- they are wearing.
		tabs[index] = {
			id = slot,
			label = locale('wardrobe.slot.' .. slot),
			marked = shown[slot] > 0,
			disabled = #pieces[slot] == 0,
		}
	end
	return {
		sliders = sliders,
		tabs = tabs,
		tab = category,
		-- ON EVERY STATE AND NOT ONLY THE FIRST FRAME, because the strip changes
		-- while the room is open: `shops` cannot offer its rows until the server
		-- has answered which looks this player's job may take, and that answer
		-- arrives after the room has already drawn. A `groups` that rode only on
		-- `roomSpec` would mean the categories appeared on the SECOND fitting.
		groups = groupRows,
		status = statusText and { text = statusText, kind = 'error' } or priceLine() or false,
	}
end

--- Sends the view the current draft.
-- Not `local function`: the name is declared above `OfferGroups`, which needs to
-- call it. See the forward declaration there.
function refresh()
	if phase ~= 'open' or draft == nil then return end
	publish('roomState', roomState())
end

--- Sends the grid one window, starting where it asked.
--
-- ITS OWN PUBLICATION AND NOT PART OF `roomState`, which is the whole reason the
-- grid can be scrolled at all. The room republishes its state on every slider
-- move -- a drag is a run of them -- and a state carrying the FIRST window would
-- throw a player who had scrolled to the four hundredth jacket back to the top
-- on the next preview. A window travels only when the category changes or the
-- page asks for the next one, and the page appends what it is sent; nothing else
-- touches the grid.
--
-- ON A THREAD OF ITS OWN, because `warmTiles` yields between lookups and every
-- slice goes out on a resume of its own (see `TILE_SLICE`). Every window
-- started bumps `tilesBuild`, so one still being built for a category the
-- player has already left -- or a room that has closed, or a scroll that asked
-- again -- stops instead of arriving late and being filed under the wrong tab.
-- @param from integer where the window starts
local function sendTiles(from)
	if phase ~= 'open' or category == nil then return end
	tilesBuild = tilesBuild + 1
	local mine, slot, room = tilesBuild, category, generation
	local function breathe()
		Wait(0)
		return mine == tilesBuild and phase == 'open' and category == slot and generation == room
	end
	CreateThread(function()
		local names = pieces[slot]
		if type(names) ~= 'table' or not warmTiles(names, from, breathe) then return end
		local last = math.min(from + TILE_CHUNK - 1, #names)
		local at = from
		while at <= last do
			if not breathe() then return end
			local window = tileWindow(at, math.min(TILE_SLICE, last - at + 1))
			if window == false then return end
			publish('roomTiles', { tiles = window })
			at = at + TILE_SLICE
		end
	end)
end

--- Opens one category, resetting its grid to the top.
-- A tab the room does not dress, or the one already open, is not a change.
local function openCategory(slot)
	if phase ~= 'open' or not IS_SLOT[slot] then return end
	if category == slot then return end
	category, tileTo = slot, 0
	-- THE STATE FIRST AND THE WINDOW SECOND. The page keys its grid by the slot
	-- the window names, so a window that arrived before the tab moved would be
	-- filed under the category the player just left and then thrown away.
	refresh()
	sendTiles(1)
end

--- Answers the grid asking for the window after the one it holds.
-- BOUNDED BY WHAT WAS ALREADY SENT, and not by the number on the message. The
-- page may ask for anything inside the track -- `panel` checks that much -- but
-- a grid that appends can only use the slice that follows what it has, and
-- honouring a leap would leave a hole in the middle of it that nothing would
-- ever fill.
local function moreTiles(slot, from)
	if phase ~= 'open' or slot ~= category then return end
	local wanted = tonumber(from)
	if wanted == nil or wanted % 1 ~= 0 then return end
	if wanted ~= tileTo + 1 then return end
	sendTiles(wanted)
end

--- Reads the body's catalogue, one slot at a time, into seven sorted lists.
-- Answers the records read, or nil and a failure.
--
-- ONE QUERY PER SLOT, AND THAT IS THE FIX. `Open77.equipment.records` takes a
-- `slot`, so the room never has to hold the whole catalogue: the largest answer
-- here is the outer chest at 677 rather than 1968 at once, and nothing is
-- formatted, bucketed or pushed anywhere. What the old stream did between the
-- read and the page -- `title` and a padded sort key per record, a Lua
-- comparator per comparison, a hundred-row batch per publish into a synchronous
-- `TriggerEvent` that re-parsed and re-counted the lot on this very thread -- is
-- gone rather than smaller.
--
-- THE SORT TAKES NO COMPARATOR ON PURPOSE. `table.sort(names)` over plain
-- strings compares in C at about one VM instruction a time; the comparator it
-- replaces was a Lua function, so 677 records cost some 6,400 CALLS in a single
-- resume that `table.sort` cannot yield out of. That was the heaviest unyieldable
-- thing in the room by a factor of forty, in the one place it could not be
-- broken up. The order is plain byte order rather than the old numeric-aware
-- one, and that is the price: `Jacket_10` sorts before `Jacket_2`. A slider is
-- travelled by dragging and not read as a list, so nobody is looking for a
-- particular name in it -- and a numeric key is exactly the Lua callback per
-- record this is removing.
local function readCatalogue(mine)
	local total = 0

	--- One frame, and whether this attempt still owns the room.
	local function breathe()
		Wait(0)
		return mine == generation
	end

	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		openingStage = 'catalogue: ' .. tostring(slot)
		local called, records, reason = pcall(Open77.equipment.records,
			{ slot = slot, family = family, restricted = false, limit = RECORD_LIMIT })
		if not called or type(records) ~= 'table' then
			return nil, tostring(called and reason or records)
		end
		if not breathe() then return nil, 'superseded' end

		local names = {}
		for entry = 1, #records do
			local record = records[entry]
			if type(record) == 'table' and type(record.record) == 'string' and
				record.nonvisual ~= true then
				names[#names + 1] = record.record
			end
			if entry % CATALOGUE_CHUNK == 0 and not breathe() then return nil, 'superseded' end
		end

		-- On its own frame. `table.sort` is C and costs the VM little, but it is
		-- the one step here that cannot be cut in half, so it is given a clean
		-- budget rather than the remains of the filter's.
		table.sort(names)
		if not breathe() then return nil, 'superseded' end

		for position = 1, #names do
			known[names[position]] = slot
			at[names[position]] = position
			if position % CATALOGUE_CHUNK == 0 and not breathe() then return nil, 'superseded' end
		end
		pieces[slot] = names
		total = total + #records

		-- The first window of every category, warmed now while the room is opening
		-- and a frame costs nothing, so the first frame and every first tab carry
		-- names and pictures without a cold lookup in a resume that publishes.
		if not warmTiles(names, 1, breathe) then return nil, 'superseded' end

		-- A SILENT TRUNCATION IS THIS WHOLE EPISODE'S SHAPE, so the one bound
		-- still in play is watched. The catalogue was at 98.4% of a 2000 ceiling
		-- when it was read whole; per slot the largest is a third of that, so
		-- this cannot fire today -- which is the point of writing it down rather
		-- than deciding it will never matter.
		if #records >= RECORD_LIMIT then
			Runtime.Note(('the %s catalogue answered %d record(s) against a limit of %d: ' ..
				'it is being truncated'):format(slot, #records, RECORD_LIMIT))
		end

		if not breathe() then return nil, 'superseded' end
	end
	return total
end

--- The first frame of the room.
local function roomSpec()
	local opened = roomState()
	opened.eyebrow = locale(creating and 'wardrobe.ui.eyebrowCreation' or 'wardrobe.ui.eyebrow')
	opened.title = locale('wardrobe.ui.heading')
	opened.subtitle = family == 'male' and locale('wardrobe.ui.male') or
		(family == 'female' and locale('wardrobe.ui.female') or nil)
	opened.intro = locale(creating and 'wardrobe.ui.introCreation' or 'wardrobe.ui.intro')
	-- NO SEARCH PLATE AND NO LOADING STATE. A search is a query over rows on the
	-- page, and the rows on the page are exactly the stream this change removes;
	-- putting them back to filter them would put the defect back behind a new
	-- face. The loading state went with the stream: the catalogue is read before
	-- the first frame goes out, so the first frame is already the finished one.
	opened.actions = {
		{ id = 'cancel', label = locale(creating and 'wardrobe.ui.skip' or 'wardrobe.ui.cancel') },
		{ id = 'save', label = locale(creating and 'wardrobe.ui.saveCreation' or 'wardrobe.ui.save'),
			primary = true },
	}
	-- THE GRID'S FIRST WINDOW FOLLOWS THE FIRST FRAME, PUSHED AND NOT ASKED FOR.
	-- It used to ride on the frame itself, so the room never showed an empty
	-- grid for a round trip; it is still never a round trip -- `begin` starts
	-- `sendTiles` the moment the frame is out, already warm, a slice a frame --
	-- but the boxes no longer share the frame's resume. The panel checks every
	-- box it is handed, and the open with its first boxes in it was the dearest
	-- resume left in the room (the meter's 7,000).
	opened.tiles = false
	if canTurn() then
		-- THE TURN BUTTONS CARRY GLYPHS, AND THAT IS THE FIX. They were four text
		-- buttons in a row, two of which -- `left` and `right` -- were not even
		-- localised: the literal English word went to the page in both languages.
		-- They now sit above the categories as picture buttons, which is what the
		-- owner asked for, and every name here is out of `OPX.Glyphs` because a
		-- name the page has no path for draws `interact` and tells nobody.
		--
		-- WHY THESE FOUR. `person` is the figure seen face on. `back` and `arrow`
		-- are the two chevrons the vocabulary already has, pointing the way the
		-- puppet turns -- and using the two DIFFERENT glyphs rather than one arrow
		-- twice is the point: two identical pictures side by side is the state the
		-- second glyph band was added to end. `refresh` is the turn all the way
		-- round, which is what the back view is.
		opened.tools = {
			{ id = 'front', label = locale('wardrobe.ui.front'), icon = 'person' },
			{ id = 'left', label = locale('wardrobe.ui.left'), icon = 'back' },
			{ id = 'right', label = locale('wardrobe.ui.right'), icon = 'arrow' },
			{ id = 'back', label = locale('wardrobe.ui.back'), icon = 'refresh' },
		}
	end
	return opened
end

--- Borrows the puppet and puts the room up, from a coroutine.
-- @param expected string|nil the character the room must be for
local function begin(owner, creation, expected)
	local refused = refusal()
	if refused then return false, refused end
	phase = 'opening'
	generation = generation + 1
	local mine = generation
	openingUntilMs = Runtime.NowMs() + OPENING_DEADLINE_MS

	--- Puts `phase` back when this attempt is still the live one.
	local function give(reason)
		if mine == generation then
			phase = 'closed'
			openingUntilMs = 0
		end
		-- EVERY WAY OUT OF `begin` THAT IS NOT A ROOM comes through here, which is
		-- what makes this the one place worth a line. There were five of them and
		-- all five were silent: a catalogue that superseded, a puppet the clothing
		-- half would not lend and its nine separate reasons for that, a character
		-- that changed under the borrow, a body that stopped being playable. The
		-- caller retries on most of them and logs the rest to the client's own
		-- file, on the player's machine, where nobody operating the server can
		-- read it.
		--
		-- Deduped per world entry, like `refusal` above and for the same reason:
		-- the retry loop calls this twice a second.
		if reason ~= nil and not refusalTold[reason] then
			refusalTold[reason] = true
			Runtime.Note(('the fitting room did not open: %s'):format(tostring(reason)))
		end
		return false, reason
	end

	-- THE CATALOGUE IS READ BEFORE THE PUPPET IS BORROWED, and the order is the
	-- argument. A read that fails now costs nothing -- there is no puppet out on
	-- loan to hand back and no room on screen to take down -- and a read that
	-- succeeds means the first frame this room publishes is its finished one,
	-- with every count already in it. The old order was the other way round and
	-- is what made a spinner possible at all.
	pieces, known, at, shown, shownName = {}, {}, {}, {}, {}
	openingStage = 'body family'
	family = Runtime.BodyFamily()
	openingStage = 'catalogue'
	local total, failure = readCatalogue(mine)
	if total == nil then
		if failure == 'superseded' then return give('superseded') end
		Runtime.Note('the clothing catalogue could not be read: ' .. failure)
		return give('catalogue_unreadable')
	end

	openingStage = 'borrowing the puppet'
	local answer, reason = Clothing.BeginPreview(owner)
	if answer == nil then return give(reason) end
	-- THE BORROW, THE DRESSING AND THE FIRST FRAME EACH GET A RESUME OF THEIR
	-- OWN. They all ran in the resume of the last catalogue breath -- the meter's
	-- 29,200 for this thread, against a budget of ~10,000 that unwinds it
	-- silently with the puppet out on loan and the room never drawn. The
	-- re-check below covers this frame too.
	Wait(0)

	-- Everything is re-checked after the borrow: the read above took frames and
	-- the borrow can take more.
	local stale = mine ~= generation or phase ~= 'opening'
	local wrong = expected ~= nil and State.citizenId ~= expected
	if stale or wrong or not playable() then
		Clothing.EndPreview(owner, false)
		if wrong then return give('character_changed') end
		return give(stale and 'superseded' or 'player_unavailable')
	end

	openingStage = 'dressing the sliders'
	baseline = slotsOf(answer)
	draft = copy(baseline)
	outfitCleared, hoverSlot, hoverRecord, statusText = false, nil, nil, nil
	citizen, creating = State.citizenId, creation == true
	roomOwner = owner
	-- Each slider starts on what the puppet is already wearing, which `at` gives
	-- in one lookup: 0 when the slot is empty, and 0 as well for a worn record
	-- the catalogue did not offer this body, because a thumb cannot stand on a
	-- position the track does not have.
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		local worn = baseline[slot]
		place(slot, worn ~= false and at[worn] or 0)
	end

	-- THE FIRST CATEGORY WITH SOMETHING IN IT, and not simply `SLOTS[1]`. A body
	-- family the catalogue has nothing for on the head opens on an empty grid and
	-- reads as a broken room; the tab for such a slot is drawn disabled, so
	-- opening on one would also put the tab strip's own cursor on a tab the
	-- player cannot press.
	category, tileTo = nil, 0
	for index = 1, #SLOTS do
		if #pieces[SLOTS[index]] > 0 then category = SLOTS[index] break end
	end

	-- BUILT HERE AND HANDED OVER ON THE NEXT FRAME: the spec is ours to build,
	-- the panel's check of it costs as much again, and the two together were
	-- the dearest resume left in the room.
	local first = roomSpec()
	Wait(0)
	if mine ~= generation or phase ~= 'opening' or not playable() then
		local superseded = mine ~= generation or phase ~= 'opening'
		Clothing.EndPreview(owner, false)
		baseline, draft, citizen, creating, roomOwner = nil, nil, nil, false, nil
		category, tileTo = nil, 0
		return give(superseded and 'superseded' or 'player_unavailable')
	end

	phase = 'open'
	openingUntilMs = 0
	openingStage = nil
	local opener = family
	publish('room', first)
	sendTiles(1)
	-- THE CAMERA, THE NOTE AND THE ANNOUNCEMENT FOLLOW ON FRESH RESUMES. The
	-- camera is a handful of natives, a note is a net event, and the
	-- announcement's listeners draw: `shops` answers it by offering its category
	-- strip, which republishes the room's state into the panel. Behind the first
	-- frame's open, in one resume, that was ~12,000.
	Wait(0)
	if mine == generation and phase == 'open' then holdCamera() end
	-- One line per room, and it is the whole of the evidence now: a room that
	-- opened on nothing and a room that never opened are different failures, and
	-- there is no stream left to tell them apart afterwards. Said once the room
	-- is drawn, whatever happens to it next.
	Runtime.Note(('the fitting room opened for %s on %d record(s) over %d slot(s)')
		:format(tostring(opener), total, #SLOTS))
	Wait(0)
	-- A room taken down in these two frames has already said `wardrobeClosed`,
	-- and announcing it open after that would cover the HUD for a room gone.
	if mine ~= generation or phase ~= 'open' then return true end
	Runtime.Publish({ ok = true, event = 'wardrobeOpened', creation = creating,
		citizenId = citizen })
	return true
end

--- Takes the room down and gives the puppet back, kept or restored.
local function release(keep, reason)
	if phase == 'opening' then
		generation = generation + 1
		phase = 'closed'
		openingUntilMs = 0
		return
	end
	if phase ~= 'open' then return end
	-- Keeping what was never changed is not a save. Whether the player ASKED to
	-- keep is published as well: "saved with nothing changed" and "cancelled"
	-- both arrive as `kept = false`, and a caller holding work for the room's
	-- end (`shops`' queued outfit save) has to tell them apart.
	local asked = keep == true
	keep = keep and changed()
	phase = 'closed'
	generation = generation + 1
	freeCamera()

	-- CAPTURED BEFORE THE STATE IS DROPPED on the next line, which is the only
	-- moment this list can be taken: `changedSlots` reads `baseline` and `draft`
	-- and both are about to be nil. It rides on `wardrobeClosed` for whoever
	-- needs to bill for a change -- see `changedSlots`.
	local moved = keep and changedSlots() or {}
	local mine, wasCreation, worn, owner = citizen, creating, draft, roomOwner
	baseline, draft, citizen, family, creating = nil, nil, nil, nil, false
	pieces, known, at, shown, shownName = {}, {}, {}, {}, {}
	hoverSlot, hoverRecord, statusText, outfitCleared, roomOwner = nil, nil, nil, false, nil
	category, tileTo = nil, 0
	openingUntilMs = 0
	-- THE STRIP GOES WITH THE ROOM. An offer is made against the room that is
	-- open -- `shops` offers its rows when it hears `wardrobeOpened`, and the rows
	-- it offers are gated on the shop the player is standing in -- so carrying
	-- them into the next room would put a uniform category on a fitting the
	-- player opened from their own appearance panel, miles from the shop.
	groupsBy, groupRows = {}, {}
	pricer = nil

	publish('roomClosed', { reason = reason, kept = keep })
	-- The registry reads pieces back as TweakDB ids: the names go with them so the
	-- clothing half can store names.
	local ok, failure = Clothing.EndPreview(owner, keep, worn)
	if not ok then
		Open77.log.warn(('[appearance] the puppet was not taken back: %s'):format(tostring(failure)))
	elseif keep and mine ~= nil then
		awaitSave = { citizenId = mine, untilMs = Runtime.NowMs() + SAVE_WAIT_MS }
	end

	Runtime.Publish({ ok = true, event = 'wardrobeClosed', reason = reason, kept = keep,
		asked = asked, creation = wasCreation, citizenId = mine, slots = moved })
	-- WHATEVER TOOK IT DOWN, THE JOIN IS NO LONGER WAITING. A room the player
	-- saved, cancelled, was pulled out of by a body reload or lost to a stopped
	-- owner is a room that has been had: holding the claim open past any of those
	-- would hold the spawn menu shut with nothing left to draw.
	claim(false, reason)
	Open77.log.info(('[appearance] the fitting room closed (%s, %s)')
		:format(reason, keep and 'kept' or 'restored'))
end

--- Takes the room down and puts back what the puppet wore.
-- @author dop42
-- @param reason string
function M.Wardrobe.Close(reason)
	release(false, reason)
end

--- Asks for the room on the live character, opened on a thread.
-- @author dop42
-- @param owner string the caller's own name
-- @return boolean
-- @return string|nil the refusal
function M.Wardrobe.Open(owner)
	if type(owner) ~= 'string' or owner == '' then return false, 'invalid_caller' end
	local refused = refusal()
	if refused then return false, refused end
	CreateThread(function()
		local ok, reason = begin(owner, false, nil)
		if ok or reason == 'superseded' then return end
		Runtime.Publish({ ok = false, event = 'wardrobeOpened', error = reason })
		Runtime.Notify('error', 'wardrobe.unavailable', { reason = tostring(reason) })
	end)
	return true
end

--- Puts what is under a thumb on the puppet without making it the choice.
-- Answers whether the puppet took it; a refusal puts the draft straight back.
--
-- NOTHING HAS TO UNDO A PREVIEW. Every put-on states all nine slots from the
-- DRAFT with one override, so previewing another slot restores the last one on
-- its way past, and giving the puppet back restores the lot.
local function tryOn(slot, record)
	if hoverSlot == slot and hoverRecord == record then return true end
	local ok = putOn(wearing(slot, record))
	if ok then
		hoverSlot, hoverRecord = slot, record
	else
		hoverSlot, hoverRecord = nil, nil
		putOn(draft)
	end
	return ok
end

--- Makes a piece, or an empty slot, the player's choice for that slot.
local function choose(slot, record)
	if phase ~= 'open' or not IS_SLOT[slot] then return end
	-- A record the catalogue did not offer for this slot is not a choice: the view
	-- is not trusted to name one.
	if record ~= false and (type(record) ~= 'string' or known[record] ~= slot) then return end
	local wanted = wearing(slot, record)
	local ok, failure = putOn(wanted)
	hoverSlot, hoverRecord = nil, nil
	if ok then
		draft, statusText = wanted, nil
		place(slot, record ~= false and at[record] or 0)
	else
		Open77.log.debug(('[appearance] %s refused on %s: %s')
			:format(tostring(record), slot, tostring(failure)))
		statusText = locale('wardrobe.ui.failed', { reason = tostring(failure):gsub('_', ' ') })
		putOn(draft)
	end
	-- Published either way, and the refusal is the interesting half: the page
	-- holds its own thumb position while the player drags, and this patch is what
	-- puts it back where the truth is when the piece would not go on.
	refresh()
end

--- Lays a whole saved look onto the open room's draft.
-- @author dop42
--
-- THE DRAFT AND NOT THE BODY, which is the whole reason this exists rather than
-- `shops` putting the look on itself. `shops.putOn` borrows the puppet through
-- `BeginClothingPreview` -- and while this room is open the puppet is ALREADY
-- borrowed, by this module, so that borrow is refused and loading a saved outfit
-- from inside the fitting room did nothing at all. Coming in through the draft
-- also gets the three things a player expects of a fitting room for free: the
-- sliders move to where the outfit put them, Cancel still puts back what they
-- walked in wearing, and the slots the outfit moved are on `wardrobeClosed` when
-- the room shuts -- so a shop bills a loaded outfit exactly as it bills a
-- hand-picked one, which is what `modules/shops/server/main.lua` already says
-- should happen ("loading a saved look at a shop is a change like any other").
--
-- ONE PUT-ON FOR THE WHOLE LOOK. Seven `Open77.equipment.apply` calls in one
-- resume is the shape of thing this file has an instruction budget note about;
-- the draft is assembled first and applied once.
-- @param records table slot name to record name, or false for an empty slot
-- @return boolean, string|nil
function Wardrobe.Dress(records)
	if phase ~= 'open' or draft == nil then return false, 'wardrobe_closed' end
	if type(records) ~= 'table' then return false, 'invalid_look' end

	local wanted, moved, dressed = copy(draft), {}, false
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		local record = records[slot]
		if record == false then
			wanted[slot] = false
			moved[#moved + 1] = slot
		elseif type(record) == 'string' and known[record] == slot then
			-- CHECKED AGAINST THE CATALOGUE THIS BODY READ, exactly as `choose` is.
			-- A share code is read out by another player and their character may not
			-- be this one's build -- so a code can perfectly legitimately name a
			-- jacket this body has no record for. Silently skipping it dresses the
			-- player in as much of the look as fits, which is better than refusing
			-- the whole outfit over one garment, and the count below is what lets
			-- the caller say so.
			wanted[slot] = record
			moved[#moved + 1] = slot
			dressed = true
		end
	end
	if #moved == 0 then return false, 'nothing_wearable' end

	-- THE FULL-BODY SUIT RULE, the same one `wearing` applies to a single piece:
	-- a suit covers everything under it, so putting a garment on takes the suit
	-- off. An outfit that names the suit itself keeps it; one that names anything
	-- else and does not mention the suit clears it, or the player would be handed
	-- a look they cannot see.
	if dressed and records.Outfit == nil then wanted.Outfit = false end

	local ok, failure = putOn(wanted)
	hoverSlot, hoverRecord = nil, nil
	if not ok then
		putOn(draft)
		statusText = locale('wardrobe.ui.failed', { reason = tostring(failure):gsub('_', ' ') })
		refresh()
		return false, tostring(failure)
	end

	draft, statusText = wanted, nil
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		local worn = wanted[slot]
		place(slot, worn ~= false and at[worn] or 0)
	end
	refresh()
	return true
end

--- Moves one slot's slider: a preview under the thumb, or the player's choice.
-- @param slot string
-- @param index any 0 for nothing, 1..count for a piece
-- @param commit boolean whether the player has let go
local function slide(slot, index, commit)
	if phase ~= 'open' or not IS_SLOT[slot] then return end
	local names = pieces[slot]
	if names == nil then return end
	-- The view names an INDEX and never a record, so this is where an index
	-- becomes one. The bound is the list this module read, not a number the page
	-- sent with it.
	local wanted = tonumber(index)
	if wanted == nil or wanted % 1 ~= 0 or wanted < 0 or wanted > #names then return end
	local record = wanted > 0 and names[wanted] or false

	if commit == true then return choose(slot, record) end

	-- A PREVIEW THAT WOULD NOT GO ON SAYS NOTHING AND MOVES NOTHING. A drag is a
	-- run of these, so a status line here would flicker one error per frame for
	-- a piece the player is only passing over -- and the commit at the end of the
	-- drag is what puts a refusal on screen.
	if not tryOn(slot, record) then return end
	place(slot, wanted)
	refresh()
end

--- Leaves at once when nothing changed, otherwise asks before dropping the draft.
local function ask()
	if phase ~= 'open' then return end
	if not changed() then return release(false, 'cancelled') end
	publish('confirm', {
		id = 'discard',
		title = locale(creating and 'wardrobe.ui.confirmTitleCreation' or 'wardrobe.ui.confirmTitle'),
		text = locale(creating and 'wardrobe.ui.confirmTextCreation' or 'wardrobe.ui.confirmText'),
		yes = locale('wardrobe.ui.confirmYes'),
		no = locale('wardrobe.ui.confirmNo'),
	})
end

-- What each button of the room does. There is no 'remove': index 0 on a slot's
-- own slider is what taking a piece off means now, which is one control fewer
-- and one less thing that can disagree with the thumb.
local ACTIONS = {
	save = function() release(true, 'saved') end,
	cancel = ask,
	front = function() orbit = FRAMING_FRONT faceCamera() end,
	back = function() orbit = 0 faceCamera() end,
	left = function() orbit = ((orbit - TURN_DEGREES + 180) % 360) - 180 faceCamera() end,
	right = function() orbit = ((orbit + TURN_DEGREES + 180) % 360) - 180 faceCamera() end,
}

--- Reports a pressed category button to the module that offered it.
--
-- ON THE DECISION BUS AND NOT THROUGH A CALLBACK, which keeps the offer one-way.
-- A callback would mean this module holding a function belonging to another
-- module across the life of a room -- and a room outlives a module stop, which
-- is the exact shape of the stale-owner bug the upkeep pass already exists to
-- clean up. A published decision is read by whoever is still listening and by
-- nobody who is not.
--
-- Answers whether the id was one of ours, so an unknown button is a no-op rather
-- than a decision nothing will ever answer.
local function pressGroup(value)
	if type(value) ~= 'string' then return false end
	for index = 1, #groupRows do
		if groupRows[index].id == value then
			-- Unwrapped back into the offerer's own id: the namespace this module
			-- added is bookkeeping and was never the caller's word for the button.
			local owner, id = value:match('^([^:]+):(.+)$')
			if owner == nil then return false end
			Runtime.Publish({ ok = true, event = 'wardrobeGroup', owner = owner, group = id,
				citizenId = citizen })
			return true
		end
	end
	return false
end

--- WARDROBE.CREATION_WAIT_MS, or the shipped value for an unusable one.
local function creationWaitMs()
	local config = type(M.Settings.WARDROBE) == 'table' and M.Settings.WARDROBE or {}
	return M.ConfigMs(config.CREATION_WAIT_MS) or CREATION_WAIT_MS
end

-- The retry's heartbeat, the offer it is working on, and how many times it has
-- been started again.
--
-- WHY A SUPERVISOR EXISTS AT ALL. `core/client/scheduler.lua` opens by saying
-- modules register work there "instead of spawning threads", and by naming the
-- exact failure this module spent five diagnoses on: exceeding the per-resume
-- instruction budget "unwinds straight out of the coroutine body ... it does not
-- crash the resource, it does not repeat, and it logs nothing. A loop that
-- quietly stopped is almost always this."
--
-- This retry is a raw `CreateThread`, and it is queued from inside the
-- synchronous handler chain of `created` -- which `FinishCreation` publishes
-- immediately before spending the bootstrap, and spending the bootstrap is what
-- LOADS THE WORLD. So the one thread the join depends on is started microseconds
-- before the client tears the pre-game context down. Whether it dies to the
-- budget, to a raise, or is simply never resumed across that transition, the
-- symptom is identical and the journal is empty: the owed line prints and
-- nothing follows it, which is exactly what five creations have now shown.
--
-- It cannot simply move into the scheduler. `runJob` wraps a step in `pcall` and
-- `begin` yields -- `readCatalogue` waits a frame per slot -- and a yield across
-- a pcall boundary is not safe on this runtime. So the thread stays, and the
-- scheduler job WATCHES it.
local retryBeat, retryLive, retryRevivals = 0, nil, 0

-- How long the supervisor waits for a beat before calling the thread dead. Six
-- retry intervals: long enough that a slow frame or a catalogue read is never
-- mistaken for a death, short enough that the player is not left looking at an
-- empty screen for long.
-- MEASURED AND RAISED FROM 3000, which was wrong and made things worse. On a
-- real creation the worker started, reported itself, and its first `begin` did
-- not answer for 3.1 s -- not because it was dead but because the WORLD WAS
-- LOADING and the client was not resuming scripts. The supervisor called that a
-- death and started a second worker; the two then raced, and one of them stood
-- down on `wardrobe_busy` against the other's half-open room. Eight seconds is
-- past the observed load stall with room to spare, and the `phase` guard below
-- is the real protection: a stall inside an open is the 10 s opening watchdog's
-- business, not this one's.
local RETRY_STALL_MS = 8000

-- How many times a dead retry is started again before the join is handed back.
-- A second attempt covers the world-load transition, which is the one moment a
-- thread is known to be at risk. Past that, something is wrong that another
-- thread will not fix, and THE JOIN MUST NOT STAY SHUT: the claim is what the
-- spawn menu waits behind, so it is withdrawn under a reason of its own rather
-- than held for a worker that is never coming back.
local MAX_REVIVALS = 2

local runRetry

--- Starts the retry thread for the live offer, beating once so the supervisor
--- does not immediately judge it dead.
local function spawnRetry()
	local live = retryLive
	if live == nil then return end
	retryBeat = Runtime.NowMs()
	CreateThread(function() runRetry(live) end)
end

--- Offers a fitting room and keeps trying until it opens, is refused for good,
--- or the window closes.
--
-- Every exit either leaves a room on screen or withdraws the claim, because the
-- claim is what the rest of the join is waiting behind: a worker that stopped
-- without doing one of the two holds the spawn menu shut for the session. The
-- one exception is `wardrobe_busy` -- a room is already up, and its own close
-- withdraws the claim.
-- @param resumed boolean this offer is itself the retry of one that expired
local function awaitRoom(owner, creation, citizenId, resumed)
	creationWatch = creationWatch + 1
	watchCitizen = citizenId
	retryLive = {
		owner = owner, creation = creation, citizenId = citizenId, resumed = resumed,
		mine = creationWatch,
		deadline = Runtime.NowMs() + creationWaitMs(),
	}
	retryRevivals = 0
	spawnRetry()
end

--- Watches the retry thread and starts it again if it stopped without saying so.
--
-- Called from `Wardrobe.Check`, which the `appearance.wardrobe` scheduler job
-- drives every 250 ms. That job is the one part of this machinery already proven
-- to survive the world load, which is precisely why the watch lives there.
local function superviseRetry()
	local live = retryLive
	if live == nil then return end
	-- Somebody else owns the claim now; the thread will notice and say so.
	if live.mine ~= creationWatch then return end

	-- NEVER WHILE AN OPEN IS IN FLIGHT. A worker inside `begin` does not beat --
	-- the beat is written once per iteration -- and `begin` legitimately spans
	-- several frames reading the catalogue. Starting a second worker there is
	-- how the first real creation ended up with two of them racing, one standing
	-- down on `wardrobe_busy` against the other's half-open room. That window
	-- already has an owner: the 10 s watchdog in `Wardrobe.Check`, which puts
	-- `phase` back and lets the retry come round again.
	if phase ~= 'closed' then return end

	if Runtime.NowMs() - retryBeat < RETRY_STALL_MS then return end

	if retryRevivals < MAX_REVIVALS then
		retryRevivals = retryRevivals + 1
		Runtime.Note(('the retry for %s stopped without a word after %d ms; '
			.. 'starting it again (%d)')
			:format(tostring(live.citizenId), RETRY_STALL_MS, retryRevivals))
		return spawnRetry()
	end

	-- THE JOIN IS GIVEN BACK, and this is the ending that was missing. With the
	-- worker dead and the claim standing, the spawn menu stands aside for a room
	-- that will never be drawn, and the player is left with an empty screen and
	-- no way forward -- which is the whole of what the owner reported. A named
	-- withdrawal is worse than a fitting room and far better than a dead end.
	retryLive, watchCitizen = nil, nil
	if live.creation then
		roomExpired = { citizenId = live.citizenId, reason = 'retry_stopped',
			resumed = live.resumed }
	end
	Runtime.Note(('no fitting room for %s: the retry stopped %d times and is not coming '
		.. 'back; the join is released')
		:format(tostring(live.citizenId), retryRevivals + 1))
	claim(false, 'retry_stopped')
end

runRetry = function(live)
	local owner, creation, citizenId, resumed =
		live.owner, live.creation, live.citizenId, live.resumed
	local mine = live.mine
	local reason, said = nil, nil
	local traced = false

	retryBeat = Runtime.NowMs()

	-- THE TRACE, and it is here because five rounds of elimination have run out
	-- of things to eliminate. The owed line prints and then nothing does: not a
	-- refusal, not a supersede, not the expiry -- and the expiry is only reached
	-- once `begin` has RETURNED, so its silence says the loop is not coming back
	-- round rather than that the window is still open. That leaves "the thread
	-- never started" and "the first attempt never finished", which are
	-- indistinguishable from outside and are told apart by exactly two lines.
	Runtime.Note(('the retry for %s is running; it has %d ms')
		:format(tostring(citizenId), creationWaitMs()))

	while mine == creationWatch and Runtime.NowMs() < live.deadline do
		retryBeat = Runtime.NowMs()

		local ok
		ok, reason = begin(owner, creation, citizenId)
		if not traced then
			traced = true
			Runtime.Note(('the first attempt for %s answered ok=%s, %s')
				:format(tostring(citizenId), tostring(ok), tostring(reason or 'no reason')))
		end

		-- THE CLOCK DOES NOT RUN WHILE ANOTHER JOIN SCREEN IS UP, which is the
		-- rule `clothing.lua` already applies to the creator. The spawn menu
		-- gives the player 45s and this window is 60s, so without this a room
		-- could be withdrawn for a delay that was somebody else's by design.
		if reason == 'spawn_up' then live.deadline = Runtime.NowMs() + creationWaitMs() end
		-- NOR WHILE THE NAME FORM IS. It holds the keyboard, so the room answers
		-- `input_captured` for as long as the player is typing, and a new player
		-- who took more than a minute over a name (the window starts before the
		-- form appears, so loading spends from it too) lost the clothes step with
		-- no word: name form, then straight to the spawn menu.
		if reason == 'input_captured' and joinIsNaming() then
			live.deadline = Runtime.NowMs() + creationWaitMs()
		end

		if ok or reason == 'wardrobe_busy' then
			if not ok then
				-- Silent until recently, and one of three ways out of this loop
				-- that wrote nothing. A room already up withdraws the claim when
				-- it closes, so this exit is legitimate -- but "legitimate" and
				-- "invisible" are different things, and telling the two busy
				-- endings apart afterwards was impossible.
				Runtime.Note(('the fitting room owed to %s stood down: one is already open')
					:format(tostring(citizenId)))
			end
			retryLive, watchCitizen = nil, nil
			return
		end

		if not RETRYABLE[reason] and reason ~= 'superseded' then
			-- A REFUSAL THAT IS NOT RETRIED IS THE END OF THE OFFER, once and for
			-- this world entry, so it is the single most important line this
			-- module can write -- and it was written to the client's own log,
			-- which is a file on the player's machine. That is precisely how
			-- `invalid_caller` refused every creation's fitting room for as long
			-- as it did without anybody being able to see it.
			retryLive, watchCitizen = nil, nil
			Runtime.Note(('no fitting room for %s: %s')
				:format(tostring(citizenId), tostring(reason)))
			return claim(false, reason)
		end

		if reason ~= said then
			said = reason
			Open77.log.debug(('[appearance] fitting room for %s not yet: %s')
				:format(tostring(citizenId), tostring(reason)))
		end
		Wait(RETRY_MS)
	end

	-- Superseded watches leave the claim alone: whatever bumped the generation
	-- owns it now, and both of the things that do -- a new character and a new
	-- offer -- settle it themselves.
	if mine == creationWatch then
		-- RECORDED AS AN EXPIRY, and withdrawn under that name rather than under
		-- whatever the last try was refused with. The window ending and the room
		-- being refused are different endings: one is a clock, the other is a
		-- state, and `wardrobeWanted` carries only the one string. See
		-- `roomExpired` -- this is what stops the retry being re-decided by a
		-- policy that never declined anything.
		if creation then
			roomExpired = { citizenId = citizenId, reason = tostring(reason or 'timeout'),
				resumed = resumed }
		end
		retryLive, watchCitizen = nil, nil
		Runtime.Note(('the fitting room owed to %s expired after %d ms: still %s')
			:format(tostring(citizenId), creationWaitMs(), tostring(reason)))
		claim(false, 'expired')
	else
		-- THE EXIT THAT ATE A CREATION'S FITTING ROOM, and it wrote nothing at
		-- all. `mine ~= creationWatch` means something bumped the generation
		-- under this worker; it then returned without opening a room, without
		-- withdrawing the claim and without a line anywhere.
		--
		-- It is a legitimate ending -- whoever bumped the generation owns the
		-- claim now -- but it is never again an invisible one.
		if retryLive == live then retryLive = nil end
		Runtime.Note(('the fitting room owed to %s was superseded while waiting (last: %s)')
			:format(tostring(citizenId), tostring(reason or 'no attempt')))
	end
end

--- Offers this world entry a fitting room, if the policy says this entry is one.
-- @param creation boolean whether the game's own creator has just built this body
-- @param citizenId string|nil the character the room must be for
local function offerRoom(creation, citizenId)
	local policy = M.WardrobeOffer or M.WARDROBE_POLICY_DEFAULT
	if policy == M.WardrobePolicy.NEVER then return end

	-- THE OFFER THAT EXPIRED IS STILL THIS CREATION'S OFFER, and it is answered
	-- ABOVE the once-per-entry guard because it is the one thing that is not a
	-- second offer: it is the first one, resumed. `clothingRestored` carries
	-- `creation = false` -- it is the stored record going on, not the creator
	-- finishing -- which is true of a returning player and true here, where it is
	-- the same join finally reaching the clothes the creation's own room was
	-- waiting for. Judging it by `creation` at this point asks the policy question
	-- twice and answers the second one wrongly.
	--
	-- ONCE. A resumed offer that expires again is recorded, reported and left
	-- alone; the alternative is a world entry that re-offers the same room for as
	-- long as anything keeps publishing.
	local expired = roomExpired
	local resumed = false
	if expired ~= nil and expired.citizenId == citizenId then
		roomExpired = nil
		if expired.resumed then
			Runtime.Note(('no fitting room for %s: the one owed to its creation expired twice ' ..
				'(%s), so it is not offered again this entry')
				:format(tostring(citizenId), expired.reason))
			return
		end
		Runtime.Note(('the fitting room owed to %s expired (%s) before the clothes were on; ' ..
			'they are on now, so the creation is offered its room again')
			:format(tostring(citizenId), expired.reason))
		creation, resumed, roomOffered = true, true, false
	end

	-- Once per world entry. A creation publishes `created` and then, seconds
	-- later, `clothingRestored`; under 'always' both are an offer, and without
	-- this the second would supersede the first -- restarting the retry window
	-- and, worse, restarting it AFTER the first had already given up.
	if roomOffered then return end

	if policy == M.WardrobePolicy.FIRST and not creation then
		-- Said, not silent, and said where the operator reads. 'first' declining a
		-- returning character is the CORRECT behaviour and is also exactly what a
		-- broken fitting room looks like from the outside; one line tells them
		-- apart without anybody having to reason about which policy is loaded.
		Runtime.Note(('no fitting room for %s: the policy is first and this is not a creation')
			:format(tostring(citizenId)))
		return
	end

	roomOffered = true
	-- THE CLAIM GOES UP BEFORE THE FIRST TRY, and that ordering is the whole
	-- sequencing: the first try is normally refused -- the name form has the
	-- keyboard, or the clothes are not on yet -- so a claim raised only once the
	-- room was up would leave the retry window unguarded, which is the window the
	-- spawn menu would open in.
	claim(true)
	Runtime.Note(('a fitting room is owed to %s (%s)'):format(tostring(citizenId), policy))
	awaitRoom(OWNER, creation, citizenId, resumed)
end

-- ── the other half of the seam ──────────────────────────────────────────────

--- What a view module calls.
-- @author dop42
--
-- `ready` says the view can be drawn on and answers with every string it draws
-- plus whatever is currently up; everything else is an intent, and every one of
-- them is re-checked here against state this module owns. Nothing a view computes
-- is trusted -- not a record name, not a slot, not an index.
-- @param action string
-- @param payload table|nil
function M.FromView(action, payload)
	payload = type(payload) == 'table' and payload or {}

	if action == 'ready' then
		local text = {}
		for _, key in ipairs(TEXT_KEYS) do text[key] = locale(key) end
		publish('config', { text = text })
		if panelOwner ~= nil then publish('panel', panelSpec()) end
		if phase == 'open' then publish('room', roomSpec()) end
		return
	end

	if action == 'panel.select' then
		if panelOwner == nil then return end
		local id = payload.item
		if id == 'wear' then return wearStored() end
		if id == 'editFace' then return openNative('ripperdoc') end
		if id == 'editHair' then return openNative('hairdresser') end
		if id == 'wardrobe' then
			local owner = panelOwner
			Panel.Close('caller')
			local ok, reason = Wardrobe.Open(owner)
			if not ok then
				Runtime.Notify('error', 'wardrobe.unavailable', { reason = tostring(reason) })
			end
		end
		return
	end

	if action == 'panel.close' then
		return Panel.Close(payload.reason == 'player' and 'player' or 'view_closed')
	end

	-- NOTHING HERE IS ANSWERED ANY MORE, and that is the size of the change.
	-- `room.items` used to be the one publication a view had to report on,
	-- because a batch was cumulative and a lost one was a hundred pieces the
	-- player never saw with nothing on screen saying so. There are no batches: a
	-- view either drew the seven sliders or it did not, and a view that did not
	-- draw them draws whatever the next `roomState` carries instead.
	if action == 'room.slide' then
		return slide(payload.slot, payload.index, payload.commit)
	end
	-- THE CATEGORY AND ITS GRID. Both are re-checked here against the seven slots
	-- and the list this side read, exactly as a slide is: a view that named an
	-- eighth category, or asked for the window after a window nobody sent, gets
	-- the same nothing a mistyped slot has always got.
	if action == 'room.tab' then return openCategory(payload.slot) end
	if action == 'room.tiles' then return moreTiles(payload.slot, payload.from) end
	if action == 'room.action' then
		local run = ACTIONS[payload.value]
		if run then return run() end
		-- The category strip rides on the same channel: the view draws one row of
		-- buttons and reports a press the same way whichever row it was in, so a
		-- value that is not one of this module's own buttons is offered to the
		-- strip before it is dropped.
		pressGroup(payload.value)
		return
	end
	if action == 'room.dismiss' then return ask() end
	if action == 'room.confirm' then
		if payload.item == 'discard' and payload.value == true then release(false, 'cancelled') end
		return
	end
	if action == 'room.close' then
		return release(false, tostring(payload.reason or 'view_closed'))
	end
	if action == 'diag' then
		Open77.log.info('[appearance] view: ' .. tostring(payload.text or ''))
	end
end

--- Runs one pass over both views.
-- @author dop42
function M.Wardrobe.Check()
	-- THE ROOM IS STILL UP, said to the server now and then. Its save grant is
	-- ten minutes from the ask, and a long browse outlived it: the save that
	-- left the room was refused "not saved" with the clothes still on. The
	-- server keeps the grant alive while it hears this, to a hard cap.
	if phase == 'open' then
		local now = Runtime.NowMs()
		if now - roomAliveAtMs >= ROOM_ALIVE_MS then
			roomAliveAtMs = now
			TriggerServerEvent(M.Event.ROOM_ALIVE)
		end
	else
		roomAliveAtMs = -math.huge
	end

	local ok, failure = pcall(panelTick)
	if not ok then Open77.log.error('[appearance] panel: ' .. tostring(failure)) end

	-- THE RETRY IS WATCHED FROM HERE, and this is the only place in the module
	-- that can watch it: the `appearance.wardrobe` job driving this function is
	-- the one piece of the machinery proven to survive the world load, while the
	-- retry itself is a raw thread started microseconds before that load. See
	-- `superviseRetry`. Outside the pcall below because it must run even if the
	-- panel tick or the sweep is failing -- a dead retry holds the whole join.
	local watched, watchFailure = pcall(superviseRetry)
	if not watched then
		Open77.log.error('[appearance] retry watch: ' .. tostring(watchFailure))
	end

	local ran, reason = pcall(function()
		-- A CHARACTER THAT LEFT WITHOUT BEING REPLACED. `characterChanged` covers
		-- a switch and `release` covers a room that was up, but an unload with no
		-- room drawn reaches neither -- and a claim left standing for nobody is a
		-- join sequence waiting on a player who is not there.
		if roomOwed and State.citizenId == nil then
			roomOffered, roomExpired = false, nil
			claim(false, 'no_character')
		end

		-- AN OPEN THAT NEVER FINISHED. Outside the `phase == 'open'` block below
		-- and before it, because this is the one check here whose whole reason
		-- for living is that the thing it watches may have died: `begin` runs on
		-- a coroutine, an overrun of the per-resume instruction budget unwinds it
		-- with nothing logged, and every other way out of `begin` is written
		-- inside the coroutine that is gone. Left alone, `phase` would sit on
		-- 'opening' and refuse every later open `wardrobe_busy` for the session.
		if openingUntilMs ~= 0 and phase == 'opening' and Runtime.NowMs() >= openingUntilMs then
			openingUntilMs = 0
			generation = generation + 1
			phase = 'closed'
			Runtime.Note(('the fitting room never finished opening after %d ms; it was at: %s')
				:format(OPENING_DEADLINE_MS, tostring(openingStage or 'the very first step')))
			openingStage = nil
		end

		if phase == 'open' then
			if not playable() then
				release(false, 'player_unavailable')
			else
				orbitCamera()
			end
			if roomOwner ~= nil and not OPX.Modules.IsRunning(roomOwner) and
				GetResourceState(roomOwner) ~= 'running' then
				release(false, 'owner_stopped')
			end
		end
		if awaitSave ~= nil and Runtime.NowMs() >= awaitSave.untilMs then awaitSave = nil end
	end)
	if not ran then Open77.log.error('[appearance] fitting room: ' .. tostring(reason)) end
end

--- Wires both views to the decisions this module reaches.
-- @author dop42
function M.Wardrobe.Wire()
	-- THE THIRD JOIN SCREEN, ordered against the second. `spawn` publishes its
	-- own up/down on the local bus and exposes no reader, so it is tracked here.
	--
	-- ASKED FOR BY NAME AND NOT DEPENDED ON: a runtime without the spawn module
	-- simply never sets this, `refusal` never returns `spawn_up`, and the room
	-- behaves exactly as it did before. That is the same shape as the optional
	-- `diagnostics` relay, and it is why this is not a hard cross-module import.
	local spawn = OPX.Modules.Get('spawn')
	local channel = type(spawn) == 'table' and type(spawn.Event) == 'table'
		and spawn.Event.ON_STATE or nil
	if channel ~= nil then
		AddEventHandler(channel, function(state)
			spawnUp = type(state) == 'table' and state.open == true
		end)
	end

	AddEventHandler(M.Event.ON_DECISION, function(decision)
		if type(decision) ~= 'table' then return end
		local event = decision.event

		if event == 'characterChanged' then
			-- THE CHARACTER IT ANNOUNCES IS NOT A CHARACTER ARRIVING, and telling
			-- those two apart is the whole of this branch. A CREATION raises
			-- `characterChanged` for the body the creator has just built -- the
			-- same citizen the retry watch three lines down was started for,
			-- seconds earlier, by that very creation. Bumping the generation here
			-- killed that thread where it stood: no room, no claim withdrawn, no
			-- line in the journal. The join then waited behind a claim nobody
			-- owned until the spawn selector gave up on its own, and the only
			-- evidence was the spawn module reporting that the player chose
			-- nothing -- which is true, and says nothing about why.
			--
			-- This is the SAME MISTAKE as the one written up on `WORLD_READY`
			-- below, one event over: an event that is structurally part of every
			-- creation, treated as though it could only mean a new character. The
			-- guard is the same shape -- ask whether this is the character already
			-- being waited for -- and the answer is a citizen id both sides have.
			--
			-- A DIFFERENT character still tears everything down, which is what
			-- this branch is for: the room, the offer and the expiry all belong to
			-- whoever has gone.
			if watchCitizen ~= nil and decision.citizenId == watchCitizen then
				Runtime.Note(('%s is the character its own fitting room is waiting for; ' ..
					'the offer stands'):format(tostring(watchCitizen)))
				return
			end

			watchCitizen = nil
			creationWatch = creationWatch + 1
			awaitSave = nil
			roomOffered = false
			-- An expiry belongs to the character it expired for; the one arriving
			-- has its own offer to be made.
			roomExpired = nil
			Panel.Close('character_changed')
			release(false, 'character_changed')
			-- After the release, which withdraws the claim itself when a room was
			-- up. This is the other case: a claim raised for a character that has
			-- gone, with no room ever drawn for it.
			return claim(false, 'character_changed')
		end

		-- THE TWO MOMENTS A JOIN IS OFFERED A ROOM, and they are different moments
		-- for a reason. `created` is the game's own creator having just built a
		-- body, which is the whole of what 'first' means and is raised before the
		-- character has any clothes at all -- the retry window is what waits for
		-- them. `clothingRestored` is the stored record actually being ON the
		-- puppet, which is the only honest moment to offer a RETURNING player the
		-- room: opened before it, 'cancel' would put back the pristine puppet's
		-- clothes rather than the ones they walked in wearing.
		if event == 'created' then
			if decision.ok ~= true then return end
			return offerRoom(true, type(decision.citizenId) == 'string' and
				decision.citizenId or nil)
		end

		if event == 'clothingRestored' then
			if decision.ok ~= true then return end
			return offerRoom(false, type(decision.citizenId) == 'string' and
				decision.citizenId or nil)
		end

		if event == 'clothingSaved' and awaitSave ~= nil and
			decision.citizenId == awaitSave.citizenId then
			awaitSave = nil
			if decision.ok == true then return Runtime.Notify('success', 'wardrobe.saved') end
			return Runtime.Notify('error', 'wardrobe.notSaved', { reason = tostring(decision.error) })
		end

		-- The panel shows the stored face and whether it is worn, so it follows
		-- every decision about one.
		if panelOwner ~= nil and (event == 'saved' or event == 'restored' or
			event == 'applied') then
			Panel.Refresh()
		end
	end)

	-- A new world entry dresses the puppet again, so the room goes down first --
	-- and is offerable again, because under 'always' a world enter is exactly
	-- what this policy is counted in. The clothes go back on from scratch after
	-- one, so `clothingRestored` will come round again and make the offer; under
	-- 'first' nothing raises `created` twice and this changes nothing.
	AddEventHandler(OPX.Host.WORLD_READY, function()
		release(false, 'world_changed')

		-- One journal line per distinct refusal PER WORLD ENTRY. The gate below is
		-- consulted by a retry loop several times a second; without this reset it
		-- would either flood the note budget or, deduped for the whole session, go
		-- quiet after the first join and tell a second join nothing.
		forgetRefusals()

		-- NOT WHILE ONE IS STILL OWED, and this is the half of the fitting-room
		-- defect that lived here. A CREATION'S OWN BOOTSTRAP ANSWER IS WHAT LOADS
		-- THE WORLD: the creator is the pre-game menu's screen, `FinishCreation`
		-- spends the bootstrap on the body it built, and the world that comes up
		-- afterwards raises this event. So every creation reaches here seconds
		-- after `created`, with its offer live and its retry window still running
		-- -- and clearing `roomOffered` there is not "a new world entry may be
		-- offered a room", it is throwing away the offer this join is in the
		-- middle of. `clothingRestored` then walked through the guard that exists
		-- to stop exactly that and was re-decided by policy.
		--
		-- `release` above withdraws the claim for a room that was UP; a room that
		-- was only owed is untouched by it, which is why the test is `roomOwed`
		-- and why it has to come after. Under 'always' a genuine later world
		-- change owes nothing and is offerable again exactly as before.
		if not roomOwed then roomOffered = false end
	end)
end
