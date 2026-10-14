--- The forms that ask for a value a menu row cannot hold.
-- @author dop42
--
-- Every form ends in a command line, and the dangerous ones end in a
-- CONFIRMATION screen rather than in the command: a ban typed into a field is one
-- keystroke from happening, and the confirm step is what makes it two.
--
-- The job, gang and money lists are read from `OPX.Config`, which is operator
-- data every script already carries, and not from the `character` contract: its
-- client half publishes what the local player IS, and never the catalogue of what
-- anybody could be. A missing section costs that one form and nothing else.

local M = OPX.Modules.Get('admin')

local Client = M.Client
local Text = OPX.Text
local Command = M.Command

M.Forms = {}
local Forms = M.Forms

-- Patterns a typed decimal and a typed whole number must match.
local NUMBER = '^%-?%d+%.?%d*$'
local INTEGER = '^%-?%d+$'

-- The open form's handle while one is up.
local handle

-- The menu module, read when called: it loads after this file.
local function menu()
	return M.Menu
end

-- One text field with its label and its extra properties.
local function text(id, labelKey, extra)
	local field = { id = id, label = locale(labelKey) }
	for key, value in pairs(extra or {}) do field[key] = value end
	return field
end

-- The LINKS table, or an empty one.
local function links()
	return M.Section('LINKS')
end

-- Options from a configured group table, sorted by label.
local function groupOptions(key)
	local character = OPX.Config.MODULES.character
	local groups = type(character) == 'table' and character[key] or nil
	if type(groups) ~= 'table' then return nil end
	local options = {}
	for name, group in pairs(groups) do
		options[#options + 1] = { label = ('%s (%s)'):format(tostring(group.label or name), name),
			value = name }
	end
	table.sort(options, function(left, right) return left.label < right.label end)
	return options
end

-- Every form by kind: how it is built and what it runs.
local FORMS = {}

FORMS.health = {
	build = function()
		return { title = locale('admin.form.health'), fields = {
			{ id = 'points', label = locale('admin.field.points'),
				slider = { min = 0, max = 100, step = 5, value = 100 } },
		} }
	end,
	submit = function(values, arg)
		local points = math.floor(Text.Finite(values.points) or 0)
		menu().Run({ Command.PLAYER_HEALTH, tostring(arg), ('%d'):format(points) })
	end,
}

FORMS.armor = {
	build = function()
		return { title = locale('admin.form.armor'), fields = {
			text('points', 'admin.field.points', { value = '100', charset = 'digits', maxLength = 5,
				required = true }),
		} }
	end,
	submit = function(values, arg)
		menu().Run({ Command.PLAYER_ARMOR, tostring(arg), values.points })
	end,
}

-- A job or gang form: the configured groups, and a typed grade.
local function groupForm(key, titleKey, linkName)
	return {
		build = function()
			local options = groupOptions(key)
			if options == nil or #options == 0 then return nil end
			return { title = locale(titleKey), fields = {
				{ id = 'group', label = locale('admin.field.group'), options = options },
				text('grade', 'admin.field.grade', { value = '0', charset = 'digits', maxLength = 2,
					required = true }),
			} }
		end,
		submit = function(values, arg)
			local link = links()[linkName]
			if type(link) ~= 'string' then return end
			menu().Run({ link, tostring(arg), values.group, values.grade })
		end,
	}
end

FORMS.job = groupForm('JOBS', 'admin.form.job', 'JOB')
FORMS.gang = groupForm('GANGS', 'admin.form.gang', 'GANG')

-- The account list a money form offers, and the two fields it asks for.
-- SHARED BY BOTH MONEY FORMS and not copied by the second one: a type the server
-- is not configured to have, or an amount field one of them let run longer than
-- the other, is a form that offers an answer that will be refused.
local function moneyOptions()
	local money = OPX.Config.SHARED.MONEY
	local types = type(money) == 'table' and money.TYPES or nil
	if type(types) ~= 'table' then return nil end
	local options = {}
	for name in pairs(types) do options[#options + 1] = name end
	table.sort(options)
	if #options == 0 then return nil end
	return options
end

local function moneyFields(options)
	return {
		{ id = 'type', label = locale('admin.field.moneyType'), options = options },
		text('amount', 'admin.field.amount', { pattern = INTEGER, maxLength = 10,
			required = true }),
	}
end

FORMS.money = {
	build = function()
		local options = moneyOptions()
		if options == nil then return nil end
		return { title = locale('admin.form.money'), description = locale('admin.form.moneyHint'),
			fields = moneyFields(options) }
	end,
	submit = function(values, arg)
		local link = links().MONEY
		if type(link) ~= 'string' then return end
		menu().Run({ link, tostring(arg), values.type, values.amount })
	end,
}

-- THE RECOVERY FORM. The same two answers as the money form above and one
-- difference: it ends in this module's own command, which is the one that takes
-- `me` -- so the row that says "give myself" needs no player id from the client,
-- and a grant can be given for handing money out without the whole character
-- screen coming with it. The target is named in the description, because the
-- row that opened this is gone by the time it is read.
FORMS.recoveryMoney = {
	build = function(arg)
		local options = moneyOptions()
		if options == nil then return nil end
		local mine = arg == nil or arg == 'me'
		return {
			title = locale(mine and 'admin.form.recoverySelf' or 'admin.form.recoveryPlayer'),
			description = mine and locale('admin.form.recoveryHintSelf')
				or locale('admin.form.recoveryHint', { id = tostring(arg) }),
			fields = moneyFields(options),
		}
	end,
	submit = function(values, arg)
		-- `arg` is the target the row carried and never a field the operator typed:
		-- the server resolves `me` from the connection, so a stale id here is
		-- refused rather than silently paying the wrong character.
		menu().Run({ Command.RECOVERY_MONEY, tostring(arg), values.type, values.amount })
	end,
}

-- A count form for giving or removing items of a picked row.
local function countForm(titleKey, commandName, refresh)
	return {
		build = function(arg)
			if type(arg) ~= 'table' or type(arg.n) ~= 'string' then return nil end
			local held = Text.Integer(arg.c)
			local label = tostring(arg.l or arg.n)
			return { title = locale(titleKey),
				description = held and locale('admin.form.itemHeld', { label = label, count = held })
					or label,
				fields = {
					text('count', 'admin.field.count', { value = '1', charset = 'digits', maxLength = 6,
						required = true }),
				} }
		end,
		submit = function(values, arg)
			menu().Run({ commandName, tostring(arg.t), arg.n, values.count }, refresh)
		end,
	}
end

FORMS.itemGive = countForm('admin.form.itemGive', Command.INVENTORY_GIVE)
FORMS.itemRemove = countForm('admin.form.itemRemove', Command.INVENTORY_REMOVE, 'bag')
FORMS.ammoGive = countForm('admin.form.ammoGive', Command.WEAPON_GIVEAMMO)

-- RENAMING A CHARACTER. A player names theirs once and cannot change it, which
-- is the rule and is kept; this is the other door, and the reason one has to
-- exist -- a slur, or a typo the player cannot fix because their own door shut
-- behind them.
--
-- `charset = 'name'` is the form module's own closed set, the same one the entry
-- form asks the player for: staff get a bigger door, not a different alphabet. A
-- name only staff could have written is a name every other reader of the column
-- still has to cope with. The server validates both halves again whatever
-- arrives here, so this is the courtesy and not the check.
--
-- It does NOT go through a confirmation: a rename is visible, reversible by
-- another rename, and loses nothing. The delete beside it in the menu does, and
-- is a `guarded` row rather than a form.
FORMS.charRename = {
	build = function(arg)
		if type(arg) ~= 'string' or arg == '' then return nil end
		return {
			title = locale('admin.form.charRename'),
			description = locale('admin.form.charRenameHint', { citizenId = arg }),
			fields = {
				text('firstName', 'admin.field.firstName',
					{ charset = 'name', maxLength = 24, required = true }),
				text('lastName', 'admin.field.lastName',
					{ charset = 'name', maxLength = 24, required = true }),
			},
		}
	end,
	submit = function(values, arg)
		-- Not `roster`: what changed is a row in the list the screen behind this
		-- form is drawing, and the roster's own copy of the name follows on its next
		-- pass anyway. WHICH list is the menu's to say -- the same character page
		-- hangs under an account's characters and under the find, and a form that
		-- named one outright refreshed the wrong one half the time.
		menu().Run({ Command.CHARACTER_RENAME, tostring(arg), values.firstName, values.lastName },
			menu().ListOf(tostring(arg)))
	end,
}

FORMS.kick = {
	build = function()
		return { title = locale('admin.form.kick'), fields = {
			text('reason', 'admin.field.reason', { maxLength = 120 }),
		} }
	end,
	submit = function(values, arg)
		local tokens = { Command.MODERATE_KICK, tostring(arg) }
		if M.Trimmed(values.reason, 120) then tokens[3] = values.reason end
		menu().Confirm(tokens, 'admin.confirm.kick', nil, nil, locale('admin.menu.kick'))
	end,
}

FORMS.ban = {
	build = function()
		local options = {}
		local configured = M.Settings.BAN_DURATIONS
		for _, word in ipairs(type(configured) == 'table' and configured or {}) do
			options[#options + 1] = tostring(word)
		end
		if #options == 0 then options[1] = 'perm' end
		return { title = locale('admin.form.ban'), fields = {
			{ id = 'duration', label = locale('admin.field.duration'), options = options },
			text('reason', 'admin.field.reason', { maxLength = 120 }),
		} }
	end,
	submit = function(values, arg)
		local tokens = { Command.MODERATE_BAN, tostring(arg), values.duration }
		if M.Trimmed(values.reason, 120) then tokens[4] = values.reason end
		menu().Confirm(tokens, 'admin.confirm.ban', nil, nil, locale('admin.menu.ban'))
	end,
}

FORMS.announce = {
	build = function()
		local maximum = math.floor(M.Bounded('ANNOUNCE.MAX_CHARACTERS',
			M.Section('ANNOUNCE').MAX_CHARACTERS, 1, 512, 240))
		return { title = locale('admin.form.announce'), fields = {
			text('message', 'admin.field.message', { maxLength = maximum, required = true }),
		} }
	end,
	submit = function(values)
		menu().Confirm({ Command.WORLD_ANNOUNCE, values.message }, 'admin.confirm.announce', nil, nil,
			locale('admin.menu.announce'))
	end,
}

FORMS.coords = {
	build = function()
		return { title = locale('admin.form.coords'), fields = {
			text('x', 'admin.field.x', { pattern = NUMBER, maxLength = 12, required = true }),
			text('y', 'admin.field.y', { pattern = NUMBER, maxLength = 12, required = true }),
			text('z', 'admin.field.z', { pattern = NUMBER, maxLength = 12, required = true }),
			text('heading', 'admin.field.heading', { pattern = NUMBER, maxLength = 8 }),
		} }
	end,
	submit = function(values, arg)
		local tokens = { Command.PLAYER_TP, tostring(arg or 'me'), values.x, values.y, values.z }
		if Text.Finite(values.heading) then tokens[6] = values.heading end
		menu().Run(tokens)
	end,
}

FORMS.location = {
	build = function()
		return { title = locale('admin.form.location'), fields = {
			text('name', 'admin.field.locationName', { pattern = '^[%w_%-]+$', maxLength = 32,
				required = true }),
			text('label', 'admin.field.label', { maxLength = 48 }),
		} }
	end,
	submit = function(values)
		local tokens = { Command.WORLD_LOC_ADD, values.name }
		if M.Trimmed(values.label, 48) then tokens[3] = values.label end
		menu().Run(tokens, 'locations')
	end,
}

-- THE SEARCH BOX THE STRIP CANNOT HAVE.
--
-- The menu reads six keys and no letters, so the one place an operator can type
-- a word is here. The form asks for nothing else and runs no command: it hands
-- the word back to the screen that opened it, which filters itself and redraws.
-- Submitting it empty is how a filter is cleared without a second row.
--
-- `arg` is the query already in force, so reopening the box shows what is in it
-- rather than a blank field over a filtered list.
FORMS.search = {
	build = function(arg)
		return { title = locale('admin.form.search'),
			description = locale('admin.form.searchHint'), fields = {
				text('query', 'admin.field.query',
					{ value = type(arg) == 'string' and arg ~= '' and arg or nil, maxLength = 48 }),
			} }
	end,
	submit = function(values)
		menu().Filter(values.query)
	end,
}

FORMS.time = {
	build = function()
		return { title = locale('admin.form.time'), fields = {
			text('time', 'admin.field.time', { pattern = '^%d%d?:%d%d$', maxLength = 5,
				value = '12:00', required = true }),
		} }
	end,
	submit = function(values)
		local link = links().TIME
		if type(link) ~= 'string' then return end
		menu().Run({ link, values.time })
	end,
}

-- ── the Dev forms are gone, and so is the screen that opened them ───────────
--
-- THE OWNER'S WORDS, 2026-09-21: "il y a pas de config live c'est tous par les
-- fichier config donc degage moi ce menu est pass moi tous dans les config".
-- The Dev screen read as a place a server is CONFIGURED from, and this server is
-- not configured from a menu: every place in it is a line in `config/`.
--
-- Four forms stood here and all four went with it:
--
--   `previewPlace` / `previewRemove` ended in a CONTRACT CALL on the
--   dealership's client half rather than in a command line, which was the one
--   place this file broke its own rule. They wrote a showroom car into
--   `opx77_dealership_previews` -- a place nobody has a copy of, which is the
--   exact thing `/opx.dealership.add` was deleted for. A showroom car is
--   declared in `PREVIEW.POINTS` in `config/dealership.lua` now, and the server
--   prints every database-only one at boot as the config line that recreates it.
--
--   `garageBring`, `dealerBuy` and the two list rows beside them were not
--   configuration at all -- they are the commands `opx.garages.bring`,
--   `opx.dealership.buy`, `.list` and `.stock`, which are still registered and
--   still ACL-gated. An operator types them, which is what the form was typing
--   for them.
--
-- `MAX_KEY`, `MAX_PLATE`, `keyField`, `with`, `dealership` and `reported` were
-- read by those six and nothing else, so they went with them. If a Dev-shaped
-- form ever comes back, it comes back around a COMMAND: a contract call from a
-- client is no permission check at all.

-- Turns one answer into its command, or brings the menu back.
local function onAnswer(payload)
	if type(payload) ~= 'table' then return end
	if payload.handle ~= nil and handle ~= nil and payload.handle ~= handle then return end
	handle = nil
	local data = type(payload.data) == 'table' and payload.data or {}
	local form = FORMS[data.form]
	if payload.action ~= 'submit' or form == nil or type(payload.values) ~= 'table' then
		return menu().Resume()
	end
	form.submit(payload.values, data.arg)
end

--- Takes the menu down and puts one form up.
-- @author dop42
-- @param kind string
-- @param arg any
-- @return boolean
function Forms.Open(kind, arg)
	local form = FORMS[kind]
	if form == nil then return false end
	local contract = Client.Contract('form')
	if contract == nil then
		menu().Status(locale('admin.client.formMissing'), false)
		return false
	end

	-- Built before the menu is taken down, so a form that cannot be built costs
	-- the operator nothing.
	local spec = form.build(arg)
	if spec == nil then
		menu().Status(locale('admin.client.formUnavailable'), false)
		return false
	end
	spec.owner = M.OWNER
	spec.id = 'admin.' .. kind
	spec.data = { form = kind, arg = arg }
	spec.on = onAnswer

	menu().Suspend()
	local opened = contract.Open(spec)
	if not opened.ok then
		Open77.log.warn(('[admin] form %s did not open: %s'):format(kind, tostring(opened.error)))
		menu().Resume(locale('admin.client.formUnavailable'), false)
		return false
	end
	handle = opened.value.handle
	return true
end

--- Whether a form of this module is up.
-- @author dop42
-- @return boolean
function Forms.IsOpen()
	return handle ~= nil
end

--- Takes the open form down, if there is one.
-- @author dop42
function Forms.Close()
	if handle == nil then return end
	local closing = handle
	handle = nil
	local contract = Client.Contract('form')
	if contract ~= nil then contract.Close(closing) end
end
