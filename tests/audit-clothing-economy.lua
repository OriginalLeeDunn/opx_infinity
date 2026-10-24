--- Clothing and its price survive lost commit replies as one operation.
-- @author dop42
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('server')
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do assert(loadfile(file, 't', env))() end
dofile('tests/money-store.lua').Install(env)
control.Pump(240)
local OPX = env.OPX
local character, appearance = OPX.Modules.Get('character'), OPX.Modules.Get('appearance')
local cid, account, source = OPX.CitizenId.Generate(), 'clothing-economy', 83
control.Admit(source, account)
local player = character.CreatePlayer({ source = source, citizenId = cid, userId = account,
	charInfo = { firstName = 'Test', lastName = 'Outfit' }, money = { EDDIES = 100, BANK = 0 } }, false)
character.RegisterPlayer(player)
local before = assert(appearance.Clothing.Canonical({ schemaVersion = 1, equipment = {}, wardrobe = {} }))
local after = assert(appearance.Clothing.Canonical({ schemaVersion = 1,
	equipment = { OuterChest = 'Items.Jacket_Police_01' }, wardrobe = {} }))
player.PlayerData.clothing = before
local durable, committed, announced = nil, 0, 0
character.Storage.UnitMoney.OnCommit = function(_, effects)
	for _, statement in ipairs(effects or {}) do
		if statement.query:find('INSERT INTO opx77_character_clothing', 1, true) then
			durable = statement.values[2]
			committed = committed + 1
		end
	end
end
local actualChange, loseReply = character.Storage.MoneyChange, true
character.Storage.MoneyChange = function(...)
	local result = actualChange(...)
	if result.ok and loseReply then loseReply = false; error('lost clothing transaction reply') end
	return result
end
local bill = { quotes = { { moneyType = 'EDDIES', amount = 25, publish = function() announced = announced + 1 end } },
	baseline = before }
local result = appearance.SaveClothing(player, after, bill)
assert(result.error == 'money.pending')
assert(durable and committed == 1 and player.PlayerData.clothing == before and player.PlayerData.money.EDDIES == 100)
local competing = appearance.SaveClothing(player, after)
assert(competing.error == 'money.pending', 'a free save raced a pending paid outfit')
control.Pump(40)
assert(appearance.Clothing.Same(player.PlayerData.clothing, after) and player.PlayerData.money.EDDIES == 75)
assert(committed == 1 and announced == 1, 'reconciliation repeated the outfit or its announcement')
character.Storage.MoneyChange = actualChange
assert(appearance.SaveClothing(player, after, bill).ok)
assert(player.PlayerData.money.EDDIES == 75 and committed == 1, 'an unchanged outfit charged twice')
local declined = appearance.SaveClothing(player, before, { baseline = player.PlayerData.clothing,
	quotes = { { moneyType = 'EDDIES', amount = 100 } } })
assert(not declined.ok and player.PlayerData.money.EDDIES == 75 and appearance.Clothing.Same(player.PlayerData.clothing, after))
print('clothing economy: outfit and price, late reply, competing save and repeated request passed')
