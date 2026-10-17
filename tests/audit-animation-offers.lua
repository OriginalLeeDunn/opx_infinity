-- Complete offers can overlap paced commits; only the newest may publish/mutate.
local handlers, workers, entries, byName = {}, {}, {}, {}
local adopted, notified = 0, 0
local catalogue = { CATEGORIES = { 'social' }, DUO_KINDS = {} }
function catalogue.Entry(name) return byName[name] end
function catalogue.Entries() return entries end
function catalogue.Forget() entries, byName = {}, {} end
function catalogue.Adopt(row)
 adopted = adopted + 1
 local entry = { name = row.name, clips = row.clips, category = 'social', written = false }
 byName[row.name] = entry; entries[#entries + 1] = entry; return entry
end
local module = { Catalogue = catalogue, Common = { Integer = function(value) return tonumber(value) end },
 Opt = { DISABLED = {} }, Presenter = {}, Event = { OFFER = 'offer' },
 Walk = { Release = function() end }, MAX_REQUEST_ID = 1000 }
OPX = { Modules = { Get = function() return module end },
 Scheduler = { Every = function() return 1 end, Cancel = function() end } }
function RegisterNetEvent(name, fn) if name then handlers[name] = fn end end
function TriggerServerEvent() return true end
function CreateThread(fn) workers[#workers + 1] = coroutine.create(fn) end
function Wait() coroutine.yield() end
dofile('modules/animations/client/main.lua')
module.Runtime.Init(); module.Runtime.Start()
module.Runtime.OnOffered = function() notified = notified + 1 end
local function offer(serial, prefix, count)
 local rows = {}
 for index = 1, count do rows[index] = { name = prefix .. index, clips = { 'clip' } } end
 handlers.offer(serial, 1, 1, rows)
 return workers[#workers]
end
local function finish(worker)
 while coroutine.status(worker) ~= 'dead' do assert(coroutine.resume(worker)) end
end
local old = offer(1, 'old', 10)
assert(coroutine.resume(old))
assert(coroutine.status(old) == 'suspended')
local newest = offer(2, 'new', 2)
finish(newest)
finish(old)
assert(notified == 1, 'superseded offer published after the newer one')
assert(module.Runtime.Offered('new1') and not module.Runtime.Offered('old1'))
assert(#module.Runtime.Entries() == 2, 'older commit replaced the newer catalogue index')
local stopped = offer(3, 'stopped', 10)
assert(coroutine.resume(stopped))
local before = adopted
module.Runtime.Shutdown()
finish(stopped)
assert(adopted == before and notified == 1, 'stopped offer worker resumed mutation or publication')
print('animation offers: concurrent commit and shutdown isolation passed')
