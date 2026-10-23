--- Carry owns a jump restriction only while its hands are occupied.
-- @author dop42
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('client')
local writes = {}
env.Open77.players.allowJump = function(allowed)
	writes[#writes + 1] = allowed
	return true
end
for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do assert(loadfile(file, 't', env))() end
control.Fire('onClientResourceStart', 'opx_infinity')
control.Pump(240)
local hauling = env.OPX.Modules.Get('hauling')
assert(env.OPX.Modules.IsRunning('hauling'), 'hauling did not boot')
local answer = assert(control.netEvents[hauling.Event.ANSWER])
answer(true, nil, '1001')
assert(writes[#writes] == false, 'carrying did not acquire the native jump restriction')
local count = #writes
answer(true, nil, '1001')
assert(#writes == count, 'unchanged carry repeatedly acquired the restriction')
answer(true, nil, false)
assert(writes[#writes] == true, 'putting the crate down did not release the jump restriction')
answer(true, nil, '1002')
hauling.Stop()
assert(writes[#writes] == true, 'module stop kept the jump restriction')
print('hauling carry jump restriction passed')
