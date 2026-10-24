--- Atomic item trades: a staged bag, a wallet receipt and optional owned rows.
-- @author dop42
-- Sellers must not save new cash while their sold items are still durable;
-- buyers must not save a debit before their goods. Both are one transaction.
-- Participants supply their SQL only from their own module storage bridge.
local M = OPX.Modules.Get('inventory')
local Common, Containers, Players = M.Common, M.Containers, M.Players
local Result = OPX.Result
M.Economy = {}

local function releaseFor(bag, token)
	return function()
		if bag.economicLock == token then bag.economicLock = nil end
		if bag.unloadWhenClean then CreateThread(function() Containers.Unload(bag.id) end) end
	end
end

--- A trusted server trade; signed money delta, signed item counts. Yields.
-- participant(op, staged) may set extra apply/publish callbacks and returns a
-- build(op) callback for additional SQL and a locked eligibility guard.
function M.Economy.Trade(target, moneyType, delta, changes, reason, opId, participant)
	local character = M.Contracts.character
	if not character or type(character.AtomicMoney) ~= 'function' then return Result.Err('unavailable') end
	local player
	if type(target) == 'table' then player = target
	elseif type(target) == 'string' then player = character.GetPlayerByCitizenId(target)
	else player = character.GetPlayer(target) end
	if not player then return Result.Err('not_loaded') end
	local source, citizenId = player.PlayerData.source, player.PlayerData.citizenId
	local may, why = Players.MayAct(source)
	if not may then return Result.Err(why) end
	if type(changes) ~= 'table' or #changes > 128 then return Result.Err('bad_request') end
	delta = math.tointeger(delta)
	if not delta or delta < -9007199254740991 or delta > 9007199254740991 then return Result.Err('bad_count') end
	local bag, refusal = Players.Bag(source)
	if not bag then return Result.Err(refusal) end
	if bag.owner ~= citizenId or bag.transient then return Result.Err('not_loaded') end
	local involved, locations = { bag }, {}
	for index = 1, #changes do
		local change = changes[index]
		if type(change) ~= 'table' then return Result.Err('bad_request') end
		if change.citizenId ~= nil and change.citizenId ~= citizenId then
			local other = character.GetPlayerByCitizenId(change.citizenId)
			if not other then return Result.Err('not_loaded') end
			local allowed, code = Players.MayAct(other.PlayerData.source)
			if not allowed then return Result.Err(code) end
			local otherBag, code = Players.Bag(other.PlayerData.source)
			if not otherBag or otherBag.owner ~= change.citizenId or otherBag.transient then return Result.Err(code or 'not_loaded') end
			locations[index] = otherBag
			local known = false
			for _, container in ipairs(involved) do if container == otherBag then known = true end end
			if not known then involved[#involved + 1] = otherBag end
		elseif change.vehicleId ~= nil then
			local trunk = M.EconomicTrunk(change.vehicleId, source)
			if not trunk.ok then return trunk end
			locations[index] = trunk.value
			local known = false
			for _, container in ipairs(involved) do if container == trunk.value then known = true end end
			if not known then involved[#involved + 1] = trunk.value end
		else locations[index] = bag end
	end
	local action = delta == 0 and 'touch' or delta > 0 and 'add' or 'remove'
	return character.AtomicMoney(player, moneyType, math.abs(delta), action, reason, opId, function(op)
		for _, container in ipairs(involved) do if container.economicLock then return nil, 'busy' end end
		local token, versions, stagedBags, baselines = {}, {}, {}, {}
		for _, container in ipairs(involved) do container.economicLock = token end
		op.release = function()
			for _, container in ipairs(involved) do releaseFor(container, token)() end
		end
		for _, container in ipairs(involved) do
			local version, blocked = M.Storage.EconomicFence(container, token)
			if version == nil then return nil, blocked end
			versions[container], stagedBags[container], baselines[container] = version, Containers.EconomicClone(container)
		end
		local staged = stagedBags[bag]
		-- Consume first: the cells and weight being sold may make room for what
		-- the transaction buys. No live item changes before SQL commits.
		for _, removing in ipairs({ true, false }) do
			for index = 1, #changes do
				local change = changes[index]
				local staged = stagedBags[locations[index]]
				if type(change) ~= 'table' or type(change.name) ~= 'string' then return nil, 'bad_request' end
				local count = math.tointeger(change.count)
				if not count or count == 0 or math.abs(count) > M.Options.MAX_STACK then return nil, 'bad_count' end
				if (count < 0) == removing then
					local ok, error
					if count > 0 then ok, error = Containers.Add(staged, change.name, count, change.metadata)
					elseif change.slot then
						local slot = Common.Integer(change.slot, 1, 65535)
						local entry = slot and staged.items[slot]
						if not entry or entry.name ~= change.name then return nil, 'empty_slot' end
						if Containers.IsHeld(staged, slot) and not change.held then return nil, 'busy' end
						if change.metadata and not Common.SameMetadata(entry.metadata, change.metadata) then return nil, 'empty_slot' end
						ok, error = Containers.TakeFromSlot(staged, slot, -count)
					else ok, error = Containers.Remove(staged, change.name, -count, change.metadata) end
					if not ok then return nil, error end
				end
			end
		end
		local extraBuild
		if participant then
			extraBuild, refusal = participant(op, staged)
			if not extraBuild then return nil, refusal or 'unavailable' end
		end
		local extraApply, extraPublish = op.apply, op.publish
		op.apply = function()
			for _, container in ipairs(involved) do
				Containers.EconomicApply(container, stagedBags[container], baselines[container])
				M.Storage.EconomicAccepted(container, versions[container])
			end
			if extraApply then extraApply() end
		end
		op.publish = function()
			for _, container in ipairs(involved) do Containers.PublishEconomic(container) end
			if extraPublish then extraPublish() end
		end
		return function(attempt)
			local statements = {}
			for _, container in ipairs(involved) do
				if not container.transient then
					for _, statement in ipairs(M.Storage.MoneyStatements(stagedBags[container], attempt)) do
						statements[#statements + 1] = statement
					end
				end
			end
			local extras, guard
			if extraBuild then extras, guard = extraBuild(attempt) end
			for index = 1, #(extras or {}) do statements[#statements + 1] = extras[index] end
			return statements, guard
		end
	end)
end

--- Trades items between two characters and credits the seller in the same SQL
--- transaction as the buyer's debit. Reverse items pay an item currency instead.
function M.Economy.PeerTrade(sellerId, buyerId, moneyType, price, items, reason, opId)
	local character = M.Contracts.character
	if opId ~= nil and (type(opId) ~= 'string' or #opId > 121 or not opId:match('^[%w_:%-%.]+$')) then
		return Result.Err('money.opIdConflict')
	end
	price = type(price) == 'number' and math.tointeger(price)
	if not price or price < 0 or price > 9007199254740991 or type(items) ~= 'table' or #items > 64 then
		return Result.Err('bad_request')
	end
	local seller = character.GetPlayerByCitizenId(sellerId)
	local buyer = character.GetPlayerByCitizenId(buyerId)
	if not seller or not buyer or seller == buyer then return Result.Err('not_loaded') end
	if type(character.PreparePeerCredit) ~= 'function' then return Result.Err('unavailable') end
	if opId then
		local receipt = character.MoneyReceipt(opId)
		if not receipt.ok then return Result.Err('error.unavailable') end
		if receipt.value then
			local secondary = character.MoneyReceipt(opId .. ':credit')
			if not secondary.ok or not secondary.value then return Result.Err('money.pending') end
			local row = secondary.value
			if row.citizen_id ~= sellerId or row.money_type ~= moneyType or tonumber(row.amount) ~= price
				or row.action ~= (price > 0 and 'add' or 'touch') or row.reason ~= 'peer-credit:' .. opId then
				return Result.Err('money.opIdConflict')
			end
			return character.AtomicMoney(buyer, moneyType, price, price > 0 and 'remove' or 'touch', reason, opId)
		end
	end
	if price > 0 and not OPX.Hooks.Trigger('money:beforeAdd', { player = seller, citizenId = sellerId,
		moneyType = moneyType, amount = price, reason = reason }) then return Result.Err('money.vetoed') end
	local changes = {}
	for _, item in ipairs(items) do
		if type(item) ~= 'table' or type(item.name) ~= 'string' or type(item.count) ~= 'number'
			or not math.tointeger(item.count) or item.count < 1 then return Result.Err('bad_request') end
		local from, into = item.reverse and buyerId or sellerId, item.reverse and sellerId or buyerId
		changes[#changes + 1] = { name = item.name, count = -item.count, metadata = item.metadata, citizenId = from }
		changes[#changes + 1] = { name = item.name, count = item.count, metadata = item.metadata, citizenId = into }
	end
	return M.Economy.Trade(buyer, moneyType, -price, changes, reason, opId, function(op)
		return character.PreparePeerCredit(op, seller)
	end)
end
