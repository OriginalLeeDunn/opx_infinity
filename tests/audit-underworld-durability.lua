--- Real op/AtomicTrade orchestration; durable storage is an explicit unit double.
-- Native behaviour and InnoDB commit boundaries are qualified separately.
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('server')
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do assert(loadfile(file, 't', env))() end
dofile('tests/money-store.lua').Install(env)
control.Pump(240)
local OPX = env.OPX
local C, I, U = OPX.Modules.Get('character'), OPX.Modules.Get('inventory'), OPX.Modules.Get('underworld')
local R = OPX.Result
local sequence = 0
U.Storage.NewEconomicId = function() sequence = sequence + 1; return R.Ok('underworld-audit-' .. sequence) end
U.Storage.EscrowLeft = function() return {} end
assert(U.Op.Recover())
local function person(id)
 control.Admit(id, 'underworld-account-' .. id)
 control.Stand(id, 10, 10, 1)
 local p = C.CreatePlayer({ source = id, userId = 'underworld-account-' .. id,
  citizenId = OPX.CitizenId.Generate(), money = { EDDIES = 500, BANK = 0 } }, false)
 C.RegisterPlayer(p)
 local bag = I.Containers.Transient(I.KIND.CHARACTER, p.PlayerData.citizenId, 50, 100000)
 bag.transient = nil
 I.Players.Attach(id)
 return p, bag
end
local p, bag = person(751)
local receiver = person(752)
assert(I.Containers.Add(bag, 'dirty_eddies', 100))
local progress = OPX.Api.Get('progress')
local originalStart = progress.Start
progress.Start = function() return R.Ok({ id = 'underworld-test-bar' }) end
local released, notifications = 0, 0
local spec = { kind = 'audit', durable = true, anchor = { x = 10, y = 10, z = 1, bucket = 0 }, reach = 3,
 durationMs = 1000, lock = 'underworld-audit-lock',
 inputs = { items = { { name = 'dirty_eddies', count = 10 } }, money = { { type = 'EDDIES', amount = 20 } } },
 release = function() released = released + 1 end,
 after = function(_, ok) if ok then notifications = notifications + 1 end end,
 commit = function(op)
  local done = U.Op.Atomic(op, { { name = 'ammo_handgun', count = 1 } }, 'EDDIES', 0)
  return done.ok, done.ok and 'bought' or done.error
 end,
}
local started, why, op = U.Op.Begin(751, spec)
assert(started, why)
assert(I.Containers.CountIn(bag, 'dirty_eddies') == 100 and p.PlayerData.money.EDDIES == 500,
 'progress start consumed value before an atomic commit')
local change, lose = C.Storage.MoneyChange, true
C.Storage.MoneyChange = function(context, build)
 local result = change(context, build)
 if result.ok and lose then lose = false; error('reply lost after commit') end
 return result
end
U.Op.Settle(op.id, { id = op.barId, completed = true })
assert(op.state == 'pending' and U.Op.Locked(spec.lock))
assert(not U.Op.Cancel(op, 'cancelled'), 'an unknown committed trade could be cancelled/refunded')
assert(released == 0 and notifications == 0)
assert(I.Containers.CountIn(bag, 'dirty_eddies') == 100 and p.PlayerData.money.EDDIES == 500)
control.Pump(40)
assert(op.state == 'done' and not U.Op.Locked(spec.lock))
assert(released == 0 and notifications == 1)
assert(I.Containers.CountIn(bag, 'dirty_eddies') == 90 and I.Containers.CountIn(bag, 'ammo_handgun') == 1)
assert(p.PlayerData.money.EDDIES == 480)
U.Op.Settle(op.id, { id = op.barId, completed = true })
assert(p.PlayerData.money.EDDIES == 480 and I.Containers.CountIn(bag, 'ammo_handgun') == 1)
C.Storage.MoneyChange = change
local cancelled, _, cancelOp = U.Op.Begin(751, spec)
assert(cancelled)
assert(U.Op.Cancel(cancelOp, 'cancelled'))
assert(released == 1 and p.PlayerData.money.EDDIES == 480 and I.Containers.CountIn(bag, 'dirty_eddies') == 90)
-- Old escrow has no reliable debit proof, so recovery only quarantines it.
local quarantined = 0
U.Storage.EscrowLeft = function() return { { opId = 'old-unproved', citizenId = p.PlayerData.citizenId,
 payload = { items = { { name = 'dirty_eddies', count = 1000 } } } } } end
U.Storage.QuarantineEscrow = function(id) assert(id == 'old-unproved'); quarantined = quarantined + 1; return R.Ok(1) end
assert(U.Op.Recover() and quarantined == 1)
assert(I.Containers.CountIn(bag, 'dirty_eddies') == 90 and p.PlayerData.money.EDDIES == 480)
-- Drugs must route the full exchange through the peer primitive, including dirty reverse payment.
local function up(fn, key)
 for index = 1, 100 do
  local name, value = debug.getupvalue(fn, index)
  if not name then break end
  if name == key then return value end
 end
 error('missing ' .. key)
end
local deals = up(U.Drugs.Complete, 'deals')
local api, peerCalls = OPX.Api.Get('inventory'), 0
local oldPeer, oldAdd, oldRemove = api.AtomicPeerTrade, api.AddItem, api.RemoveItem
api.AddItem, api.RemoveItem = function() error('split peer credit') end, function() error('split peer debit') end
api.AtomicPeerTrade = function(seller, buyer, moneyType, amount, changes, reason, id)
 peerCalls = peerCalls + 1
 assert(seller == p.PlayerData.citizenId and buyer == receiver.PlayerData.citizenId)
 assert(moneyType == U.Built.dirty.cleanType and reason == 'underworld:deal' and id:match('^underworld:deal:'))
 assert(changes[1].name == 'glitter' and changes[1].count == 3)
 if U.Built.street.currency == 'clean' then assert(amount == 50 and #changes == 1)
 else assert(amount == 0 and changes[2].reverse and changes[2].count == 50) end
 return R.Err('money.pending')
end
for _, currency in ipairs({ 'dirty', 'clean' }) do
 U.Built.street.currency = currency
 deals[currency] = { seller = 751, buyer = 752, sellerCitizen = p.PlayerData.citizenId,
  buyerCitizen = receiver.PlayerData.citizenId, item = 'glitter', count = 3, price = 50 }
 assert(not U.Drugs.Complete(currency))
 assert(not U.Drugs.Complete(currency), 'second coordinator completion repeated a swap')
end
assert(peerCalls == 2)
api.AtomicPeerTrade, api.AddItem, api.RemoveItem = oldPeer, oldAdd, oldRemove
progress.Start = originalStart
print('underworld durability: deferred inputs, lost reply, retained claims, no refund, replay, quarantine and peer routing passed')
