--- The two modal transactions: building a new character, and editing its face.
-- @author dop42
--
-- The engine's own screens are the only ones there are: an option is
-- `{ part, name, value, choices }` where `name` is an opaque 64-bit catalogue
-- hash with no human label anywhere on the platform. So this file does not draw
-- an editor, it opens one, and everything after the player confirms -- the
-- capture, the family, the save -- belongs here again.
--
-- THE TWO SCREENS ARE NOT THE SAME SCREEN.
--
-- * A CREATION opens the game's own character creator, which is the flow the
--   platform offers for it: the body choice first, then the whole face. It is
--   what decides the body family, and its answer -- `confirmed:female`,
--   `confirmed:male` or `cancelled` -- arrives in a mailbox that `Watch` reads
--   once. Nothing here asks the player which body to build on, and nothing here
--   reloads one to open it on.
-- * An EDIT opens the ripperdoc mirror on the body the character already has.
--   The mirror cannot change a body family, which is exactly why it is the
--   editor: the family belongs to the character row.
--
-- The mirror is also the fallback for a creation the creator refuses. A refused
-- creator must not be a player who cannot make a character, so the mirror is
-- opened on whatever body the world loaded and the family is read off it.

local M = OPX.Modules.Get('appearance')

local Snapshot = M.Snapshot
local State = M.Face
local Runtime = M.Runtime

M.Editor = {}
local Editor = M.Editor

-- Milliseconds an asked-for creation editor may stay unseen before a log line,
-- and before a native creator nothing is holding is given up on.
local CREATOR_UNSEEN_MS = 30000

-- The bootstrap phases that PROVE the platform has a creator on screen. While the
-- projection reads one of these there is something to wait for, and an unseen
-- editor is a player deliberating rather than an editor that never came.
--
-- `creator_requested` is deliberately NOT one of them: it says the request was
-- granted, which is exactly what a creator that never comes says too.
local CREATOR_PHASES = {
	creator_open = true,
	awaiting_commit = true,
}

-- Milliseconds between two passes, matching the watch that drives this file.
local WATCH_MS = 200

-- When the last captured face went out, in milliseconds.
local lastSaveAtMs = 0

-- A creation editor is being waited for or opened, when it was last asked for,
-- and whether it was then seen on screen.
local creatorOpening = false
local creatorAskedAtMs = 0
local creatorShown = false

-- Whether the creation screen on its way up is the game's own creator, which
-- answers in a mailbox, rather than the mirror, which raises the host's
-- confirmed and cancelled events like any other edit.
local creatorNative = false

-- Every code the server answers a face save with. A code outside this set is a
-- protocol drift worth one log line, and is handled like any other refusal.
local REFUSALS = {
	['appearance.invalid'] = true,
	['appearance.stale'] = true,
	['appearance.tooLarge'] = true,
	['error.badRequest'] = true,
	['error.notLoggedIn'] = true,
	['error.tooFast'] = true,
	['error.unavailable'] = true,
}

-- Says what a creation just did, in the SERVER's journal as well as this
-- client's log. A creation happens before the player is in the world, which is
-- exactly where a client log is hardest to ask for and where a player who is
-- stuck can say only that nothing happened. It used to be written out here; it
-- is `Runtime.Note` now, because the clothing half and the fitting room needed
-- the same door and three copies of it would have been three chances to forget
-- the server half of the line. A creation spends at most four of its forty.
local note = Runtime.Note

--- Releases the native transaction a moment later.
-- Not on this stack: the engine is still settling the face it has just accepted,
-- and releasing inside the confirmation loses it.
local function releaseSoon()
	CreateThread(function()
		Wait(250)
		Runtime.FinishMutation()
	end)
end

--- Puts the stored face back after an edit that did not land.
local function rollback(reason)
	Runtime.FinishMutation()
	if type(State.canonical) ~= 'table' then return end
	local snapshot, citizen, token = State.canonical, State.citizenId, State.restoreToken
	CreateThread(function()
		if State.citizenId ~= citizen or not State.Current(token) then return end
		local ok, failure = Runtime.ApplySnapshot(snapshot, 8, token)
		if State.citizenId ~= citizen or not State.Current(token) then return end
		if not ok then
			Runtime.Notify('error', 'appearance.rollbackFailed',
				{ reason = tostring(reason), failure = tostring(failure) })
		end
	end)
end

--- Sends a captured face to the server once its cooldown has passed.
-- The cooldown is WAITED OUT rather than tripped: a save refused for being early
-- is a save the player has to make again, and they cannot see that it failed.
-- @param kind string `edit` or `create`
-- @param family string|nil the body a creation was built on, never sent for an edit
local function send(payload, kind, onNotSent, family)
	local commit = { kind = kind, family = family, deadlineMs = 0 }
	State.commit = commit
	local citizen = State.citizenId
	local cooldown = M.ConfigMs(M.Settings.SAVE_COOLDOWN_MS) or 2000
	local commitMs = M.ConfigMs(M.Settings.COMMIT_MS) or 20000
	CreateThread(function()
		local idle = cooldown - (Runtime.NowMs() - lastSaveAtMs)
		if idle > 0 then Wait(idle) end
		if State.commit ~= commit or State.citizenId ~= citizen then return end
		lastSaveAtMs = Runtime.NowMs()
		State.commit.deadlineMs = Runtime.NowMs() + commitMs
		local sent, reason = TriggerServerEvent(M.Event.SAVE_FACE,
			{ snapshot = payload, citizenId = citizen, family = family })
		if sent then return end
		State.commit = nil
		onNotSent(tostring(reason or 'not_sent'))
	end)
end

--- Ends a creation that stored nothing and settles on the default face.
-- Nobody is ever left unable to enter: the character exists either way, only its
-- face does not. It is not reopened for this character again this session, or it
-- would come straight back up on top of somebody standing in the city.
--
-- EVERY CREATION THAT ENDS BADLY ENDS HERE, which is why the bootstrap is
-- answered here too. Opening the game's own creator arms a bootstrap transaction
-- and the creator is the only thing that would have answered it; one left armed
-- is a player behind the loading cover for the rest of the session. Spending it
-- on the body already loaded costs nothing when none was armed -- a bootstrap
-- that is already spent ignores this.
local function enterPristine(reason)
	State.creating = false
	State.creatorUp = false
	creatorNative = false
	State.commit = nil
	State.creationRefused = true
	Runtime.ResolveBootstrap(Runtime.BodyFamily() or Runtime.DefaultFamily())
	note(('the creation ended with no face stored: %s'):format(tostring(reason)))
	Runtime.Publish({ ok = false, event = 'created', error = tostring(reason),
		citizenId = State.citizenId })
	Runtime.Notify('error', 'appearance.creationNotSaved', { reason = tostring(reason) })
	Runtime.BeginPristine('creation_ended')
end

--- Opens the game's own character creator, or the mirror when it cannot be had.
-- @author dop42
--
-- The body is NOT decided here and no body is reloaded to open on: the creator
-- opens on the body choice itself, and the family it answers is the character's.
--
-- THE TWO SCREENS WANT OPPOSITE THINGS. The creator is the pre-game menu's and
-- needs NO world -- waiting for one before asking for it would be waiting for
-- the world it is there to decide, a wait nothing ends, since the bootstrap that
-- would load it is the one the creator answers. The mirror is the opposite: it
-- dresses a body, so it waits for a world to hold one. Falling back from the
-- first to the second therefore has to spend the bootstrap on the way.
local function openCreator()
	State.creating = true
	if creatorOpening or State.creatorUp then return end
	creatorOpening = true
	local citizen = State.citizenId

	CreateThread(function()
		local function gone()
			return not State.creating or State.creatorUp or State.citizenId ~= citizen
		end

		-- Naming the branch this creation takes. A creation that opens nothing is a
		-- player who never enters the world, and the only other evidence of which
		-- door was tried is the absence of a screen.
		note(('creation for %s: creator natives=%s bootstrap=%s'):format(tostring(citizen),
			tostring(Runtime.CreatorAvailable()), tostring(Runtime.BootstrapPhase())))

		if Runtime.CreatorReady() and not gone() then
			local opened, reason = Runtime.RequestCreator()
			if opened then
				creatorOpening = false
				creatorNative = true
				State.creatorUp = true
				creatorAskedAtMs, creatorShown = Runtime.NowMs(), false
				note('the character creator was asked for; the body family is its answer')
				return
			end
			note(('the character creator refused (%s): the mirror takes the creation')
				:format(tostring(reason)))
		end

		-- THE MIRROR NEEDS A WORLD, AND A WORLD NEEDS THE BOOTSTRAP ANSWERED. The
		-- creation holding it open is the only thing that would have answered it,
		-- so waiting for a world before spending it is a wait nothing ends: the
		-- player sits in the menu with no creator, no mirror and no world, and the
		-- platform's readiness gate never opens -- which is what every admin screen
		-- reads as "joining". Spent here on the body already loaded, and a no-op
		-- when the creator took the transaction instead.
		Runtime.ResolveBootstrap(Runtime.BodyFamily() or Runtime.DefaultFamily())

		while not Runtime.Faceable() or Runtime.IsDown() do
			-- The captured citizen id is what ends this wait: a character change
			-- must not open an editor for the one that left.
			if not State.creating or State.citizenId ~= citizen then
				creatorOpening = false
				return
			end
			Wait(WATCH_MS)
		end
		creatorOpening = false
		if gone() then return end

		-- No `gender` is passed: there is no family to ask for yet, and passing one
		-- would reload the world to open an editor on a body nobody chose.
		local mirrored, refusal = Open77.appearance.open({ mode = 'ripperdoc' })
		if mirrored then
			creatorNative = false
			State.creatorUp = true
			creatorAskedAtMs, creatorShown = Runtime.NowMs(), false
			note(('the creation mirror is up on the %s body'):format(tostring(Runtime.BodyFamily())))
			return
		end
		Runtime.Notify('error', 'appearance.creatorUnavailable', { reason = tostring(refusal) })
		enterPristine('character_creator_unavailable')
	end)
end

--- Answers `needsCreation` by opening the creation editor for the live character.
-- @author dop42
-- @return boolean
-- @return string|nil the refusal
function M.Editor.Creator()
	if Runtime.IsDown() then return false, 'player_down' end
	if State.citizenId == nil then return false, 'no_character' end
	if State.creating then return false, 'appearance_busy' end
	if State.editing or Runtime.ModalOnScreen() then return false, 'appearance_busy' end
	if State.commit ~= nil then return false, 'appearance_busy' end
	if State.creationRefused then return false, 'creation_refused' end
	if type(State.canonical) == 'table' then return false, 'already_has_a_face' end
	State.creationAskedAtMs = 0
	openCreator()
	return true
end

--- Completes a creation whose face the server stored.
-- @author dop42
--
-- The bootstrap the creator was opened for is answered HERE and nowhere earlier:
-- it is what loads the world on the body that was just built, and answering it
-- before the server held the face would have loaded a world for a creation that
-- could still be refused.
-- @param family string|nil the body it was built on
function M.Editor.FinishCreation(family)
	State.creating = false
	State.creatorUp = false
	creatorNative = false
	if M.IsFamily(family) then
		State.family = family
		Runtime.ResolveBootstrap(family)
	end
	State.Wore()
	Runtime.Publish({ ok = true, event = 'created', citizenId = State.citizenId,
		family = State.family })
	Runtime.Notify('success', 'appearance.created')
	Runtime.Announce()
end

--- Captures a confirmed creation and sends it with the body it was built on.
-- @param family string|nil what the creator answered; the loaded body otherwise
local function confirmCreation(family)
	State.creatorUp = false
	creatorNative = false

	-- The creator names the family in its own answer. The mirror does not, so the
	-- body the player is standing on is read instead: that is the one they built.
	if not M.IsFamily(family) then family = Runtime.BodyFamily() end
	if not M.IsFamily(family) then
		Runtime.FinishMutation()
		return enterPristine('body_family_unknown')
	end

	local payload, why = Snapshot.Capture()
	if payload == nil then
		Runtime.FinishMutation()
		return enterPristine(tostring(why or 'character_capture_failed'))
	end

	-- Held here so everything after this reads the body that was built; the
	-- character row learns it from the server, on this same message, once.
	State.family = family

	send(payload, 'create', function(reason)
		Runtime.FinishMutation()
		enterPristine(reason)
	end, family)
end

--- Reads the creator's one-shot answer and acts on it, once it has one.
-- `confirmed:female`, `confirmed:male` and `cancelled` are the platform's own
-- words for it. A fourth answer is a protocol drift, and ends the creation the
-- way a cancellation does rather than being guessed at.
local function takeCreatorResult()
	local result = Runtime.TakeCreatorResult()
	if result == nil then return end
	if result == 'cancelled' then
		Runtime.FinishMutation()
		return enterPristine('character_creation_cancelled')
	end

	local action, family = result:match('^([^:]+):(.+)$')
	if action == 'confirmed' and M.IsFamily(family) then return confirmCreation(family) end

	Open77.log.warn(('[appearance] the character creator answered %q'):format(result))
	Runtime.FinishMutation()
	enterPristine('invalid_creator_result')
end

--- Asks the server to store a face, by default a capture.
-- @author dop42
-- @param snapshot table|nil
-- @return boolean
-- @return string|nil the refusal
function M.Editor.Save(snapshot)
	if State.citizenId == nil then return false, 'no_character' end
	if State.commit ~= nil then return false, 'appearance_busy' end
	if State.editing or State.creating then return false, 'appearance_busy' end

	local payload, reason
	if snapshot == nil then
		payload, reason = Snapshot.Capture()
	else
		payload, reason = Snapshot.ForNetwork(snapshot)
	end
	if payload == nil then return false, tostring(reason or 'capture_failed') end
	if not M.BuildAccepted(payload.gameBuild) then
		return false, 'stored_build_mismatch'
	end

	-- A save that changes nothing is completed here: the server writes nothing and
	-- publishes nothing for a face identical to the stored one, so waiting for an
	-- answer would time out on a correct save.
	if Snapshot.Same(payload, State.canonical) then
		-- Deferred, so the caller learns the save was accepted before anything can
		-- act on the decision it raises.
		CreateThread(function()
			Runtime.Publish({ ok = true, event = 'saved', citizenId = State.citizenId,
				unchanged = true })
		end)
		return true
	end

	send(payload, 'edit', function(failure)
		Runtime.Publish({ ok = false, event = 'saved', error = failure,
			citizenId = State.citizenId })
		Runtime.Notify('error', 'appearance.saveFailed', { reason = failure })
	end)
	return true
end

--- Asks for the native face editor on the live character.
-- @author dop42
-- @param mode string `ripperdoc` or `hairdresser`
-- @return boolean
-- @return string|nil the refusal
function M.Editor.Open(mode)
	mode = tostring(mode or 'ripperdoc'):lower()
	if mode ~= 'ripperdoc' and mode ~= 'hairdresser' then return false, 'invalid_mode' end
	if Runtime.IsDown() then return false, 'player_down' end
	if State.creating then return false, 'character_creation_in_progress' end
	if State.editing or Runtime.ModalOnScreen() then return false, 'appearance_busy' end
	if State.commit ~= nil then return false, 'appearance_busy' end
	if State.citizenId == nil then return false, 'no_character' end

	if type(State.canonical) ~= 'table' or not M.BuildAccepted(State.canonical.gameBuild) then
		Runtime.Notify('warning', 'appearance.editorDefaultFace')
	end

	-- No gender is ever passed here: `openEditor` must not be able to change a
	-- character's body family, which belongs to the character row.
	State.editing = true
	CreateThread(function()
		if Runtime.IsDown() then
			State.editing = false
			return
		end
		local opened, reason = Open77.appearance.open({ mode = mode })
		if opened then return end
		State.editing = false
		Runtime.Notify('error', 'appearance.editorUnavailable', { reason = tostring(reason) })
	end)
	return true
end

--- Whether a creation is waiting for an editor nothing is opening.
local function creationStalled()
	return State.creating and not State.creatorUp and not creatorOpening and State.commit == nil
end

--- Picks up what a body-family reload answered on its other side.
local function resumeFamilyTransition()
	local result = Open77.appearance.takeBodyFamilyTransition()
	if type(result) ~= 'string' or result == '' then return false end
	local action, family = result:match('^([^:]+):(.+)$')
	if action == 'error' then
		Runtime.Notify('error', 'appearance.bodyChangeFailed', { reason = tostring(family) })
		State.bodyReloading = false
		State.bodyReloadingSince = 0
		Runtime.LiftCover('body_family_transition_error')
		Runtime.MarkWorldEligibility('body_family_transition_error')
		if creationStalled() then return enterPristine('body_family_mismatch') end
		State.settled = false
		Runtime.ResolveCharacter('body_family_transition_error')
		return true
	end
	if action ~= 'edit' then
		Open77.log.debug('[appearance] body family transition: ' .. result)
		return true
	end
	if not M.IsFamily(family) then
		Runtime.Notify('error', 'appearance.bodyChangeInvalid')
		return true
	end
	Open77.log.info(('[appearance] body family transition answered %s'):format(result))
	if creationStalled() then openCreator() end
	return true
end

--- One pass over creations, family transitions and save deadlines.
-- @author dop42
--
-- Driven by the scheduler rather than a thread of its own: exceeding the
-- per-resume instruction budget unwinds out of a coroutine body, and a
-- `while true` loop that hits it is never resumed again, silently -- which here
-- would mean a body reload nobody ends and a gate nobody opens.
function M.Editor.Watch()
	Runtime.WarnUnanswered()
	resumeFamilyTransition()

	-- The creator's answer is a mailbox with exactly one reader, and this is it.
	if creatorNative and State.creatorUp then takeCreatorResult() end

	if creationStalled() and Runtime.Faceable() then openCreator() end

	if State.creatorUp and creatorAskedAtMs ~= 0 and not creatorShown then
		local waited = Runtime.NowMs() - creatorAskedAtMs
		local phase = Runtime.BootstrapPhase()
		if Runtime.ModalOnScreen() or CREATOR_PHASES[phase] then
			creatorShown = true
		elseif waited >= CREATOR_UNSEEN_MS then
			creatorShown = true
			Open77.log.warn(('[appearance] the creation editor asked for %d ms ago is not on ' ..
				'screen: reset=%s life=%s bootstrap=%s'):format(waited,
					tostring(Runtime.PlayerResetPhase()), tostring(Runtime.LifePhase()), phase))
			-- Nothing on screen, and the platform's own projection has no creator
			-- open either. That is not a creation that has to end -- the mirror is
			-- still there. The bootstrap the creator was asked for is answered
			-- first, so the next attempt is refused and the mirror is what opens.
			if creatorNative then
				creatorNative = false
				State.creatorUp = false
				Runtime.ResolveBootstrap(Runtime.BodyFamily() or Runtime.DefaultFamily())
				Runtime.LiftCover('character_creator_unseen')
				openCreator()
			end
		end
	end

	local pending = State.commit
	if pending ~= nil and pending.deadlineMs > 0 and Runtime.NowMs() >= pending.deadlineMs then
		State.commit = nil
		if pending.kind == 'create' then
			Runtime.FinishMutation()
			enterPristine('save_timeout')
		else
			rollback('save_timeout')
			Runtime.Notify('error', 'appearance.saveTimedOut')
		end
	end
end

--- Registers the modal and save handlers.
-- @author dop42
function M.Editor.Wire()
	AddEventHandler(M.HostEvent.CONFIRMED, function()
		-- The game's own creator answers in the mailbox `Watch` reads and not
		-- here. Anything this event says while it is up is the engine settling
		-- its own screen, never the player's answer to this module.
		if State.creatorUp then
			if creatorNative then return end
			return confirmCreation()
		end
		if not State.editing then
			-- Not a player confirming anything: the mirror acknowledging the
			-- restore this world entry queued, which is what the announcement
			-- has been waiting on.
			if State.bootstrapToken == State.restoreToken and State.bootstrapQueued then
				State.appearanceConfirmed = true
				-- The announcement is what releases the mutation, and when the
				-- platform's armed reset made it go out AHEAD of the face it has
				-- already gone: the release is then this confirmation's to do.
				if not Runtime.Announce() and State.gameplayAnnounced then
					Runtime.FinishMutation()
				end
			else
				Runtime.FinishMutation()
			end
			return
		end
		State.editing = false

		local payload, why = Snapshot.Capture()
		if payload == nil then
			why = tostring(why or 'capture_failed')
			rollback(why)
			return Runtime.Notify('error', 'appearance.captureFailed', { reason = why })
		end

		if Snapshot.Same(payload, State.canonical) then
			State.Wore()
			releaseSoon()
			Runtime.Publish({ ok = true, event = 'saved', citizenId = State.citizenId,
				unchanged = true })
			return Runtime.Notify('success', 'appearance.saved')
		end

		send(payload, 'edit', function(reason)
			rollback(reason)
			Runtime.Notify('error', 'appearance.saveFailed', { reason = reason })
		end)
	end)

	AddEventHandler(M.HostEvent.CANCELLED, function()
		-- As above: a creator that was walked out of says so in its mailbox.
		if State.creatorUp and creatorNative then return end
		local creation = State.creatorUp
		State.editing = false
		State.creatorUp = false
		Runtime.FinishMutation()
		if creation then enterPristine('character_creation_cancelled') end
	end)

	RegisterNetEvent(M.Event.FACE_SAVED, function(snapshot)
		if type(snapshot) ~= 'table' then return end
		local pending = State.commit
		State.commit = nil
		State.canonical = snapshot

		if pending ~= nil and pending.kind == 'create' then
			return Editor.FinishCreation(pending.family)
		end
		if pending ~= nil then
			State.Wore()
			releaseSoon()
			Runtime.Publish({ ok = true, event = 'saved', citizenId = State.citizenId })
			Runtime.Notify('success', 'appearance.saved')
			return
		end

		-- Nothing pending: this face was stored somewhere else, so it is put on.
		Runtime.BeginRestore(snapshot, 'server')
	end)

end

--- Ends the pending face save the server refused.
-- @author dop42
--
-- Only a refusal naming a FACE save is this one's: an `error.tooFast` raised by a
-- clothing save, or by anything else, is left alone rather than taken for the
-- answer to a capture still in flight. The server already toasted this code
-- through the runtime's refusal channel, which guarantees it is in the catalogue,
-- so nothing is said here twice.
-- @param code string
-- @param operation string
function M.Editor.OnRefused(code, operation)
	local pending = State.commit
	if pending == nil or operation ~= M.Operation.SAVE_FACE then return end
	code = tostring(code)
	if not REFUSALS[code] then
		Open77.log.warn(('[appearance] a face save was refused with an unlisted code: %s')
			:format(code))
	end
	State.commit = nil
	if pending.kind == 'create' then return enterPristine(code) end
	Runtime.Publish({ ok = false, event = 'saved', error = code, citizenId = State.citizenId })
	rollback(code)
end
