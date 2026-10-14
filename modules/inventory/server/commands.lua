--- The staff commands, their answers and their audit lines.
-- @author dop42
--
-- Every command is registered restricted through `OPX.Command.Register`: the host
-- resolves `command.<name>` against the ACL BEFORE the handler runs, and no
-- handler checks a permission itself. Hiding a suggestion is not a check, and the
-- suggestion list is core's to build.
--
-- A target is a player id, which reaches the bag of the character that connection
-- has loaded, or a citizen id, which also reaches the bag of a character who is
-- offline. A bag borrowed for a command is written and forgotten again afterwards,
-- unless its character came back or somebody opened it meanwhile.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Catalog = M.Catalog
local Containers = M.Containers
local Players = M.Players

M.Commands = {}
local Commands = M.Commands

-- Least milliseconds between two runs of one command by one operator. Shared with
-- nothing: it is a doorway window, and core applies it before the handler runs.
local RUN_MS = 400

-- Rows the holders report asks for. A report is read in a chat box.
local HOLDERS_LIMIT = 20

-- Answer keys about what was TYPED rather than about the world. A second attempt
-- with the right words succeeds, so they are warnings and not errors.
local TYPED = {
	['inventory.command.error.unknown_item'] = true,
	['inventory.command.error.bad_count'] = true,
	['inventory.command.error.bad_target'] = true,
	['inventory.command.error.not_loaded'] = true,
	['inventory.command.error.no_character'] = true,
	['inventory.command.error.not_enough'] = true,
	['inventory.command.error.self'] = true,
}

--- Answers what a command did, as a toast the client half raises.
local function reply(source, raw, ok, key, params)
	local kind = ok and 'success' or (TYPED[key] and 'warning' or 'error')
	OPX.CommandNotice(source, raw, kind, locale(key, params))
end

--- The catalogue key answering a refusal code, or the generic one.
local function errorKey(code)
	return Common.ErrorKey(code, 'inventory.command.error.')
end

--- Writes one audit line for a staff action.
local function audit(source, event, ok, message, data)
	OPX.Audit.Log({
		event = event,
		severity = ok and 'info' or 'warn',
		message = message,
		data = data,
		source = source > 0 and source or nil,
		citizenId = data and data.citizenId or nil,
	})
end

--- Resolves a typed player id or citizen id to a target.
-- A player id with no character loaded is asked about once more before it is
-- refused: this module may simply not have seen the load event yet.
local function targetOf(token)
	local id = Common.TypedInteger(token, 1, 2147483647)
	if id then
		local citizenId = Players.Citizen(id)
		if not citizenId then
			local _, reason = Players.Attach(id)
			citizenId = Players.Citizen(id)
			if not citizenId then
				return nil, reason == 'storage' and reason or 'not_loaded'
			end
		end
		return { source = id, citizenId = citizenId }, nil
	end
	local citizenId, reason = Players.Identify(token)
	if not citizenId then return nil, reason end
	return { source = Players.SourceOf(citizenId), citizenId = citizenId }, nil
end

--- Loads the target's bag, and says whether this command is the one holding it.
local function bagOf(target)
	if target.source then
		local bag, reason = Players.Bag(target.source)
		return bag, false, reason
	end
	return Players.LoadBag(target.citizenId)
end

--- The typed count: one when omitted, nil when out of range.
local function countArg(args)
	if args[3] == nil then return 1 end
	return Common.TypedInteger(args[3], 1, Options.MAX_COMMAND_COUNT)
end

local TARGET = { name = 'playerId|citizenId', help = 'inventory.command.param.target' }
local ITEM = { name = 'item', help = 'inventory.command.param.item' }
local COUNT = { name = 'count', help = 'inventory.command.param.count', optional = true }

--- Registers every command. Called from `Start`, on a coroutine.
-- Each handler runs on a thread of its own: loading a bag reaches the database,
-- and a command handler is not resumed after it yields.
-- @author dop42
function Commands.Register()
	OPX.Command.Register('opx.inventory.give', {
		restricted = true,
		help = 'inventory.command.help.give',
		params = { TARGET, ITEM, COUNT },
		cooldownMs = RUN_MS,
	}, function(source, args, raw)
		CreateThread(function()
			local item = Catalog.Get(type(args[2]) == 'string' and args[2]:lower() or nil)
			if not item then
				return reply(source, raw, false, 'inventory.command.error.unknown_item',
					{ item = Common.Clean(args[2], 48) or '?' })
			end
			local count = countArg(args)
			if not count then
				return reply(source, raw, false, 'inventory.command.error.bad_count',
					{ max = Options.MAX_COMMAND_COUNT })
			end
			local target, code = targetOf(args[1])
			if not target then return reply(source, raw, false, errorKey(code)) end
			local bag, borrowed, reason = bagOf(target)
			if not bag then return reply(source, raw, false, errorKey(reason)) end

			local added, refusal = Containers.Add(bag, item.name, count)
			audit(source, 'inventory.give', added, ('%dx %s'):format(count, item.name),
				{ citizenId = target.citizenId, target = target.source, item = item.name,
					count = count, error = refusal })
			if borrowed then Players.Settle(bag) end
			if not added then return reply(source, raw, false, errorKey(refusal)) end

			local label = Catalog.Label(item.name)
			-- The receiver hears it from their own bag push ("+2 Water"), as a
			-- player's hand-over does; a server toast as well said it twice.
			-- Notes are the exception: the client's line leaves them out.
			if item.name == Options.CURRENCY_ITEM and Options.CURRENCY_MONEY_TYPE ~= nil
				and target.source and target.source ~= source then
				OPX.NotifyLocale(target.source, 'inventory.notify.receivedMoney',
					{ amount = OPX.Locale.Money(count, Options.CURRENCY_MONEY_TYPE) }, 'info')
			end
			reply(source, raw, true, 'inventory.command.done.given',
				{ count = count, item = label, citizenId = target.citizenId })
		end)
	end)

	OPX.Command.Register('opx.inventory.remove', {
		restricted = true,
		help = 'inventory.command.help.remove',
		params = { TARGET, ITEM, COUNT },
		cooldownMs = RUN_MS,
	}, function(source, args, raw)
		CreateThread(function()
			-- Taken by NAME and not by catalogue entry: an item removed from the
			-- data files is exactly what a staff member needs to be able to take
			-- out of a bag.
			local name = type(args[2]) == 'string' and args[2]:lower() or nil
			if not Common.Word(name, Catalog.NAME_MAX, Catalog.NAME) then
				return reply(source, raw, false, 'inventory.command.error.unknown_item',
					{ item = Common.Clean(args[2], 48) or '?' })
			end
			local count = countArg(args)
			if not count then
				return reply(source, raw, false, 'inventory.command.error.bad_count',
					{ max = Options.MAX_COMMAND_COUNT })
			end
			local target, code = targetOf(args[1])
			if not target then return reply(source, raw, false, errorKey(code)) end
			local bag, borrowed, reason = bagOf(target)
			if not bag then return reply(source, raw, false, errorKey(reason)) end

			local removed, refusal = Containers.Remove(bag, name, count)
			audit(source, 'inventory.remove', removed, ('%dx %s'):format(count, name),
				{ citizenId = target.citizenId, target = target.source, item = name,
					count = count, error = refusal })
			if borrowed then Players.Settle(bag) end
			if not removed then return reply(source, raw, false, errorKey(refusal)) end

			local label = Catalog.Label(name)
			if target.source and target.source ~= source then
				OPX.NotifyLocale(target.source, 'inventory.notify.taken',
					{ count = count, item = label }, 'warning')
			end
			reply(source, raw, true, 'inventory.command.done.removed',
				{ count = count, item = label, citizenId = target.citizenId })
		end)
	end)

	OPX.Command.Register('opx.inventory.clear', {
		restricted = true,
		help = 'inventory.command.help.clear',
		params = { TARGET },
		cooldownMs = RUN_MS,
	}, function(source, args, raw)
		CreateThread(function()
			local target, code = targetOf(args[1])
			if not target then return reply(source, raw, false, errorKey(code)) end
			local bag, borrowed, reason = bagOf(target)
			if not bag then return reply(source, raw, false, errorKey(reason)) end

			local stacks = OPX.Table.Count(bag.items)
			Containers.Clear(bag)
			audit(source, 'inventory.clear', true, ('%d stack(s)'):format(stacks),
				{ citizenId = target.citizenId, target = target.source, stacks = stacks })
			if borrowed then Players.Settle(bag) end

			if target.source and target.source ~= source then
				OPX.NotifyLocale(target.source, 'inventory.notify.cleared', nil, 'warning')
			end
			reply(source, raw, true, 'inventory.command.done.cleared',
				{ stacks = stacks, citizenId = target.citizenId })
		end)
	end)

	OPX.Command.Register('opx.inventory.open', {
		restricted = true,
		help = 'inventory.command.help.open',
		params = { TARGET },
		cooldownMs = RUN_MS,
	}, function(source, args, raw)
		CreateThread(function()
			if source <= 0 then
				return reply(source, raw, false, 'inventory.command.error.in_game_only')
			end
			local target, code = targetOf(args[1])
			if not target then return reply(source, raw, false, errorKey(code)) end
			if target.source == source then
				return reply(source, raw, false, 'inventory.command.error.self')
			end
			if not Players.Bag(source) then
				return reply(source, raw, false, errorKey('not_loaded'))
			end
			local bag, _, reason = bagOf(target)
			if not bag then return reply(source, raw, false, errorKey(reason)) end

			bag.title = locale('inventory.kind.search', { citizenId = target.citizenId })
			-- `staff` true: reach does not close a search, and closing it is what
			-- writes and forgets an offline bag again.
			Containers.View(source, bag, true)
			audit(source, 'inventory.search', true, target.citizenId,
				{ citizenId = target.citizenId, target = target.source })
			TriggerClientEvent(M.Event.OPEN, source)
			reply(source, raw, true, 'inventory.command.done.opened',
				{ citizenId = target.citizenId })
		end)
	end)

	OPX.Command.Register('opx.inventory.holders', {
		restricted = true,
		help = 'inventory.command.help.holders',
		params = { ITEM },
		cooldownMs = RUN_MS,
	}, function(source, args, raw)
		CreateThread(function()
			local name = type(args[1]) == 'string' and args[1]:lower() or nil
			if not Common.Word(name, Catalog.NAME_MAX, Catalog.NAME) then
				return reply(source, raw, false, 'inventory.command.error.unknown_item',
					{ item = Common.Clean(args[1], 48) or '?' })
			end

			local found = M.Storage.Holders(name, HOLDERS_LIMIT)
			if not found.ok then return reply(source, raw, false, errorKey('storage')) end
			local holders = found.value

			local lines = {
				locale('inventory.command.done.holders', { item = name, count = #holders }),
			}
			for index = 1, #holders do
				local row = holders[index]
				lines[#lines + 1] = locale('inventory.command.holder', {
					kind = tostring(row.kind), owner = tostring(row.owner),
					slot = tostring(row.slot), count = tostring(row.count),
				})
			end
			audit(source, 'inventory.holders', true, name, { item = name, found = #holders })
			-- A report is read back rather than acted on, so it goes out on the
			-- result channel, which a chat box draws line by line.
			OPX.CommandResult(source, true, table.concat(lines, '\n'))
		end)
	end)
end
