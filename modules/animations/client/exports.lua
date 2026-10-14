--- The animations contract, and the client half's lifecycle.
-- @author dop42
--
-- Every function answers a Result and none of them ever raises: `checked` turns
-- a raise inside one into `internal_error` and a log line naming the function.
--
-- `Play` and `Stop` answer "asked for": `value.requestId` addresses the verdict,
-- which arrives on `M.Event.ON_RESULT`. A refusal from here raises no toast, so
-- the caller decides what to show.
--
-- `owner` names the caller that owns the playback. It is what lets that caller,
-- and only it, stop or replace a playback nobody else may, and what ends the
-- playback when the owning module stops. Passing nil simply records no owner.
--
-- This file is last on purpose: publishing the surface asserts it exists.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common
local Presenter = M.Presenter
local Runtime = M.Runtime
local Picker = M.Picker
local Prompt = M.Prompt
local Keys = M.Keys

local Result = OPX.Result

-- Turns the internal request shape into a Result, keeping its fields.
local function answered(request)
	if request.ok ~= true then return Result.Err(request.error or 'refused') end
	request.ok = nil
	return Result.Ok(request)
end

-- Wraps a contract function so a raise inside it is a refusal, not a fault in
-- whatever called it.
local function checked(name, fn)
	return function(...)
		local ran, answer = pcall(fn, ...)
		if not ran then
			Open77.log.error(('[animations] %s raised: %s'):format(name, tostring(answer)))
			return Result.Err('internal_error')
		end
		return answer
	end
end

--- Asks for an animation on the local player; the verdict follows.
-- @author dop42
-- @param name string
-- @param options table|nil variant, clip, loop, durationMs, cancelable
-- @param owner string|nil
-- @return Result
local function play(name, options, owner)
	return answered(Runtime.Play(name, options, 'contract', owner))
end

--- Asks for the local player's animation to end, whoever started it.
-- @author dop42
-- @param owner string|nil
-- @return Result
local function stop(owner)
	return answered(Runtime.Stop('contract', owner))
end

--- Answers every animation this player may ask for, optionally in one category.
-- @author dop42
-- @param category string|nil
-- @return Result
local function list(category)
	if category ~= nil then
		if not Catalogue.IsCategory(category) then return Result.Err('unknown_category') end
		category = category:lower()
	end
	local animations = {}
	local entries = Runtime.Entries(category)
	for index = 1, #entries do animations[index] = Runtime.Listing(entries[index]) end
	return Result.Ok({ animations = animations })
end

--- Answers the categories in picker order, with a count each.
-- @author dop42
-- @return Result
local function categories()
	local rows = {}
	for index = 1, #Catalogue.CATEGORIES do
		local category = Catalogue.CATEGORIES[index]
		rows[index] = {
			name = category,
			label = locale('animations.category.' .. category),
			count = #Runtime.Entries(category),
		}
	end
	return Result.Ok({ categories = rows })
end

--- Answers one animation with its offered variants.
-- @author dop42
-- @param name string
-- @return Result
local function get(name)
	local entry = Runtime.Offered(name)
	if entry == nil then return Result.Err('unknown_animation') end
	return Result.Ok({ animation = Runtime.Listing(entry) })
end

--- Answers what a player plays, the local player by default.
-- @author dop42
-- @param playerId integer|nil
-- @return Result
local function state(playerId)
	if playerId ~= nil then
		playerId = Common.Integer(tonumber(playerId), 1, Common.MAX_INTEGER)
		if playerId == nil then return Result.Err('invalid_player') end
	end
	if not Presenter.Available() then return Result.Err('presentation_unavailable') end
	local answer = Presenter.State(playerId)
	answer.presenting = Presenter.Presenting()
	return Result.Ok(answer)
end

--- Opens the picker, on a category's screen when one is named.
-- @author dop42
-- @param category string|nil
-- @return Result
local function openPicker(category)
	return answered(Picker.Open(category))
end

--- Closes the picker when this module has it open.
-- @author dop42
-- @return Result
local function closePicker()
	return answered(Picker.Close())
end

--- Builds the mirror, the request state, the screen stack and the strip.
-- @author dop42
function M.Init()
	-- The presenter first: Runtime.Init posts its two hooks onto it.
	Presenter.Init()
	Runtime.Init()
	Picker.Init()
	M.Invite.Init()
	Prompt.Init()
end

--- Publishes the animations contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('animations', 1, {
		Play = checked('Play', play),
		Stop = checked('Stop', stop),
		List = checked('List', list),
		Categories = checked('Categories', categories),
		Get = checked('Get', get),
		State = checked('State', state),
		OpenPicker = checked('OpenPicker', openPicker),
		ClosePicker = checked('ClosePicker', closePicker),
	})
end

--- Starts the mirror, the request channels, the keys and the picker.
-- @author dop42
function M.Start()
	Presenter.Start()
	Runtime.Start()
	Keys.Start()
	Picker.Start()
	M.Invite.Start()
	M.Walk.Start()
end

--- Takes every screen, prompt and posed body back down.
-- @author dop42
function M.Stop()
	Picker.Shutdown()
	M.Invite.Shutdown()
	Prompt.Shutdown()
	Runtime.Shutdown()
	Presenter.Shutdown()
end
