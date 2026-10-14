--- One outstanding spawn choice per player, and the deadline that ends it.
-- @author dop42
--
-- The whole of this half is a handshake with `character`, which owns placement:
--
--   1. `character.PlacePending` asks `M.Offer` on every join. Answering true means
--      this module has taken the placement over and `character` must NOT place.
--   2. `M.Offer` records the choice, puts `spawn:offer` on the wire and starts the
--      one watcher that ends a choice nobody makes.
--   3. The player's click arrives as `spawn:choose` carrying an ID and nothing
--      else. The ID is looked up in this VM's own catalogue -- see `M.Point` --
--      so the coordinates are never the client's to choose.
--   4. Either way the choice ends, `M.Settle` places the body through
--      `character.PlaceCharacter` and puts `spawn:close` on the wire.
--
-- WHY THE DEADLINE MATTERS MORE THAN IT LOOKS. Nobody places the body until step
-- 4 runs, so a menu that never closes leaves the character standing wherever the
-- join put them -- and on a first join, with no name either, because the entry
-- module's form and this module's menu are answers to the same moment. That is a
-- player stuck for the session, so the deadline is not a nicety: it is the only
-- exit a choice nobody makes ever gets.
--
-- There is no `OPX.Scheduler` here and there must not be: that is the client's
-- loop. On the server a loop is a `CreateThread` that yields.

local M = OPX.Modules.Get('spawn')

-- How often the watcher looks at its own deadline. A pick that lands inside this
-- window is answered by the handler itself, so the watcher only ever has to be
-- accurate to within one tick.
local WATCH_MS = 500

-- A floor on the configured timeout, in seconds, and also the answer for a setting
-- that is missing or unreadable. A zero from a typo would expire the offer in the same
-- tick it was made, which is not a short choice but no choice at all -- so this is the
-- one module where the floor and the fallback are deliberately LOWER than the number
-- the configuration ships with: an operator may shorten the choice, not remove it.
local TIMEOUT_FLOOR_SECONDS = 5

--- The character contract, resolved once the Api phase has ended.
local Character

--- The outstanding choice, by player id.
--  source -> { token, citizenId, expiresAtMs }
-- The token is what makes a late settle harmless: a watcher holding an old token
-- cannot clear a choice that replaced it.
local pending

local tokenSeq

--- How long a player has to choose, in milliseconds.
local function timeoutMs()
	return math.floor(M.Number(M.Settings.TIMEOUT_SECONDS, TIMEOUT_FLOOR_SECONDS) * 1000)
end

-- A bound on how long an offer nobody opens may hold a character unplaced, in
-- seconds, and also the answer for a setting that is missing or unreadable.
-- Generous, because waiting on a player is the normal case: it exists only so a
-- client that never draws the menu cannot strand a body for the session.
local HOLD_MAX_FLOOR_SECONDS = 60

-- The most a hold can be stretched by a join that keeps reporting itself busy
-- (`M.Waiting`), counted from the offer: half an hour in the fitting room and
-- on the name form together is a player who is not coming back to choose.
local HOLD_CAP_MS = 30 * 60 * 1000

local function holdMs()
	return math.floor(M.Number(M.Settings.HOLD_MAX_SECONDS, HOLD_MAX_FLOOR_SECONDS) * 1000)
end

--- Whether this module is switched on at all.
local function enabled()
	return M.Settings.enabled ~= false
end

--- Whether this character has ever stood anywhere.
-- THE WHOLE OF WHAT `first` MEANS, and the row's own position is what says so:
-- `PlayerData.position` is nil on a character created and never placed, and a
-- table from the moment the first save writes one back. There is no "has spawned
-- before" flag and there must not be -- a second column saying the same thing as
-- the first is a second thing to keep in step, and the one that drifted would be
-- the one deciding whether a player is interrupted on every join for the rest of
-- the character's life.
--
-- A CHARACTER THIS CANNOT READ COUNTS AS HAVING STOOD. The caller's next move on
-- a false is to hold the player for a menu, and holding somebody on the strength
-- of a row nobody could read is the one outcome worse than not asking them: the
-- row still places them, which is where they were.
-- @param source Source
-- @param citizenId CitizenId
-- @return boolean
local function hasStood(source, citizenId)
	if Character == nil then return true end
	local player = Character.GetPlayer(source)
	if not player then return true end
	local data = player.PlayerData
	if type(data) ~= 'table' or data.citizenId ~= citizenId then return true end
	return type(data.position) == 'table'
end

--- Puts a payload on the wire to one player.
local function send(event, source, payload)
	if source == nil then return end
	TriggerClientEvent(event, source, payload)
end

--- Moves the body the choice selected, or leaves the target to the row when none
-- was made -- so a player who picks nothing resumes where they were, and only a
-- character whose row holds no position falls to the default spawn.
-- The player is re-resolved from the citizen id rather than held across the
-- wait: a slot is recycled, and a character that left during the choice must not
-- have its body moved -- nor somebody else's.
-- @return boolean whether a placement was attempted and took
local function place(source, held, point)
	local player = Character.GetPlayer(source)
	if not player then return false end
	if player.PlayerData == nil or player.PlayerData.citizenId ~= held.citizenId then
		return false
	end

	-- A nil point is not a fallback this module chooses: it means "no explicit
	-- target", which `character` resolves to the row's own position and then to
	-- the default spawn. Passing nothing is deliberate, so the resume and the
	-- default both stay owned by the module that owns the setting.
	local placed, reason = Character.PlaceCharacter(player, point)
	if not placed then
		Open77.log.warn(('[spawn] %s could not be placed at %s: %s')
			:format(held.citizenId, point ~= nil and point.id or 'where the row says',
				tostring(reason)))
	end
	return placed
end

--- Ends one choice: spends it, takes the menu down, and moves the body.
-- Idempotent against the token, so the deadline watcher and a click that arrive
-- together cannot both place.
-- @param source Source
-- @param token integer the choice this settles, as the caller saw it
-- @param point table|nil the spot chosen, or nil for the default
-- @param reason string what ended it: 'chosen', 'resumed' or 'timeout'
-- @return boolean whether it settled anything
local function settle(source, token, point, reason)
	local held = pending and pending[source]
	if held == nil or held.token ~= token then return false end
	-- SPENT HERE, SYNCHRONOUSLY, and this line is the whole of the rate limit: a
	-- second click arriving while the body is still moving finds no choice to take,
	-- and two settles can never both place.
	pending[source] = nil

	-- THE MENU COMES DOWN FIRST. Placement is a kill and a respawn -- about a
	-- second, with a fade -- and a menu held up over that is a player staring at a
	-- list while their body is moved underneath it. Sent whatever placement then
	-- does, because a choice that has been spent is spent: a menu left up because a
	-- kill was refused has nothing behind it, and the player has to be able to move.
	--
	-- AND IT CARRIES NO SENTENCE. "Spawned at X." went up here, before the body
	-- had moved, and stayed up when the placement was then refused (down, mid
	-- transition, a refused kill): told they were somewhere they were not. The
	-- sentence follows the placement, on the same name, as `result`.
	send(M.Event.CLOSE, source, { reason = reason })

	if reason == 'timeout' then
		-- Not 'the default spawn': a player who picked nothing is placed by the
		-- row, which for a returning character is exactly where they left off.
		-- Only a character whose row holds nowhere reaches the default.
		Open77.log.info(('[spawn] %s chose nothing in time; the row decides where they land')
			:format(held.citizenId))
	end

	-- ON ITS OWN THREAD, and it has to be: `PlaceCharacter` yields -- it polls the
	-- life state with `Wait` -- and the routeway this is reached from is a net
	-- handler, which is not a coroutine. Yielding from one is a raise, and a raise
	-- here would be a character left where the pristine save dropped them.
	CreateThread(function()
		local placed = place(source, held, point)
		send(M.Event.CLOSE, source, {
			reason = reason,
			result = true,
			placed = placed == true,
			-- The label only, for the sentence the client shows. The coordinates
			-- are not the client's business in either direction.
			place = point ~= nil and point.label or nil,
			-- And its id, which the client turns into the place's name in the
			-- player's language when the catalogue has one.
			placeId = point ~= nil and point.id or nil,
		})
	end)
	return true
end

--- Offers a spawn choice to the character a join has just loaded.
-- @author dop42
-- Called by `character.PlacePending` on EVERY world enter; which of those turn
-- into a menu is `OFFER_POLICY`'s decision and is made here. Answering true means
-- the body is placed from here instead, and a player who picks nothing is placed
-- by the row. Answers false -- "place them yourself" -- for every case this
-- module will not or cannot serve: switched off, the policy declining this join,
-- no usable location, no identity to place, or a choice already outstanding.
--
-- A FALSE IS NOT A FAILURE AND COSTS NOTHING. `character` answers it by calling
-- `PlaceCharacter` with no explicit target, which resolves to the row's own
-- position and then to `DEFAULT_SPAWN` -- so every path this function declines
-- lands the player exactly where the row says, in the same tick, with no clock
-- armed anywhere. That is what makes returning false the right way to express
-- 'never' rather than offering a menu and closing it immediately.
-- @param source Source
-- @param citizenId CitizenId
-- @return boolean whether this module has taken the placement over
function M.Offer(source, citizenId)
	source = tonumber(source)
	if not source or source <= 0 then return false end
	if type(citizenId) ~= 'string' or citizenId == '' then return false end
	if not enabled() then return false end

	-- BEFORE ANYTHING IS RECORDED, and that ordering is the requirement rather
	-- than a tidiness: every clock this module owns is armed by the block below,
	-- so declining here is the only way to leave a 'never' server with no hold,
	-- no deadline and no watcher thread for a menu that is never drawn.
	if M.OfferPolicy == M.Policy.NEVER then return false end

	local catalogue = M.Catalogue()
	if #catalogue == 0 then return false end
	-- One choice at a time. A second offer for the SAME character leaves the
	-- first one standing rather than replacing its deadline. One left over by a
	-- character that is no longer the one on this slot is nobody's, and is
	-- dropped -- see `Abandon` -- rather than standing in front of this one.
	local standing = pending[source]
	if standing ~= nil and standing.citizenId ~= citizenId then
		M.Abandon(source, standing.citizenId)
	end
	if pending[source] ~= nil then return false end

	-- 'first' ASKS A ROW, NOT A CLOCK. A character whose row already holds a
	-- position has stood somewhere, so it resumes in silence; only one that has
	-- never been placed is interrupted, which is once per character for its whole
	-- life. Read after the catalogue and the outstanding check because those two
	-- are free and this one resolves a player.
	if M.OfferPolicy == M.Policy.FIRST and hasStood(source, citizenId) then
		return false
	end

	local life = timeoutMs()
	tokenSeq = tokenSeq + 1
	local token = tokenSeq
	-- `expiresAtMs` is left NIL on purpose: the player's clock has not started,
	-- because the menu is not on screen yet. It starts when the client reports
	-- the menu up -- see `M.Opened` -- which is the whole reason the offer carries
	-- an event of its own. Until then `holdUntilMs` is the only bound, and it is
	-- a bound on the RUNTIME rather than on the player.
	-- WHETHER "WHERE I LEFT OFF" IS A CHOICE AT ALL. Picking nothing used to be
	-- the only way to keep the row's position -- an invisible forty-five second
	-- wait the page never mentioned. A character whose row holds a position is
	-- offered it as a card of its own; one that has never stood anywhere has no
	-- such place to go back to, and is not offered one.
	local resume = hasStood(source, citizenId)
	pending[source] = {
		token = token,
		citizenId = citizenId,
		resume = resume,
		expiresAtMs = nil,
		holdUntilMs = OPX.Now() + holdMs(),
		offeredAtMs = OPX.Now(),
	}

	-- A DURATION, not a deadline. The page counts down to its own clock plus this
	-- number, and that display is presentation of a server number -- the server
	-- counts this same `life` itself, and only its count ends the choice. The two
	-- now agree because both start from the same moment: the menu appearing.
	send(M.Event.OFFER, source, { timeoutMs = life, resume = resume })
	Open77.log.info(('[spawn] %s is choosing a spawn point (%d configured)')
		:format(citizenId, #catalogue))

	-- One thread per outstanding choice. It exits the moment the choice settles,
	-- because `settle` clears the slot -- so a server with nobody choosing holds
	-- no loop for anybody.
	CreateThread(function()
		while true do
			Wait(WATCH_MS)
			local held = pending[source]
			if held == nil or held.token ~= token then return end
			local now = OPX.Now()
			if held.expiresAtMs == nil then
				-- Nobody has the menu up yet. The player's window has not begun, so
				-- the only thing that can run out here is the hold.
				if now >= held.holdUntilMs then
					settle(source, token, nil, 'timeout')
					return
				end
			elseif now >= held.expiresAtMs then
				settle(source, token, nil, 'timeout')
				return
			end
		end
	end)

	return true
end

--- The menu is on screen: the player's window starts now.
-- @author dop42
-- Reported by the client, because only the client knows when the menu became
-- visible -- and it is deliberately not sent the moment the offer arrives, since
-- the menu stands aside while the entry module is asking the same player for a
-- name. See the payload's own comment in module.lua for the measurement that
-- made this necessary.
--
-- A malicious client can call this, and the worst it buys is its own window
-- starting now instead of earlier -- a bound on the INTERVAL, not on the
-- choice, whose coordinates and deadline are still the server's alone to
-- decide. A SECOND report is ignored, so nobody can extend their own window for
-- ever: the first one starts the clock and only the hold can be reached from
-- there.
-- @param source Source
function M.Opened(source)
	local held = pending and pending[source]
	if held == nil then return end
	if held.expiresAtMs ~= nil then return end

	local life = timeoutMs()
	held.expiresAtMs = OPX.Now() + life
	Open77.log.info(('[spawn] %s has the menu up: %d second(s) to choose')
		:format(held.citizenId, math.floor(life / 1000)))
end

--- The join is still busy ahead of the menu: the hold is stretched.
-- @author dop42
-- THE HOLD RAN OUT UNDER THE FITTING ROOM. It is five minutes from the offer,
-- and the offer comes at world entry, before the name form and the clothes: a
-- new player who took their time there was placed by the server ("No choice
-- was made") -- a kill and a respawn under an open modal -- for a menu they
-- had never seen. The client says, while the entry module reports itself
-- busy, that it still is; each report pushes the hold a full hold away, up to
-- `HOLD_CAP_MS` from the offer. A forged report buys its own player a later
-- placement and nothing else, which is the bound `M.Opened` already accepts.
-- @param source Source
function M.Waiting(source)
	local held = pending and pending[source]
	if held == nil or held.expiresAtMs ~= nil then return end
	local now = OPX.Now()
	local cap = (held.offeredAtMs or now) + HOLD_CAP_MS
	held.holdUntilMs = math.min(cap, math.max(held.holdUntilMs, now + holdMs()))
end

--- Handles the click. Every field on the payload is attacker-controlled.
-- @author dop42
-- @param source Source
-- @param payload table
function M.Choose(source, payload)
	if type(payload) ~= 'table' then return end

	local held = pending[source]
	-- The choice is over: placed already, or timed out, or this player was never
	-- offered one. Nothing to do but say so.
	if held == nil then
		OPX.Refuse(source, 'spawn.noChoice', M.Operation.CHOOSE)
		return
	end

	if OPX.Cooling(source, M.Operation.CHOOSE, M.Number(M.Settings.CHOOSE_COOLDOWN_MS, 1000)) then
		OPX.Refuse(source, 'error.tooFast', M.Operation.CHOOSE)
		return
	end

	-- WHERE I LEFT OFF: no point, so the row decides, which is the resume. Only
	-- for a choice that was offered it -- a character with nowhere to go back to
	-- asking for it is refused like any id this module does not carry.
	if payload.id == M.RESUME_ID then
		if held.resume ~= true then
			OPX.Refuse(source, 'spawn.noChoice', M.Operation.CHOOSE)
			return
		end
		settle(source, held.token, nil, 'resumed')
		return
	end

	-- THE LOOKUP. An id this module does not carry -- a typo, or a catalogue the
	-- client invented -- is refused rather than placed, and the menu stays up so
	-- the player can pick again.
	local point = M.Point(payload.id)
	if point == nil then
		OPX.Refuse(source, 'spawn.noChoice', M.Operation.CHOOSE)
		return
	end

	settle(source, held.token, point, 'chosen')
end

--- Drops a choice whose character has left the slot, and takes its menu down.
-- @author dop42
--
-- A CHOICE BELONGS TO A CHARACTER, AND THE TABLE IS KEYED BY A SLOT. A switch in
-- the world (`opx.select`) unloads one character and places the next on the
-- spot, without asking this module anything -- so a choice still open for the
-- first stayed open: its menu up on the player's screen holding the keyboard,
-- the HUD standing aside for it, until the hold or the window ran out. Anything
-- clicked on it placed nobody (`place` checks the citizen), which is the only
-- reason it never moved the wrong body. Nothing is placed here: the character it
-- was for has gone, and the one that replaced it is placed by its own path.
-- @param source Source
-- @param citizenId CitizenId|nil only a choice for this character is dropped
-- @return boolean whether one was
function M.Abandon(source, citizenId)
	source = tonumber(source)
	local held = source and pending and pending[source]
	if held == nil then return false end
	if citizenId ~= nil and held.citizenId ~= citizenId then return false end
	pending[source] = nil
	send(M.Event.CLOSE, source, { reason = 'abandoned' })
	Open77.log.info(('[spawn] the choice of %s was dropped: the character left the slot')
		:format(tostring(held.citizenId)))
	return true
end

--- Whether a choice is outstanding for a player.
-- Read by the diagnostics command and by the tests; nothing else consults it.
-- @author dop42
-- @param source Source
-- @return boolean
function M.IsPending(source)
	return pending ~= nil and pending[tonumber(source)] ~= nil
end

--- Builds the held state and settles the offer policy.
-- @author dop42
--
-- RESOLVED ONCE, HERE, for the same reason `character` resolves its paycheck type
-- in its own Init: a setting read at the point of use is a setting whose typo is
-- reported on every join, in the middle of a join's own log lines, where nobody
-- reads it. Resolved at boot it is said once, in the block an operator scans
-- after editing a config file, and every join afterwards reads a value that is
-- already known to be one of three.
function M.Init()
	pending = {}
	tokenSeq = 0

	local configured = M.Settings.OFFER_POLICY
	M.OfferPolicy = M.KnownPolicy(configured)
	if M.OfferPolicy == nil then
		-- NAMED, NOT SILENT. An unknown policy that quietly became 'always' would
		-- be indistinguishable from an operator who meant 'always', and one that
		-- quietly became 'never' would look exactly like the module being broken.
		-- Both values are on the line so the journal says what was refused and
		-- what is running instead.
		Open77.log.warn(('[spawn] OFFER_POLICY %s is not one of first/always/never; ' ..
			'offering on %s instead')
			:format(tostring(configured), M.POLICY_DEFAULT))
		M.OfferPolicy = M.POLICY_DEFAULT
	end
end

--- Publishes the decision `character` reaches for.
-- @author dop42
-- THE WHOLE SEAM. `character.PlacePending` asks this module, on every join,
-- whether it will take the placement over. It looks the contract up with
-- `OPX.Api.Get('spawn')`, because
-- declaring the dependency both ways is a cycle: `spawn` requires `character`,
-- so `character` cannot require `spawn`.
--
-- Without this phase the two halves are simply never connected: `Get` answers
-- nil, `character` places the body itself and the menu is never seen -- with NO
-- error anywhere, because an absent contract is a legitimate answer. That is
-- what happened the first time this shipped to a live server, and it is why the
-- suite now asserts the contract is published rather than only that `Offer`
-- works when called directly.
function M.Api()
	OPX.Api.Provide('spawn', 1, {
		-- Answers whether this module has taken the placement over. The only
		-- operation `character` needs, and the only one published.
		Offer = M.Offer,
	})
end

--- Resolves the character contract and registers the routeways.
-- @author dop42
function M.Start()
	Character = OPX.Api.Require('character')

	RegisterNetEvent(M.Event.CHOOSE, function(payload)
		local src = tonumber(source)
		if not src then return end
		M.Choose(src, payload)
	end)

	RegisterNetEvent(M.Event.OPENED, function(payload)
		local src = tonumber(source)
		if not src then return end
		M.Opened(src)
	end)

	RegisterNetEvent(M.Event.WAITING, function()
		local src = tonumber(source)
		if not src then return end
		if OPX.Cooling(src, 'spawn:waiting', 5000) then return end
		M.Waiting(src)
	end)

	-- A character put down on a slot that stays connected: its choice goes with it.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'unloaded'),
		function(rawPlayerId, playerData)
			local src = tonumber(rawPlayerId)
			if not src then return end
			M.Abandon(src, type(playerData) == 'table' and playerData.citizenId or nil)
		end)

	-- Forget the choice with the player. Nothing is placed: their slot is gone,
	-- and the watcher notices the same way -- by finding no slot to settle.
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(rawPlayerId)
		local src = tonumber(rawPlayerId)
		if src then pending[src] = nil end
	end)

	-- Said once, at start, because a spawn module that can never offer anything
	-- has no other symptom at all: every new character simply lands on the
	-- default spawn and nothing in a log says why.
	if not enabled() then
		Open77.log.info('[spawn] the module is switched off: new characters land on the ' ..
			'default spawn')
	else
		-- BUILT EVEN UNDER 'never', and the call is here for its side effect as
		-- much as its count: `Catalogue` is what validates the configured spots and
		-- names a broken one. A server that is not asking anybody this week may be
		-- next week, and a coordinate with a typo in it should be named the day it
		-- was written rather than the day the menu is switched back on.
		if #M.Catalogue() == 0 then
			Open77.log.warn('[spawn] no destination is configured: new characters land ' ..
				'on the default spawn')
		end

		-- WHICH WORLD ENTERS ARE ASKED, said on every start rather than only on the
		-- unusual values. It is the first thing anybody debugging "the menu did not
		-- appear" needs, and a policy visible only by its absence from the journal
		-- is a policy nobody can confirm is the one they configured.
		if M.OfferPolicy == M.Policy.NEVER then
			Open77.log.info(('[spawn] OFFER_POLICY is %s: nobody is asked, and every ' ..
				'character starts where its row says'):format(M.Policy.NEVER))
		else
			Open77.log.info(('[spawn] OFFER_POLICY is %s'):format(M.OfferPolicy))
		end
	end
end

--- Drops every outstanding choice.
-- The world is going away underneath them; nothing here is worth placing.
-- @author dop42
function M.Stop()
	pending = {}
end
