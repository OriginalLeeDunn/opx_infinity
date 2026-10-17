--- Checks the offline balance ceiling at the actual storage boundary.
-- @author dop42
--
-- Run with `lua tests/audit-offline-money.lua`. The simulated database applies
-- the UPDATE predicate and checks that its limit is bound, so removing the
-- atomic condition makes the overflow case fail rather than silently passing.

local maximum, balance, present = 9007199254740991, 0, true
local Result = { Ok = function(value) return { ok = true, value = value } end,
	Err = function(code) return { ok = false, error = code } end }
local M = {}
local storage = {
	Execute = function(sql, params)
		assert(sql:find('<= @remaining', 1, true), 'offline UPDATE lacks an atomic ceiling')
		assert(params.remaining == maximum - params.amount)
		if not present or balance > params.remaining then return Result.Ok(0) end
		balance = balance + params.amount
		return Result.Ok(1)
	end,
	Scalar = function() return Result.Ok(present and 1 or 0) end,
}
local env = setmetatable({ OPX = { Modules = { Get = function() return M end },
	Result = Result, Storage = storage } }, { __index = _G })
assert(loadfile('modules/character/server/storage.lua', 't', env))()
assert(M.Storage.AddMoney('citizen', 'EDDIES', maximum).ok)
assert(balance == maximum)
assert(M.Storage.AddMoney('citizen', 'EDDIES', 1).error == 'money.tooLarge')
assert(balance == maximum, 'refused payment changed the balance')
present = false
assert(M.Storage.AddMoney('missing', 'EDDIES', 1).error == 'character.notFound')
print('offline money audit regression checks passed')
