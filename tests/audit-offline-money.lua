--- Offline and online credits use the same SQL ceiling and durable journal.
-- @author dop42
-- Real execution, overflow and rollback are exercised by economy-sql.py.
local Host = dofile('tests/host.lua')
local env = Host.Environment('server')
local module, saved = {}, nil
local OPX = { Modules = { Get = function() return module end } }
env.OPX = OPX
assert(loadfile('lib/shared/result.lua', 't', env))()
assert(loadfile('lib/server/storage.lua', 't', env))()
assert(loadfile('modules/character/server/storage.lua', 't', env))()
local maximum = 9007199254740991
local op = { id = 'offline-test', attempt = 'attempt', citizenId = 'TEST', moneyType = 'EDDIES',
	action = 'add', amount = maximum, reason = 'test' }
local plan = module.Storage.MoneyStatements(op)
assert(plan.ok and #plan.value == 2)
local insert = plan.value[1]
assert(insert.query:find('FOR UPDATE', 1, true), 'balance eligibility is not locked')
assert(insert.query:find('attempt_token', 1, true), 'receipt lacks attempt ownership')
assert(plan.value[2].query:find('attempt_token', 1, true), 'wallet update can reuse another attempt')
local zero = false
for _, value in ipairs(insert.values) do if value == 0 then zero = true end end
assert(zero, 'maximum credit must bind a zero remaining ceiling')
-- The actual store distinguishes an absent/deleted character from overflow.
OPX.Storage.Single = function() return OPX.Result.Ok(nil) end
OPX.Storage.Scalar = function(query)
	return OPX.Result.Ok(query == 'SELECT UUID()' and 'missing-attempt' or 0)
end
OPX.Storage.Transaction = function() return OPX.Result.Ok(true) end
assert(module.Storage.MoneyChange(op).error == 'character.notFound')
local called = false
module.Storage.MoneyChange = function(received)
	called = received.citizenId == 'TEST' and received.action == 'add' and received.amount == maximum
	return OPX.Result.Ok({ balance = maximum })
end
assert(module.Storage.AddMoney('TEST', 'EDDIES', maximum).ok and called, 'offline credit bypasses shared durable ledger')
print('offline credit shares locked wallet ceiling and journal')
