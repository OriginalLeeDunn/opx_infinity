local spots = {}
for i = 1, 30 do spots[tostring(i)] = { x = i, y = 1, z = 1, label = 'Garage' } end
local garages = { Runtime = { Spots = function() return spots end } }
local module = { Settings = { CATEGORIES = { garages = { SPRITE = 'garage' } } },
 ORDER = { 'garages' }, REFUSED_KEYS = {}, MIN_RANGE = 0, MAX_RANGE = 4000,
 DEFAULT_ICON = 32, QUOTA = 128 }
local workers, created, cleared = {}, 0, 0
OPX = { Modules = { Get = function(id) return id == 'garages' and garages or module end },
 Scheduler = { Cancel = function() end }, Note = function() end }
Open77 = { log = { warn = function() end, error = function() end }, blips = {
 create = function() created = created + 1; return tostring(created) end,
 clear = function() cleared = cleared + 1; return true end,
} }
function CreateThread(fn) workers[#workers + 1] = coroutine.create(fn) end
function Wait() coroutine.yield() end
dofile('modules/blips/client/main.lua')
module.Runtime.Init(); module.Runtime.Sync()
assert(coroutine.resume(workers[1])) -- deriving catalogue, paced before creating
module.Runtime.Shutdown()
while coroutine.status(workers[1]) ~= 'dead' do assert(coroutine.resume(workers[1])) end
assert(created == 0 and cleared == 1, 'stale reconcile recreated pins after Shutdown')
print('blips lifecycle: stopped reconcile cannot recreate pins')
