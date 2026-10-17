-- Real production modules under small deterministic contract stubs.
local checks = 0
local function check(value, message) assert(value, message); checks = checks + 1 end
local function set(fn, key, value)
 local visited = {}
 local function walk(target)
  if visited[target] then return false end
  visited[target] = true
  for index = 1, 100 do
   local name, current = debug.getupvalue(target, index)
   if not name then break end
   if name == key then debug.setupvalue(target, index, value); return true end
   if type(current) == 'function' and walk(current) then return true end
  end
  return false
 end
 assert(walk(fn), 'missing upvalue ' .. key)
end

local Result = { Ok = function(value) return { ok = true, value = value } end,
 Err = function(code, detail) return { ok = false, error = code, detail = detail } end }
local active, now = nil, 100
OPX = { Modules = { Get = function() return active end }, Result = Result,
 Math = { Finite = tonumber }, Text = { Clean = tostring }, Now = function() return now end,
 Publish = function() end, Spots = { ServerReachSq = function(radius) return radius * radius end } }
Open77 = { log = { error = function() end, info = function() end, warn = function() end } }
-- Store guard runs after storage yields; force/offline stores preserve their API.
local writes, removed, guardCalls, writtenGarage = {}, 0, 0, nil
active = { Event = { ON_STORED = 'stored' }, Storage = { STATE = { STORED = 'stored', OUT = 'out' },
 FetchOne = function() return Result.Ok({ garage = 'old' }) end,
 SetState = function(_, state, garage) writes[#writes + 1] = state; writtenGarage = garage; return Result.Ok() end } }
Open77.vehicles = { get = function() return nil end,
 remove = function() removed = removed + 1; return true end }
dofile('modules/vehicles/server/main.lua')
local vehicles = active
set(vehicles.Store, 'live', { P = { id = 12, citizenId = 'C' } })
set(vehicles.Store, 'storing', {})
local refused = vehicles.Store('P', 'garage', function()
 guardCalls = guardCalls + 1
 check(writes[#writes] == 'stored', 'guard ran before final storage operation')
 return false, 'garages.tooFar'
end)
check(not refused.ok and refused.error == 'garages.tooFar')
check(removed == 0 and writes[#writes] == 'out', 'refused guard removed car or kept STORED')
check(guardCalls == 1)
check(writtenGarage == 'old', 'guard refusal changed the previous garage')
check(vehicles.Store('P', 'garage').ok, 'forced store lost compatibility')
check(removed == 1)
-- The recall/impound helper reads occupancy when removal is imminent.
local emptyGuard
for index = 1, 100 do
 local name, value = debug.getupvalue(vehicles.Spawn, index)
 if not name then break end
 if name == 'emptyBeforeRemoval' then emptyGuard = value; break end
end
check(type(emptyGuard) == 'function', 'recall omits the final occupant guard')
set(vehicles.Store, 'live', { P = { id = 12, citizenId = 'C' } })
local occupants = {}
Open77.vehicles.get = function() return { occupants = occupants } end
local guard = emptyGuard('P')
check(guard() == true)
occupants[1] = 7
local allowed, code = guard()
check(allowed == false and code == 'vehicle.occupied')
-- Accept checks deadline itself even if timeout worker has not resumed.
active = { Event = { SETTLED = 'settled' }, KIND = { GARAGE = 'garage', AVPAD = 'avpad' }, Access = { Coordinate = tonumber, Integer = math.tointeger,
 FiniteNumber = tonumber, OFFER_TIMEOUT_MS = 20 }, Storage = {} }
function TriggerClientEvent() end
dofile('modules/dealership/server/main.lua')
local dealership = active
set(dealership.Accept, 'offers', { [7] = { token = 1, at = 0, seller = 8, entry = 'car' } })
local expired = dealership.Accept(7, 1, true)
check(not expired.ok and expired.error == 'dealership.offerExpired')
-- Config showroom survives a failed read of both legacy tables.
local bootThreads, created = {}, 0
dealership.Settings = {}
dealership.Event = {}
dealership.Storage.SCHEMA = {}
dealership.Storage.FetchAll = function() return Result.Err('database_down') end
dealership.Storage.FetchPreviews = function() return Result.Err('database_down') end
local dealer = { key = 'dealer', bucket = 0 }
local preview = { key = 'preview', dealer = 'dealer', entry = 'car', x = 0, y = 0, z = 0 }
local da = dealership.Access
da.SPOTS, da.PREVIEW_POINTS, da.PREVIEW_LIMIT, da.KINDS = { dealer = dealer }, { preview = preview }, 5, {}
da.Problems = function() return {} end
da.PreviewsEnabled = function() return true end
da.PreviewLocked = function() return false end
da.PreviewLift = function() return 0 end
da.Entry = function() return { record = 'Vehicle.Car' } end
OPX.Api = { Get = function() return nil end }
OPX.Host = { PLAYER_DISCONNECTED = 'disconnect' }
OPX.Schema = { Add = function() end }
OPX.Table = { Count = function(values) local n = 0; for _ in pairs(values) do n = n + 1 end; return n end }
Open77.players = { all = function() return {} end }
Open77.vehicles.create = function() created = created + 1; return 88 end
function CreateThread(fn) bootThreads[#bootThreads + 1] = fn end
function locale(key) return key end
function RegisterNetEvent() end
function AddEventHandler() end
function Wait() end
dealership.Init()
dealership.Start()
bootThreads[1]()
check(created == 1, 'config showroom was suppressed by legacy database failure')
-- Garage Bring must recheck reach and citizen after the owned-list SQL call.
local position, citizen, spawned = { x = 0, y = 0, bucket = 0 }, 'C', 0
local point = { key = 'g#1', garage = 'g', location = 1, bucket = 0, x = 0, y = 0 }
local access = { Coordinate = tonumber, Integer = math.tointeger, USE_RADIUS = 3,
 Spot = function(_, key) return key == point.key and point or nil end,
 FlatDistanceSquared = function(_, x, y) return x * x + y * y end }
active = { Access = access, Storage = {} }
Open77.players = { position = function() return position end }
dofile('modules/garages/server/main.lua')
local garages = active
local character = { GetPlayer = function() return { PlayerData = { citizenId = citizen } } end }
local api = { List = function()
 position.x = 100
 return Result.Ok({ { plate = 'P', record = 'Vehicle.Car' } })
 end, Spawn = function() spawned = spawned + 1; return Result.Ok() end }
set(garages.Bring, 'character', character)
set(garages.Bring, 'vehicles', api)
set(garages.Bring, 'spots', { [point.key] = point })
set(garages.Bring, 'garages', { g = { key = 'g', locations = { {} } } })
local distant = garages.Bring(7, point.key, 'P')
check(not distant.ok and distant.error == 'garages.tooFar' and spawned == 0)
position.x = 0
api.List = function() citizen = 'D'; return Result.Ok({}) end
local switched = garages.Bring(7, point.key, 'P')
check(not switched.ok and switched.error == 'garages.noCharacter' and spawned == 0)
-- Garage Store forwards an authoritative guard that still checks after writes.
position.x, citizen = 0, 'C'
api.Occupied = function() return Result.Ok({ id = 12, plate = 'P' }) end
api.Get = function() return Result.Ok({ record = 'Vehicle.Car' }) end
local guarded = false
api.Store = function(_, _, canRemove)
 check(type(canRemove) == 'function', 'garage omitted final Store guard')
 position.x = 100
 local allowed, code = canRemove()
 guarded = true
 return allowed and Result.Ok() or Result.Err(code)
end
local rejected = garages.Use(7, point.key)
check(guarded and not rejected.ok and rejected.error == 'garages.tooFar')
print(('vehicles economy: %d checks passed'):format(checks))
