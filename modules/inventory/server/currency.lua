--- Eddies you can hand over: the bridge between the balance and one item.
-- @author dop42
--
-- THE MODEL, AND IT IS THE WHOLE OF THIS FILE. The balance in `PlayerData.money`
-- stays the single authority on what anybody is worth. The `eddies` item is a
-- BEARER NOTE drawn against it:
--
--   * a WITHDRAW debits the balance and puts that many units in the bag (mint);
--   * USING the stack destroys it and credits the balance back (burn);
--   * everything in between -- handing it over, putting it in a boot, a stash or
--     a searched bag -- is the inventory module's existing machinery, untouched.
--
-- WHY NOT MAKE THE ITEM THE MONEY. Because every reader of the balance would
-- then have to read a bag instead, and there are eight of them across four
-- modules (shops, dealership, garages, the paycheck, the staff command). The day
-- one of them was missed, a player would pay for a car with money that was
-- sitting in a stash. A bearer note has the opposite property: a note is money
-- that is OUT of circulation, so the worst a missed reader can do is under-count,
-- and nothing can be spent twice.
--
-- WHAT THAT LEAVES TO GET WRONG, and it is the only thing:
--
--   TOTAL MONEY MUST NOT CHANGE. balance + notes held, before an operation,
--   equals balance + notes held after it -- including when the operation fails.
--
-- There is no transaction across a balance and a container: one lives in
-- PlayerData and the other in a container table written back on a timer, and
-- neither half can be rolled back by the other. So each conversion is an ORDERED
-- PAIR, and the order is chosen the same way both times:
--
--   THE STEP THAT CREATES VALUE GOES SECOND.
--
-- Mint first and a refused debit leaves notes nobody paid for -- money minted,
-- repeatably, by whoever finds the refusal. Debit first and a refused mint leaves
-- money owed -- destroyed once, and recoverable, which is what the compensating
-- step in each direction is for. A bridge that can only ever lose is a bridge an
-- operator can settle from the log; one that can gain is an economy nobody can.
--
-- Neither pair yields between its two halves, so nothing interleaves with one:
-- `RemoveMoney`/`AddMoney` publish PlayerData, raise the internal money event and
-- write an audit line, and not one of those reaches the database or waits; the
-- container calls mark a row dirty for a later sweep rather than writing it. The
-- bag is resolved BEFORE the pair, which is where the yield lives.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Catalog = M.Catalog
local Containers = M.Containers
local Players = M.Players
local Actions = M.Actions

M.Currency = {}
local Currency = M.Currency

-- False until `Register` has checked the configuration, the catalogue AND the
-- character contract. Every entry point asks first: half a bridge is where money
-- goes missing, so the answer to any missing piece is to refuse the whole
-- conversion rather than perform the half that works.
local wired = false

-- Least milliseconds between two withdraws by one player. A doorway window and
-- not a security boundary: every withdraw is revalidated whether or not it was
-- waited for.
local RUN_MS = 1000

--- The `character` contract, or nil.
-- Read through a function rather than captured: `Init` runs before any contract
-- is published, and a local taken then would be nil for the life of the resource.
local function characterApi()
	return M.Contracts.character
end

--- Whether the bridge is wired, and the three values it trades on.
-- @author dop42
-- @return boolean
-- @return string|nil the item name
-- @return string|nil the money type
function Currency.Wired()
	if not wired then return false, nil, nil end
	return true, Options.CURRENCY_ITEM, Options.CURRENCY_MONEY_TYPE
end

--- How many units of the currency item a container holds.
-- The count the conservation property is stated over: a player's total is this
-- plus their balance, and no operation may change the sum.
-- @author dop42
-- @param container table|nil
-- @return integer
function Currency.CountIn(container)
	if not wired then return 0 end
	return Containers.CountIn(container, Options.CURRENCY_ITEM, nil)
end

--- Debits the balance and puts that many notes in the bag. Yields.
--
-- @author dop42
-- @param source Source
-- @param amount any
-- @return boolean
-- @return string|nil a refusal code, or a character-module locale key
function Currency.Withdraw(source, amount)
	if not wired then return false, 'unavailable' end
	local character = characterApi()
	if not character then return false, 'unavailable' end

	amount = Common.Integer(amount, 1, Options.CURRENCY_MAX_WITHDRAW)
	if not amount then return false, 'bad_count' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end

	-- YIELDS, AND THAT IS WHY IT IS HERE rather than between the two halves of
	-- the exchange below. A bag that never arrives must cost nothing at all.
	local bag, reason = Players.Bag(source)
	if not bag then return false, reason end

	local item = Options.CURRENCY_ITEM
	local moneyType = Options.CURRENCY_MONEY_TYPE

	-- Read before anything is charged, so the common refusal costs the player
	-- nothing: `RemoveMoney` re-checks and is the check that counts -- this one
	-- is the courtesy, in the shape the dealership already uses.
	local balance = character.GetMoney(source, moneyType)
	if type(balance) ~= 'number' or balance < amount then return false, 'not_enough_money' end

	-- ...and the room, which is NOT a courtesy. This is what makes the insert
	-- below unable to refuse: nothing yields between here and it, so the answer
	-- `Add` gets when it re-asks is the answer read here.
	local room, why = Containers.CanCarry(bag, item, amount)
	if not room then return false, why end

	-- ── the exchange: debit, then mint ───────────────────────────────────────
	local paid, payRefusal = character.RemoveMoney(source, moneyType, amount,
		'inventory:withdraw')
	if not paid then
		-- The character contract answers a catalogue key of its own
		-- (`money.insufficient`, `money.offline`); anything else is a fault here.
		return false, type(payRefusal) == 'string' and payRefusal or 'failed'
	end

	-- GUARDED, BECAUSE A THROW HERE WOULD UNWIND PAST THE REFUND and out of the
	-- caller, leaving a player charged for notes they never got and no line
	-- anywhere saying how much. `Add` reaches the weapons half and the pile
	-- sweeper through `commit`, and neither is this file's to promise cannot
	-- raise. The dealership learned this with `vehicles.Register`.
	local answered, added, addRefusal = pcall(Containers.Add, bag, item, amount)
	if not answered then
		Open77.log.error(('[inventory] the mint of %d %s threw for %s: %s')
			:format(amount, item, tostring(source), tostring(added)))
		added, addRefusal = false, 'failed'
	end

	if added then
		OPX.Audit.Log({
			event = 'money.withdraw',
			message = ('%d %s withdrawn as %s'):format(amount, moneyType, item),
			data = { moneyType = moneyType, amount = amount, item = item,
				citizenId = Players.Citizen(source) },
			source = source,
			citizenId = Players.Citizen(source),
		})
		-- AS MONEY, in the language's own format: it read "You drew 1000000x
		-- Eddies.", with no grouping and no currency, beside a HUD that groups.
		OPX.NotifyLocale(source, 'inventory.notify.withdrew',
			{ amount = OPX.Locale.Money(amount, moneyType) }, 'success')
		return true, nil
	end

	-- THE HALF THAT CAN BE UNDONE. Nothing was handed over, so the money goes
	-- back, and the refund is the reliable half because the debit just ran: the
	-- same player, still loaded, still this coroutine, and `AddMoney` refuses
	-- only for the reasons `RemoveMoney` has just not refused for. A refund that
	-- fails anyway is the one outcome that costs a player money, and it is said
	-- in the log with everything needed to settle it by hand.
	local back, backWhy = character.AddMoney(source, moneyType, amount,
		'inventory:withdraw:refund')
	if not back then
		Open77.log.error(
			('[inventory] %s was debited %d %s for a withdraw that could not be minted (%s); ' ..
				'the refund ALSO failed (%s) -- settle this by hand')
				:format(tostring(Players.Citizen(source) or source), amount, moneyType,
					tostring(addRefusal), tostring(backWhy)))
	else
		Open77.log.warn(('[inventory] %s could not be minted for %s (%s); %d %s refunded')
			:format(item, tostring(Players.Citizen(source) or source), tostring(addRefusal),
				amount, moneyType))
	end
	return false, addRefusal or 'failed'
end

--- Destroys notes in one bag slot and credits the balance. Yields.
--
-- Takes the units out ITSELF rather than answering a `consume` for `Actions.Use`
-- to perform, and that is not a style choice: that consume runs AFTER the handler
-- has returned, so a consume that refused there would leave the balance credited
-- and the stack still in the bag -- money minted, once per failure, by anybody
-- who can make the consume fail.
--
-- @author dop42
-- @param source Source
-- @param slot any
-- @param count any nil deposits the whole stack
-- @return boolean
-- @return string|nil
function Currency.Deposit(source, slot, count)
	if not wired then return false, 'unavailable' end
	local character = characterApi()
	if not character then return false, 'unavailable' end

	slot = Common.Integer(slot, 1, 65535)
	if not slot then return false, 'bad_request' end
	local may, refusal = Players.MayAct(source)
	if not may then return false, refusal end

	local bag, reason = Players.Bag(source)
	if not bag then return false, reason end

	local item = Options.CURRENCY_ITEM
	local moneyType = Options.CURRENCY_MONEY_TYPE

	-- The slot is re-read here and the NAME is checked again. `Actions.Use` has
	-- already done both, but this is also a public entry point, and a handler
	-- that trusted its caller's word about which item it was holding would credit
	-- eddies for a bandage.
	local entry = bag.items[slot]
	if not entry or entry.name ~= item then return false, 'empty_slot' end
	count = count == nil and entry.count or Common.Integer(count, 1, entry.count)
	if not count then return false, 'bad_count' end

	-- ── the exchange: burn, then credit ──────────────────────────────────────
	-- The notes go first for the same reason the debit goes first in `Withdraw`:
	-- the step that creates value goes second. Credit first and a removal that
	-- refused would leave the balance up and the stack still in the bag.
	local taken, takeRefusal = Containers.TakeFromSlot(bag, slot, count)
	if not taken then return false, takeRefusal or 'failed' end

	local answered, credited, creditRefusal =
		pcall(character.AddMoney, source, moneyType, count, 'inventory:deposit')
	if not answered then
		Open77.log.error(('[inventory] the deposit of %d %s threw for %s: %s')
			:format(count, item, tostring(source), tostring(credited)))
		credited, creditRefusal = false, 'failed'
	end

	if credited then
		OPX.Audit.Log({
			event = 'money.deposit',
			message = ('%d %s deposited as %s'):format(count, item, moneyType),
			data = { moneyType = moneyType, amount = count, item = item,
				citizenId = Players.Citizen(source) },
			source = source,
			citizenId = Players.Citizen(source),
		})
		-- "Banked" was wrong as well as unformatted: the notes go back to the
		-- balance they were drawn from, which this server calls cash, not bank.
		OPX.NotifyLocale(source, 'inventory.notify.deposited',
			{ amount = OPX.Locale.Money(count, moneyType) }, 'success')
		return true, nil
	end

	-- THE PUT-BACK, AND IT IS THE RELIABLE HALF BY CONSTRUCTION. These units came
	-- out of this bag one call ago, the item weighs nothing, and the slot they
	-- left is either still theirs or now free -- so there is room for them by
	-- arithmetic rather than by hope. It is still guarded and still logged,
	-- because "cannot happen" is how the balance of a player who was never told
	-- goes missing.
	local restoreAnswered, restored = pcall(Containers.Add, bag, item, count)
	if not restoreAnswered or restored ~= true then
		Open77.log.error(
			('[inventory] %d %s was taken from %s for a deposit that could not be credited ' ..
				'(%s), and putting it back ALSO failed -- settle this by hand')
				:format(count, item, tostring(Players.Citizen(source) or source),
					tostring(creditRefusal)))
	else
		Open77.log.warn(('[inventory] %s could not be credited for %s (%s); %d %s put back')
			:format(moneyType, tostring(Players.Citizen(source) or source),
				tostring(creditRefusal), count, item))
	end
	return false, type(creditRefusal) == 'string' and creditRefusal or 'failed'
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

	if not characterApi() then
		Open77.log.warn('[inventory] no character contract: there is no balance to draw a note ' ..
			'against, so money cannot be carried as an item')
		return
	end

	wired = true

	-- The deposit, reached from the Use row the screen draws for the stack.
	-- `consume = 0` because the units are already gone: `Deposit` removed them
	-- itself, before it credited anything. See its comment for why.
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
