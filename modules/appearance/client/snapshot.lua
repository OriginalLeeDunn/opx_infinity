--- The shape of a face on the wire, and everything this client knows about the
--- live character's one.
-- @author dop42
--
-- Nothing here is authoritative: a modified client can rewrite every value below,
-- and the server re-derives anything that matters. What it is for is knowing when
-- this world entry's appearance work has FINISHED, because that answer is what
-- decides whether the player is ever let into the world at all.

local M = OPX.Modules.Get('appearance')

M.Snapshot = {}
local Snapshot = M.Snapshot

--- Reduces a capture to the four fields that are the face, option names
--- lower-cased.
-- @author dop42
--
-- Lower-cased here exactly as the server canonicalises it, so that `Same` can
-- compare a fresh capture against a face the server has already stored. The
-- editor metadata the capture also carries is dropped: the runtime's value codec
-- does not carry it, and it is not part of the face.
-- @param capture any
-- @return table|nil
-- @return string|nil the code
function M.Snapshot.ForNetwork(capture)
	if type(capture) ~= 'table' or type(capture.options) ~= 'table' then
		return nil, 'invalid_snapshot'
	end
	local payload = {
		schemaVersion = capture.schemaVersion,
		gameBuild = capture.gameBuild,
		catalogDigest = capture.catalogDigest,
		gender = capture.gender,
		options = {},
	}
	for index = 1, #capture.options do
		local option = capture.options[index]
		if type(option) ~= 'table' then return nil, 'invalid_option' end
		if type(option.name) ~= 'string' then return nil, 'invalid_option_name' end
		payload.options[index] = {
			part = option.part,
			name = option.name:lower(),
			value = option.value,
			choices = option.choices,
		}
	end
	return payload
end

--- Captures the puppet's face in network form, a refusal as a code.
-- @author dop42
-- @return table|nil
-- @return string|nil the code
function M.Snapshot.Capture()
	local read, capture, failure = pcall(Open77.appearance.capture)
	if not read then return nil, 'capture_failed' end
	if type(capture) ~= 'table' then return nil, tostring(failure or 'capture_failed') end
	local payload, reason = Snapshot.ForNetwork(capture)
	if payload == nil then return nil, tostring(reason) end
	return payload
end

--- Whether two snapshots describe the same face.
-- @author dop42
-- @param left table|nil
-- @param right table|nil
-- @return boolean
function M.Snapshot.Same(left, right)
	if type(left) ~= 'table' or type(right) ~= 'table' then return false end
	if left.gameBuild ~= right.gameBuild or left.catalogDigest ~= right.catalogDigest then
		return false
	end
	if left.gender ~= right.gender then return false end
	if type(left.options) ~= 'table' or type(right.options) ~= 'table' then return false end
	local count = #left.options
	if count ~= #right.options then return false end
	for index = 1, count do
		local a, b = left.options[index], right.options[index]
		if a.part ~= b.part or a.name ~= b.name or a.value ~= b.value then return false end
	end
	return true
end

-- ── what this client knows ───────────────────────────────────────────────────
-- `M.Face` and not `M.State`: the registry owns `State` on every module table --
-- it is the lifecycle phase -- and hanging this here would overwrite it and stop
-- the module dead at `started`.

M.Face = {}
local State = M.Face

--- Clears every field to the state of a client with no character.
-- @author dop42
function M.Face.Reset()
	-- The live character, its body family, and the stored face as PlayerData
	-- carries it.
	State.citizenId = nil
	State.family = nil
	State.canonical = nil

	-- The character whose face was last accepted onto the puppet, and that face.
	State.appliedCitizen = nil
	State.appliedSnapshot = nil

	-- The current restore generation, the last one that settled, the one the
	-- readiness announcement waits on, and whether it queued the mirror.
	State.restoreToken = 0
	State.restoreSettledToken = 0
	State.bootstrapToken = nil
	State.bootstrapQueued = false
	State.appearanceConfirmed = false
	-- The restore generation that is waiting on nothing but the platform's own
	-- pristine reset of the body, nil when none is. See `AwaitingPlatform`.
	State.platformWaitToken = nil

	-- This world entry's pristine player reset has run, and the re-dispatches
	-- spent on the current bootstrap restore.
	State.playerResetDone = false
	State.restoreAttempts = 0

	-- The character whose stored face a dead body made this world entry give up,
	-- nil when none is owed. See `Runtime.ResumeOwedFace`.
	State.faceOwed = nil

	-- This world is the gameplay one and not the pre-game menu, the announcement
	-- went out for it, and this world entry's face has been decided.
	State.worldEligible = false
	State.gameplayAnnounced = false
	State.settled = false

	-- A native modal this module owns is open, a creation runs from openCreator to
	-- the server's answer, and the creation editor is up.
	State.editing = false
	State.creating = false
	State.creatorUp = false

	-- A captured face sent to the server and not yet answered: { kind, deadlineMs }.
	State.commit = nil

	-- This character was told its stored face is from another build, how many body
	-- family attempts it has spent, and whether a reload has not reached its new
	-- puppet's reset yet.
	State.buildWarned = false
	State.familyAttempts = 0
	State.bodyReloading = false
	-- When that reload started, 0 when none is running. It is the only thing
	-- standing between a reset projection that never moves and a player left under
	-- the loading cover the reload put up.
	State.bodyReloadingSince = 0

	-- This character's creation ended without a face, when an unanswered
	-- needsCreation went out (0 when none waits), and whether that wait ran out.
	State.creationRefused = false
	State.creationAskedAtMs = 0
	State.creationWarned = false
end

M.Face.Reset()

--- Starts a restore generation and answers its token.
-- @author dop42
-- @return integer
function M.Face.NextRestore()
	State.restoreToken = State.restoreToken + 1
	State.bootstrapToken = State.restoreToken
	State.bootstrapQueued = false
	State.appearanceConfirmed = false
	return State.restoreToken
end

--- Whether a token is still the current restore generation.
-- A thread holding an older one has been replaced and must stop, rather than
-- finish work for a character that has gone.
-- @author dop42
-- @param token integer
-- @return boolean
function M.Face.Current(token)
	return token == State.restoreToken
end

--- Whether the puppet already wears this character's stored face.
-- @author dop42
-- @return boolean
function M.Face.Wearing()
	return State.appliedCitizen ~= nil and State.appliedCitizen == State.citizenId and
		Snapshot.Same(State.appliedSnapshot, State.canonical)
end

--- Records that the stored face was accepted onto the puppet.
-- @author dop42
function M.Face.Wore()
	State.appliedCitizen = State.citizenId
	State.appliedSnapshot = State.canonical
end

--- Forgets which face is on the puppet.
-- @author dop42
function M.Face.Undress()
	State.appliedCitizen = nil
	State.appliedSnapshot = nil
end

--- Whether every piece of appearance work for this world entry has finished.
-- @author dop42
--
-- THIS IS THE GATE QUESTION. The readiness announcement goes out when this turns
-- true and at no other moment, so every `false` below is a reason nobody spawns.
-- A FAILED restore is an honestly settled state: it must not hold the player
-- behind the gate.
-- @return boolean
function M.Face.AppearanceSettled()
	if State.citizenId == nil then return false end
	if not State.settled or State.creating or State.bodyReloading then return false end
	-- An unanswered needsCreation still waits: an editor may yet come.
	if State.creationAskedAtMs ~= 0 then return false end
	if State.commit ~= nil and State.commit.kind == 'create' then return false end
	if State.restoreToken ~= State.restoreSettledToken then return false end
	if State.bootstrapToken == State.restoreToken and State.bootstrapQueued then
		return State.appearanceConfirmed and State.playerResetDone
	end
	return true
end

--- Whether the face is settled in everything but a restore the platform holds.
-- @author dop42
--
-- THE PLATFORM GOES FIRST, AND THAT IS ITS ORDER, NOT OURS. On op77.121 a joining
-- player's puppet attaches with its pristine reset ARMED (`local player attached
-- ... reset=armed`) and the host runs that reset -- and only then places the body
-- and brings it alive -- AFTER `open77:session:gameplayReady`. Every join in the
-- owner's log of 2026-10-02 shows it: the announcement at 15:17:32.146, the reset
-- `clearing` 0.6 s later, `reset_complete` at .950, `life placement settled` at
-- 33.261. A restore that waits for a live body before letting the announcement
-- out is waiting for something only the announcement can start; the 5 s / 3 s
-- safety nets were all that broke it, and they gave the face up for the entry,
-- so every join landed on the default face.
--
-- So a restore waiting on the platform alone does not hold the gate: the
-- announcement goes out, the platform resets and revives the body, and the
-- restore -- still owning its token -- puts the face on that live body.
-- Everything else `AppearanceSettled` refuses still refuses here, and a reset
-- that has already run this entry means the platform is no longer the one
-- holding anything.
-- @return boolean
function M.Face.AwaitingPlatform()
	if State.citizenId == nil then return false end
	if not State.settled or State.creating or State.bodyReloading then return false end
	if State.creationAskedAtMs ~= 0 then return false end
	if State.commit ~= nil and State.commit.kind == 'create' then return false end
	if State.playerResetDone then return false end
	return State.platformWaitToken ~= nil and State.platformWaitToken == State.restoreToken and
		State.restoreToken ~= State.restoreSettledToken
end

--- Clears what a new world entry invalidates, keeping the character.
-- @author dop42
function M.Face.EnterWorld()
	if M.Clothing then M.Clothing.EnterWorld() end
	State.settled = false
	State.gameplayAnnounced = false
	State.bootstrapToken = nil
	State.bootstrapQueued = false
	State.appearanceConfirmed = false
	State.playerResetDone = false
	State.platformWaitToken = nil
	State.restoreAttempts = 0
	-- A new world entry restores the face on its own.
	State.faceOwed = nil
end

--- Forgets the character, its face and any restore still under way.
-- The new generation is taken AND marked settled: a token left behind would make
-- `AppearanceSettled` false for ever, which is the gate shut for ever.
--
-- THE WORLD ENTRY OUTLIVES THE CHARACTER. Two facts here belong to the puppet in
-- this world and not to whoever is wearing it: the platform has run its pristine
-- reset (`playerResetDone`), and gameplay-ready went out (`gameplayAnnounced`).
-- Both used to be cleared with the character, and `CHARACTERS.SWITCH = 'relog'`
-- swaps characters in the world, on the same puppet, with no world entry and no
-- reset to set them again. So the next character's face went on and its entry
-- never settled -- `AppearanceSettled` waits on a reset that was never coming --
-- and with it never announced: its clothes were never put on (`not_announced`),
-- nothing was saved, and the look was withdrawn at the unload and never
-- published again, so every other player stopped seeing them until they
-- reconnected. A real world entry (`WORLD_READY`, a body reload, a restart) goes
-- through `EnterWorld` and clears both, which is where they are owed.
-- @author dop42
function M.Face.Unload()
	State.restoreSettledToken = State.NextRestore()
	State.citizenId = nil
	State.family = nil
	State.canonical = nil
	State.editing = false
	State.creating = false
	State.creatorUp = false
	State.commit = nil
	State.creationRefused = false
	State.creationAskedAtMs = 0
	State.creationWarned = false
	State.familyAttempts = 0
	State.buildWarned = false
	State.Undress()
	local resetDone, announced = State.playerResetDone, State.gameplayAnnounced
	State.EnterWorld()
	State.playerResetDone, State.gameplayAnnounced = resetDone, announced
end

--- The diagnostic fields the `State` contract function answers.
-- @author dop42
-- @return table
function M.Face.Report()
	return {
		citizenId = State.citizenId,
		family = State.family,
		stored = State.canonical ~= nil,
		wearing = State.Wearing(),
		decided = State.settled,
		settled = State.AppearanceSettled(),
		restoring = State.restoreToken ~= State.restoreSettledToken,
		committing = State.commit ~= nil,
		creating = State.creating,
		editing = State.editing,
		worldEligible = State.worldEligible,
		announced = State.gameplayAnnounced,
		bodyReloading = State.bodyReloading,
	}
end
