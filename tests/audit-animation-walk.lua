local module = { Catalogue = {}, Settings = {} }
OPX = { Modules = { Get = function() return module end } }
local calls, accepted = 0, false
Open77 = { log = { warn = function() end }, movement = { setWalkMode = function()
 calls = calls + 1; return accepted, 'refused'
end } }
dofile('modules/animations/client/walk.lua')
assert(module.Walk.Hold(1) == false)
assert(module.Walk.Held() == nil)
accepted = true
assert(module.Walk.Hold(1) == true and calls == 2)
accepted = false
module.Walk.Release()
assert(module.Walk.Held() == 1, 'refused release forgot the active lease')
accepted = true
module.Walk.Release()
assert(module.Walk.Held() == nil and calls == 4)
assert(module.Walk.Hold(0/0) == false and calls == 4)
assert(module.Walk.Hold(1))
accepted = false
module.Walk.Release()
accepted = true
module.Walk.Check()
assert(module.Walk.Held() == nil, 'watchdog failed to retry refused release')
print('animation walk: refused lease and retry checks passed')
