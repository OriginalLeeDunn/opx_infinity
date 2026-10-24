--- Regression checks for durable service payments and conditional slot removal.
-- @author dop42
--
-- A yielding account or inventory read must never redirect settlement to the
-- replacement occupant of a server id. Run with Lua 5.4 from the repo root.

local function upvalue(fn, wanted)
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if name == nil then break end
		if name == wanted then return value end
	end
	error('missing upvalue ' .. wanted)
end

local current = 'original'
local paid, removed, added = {}, {}, {}
local api = {
	GetPlayer = function() return { PlayerData = { citizenId = current } } end,
	AddMoney = function(target) paid[#paid + 1] = target; return true end,
}
local bag = {
	RemoveFromSlot = function(_, _, _, expected)
		removed[#removed + 1] = expected
		return { ok = expected.name == 'shard' and expected.metadata.serial == 'original' }
	end,
	AddItem = function(target) added[#added + 1] = target; coroutine.yield(); return { ok = true } end,
}
local accounts = {
	Withdraw = function() coroutine.yield(); return { ok = true } end,
	PayCitizen = function(_, _, citizen) coroutine.yield(); paid[#paid + 1] = citizen; return { ok = true } end,
}
local M = { Access = { Build = function() return { currency = 'BANK' } end }, Kind = {}, Stage = {} }
local env = setmetatable({ OPX = {
	Modules = { Get = function() return M end }, Result = {},
	Api = { Get = function(name) return ({ character = api, inventory = bag, accounts = accounts })[name] end },
	Tune = { Declare = function() end }, Audit = { Log = function() end },
}, Open77 = { log = { warn = function() end } } }, { __index = _G })
assert(loadfile('modules/corpo/server/main.lua', 't', env))()
M.Init()
local task = coroutine.create(function()
	assert(M.Server.Pay(7, { key = 'corp', account = { kind = 'job', key = 'corp' } }, 10, 'op', 'test'))
end)
assert(coroutine.resume(task))
current = 'replacement'
assert(coroutine.resume(task))
assert(paid[1] == 'original', 'payment followed a recycled player id')
local takeSlot = upvalue(M.Server.Fail, 'takeSlot')
assert(takeSlot(7, 3, 'shard', { serial = 'original' }))
assert(removed[1].name == 'shard' and removed[1].metadata.serial == 'original',
	'slot removal lost its expected item')

M = { Model = {}, Storage = {} }
assert(loadfile('modules/underworld/server/op.lua', 't', env))()
local paidBefore, addedBefore = #paid, #added
local quarantined = nil
M.Storage.EscrowLeft = function() return { { opId = 'unproved-legacy', citizenId = 'original',
 payload = { items = { { name = 'a', count = 1 }, { name = 'b', count = 1 } },
  money = { { type = 'BANK', amount = 5 } } } } } end
M.Storage.QuarantineEscrow = function(id) quarantined = id; return { ok = true } end
assert(M.Op.Recover())
assert(quarantined == 'unproved-legacy' and #paid == paidBefore and #added == addedBefore,
 'ambiguous legacy escrow caused an automatic payment/refund')
assert(M.Op.Refund == nil, 'unsafe split escrow refund API remains reachable')
print('audit-services: PASS')

-- An outsourced offer is claimed before the account write yields: a second
-- caller cannot publish it with the same idempotent withdrawal receipt.
local corp = { key = 'corp', job = 'corp', publishGrade = 0, account = { kind = 'job', key = 'corp' } }
local offer = { id = 'offer', template = 'delivery', kind = 'deliver', label = 'Delivery', pay = 10 }
M = { Kind = {}, Stage = {}, Access = {
	Build = function() return { currency = 'BANK', order = { 'corp' }, corps = { corp = corp },
		publish = { enabled = true, markup = 1, deadlineS = 100, targets = { { type = 'deliver_item', target = 'drop' } } },
		board = { refreshMs = 100000, size = 1 } } end,
	Place = function() return { bucket = 0, radius = 2, x = 0, y = 0, z = 0 } end,
	Generate = function() return { offer } end,
} }
local posted = 0
local contracts = { Post = function() posted = posted + 1; return { ok = true, value = posted } end }
api.GetPlayer = function() return { PlayerData = { citizenId = 'original', job = { name = 'corp', grade = { level = 1 } } } } end
env.OPX.Api.Get = function(name) return ({ character = api, inventory = bag, accounts = accounts, contracts = contracts })[name] end
env.OPX.Now = function() return 10 end
env.OPX.Math = { Finite = function(n) return n end }
env.OPX.Spots = { ServerReach = function(n) return n end }
env.OPX.JobGate = { Evaluate = function() return true end }
env.OPX.Locale = { Exists = function() return true end, Money = tostring }
env.OPX.NotifyLocale = function() end
env.OPX.Text = { Clean = function(s) return s end }
env.OPX.Cooling = function() return false end
env.Open77.players = { position = function() return { x = 0, y = 0, z = 0, bucket = 0 } end }
assert(loadfile('modules/corpo/server/main.lua', 't', env))()
M.Init()
task = coroutine.create(function() assert(M.Outsource(7, { corp = 'corp', office = 'office', offer = 'offer' })) end)
assert(coroutine.resume(task))
local second, reason = M.Outsource(8, { corp = 'corp', office = 'office', offer = 'offer' })
assert(second == false and reason == 'offer_gone', 'an offer stayed available during funding')
assert(coroutine.resume(task))
assert(posted == 1, 'one offer published two contracts')

-- Detention belongs to the originally named suspect, even if the replacement
-- character is also trespassing in the same enclave when the guard finishes.
local players = { [7] = { PlayerData = { citizenId = 'guard' } }, [8] = { PlayerData = { citizenId = 'replacement' } } }
M.Server.PlayerOf = function(id) return players[id] end
M.Server.RoleOf = function() return { key = 'corp', securityGrade = 1 }, 2, true end
M.Server.PointOf = function() return { x = 0, y = 0, z = 0 } end
local refused = 0
M.Server.Answer = function() refused = refused + 1 end
assert(loadfile('modules/corpo/server/security.lua', 't', env))()
local detained = upvalue(M.Security.Detain, 'onDetained')
local detentions = upvalue(detained, 'detentions')
detentions[7] = { barId = 'bar', suspect = 8, suspectCid = 'original', guardCid = 'guard', corp = 'corp' }
detained(7, { id = 'bar', completed = true })
assert(refused == 1, 'a replacement suspect was not refused before handoff')
print('audit-services: offer claim and detention PASS')

local loaded = { citizenId = 'original', data = {} }
local config = { dirty = { item = 'dirty', mode = 'item' }, dealers = { list = {} }, stores = { list = {} },
	fronts = { byId = { front = { id = 'front', perTxMax = 100, dailyCap = 100, rate = 0.5,
		batchMs = 1000, payout = 'BANK' } } }, launderAmounts = {} }
local ledgerRows, minted, mintBusy = 0, 0, false
M = { Settings = { MINT_CAPS = { corner = 10 } }, Event = {}, Command = { LEDGER = 'ledger', SITES = 'sites', CAPTURE = 'capture' },
	Model = { ID_MAX = 32, ID = '^[%w_]+$', Build = function() return config, {}, {} end,
		Integer = function(n, low, high) return type(n) == 'number' and n >= low and n <= high and n or nil end,
		Bounded = function(_, _, _, fallback) return fallback end,
		Clean = function(n, rate) return math.floor(n * rate) end,
		Gate = function() return true end,
		CapLeft = function(list, _, _, cap)
			local used = 0; for _, entry in ipairs(list) do used = used + entry.amount end
			return cap - used
		end,
	},
	Storage = { SCHEMA = {}, COLUMNS = {}, Minted = function() return minted end, DepositedToday = function() coroutine.yield(); return 0 end,
		Ledger = function() ledgerRows = ledgerRows + 1 end,
		CitizenOf = function(id) return id end,
		LedgerOf = function() coroutine.yield(); return {}, 0 end,
	},
	Op = { Atomic = function(op)
		if mintBusy then return { ok = false, error = 'busy' } end
		mintBusy = true
		coroutine.yield()
		minted, ledgerRows, mintBusy = minted + op.mintPlan.amount, ledgerRows + 1, false
		return { ok = true }
	end, Character = function() return loaded end, Snapshot = function() return {} end,
		Standing = function() return nil end, Init = function() end,
		Begin = function(_, spec) return false, spec.check({}, false) or 'no_bar' end,
	},
}
env.OPX.Schema = { Add = function() end, AddColumns = function() end }
env.OPX.Text = { Bytes = function(value) return value end }
env.OPX.Publish = function() end
env.TriggerClientEvent = function() end
assert(loadfile('modules/underworld/server/main.lua', 't', env))()
M.Init()
env.locale = function(key) return key end
local mint = coroutine.create(function() assert(M.Dirty.Mint(7, 'original', 10, 'corner', 'test') == 10) end)
assert(coroutine.resume(mint))
assert(M.Dirty.Mint(7, 'original', 10, 'corner', 'test') == 0,
	'mint cap was still available while its first inventory write yielded')
assert(coroutine.resume(mint))
assert(ledgerRows == 1)

local deposit = coroutine.create(function() M.Launder(7, { front = 'front', amount = 80 }) end)
assert(coroutine.resume(deposit))
assert(M.Launder(8, { front = 'front', amount = 80 }) == false,
	'same citizen could start another daily-cap read while a deposit was pending')
assert(coroutine.resume(deposit))
-- An early Begin refusal releases the deposit lock for a later request.
deposit = coroutine.create(function() M.Launder(7, { front = 'front', amount = 80 }) end)
assert(coroutine.resume(deposit) and coroutine.status(deposit) == 'suspended')
assert(coroutine.resume(deposit))

local registered = {}
env.OPX.Command = { Register = function(name, _, fn) registered[name] = fn end }
env.locale = function(key) return key end
upvalue(M.Start, 'registerCommands')()
local session, user, grant = {}, 'staff', true
env.OPX.Sessions = { [7] = session }
env.OPX.UserIdOf = function() return user end
env.Open77.acl = { isAllowed = function() return grant end }
local replies = 0
env.OPX.CommandResult = function() replies = replies + 1 end
env.CreateThread = function(fn) task = coroutine.create(fn) end
registered.ledger(7, { 'original' })
assert(coroutine.resume(task))
user = 'replacement'
assert(coroutine.resume(task))
assert(replies == 0, 'ledger reached a recycled player id')
user = 'staff'
registered.ledger(7, { 'original' })
assert(coroutine.resume(task))
grant = false
assert(coroutine.resume(task))
assert(replies == 0, 'ledger survived staff ACL revocation')
print('audit-services: mint cap, deposit lock and ledger PASS')

-- One atomic peer request keeps its original citizens across source changes.
local identities = { [7] = { citizenId = 'seller', data = {} }, [8] = { citizenId = 'buyer', data = {} } }
local moves = {}
bag.RemoveItem = function() error('split peer debit remains') end
bag.AddItem = function() error('split peer credit remains') end
bag.AtomicPeerTrade = function(seller, buyer, moneyType, price, changes)
	assert(moneyType == 'BANK' and price == 10 and #changes == 1 and changes[1].name == 'drug')
	moves[#moves + 1], moves[#moves + 2] = seller, buyer
	coroutine.yield()
	return { ok = true }
end
M.Storage.NewEconomicId = function() return { ok = true, value = 'peer-fixed-id' } end
api.RemoveMoney = function(target) moves[#moves + 1] = target; return true end
api.AddMoney = function(target) moves[#moves + 1] = target; return true end
M.Built = { street = { currency = 'clean', alert = {} }, dirty = { cleanType = 'BANK' } }
M.Op.Character = function(id) return identities[id] end
M.Op.Point = function() return nil end
M.Answer = function() error('a changed audience was answered') end
assert(loadfile('modules/underworld/server/drugs.lua', 't', env))()
local deals = upvalue(M.Drugs.Complete, 'deals')
deals.swap = { seller = 7, buyer = 8, sellerCitizen = 'seller', buyerCitizen = 'buyer', item = 'drug', count = 1, price = 10 }
task = coroutine.create(function() assert(M.Drugs.Complete('swap')) end)
assert(coroutine.resume(task))
identities[7], identities[8] = { citizenId = 'newSeller', data = {} }, { citizenId = 'newBuyer', data = {} }
while coroutine.status(task) ~= 'dead' do assert(coroutine.resume(task)) end
assert(table.concat(moves, ',') == 'seller,buyer', 'street settlement moved replacement characters assets')
print('audit-services: street settlement PASS')
