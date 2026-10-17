--- Walking while an emote plays, and giving the ability back.
-- @author dop42
--
-- WHAT THE PLATFORM ACTUALLY OFFERS, because the obvious name for this does not
-- exist. There is no `canWalk` flag on an animation anywhere in the catalogue.
-- What arrived in client 2.31.13+op77.75 is `Open77.movement.setWalkMode`, and
-- it is not a switch on the emote -- it is a LEASE ON THE LOCAL PLAYER, held by
-- a resource, asking their body to move at a bounded speed:
--
--   Open77.movement.setWalkMode(enabled, speed?)   -- players.controls
--
-- The platform's own words: "Every resource holds its own request and the
-- slowest live request wins; `false` releases only this resource's request and
-- never touches another's." Speed is 0.5 to 2.5 m/s.
--
-- THAT SHAPE IS WHY THIS IS SAFE TO USE AND DANGEROUS TO FORGET. Safe, because
-- another resource carrying a body at 1.0 m/s cannot be overridden by us asking
-- for 2.0, and we cannot be overridden either -- the slowest wins and every
-- release is private. Dangerous, because a lease is not tied to the animation
-- that justified it: if the emote ends and nothing releases, the player walks
-- for the rest of the session and has no idea why.
--
-- So there are two mechanisms here and not one. The lease is taken and released
-- on the state change, AND a watchdog re-checks every sweep that a held lease
-- still has an emote under it. The second exists because the first is a
-- promise about every exit path -- stop, expiry, death, a character change, the
-- resource stopping -- and a promise about every path is the kind that is kept
-- until somebody adds a path.

local M = OPX.Modules.Get('animations')

local Catalogue = M.Catalogue

M.Walk = {}
local Walk = M.Walk

-- The speed the lease is currently held at, or nil when it is not held. The
-- speed is kept rather than a boolean because re-asking at a different speed is
-- how one is changed, and asking again at the SAME speed every sweep would be a
-- native call a second for no reason.
local heldAt = nil

-- Named reasons this runtime wants a bounded walk, to the speed each asks for.
--
-- THE LEASE IS PER RESOURCE, NOT PER CALLER. The platform's rule -- "every
-- resource holds its own request and the slowest live request wins" -- arbitrates
-- BETWEEN resources. Inside one resource there is a single request, so two
-- reasons here would simply overwrite each other: an emote asking for 1.3 would
-- wipe out a player who chose to stroll, and releasing either would release
-- both. The same rule is therefore applied locally, over these names, and the
-- one number that comes out of it is the only thing `setWalkMode` ever sees.
local requests = {}

--- Applies the slowest live request, or releases when there is none.
local function settle()
	local slowest
	for _, speed in pairs(requests) do
		if slowest == nil or speed < slowest then slowest = speed end
	end
	if slowest == nil then return Walk.Release() end
	Walk.Hold(slowest)
end

--- Whether this build has the walk lease at all.
--
-- op77.75 is recent, and a client older than that is not broken -- it simply
-- cannot walk through an emote. Asked by name at call time rather than captured,
-- like every other native this runtime reaches for.
-- @author dop42
-- @return boolean
function Walk.Available()
	local movement = Open77.movement
	return type(movement) == 'table' and type(movement.setWalkMode) == 'function'
end

--- Asks for the lease at one speed, or moves it to another.
-- @author dop42
-- @param speed number metres per second
-- @return boolean
function Walk.Hold(speed)
	if not Walk.Available() then return false end
	local wanted = tonumber(speed)
	-- Bounded here as well as by the platform: a config that wandered outside
	-- the range would otherwise refuse once a second and log nothing anybody
	-- reads, which is the shape of a fault that lasts for months.
	if wanted == nil or wanted ~= wanted or wanted < 0.5 or wanted > 2.5 then return false end
	if heldAt == wanted then return true end

	local called, ok, reason = pcall(Open77.movement.setWalkMode, true, wanted)
	if not called or ok ~= true then
		Open77.log.warn('[animations] the walk lease refused: ' .. tostring(called and reason or ok))
		return false
	end
	heldAt = wanted
	return true
end

--- Gives the lease back. Safe to call when it is not held.
--
-- CALLED FROM EVERY EXIT, and deliberately cheap enough that a caller never has
-- to ask itself whether it is holding one. `false` releases only our own
-- request, so this can never take the ground out from under another resource.
-- @author dop42
function Walk.Release()
	if heldAt == nil then return end
	if not Walk.Available() then return end
	local called, ok, reason = pcall(Open77.movement.setWalkMode, false)
	if not called or ok ~= true then
		Open77.log.warn('[animations] the walk lease would not release: ' .. tostring(called and reason or ok))
		return
	end
	heldAt = nil
end

--- Whether the lease is held, and at what speed. Nil when it is not.
-- @author dop42
-- @return number|nil
function Walk.Held()
	return heldAt
end

--- Takes or releases the lease for one state of the local player.
--
-- THE ONE PLACE THE DECISION IS MADE, fed by `onOwnChanged`, which is the single
-- funnel for "what my own body is doing now". An emote that does not walk, an
-- emote this client does not know, and no emote at all are the same answer:
-- release.
-- @author dop42
-- @param active boolean whether an emote is playing
-- @param profile string|nil the profile it is playing
function Walk.Follow(active, profile)
	if active ~= true then return Walk.Request('emote', nil) end

	local entry = Catalogue.Entry(profile)
	local speed = entry ~= nil and entry.walk or nil
	Walk.Request('emote', speed)
end

--- Sets or clears one named reason to walk, and settles the lease.
--- A nil speed clears that reason and never touches another's.
-- @author dop42
-- @param name string
-- @param speed number|nil metres per second
function Walk.Request(name, speed)
	if type(name) ~= 'string' or name == '' then return end
	local wanted = tonumber(speed)
	if wanted ~= nil and (wanted ~= wanted or wanted < 0.5 or wanted > 2.5) then wanted = nil end
	requests[name] = wanted
	settle()
end

--- The speed one named reason is asking for, or nil.
-- @author dop42
-- @param name string
-- @return number|nil
function Walk.Asked(name)
	return requests[name]
end

-- ── the player's own pace ────────────────────────────────────────────────────
--
-- A SECOND REASON TO WALK, AND THE FIRST THAT OUTLIVES ITS TRIGGER. Every other
-- caller of the lease holds it for as long as something is visibly happening --
-- an emote, a carry -- and lets go when it ends. This one is a preference: the
-- player presses a key and their body keeps that pace until they press it
-- again. That is exactly the shape the watchdog above was written to destroy,
-- which is why the watchdog now answers only for `emote`.
--
-- Client-local and not persisted. A pace is a posture for the moment, not a
-- fact about the character, and it costs one keypress to set again.

-- Which entry of `WALK_PACES` is live, or 0 for the ordinary body.
local paceIndex = 0

--- The configured paces, as a list, refusing anything the platform would.
local function paces()
	local list = type(M.Settings.WALK_PACES) == 'table' and M.Settings.WALK_PACES or {}
	local out = {}
	for index = 1, #list do
		local row = list[index]
		local speed = type(row) == 'table' and tonumber(row.SPEED) or nil
		local id = type(row) == 'table' and row.ID or nil
		-- Bounded HERE, so a config that wandered out of range is one log line at
		-- start rather than a key that silently does nothing forever.
		if type(id) == 'string' and id ~= '' and speed ~= nil
			and speed >= 0.5 and speed <= 2.5 then
			out[#out + 1] = { id = id, speed = speed }
		end
	end
	return out
end

--- The pace the player is on, or nil for the ordinary body.
-- @author dop42
-- @return table|nil { id, speed }
function Walk.Pace()
	local list = paces()
	return paceIndex >= 1 and list[paceIndex] or nil
end

--- Takes one pace by its id, or the ordinary body when the id is nil.
-- @author dop42
-- @param id string|nil
-- @return table|nil the pace now held
function Walk.Choose(id)
	local list = paces()
	paceIndex = 0
	for index = 1, #list do
		if list[index].id == id then paceIndex = index break end
	end

	local pace = paceIndex >= 1 and list[paceIndex] or nil
	Walk.Request('pace', pace and pace.speed or nil)
	return pace
end

--- The rows the eye shows on the player's own body.
---
--- ON THE EYE AND NOT ON A KEY. A key would have to cycle -- there is no room
--- on one binding for four choices -- so a player wanting to stroll would press
--- it three times and read three toasts to find out where they landed. `ALT` on
--- your own body already lists what you can do to yourself, it draws the
--- current state beside each row, and it costs no binding at all.
---
--- One row per pace plus the ordinary body, all under one folder so they do not
--- crowd the other self rows. `state` is what makes the list readable: the eye
--- marks the live one, so the answer to "which pace am I on" is the same click
--- as changing it.
-- @author dop42
-- @return table[]
function Walk.Rows()
	-- THE REGISTRY'S VOCABULARY, AND THE FIRST VERSION SPOKE ADMIN'S.
	--
	-- `modules/admin/client/target.lua` builds rows with `kind`, `folder`,
	-- `select`, `check` and `state`, then translates them at the door: `kind`
	-- picks which `Register*` to call, and the rest is its own shape. Copying
	-- that shape straight into `RegisterSelf` looked right and was not.
	--
	-- `modules/target/shared/model.lua` wants `onSelect`, `canInteract` and
	-- `checked`, and `Register` refuses a definition whose `onSelect` is not a
	-- callback -- `invalid_option`. `RegisterMany` is all-or-nothing, so all
	-- four rows were refused together and NO pace row ever existed. The refusal
	-- was logged with `Open77.log.warn`, which writes on the player's own
	-- machine, so the line existed and was nowhere anybody was looking.
	-- `modules/hauling/client/main.lua` is the caller that gets this right.
	--
	-- The label is RESOLVED here. The registry takes display text, not a
	-- catalogue key, so the raw key would have been drawn as itself.
	local function row(id, label, pace)
		return {
			id = id,
			label = locale(label),
			icon = 'person',
			group = locale('animations.walk.group'),
			-- Above the staff band, which starts at 100: a pace is something
			-- everybody has and a player should not scroll past noclip to reach.
			order = 10,
			canInteract = function() return Walk.Available() end,
			checked = function()
				local live = Walk.Pace()
				if pace == nil then return live == nil end
				return live ~= nil and live.id == pace.id
			end,
			onSelect = function()
				Walk.Choose(pace and pace.id or nil)
				return true
			end,
		}
	end

	-- No `kind` field: `RegisterSelf` is what makes these self rows, and it sets
	-- `types`, `allowSelf` and `selfOnly` itself.
	local rows = { row('walkOff', 'animations.walk.off', nil) }
	local list = paces()
	for index = 1, #list do
		local pace = list[index]
		rows[#rows + 1] = row('walk_' .. pace.id, 'animations.walk.' .. pace.id, pace)
	end
	return rows
end

--- Publishes the pace rows on the eye, when there is an eye to publish them on.
-- @author dop42
function Walk.Start()
	paceIndex = 0
	requests.pace = nil

	-- `target` is optional to this module, so its absence is a runtime without
	-- an eye rather than a fault: the paces are simply unreachable, and nothing
	-- else about animations changes.
	local contract = OPX.Api.Get('target')
	if contract == nil or type(contract.RegisterSelf) ~= 'function' then return end

	if not Walk.Available() then
		Open77.log.info('[animations] this client has no walk lease: no pace rows are offered')
		return
	end

	local answer = contract.RegisterSelf('animations', Walk.Rows())
	if answer == nil or answer.ok ~= true then
		--  AND NOT . A client log line is written on
		-- the PLAYER'S machine, so the first version of this refusal existed and
		-- was nowhere the operator could ever read it -- which is how four rows
		-- refused in a batch went unnoticed until somebody reported the feature
		-- missing in game. This is exactly what the bounded relay is for.
		OPX.Note('animations', ('the walking pace rows were refused: %s')
			:format(tostring(answer and answer.error)))
	end
end

--- Releases a lease that has outlived whatever justified it.
--
-- THE WATCHDOG, and the reason it exists is written in the header: the release
-- above is a promise about every exit path, and this is what makes the promise
-- survive somebody adding a path. Asked from the module's own sweep, which
-- already runs.
--
-- It reads the presenter rather than a flag of its own: a flag would answer the
-- question "did we think we should be walking", and the question worth asking
-- is "is there an emote on this body right now".
-- @author dop42
function Walk.Check()
	-- IT SWEEPS THE EMOTE'S REASON, NOT THE LEASE. This used to release
	-- outright, which was right while an emote was the only thing that could
	-- ask -- and would now take away a pace the player chose on purpose, every
	-- sweep, with a warning line each time saying somebody had forgotten a path.
	-- Nobody had. The watchdog's question is "is there still an emote under the
	-- emote's request", and that is the only request it may answer for.
	if requests.emote == nil then
		settle()
		return
	end

	local state = M.Presenter.State()
	if type(state) == 'table' and state.active == true then
		local entry = Catalogue.Entry(state.animation)
		if entry ~= nil and entry.walk ~= nil then return end
	end

	-- Said out loud, once per occurrence: a lease that had to be swept is a path
	-- somebody forgot, and the whole point of the watchdog is to name it rather
	-- than to quietly paper over it.
	Open77.log.warn('[animations] a walk lease outlived its emote and was swept')
	Walk.Request('emote', nil)
end
