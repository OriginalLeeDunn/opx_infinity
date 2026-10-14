--- The client half: the state the server pushed, the rows on the eye, the ring.
-- @author dop42
--
-- This file owns a state machine and DRAWS NOTHING. It says everything it has
-- to say on the local `calls:view` event and takes everything back through
-- `M.FromView`; `client/view.lua` is the only file that knows those two ends
-- are a CEF page. That is the seam `modules/downed` uses and it is here for the
-- same reason -- the state half stays testable without a browser.
--
-- NOTHING IN THIS FILE IS A FACT. The server pushes one payload describing this
-- player's whole call world and everything below is a projection of it. A key
-- does not end a call, it asks the server to. The only local state is about
-- this machine's speakers and this screen -- which ring was silenced, which
-- dial tone was stopped, whether the hologram is open -- and the server
-- neither knows nor should.
--
-- ONE SCREEN. The incoming card and the live chip that used to sit at the edge
-- of the view are gone, and with them the card's dwell clock and its
-- dismiss/re-pop pair: the sphere in `HoloRoot.vue` pops on a call arriving,
-- says who it is and which key answers, and takes nothing. So the only payload
-- this file publishes is the hologram's (`kind = 'holo'`).
--
-- ── the rows, and the budget ─────────────────────────────────────────────────
--
-- Seven rows across two kinds. `RegisterMany` is ALL OR NOTHING -- one
-- malformed row refuses the whole batch and the refusal is written to a log on
-- the player's own machine -- which is the trap `modules/animations/client/walk.lua`
-- fell into and documented, so the registration is one `Register*` call per
-- kind with a `Wait(0)` between, on a thread of its own, and the answer of each
-- is checked and relayed with `OPX.Note` rather than `Open77.log`.
--
-- THE ROWS ARE REGISTERED ONCE AND NEVER RE-REGISTERED. `canInteract` is what
-- makes a row appear and disappear: answer is called in-process on every pick,
-- costs a table lookup, and reads the same state the screen does. The first
-- sketch re-registered the set on every state push -- a `Clear` plus two
-- `Register*` calls per incoming call -- which is the admin module's whole
-- instruction-budget story being re-enacted on a hot path.
--
-- ── the sound ────────────────────────────────────────────────────────────────
--
-- `Open77.sfx.play2d(event)` plays one of Cyberpunk's own `ui_phone_01` Wwise
-- events, by name, with nothing shipped and nothing copied -- see the SOUND
-- block in `config/calls.lua`. It is gated on `world.effects`, which this
-- manifest already declares for the vfx the staff noclip pops, and its refusal
-- is SILENT in the same way: the native answers `nil, permission_denied` or
-- `nil, invalid_sfx_event` and logs nothing. So every call goes through `ring`
-- below, which notes the FIRST refusal of each event name to the server and
-- then stops asking about it.

local M = OPX.Modules.Get('calls')

local Model = M.Model


-- The last state the server pushed. Never written from this side.
local state = { call = nil, invite = nil, outgoing = nil }

-- When the ring was last re-armed, and how often it may be.
local lastRingMs = -math.huge
local ringEveryMs = 3500

-- The invite this player already answered or refused. The ring stops on the
-- key press rather than on the server's reply: the round trip is long enough
-- for the re-arm clock to ring once more over the "allô".
--
-- AND IT IS UNDONE WHEN THE SERVER KEEPS THE INVITE. Every answer the server
-- refuses -- `tooFast` included -- goes back with this player's state, so a
-- push that still carries the very invite that was silenced means the answer
-- did not take: the phone rings again and the key works again. Without that the
-- invite sat there silent until it expired, with nothing to say it was still
-- waiting.
local silenced = nil

-- The outgoing call this player already withdrew. Same reason: the dial tone
-- stops on the key, and the server's reply must not play the stop a second time.
local withdrawn = nil

-- Sound event names, settled in `Start` from the config.
local sounds = {}

-- Event names whose refusal has already been reported. One note per name per
-- session: a missing sound is worth saying once and is worth nothing at all
-- forty times.
local mutedEvents = {}

-- The scheduler handles this module holds, so `Stop` can give them back.
local jobs = {}

-- The name the pause plugin re-raises Escape under. A host name, so it is not
-- built from `OPX.Event`, and the same constant `modules/menu` reads.
local PAUSE_KEY = 'open77:pauseKey'

-- When the hologram opened, for Escape's layer order.
local holoOpenedAtMs = 0

-- The view seam, and the one channel every payload travels on.
local EVENT_VIEW = M.Event.VIEW

local function locale(key, params)
	return OPX.Locale.Text(key, params)
end

--- Plays one of the game's own frontend events, at most once per name per
--- refusal.
---
--- A REFUSAL IS A MISSING SOUND AND NEVER A FAILED CALL. The platform refuses
--- an event outside its curated table rather than forwarding it, and every name
--- in the config is carried by the devkit's catalogue as read-from-the-bank but
--- not yet played on this build. So a name that does not take costs the player
--- a ringtone and costs the call nothing.
-- @param event string|nil
local function play(event)
	if type(event) ~= 'string' or event == '' or mutedEvents[event] then return end
	local sfx = Open77.sfx
	if type(sfx) ~= 'table' or type(sfx.play2d) ~= 'function' then return end
	local ok, reason = pcall(sfx.play2d, event)
	-- `pcall` answers (true, nil, reason) when the native refused, so the raise
	-- and the refusal are two different shapes and both are caught here.
	if ok and reason ~= nil then return end
	mutedEvents[event] = true
	-- `OPX.Note` AND NOT `Open77.log.warn`: a client log line is written on the
	-- PLAYER's machine, and a ringtone that never played would otherwise be a
	-- complaint with no evidence anywhere the operator can reach.
	OPX.Note('calls', ('the sound %q did not play: %s'):format(event, tostring(reason)))
end

-- Whether an invite is one the phone rings for. A contact hand-over is not.
local function ringsFor(invite)
	return type(invite) == 'table' and invite.kind ~= 'contact'
end

-- Stops the ring for the invite on screen, at once.
local function silence()
	if state.invite == nil or silenced == state.invite.id then return end
	silenced = state.invite.id
	if ringsFor(state.invite) then play(sounds.INCOMING_STOP) end
end

-- Forward-declared: `onState` below pushes the projection's payload, and it is
-- defined with the rest of the hologram two hundred lines further down.
-- Without this the call would resolve to a global and be nil.
local drawHolo
-- Same reason: `onState` routes the voice the moment a call connects, and the
-- function is defined below it. As a bare global it was nil, and the error cut
-- `onState` short on every call that connected.
local routeVoice

-- Publishes one payload to whatever is drawing this module.
local function publish(payload)
	TriggerEvent(EVENT_VIEW, payload)
end

-- Takes a fresh state from the server and works out what changed, which is the
-- only thing the sounds are keyed off.
local function onState(payload)
	if type(payload) ~= 'table' then return end

	local hadInvite = state.invite ~= nil and state.invite.id or nil
	local hadCall = state.call ~= nil and state.call.id or nil
	local hadOutgoing = state.outgoing ~= nil and state.outgoing.id or nil
	local previous = state
	-- READ BEFORE A NEW INVITE CLEARS IT: the key press already played the stop
	-- for this one, and the reply taking it away must not play it again.
	local stoppedInvite = hadInvite ~= nil and silenced == hadInvite
	local stoppedOutgoing = hadOutgoing ~= nil and withdrawn == hadOutgoing

	state = {
		call = type(payload.call) == 'table' and payload.call or nil,
		invite = type(payload.invite) == 'table' and payload.invite or nil,
		outgoing = type(payload.outgoing) == 'table' and payload.outgoing or nil,
	}

	local nowInvite = state.invite ~= nil and state.invite.id or nil
	local nowCall = state.call ~= nil and state.call.id or nil

	if nowInvite ~= hadInvite then lastRingMs = -math.huge end

	-- THE SERVER KEPT AN INVITE THIS PLAYER ALREADY ANSWERED: the answer was
	-- refused (`tooFast`, or any other reason that leaves it standing) and the
	-- refusal came back with this push. Un-silenced, and the clock re-armed so
	-- the very next tick rings -- the same invite ringing again rather than
	-- sitting there mute until it expires. The ring that resumes is what tells
	-- the player to press again.
	if nowInvite ~= nil and nowInvite == hadInvite and silenced == nowInvite then
		silenced = nil
		lastRingMs = -math.huge
	end
	-- THE SAME FOR A WITHDRAWAL THE SERVER REFUSED: the dial tone stopped on the
	-- key, the invite is still out, so the tone comes back and the key works
	-- again rather than leaving a call ringing out in silence.
	local nowOutgoing = state.outgoing ~= nil and state.outgoing.id or nil
	if nowOutgoing ~= nil and nowOutgoing == hadOutgoing and withdrawn == nowOutgoing then
		withdrawn = nil
		if ringsFor(state.outgoing) then play(sounds.OUTGOING) end
	end

	-- The ring starts on an invite arriving and stops on it going, whichever way
	-- it went -- answered, refused, expired or the caller hanging up. The stop
	-- event exists because `ui_phone_incoming_call` is a one-shot with no
	-- handle: there is nothing to stop, so the bank carries a separate event
	-- that plays the line closing.
	-- A CONTACT HAND-OVER DOES NOT RING. The owner: "quand quelqu'un demande le
	-- contact ne joue pas de son d'appel". It is a yes/no from somebody standing
	-- in front of you, not a call, so neither side hears the phone.
	if nowInvite ~= nil and nowInvite ~= hadInvite then
		silenced = nil
		if ringsFor(state.invite) then
			play(sounds.INCOMING)
			lastRingMs = OPX.Now()
		end
	end
	-- STOPPED WHENEVER THE INVITE WENT, including when a second one replaced it:
	-- answered, refused, expired or withdrawn by the caller.
	if hadInvite ~= nil and nowInvite ~= hadInvite and ringsFor(previous.invite)
		and not stoppedInvite then
		play(sounds.INCOMING_STOP)
	end

	-- THE DIAL TONE STOPS ON EVERY WAY OUT, answered included. It used to be
	-- skipped when the call connected, and the caller went on hearing it over
	-- the other person's voice.
	if hadOutgoing == nil and state.outgoing ~= nil and ringsFor(state.outgoing) then
		play(sounds.OUTGOING)
	elseif hadOutgoing ~= nil and state.outgoing == nil and ringsFor(previous.outgoing)
		and not stoppedOutgoing then
		play(sounds.OUTGOING_STOP)
	end

	if nowCall ~= nil and nowCall ~= hadCall then
		play(sounds.ACCEPTED)
		-- At once, not on the next sweep: the first half-second of a call is
		-- exactly when somebody says "allô".
		routeVoice()
	elseif hadCall ~= nil and nowCall == nil then
		play(sounds.HANG_UP)
		-- AND THE ROUTE GOES BACK. Nothing set it back when the call ended, so
		-- the intent stayed `all` for the rest of the session -- and a player
		-- another resource puts on a voice channel (a radio) spoke into it from
		-- their first holocall on, without pressing anything.
		routeVoice('proximity')
	end

	-- THE PROJECTION KNOWS ABOUT THE CALL TOO. It is not only the screen the
	-- player opens: a call arriving pops the sphere with the caller in it and
	-- nothing else, which is the owner's "tu vas juste pop l'animation pas le
	-- menu". So the holo payload goes out on every state change as well as on
	-- every open.
	drawHolo()
end

-- ── the route this machine's own voice takes ─────────────────────────────────
--
-- THE OWNER: "petit bug quand il repond a l'appel on s'entend pas". The server
-- half of that is a voice channel per call and membership on it -- see
-- `modules/calls/server/main.lua` -- and membership is what makes the other
-- person AUDIBLE. It is not what makes you audible to them.
--
-- A client captures one stream and ROUTES it: `setTransmitting`'s intent picks
-- between proximity, the channels you are a member of, or both. The default is
-- proximity, which across Night City reaches nobody, so two people on a call
-- could each hear a channel neither of them was speaking into.
--
-- THE MIC IS NEVER FORCED OPEN, and the shape below is the whole of that
-- promise: `enabled` is read back out of `Open77.voice.status()` and handed
-- straight back. This says "whatever you are doing with the microphone, keep
-- doing it, and send it to the call as well" -- it cannot start a transmission
-- and it cannot stop one. `all` rather than `channels` because a holocall in a
-- shared world should still be half-audible to whoever is standing next to you.
--
-- Re-asserted on the sweep as well as on the state change, because `open-voice`
-- owns the push-to-talk key and drives the same native; if it re-states the
-- intent, this takes it back within half a second rather than for good.
function routeVoice(intent)
	local api = Open77.voice
	if type(api) ~= 'table' or type(api.setTransmitting) ~= 'function' then return end
	if type(api.status) ~= 'function' then return end

	local read, status = pcall(api.status)
	if not read or type(status) ~= 'table' then return end

	-- Two names for the same fact across builds, and neither is guessed at: the
	-- card for `status` promises "PTT/VAD state" without fixing the field, so
	-- both are read and anything else leaves the route alone.
	local talking = status.transmitting
	if type(talking) ~= 'boolean' then talking = status.pushToTalk end
	if type(talking) ~= 'boolean' then return end

	pcall(api.setTransmitting, talking, intent or 'all')
end

-- Re-arms the ring while an invite is waiting, and re-asserts the voice route
-- while a call is live. `ui_phone_incoming_call` is a one-shot, so "it rings
-- until you answer" is a clock rather than a loop.
local function rearm()
	-- BEFORE THE INVITE GUARD, because a call is live long after the invite is
	-- gone and this is the only clock the module runs.
	if state.call ~= nil then routeVoice() end
	if state.invite == nil then return end
	local atMs = OPX.Now()

	if ringsFor(state.invite) and silenced ~= state.invite.id
		and atMs - lastRingMs >= ringEveryMs then
		lastRingMs = atMs
		play(sounds.INCOMING)
	end
end

-- ── what the page asks for ───────────────────────────────────────────────────

--- The other end of the seam. Every action the page may take, and an unknown
--- one is ignored here so `view.lua` need not filter a second time.
-- @author dop42
-- @param action string
-- @param payload table|nil
function M.FromView(action, payload)
	if action == 'ready' then
		-- The page mounted, or this module started. Ask the server for the
		-- state again: a reloaded page has to be told the call it is on.
		TriggerServerEvent(M.Event.READY)
		drawHolo()
		return
	end
	if action == 'accept' then return M.Accept() end
	if action == 'decline' then return M.Decline() end
	if action == 'hangUp' then return M.HangUp() end
	if action == 'withdraw' then return M.Withdraw() end

	-- ── THE HOLOGRAM'S OWN VERBS ─────────────────────────────────────────────
	-- Every one of them names a player id the SERVER then judges again. A page
	-- is the least trustworthy caller in the resource -- it is a browser -- so
	-- the id is bounded through the model here and the rule is applied there.
	if action == 'close' then return M.CloseHolo() end
	if action == 'toggle' then return M.ToggleHolo() end
	if action == 'call' then
		return M.Invite(type(payload) == 'table' and payload.id or nil, nil)
	end
	if action == 'share' then
		-- THE OWNER: "le share contact devrais etre un input qui propose un yes
		-- or no". It always was on the receiving side -- a contact hand-over is
		-- an invite like any other and needs the other party's consent -- and
		-- what was missing is that the ASKING side had no screen of its own.
		-- The page puts the question; this is the yes.
		return M.Invite(type(payload) == 'table' and payload.id or nil, 'contact')
	end
	if action == 'forget' then
		-- A row's reference, as the server minted it with the list; the server
		-- alone knows which contact it stands for, and judges it again.
		local ref = type(payload) == 'table' and payload.ref or nil
		if type(ref) ~= 'string' or #ref > 8 then return end
		TriggerServerEvent(M.Event.FORGET, ref)
		return
	end
	if action == 'diag' then
		OPX.Note('calls', ('view: %s'):format(tostring(type(payload) == 'table'
			and payload.detail or payload)))
		return
	end
end

-- ── the verbs, as the rows and the page call them ────────────────────────────

--- Answers the call waiting for this player. Answers false when there is none,
--- which is what a row's `canInteract` already prevents and what a page cannot
--- be trusted to.
-- @author dop42
-- @return boolean whether anything was asked for
function M.Accept()
	if state.invite == nil then return false end
	-- ONE ANSWER IN FLIGHT. A second press before the reply was a second
	-- request inside the server's cooldown, refused as `tooFast` on the
	-- player's screen over a call that had in fact connected. The reply always
	-- comes -- every path in `onAccept` pushes this player's state -- and a
	-- refused answer un-silences the invite in `onState`, so the key works
	-- again exactly when it can.
	if silenced == state.invite.id then return false end
	silence()
	TriggerServerEvent(M.Event.ACCEPT, state.invite.id)
	return true
end

--- Refuses the call waiting for this player.
-- @author dop42
-- @return boolean
function M.Decline()
	if state.invite == nil then return false end
	-- Same rule as `Accept`: one answer in flight per invite.
	if silenced == state.invite.id then return false end
	silence()
	play(sounds.DECLINED)
	TriggerServerEvent(M.Event.DECLINE, state.invite.id)
	return true
end

--- Withdraws the invite this player sent and nobody has answered yet -- a call
--- ringing out, or a third person being asked to join -- and touches no call.
-- @author dop42
-- @return boolean whether anything was asked for
function M.Withdraw()
	if state.outgoing == nil then return false end
	-- One withdrawal in flight, for the reason `Accept` gives.
	if withdrawn == state.outgoing.id then return false end
	withdrawn = state.outgoing.id
	if ringsFor(state.outgoing) then play(sounds.OUTGOING_STOP) end
	TriggerServerEvent(M.Event.WITHDRAW)
	return true
end

--- Leaves the call this player is on. With no call, withdraws the one they are
--- ringing -- the server reads `HANG_UP` the same way.
-- @author dop42
-- @return boolean
function M.HangUp()
	if state.call == nil then return M.Withdraw() end
	TriggerServerEvent(M.Event.HANG_UP)
	return true
end

--- The refuse key's verb. THE OWNER: hanging up works "la même façon" as
--- answering -- a key named in the sphere, nothing to open.
---
--- THE MOST RECENT THING YOU STARTED IS THE FIRST THING IT STOPS:
---   1. an invite ringing at you      refused
---   2. an invite you sent, ringing   withdrawn
---   3. the call you are on           left
--- The second used to lose to the third. On a live call, asking a third person
--- to join and then thinking better of it ended your own call -- and left the
--- invite ringing on their screen for a call that no longer had you in it. A
--- second press still hangs up.
-- @author dop42
-- @return boolean
function M.DeclineOrHangUp()
	if state.invite ~= nil then return M.Decline() end
	if state.outgoing ~= nil then return M.Withdraw() end
	return M.HangUp()
end

--- The decline key. Whether a press is this module's at all -- a cancelable
--- bar, a carried crate or an emote may hold it -- is decided before this runs,
--- by the contest `bind` enters it in (`OPX.Spots.Key.Owns`).
-- @author dop42
function M.OnDeclineKey()
	return M.DeclineOrHangUp()
end

--- Asks to call, to add, or to share a contact with one player.
---
--- ONE VERB FOR ALL THREE, because the server derives which of them this is
--- from whether the caller is already on a call -- see `registry.Invite`. The
--- client names `contact` or nothing, and naming anything else is a request the
--- server refuses as `badRequest` rather than a shape this file has to know.
-- @author dop42
-- @param playerId integer
-- @param kind string|nil 'contact', or nil for a call
-- @return boolean
function M.Invite(playerId, kind)
	local target = Model.PlayerId(playerId)
	if target == nil then return false end
	TriggerServerEvent(M.Event.INVITE, target, kind == 'contact' and 'contact' or nil)
	return true
end

--- Whether this player is on a call, and what it looks like. For the HUD, for
--- another module, and for a test.
-- @author dop42
-- @return table|nil
function M.State()
	return {
		call = state.call,
		invite = state.invite,
		outgoing = state.outgoing,
	}
end

-- ── the one thing the eye is still right for ─────────────────────────────────
--
-- THE OWNER: "pour demander le contact a quelqun c'est toujours avec alt ? ce
-- serais top", and then: "du coup plus de arround me vu que tu utilise le target
-- pour partager le contact ou avoir le contact".
--
-- ALT CAME BACK FOR EXACTLY ONE ROW, and the reason is the reason it was wrong
-- for the others. The eye needs a body under the crosshair. Answering a call
-- does not have one -- the person is somewhere else, which is the whole point of
-- a holocall -- and the eight rows that used to live here made a player point at
-- their own body to pick up. Handing somebody your contact is the opposite: it
-- IS a thing you do to a person standing in front of you, face to face, within
-- arm's reach, and pointing at them is the natural way to say which one.
--
-- SO THE "AROUND ME" TAB WENT. The hologram grew one when ALT was removed --
-- otherwise a contact list you can only add to with the thing just deleted stays
-- empty forever -- and this row makes it redundant. One way to do a thing.
--
-- THE SERVER STILL DECIDES. The row names a player id and nothing else; the
-- range, the bucket, the consent and the swap are all judged there, by the same
-- function that judges every other invite.
local OWNER = 'calls'

-- Metres the row reaches. Deliberately short and deliberately not the twelve a
-- call row used to have: the server refuses a hand-over beyond `CONTACT_RANGE`,
-- and a row offered where it would be refused is a row that teaches a player the
-- feature is broken.
local ROW_DISTANCE = 6.0

-- The id the eye's context names for the body under the crosshair, as a number.
local function targetOf(context)
	local target = type(context) == 'table' and context.target or nil
	if type(target) ~= 'table' then return nil end
	return Model.PlayerId(target.playerId)
end

--- The one row this module draws on another player.
-- @author dop42
-- @return table[]
function M.PlayerRows()
	return {
		{
			id = 'callShare',
			label = locale('calls.row.share'),
			icon = 'person',
			-- NO FOLDER. It sat alone inside a `Holocall` folder on the eye: one
			-- more press to reach the only row in it.
			order = 60,
			distance = ROW_DISTANCE,
			canInteract = function(context) return targetOf(context) ~= nil end,
			onSelect = function(context)
				local target = targetOf(context)
				if target == nil then return false end
				return M.Invite(target, 'contact')
			end,
		},
	}
end

-- Puts the row on the eye. ON A THREAD with a `Wait(0)`, because `RegisterMany`
-- is ALL OR NOTHING -- one malformed row refuses the whole batch, and the
-- refusal is written to a log on the player's own machine, which is the trap
-- `modules/animations/client/walk.lua` fell into and documented.
local function registerRows(contract)
	Wait(0)
	local answer = contract.RegisterPlayers(OWNER, M.PlayerRows())
	if answer == nil or answer.ok ~= true then
		OPX.Note('calls', ('the contact row was refused: %s')
			:format(tostring(answer and answer.error)))
		return false
	end
	return true
end


-- ── the hologram: one screen, and every verb on it ───────────────────────────
--
-- THE OWNER: "fait en sorte que cela passe pas par alt ce serais en gros fait
-- une touche qui ouvre un menu style halogram tous se passe desus call resus
-- contact etc plus de alt", then "le halo prend vrais le devant de l'ecran" and
-- "en plein centre".
--
-- WHAT WAS HERE BEFORE: eight rows on the target eye and a contacts list drawn
-- with the generic menu module. Both are gone. The eye is where you interact
-- with a thing you are LOOKING AT, and a holocall is the thing you reach for
-- when the person is not there -- answering one meant pointing at your own body
-- first, which is the tell that the mechanism was the one at hand rather than
-- the one the feature wanted.
--
-- ONE SURFACE, TWO MODES. A call arriving, running or ringing out pops the
-- sphere with `open = false`: a name, a key letter, nothing pressable and no
-- focus, so it can never take the mouse or stand between the player and what
-- they are aiming at. The player's own key opens the panel -- focused,
-- pressable, every verb on it -- because that is the thing they deliberately
-- asked for. The incoming card and live chip that used to do the first job on
-- `overlay` are gone.
--
-- THE LIST IS ASKED FOR WHEN THE SCREEN OPENS AND NEVER CACHED. A contact list a
-- minute old is a list of rows that refuse: who is connected, who is already on
-- a call and who is close enough to hand a contact to are all facts with a
-- shelf life measured in seconds, and the server works every one of them out
-- with the SAME function that judges the invite itself.

-- The letter a configured key block names, or nil. The page prints it beside
-- the word that says what it does, so a rebind reaches the player.
local function keyLetter(block)
	local key = type(block) == 'table' and block.DEFAULT or nil
	if type(key) ~= 'string' or key == '' then return nil end
	return key
end

-- Whether the hologram is up, and the last roster the server sent for it.
local holoOpen = false
local roster = { rows = {}, recent = {}, onCall = false }

-- Pushes the whole of what the sphere draws. ONE payload rather than a diff:
-- the page redraws from it whole, so a diff would be more code than the thing
-- it describes.
function drawHolo()
	publish({
		kind = 'holo',
		open = holoOpen,
		rows = roster.rows,
		recent = roster.recent,
		call = state.call,
		invite = state.invite,
		outgoing = state.outgoing,
		-- THE LETTERS THE SPHERE PRINTS. Read off the config rather than written
		-- into the page: a server that rebinds them must not have its players
		-- told the wrong key.
		-- WHERE IT SITS, settled once through the shared vocabulary. The page
		-- takes a name rather than a stylesheet: one word, nine values, refused
		-- and named in the journal when it is none of them.
		anchor = OPX.Anchors.Resolve(M.Settings.ANCHOR, 'bottom-center', 'calls.ANCHOR'),
		answerKey = keyLetter(M.Settings.ANSWER_KEY),
		declineKey = keyLetter(M.Settings.DECLINE_KEY),
	})
end

-- Takes a roster from the server and redraws, if the screen is still up. A
-- roster arriving after the player closed the screen is dropped rather than
-- stored: the next open asks again.
local function onRoster(payload)
	if type(payload) ~= 'table' then return end
	roster = {
		rows = type(payload.rows) == 'table' and payload.rows or {},
		recent = type(payload.recent) == 'table' and payload.recent or {},
		onCall = payload.onCall == true,
	}
	if holoOpen then drawHolo() end
end

--- Opens the hologram and asks for a fresh roster.
-- @author dop42
-- @return boolean
function M.OpenHolo()
	if holoOpen then return true end
	holoOpen = true
	holoOpenedAtMs = OPX.Now()
	-- Drawn before the roster arrives, with whatever the last one held. The
	-- screen must appear on the key press rather than on a round trip: a
	-- hologram that opens a beat after the key is a hologram that feels broken.
	drawHolo()
	TriggerServerEvent(M.Event.ASK_ROSTER)
	return true
end

--- Takes the hologram down.
-- @author dop42
-- @return boolean
function M.CloseHolo()
	if not holoOpen then return false end
	holoOpen = false
	drawHolo()
	return true
end

--- The key's verb, and the page's close button.
-- @author dop42
-- @return boolean
function M.ToggleHolo()
	if holoOpen then return M.CloseHolo() end
	return M.OpenHolo()
end

--- Whether the hologram is up. For a test, and for whatever asks next.
-- @author dop42
-- @return boolean
function M.HoloOpen()
	return holoOpen
end


--- Builds the state.
-- @author dop42
function M.Init()
	state = { call = nil, invite = nil, outgoing = nil }
	lastRingMs = -math.huge
	silenced = nil
	withdrawn = nil
	mutedEvents = {}
	holoOpen = false
	roster = { rows = {}, recent = {}, onCall = false }
	jobs = {}

	local settings = M.Settings
	sounds = type(settings.SOUND) == 'table' and settings.SOUND or {}
	ringEveryMs = math.floor(OPX.Math.Clamp(
		OPX.Math.Finite(settings.RING_EVERY_MS) or 3500, 1000, 60000))
end

--- Wires the state push, the rows and the ring.
-- @author dop42
function M.Start()
	-- The seam, FIRST: `client/view.lua` registers the handler for the local
	-- view event, and the very first payload this module publishes is the one
	-- `FromView('ready')` draws straight back at the end of this function.
	if type(M.View) == 'table' and type(M.View.Start) == 'function' then M.View.Start() end

	RegisterNetEvent(M.Event.STATE, onState)
	RegisterNetEvent(M.Event.ROSTER, function(payload)
		if type(payload) ~= 'table' then return end
		onRoster(payload)
	end)

	-- The ring is a scheduler job rather than a thread of its own: it has one
	-- comparison to make and a module that wants a tick has to justify it.
	jobs[#jobs + 1] = OPX.Scheduler.Every('calls:ring', 500, rearm)
	-- ── THE KEYS ─────────────────────────────────────────────────────────────
	-- One opens the projection; two answer a call without opening anything. All
	-- three are declared the same way and refused the same way, so the shape is
	-- written once.
	--
	-- `DEFAULT = false` switches one off for a server that binds it elsewhere,
	-- and there is then no way in by that route -- a configuration rather than a
	-- fault, so it is said once and not warned about.
	local function bind(block, fallbackId, fallbackName, press, wants)
		local declared = type(block) == 'table' and block or {}
		local key = declared.DEFAULT
		if type(key) ~= 'string' or key == '' then
			Open77.log.info(('[calls] no key is configured for %s'):format(fallbackId))
			return
		end
		if type(RegisterKeyMapping) ~= 'function' then
			OPX.Note('calls', 'this host has no RegisterKeyMapping: the calls have no keys')
			return
		end
		-- TWO ANSWER SHAPES ARE DOCUMENTED for this host call -- the effective
		-- key, or `true` and the key -- and reading only one of them logged a
		-- working mapping as a failure everywhere else in this resource before
		-- it was written down. Both are accepted; anything else is reported.
		-- A key typed into another surface is not a key pressed in the world --
		-- every other mapping in this resource already said so and these three
		-- did not -- and a press another feature on the same key owns is not
		-- this one's (see `OPX.Spots.Key.Owns`).
		local id = tostring(declared.ID or fallbackId)
		local called, ok, answer = pcall(RegisterKeyMapping, id,
			locale(declared.NAME or fallbackName), key, function()
				if OPX.Spots.Captured() or not OPX.Spots.Key.Owns(id) then return end
				press()
			end)
		if not called then
			OPX.Note('calls', ('%s was not mapped: %s'):format(fallbackId, tostring(ok)))
		elseif ok == false or (ok == nil and answer == nil) then
			OPX.Note('calls', ('%s could not take %q: %s')
				:format(fallbackId, key, tostring(answer)))
		elseif wants ~= nil then
			OPX.Spots.Key.Contend({ tag = 'calls', id = id, default = key, wants = wants })
		end
	end

	bind(M.Settings.KEY, 'opx.calls.holo', 'calls.key.holo',
		function() M.ToggleHolo() end)

	-- ANSWERING AND REFUSING DO NOTHING WHEN THERE IS NOTHING TO ANSWER, and
	-- that is what makes sharing a key with the hotbar peek and the emote stop
	-- survivable: outside a ringing call these handlers return immediately and
	-- the other feature is the only one that acted. `M.Accept` and `M.Decline`
	-- already answer false with no invite, so the guard is theirs and not a
	-- second copy of the same question.
	bind(M.Settings.ANSWER_KEY, 'opx.calls.answer', 'calls.key.answer',
		function() M.Accept() end,
		-- Y is also the hotbar peek, which stays silent while a call rings.
		function()
			if state.invite ~= nil then return OPX.Spots.Key.Rank('RINGING') end
			return nil
		end)
	-- THE SAME KEY HANGS UP. Refusing wins while something rings at you, then
	-- withdrawing what you are ringing out, then leaving the call -- see
	-- `M.DeclineOrHangUp` for why the middle one comes before the last.
	--
	-- AND THE KEY IS CONTESTED. X is also the progress cancel, the crate drop
	-- and the emote stop. Something ringing at the player outranks a crate and
	-- an emote -- the projection is up saying "X to refuse" -- and hanging up a
	-- call that is merely going on ranks below all of them: putting a crate down
	-- or ending a dance in the middle of a call used to end the call too.
	bind(M.Settings.DECLINE_KEY, 'opx.calls.decline', 'calls.key.decline',
		function() M.OnDeclineKey() end,
		function()
			if state.invite ~= nil then return OPX.Spots.Key.Rank('RINGING') end
			if state.outgoing ~= nil then return OPX.Spots.Key.Rank('OUTGOING') end
			if state.call ~= nil then return OPX.Spots.Key.Rank('CALL') end
			return nil
		end)

	-- ESCAPE CLOSES IT, and it is not a key this module may bind. The pause
	-- plugin swallows Escape before any surface sees it and re-raises it under
	-- its own name --  answers the same broadcast the same way --
	-- so binding  here would be asking for a key the platform has already
	-- taken. Closing only when the projection is OPEN matters: the sphere pops
	-- unbidden while a call rings, and Escape must not answer a call.
	-- And only when it is the TOP layer: a menu opened over it takes Escape.
	local layer = OPX.Spots.Key.Layer('calls', function() return holoOpen and holoOpenedAtMs or nil end)
	AddEventHandler(PAUSE_KEY, function()
		if not OPX.Spots.Key.TopLayer(layer) then return end
		if holoOpen then M.CloseHolo() end
	end)

	-- GOING DOWN CLOSES THE PANEL, as it closes the chat box. The down screen
	-- takes the keyboard, so none of the panel's own ways out could reach it,
	-- and after the revive it was still open and still holding the cursor. A
	-- call itself is not touched: the server decides who stays on one.
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed'), function(payload)
		if type(payload) == 'table' and payload.down == true and holoOpen then M.CloseHolo() end
	end)

	-- THE ONE ROW ON THE EYE. `target` is optional to this module, so its absence
	-- is a runtime with no way to hand somebody a contact face to face rather
	-- than a fault: the calls themselves are all behind the key above.
	local eye = OPX.Api.Get('target')
	if eye == nil or type(eye.RegisterPlayers) ~= 'function' then
		Open77.log.info('[calls] this client has no target eye: contacts cannot be handed over')
	else
		CreateThread(function()
			local ok, failure = pcall(registerRows, eye)
			if not ok then OPX.Note('calls', 'the contact row: ' .. tostring(failure)) end
		end)
	end

	-- Ask for the state once we are up. A player who reloads into a live call
	-- has to get their sphere back, and the server has no way of knowing this VM
	-- restarted.
	TriggerServerEvent(M.Event.READY)
end

--- Stops the ring and takes the rows back down.
-- @author dop42
function M.Stop()
	for index = 1, #jobs do
		if type(OPX.Scheduler.Cancel) == 'function' then OPX.Scheduler.Cancel(jobs[index]) end
	end
	jobs = {}
	-- THE HOLOGRAM GOES WITH THE MODULE. A screen left standing over a stopped
	-- owner is a set of buttons whose handler belongs to a VM that is no longer
	-- answering -- and this one holds focus, so it would also be a screen the
	-- player cannot close.
	--
	-- THE SPHERE GOES TOO. It pops for a live or ringing call with the panel
	-- closed, so closing the panel alone would leave a projection of a call this
	-- VM no longer answers for. Emptied here; the server's next push after a
	-- restart draws it back.
	holoOpen = false
	-- A call live when the module stops leaves the route where `onState` would
	-- have put it back on the hang-up.
	if state.call ~= nil then routeVoice('proximity') end
	state = { call = nil, invite = nil, outgoing = nil }
	drawHolo()
end
