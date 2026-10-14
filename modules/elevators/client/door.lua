--- The way in: the key that opens the floor list, and the strip row naming it.
-- @author dop42
--
-- THE PANEL HAD NO DOOR. `Panel.Open` was published as `OpenPanel` on the
-- contract and nothing in this resource called it -- no key, no strip row, no
-- eye row -- while the server adopts every configured lift LOCKED, which is what
-- refuses the vanilla in-cabin button. So a configured shaft was a cabin no
-- player could ride at all: the game's own button was refused by design and the
-- replacement for it could not be reached. This file is that door, built the way
-- a garage, a dealer, a store and a teleport are built: a rebindable key
-- (`KEY` in `config/elevators.lua`, E out of the box) and a strip row while the
-- player stands within USE_RADIUS of a configured lift.
--
-- The row is a hint like everything else on this side: what the key opens is
-- the floor list, every row of it re-decided by the server before a cabin moves.
-- `prompts` is optional -- without it the key still opens the panel.

local M = OPX.Modules.Get('elevators')
local Runtime = M.Runtime
local Panel = M.Panel

M.Door = {}
local Door = M.Door

-- What the prompts contract records as this module's own.
local OWNER = 'elevators'
local GROUP = 'lift'

-- The elevator whose row is up, or nil, and whether the key mapping answered.
local shown, keyRegistered = nil, false

-- Whether a refused strip row was already logged.
local reportedStrip = false

-- Scheduler handle, so Stop can cancel it.
local syncJob = nil

-- Reads the key declaration, with the shipped value as the fallback so a config
-- that lost its KEY block still names a key.
local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or { ID = 'opx.elevators.use', NAME = 'elevators.key.use', DEFAULT = 'E' }
end

-- Whether another surface holds the keyboard; see `lib/client/spots.lua`.
local captured = OPX.Spots.Captured

-- Brings the strip in line with the lift the player is standing at.
local function syncPrompt()
	local key = nil
	-- The claim on the shared key is filed every pass, row or no row.
	local wins = OPX.Spots.Key.Shows(keySettings().ID)
	if keyRegistered and not captured() and wins then key = Runtime.Nearest() end
	if key == shown then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		shown = nil
		return
	end

	local ran, answer
	if key ~= nil then
		local elevator = M.Access.Elevator(key)
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			label = locale('elevators.prompt', { place = elevator and elevator.LABEL or key }),
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	shown = key
	if (not ran or type(answer) ~= 'table' or answer.ok ~= true) and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[elevators] the strip row was refused: ' ..
			tostring(ran and type(answer) == 'table' and answer.error or answer))
	end
end

-- Says a refusal the panel answered before it opened. A refusal after it opened
-- is the panel's own to say, on the decision event.
local function say(failure)
	local raised = OPX.Toast.Show({
		id = 'opx.elevators.answer',
		kind = OPX.Result.Kind(failure, 'error'),
		title = locale('elevators.title'),
		message = locale(Door.REFUSAL[failure] or 'elevators.refused'),
		durationMs = 5000,
	})
	if raised == nil then Open77.log.info('[elevators] panel refused: ' .. tostring(failure)) end
end

--- Catalogue key for each refusal the panel can answer before it opens.
Door.REFUSAL = {
	no_elevator_nearby = 'elevators.noElevatorNearby',
	no_such_elevator = 'elevators.noSuchElevator',
	no_floors_available = 'elevators.noFloors',
	menu_not_running = 'elevators.noPanel',
	player_down = 'elevators.downed',
}

--- Opens the floor list at the lift the player is standing at.
-- @author dop42
-- @param origin string|nil the key, or a caller's name
-- @return table
function Door.Open(origin)
	local fromKey = origin == nil or origin == 'key'
	-- NOT A WORD WHEN THE KEY FINDS NO LIFT. E is shared: clothing, garages,
	-- dealership, teleports and doors declare it too, and they already stay
	-- silent away from their spots. This one answered every press anywhere on
	-- the map with "you are not standing at an elevator", which is the owner's
	-- report. Only a press AT a lift, or a caller that named itself, is told why
	-- it failed.
	--
	-- ASKED BEFORE THE PANEL IS, for the key. `Panel.Open` checks the down state
	-- and the menu before it looks for a lift, so a player who pressed E while
	-- down -- for anything, anywhere -- was told "not while downed" by a lift
	-- that was not there.
	if fromKey and Runtime.Nearest() == nil then
		return { ok = false, error = 'no_elevator_nearby', source = 'key' }
	end
	local opened = Panel.Open(nil)
	local quiet = fromKey and opened.error == 'no_elevator_nearby'
	if opened.ok ~= true and not quiet then say(opened.error) end
	opened.source = origin or 'key'
	return opened
end

-- How far the player is from the lift the key would open, for the contest on a
-- shared key: the sighting's own reach, as `State.Nearest` ranks it.
local function wants()
	local key = Runtime.Nearest()
	if key == nil then return nil end
	local lift = M.State and M.State.seen and M.State.seen[key] or nil
	local reach = type(lift) == 'table' and (lift.reach or lift.distance) or nil
	return OPX.Spots.Key.Rank('SPOT'), type(reach) == 'number' and reach or nil
end

--- What the door holds, for a diagnostic or a test.
-- @author dop42
-- @return table
function Door.Report()
	return {
		key = OPX.Spots.Key.Label(keyRegistered, keySettings()),
		shown = shown,
	}
end

--- Clears the door state.
-- @author dop42
function Door.Init()
	shown, keyRegistered, reportedStrip, syncJob = nil, false, false, nil
end

--- Declares the key and starts the row's sync.
-- @author dop42
function Door.Start()
	-- The key, and the silent press, the way every spot module declares it: see
	-- `OPX.Spots.Key.Register`. What a press away from a lift says is
	-- `Door.Open`'s own rule (nothing).
	keyRegistered = OPX.Spots.Key.Register({
		tag = 'elevators',
		declared = keySettings(),
		onPress = Door.Open,
		wants = wants,
	})

	-- The row follows the scan's own sightings, so it runs at the scan's pace.
	local every = M.Access.SCAN_MS > 0 and M.Access.SCAN_MS or 500
	syncJob = OPX.Scheduler.Every('elevators:door', every, syncPrompt)
end

--- Cancels the sync and hands the strip back.
-- @author dop42
function Door.Shutdown()
	if syncJob ~= nil then
		OPX.Scheduler.Cancel(syncJob)
		syncJob = nil
	end
	local api = OPX.Api.Get('prompts')
	if shown ~= nil and api ~= nil and type(api.Hide) == 'function' then
		pcall(api.Hide, OWNER, GROUP)
	end
	shown = nil
end
