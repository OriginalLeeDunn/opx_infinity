--- The player commands and their answers.
-- @author dop42
--
-- Every command acts on its caller alone, so all four ship open; an operator who
-- wants one behind the ACL sets `RESTRICTED = true` and the host resolves
-- `command.<NAME>` before the handler runs. Two entries under one name would
-- bind a single ACL key, and the loser's RESTRICTED flag with it, so the second
-- is refused and logged.
--
-- Only the list is a report someone wants to re-read, and it stays a chat line.
-- Everything else is a toast: a typing mistake is answered where the player is
-- looking.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common
local Opt = M.Opt
local Service = M.Service

M.Commands = {}

-- Chat suggestion text and parameter help keys per command entry.
local HELP = {
	ANIM = { text = 'animations.help.anim', params = {
		{ name = 'name', help = 'animations.help.name', optional = true },
		{ name = 'variant', help = 'animations.help.variant', optional = true },
	} },
	STOP = { text = 'animations.help.stop', params = {} },
	LIST = { text = 'animations.help.list', params = {} },
}
HELP.EMOTE = HELP.ANIM

-- Refusal codes a typed command answers with its own text, followed by the
-- command that lists the names. Every other refusal is the toast the picker
-- shows.
local TYPED = {
	unknown_animation = 'animations.error.unknownAnimation',
	invalid_variant = 'animations.error.invalidVariant',
}

-- Commands actually registered, for the boot line and the duplicate check.
local registered = {}

-- `args.n` is authoritative: `#args` would read 1 for a single nil.
local function count(args)
	if type(args) ~= 'table' then return 0 end
	local given = Common.Integer(tonumber(args.n), 0, 32)
	if given == nil then return #args end
	return given
end

-- Answers a typing mistake with a warning toast on the player's client.
local function notice(player, raw, message)
	OPX.CommandNotice(player, raw, 'warning', message)
end

-- Answers a hint naming the LIST command, when it exists.
local function listHint()
	local name = Opt.ListCommand()
	return name and locale('animations.hint.list', { command = name }) or nil
end

-- Stops the player on the server and asks their client to release the playback
-- the client itself started, which this VM cannot do for it.
local function stop(player)
	local result = Service.Stop(player, false)
	Service.Answer(player, 0, 'stop', result)
	if result.error == 'animation_locked' then return end
	TriggerClientEvent(M.Event.CANCEL, player)
end

-- Sends the player the offered animations, by category, as a chat report.
local function list(player)
	if OPX.Cooling(player, 'animations.list', 2000) then return end
	local lines = { locale('animations.list.header') }
	local entries = Catalogue.Entries()
	-- One pass, grouped by category: a hundred-odd entries walked once per
	-- category would be twelve walks for one chat line.
	local byCategory = {}
	for position = 1, #entries do
		local entry, variants = Service.Offered(entries[position].name)
		if entry ~= nil then
			local names = byCategory[entry.category] or {}
			byCategory[entry.category] = names
			local offered = OPX.Table.Count(variants)
			names[#names + 1] = offered > 1 and ('%s (%d)'):format(entry.name, offered) or entry.name
		end
	end
	for index = 1, #Catalogue.CATEGORIES do
		local category = Catalogue.CATEGORIES[index]
		local names = byCategory[category] or {}
		if #names > 0 then
			lines[#lines + 1] = locale('animations.list.row', {
				category = locale('animations.category.' .. category),
				names = table.concat(names, ', '),
			})
		end
	end
	if #lines == 1 then lines[1] = locale('animations.list.empty') end
	OPX.CommandResult(player, true, table.concat(lines, '\n'))
end

-- Handles a name and variant, a category, stop, list, accept, decline, with or
-- nothing. `stop` and `list` are words before they are names, so the
-- platform's `stop` gesture is reached from the picker only.
local function anim(source, args, raw)
	local player = tonumber(source) or 0
	if player <= 0 then
		Open77.log.warn('[animations] animations are played by a player, not the console')
		return
	end

	local given = count(args)
	if given == 0 then
		if OPX.Cooling(player, 'animations.picker', 1000) then return end
		TriggerClientEvent(M.Event.PICKER, player, '')
		return
	end

	local first = tostring(args[1]):lower()
	if given == 1 and first == 'stop' then return stop(player) end
	if given == 1 and first == 'list' then return list(player) end
	-- The answer to an invitation from a nearby player, for whoever cannot or
	-- will not use the menu it opens.
	if given == 1 and (first == 'accept' or first == 'decline') then
		if not M.Duo.Answer(player, first == 'accept') then
			return notice(player, raw, locale('animations.duo.none'))
		end
		return
	end
	-- An emote with the nearest player: `with <kind|shortcut|profile> [profile]`.
	if first == 'with' then
		if given < 2 or given > 3 then return notice(player, raw, locale('animations.usage')) end
		local spec = M.Duo.Spec(tostring(args[2]):lower(),
			given == 3 and tostring(args[3]):lower() or nil)
		local result = M.Duo.Request(player, spec)
		if result.error == 'unknown_animation' then
			local hint = listHint()
			return notice(player, raw, locale('animations.duo.unknown') .. (hint and (' ' .. hint) or ''))
		end
		M.Duo.Tell(player, result)
		return
	end
	-- An offered animation wins over a category of the same word. None shares
	-- a name today (that is why the platform's `dance` and `seated` families
	-- are `music` and `sitting` here), but a profile a later build adds might.
	if given == 1 and Service.Offered(first) == nil and Catalogue.IsCategory(first) then
		if OPX.Cooling(player, 'animations.picker', 1000) then return end
		TriggerClientEvent(M.Event.PICKER, player, first)
		return
	end
	if given > 2 then return notice(player, raw, locale('animations.usage')) end

	local result = Service.Play(player, first, args[2], nil)
	local typed = TYPED[result.error or '']
	if typed ~= nil then
		local hint = listHint()
		return notice(player, raw, locale(typed) .. (hint and (' ' .. hint) or ''))
	end
	-- A success has no line: the body that moves is the answer.
	Service.Answer(player, 0, 'play', result)
end

-- Registers one configured command, or logs why it does not exist.
local function register(key, handler)
	local entry = Opt.COMMANDS[key]
	local name = type(entry) == 'table' and entry.NAME or nil
	if type(name) ~= 'string' or name == '' then
		Open77.log.info(('[animations] command %s is off (COMMANDS.%s.NAME)'):format(key, key))
		return
	end
	local restricted = entry.RESTRICTED == true

	for index = 1, #registered do
		if registered[index].name == name then
			Open77.log.error(('[animations] command %s is declared twice (COMMANDS.%s and ' ..
				'COMMANDS.%s); %s is NOT registered'):format(name, registered[index].key, key, key))
			return
		end
	end

	-- Core renders a command's own help at send time but passes its parameters
	-- through as written, so the parameter help is resolved here.
	local help = HELP[key]
	local params = {}
	for index = 1, help and #help.params or 0 do
		local parameter = help.params[index]
		params[index] = {
			name = parameter.name,
			help = parameter.help and locale(parameter.help) or nil,
			optional = parameter.optional == true or nil,
		}
	end

	OPX.Command.Register(name, {
		restricted = restricted,
		help = help and help.text or nil,
		params = params,
	}, handler)
	registered[#registered + 1] = { key = key, name = name, restricted = restricted }
end

--- Registers every configured command and logs which ones exist.
-- @author dop42
function M.Commands.Register()
	register('ANIM', anim)
	register('EMOTE', anim)

	register('STOP', function(source, args, raw)
		local player = tonumber(source) or 0
		if player <= 0 then
			Open77.log.warn('[animations] animations are stopped by a player, not the console')
			return
		end
		if count(args) ~= 0 then return notice(player, raw, locale('animations.usage.none')) end
		stop(player)
	end)

	register('LIST', function(source, args, raw)
		local player = tonumber(source) or 0
		-- The console form is the operator's: English, every resolved variant.
		if player <= 0 then
			local entries = Catalogue.Entries()
			for index = 1, #entries do
				local entry, variants = Service.Offered(entries[index].name)
				if entry ~= nil then
					local numbers = {}
					for position = 1, #entry.clips do
						if variants[position] then numbers[#numbers + 1] = tostring(position) end
					end
					Open77.log.info(('  %-10s %-12s variants %s'):format(entry.name, entry.category,
						table.concat(numbers, ',')))
				end
			end
			return
		end
		if count(args) ~= 0 then return notice(player, raw, locale('animations.usage.none')) end
		list(player)
	end)

	local names = {}
	for index = 1, #registered do
		local command = registered[index]
		names[index] = command.name .. (command.restricted and ' [acl]' or ' [open]')
	end
	Open77.log.info(('[animations] commands: %s'):format(
		#names > 0 and table.concat(names, ', ') or 'none'))
end
