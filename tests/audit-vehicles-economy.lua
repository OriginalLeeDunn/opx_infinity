do
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
-- A slow active registration cannot be overtaken after the old 30s heuristic.
do
 local waiting, oldWait = { C = { since = 0 } }, Wait
 set(vehicles.Register, 'registering', waiting)
 now = 61000
 Wait = function() now = now + 50 end
 local delayed = vehicles.Register('C', 'Vehicle.Car')
 check(not delayed.ok and delayed.error == 'vehicle.registering', 'slow active registration was expired')
 check(waiting.C ~= nil, 'a refused contender cleared another writer')
 Wait = oldWait
end
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

end

do
--- Actual purchase/payout orchestration; explicit SQL-effect fixture, not InnoDB.
local Host = dofile('tests/host.lua')
local rows, payouts, company, receipts = {}, {}, {}, {}
local companyDown = false
local db = Host.Database({
 scalar = function() return 0 end,
 insert = function() return 1 end,
 query = function(sql)
  if sql:find('opx77_dealership_payouts', 1, true) then
   local pending = {}; for _, row in ipairs(payouts) do if not row.paid then pending[#pending + 1] = row end end
   return pending
  end
  return {}
 end,
 single = function(sql, p)
  if sql:find('purchase_op = @id', 1, true) then return rows[p.id] end
  if sql:find('opx77_company_ledger', 1, true) then return receipts[p.op] end
  return nil
 end,
 update = function(sql, p)
  if sql:find('SET paid = 1', 1, true) then
   for _, row in ipairs(payouts) do if row.op_id == p.id and row.phase == p.phase then row.paid = true end end
  end
  return 1
 end,
 transaction = function(plan)
  if plan[1].query:find('INSERT INTO opx77_company_ledger', 1, true) then
   if companyDown then return false end
   local v = plan[1].values
   assert(not receipts[v[1]], 'duplicate company debit reached transaction')
   local key = v[2] .. ':' .. v[3]
   company[key] = (company[key] or 0) + v[4]
   receipts[v[1]] = { kind = v[2], group_key = v[3], delta = v[4], balance_after = company[key], attempt_token = v[7] }
   return true
  end
  for _, stmt in ipairs(plan) do
   local q, v = stmt.query, stmt.values
   if q:find('INSERT INTO opx77_vehicles', 1, true) then
    assert(q:find('attempt_token = ?', 1, true), 'ownership is not attempt gated')
    assert(not rows[v[11]], 'replayed ownership was inserted')
    rows[v[11]] = { plate = v[1], citizen_id = v[2], record = v[3], appearance = v[4], garage = v[5],
     state = v[6], health = v[7], body = v[8], paint = v[9], metadata = v[10] }
   elseif q:find('INSERT INTO opx77_dealership_payouts', 1, true) then
    assert(q:find('attempt_token = ?', 1, true), 'obligation is not attempt gated')
    payouts[#payouts + 1] = { phase = v[1], citizen_id = v[2], kind = v[3], group_key = v[4],
     money_type = v[5], amount = v[6], plate = v[7], op_id = v[8] }
   end
  end
  return true
 end,
})
db.unitMoneyGuard = function(guard)
 assert(guard.query:find('FOR UPDATE', 1, true), 'purchase cap not locked')
 local n = 0; for _, row in pairs(rows) do if row.citizen_id == guard.values[1] then n = n + 1 end end
 return n < guard.values[2]
end
local env, control = Host.Environment('server', db)
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do assert(loadfile(file, 't', env))() end
dofile('tests/money-store.lua').Install(env, db)
control.Pump(240)
local OPX = env.OPX
local C, V, D = OPX.Modules.Get('character'), OPX.Modules.Get('vehicles'), OPX.Modules.Get('dealership')
D.Stop()
control.Pump(30)
local function person(id, cash)
 control.Admit(id, 'vehicle-economy-' .. id)
 local p = C.CreatePlayer({ source = id, userId = 'vehicle-economy-' .. id,
  citizenId = OPX.CitizenId.Generate(), money = { EDDIES = cash, BANK = 0 } }, false)
 C.RegisterPlayer(p); return p
end
local buyer, seller = person(761, 1000), person(762, 0)
local settleSales = D.SettleSales
D.SettleSales = function() return 0 end
local actual, lose = C.Storage.MoneyChange, true
C.Storage.MoneyChange = function(op, build)
 local result = actual(op, build)
 if result.ok and lose then lose = false; error('reply lost after transaction') end
 return result
end
local sale = { sellerCitizen = seller.PlayerData.citizenId, kind = 'job', group = 'fixer' }
local payment = { amount = 100, moneyType = 'EDDIES', reason = 'audit purchase', opId = 'vehicle-audit-one',
 participant = function(op, entity) return D.Storage.SaleStatements(op, entity, sale, 'EDDIES', 10, 90) end }
local answer = V.Purchase(761, 'Vehicle.v_standard2_archer_hella_player', { garage = 'impound' }, payment)
assert(not answer.ok and answer.error == 'money.pending')
assert(rows['vehicle-audit-one'] and #payouts == 2, 'unknown purchase lost its vehicle or obligations')
assert(C.Storage.Balance(buyer.PlayerData.citizenId, 'EDDIES').value == 900)
assert(buyer.PlayerData.money.EDDIES == 1000, 'unknown reply published early')
control.Pump(30)
assert(buyer.PlayerData.money.EDDIES == 900 and not C.Money.Pending[buyer.PlayerData.citizenId])
C.Storage.MoneyChange = actual
local replay = V.Purchase(761, 'Vehicle.v_standard2_archer_hella_player', {}, payment)
assert(replay.ok and replay.value.plate == rows['vehicle-audit-one'].plate)
assert(buyer.PlayerData.money.EDDIES == 900 and #payouts == 2, 'purchase replay duplicated a side')
local ceiling = V.Settings.PER_CHARACTER
V.Settings.PER_CHARACTER = 1
local refused = V.Purchase(761, 'Vehicle.v_standard2_archer_hella_player', {}, {
 amount = 50, moneyType = 'EDDIES', reason = 'cap test', opId = 'vehicle-audit-cap' })
assert(not refused.ok and refused.error == 'vehicle.limit' and not rows['vehicle-audit-cap'])
assert(buyer.PlayerData.money.EDDIES == 900, 'cap refusal charged buyer')
V.Settings.PER_CHARACTER = ceiling
-- Lose commission acknowledgement after its durable payment. No redirection.
local api = OPX.Api.Get('character')
local originalPay, lostCommission = api.AddMoney, true
api.AddMoney = function(...)
 local paid, why = originalPay(...)
 if paid and lostCommission then lostCommission = false; error('commission reply lost') end
 return paid, why
end
D.SettleSales = settleSales
companyDown = true
D.SettleSales()
assert(seller.PlayerData.money.EDDIES == 10 and not company['job:fixer'])
D.SettleSales()
assert(seller.PlayerData.money.EDDIES == 10 and not company['job:fixer'], 'unknown commission redirected or duplicated')
companyDown = false
D.SettleSales(); D.SettleSales()
assert(seller.PlayerData.money.EDDIES == 10 and company['job:fixer'] == 90)
for _, row in ipairs(payouts) do assert(row.paid, 'durable obligation not reconciled') end
api.AddMoney = originalPay
print('vehicle economy: atomic ownership, unknown reply, replay, locked cap and fixed payout recovery passed')

end
