-- A stopped target registration must never recreate staff rows.
local workers, registrations, cleared = {}, 0, 0
local contract = { Clear = function() cleared = cleared + 1; return { ok = true } end }
for _, name in ipairs({ 'RegisterSelf', 'RegisterPlayers', 'RegisterVehicles', 'RegisterDoors',
 'RegisterProps', 'RegisterNpcs', 'RegisterWorld', 'RegisterSky' }) do
 contract[name] = function() registrations = registrations + 1; return { ok = true } end
end
local commands = setmetatable({}, { __index = function(_, key) return key end })
local module = {
 Command = commands, OWNER = 'admin', OPENER = 'admin', Settings = {}, Event = {},
 Section = function() return {} end,
 Client = { Contract = function() return contract end },
}
OPX = { Modules = { Get = function() return module end },
 Text = { Finite = tonumber }, Scheduler = { Every = function() return 1 end, Cancel = function() end } }
Open77 = { log = { warn = function() end } }
function locale(key) return key end
function RegisterNetEvent() end
function TriggerServerEvent() return true end
function CreateThread(fn) workers[#workers + 1] = coroutine.create(fn) end
function Wait() coroutine.yield() end
dofile('modules/admin/client/target.lua')
module.Target.Start()
module.Target.Access({ access = { admin = true }, aclKnown = false })
-- Walk until the first batch is placed, leaving more work suspended.
for _ = 1, 100 do
 assert(coroutine.resume(workers[1]))
 if registrations > 0 then break end
end
assert(registrations > 0)
module.Target.Stop()
local before = registrations
for _ = 1, 100 do
 if coroutine.status(workers[1]) == 'dead' then break end
 assert(coroutine.resume(workers[1]))
end
assert(registrations == before, 'staff rows recreated after Stop')
assert(cleared >= 2)
print('admin target: stop invalidation checks passed')
