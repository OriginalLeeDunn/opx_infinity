--- Unsurveyed fuel stations must not strand a new server's players.
-- @author dop42
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('server')
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do assert(loadfile(file, 't', env))() end
control.Pump(240)
local fuel = env.OPX.Modules.Get('fuel')
assert(not fuel.RefuelingAvailable(), 'default station placeholders became active')
local burns = 0
fuel.Tanks.BurnOne = function() burns = burns + 1 end
env.Open77.vehicles.all = function() return { { id = 99 } } end
fuel.Tanks.Tick()
assert(burns == 0, 'fuel burned without a usable station')
fuel.RefuelingAvailable = function() return true end
control.Advance(1000)
fuel.Tanks.Tick()
assert(burns == 1, 'surveyed stations did not reenable consumption')
print('fuel readiness: consumption paused before station survey and resumes afterwards')
