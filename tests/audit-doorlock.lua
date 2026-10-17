--- Regression checks for networked door adoption after service ownership loss.
-- @author dop42
--
-- Run with `lua tests/audit-doorlock.lua`; the export replies exercise the
-- actual backend without a running door service.

local M = { Settings = { BACKEND = 'networked' }, NETWORKED = 'open77_doors' }
local replies, calls = {}, 0
local env = setmetatable({
	OPX = { Modules = { Get = function() return M end } },
	GetResourceState = function() return 'running' end,
	Open77 = {
		log = { error = function() end, warn = function() end },
		exports = { call = function(_, method)
			calls = calls + 1
			local reply = assert(table.remove(replies, 1), 'unexpected export: ' .. method)
			assert(method == reply[1], 'unexpected export order')
			return { await = function() return reply[2], reply[3] end }
		end },
	},
}, { __index = _G })
assert(loadfile('modules/doorlock/server/backend.lua', 't', env))()
local backend = M.Backend
assert(backend.Decide() == 'networked')
local door = { id = 1, ids = { 'left', 'right' }, bucket = 0, coords = { x = 0, y = 0, z = 0 } }
replies = {
	{ 'configure', false, 'not_owner' },
	{ 'get', nil }, { 'register', false, 'conflict' },
	{ 'get', nil }, { 'register', false, 'conflict' },
}
assert(backend.Apply(door, true) == false, 'failed adoption was reported as a successful lock')
assert(backend.Refusals()[1] == 'conflict')
assert(#replies == 0)
replies = {
	{ 'configure', false, 'not_owner' },
	{ 'get', nil }, { 'register', true }, { 'configure', true },
	{ 'get', nil }, { 'register', true }, { 'configure', true },
}
assert(backend.Apply(door, true) == true, 'successful adoption did not restore both leaves')
assert(backend.Refusals()[1] == nil)
assert(#replies == 0)
print('doorlock audit regression checks passed')
