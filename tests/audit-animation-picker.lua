local workers, closes = {}, 0
local module = { Catalogue = { CATEGORIES = {} }, Opt = {},
 Runtime = { Locked = function() return false end, Entries = function() return {} end,
  Duos = function() return { kinds = {}, pairs = {} } end },
 Keys = { Effective = function() return nil end } }
local menu = { Open = function() coroutine.yield(); return { ok = true, value = { handle = 12 } } end,
 Close = function(handle) assert(handle == 12); closes = closes + 1; return { ok = true } end }
OPX = { Modules = { Get = function() return module end }, Now = function() return 1 end,
 Api = { Get = function(name) return name == 'menu' and menu or nil end } }
Open77 = { log = { warn = function() end, error = function() end } }
function locale(key) return key end
function CreateThread(fn) workers[#workers + 1] = coroutine.create(fn) end
function Wait() coroutine.yield() end
dofile('modules/animations/client/picker.lua')
module.Picker.Init()
assert(module.Picker.Open().ok)
assert(coroutine.resume(workers[1])) -- built
assert(coroutine.resume(workers[1])) -- menu Open pending
module.Picker.Shutdown()
assert(coroutine.resume(workers[1]))
assert(closes == 1 and not module.Picker.IsOpen(), 'late picker open survived Shutdown')
print('animation picker: late open closed after Shutdown')
