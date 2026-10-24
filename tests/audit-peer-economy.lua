--- Two wallets and two bags cannot split across a failed peer trade.
-- @author dop42
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('server')
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do assert(loadfile(file, 't', env))() end
dofile('tests/money-store.lua').Install(env)
control.Pump(240)
local OPX = env.OPX
local character, inventory = OPX.Modules.Get('character'), OPX.Modules.Get('inventory')
local function person(source, cash)
	local account, cid = 'peer-account-' .. source, OPX.CitizenId.Generate()
	control.Admit(source, account)
	control.Stand(source, 10, 10, 0)
	local player = character.CreatePlayer({ source = source, userId = account, citizenId = cid,
		charInfo = { firstName = 'Test', lastName = 'Peer' }, money = { EDDIES = cash, BANK = 0 } }, false)
	character.RegisterPlayer(player)
	local bag = inventory.Containers.Transient(inventory.KIND.CHARACTER, cid, 20, 100000)
	bag.transient = nil
	inventory.Players.Attach(source)
	return player, bag
end
local seller, sellerBag = person(81, 10)
local buyer, buyerBag = person(82, 100)
local sellerId, buyerId = seller.PlayerData.citizenId, buyer.PlayerData.citizenId
assert(inventory.Containers.Add(sellerBag, 'water', 3))
local function count(bag, name) return inventory.Containers.CountIn(bag, name) end
local function trade(id, price, count)
	return inventory.Economy.PeerTrade(sellerId, buyerId, 'EDDIES', price,
		{ { name = 'water', count = count } }, 'peer audit', id)
end
local veto = OPX.Hooks.Register('money:beforeAdd', function() return false end)
assert(trade('peer-veto', 20, 2).error == 'money.vetoed')
assert(count(sellerBag, 'water') == 3 and buyer.PlayerData.money.EDDIES == 100)
OPX.Hooks.Remove(veto)
local store, original = character.Storage, character.Storage.MoneyChange
local disappear = true
store.MoneyChange = function(...)
	local answer = original(...)
	if answer.ok and disappear then disappear = false; error('lost peer commit reply') end
	return answer
end
assert(trade('peer-success', 20, 2).error == 'money.pending')
assert(buyer.PlayerData.money.EDDIES == 100 and seller.PlayerData.money.EDDIES == 10)
assert(count(sellerBag, 'water') == 3 and count(buyerBag, 'water') == 0)
assert(sellerBag.economicLock and buyerBag.economicLock)
assert(character.Money.Pending[sellerId] and character.Money.Pending[buyerId])
-- Slow reconciliation must never expire a known active wallet lock.
control.Advance(61000)
assert(character.Ledger.Busy(sellerId) and character.Ledger.Busy(buyerId))
assert(not character.AddMoney(seller, 'EDDIES', 1, 'competing credit'))
control.Pump(40)
assert(not sellerBag.economicLock and not buyerBag.economicLock)
assert(not character.Money.Active[sellerId] and not character.Money.Active[buyerId])
assert(buyer.PlayerData.money.EDDIES == 80 and seller.PlayerData.money.EDDIES == 30)
assert(count(sellerBag, 'water') == 1 and count(buyerBag, 'water') == 2)
store.MoneyChange = original
assert(trade('peer-success', 20, 2).ok, 'replay incorrectly required already delivered items')
assert(buyer.PlayerData.money.EDDIES == 80 and seller.PlayerData.money.EDDIES == 30)
local unrelated = person(84, 0)
local wrongSeller = inventory.Economy.PeerTrade(unrelated.PlayerData.citizenId, buyerId, 'EDDIES', 20,
	{ { name = 'water', count = 2 } }, 'peer audit', 'peer-success')
assert(wrongSeller.error == 'money.opIdConflict', 'replay changed the credited seller')
assert(trade('peer-insufficient', 200, 1).error == 'money.insufficient')
assert(character.SetMoney(seller, 'EDDIES', 9007199254740991, 'maximum'))
assert(trade('peer-overflow', 1, 1).error == 'money.tooLarge')
assert(not sellerBag.economicLock and not buyerBag.economicLock)
assert(count(sellerBag, 'water') == 1 and count(buyerBag, 'water') == 2 and buyer.PlayerData.money.EDDIES == 80)
assert(inventory.Containers.Add(buyerBag, 'scrap_metal', 2))
local swap = inventory.Economy.PeerTrade(sellerId, buyerId, 'EDDIES', 0,
	{ { name = 'water', count = 1 }, { name = 'scrap_metal', count = 2, reverse = true } }, 'item currency', 'peer-swap')
assert(swap.ok, swap.error)
assert(count(sellerBag, 'water') == 0 and count(buyerBag, 'water') == 3)
assert(count(sellerBag, 'scrap_metal') == 2 and count(buyerBag, 'scrap_metal') == 0)
assert(buyer.PlayerData.money.EDDIES == 80 and seller.PlayerData.money.EDDIES == 9007199254740991)
local releaseProbe = { id = 'peer-release', citizenId = buyerId, moneyType = 'EDDIES', amount = 0,
	release = function() error('optional participant cleanup raised') end }
assert(character.Money.AttachCredit(releaseProbe, seller))
releaseProbe.release()
assert(not character.Money.Pending[sellerId] and not character.Money.Active[sellerId] and not character.Ledger.Busy(sellerId))
print('peer economy: two wallets, two bags, late reply, replay, veto, overflow, long locks and item currency passed')
