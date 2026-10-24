--- Cache reconciliation, late replies, replay and source lifetime on real APIs.
-- @author dop42
-- SQL execution/crash boundaries are verified separately by economy-sql.py.
-- This fixture replaces only durable storage; real hooks, locks and trades run.
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('server')
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do assert(loadfile(file, 't', env))() end
dofile('tests/money-store.lua').Install(env)
control.Pump(240)
local OPX = env.OPX
local character, inventory = OPX.Modules.Get('character'), OPX.Modules.Get('inventory')
local playerId, account = 77, 'durability-account'
control.Admit(playerId, account)
control.Stand(playerId, 10, 10, 0)
local player = character.CreatePlayer({ source = playerId, userId = account,
	citizenId = OPX.CitizenId.Generate(), charInfo = { firstName = 'Test', lastName = 'Wallet' },
	money = { EDDIES = 100, BANK = 0 } }, false)
character.RegisterPlayer(player)
local bag = inventory.Containers.Transient(inventory.KIND.CHARACTER, player.PlayerData.citizenId, 50, 100000)
bag.transient = nil
inventory.Players.Attach(playerId)
local store = character.Storage
local actualChange = store.MoneyChange
local notices, actualAnnounce = 0, character.AnnounceMoney
character.AnnounceMoney = function(...)
	notices = notices + 1
	local stored = store.Balance(player.PlayerData.citizenId, 'EDDIES')
	assert(stored.ok and stored.value == player.PlayerData.money.EDDIES, 'success announced before durable balance')
	return actualAnnounce(...)
end
local function notes() return inventory.Currency.CountIn(bag) end
local function total() return player.PlayerData.money.EDDIES + notes() end

-- Database commits both halves, but the reply disappears before memory changes.
local loseReply = true
local recoveryThrows = true
store.MoneyChange = function(op, build)
	local answer = actualChange(op, build)
	if answer.ok and loseReply then
		loseReply = false
		error('simulated lost response after commit')
	end
	if answer.ok and recoveryThrows then recoveryThrows = false; error('transient exception during recovery') end
	return answer
end
local ok, code = inventory.Currency.Withdraw(playerId, 20)
assert(not ok and code == 'money.pending', 'ambiguous commit was treated as a safe failure')
assert(notes() == 0 and player.PlayerData.money.EDDIES == 100 and bag.economicLock, 'unacknowledged snapshot was published or unlocked')
assert(store.Balance(player.PlayerData.citizenId, 'EDDIES').value == 80, 'fixture did not commit before losing reply')
local blocked, why = character.AddMoney(player, 'EDDIES', 1, 'blocked while pending')
assert(not blocked and why == 'money.pending')
local changed = inventory.Containers.Add(bag, 'water', 1)
assert(not changed, 'another item writer entered a pending bag')
control.Pump(45)
assert(not bag.economicLock and not character.Money.Pending[player.PlayerData.citizenId])
assert(notes() == 20 and player.PlayerData.money.EDDIES == 80 and total() == 100, 'reconciliation did not restore both halves once')
assert(notices == 1, 'recovery announced a duplicate money movement')
store.MoneyChange = actualChange
local slot = next(bag.items)
assert(inventory.Currency.Deposit(playerId, slot))
assert(total() == 100 and notes() == 0 and player.PlayerData.money.EDDIES == 100)

-- Receipt lookup precedes the now-insufficient balance and changed veto hooks.
assert(character.RemoveMoney(player, 'EDDIES', 100, 'durable purchase', 'same-payment'))
assert(player.PlayerData.money.EDDIES == 0)
local vetoed = 0
local hook = OPX.Hooks.Register('money:beforeRemove', function() vetoed = vetoed + 1; return false end)
local priorNotices = notices
assert(character.RemoveMoney(player, 'EDDIES', 100, 'durable purchase', 'same-payment'))
assert(vetoed == 0 and notices == priorNotices, 'a replay reran payment hooks or events')
OPX.Hooks.Remove(hook)
assert(character.AddMoney(player, 'EDDIES', 50, 'another payment'))
assert(character.RemoveMoney(player, 'EDDIES', 100, 'durable purchase', 'same-payment'))
assert(player.PlayerData.money.EDDIES == 50, 'an old receipt overwrote a newer balance')
local conflict, conflictCode = character.RemoveMoney(player, 'EDDIES', 1, 'durable purchase', 'same-payment')
assert(not conflict and conflictCode == 'money.opIdConflict')

-- Hold a replay's balance snapshot while another coroutine tries a new credit.
-- Without the replay lock the second credit commits and the old snapshot then
-- overwrites its cache. With the lock it runs after the replay has released it.
local actualBalance = store.Balance
local parked, hold, firstRead = false, true, true
store.Balance = function(...)
	local snapshot = actualBalance(...)
	if firstRead then
		firstRead, parked = false, true
		while hold do env.Wait(0) end
	end
	return snapshot
end
local replayAnswer, addAnswer
env.CreateThread(function() replayAnswer = character.RemoveMoney(player, 'EDDIES', 100, 'durable purchase', 'same-payment') end)
control.Pump(1)
assert(parked)
env.CreateThread(function() addAnswer = character.AddMoney(player, 'EDDIES', 10, 'concurrent credit') end)
control.Pump(3)
hold = false
control.Pump(20)
store.Balance = actualBalance
assert(replayAnswer and addAnswer and store.Balance(player.PlayerData.citizenId, 'EDDIES').value == 60)
assert(player.PlayerData.money.EDDIES == 60, 'a concurrent replay restored a stale cache balance')

-- A preparation error is before dispatch: nothing moved and locks are released.
local released = false
local before = player.PlayerData.money.EDDIES
local failed = character.AtomicMoney(player, 'EDDIES', 10, 'remove', 'broken participant', nil, function(op)
	op.release = function() released = true end
	return function() error('invalid participant before transaction') end
end)
assert(not failed.ok and released and not character.Money.Pending[player.PlayerData.citizenId])
assert(player.PlayerData.money.EDDIES == before)

-- A hauling sale locks and installs the bag and every trunk together.
local trunk = inventory.Containers.Transient(inventory.KIND.TRUNK, 'durable-test-trunk', 10, 100000)
trunk.transient = nil
assert(inventory.Containers.Add(bag, 'water', 1))
assert(inventory.Containers.Add(trunk, 'water', 2))
local actualTrunk = inventory.EconomicTrunk
inventory.EconomicTrunk = function() return OPX.Result.Ok(trunk) end
local beforeSale = player.PlayerData.money.EDDIES
local failed = true
store.MoneyChange = function(op, build)
	local result = actualChange(op, build)
	if result.ok and failed then failed = false; error('lost multi-container sale reply') end
	return result
end
local sale = inventory.Economy.Trade(player, 'EDDIES', 20,
	{ { name = 'water', count = -1 }, { name = 'water', count = -2, vehicleId = 99 } }, 'hauling:test')
assert(not sale.ok and sale.error == 'money.pending' and bag.economicLock and trunk.economicLock)
assert(inventory.Containers.CountIn(bag, 'water') == 1 and inventory.Containers.CountIn(trunk, 'water') == 2)
assert(not inventory.Containers.Remove(trunk, 'water', 1))
control.Pump(30)
assert(not bag.economicLock and not trunk.economicLock)
assert(inventory.Containers.CountIn(bag, 'water') == 0 and inventory.Containers.CountIn(trunk, 'water') == 0)
assert(player.PlayerData.money.EDDIES == beforeSale + 20)
store.MoneyChange, inventory.EconomicTrunk = actualChange, actualTrunk

-- A yielded hook cannot bill a character that left the source in the meantime.
hook = OPX.Hooks.Register('money:beforeAdd', function() character.UnregisterPlayer(player) end)
local count = OPX.Table.Count(store.UnitMoney.receipts)
local stale, staleCode = character.AddMoney(player, 'EDDIES', 10, 'stale player')
assert(not stale and staleCode == 'error.notLoggedIn' and OPX.Table.Count(store.UnitMoney.receipts) == count)
OPX.Hooks.Remove(hook)
character.RegisterPlayer(player)
assert(character.SetMoney(player, 'EDDIES', 9007199254740991, 'safe maximum'))
assert(player.PlayerData.money.EDDIES == 9007199254740991)
local overflow, overflowCode = character.AddMoney(player, 'EDDIES', 1, 'overflow')
assert(not overflow and overflowCode == 'money.tooLarge')
local direct = player.Functions.SetPlayerData('money', { EDDIES = 1 })
assert(direct == false and player.PlayerData.money.EDDIES == 9007199254740991)
print('durable money: lost commit replies, atomic notes, replay, current cache, hooks and source lifetime passed')
