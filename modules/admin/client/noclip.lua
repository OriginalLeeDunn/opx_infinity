--- The pop when noclip goes on and off, and the body it leaves behind.
-- @author dop42
--
-- WHAT THIS IS, IN FIVEM TERMS. `txadmin`'s noclip plays a "wizard" particle on
-- the ped both ways -- once on the way up and again on the way down -- and that
-- is the behaviour kept here: one effect per transition, in either direction,
-- and the body gone for as long as the operator is flying. What is NOT kept is
-- the asset: a FiveM resource is not something this build can load, so the pop is
-- a name out of the engine's own effect catalogue (`Open77.vfx.catalog()`) and
-- `config/admin.lua` moves it in one line.
--
-- WHY IT IS PLAYED IN THE WORLD AND NOT ON THE BODY. The obvious parallel to
-- `StartNetworkedParticleFxNonLoopedOnEntity` is `Open77.vfx.playEntity`, and it
-- is the wrong call here: `playEntity` resolves its name as a CName against the
-- RECEIVING ENTITY'S TEMPLATE, while `vfx.play` resolves a depot path at a
-- transform. Handing a curated alias such as `fire.large` to `playEntity`
-- therefore draws nothing at all -- the same conflation, already paid for once,
-- recorded in `docs/research/props-and-object-spawning.md` §6.
--
-- AND WHY IT IS THEN MOVED EVERY FRAME. A world effect is placed once and stays:
-- an instance spawned where the operator stood is behind a noclip flying at
-- 40 m/s inside a single frame, so the pop was drawn correctly and visible to
-- nobody -- which reads in game as "the pop does not show". `txadmin`'s particle
-- RIDES the ped, so this does the same by hand: the handle is re-placed at the
-- operator's feet until it expires. `vfx.update` takes the same position shape
-- as `play` and is refused for a handle this resource does not own, so the loop
-- stops on the first refusal instead of spinning at a dead handle.
--
-- ONE TRANSITION, ONE OWNER. `Controls` owns the noclip state on this client and
-- calls `Noclip.Changed` on both edges -- the server command that arms it, and
-- the native being switched off underneath us. Nothing else calls this file, so
-- the pop cannot play twice for one toggle.
--
-- EVERY OUTCOME IS ONE LOG LINE. A pop that drew, a pop the engine refused with
-- its reason, a client with no effect layer, an empty `EFFECT` and an operator
-- with no position YET are five different things, and a reader must not have to
-- guess which they have from an empty log.
--
-- THE BODY IS THE SERVER'S. Hiding a body is `Open77.players.setVisible`, on the
-- server only, so this half reports the one edge the server cannot see and the
-- server decides what the body of a flying operator looks like. That also keeps
-- the Invisible switch and this pop from fighting: both end in the same
-- server-side veil, and noclip only asks for its own reason on top of it.

local M = OPX.Modules.Get('admin')

-- The module's own clock, like every other client half here reads it. The follow
-- loop below is bounded in time, so it needs the same clock the rest of the
-- module times its sends against.
local Client = M.Client

M.Noclip = {}
local Noclip = M.Noclip

-- The configured pop, read once at start.
local effect, seconds, sound = '', 0.0, ''

-- Whether the body is hidden while flying. Read once, like the rest.
local hideBody = true

-- The live effect handle, so Stop can take it down with the module.
local handle

-- How often the live handle is re-placed, and how long it is followed when the
-- config asks for the effect's own lifetime (`EFFECT_SECONDS = 0`).
local FOLLOW_MS = 33
local DEFAULT_LIFE = 3.0

-- Whether each problem was already reported: a client with no effect layer, a
-- pop the engine turned down, a config with no effect in it and an operator with
-- no position are four different things, and a reader wants to know which they
-- have -- once, not once per toggle.
local reportedMissing, reportedRefused, reportedOff, reportedNowhere =
	false, false, false, false

-- Where the local operator is standing, or nil before there is a world.
local function playerPosition()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local ok, x, y, z = pcall(character.position)
	if not ok or type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
	return { x = x, y = y, z = z }
end

--- Keeps one drawn pop on the operator until it expires.
-- The loop is bounded by the handle: a newer pop, a `Stop` or a transition that
-- cleared it ends this one at its next tick, so nothing has to remember to.
-- @author dop42
-- @param id number the handle `play` returned
-- @param life number seconds to follow it for
local function follow(id, life)
	local api = Open77.vfx
	local untilMs = Client.NowMs() + math.floor(math.max(life, 0.2) * 1000)
	CreateThread(function()
		while handle == id and Client.NowMs() < untilMs do
			local at = playerPosition()
			if at == nil then break end
			local ok, moved = pcall(api.update, id, { position = at })
			if not ok or moved ~= true then break end
			Wait(FOLLOW_MS)
		end
	end)
end

--- Plays one instance of the pop where the operator is standing.
-- The engine answers `handle, reason` and does not raise: a missing alias, an
-- out-of-range duration and a full effect pool all arrive as a nil handle with a
-- reason, so both are read rather than assumed.
-- @author dop42
-- @return boolean whether the pop was drawn
function Noclip.Pop()
	if effect == '' then
		-- AN EMPTY EFFECT IS A CHOICE, NOT AN OMISSION, and this said it in a
		-- warning -- which is what an operator reads when something is wrong.
		-- The shipped config is empty now, deliberately, so warning about it
		-- would put a line in every session's log for a setting working exactly
		-- as written. Still said once, at debug, because "no pop at all" is
		-- worth being able to confirm when somebody expects one.
		if not reportedOff then
			reportedOff = true
			Open77.log.debug('[admin] noclip draws no pop: MODULES.admin.NOCLIP.EFFECT is empty')
		end
		return false
	end

	local api = Open77.vfx
	if type(api) ~= 'table' or type(api.play) ~= 'function' then
		if not reportedMissing then
			reportedMissing = true
			Open77.log.info('[admin] this client has no Open77.vfx: the noclip pop is off')
		end
		return false
	end

	local at = playerPosition()
	if at == nil then
		if not reportedNowhere then
			reportedNowhere = true
			Open77.log.info('[admin] the noclip pop waits for a world: no character position yet')
		end
		return false
	end

	local ok, id, reason = pcall(api.play, effect, { position = at, duration = seconds })
	if not ok then
		-- A raise is not the documented contract, but a native missing behind a
		-- present table is; its message becomes the reason and it is reported the
		-- same way a refusal is.
		reason, id = id, nil
	end
	if id == nil then
		if not reportedRefused then
			reportedRefused = true
			Open77.log.warn(('[admin] the noclip pop %s was refused: %s')
				:format(effect, tostring(reason)))
		end
		return false
	end
	handle = id
	Open77.log.info(('[admin] the noclip pop %s drawn at (%.2f, %.2f, %.2f) handle=%s')
		:format(effect, at.x, at.y, at.z, tostring(id)))

	-- Followed for its own configured life; a duration of 0 hands the lifetime to
	-- the effect, so a bounded default is used rather than following for ever.
	follow(id, seconds > 0 and seconds or DEFAULT_LIFE)

	local sfx = Open77.sfx
	if sound ~= '' and type(sfx) == 'table' and type(sfx.play) == 'function' then
		pcall(sfx.play, sound, { position = at })
	end
	return true
end

--- Reacts to one noclip transition, in either direction.
-- @author dop42
-- @param on boolean whether noclip is now on
function Noclip.Changed(on)
	Noclip.Pop()
	-- The body travels on the way DOWN only, and that direction is the whole
	-- reason this message exists: an ON edge was a server command, so the server
	-- has already hidden the body it is about to give back. The opposite edge is
	-- the one it cannot know about -- the native switched off underneath us --
	-- and without it the server's idea of who is flying stays on for the rest of
	-- the session, with their body hidden for it.
	--
	-- SENT WHETHER OR NOT THE BODY IS HIDDEN. It used to be skipped with
	-- `HIDE_BODY` off, which left the server believing the operator still flew --
	-- and the flight is also what the Observe screen and the roster read.
	if on == true then return end
	local sent, reason = TriggerServerEvent(M.Event.NOCLIP_BODY, false)
	if not sent then
		Open77.log.warn('[admin] the noclip body state was not sent: ' .. tostring(reason))
	end
end

--- Reads the pop's settings and starts with no handle.
-- @author dop42
function Noclip.Start()
	local section = M.Section('NOCLIP')
	effect = type(section.EFFECT) == 'string' and section.EFFECT or ''
	seconds = M.Bounded('NOCLIP.EFFECT_SECONDS', section.EFFECT_SECONDS, 0.0, 600.0, 1.5)
	sound = type(section.SOUND) == 'string' and section.SOUND or ''
	hideBody = section.HIDE_BODY ~= false
	handle = nil
	reportedMissing, reportedRefused, reportedOff, reportedNowhere = false, false, false, false
end

--- Stops the effect this module still owns, if the engine gave it a handle.
-- @author dop42
function Noclip.Stop()
	if handle == nil then return end
	local api = Open77.vfx
	if type(api) == 'table' and type(api.stop) == 'function' then pcall(api.stop, handle) end
	handle = nil
end

--- What this half knows, for a diagnostic or a test.
-- @author dop42
-- @return table
function Noclip.Report()
	return { effect = effect, seconds = seconds, sound = sound,
		hideBody = hideBody, handle = handle }
end
