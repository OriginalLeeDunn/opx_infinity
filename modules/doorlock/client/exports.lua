--- The client half's lifecycle and its published contract.
-- @author dop42
--
-- The registry calls `Init`, `Api`, `Start` and `Stop` on the MODULE; the work
-- lives in `Runtime` and `Staff`. Without this file the client half is built by
-- nobody, and the module still reports as running.

local M = OPX.Modules.Get('doorlock')
local Runtime = M.Runtime
local Staff = M.Staff
local Result = OPX.Result

--- Builds the client state. Never yields.
-- @author dop42
function M.Init()
	Runtime.Init()
end

--- Publishes the client half of the doorlock contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('doorlock', 1, {
		--- What this client knows: doors, bucket, backend, the nearest door.
		State = function() return Result.Ok(Runtime.Report()) end,
		--- The door the player stands at, or a refusal.
		Nearest = function()
			local report = Runtime.Report()
			local door = report.nearest and Runtime.Door(report.nearest) or nil
			if door == nil then return Result.Err('doorlock.noDoor') end
			return Result.Ok({ key = door.key, name = door.name, locked = door.locked })
		end,
		--- Asks the server to turn the door the player stands at.
		Use = function(origin)
			if not Runtime.Use(origin or 'contract') then return Result.Err('doorlock.noDoor') end
			return Result.Ok(true)
		end,
		--- Opens the staff panel. The server still checks every write.
		OpenStaff = function()
			local flags = Runtime.Staff()
			if flags == nil then return Result.Err('doorlock.notStaff') end
			return Result.Ok(Staff.Open(flags))
		end,
	})
end

--- Declares the key, registers the rows and wires the server's answers.
-- @author dop42
function M.Start()
	Runtime.Start()
	Staff.Start()
end

--- Takes the panel down and gives every door back to the game.
-- @author dop42
function M.Stop()
	Staff.Stop()
	Runtime.Shutdown()
end
