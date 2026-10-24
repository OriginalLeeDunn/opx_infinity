--- Bearer notes and the wallet move in one durable SQL transaction.
-- @author dop42
-- A staged bag is never published or marked dirty. Its post-state is written
-- with the wallet receipt, then installed in memory. Neither a failed query nor
-- a crash can persist only one half; ambiguous replies are never refunded.
local M = OPX.Modules.Get('inventory')
local Common, Options, Catalog = M.Common, M.Options, M.Catalog
local Containers, Players, Actions = M.Containers, M.Players, M.Actions
M.Currency = {}
local Currency = M.Currency
local wired = false
local RUN_MS = 1000
local function characterApi() return M.Contracts.character end

function Currency.Wired()
	if not wired then return false, nil, nil end
	return true, Options.CURRENCY_ITEM, Options.CURRENCY_MONEY_TYPE
end

function Currency.CountIn(container)
	if not wired then return 0 end
	return Containers.CountIn(container, Options.CURRENCY_ITEM, nil)
end

local function convert(source, bag, amount, action, slot)
	local character = characterApi()
	local player = character.GetPlayer(source)
	if not player or player.PlayerData.citizenId ~= bag.owner then return false, 'unavailable' end
	local direction = action == 'remove' and 'withdraw' or 'deposit'
	local answer = M.Economy.Trade(player, Options.CURRENCY_MONEY_TYPE,
		action == 'remove' and -amount or amount,
		{ { name = Options.CURRENCY_ITEM, count = action == 'remove' and amount or -amount,
			slot = slot, held = true } }, 'inventory:' .. direction, nil, function(op)
			op.publish = function()
				OPX.Audit.Log({ event = 'money.' .. direction,
					message = ('%d %s converted'):format(amount, Options.CURRENCY_MONEY_TYPE),
					data = { amount = amount, item = Options.CURRENCY_ITEM, opId = op.id },
					source = source, citizenId = bag.owner })
				if Players.Citizen(source) == bag.owner then
					OPX.NotifyLocale(source, action == 'remove' and 'inventory.notify.withdrew' or 'inventory.notify.deposited',
						{ amount = OPX.Locale.Money(amount, Options.CURRENCY_MONEY_TYPE) }, 'success')
				end
			end
			return function() return {} end
		end)
	if not answer.ok then return false, answer.error or 'failed' end
	return true
end

--- Debits the wallet and mints notes together. Yields.
function Currency.Withdraw(source, amount)
	if not wired or not characterApi() then return false, 'unavailable' end
	amount = Common.Integer(amount, 1, Options.CURRENCY_MAX_WITHDRAW)
	if not amount then return false, 'bad_count' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end
	local bag, reason = Players.Bag(source)
	if not bag then return false, reason end
	local balance = characterApi().GetMoney(source, Options.CURRENCY_MONEY_TYPE)
	if type(balance) ~= 'number' or balance < amount then return false, 'not_enough_money' end
	local room, why = Containers.CanCarry(bag, Options.CURRENCY_ITEM, amount)
	if not room then return false, why end
	return convert(source, bag, amount, 'remove')
end

--- Burns the exact stack and credits the wallet together. Yields.
function Currency.Deposit(source, slot, count)
	if not wired or not characterApi() then return false, 'unavailable' end
	slot = Common.Integer(slot, 1, 65535)
	if not slot then return false, 'bad_request' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end
	local bag, reason = Players.Bag(source)
	if not bag then return false, reason end
	local entry = bag.items[slot]
	if not entry or entry.name ~= Options.CURRENCY_ITEM then return false, 'empty_slot' end
	count = count == nil and entry.count or Common.Integer(count, 1, entry.count)
	if not count then return false, 'bad_count' end
	return convert(source, bag, count, 'add', slot)
end

--- The catalogue key answering a refusal code, or the generic one.
local function errorKey(code)
	return Common.ErrorKey(code, 'inventory.error.')
end

local AMOUNT = { name = 'amount', help = 'inventory.command.param.amount' }

--- Checks the configuration, wires the use handler and registers the command.
-- Called from `Start`, after the contracts are resolved.
-- @author dop42
function Currency.Register()
	if not Options.CURRENCY_ENABLED then
		Open77.log.info('[inventory] no currency item is wired: money cannot be carried or ' ..
			'handed over as an item')
		return
	end

	-- THE CHECK `shared/common.lua` COULD NOT MAKE. It runs before the catalogue
	-- is built, so the item name it accepted is only a well-formed name. An item
	-- name nothing carries would make every withdraw answer `unknown_item` AFTER
	-- the balance had been debited -- the refund would carry it, but the honest
	-- answer is not to wire the bridge at all.
	local item = Options.CURRENCY_ITEM
	if not Catalog.Get(item) then
		Open77.log.warn(('[inventory] CURRENCY.ITEM %q is not in the catalogue: money cannot ' ..
			'be carried or handed over as an item'):format(tostring(item)))
		return
	end

	if not characterApi() or type(characterApi().AtomicMoney) ~= 'function' then
		Open77.log.warn('[inventory] no character contract: there is no balance to draw a note ' ..
			'against, so money cannot be carried as an item')
		return
	end

	wired = true

	-- The deposit, reached from the Use row the screen draws for the stack.
	-- `consume = 0`: the durable conversion already consumed this stack.
	Actions.RegisterUsable(item, function(source, info)
		local ok, why = Currency.Deposit(source, info.slot, info.count)
		if not ok then return { ok = false, error = why } end
		return { ok = true, consume = 0 }
	end, 'inventory.currency')

	OPX.Command.Register('opx.withdraw', {
		help = 'inventory.command.help.withdraw',
		params = { AMOUNT },
		cooldownMs = RUN_MS,
	}, function(source, args, raw)
		if source <= 0 then
			return OPX.CommandNotice(source, raw, 'warning',
				locale('inventory.command.error.in_game_only'))
		end
		-- A thread of its own: loading a bag reaches the database, and a command
		-- handler is not resumed after it yields.
		CreateThread(function()
			local amount = Common.TypedInteger(args[1], 1, Options.CURRENCY_MAX_WITHDRAW)
			if not amount then
				return OPX.CommandNotice(source, raw, 'warning',
					locale('inventory.command.error.bad_amount',
						{ max = Options.CURRENCY_MAX_WITHDRAW }))
			end

			local ok, why = Currency.Withdraw(source, amount)
			if ok then
				-- `toasted`: `Withdraw` has just toasted its own sentence, and the
				-- command's answer on top of it was the same news twice.
				return OPX.CommandNotice(source, raw, 'success',
					locale('inventory.command.done.withdrew',
						{ amount = OPX.Locale.Money(amount, Options.CURRENCY_MONEY_TYPE) }), true)
			end
			-- Two vocabularies answer here: this module's refusal codes and the
			-- character module's own locale keys (`money.insufficient`). A key
			-- that already resolves is used as it stands; anything else is a
			-- code and is prefixed.
			local key = (type(why) == 'string' and OPX.Locale.Exists(why)) and why or errorKey(why)
			-- One parameter table covers every code either vocabulary answers --
			-- `money.insufficient` names the currency and the rest name nothing --
			-- and a spare parameter is ignored. The same shape `opx.money` uses.
			OPX.CommandNotice(source, raw, 'error',
				locale(key, { type = Options.CURRENCY_MONEY_TYPE }))
		end)
	end)

	Open77.log.info(('[inventory] money is carried as %s, drawn against %s, up to %d a withdraw')
		:format(item, Options.CURRENCY_MONEY_TYPE, Options.CURRENCY_MAX_WITHDRAW))
end
