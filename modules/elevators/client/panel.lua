--- The floor list drawn through the menu contract, which is optional.
-- @author dop42
--
-- A refused floor carries its reason as the row's value -- a greyed row with
-- nothing beside it reads as broken: the operator's REASON when there is one,
-- and `elevators.locked` otherwise.
--
-- A refusal cannot be shown under the list: the panel opens with
-- `closeOnSelect`, and the menu closes it right after raising the selection, so
-- anything written back would land on a menu that is no longer open. It goes to
-- a replaced toast instead, and to a chat line when no toast can be raised.

local M = OPX.Modules.Get('elevators')
local Access = M.Access
local Runtime = M.Runtime

M.Panel = {}
local Panel = M.Panel

-- What the menu contract records as this module's own: the owner tells two
-- callers apart, and the id names this particular menu.
local OWNER = 'elevators'

-- Elevator whose panel this file last opened, until answered or closed, and the
-- handle the menu gave it.
local openFor, handle = nil, nil

-- Whether a toast failure has already been logged.
local notifyReported = false

-- Catalogue key a player reads for each refusal code; a code with no entry
-- reads as the generic sentence.
local REFUSAL = {
	no_elevator_nearby = 'elevators.noElevatorNearby',
	no_such_elevator = 'elevators.noSuchElevator',
	no_such_floor = 'elevators.noSuchFloor',
	not_adopted = 'elevators.notAdopted',
	floor_out_of_range = 'elevators.floorOutOfRange',
	move_rejected = 'elevators.moveRejected',
	not_sent = 'elevators.notSent',
	rate_limited = 'elevators.rateLimited',
	no_character = 'elevators.noCharacter',
	job_stale = 'elevators.jobStale',
	job_required = 'elevators.jobRequired',
	grade_too_low = 'elevators.gradeTooLow',
	off_duty = 'elevators.offDuty',
	no_position = 'elevators.noPosition',
	wrong_bucket = 'elevators.wrongBucket',
	too_far = 'elevators.tooFar',
	-- The server's own down check. The sentence existed and was reached only by
	-- the client's `player_down`, so a refusal from the server read as the
	-- generic "the lift refused".
	downed = 'elevators.downed',
}

-- The operator's REASON, or this module's wording for the code.
local function refusal(payload)
	local reason = payload.reason
	if type(reason) == 'string' and reason ~= '' then return reason end
	return locale(REFUSAL[payload.error] or 'elevators.refused')
end

-- Writes a refusal as a chat line when no toast is possible. Optional: without
-- the chat contract it is a log line and nothing else.
local function chatLine(message, kind)
	local chat = OPX.Api.Get('chat')
	if chat == nil or type(chat.AddMessage) ~= 'function' then
		Open77.log.info('[elevators] ' .. message)
		return
	end
	chat.AddMessage({ kind = kind or 'error', author = locale('elevators.title'), text = message })
end

-- Shows a refusal as one replaced toast, or as a chat line otherwise.
local function toast(message, code)
	local kind = OPX.Result.Kind(code, 'error')
	local raised = OPX.Toast.Show({
		id = 'opx.elevators.answer',
		kind = kind,
		title = locale('elevators.title'),
		message = message,
		durationMs = 5000,
	})
	if raised ~= nil then return end
	if not notifyReported then
		notifyReported = true
		Open77.log.warn('[elevators] no toast: refusals go to the chat box instead')
	end
	chatLine(message, kind)
end

-- Forward-declared: the menu spec carries this callback, and it is written below
-- the opening it answers.
local onRow

-- Calls one function of the menu contract. Answers its value, or a failure code.
local function call(name, ...)
	local api = OPX.Api.Get('menu')
	if api == nil or type(api[name]) ~= 'function' then return nil, 'menu_not_running' end
	local ran, answer = pcall(api[name], ...)
	if not ran then
		Open77.log.error(('[elevators] menu %s raised: %s'):format(name, tostring(answer)))
		return nil, 'menu_raised'
	end
	if type(answer) ~= 'table' then return nil, 'malformed_answer' end
	if answer.ok ~= true then return nil, tostring(answer.error or 'refused') end
	return answer.value or answer, nil
end

-- Whether the player is down right now, read from the contract at the moment of
-- use. Without the contract nobody is down.
local function isDown()
	local api = OPX.Api.Get('downed')
	if api == nil or type(api.IsDown) ~= 'function' then return false end
	local ran, answer = pcall(api.IsDown)
	if not ran or type(answer) ~= 'table' or answer.ok ~= true then return false end
	return type(answer.value) == 'table' and answer.value.down == true
end

--- Opens an elevator's floor list through the menu contract.
-- @author dop42
-- @param key string|nil
-- @return table
function Panel.Open(key)
	-- WHERE FIRST, THEN WHETHER. The lift key is E, shared by every place in the
	-- city, and the door keeps "no lift here" silent for a key press. Asked after
	-- the down and menu checks, a press anywhere on the map while one of those
	-- failed answered `player_down` or `menu_not_running` -- a toast about lifts
	-- to a player standing nowhere near one.
	local listing = Runtime.Floors(key)
	if not listing.ok then return listing end

	-- The down screen is the answer; a panel over it could not be worked anyway.
	if isDown() then return { ok = false, error = 'player_down' } end

	local api = OPX.Api.Get('menu')
	if api == nil or type(api.Open) ~= 'function' then
		return { ok = false, error = 'menu_not_running' }
	end
	local elevator = Access.Elevator(listing.elevator)
	if #listing.floors == 0 then
		return { ok = false, error = 'no_floors_available', elevator = listing.elevator }
	end

	local rows = listing.floors
	local items = {}
	for index = 1, #rows do
		local row = rows[index]
		items[index] = {
			id = 'floor_' .. tostring(row.index),
			label = row.label,
			-- A FLOOR SAYS WHETHER IT IS OPEN TO THIS PLAYER IN THE GLYPH COLUMN as
			-- well as in the words beside it: the padlock is read at a glance down
			-- a column of eight floors, where a greyed row and a reason are read
			-- one row at a time.
			icon = row.ok and 'door' or 'lock',
			value = (not row.ok) and (row.reason or locale('elevators.locked')) or nil,
			disabled = not row.ok,
			data = { elevator = listing.elevator, floor = row.index },
		}
	end

	openFor = listing.elevator
	local opened, failure = call('Open', {
		owner = OWNER,
		id = 'elevators.' .. listing.elevator,
		title = elevator.LABEL or listing.elevator,
		on = onRow,
		closeOnSelect = true,
		items = items,
	})
	if opened == nil then
		openFor, handle = nil, nil
		Open77.log.warn(('[elevators] panel for %s did not open: %s')
			:format(listing.elevator, failure))
		return { ok = false, error = failure, elevator = listing.elevator }
	end
	handle = opened.handle
	return { ok = true, queued = true, elevator = listing.elevator, floors = #items }
end

-- Requests a selected floor, or forgets a panel the player closed. A row is only
-- believed when the menu stamped it with this module's own name.
onRow = function(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER then return end
	if payload.action == 'close' then
		-- A `select` close leaves openFor alone, since the server's answer comes
		-- next, and so does `reopened`, since it is this panel reopening.
		if openFor ~= nil and payload.menu == 'elevators.' .. openFor and
			payload.reason ~= 'select' and payload.reason ~= 'reopened' then
			openFor = nil
		end
		if payload.handle == handle then handle = nil end
		return
	end
	if payload.action ~= 'select' then return end
	local data = payload.data
	if type(data) ~= 'table' then return end
	Runtime.Use(data.elevator, data.floor, 'panel')
end

-- Toasts the first answer that carries the elevator of the panel this file
-- opened. Any answer for it, accepted or refused, clears openFor.
local function onDecision(payload)
	if type(payload) ~= 'table' or openFor == nil or payload.elevator ~= openFor then return end
	openFor = nil
	if payload.ok == true then return end
	toast(refusal(payload), payload.error)
end

--- Clears the panel state.
-- @author dop42
function Panel.Init()
	openFor, handle, notifyReported = nil, nil, false
end

--- Wires the decision channel; the menu carries the row callback itself.
-- @author dop42
function Panel.Start()
	AddEventHandler(M.Event.ON_DECISION, onDecision)
end

--- Closes the panel this file opened, and only that one: the handle is the
--- capability, so a close without it would take down whatever replaced it.
-- @author dop42
function Panel.Shutdown()
	openFor = nil
	if handle == nil then return end
	local closing = handle
	handle = nil
	call('Close', closing, 'elevators')
end
