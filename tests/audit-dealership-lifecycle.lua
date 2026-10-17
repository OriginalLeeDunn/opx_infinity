local module = { Access = {}, KIND = { GARAGE = 'garage', AVPAD = 'avpad' }, Settings = {} }
local threads, registered, cleared = {}, 0, 0
local eye = { RegisterPlayers = function() registered = registered + 1; return { ok = true } end,
 Clear = function() cleared = cleared + 1; return { ok = true } end }
OPX = { Modules = { Get = function() return module end },
 Spots = { Key = { Shows = function() return true end }, Markers = { New = function() return { Reset = function() end, Clear = function() end } end } },
 Api = { Get = function(name) return name == 'target' and eye or nil end },
 Scheduler = { Cancel = function() end } }
Open77 = { log = { warn = function() end, info = function() end } }
function CreateThread(fn) threads[#threads + 1] = coroutine.create(fn) end
function Wait() coroutine.yield() end
function locale(key) return key end
dofile('modules/dealership/client/main.lua')
local function up(fn, wanted, replacement, mutate)
 local seen = {}
 local function walk(f)
  if seen[f] then return end; seen[f] = true
  for i = 1, 100 do
   local name, value = debug.getupvalue(f, i)
   if not name then break end
   if name == wanted then if mutate then debug.setupvalue(f, i, replacement) end; return true, value end
   if name ~= '_ENV' and type(value) == 'function' then
    local ok, result = walk(value); if ok then return ok, result end
   end
  end
 end
 local ok, result = walk(fn); assert(ok, wanted); return result
end
module.Runtime.Init()
up(module.Runtime.Start, 'zone', {}, true)
local sync = up(module.Runtime.Start, 'syncTarget')
sync()
assert(coroutine.resume(threads[1]))
-- A waiting offer must not open another menu while shutting down.
up(module.Runtime.Shutdown, 'offer', {}, true)
up(module.Runtime.Shutdown, 'offerWaiting', true, true)
module.Runtime.Shutdown()
assert(coroutine.resume(threads[1]))
assert(registered == 0, 'showroom row registered after Shutdown')
assert(cleared == 1)
print('dealership lifecycle: pending offer and registration shutdown passed')
