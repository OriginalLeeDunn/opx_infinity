--- Real contract orchestration and durable character API, with explicit stores.
-- SQL crash/rollback semantics are covered separately by economy-sql.py.
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('server')
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do assert(loadfile(file, 't', env))() end
dofile('tests/money-store.lua').Install(env)
control.Pump(240)
local OPX = env.OPX
local C, G = OPX.Modules.Get('character'), OPX.Modules.Get('contracts')
local R = OPX.Result
local function up(fn, name)
 for i = 1, 100 do
  local key, value = debug.getupvalue(fn, i)
  if not key then break end
  if key == name then return value end
 end
 error('missing upvalue ' .. name)
end
local finish = up(G.Server.Reconcile, 'finish')
local operate = up(finish, 'operate')
local pay = up(finish, 'pay')
local recover = up(G.Server.Reconcile, 'recoverLocking')
local function person(source, cash)
 control.Admit(source, 'contract-test-' .. source)
 local player = C.CreatePlayer({ source = source, userId = 'contract-test-' .. source,
  citizenId = OPX.CitizenId.Generate(), money = { EDDIES = cash, BANK = 0 } }, false)
 C.RegisterPlayer(player)
 return player
end
local payer, merc = person(771, 1000), person(772, 1000)
local ledger, rows = {}, {}
local S = G.Storage
S.Reserve = function(op)
 local old = ledger[op.id]
 if old then return R.Ok({ fresh = false, state = old.state, durable = old.durable }) end
 ledger[op.id] = { state = 'reserved', durable = true, amount = op.amount,
  citizenId = op.citizenId, contractId = op.contractId, phase = op.phase }
 return R.Ok({ fresh = true, state = 'reserved', durable = true })
end
S.Settle = function(id, state)
 if ledger[id] and ledger[id].state == 'reserved' then ledger[id].state = state end
 return R.Ok(1)
end
S.Rearm = function() error('unknown operations must not be rearmed') end
S.OpInfo = function(id)
 local row = ledger[id]
 return R.Ok(row and { state = row.state, durable_version = row.durable and 1 or 0, amount = row.amount })
end
S.Move = function(record) rows[record.id] = OPX.Table.DeepCopy(record); return R.Ok(true) end
S.Forget = function(id) rows[id] = nil; return R.Ok(1) end
S.History = function() return R.Ok(1) end
local cid = payer.PlayerData.citizenId
local contract = { id = 991 }
local lose = true
local settled = S.Settle
S.Settle = function(id, state)
 if lose then lose = false; return R.Err('unavailable') end
 return settled(id, state)
end
assert(operate(contract, 'testpay', cid, 100, function(id) return pay(cid, 100, 'contract test', id) end))
assert(payer.PlayerData.money.EDDIES == 1100)
assert(ledger['contracts:991:testpay'].state == 'reserved')
assert(operate(contract, 'testpay', cid, 100, function(id) return pay(cid, 100, 'contract test', id) end))
assert(payer.PlayerData.money.EDDIES == 1100, 'lost ledger acknowledgement duplicated payment')
assert(ledger['contracts:991:testpay'].state == 'committed')
S.Settle = settled
-- An exception after dispatch remains reserved, and retry uses the same id.
local first = true
local function ambiguous(id)
 local ok, why = pay(cid, 25, 'unknown reply', id)
 if first then first = false; error('lost committed reply') end
 return ok, why
end
assert(not operate(contract, 'unknown', cid, 25, ambiguous))
assert(ledger['contracts:991:unknown'].state == 'reserved')
assert(operate(contract, 'unknown', cid, 25, ambiguous))
assert(payer.PlayerData.money.EDDIES == 1125)
-- Legacy reservations are quarantined even if their old state says committed.
ledger['contracts:992:legacy'] = { state = 'committed', durable = false }
local called = false
assert(not operate({ id = 992 }, 'legacy', cid, 50, function() called = true; return true end))
assert(not called)
-- Locking escrow: no refund while a debit is still unknown.
local record = { id = 993, state = 'locking', rev = 0, reward = 100, payerCid = cid,
 funded = G.Funded.PLAYER, posterKind = G.Poster.NPC, type = 'manual' }
local escrowId = 'contracts:993:' .. G.Phase.RESERVE
ledger[escrowId] = { state = 'reserved', durable = true, amount = 100 }
C.Money.Pending[cid] = escrowId
assert(not recover(record))
assert(record.state == 'locking' and payer.PlayerData.money.EDDIES == 1125)
C.Money.Pending[cid] = nil
-- A durable debit whose contract acknowledgement vanished is refunded once.
assert(C.RemoveMoney(payer, 'EDDIES', 100, 'escrow test', escrowId))
assert(recover(record))
assert(payer.PlayerData.money.EDDIES == 1125, 'proved escrow not restored exactly once')
assert(record.state == 'cancelled')
-- Legacy locking escrow is retained instead of deleted or refunded.
local legacy = { id = 994, state = 'locking', reward = 100, payerCid = cid }
ledger['contracts:994:' .. G.Phase.RESERVE] = { state = 'reserved', durable = false, amount = 100 }
rows[994] = legacy
assert(not recover(legacy) and rows[994] == legacy)
-- A crash after the fine debit cannot lose or duplicate its separate payout.
local failed = { id = 995, state = 'settling', outcome = 'failed', rev = 0,
 reward = 1000, funded = G.Funded.PLAYER, payerCid = cid,
 mercCid = merc.PlayerData.citizenId, posterKind = G.Poster.NPC, type = 'manual' }
local api = OPX.Api.Get('character')
local originalPay, loseFine = api.AddMoneyOffline, true
api.AddMoneyOffline = function(target, kind, amount, reason, id)
 if id and id:match(':pay$') and loseFine then
  loseFine = false
  return R.Err('money.pending')
 end
 return originalPay(target, kind, amount, reason, id)
end
local payerBefore, mercBefore = payer.PlayerData.money.EDDIES, merc.PlayerData.money.EDDIES
assert(not finish(failed))
local fine = G.Access.Penalty(failed.reward)
assert(merc.PlayerData.money.EDDIES == mercBefore - fine)
assert(finish(failed))
assert(merc.PlayerData.money.EDDIES == mercBefore - fine, 'fine debit repeated')
assert(payer.PlayerData.money.EDDIES == payerBefore + failed.reward + fine, 'fine payout lost or repeated')
api.AddMoneyOffline = originalPay
print('contracts durability: stable payment ids, lost replies, escrow proof, pending debit and legacy quarantine passed')
