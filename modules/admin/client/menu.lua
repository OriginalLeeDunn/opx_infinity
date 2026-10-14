--- The staff menu: its screens, its navigation stack, and the menu key.
-- @author dop42
--
-- EVERY ROW IS A HINT. A row is greyed when the access map says the ACL would
-- refuse the command it ends in, and that is all the greying does: selecting it
-- would still send the line, and the host would still refuse it. Nothing here
-- decides anything.
--
-- ONE SCREEN AT A TIME, and not the whole tree in one spec. The `menu` contract
-- takes nested submenus, which is the right shape for a small static tree; this
-- one has 271 vehicles behind ten classes and every list arrives from the server
-- after the menu is already open. So each screen is a FLAT item list, this file
-- keeps the stack, and `Open` pushes while `Update` redraws in place. A whole
-- tree would also not fit: the contract bounds a spec at 400 nodes.

local M = OPX.Modules.Get('admin')

local Client = M.Client
local Catalog = M.Catalog
local Peds = M.Peds
local Forms = M.Forms
local Keys = M.Keys
local Text = OPX.Text
local Command = M.Command

M.Menu = {}
local Menu = M.Menu

-- ROWS ONE PAGE OF A LIST DRAWS, and every list on this menu is paged.
--
-- The roster, a bag, the saved places, an account's characters and the ammo
-- kinds used to draw up to 190 rows on one screen, and the menu contract checks
-- every row of a spec it is handed -- its id, its text, the size of its data --
-- inside the one resume that hands it over. That is several hundred
-- instructions a row: a full roster or a full bag was tens of thousands in one
-- resume, past the per-resume budget, and the redraw died with the old screen
-- still up. Twenty rows is the catalogues' page, and now everyone's.
local PAGE_ROWS = 20

-- Milliseconds between two looks at whether the down screen should be aside.
local UPKEEP_MS = 250

-- Milliseconds a screen asked for before the opener answered is still wanted.
local LANDING_MS = 5000

-- What the server sent when the menu opened: the access map, whether the ACL
-- could be read at all, and whether the inventory answered.
local session

-- The roster, its index by id, and the chunks still arriving.
local roster, rosterById, rosterIncoming = {}, {}, {}

-- The destination rows, and the chunks still arriving.
local locations, locationsIncoming = {}, {}

-- The item catalogue and the one bag the removal picker draws.
local catalog = { rows = {}, incoming = {}, loaded = false, error = nil }
local bag = { target = nil, rows = {}, incoming = {}, loaded = false, error = nil }

-- The characters of the one account the roster screen is looking into. Same
-- shape as `bag` and for the same reason: it is a per-target list fetched from
-- the server, so it carries the target it was read for and a late answer for
-- somebody else is dropped rather than drawn as theirs.
local chars = { target = nil, rows = {}, incoming = {}, loaded = false, error = nil }

-- THE PEOPLE WHO ARE NOT HERE. The same shape again, and tagged for the same
-- reason -- but with the QUESTION rather than a player id, because this screen
-- has no player: it reads the character table, and what makes a late answer
-- harmless is which question it is answering. `mode`, `term` and `cursor` are
-- the question; `more`, `cursor` and `seenAt` are where the next page starts.
local absent = { tag = nil, rows = {}, incoming = {}, loaded = false, error = nil,
	mode = 'recent', term = nil, cursor = nil, seenAt = nil, more = false }

-- Screen, argument and cursor from the root down.
local stack = {}

-- The open menu's handle, and whether it was taken down to put a form up.
local handle, suspended = nil, false

-- A status line to write when the next screen opens.
local queuedStatus

-- Lists to ask for again once the line that changes them has been ANSWERED, by
-- command name. See `Menu.Run`, which used to sleep 1200ms instead of waiting
-- for the answer it was already being sent.
local pending = {}

-- Bumped by every draw, so a stale open claims nothing.
local drawn = 0

-- The screen, argument and form to land on once the opener answers.
local landing

-- Whether the player is down, and whether this module has the down screen aside.
local playerDown, suspending, suspendReported = false, false, false

-- The scheduler handle for the upkeep pass.
local job

-- ── rows ────────────────────────────────────────────────────────────────────

-- Whether the access map grants a command. True without an ACL reader: a host
-- that cannot say greys nothing, and the host still refuses what it refuses.
local function permitted(name)
	if session == nil or type(name) ~= 'string' or name == '' then return false end
	if not session.aclKnown then return true end
	return session.access[name] == true
end

-- A catalogue key's text, or the words of a text table.
local function text(label)
	if type(label) == 'table' then return tostring(label.text) end
	return locale(label)
end

-- One menu row with its data and extra properties.
local function row(id, label, data, extra)
	local item = { id = id, label = label, data = data }
	for key, value in pairs(extra or {}) do item[key] = value end
	return item
end

-- Puts a glyph on a row built by a helper that takes no `extra`. The menu module
-- refuses a name outside `menu.M.ICONS`, so a typo here is a refused menu rather
-- than a row that quietly loses its picture.
local function icon(item, name)
	item.icon = name
	return item
end

-- Greys a row with a word beside it.
local function unavailable(item, key)
	item.disabled, item.value = true, locale(key or 'admin.menu.unavailable')
	return item
end

-- Greys a row when the access map says the ACL refuses the command it ends in.
local function denied(item, name)
	if not permitted(name) then unavailable(item, 'admin.menu.denied') end
	return item
end

-- The one disabled row a list shows when it has none.
local function empty(key)
	return row('empty', locale(key), nil, { disabled = true, icon = 'info' })
end

-- A row running a command line, greyed when the ACL refuses it.
local function command(id, label, tokens, refresh, extra)
	return denied(row(id, text(label), { run = tokens, refresh = refresh }, extra), tokens[1])
end

-- A command row that goes through a confirmation screen first.
local function guarded(id, labelKey, tokens, confirmKey, refresh, popAfter)
	local item = command(id, labelKey, tokens)
	-- `refresh` and `popAfter` are carried through the confirmation the same way
	-- the tokens are: a row that destroys what the screen under it draws has to
	-- say so HERE, where the caller knows, rather than have the dispatch guess
	-- from the screen's name.
	--
	-- IT IS `popAfter` AND NOT `back`, and that is the whole bug this name fixes.
	-- `back` already means something on a row -- "pressing me pops the screen",
	-- which is what Cancel is -- and `onRow` tests it FIRST, before it ever looks
	-- for a confirmation. A guarded row carrying `back = true` therefore popped on
	-- press and never confirmed and never ran: the delete row did nothing at all,
	-- silently, while looking exactly like a row that had been pressed.
	item.data = { confirm = tokens, key = confirmKey, refresh = refresh, popAfter = popAfter,
		label = item.label }
	return item
end

-- A row opening a form, greyed when the command it ends in is refused.
local function form(id, labelKey, kind, arg, name)
	return denied(row(id, locale(labelKey), { form = kind, arg = arg }), name)
end

-- A row that pushes another screen.
--
-- `submenu = true` IS THE POINT OF THIS HELPER AND NOT A DETAIL. This menu keeps
-- its own stack and opens one flat screen at a time, so nothing it sends the
-- contract has `items` under it and the contract could not derive the affordance
-- itself: every navigation row drew exactly like the rows that fire a command,
-- and the only way to learn that `Players` was a list and `Heal` was not was to
-- press one of them. The flag puts the `>` back in the affordance column, and it
-- rides on THIS function so that a screen added later cannot forget it.
local function go(id, label, screen, arg, extra)
	local item = row(id, text(label), { go = screen, arg = arg }, extra)
	item.submenu = true
	return item
end

-- A row to a picker, greyed when its final command is refused.
local function goFor(id, labelKey, screen, arg, name, extra)
	return denied(go(id, labelKey, screen, arg, extra), name)
end

-- A separator row, with a heading when one is given.
local function section(labelKey)
	return { separator = true, label = labelKey and locale(labelKey) or nil }
end

-- ── the filter ──────────────────────────────────────────────────────────────
--
-- WHY A LIST THIS LONG NEEDS ONE. The catalogues behind this menu are 271
-- vehicles under ten classes, every ped family the build ships, and the whole
-- item catalogue -- paged twenty rows at a time. Finding `quadra` in that meant
-- walking fourteen pages with an arrow key, and the operator already knew the
-- word they were looking for.
--
-- WHY IT IS A FORM AND NOT A TEXT FIELD ON THE STRIP. The strip reads six keys
-- and no letters: it is drawn by a page that forwards arrows, Enter and
-- Backspace and nothing else, on purpose, so that a menu can be open while the
-- game still has the keyboard. The one surface in this resource that takes typed
-- text is the form, so the search row opens one, and the answer comes back
-- through `Menu.Filter`.
--
-- WHERE IT APPEARS. Only on a list long enough to be worth searching, or one
-- already filtered -- see `SEARCH_FROM`. A three-player roster with a search box
-- over it is a box in the way.

-- Rows a list must hold before it offers to be searched.
local SEARCH_FROM = 12

-- ROWS BETWEEN TWO YIELDS while a screen is built. A builder walks a whole
-- catalogue -- every item, all 271 vehicles, every ped family -- and the
-- client gives one resume a fixed instruction budget. Even on the redraw's own
-- thread a filtered walk ran past it (`menu.lua: ... budget exceeded` in
-- `drawNow`, in the owner's log after the redraw moved off the callers), and
-- the coroutine died with the menu half-drawn. So the walk yields every
-- `BREATHE_EVERY` rows -- but only on the redraw's own thread, which `draw`
-- names: a builder called anywhere else runs straight, and nothing else here
-- may be paused halfway.
--
-- THE THREAD IS NAMED, NOT FLAGGED. This was one boolean, set while the redraw
-- ran, and a second redraw thread -- the stale take-over in `draw`, after a
-- build that outlived `DRAW_STALE_MS` at a low frame rate -- shared it: the
-- first to finish cleared it and the other walked on without yielding, into
-- the budget. Every thread `draw` started is remembered and yields here; only
-- the newest one -- `drawThread` -- may hand its screen to the contract.
local BREATHE_EVERY = 25
local breaths = 0
local drawThread = nil
-- A plain table, not a weak one: the client sandbox has no `setmetatable`. A
-- thread removes itself when it ends; only one the budget killed stays, and
-- that is one entry per kill.
local drawThreads = {}

-- Whether the code running now is one of the redraw's threads, where a yield is
-- safe and wanted.
local function onDrawThread()
	return drawThreads[coroutine.running()] == true and type(Wait) == 'function'
end

-- Whether a build running now still owns the redraw: run inline (no thread at
-- all), or on the newest drawing thread rather than one taken over since.
local function ownsDraw()
	return not onDrawThread() or coroutine.running() == drawThread
end

-- Declared here so a breath can say the redraw is still alive; `draw` owns it.
local drawingSince = nil

local function breathe()
	breaths = breaths + 1
	if breaths % BREATHE_EVERY ~= 0 then return end
	if onDrawThread() then
		-- A long walk is a live one, not a thread the budget killed.
		drawingSince = Client.NowMs()
		Wait(0)
	end
end

-- Whether a row's words match the query. Case-insensitive, plain substring, and
-- EVERY word of the query has to appear somewhere: `mil tech` finds the
-- Militech rows without the operator having to remember which field the word is
-- in. Plain `find`, never a pattern -- a typed `(` is a character, not syntax.
local function matches(query, ...)
	breathe()
	if query == nil then return true end
	local hay = ''
	for index = 1, select('#', ...) do
		local part = select(index, ...)
		if part ~= nil then hay = hay .. ' ' .. tostring(part):lower() end
	end
	for word in query:lower():gmatch('%S+') do
		if not hay:find(word, 1, true) then return false end
	end
	return true
end

-- The stack entry the screen being built belongs to.
local function building()
	return stack[#stack]
end

-- The query the screen on top of the stack is under, or nil. Read off the stack
-- rather than passed down, because a screen builder is handed its `arg` and
-- nothing else, and the filter belongs to the SCREEN and not to the argument
-- that named it -- going back to a list has to bring its filter back with it.
local function filtering()
	local current = building()
	local typed = current and current.filter
	if type(typed) ~= 'string' or typed == '' then return nil end
	return typed
end

-- The block at the top of a list: the search box, what it is holding, whatever
-- else that list filters by, and the rule under the lot.
--
-- Empty for a short unfiltered list carrying no filters of its own, which is
-- most of them -- so this can be called from EVERY list screen without asking
-- each one whether it is long enough to deserve it.
local function searchRows(shown, total, extras)
	local query = filtering()
	local items = {}
	if query ~= nil or total >= SEARCH_FROM then
		items[1] = row('search', locale('admin.menu.search'), { form = 'search', arg = query },
			{ icon = 'search', value = query, description = locale('admin.menu.searchHint') })
		if query ~= nil then
			items[2] = row('searchClear', locale('admin.menu.searchClear'), { clearFilter = true },
				{ icon = 'minus', value = ('%d/%d'):format(shown, total) })
		end
	end
	for _, item in ipairs(extras or {}) do items[#items + 1] = item end
	if #items == 0 then return items end
	items[#items + 1] = section()
	return items
end

-- The states a roster row can be in, in the order the filter cycles them.
-- `all` is first so the list starts whole.
local STATES = { 'all', 'up', 'down', 'gate', 'loading' }

-- The words beside the state filter, in the same order.
local function stateLabels()
	local labels = {}
	for index, key in ipairs(STATES) do
		labels[index] = key == 'all' and locale('admin.menu.stateAll')
			or locale('admin.state.' .. key)
	end
	return labels
end

-- The state filter: LEFT and RIGHT cycle it where a submenu would have cost a
-- screen. The row carries the key list, so the dispatch can read the chosen
-- LABEL back to the key it stands for without either side holding an index.
local function stateRow(current)
	local labels = stateLabels()
	local selected = 1
	for index, key in ipairs(STATES) do
		if key == current then selected = index end
	end
	return row('state', locale('admin.menu.stateFilter'), { states = true },
		{ icon = 'filter', choices = labels, selected = selected })
end

-- The state key a chosen label stands for, or nil for a word from a stale draw.
local function stateOf(label)
	for index, word in ipairs(stateLabels()) do
		if word == label then return STATES[index] end
	end
	return nil
end

-- A checkbox row whose flip runs the command with `on` or `off`. A row whose
-- state cannot be read stays a plain command row that toggles: a checkbox drawn
-- from a guess is worse than no checkbox.
local function switch(id, labelKey, tokens, on)
	local item = command(id, labelKey, tokens)
	if not item.disabled and type(on) == 'boolean' then
		item.toggle = on
		item.data = { switch = tokens }
	end
	return item
end

-- A checkbox that flips a CLIENT flag, with no command line behind it.
--
-- `switch` above sends a command to the server dispatcher, which is right for
-- anything the server decides. This is for the ones it does not: a preference
-- that changes what this client draws for itself, needs no grant, is audited
-- nowhere, and would be a round trip for nothing. The row carries the NAME of
-- the flip and the menu's own dispatch looks it up; nothing about it reaches the
-- wire.
--
-- `enabled` is the condition the preference is only meaningful under. False
-- greys the row rather than hiding it, which says the option exists and what has
-- to be true for it to do anything.
local function flip(id, labelKey, name, on, enabled, offKey)
	local item = row(id, locale(labelKey), { flip = name })
	if enabled == false then
		unavailable(item, offKey)
	else
		item.toggle = on == true
	end
	return item
end

-- One page of a long list, with a row to the next. Only the rows on the page
-- are built: `build` makes a whole menu row, and a list is filtered down to
-- plain entries first so that a thousand matches cost a thousand comparisons
-- and twenty rows, not a thousand rows.
--
-- THE PAGE IS THE STACK ENTRY'S, not the argument's. It used to be `arg.p`,
-- which only a screen whose argument is a table can carry -- the roster, a bag
-- and the saved places take a bare player id, which is why they were never
-- paged and drew everything instead. The next-page row pushes the same screen
-- with the same argument and the page beside it, so Back is a page back.
local function paged(list, screen, arg, title, build)
	local current = building()
	local pages = math.max(1, math.ceil(#list / PAGE_ROWS))
	local page = math.min(math.max(math.floor(tonumber(current and current.page) or 1), 1), pages)
	local first = (page - 1) * PAGE_ROWS + 1
	local items = {}
	for index = first, math.min(#list, first + PAGE_ROWS - 1) do
		items[#items + 1] = build(list[index])
	end
	if page < pages then
		local more = go('more', 'admin.menu.more', screen, arg,
			{ value = ('%d/%d'):format(page + 1, pages), icon = 'arrow' })
		more.data.page = page + 1
		items[#items + 1] = more
	end
	if pages > 1 then title = ('%s %d/%d'):format(title, page, pages) end
	return title, items
end

-- Whether the server last reported the inventory contract answering.
local function inventoryUp()
	return session ~= nil and session.inventory == true
end

-- Greys a row that is otherwise enabled while the inventory is not answering.
local function offline(item)
	if not item.disabled and not inventoryUp() then unavailable(item) end
	return item
end

-- The one row a picker shows while loading, failed or empty.
local function placeholder(list, emptyKey)
	local key = not list.loaded and 'admin.menu.loading'
		or list.error and 'admin.menu.inventoryError' or emptyKey
	return empty(key)
end

-- Adds every row of a list to the end of another.
local function append(items, more)
	for _, item in ipairs(more) do items[#items + 1] = item end
	return items
end

-- A roster player's name and id, for a title. `name` is the CHARACTER's, with the
-- account behind it as the fallback -- see `World.RosterRow` on the server.
local function nameOf(id)
	local entry = rosterById[id]
	return entry and ('%s [%d]'):format(entry.name, id) or ('[%s]'):format(tostring(id))
end

-- The other two names a roster row carries: the account playing the character,
-- and the character's public id. A disabled row, because it is a fact and not an
-- action, and nil when the row has neither -- a slot with no character loaded has
-- nothing here that the title is not already saying.
local function identityRow(entry)
	if type(entry) ~= 'table' then return nil end
	local user = type(entry.user) == 'string' and entry.user ~= '' and entry.user or nil
	local citizen = type(entry.citizenId) == 'string' and entry.citizenId ~= '' and entry.citizenId
		or nil
	if user == nil and citizen == nil then return nil end
	return row('identity', user or locale('admin.menu.noAccount'), nil,
		{ disabled = true, value = citizen, icon = 'person' })
end

-- A player sub-screen title: Name [id] - Family.
local function playerTitle(id, key)
	return ('%s - %s'):format(nameOf(id), locale(key))
end

-- A picker title, naming the player when the target is not the operator.
local function titleFor(titleKey, target)
	if target == nil or target == 'me' then return locale(titleKey) end
	return ('%s: %s'):format(locale(titleKey), nameOf(tonumber(target) or target))
end

-- The LINKS table.
local function links()
	return M.Section('LINKS')
end

-- The weapon rows for a target.
local function weaponRows(target, giveKey)
	local items = {
		goFor('giveWeapon', giveKey, 'weaponList', { t = target }, Command.WEAPON_GIVE,
			{ icon = 'weapon' }),
		goFor('giveAmmo', 'admin.menu.giveAmmo', 'ammoList', target, Command.WEAPON_GIVEAMMO,
			{ icon = 'ammo' }),
		icon(command('ammo', 'admin.menu.ammo', { Command.WEAPON_AMMO, target }), 'ammo'),
		icon(command('holster', 'admin.menu.holster', { Command.WEAPON_HOLSTER, target }), 'lock'),
		icon(guarded('disarm', 'admin.menu.disarm', { Command.WEAPON_REMOVE, target, 'all' },
			'admin.confirm.disarm'), 'trash'),
		icon(command('loadout', 'admin.menu.loadout', { Command.WEAPON_READ, target }), 'list'),
	}
	-- Holster included: it used to be greyed as unavailable here, because the
	-- inventory contract had no way to put a weapon away. It has one now.
	for _, item in ipairs(items) do offline(item) end
	return items
end

-- The command line that dresses a target in a ped, or takes one off. The self
-- command for the operator's own body and the player one for anybody else, so
-- that a server may grant staff the right to morph themselves and not others.
local function modelTokens(target, name)
	if target == nil or target == 'me' then return { Command.SELF_MODEL, name } end
	return { Command.PLAYER_MODEL, tostring(target), name }
end

-- The row that opens the ped picker, showing the ped already being worn. Greyed
-- on a build with no model API: the server says so in the body states, and the
-- reason is worth reading once rather than on every refused pick.
local function modelRow(target, worn)
	local item = goFor('model', 'admin.menu.model', 'pedFamilies', target,
		modelTokens(target, 'x')[1], { icon = 'person' })
	if worn ~= nil then item.value = Peds.LabelOf(worn) end
	if not item.disabled and not M.Target.HasModels() then
		unavailable(item, 'admin.menu.modelsOff')
	end
	return item
end

-- The bag rows for a target; the open row only for another player.
local function bagRows(target)
	local items = {
		icon(command('invView', 'admin.menu.invView', { Command.INVENTORY_VIEW, target }), 'list'),
	}
	if target ~= 'me' and links().INVENTORY_OPEN then
		items[#items + 1] = icon(command('invOpen', 'admin.menu.invOpen',
			{ links().INVENTORY_OPEN, target }), 'box')
		items[#items].data.closeAfter = true
	end
	items[#items + 1] = goFor('invGive', 'admin.menu.invGive', 'itemCategories',
		{ t = target, m = 'give' }, Command.INVENTORY_GIVE, { icon = 'plus' })
	items[#items + 1] = goFor('invRemove', 'admin.menu.invRemove', 'bag', target,
		Command.INVENTORY_REMOVE, { icon = 'minus' })
	items[#items + 1] = icon(guarded('invClear', 'admin.menu.invClear',
		{ Command.INVENTORY_CLEAR, target }, 'admin.confirm.invClear'), 'trash')
	for _, item in ipairs(items) do offline(item) end
	return items
end

-- ── the screens ─────────────────────────────────────────────────────────────

-- THE LEVELS, on Myself and on a player's page: the skill tree's lever
-- (`/opx.skills.level`), whose `max` also maxes the base game's own levels on
-- that player's machine, and on Myself the ripperdoc's chrome override. Each
-- row is there only while its LINKS name is, and greyed when the ACL refuses it.
local function levelRows(target)
	local link = links()
	local rows = {}
	if link.SKILLS_LEVEL then
		local max, reset = { link.SKILLS_LEVEL, 'max' }, { link.SKILLS_LEVEL, 'reset' }
		if target ~= 'me' then
			max[#max + 1], reset[#reset + 1] = target, target
		end
		rows[#rows + 1] = icon(command('levelsMax', 'admin.menu.levelsMax', max, nil,
			{ value = locale('admin.menu.levelsMaxValue') }), 'star')
		rows[#rows + 1] = icon(guarded('levelsReset', 'admin.menu.levelsReset', reset,
			target == 'me' and 'admin.confirm.levelsReset' or 'admin.confirm.levelsResetPlayer'), 'refresh')
	end
	if target == 'me' and link.CHROME then
		rows[#rows + 1] = icon(command('chromeFull', 'admin.menu.chromeFull', { link.CHROME, 'full' }),
			'tool')
	end
	if #rows > 0 then table.insert(rows, 1, section('admin.menu.section.levels')) end
	return rows
end

local SCREENS = {}

-- EVERY ROW CARRIES A GLYPH NOW, and the note that used to stand here said the
-- opposite: that the root was "the one screen a glyph earns", because a list of
-- players or vehicles would be the same icon fourteen times. That was true of
-- the fourteen glyphs the set then had -- `tool` stood for the noclip switch,
-- the weather presets, the ped families and the vehicle flags at once, so half
-- the menu was one picture. The set is wider now (see `menu.M.ICONS`) and the
-- rule is the plain one: a row says what KIND of thing it is, and a list of one
-- kind repeats its glyph on purpose, which is how the eye finds where that list
-- ends. Names outside the set are REFUSED by the menu module, not dropped.
SCREENS.root = function()
	return locale('admin.menu.title'), {
		section('admin.menu.section.quick'),
		icon(switch('noclip', 'admin.menu.noclip', { Command.SELF_NOCLIP }, Client.IsNoclip()), 'bolt'),
		section('admin.menu.section.manage'),
		go('players', 'admin.menu.players', 'players', nil,
			{ value = tostring(#roster), icon = 'person' }),
		-- Beside `Players` and not under it, because it is the same question asked
		-- of the other set: that row is everybody the server is holding, and this
		-- one is everybody it is not. Greyed rather than hidden when the ACL
		-- refuses the find, so an operator can see that the door exists.
		goFor('offline', 'admin.menu.offlinePlayers', 'offlineChars', nil,
			Command.CHARACTER_FIND, { icon = 'clock' }),
		go('self', 'admin.menu.self', 'self', nil, { icon = 'star' }),
		go('vehicles', 'admin.menu.vehicles', 'vehicles', nil, { icon = 'vehicle' }),
		go('world', 'admin.menu.world', 'world', nil, { icon = 'world' }),
		go('server', 'admin.menu.server', 'server', nil, { icon = 'server' }),
		-- RECOVERY SITS ON ITS OWN, under everything that acts on a body. What it
		-- reaches is a balance, which is the one thing in this panel that outlives
		-- the session and the character it belonged to.
		section('admin.menu.section.recovery'),
		goFor('recovery', 'admin.menu.recovery', 'recovery', nil, Command.RECOVERY_MONEY,
			{ icon = 'money' }),
		-- THE TOOLS, AND THEY ARE ALL READS. See the screen's own header for why a
		-- screen by this name is allowed to exist again: the one that was removed
		-- wrote, and this one asks.
		go('dev', 'admin.menu.dev', 'dev', nil, { icon = 'info' }),
	}
end

SCREENS.players = function()
	local query = filtering()
	local current = building()
	local state = (current and current.state) or 'all'

	-- Filtered before anything is drawn, so the count beside the clear row is the
	-- count of what the operator is actually looking at. The state word is part of
	-- the haystack as well as its own filter: typing `down` finds the same rows
	-- the state filter would, which is the answer to a search box that silently
	-- ignores the word somebody typed into it.
	--
	-- The roster is read through a local: the walk yields on the redraw's
	-- thread, and a ROSTER answer landing in that gap replaces the module's list
	-- -- possibly with a shorter one, which an index into the upvalue would then
	-- run off the end of.
	local list = roster
	local matched = {}
	for index = 1, #list do
		local entry = list[index]
		local word = locale('admin.state.' .. entry.state)
		if (state == 'all' or entry.state == state)
			and matches(query, entry.id, entry.name, entry.user, entry.citizenId, word) then
			matched[#matched + 1] = entry
		end
	end

	local extras = {}
	if #list >= SEARCH_FROM or state ~= 'all' then extras[1] = stateRow(state) end
	local title, listed = paged(matched, 'players', nil, locale('admin.menu.players'), function(entry)
		local value = locale('admin.state.' .. entry.state)
		if entry.bucket ~= 0 then
			value = value .. ' ' .. locale('admin.menu.bucket', { bucket = entry.bucket })
		end
		if entry.distance then value = value .. ' ' .. entry.distance .. 'm' end
		return go('player_' .. entry.id,
			{ text = ('[%d] %s'):format(entry.id, entry.name) }, 'player', entry.id,
			{ value = value, icon = entry.state == 'down' and 'heal' or 'person' })
	end)
	local items = append(searchRows(#matched, #list, extras), listed)
	if #matched == 0 then
		items[#items + 1] = empty(#list > 0 and 'admin.menu.noMatch' or 'admin.menu.nobody')
	end
	return title, items
end

SCREENS.player = function(id)
	local target = tostring(id)
	local entry = rosterById[id]
	local items = {}

	-- Above the first separator on purpose: the title carries the character and the
	-- slot, and this is who is actually holding the keyboard.
	local identity = identityRow(entry)
	if identity then items[#items + 1] = identity end

	append(items, {
		section('admin.menu.section.quick'),
		icon(command('goto', 'admin.menu.goto', { Command.PLAYER_GOTO, target }), 'location'),
		icon(command('bring', 'admin.menu.bring', { Command.PLAYER_BRING, target }, 'roster'),
			'arrow'),
		icon(command('heal', 'admin.menu.heal', { Command.PLAYER_HEAL, target }, 'roster'), 'heal'),
		icon(command('revive', 'admin.menu.revive', { Command.PLAYER_REVIVE, target }, 'roster',
			entry and entry.state == 'down' and { value = locale('admin.state.down') } or nil),
			'heart'),

		section('admin.menu.section.actions'),
		go('move', 'admin.menu.movement', 'playerMove', id, { icon = 'map' }),
		go('health', 'admin.menu.healthActions', 'playerHealth', id, { icon = 'heal' }),
		-- Beside the ped picker, because they are the same question one layer
		-- apart: that one changes the body, this one changes what is on it.
		icon(command('wardrobe', 'admin.menu.wardrobe', { Command.PLAYER_WARDROBE, target },
			'roster'), 'person'),
		modelRow(target, M.Target.ModelOf(id)),
	})
	local link = links()
	if link.WHERE or link.JOB or link.GANG or link.MONEY then
		items[#items + 1] = go('character', 'admin.menu.character', 'playerCharacter', id,
			{ icon = 'tag' })
	end
	-- THE ACCOUNT'S CHARACTERS, which is a different question from the row above
	-- it: that one acts on the character being PLAYED -- its job, its gang, its
	-- money -- and this one lists every character the person owns, played or not.
	-- Greyed rather than hidden when the ACL refuses the listing, so an operator
	-- can see that the door exists and is not theirs.
	items[#items + 1] = goFor('characters', 'admin.menu.charList', 'playerCharacters', id,
		Command.CHARACTER_LIST, { icon = 'folder' })
	items[#items + 1] = go('items', 'admin.menu.items', 'playerItems', id, { icon = 'weapon' })
	if inventoryUp() then
		items[#items + 1] = go('inventory', 'admin.menu.inventory', 'playerInventory', id,
			{ icon = 'box' })
	end

	append(items, levelRows(target))

	items[#items + 1] = section('admin.menu.section.moderation')
	items[#items + 1] = icon(form('kick', 'admin.menu.kick', 'kick', id, Command.MODERATE_KICK),
		'door')
	items[#items + 1] = icon(form('ban', 'admin.menu.ban', 'ban', id, Command.MODERATE_BAN), 'ban')
	return nameOf(id), items
end

SCREENS.playerMove = function(id)
	local target = tostring(id)
	return playerTitle(id, 'admin.menu.movement'), {
		icon(command('goto', 'admin.menu.goto', { Command.PLAYER_GOTO, target }), 'location'),
		icon(command('bring', 'admin.menu.bring', { Command.PLAYER_BRING, target }, 'roster'),
			'arrow'),
		go('send', 'admin.menu.send', 'locations', id, { icon = 'map' }),
		icon(form('coords', 'admin.menu.coords', 'coords', id, Command.PLAYER_TP), 'location'),
		icon(command('observe', 'admin.menu.observe', { Command.PLAYER_OBSERVE, target }), 'eye'),
	}
end

SCREENS.playerHealth = function(id)
	local target = tostring(id)
	return playerTitle(id, 'admin.menu.healthActions'), {
		icon(command('heal', 'admin.menu.heal', { Command.PLAYER_HEAL, target }, 'roster'), 'heal'),
		icon(command('revive', 'admin.menu.revive', { Command.PLAYER_REVIVE, target }, 'roster'),
			'heart'),
		icon(switch('god', 'admin.menu.god', { Command.PLAYER_GOD, target }, Client.GodMode(id)),
			'shield'),
		icon(switch('freeze', 'admin.menu.freeze', { Command.PLAYER_FREEZE, target },
			M.Target.IsFrozen(id)), 'lock'),
		icon(form('health', 'admin.menu.health', 'health', id, Command.PLAYER_HEALTH), 'heal'),
		icon(form('armor', 'admin.menu.armor', 'armor', id, Command.PLAYER_ARMOR), 'shield'),
		section('admin.menu.section.danger'),
		icon(guarded('kill', 'admin.menu.kill', { Command.PLAYER_KILL, target },
			'admin.confirm.kill'), 'warning'),
	}
end

SCREENS.playerCharacter = function(id)
	local target = tostring(id)
	local link = links()
	local items = {}
	if link.WHERE then
		items[#items + 1] = icon(command('record', 'admin.menu.record', { link.WHERE, target }),
			'info')
	end
	if link.JOB then
		items[#items + 1] = icon(form('job', 'admin.menu.job', 'job', id, link.JOB), 'tag')
	end
	if link.GANG then
		items[#items + 1] = icon(form('gang', 'admin.menu.gang', 'gang', id, link.GANG), 'flag')
	end
	if link.MONEY then
		items[#items + 1] = icon(form('money', 'admin.menu.money', 'money', id, link.MONEY), 'money')
	end
	if #items == 0 then items[1] = empty('admin.menu.catalogEmpty') end
	return playerTitle(id, 'admin.menu.character'), items
end

-- ── an account's characters ─────────────────────────────────────────────────
-- EVERY CHARACTER THE PERSON OWNS, played or not, which is a different question
-- from the screen above: that one acts on the body in the world and dies with
-- the connection, these are the rows behind it and outlive it. The list is
-- served by the server against the ACL and arrives tagged with the player it was
-- read for, so this draws nothing until the tag matches the screen's own target.

--- One character out of a list the server sent, and which list it came from.
--
-- TWO STORES AND ONE PAGE. `SCREENS.character` is reached two ways now -- down
-- from an account's list, and out of the find screen -- and it is deliberately
-- the SAME screen both times: the readouts, the rename and the delete are the
-- same three things about the same row, and a second copy of them would be a
-- second copy to keep in step. What differs is only which list the page has to
-- ask for again afterwards, so that is what this answers alongside the row.
-- @return table|nil the row
-- @return string|nil the refresh topic the list it came from is served by
local function characterRow(citizenId)
	for _, entry in ipairs(chars.rows) do
		if entry.citizenId == citizenId then return entry, 'characters' end
	end
	for _, entry in ipairs(absent.rows) do
		if entry.citizenId == citizenId then return entry, 'found' end
	end
	return nil, nil
end

--- A character's display name, or the word for one that was never named.
local function characterName(entry)
	if entry == nil or entry.firstName == nil then return locale('admin.menu.charUnnamed') end
	return ('%s %s'):format(entry.firstName, entry.lastName or '')
end

SCREENS.playerCharacters = function(id)
	local query = filtering()
	local held, rows = 0, {}
	if chars.target == tostring(id) then
		for _, entry in ipairs(chars.rows) do
			held = held + 1
			if matches(query, characterName(entry), entry.citizenId, entry.job, entry.gang) then
				rows[#rows + 1] = entry
			end
		end
	end
	local title, listed = paged(rows, 'playerCharacters', id, titleFor('admin.menu.charList', id),
		function(entry)
			local item = go('char_' .. entry.citizenId, { text = characterName(entry) }, 'character',
				entry.citizenId, { icon = entry.live and 'star' or 'person' })
			-- `live` is the one being played right now and `active` the one the
			-- ACCOUNT is locked on. They are usually the same and are not while a
			-- switch is in flight, so the value says which claim is being made.
			item.value = entry.live and locale('admin.menu.charLive')
				or (entry.active and locale('admin.menu.charActive'))
				or entry.gender or nil
			-- The citizen id is what every command here takes, so it is on the
			-- row rather than a level in; the date is what tells two unnamed
			-- characters apart.
			item.description = entry.createdAt
				and ('%s  %s'):format(entry.citizenId, entry.createdAt) or entry.citizenId
			return item
		end)
	local items = append(searchRows(#rows, held), listed)
	if #rows == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(chars.target == tostring(id) and chars or { loaded = false },
				'admin.menu.charNone')
	end
	return title, items
end

SCREENS.character = function(citizenId)
	local entry, from = characterRow(citizenId)
	local items = {}

	-- WHAT THE ROW IS, as readouts and not as controls: a readout is a line of
	-- type and takes no frame. None of it is editable and that is the point --
	-- the dates are a RECORD of what happened, and a date this menu could rewrite
	-- is an audit trail nobody can trust. There is no birth date in this schema;
	-- lifepath, origin and date of birth were dropped from it.
	append(items, {
		row('id', locale('admin.menu.charId'), nil,
			{ value = tostring(citizenId), disabled = true, icon = 'info' }),
		row('name', locale('admin.menu.charName'), nil,
			{ value = characterName(entry), disabled = true, icon = 'person' }),
	})
	if entry ~= nil and entry.gender then
		items[#items + 1] = row('body', locale('admin.menu.charBody'), nil,
			{ value = entry.gender, disabled = true, icon = 'person' })
	end
	if entry ~= nil and entry.job then
		items[#items + 1] = row('job', locale('admin.menu.charJob'), nil,
			{ value = entry.job, disabled = true, icon = 'tag' })
	end
	if entry ~= nil and entry.gang then
		items[#items + 1] = row('gang', locale('admin.menu.charGang'), nil,
			{ value = entry.gang, disabled = true, icon = 'flag' })
	end
	if entry ~= nil and entry.createdAt then
		items[#items + 1] = row('created', locale('admin.menu.charCreated'), nil,
			{ value = entry.createdAt, disabled = true, icon = 'clock' })
	end
	if entry ~= nil and entry.lastLoggedOut then
		items[#items + 1] = row('seen', locale('admin.menu.charSeen'), nil,
			{ value = entry.lastLoggedOut, disabled = true, icon = 'clock' })
	end
	-- ONLY THE FIND CARRIES THESE, and the account row is why a find is worth
	-- having: a row reached from the roster already knows whose it is -- the
	-- screen above it is that player -- and one reached by searching the table
	-- does not, so the account and the slot holding it are said here or nowhere.
	if entry ~= nil and entry.account then
		items[#items + 1] = row('account', locale('admin.menu.charAccount'), nil,
			{ value = entry.account, disabled = true, icon = 'person' })
	end
	-- A NUMBER AND NOT A FLAG, and the test is `type` rather than truthiness for a
	-- reason that would otherwise be a crash: the per-account list carries `live`
	-- as a BOOLEAN -- down there the player is the screen above and there is
	-- nothing to name -- and formatting `true` with `%d` raises inside the builder,
	-- which loses the whole screen rather than one row.
	local slot = type(entry) == 'table'
		and (type(entry.live) == 'number' and entry.live
			or type(entry.online) == 'number' and entry.online)
		or nil
	if slot then
		items[#items + 1] = row('here', locale('admin.menu.charHere'), nil,
			{ value = ('[%d] %s'):format(slot, locale(type(entry.live) == 'number'
				and 'admin.menu.charLive' or 'admin.menu.charOnline')),
				disabled = true, icon = 'star' })
	end

	-- THE ONE EDITABLE THING. Job, gang and money are the modules that own them,
	-- reachable a screen away on the character being played; the name is the only
	-- part of a character's identity this module writes, and it is here because a
	-- player may only write it once and cannot fix a typo afterwards.
	items[#items + 1] = section('admin.menu.section.actions')
	items[#items + 1] = icon(form('rename', 'admin.menu.charRename', 'charRename', citizenId,
		Command.CHARACTER_RENAME), 'tool')

	items[#items + 1] = section('admin.menu.section.danger')
	-- `back` because this page is about to be about nothing, and the list it came
	-- from because that list has one row fewer. Which list is `from`: the same
	-- page hangs under an account's characters and under the find, and refreshing
	-- the one the operator is not standing on would leave the stale one under them.
	items[#items + 1] = icon(guarded('delete', 'admin.menu.charDelete',
		{ Command.CHARACTER_DELETE, tostring(citizenId) }, 'admin.confirm.charDelete',
		from, true), 'trash')

	return ('%s: %s'):format(locale('admin.menu.charList'), characterName(entry)), items
end

-- ── the people who are not here ─────────────────────────────────────────────
-- WHAT THIS SCREEN IS HONEST ABOUT. It lists CHARACTER ROWS out of the database
-- and not sessions, because a session is the one thing an offline player does
-- not have. Nothing is hidden: a row whose character is being played right now
-- says so, because a directory that silently dropped the people who happened to
-- be online would have staff searching for a name that is there and not finding
-- it. See `server/offline.lua` for the argument in full.
--
-- NOTHING IS FILTERED HERE EITHER, which is the other half of it and the half
-- that costs. Every other list on this menu arrives whole and `matches()` cuts
-- it down in the client; there is no whole to arrive here, so the search box
-- goes to the SERVER and comes back as a page. The screen therefore draws
-- exactly what it was sent, in the order it was sent, and the `search` row is
-- always up rather than appearing at `SEARCH_FROM` rows -- on this screen it is
-- not a convenience over a list, it IS the way to the list.

-- The fewest characters the server will run a search for. The floor is checked
-- there and is the authority; this copy exists so that a term too short is a
-- sentence on the screen instead of a request that comes back refused.
local FIND_MIN_TERM = 3

--- The tag a find page is answered under. Its twin is `findTag` in
--- `server/menu.lua`, and the two are kept in step by hand: a tag built
--- differently on either side drops every answer instead of the late ones.
local function findTag(request)
	return ('%s|%s|%s'):format(request.mode, request.term or '', request.cursor or '')
end

--- Asks the server for one find page, and remembers which one was asked for.
-- The store is emptied and re-tagged BEFORE the request goes, so the screen
-- draws `loading` rather than the previous question's rows while it waits -- and
-- so the answer to the previous question, arriving late, no longer matches.
local function askFind(request)
	absent.tag = findTag(request)
	absent.rows, absent.incoming = {}, {}
	absent.loaded, absent.error = false, nil
	absent.mode, absent.term = request.mode, request.term
	absent.more, absent.cursor, absent.seenAt = false, nil, nil
	-- Kept whole, so that a refresh after a rename or a delete re-asks the SAME
	-- question -- including the page the operator was on -- rather than dropping
	-- them back on the first page of the recent list.
	absent.request = request
	TriggerServerEvent(M.Event.REFRESH, 'found', request)
end

SCREENS.offlineChars = function()
	local searching = absent.mode == 'search' and absent.term or nil
	local items = {
		row('search', locale('admin.menu.findSearch'), { form = 'search', arg = searching },
			{ icon = 'search', value = searching,
				description = locale('admin.menu.findHint') }),
	}
	if searching ~= nil then
		items[#items + 1] = row('searchClear', locale('admin.menu.findRecent'),
			{ clearFilter = true }, { icon = 'clock' })
	end
	items[#items + 1] = section()

	for _, entry in ipairs(absent.rows) do
		local name = characterName(entry)
		local item = go('found_' .. entry.citizenId, { text = name }, 'character',
			entry.citizenId, { icon = entry.live and 'star' or 'person' })
		-- The three states this screen exists to tell apart, in the order they
		-- matter: somebody is playing this very character, somebody is on this
		-- account playing another of theirs, or nobody is here at all and the
		-- value is when they last were.
		item.value = entry.live and locale('admin.menu.charLive')
			or entry.online and locale('admin.menu.charOnline')
			or entry.lastLoggedOut or locale('admin.menu.charNever')
		-- The account rather than the citizen id, unlike the per-account list: down
		-- there every row belongs to the player named in the title, and up here
		-- knowing WHOSE a character is is most of what an operator came to find out.
		item.description = entry.account
			and ('%s  %s'):format(entry.citizenId, entry.account) or entry.citizenId
		items[#items + 1] = item
	end

	if #absent.rows == 0 then
		items[#items + 1] = empty(not absent.loaded and 'admin.menu.loading'
			or absent.error and 'admin.menu.findError'
			or searching and 'admin.menu.findNoMatch' or 'admin.menu.findNone')
	elseif absent.more then
		-- A SEEK AND NOT A PAGE NUMBER. The row carries the sort key of the last
		-- row above it, so the next page is "what comes after this one" -- there is
		-- no page four to ask for, and a roster reordered by somebody logging out
		-- while the operator reads it cannot make this repeat a row or step over
		-- one below the cursor.
		items[#items + 1] = row('more', locale('admin.menu.more'),
			{ seek = { mode = absent.mode, term = absent.term,
				cursor = absent.cursor, seenAt = absent.seenAt } },
			{ icon = 'arrow' })
	end

	return locale(searching and 'admin.menu.findResults' or 'admin.menu.findRecentTitle'), items
end

SCREENS.playerItems = function(id)
	local target = tostring(id)
	return playerTitle(id, 'admin.menu.items'), append({
		section('admin.menu.section.vehicles'),
		go('giveVehicle', 'admin.menu.giveVehicle', 'vehicleClasses', id, { icon = 'vehicle' }),
		section('admin.menu.section.weapons'),
	}, weaponRows(target, 'admin.menu.giveWeapon'))
end

SCREENS.playerInventory = function(id)
	return playerTitle(id, 'admin.menu.inventory'), bagRows(tostring(id))
end

SCREENS.self = function()
	local items = append({
		section('admin.menu.section.movement'),
		icon(switch('noclip', 'admin.menu.noclip', { Command.SELF_NOCLIP }, Client.IsNoclip()),
			'bolt'),
		icon(command('maptravel', 'admin.menu.maptravel', { Command.SELF_MAPTRAVEL }), 'map'),
		go('teleport', 'admin.menu.teleport', 'locations', 'me', { icon = 'location' }),
		icon(form('coords', 'admin.menu.coords', 'coords', 'me', Command.PLAYER_TP), 'location'),
		icon(command('pos', 'admin.menu.pos', { Command.SELF_POS }), 'info'),

		section('admin.menu.section.view'),
		icon(switch('tags', 'admin.menu.tags', { Command.SELF_TAGS }, M.Tags.IsShown()), 'tag'),
		icon(flip('tagsOwn', 'admin.menu.tagsOwn', 'tagsOwn', M.Tags.IsOwnShown(), M.Tags.IsShown(),
			'admin.menu.tagsOwnOff'), 'tag'),
		icon(switch('invisible', 'admin.menu.invisible', { Command.SELF_INVISIBLE },
			M.Target.IsInvisible()), 'hidden'),

		section('admin.menu.section.body'),
		modelRow('me', M.Target.SelfModel()),
		icon(command('modelOff', 'admin.menu.modelOff', { Command.SELF_MODEL, 'off' }), 'refresh'),

		section('admin.menu.section.health'),
		icon(command('heal', 'admin.menu.heal', { Command.SELF_HEAL }), 'heal'),
		icon(command('revive', 'admin.menu.revive', { Command.SELF_REVIVE }), 'heart'),
		icon(switch('god', 'admin.menu.god', { Command.SELF_GOD }, Client.GodMode()), 'shield'),
	}, levelRows('me'))
	append(items, { section('admin.menu.section.weapons') })
	append(items, weaponRows('me', 'admin.menu.giveMe'))
	if inventoryUp() then
		items[#items + 1] = section('admin.menu.section.inventory')
		append(items, bagRows('me'))
	end
	return locale('admin.menu.self'), items
end

-- ── recovery ────────────────────────────────────────────────────────────────
-- MONEY BACK TO A CHARACTER, which is the one thing an operator is asked for
-- that the player cannot do for themselves: a purchase that ate a paycheque, a
-- balance zeroed by a bug, a truck of somebody's eddies that went to the wrong
-- citizen id. Two rows and no third: give it, to me or to somebody here.
--
-- EVERY ROW ENDS IN THE SAME COMMAND, and the only difference between them is
-- the target it carries -- `me`, resolved by the SERVER from the connection,
-- or a player id picked out of the roster. A client that could name its own
-- target would be a client deciding whose balance it is.
SCREENS.recovery = function()
	return locale('admin.menu.recovery'), {
		icon(form('recoverySelf', 'admin.menu.recoverySelf', 'recoveryMoney', 'me',
			Command.RECOVERY_MONEY), 'money'),
		goFor('recoveryPlayer', 'admin.menu.recoveryPlayer', 'recoveryPlayers', nil,
			Command.RECOVERY_MONEY, { icon = 'person', value = tostring(#roster) }),
	}
end

-- The picker the second row opens: the roster, and every row puts the player it
-- names into the same money form. Not a copy of the players screen -- that one
-- leads to everything that can be done to a body, and picking a target here
-- leads to one field and a confirm-free amount.
SCREENS.recoveryPlayers = function()
	local query = filtering()
	-- Read through a local, as the players screen reads it: the walk yields on the
	-- redraw's thread, and a ROSTER answer landing in that gap replaces the
	-- module's list -- possibly with a shorter one.
	local list = roster
	local matched = {}
	for index = 1, #list do
		local entry = list[index]
		local word = locale('admin.state.' .. entry.state)
		if matches(query, entry.id, entry.name, entry.user, entry.citizenId, word) then
			matched[#matched + 1] = entry
		end
	end

	-- PAGED like every list on this menu (see `PAGE_ROWS`): a full roster built
	-- in one resume was past the per-resume budget.
	local title, listed = paged(matched, 'recoveryPlayers', nil, locale('admin.menu.recoveryPlayer'),
		function(entry)
			local value = locale('admin.state.' .. entry.state)
			if entry.bucket ~= 0 then
				value = value .. ' ' .. locale('admin.menu.bucket', { bucket = entry.bucket })
			end
			if entry.distance then value = value .. ' ' .. entry.distance .. 'm' end
			-- THE LABEL IS A STRING AND NOT A `{ text = ... }` TABLE. The `go`/`form`
			-- helpers unwrap that shape for the rows they build; a row assembled by
			-- hand has to do it itself, and the contract refuses the WHOLE SCREEN when
			-- one label is a table -- `invalid_item_label`, which is how the picker
			-- drew nothing at all while the rest of the panel worked.
			return denied(row('recoveryPlayer_' .. entry.id,
				('[%d] %s'):format(entry.id, entry.name),
				{ form = 'recoveryMoney', arg = entry.id },
				{ value = value, icon = entry.state == 'down' and 'heal' or 'person' }),
				Command.RECOVERY_MONEY)
		end)
	local items = append(searchRows(#matched, #list), listed)
	if #matched == 0 then
		items[#items + 1] = empty(#list > 0 and 'admin.menu.noMatch' or 'admin.menu.nobody')
	end
	return title, items
end

SCREENS.vehicles = function()
	local items = {
		section('admin.menu.section.spawn'),
		go('spawn', 'admin.menu.spawn', 'vehicleClasses', 'me', { icon = 'vehicle' }),
		section('admin.menu.section.nearest'),
		icon(command('repair', 'admin.menu.repair', { Command.VEHICLE_REPAIR, 'near', 'full' }),
			'tool'),
		icon(command('repairVisual', 'admin.menu.repairVisual',
			{ Command.VEHICLE_REPAIR, 'near', 'visual' }), 'tool'),
		icon(command('enter', 'admin.menu.enter', { Command.VEHICLE_ENTER, 'near' }), 'door'),
		-- The key to the vehicle the operator sits in, else the nearest one: the
		-- same `near` every row in this band means, resolved on the server.
		icon(command('key', 'admin.menu.vehicleKey', { Command.VEHICLE_KEY, 'near' }), 'key'),
	}
	local flags = {}
	for _, flag in ipairs(M.Section('VEHICLES').FLAGS or {}) do
		if type(flag) == 'string' and flag:match('^[%w_]+$') then
			-- THE FLAG'S OWN WORDS, and its config name only for a flag nobody wrote
			-- any for. This row read `Toggle engineOn`: a code name, and a verb that
			-- says nothing about what pressing it does.
			local worded = 'admin.menu.flag.' .. flag
			local label = OPX.Locale.Exists(worded) and locale(worded)
				or locale('admin.menu.flag', { flag = flag })
			flags[#flags + 1] = icon(command('flag_' .. flag, { text = label },
				{ Command.VEHICLE_FLAG, 'near', flag }), 'flag')
		end
	end
	-- The flags are a band of their own: they are the only rows on this screen
	-- that change a state rather than do a thing, and without a rule over them
	-- they read as five more verbs in the same list.
	if #flags > 0 then
		items[#items + 1] = section('admin.menu.section.flags')
		append(items, flags)
	end
	items[#items + 1] = section('admin.menu.section.cleanup')
	items[#items + 1] = icon(command('remove', 'admin.menu.remove',
		{ Command.VEHICLE_REMOVE, 'near' }), 'trash')
	items[#items + 1] = icon(command('removeMine', 'admin.menu.removeMine',
		{ Command.VEHICLE_REMOVE, 'mine' }), 'trash')
	items[#items + 1] = icon(guarded('cleanup', 'admin.menu.cleanup', { Command.VEHICLE_CLEANUP },
		'admin.confirm.cleanup'), 'warning')
	return locale('admin.menu.vehicles'), items
end

SCREENS.vehicleClasses = function(target)
	local classes = {}
	for _, class in ipairs(Catalog.Classes()) do
		if #class.members > 0 then classes[#classes + 1] = class end
	end
	local items = searchRows(#classes, #classes)
	for _, class in ipairs(classes) do
		items[#items + 1] = go('class_' .. class.key, { text = class.label }, 'vehicleList',
			{ t = target, c = class.key }, { value = tostring(#class.members), icon = 'folder' })
	end
	if #classes == 0 then items[#items + 1] = empty('admin.menu.catalogEmpty') end
	return titleFor('admin.menu.vehicles', target), items
end

SCREENS.vehicleList = function(arg)
	local target = type(arg) == 'table' and arg.t or 'me'
	local query = filtering()
	local found
	for _, class in ipairs(Catalog.Classes()) do
		if type(arg) == 'table' and class.key == arg.c then found = class end
	end
	local all = found and found.members or {}
	local matching = {}
	for _, entry in ipairs(all) do
		breathe()
		if matches(query, entry.label, entry.name) then matching[#matching + 1] = entry end
	end
	local title, listed = paged(matching, 'vehicleList', arg, found and found.label or '?', function(entry)
			local tokens = target == 'me' and { Command.VEHICLE_SPAWN, entry.name }
				or { Command.VEHICLE_GIVE, tostring(target), entry.name }
			local item = icon(command('entry_' .. entry.name, { text = entry.label }, tokens),
				'vehicle')
			item.description = entry.name
			return item
		end)
	local items = append(searchRows(#matching, #all), listed)
	if #matching == 0 then
		items[#items + 1] = empty(query and 'admin.menu.noMatch' or 'admin.menu.catalogEmpty')
	end
	return title, items
end

SCREENS.pedFamilies = function(target)
	local families = {}
	for _, family in ipairs(Peds.Families()) do
		if #family.members > 0 then families[#families + 1] = family end
	end
	local items = searchRows(#families, #families)
	for _, family in ipairs(families) do
		items[#items + 1] = go('family_' .. family.key, { text = family.label }, 'pedList',
			{ t = target, f = family.key }, { value = tostring(#family.members), icon = 'folder' })
	end
	if #families == 0 then items[#items + 1] = empty('admin.menu.catalogEmpty') end
	items[#items + 1] = section()
	items[#items + 1] = icon(command('modelOff', 'admin.menu.modelOff', modelTokens(target, 'off')),
		'refresh')
	return titleFor('admin.menu.model', target), items
end

SCREENS.pedList = function(arg)
	local target = type(arg) == 'table' and arg.t or 'me'
	local query = filtering()
	local found
	for _, family in ipairs(Peds.Families()) do
		if type(arg) == 'table' and family.key == arg.f then found = family end
	end
	local all = found and found.members or {}
	local matching = {}
	for _, entry in ipairs(all) do
		breathe()
		if matches(query, entry.label, entry.name) then matching[#matching + 1] = entry end
	end
	local title, listed = paged(matching, 'pedList', arg, found and found.label or '?', function(entry)
			local item = icon(command('ped_' .. entry.name, { text = entry.label },
				modelTokens(target, entry.name)), 'person')
			item.description = entry.name
			return item
		end)
	local items = append(searchRows(#matching, #all), listed)
	if #matching == 0 then
		items[#items + 1] = empty(query and 'admin.menu.noMatch' or 'admin.menu.catalogEmpty')
	end
	return title, items
end

SCREENS.weaponList = function(arg)
	local target = type(arg) == 'table' and tostring(arg.t) or 'me'
	local query = filtering()
	local weapons, matching = {}, {}
	for _, entry in ipairs(catalog.rows) do
		breathe()
		if entry.weapon then
			weapons[#weapons + 1] = entry
			if matches(query, entry.label, entry.name) then matching[#matching + 1] = entry end
		end
	end
	local title, listed = paged(matching, 'weaponList', arg, locale('admin.menu.weapons'), function(entry)
			local item = offline(icon(command('entry_' .. entry.name, { text = entry.label },
				{ Command.WEAPON_GIVE, target, entry.name }), 'weapon'))
			item.description = entry.name
			return item
		end)
	local items = append(searchRows(#matching, #weapons), listed)
	if #matching == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(catalog, 'admin.menu.catalogEmpty')
	end
	return title, items
end

SCREENS.ammoList = function(target)
	local query = filtering()
	local kinds, rows = 0, {}
	for _, entry in ipairs(catalog.rows) do
		breathe()
		if entry.ammo then
			kinds = kinds + 1
			if matches(query, entry.label, entry.name) then rows[#rows + 1] = entry end
		end
	end
	local title, listed = paged(rows, 'ammoList', target, titleFor('admin.menu.giveAmmo', target),
		function(entry)
			local item = form('ammo_' .. entry.name, 'admin.menu.giveAmmo', 'ammoGive',
				{ t = tostring(target), n = entry.name, l = entry.label },
				Command.WEAPON_GIVEAMMO)
			item.label = entry.label
			item.description = entry.name
			return offline(icon(item, 'ammo'))
		end)
	local items = append(searchRows(#rows, kinds), listed)
	if #rows == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(catalog, 'admin.menu.catalogEmpty')
	end
	return title, items
end

-- Both catalogue screens take a table argument, and `Menu.OpenAt` -- public, the
-- `admin.OpenAt` export -- passes whatever it was given: a nil there indexed
-- `arg.t` and raised inside the redraw.
SCREENS.itemCategories = function(arg)
	arg = type(arg) == 'table' and arg or {}
	local query = filtering()
	local counts, names = {}, {}
	for _, entry in ipairs(catalog.rows) do
		breathe()
		if counts[entry.category] == nil then names[#names + 1] = entry.category end
		counts[entry.category] = (counts[entry.category] or 0) + 1
	end
	table.sort(names)
	local matching = {}
	for _, name in ipairs(names) do
		if matches(query, name) then matching[#matching + 1] = name end
	end
	local items = searchRows(#matching, #names)
	-- THE ROW ID IS THE CATEGORY'S PLACE, NOT ITS NAME. The server sends the
	-- name as the item catalogue spells it, trimmed and nothing else, and a
	-- name with a space in it -- `body armor` -- is not an id the menu contract
	-- accepts: one such category refused the whole screen. The name is in the
	-- row's text and its argument, which is all that reads it.
	for index, name in ipairs(matching) do
		items[#items + 1] = go('cat_' .. index, { text = name }, 'itemList',
			{ t = arg.t, m = arg.m, c = name }, { value = tostring(counts[name]), icon = 'folder' })
	end
	if #matching == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(catalog, 'admin.menu.catalogEmpty')
	end
	local titleKey = arg.m == 'holders' and 'admin.menu.invHolders' or 'admin.menu.invGive'
	return titleFor(titleKey, arg.t), items
end

SCREENS.itemList = function(arg)
	arg = type(arg) == 'table' and arg or {}
	local query = filtering()
	local all, matching = {}, {}
	for _, entry in ipairs(catalog.rows) do
		breathe()
		if entry.category == arg.c then
			all[#all + 1] = entry
			if matches(query, entry.label, entry.name) then matching[#matching + 1] = entry end
		end
	end
	local title, listed = paged(matching, 'itemList', arg, tostring(arg.c or '?'), function(entry)
		local item
		if arg.m == 'holders' then
			item = command('item_' .. entry.name, { text = entry.label },
				{ links().INVENTORY_HOLDERS, entry.name })
		else
			item = form('item_' .. entry.name, 'admin.menu.invGive', 'itemGive',
				{ t = arg.t, n = entry.name, l = entry.label }, Command.INVENTORY_GIVE)
			item.label = entry.label
		end
		item.description = entry.name
		return icon(item, arg.m == 'holders' and 'search' or 'box')
	end)
	local items = append(searchRows(#matching, #all), listed)
	if #matching == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(catalog, 'admin.menu.catalogEmpty')
	end
	return title, items
end

SCREENS.bag = function(target)
	local query = filtering()
	local held, rows = 0, {}
	if bag.target == tostring(target) then
		for _, entry in ipairs(bag.rows) do
			held = held + 1
			if matches(query, entry.label, entry.name, entry.slot) then rows[#rows + 1] = entry end
		end
	end
	local title, listed = paged(rows, 'bag', target, titleFor('admin.menu.invRemove', target),
		function(entry)
			local item = form(('slot_%d'):format(entry.slot), 'admin.menu.invRemove',
				'itemRemove',
				{ t = tostring(target), n = entry.name, l = entry.label, c = entry.count },
				Command.INVENTORY_REMOVE)
			item.label = ('%d  %s'):format(entry.slot, entry.label)
			if not item.disabled then item.value = 'x' .. tostring(entry.count) end
			item.description = entry.name
			return icon(item, 'box')
		end)
	local items = append(searchRows(#rows, held), listed)
	if #rows == 0 then
		items[#items + 1] = query and empty('admin.menu.noMatch')
			or placeholder(bag.target == tostring(target) and bag or { loaded = false },
				'admin.menu.bagEmpty')
	end
	return title, items
end

SCREENS.locations = function(target)
	local query = filtering()
	-- Through a local, for the reason the roster gives: a LOCATIONS answer can
	-- replace the list while this walk is yielded.
	local list = locations
	local rows = {}
	for index = 1, #list do
		local entry = list[index]
		if matches(query, entry.label, entry.name) then rows[#rows + 1] = entry end
	end
	local title = target == 'me' and locale('admin.menu.teleport')
		or ('%s: %s'):format(locale('admin.menu.send'), nameOf(target))
	local listed
	title, listed = paged(rows, 'locations', target, title, function(entry)
		local item = icon(command('loc_' .. entry.name, { text = entry.label },
			{ Command.PLAYER_SEND, tostring(target), entry.name }), 'location')
		if not item.disabled and entry.runtime then item.value = locale('admin.menu.runtime') end
		return item
	end)
	local items = append(searchRows(#rows, #list), listed)
	if #rows == 0 then
		items[#items + 1] = empty(query and 'admin.menu.noMatch' or 'admin.menu.noLocations')
	end
	return title, items
end

SCREENS.saved = function()
	local query = filtering()
	local runtime, rows = 0, {}
	for _, entry in ipairs(locations) do
		if entry.runtime then
			runtime = runtime + 1
			if matches(query, entry.label, entry.name) then rows[#rows + 1] = entry end
		end
	end
	-- CONFIRMED, like every other row that destroys something. A spot saved in
	-- game exists nowhere else, and this list is twenty identical trash rows an
	-- arrow key apart: one press used to forget it on the spot.
	local title, listed = paged(rows, 'saved', nil, locale('admin.menu.saved'), function(entry)
		return icon(guarded('forget_' .. entry.name,
			{ text = locale('admin.menu.forget', { label = entry.label }) },
			{ Command.WORLD_LOC_REMOVE, entry.name }, 'admin.confirm.forget', 'locations'), 'trash')
	end)
	local items = append(searchRows(#rows, runtime), listed)
	if #rows == 0 then
		items[#items + 1] = empty(query and 'admin.menu.noMatch' or 'admin.menu.noSaved')
	end
	return title, items
end

SCREENS.world = function()
	local link = links()
	local items = {
		section('admin.menu.section.broadcast'),
		icon(form('announce', 'admin.menu.announce', 'announce', nil, Command.WORLD_ANNOUNCE),
			'talk'),
		section('admin.menu.section.combat'),
		icon(switch('pvp', 'admin.menu.pvp', { Command.WORLD_PVP }, M.Combat.IsPvp()), 'weapon'),
	}
	if link.WEATHER_SET or link.TIME then
		items[#items + 1] = section('admin.menu.section.sky')
		if link.WEATHER_SET then
			items[#items + 1] = go('weather', 'admin.menu.weather', 'weather', nil,
				{ icon = 'weather' })
		end
		if link.TIME then
			items[#items + 1] = go('time', 'admin.menu.time', 'time', nil, { icon = 'clock' })
		end
	end
	items[#items + 1] = section('admin.menu.section.locations')
	items[#items + 1] = icon(form('save', 'admin.menu.saveHere', 'location', nil,
		Command.WORLD_LOC_ADD), 'plus')
	items[#items + 1] = go('saved', 'admin.menu.saved', 'saved', nil, { icon = 'list' })
	-- THE DOOR PANEL IS THE DOORLOCK MODULE'S, and this row only opens it: a
	-- command line, so the host checks `command.opx.doorlock` before anything is
	-- drawn, and the staff menu closes first because one owner holds the menu
	-- surface at a time.
	if link.DOORLOCK then
		items[#items + 1] = section('admin.menu.section.doors')
		local doors = icon(command('doors', 'admin.menu.doors', { link.DOORLOCK }), 'lock')
		doors.data.closeAfter = true
		items[#items + 1] = doors
	end
	return locale('admin.menu.world'), items
end

-- ── the Dev screen is gone ──────────────────────────────────────────────────
--
-- THE OWNER'S WORDS, 2026-09-21: "il y a pas de config live c'est tous par les
-- fichier config donc degage moi ce menu est pass moi tous dans les config".
--
-- A screen called Dev, sitting on the root beside Players and World and opened
-- by a key of its own, read as the place this server is CONFIGURED from. It is
-- not. Every place on this server -- a garage, a dealer, a showroom car, a
-- teleport, a lift -- is a line in `config/`, read at start, in version control
-- and reviewable. A menu that appears to place one of them teaches an operator
-- to set the server up somewhere nobody can read afterwards, which is the exact
-- lesson `/opx.garages.add` and `/opx.dealership.add` were deleted for.
--
-- WHERE THE SEVEN ROWS WENT:
--
--   `previewPlace` / `previewRemove` were the only two that were genuinely
--   CONFIGURATION, and they are `PREVIEW.POINTS` in `config/dealership.lua`
--   now. The dealership's server half prints every showroom car that exists
--   only in the database at boot, as the config line that recreates it, exactly
--   as it already did for adopted dealers.
--
--   `garageList`, `garageBring`, `dealerList`, `dealerStock` and `dealerBuy`
--   were never configuration: they are `opx.garages.list`, `opx.garages.bring`,
--   `opx.dealership.list`, `.stock` and `.buy`, all still registered and still
--   ACL-gated by the host. An operator types them in chat, which is what the
--   rows were typing on their behalf.
--
-- THE KEY WENT WITH IT. `Keys.DEV`, its registration here and `KEYS.DEV` in
-- `config/admin.lua` existed to land on this screen and on nothing else, so
-- F10 is free again. `Menu.OpenAt` stays -- the target eye and the down screen
-- both land on a named screen through it.
--
-- HOW AN OPERATOR CAPTURES A POSITION NOW: `/opx.admin.self.pos`, which is on
-- this menu under Self -> Position and on the eye's own row. It copies the
-- position AND the facing the operator is standing at straight to the operating
-- system clipboard, ready to paste into whichever `config/` file wants it. That
-- command is the whole of the capture path and the config headers name it.

-- ── the Dev screen ───────────────────────────────────────────────────────────
--
-- THE OWNER: "tu peux faire maintenant dans le menu admin avoir un categorie dev
-- pour avoir des tool avoir le nom de props get position etc".
--
-- NOT THE SCREEN THAT WAS REMOVED, and the difference is the whole reason this
-- one is allowed to exist. That one placed garage spots and showroom cars --
-- writes dressed as configuration, on a server whose configuration is files --
-- and went on the owner's word: "il y a pas de config live c'est tous par les
-- fichier config donc degage moi ce menu". These are READS. Nothing here writes
-- anything, anywhere; every row answers a question about the world and puts the
-- answer on the clipboard.
--
-- THE AIMING HALF IS ON THE EYE AND NOT HERE, because a menu has no crosshair. A
-- screen cannot ask what you are looking at: you are looking at the screen. So
-- the inspector is an ALT row on all eight kinds, and this screen shows what the
-- last one found -- which is also what makes the two halves one tool rather than
-- two features with the same name.
SCREENS.dev = function()
	local items = {
		section('admin.menu.section.devCapture'),
		-- The capture path itself, which every config header in this resource
		-- names. It is on the Self screen too: an operator looking for a dev tool
		-- should not have to know it is filed under Self.
		icon(command('pos', 'admin.menu.pos', { Command.SELF_POS }), 'location'),

		section('admin.menu.section.devInspect'),
	}

	local last = M.Target.LastInspection and M.Target.LastInspection() or nil
	if last == nil then
		-- A SEPARATOR AND NOT A DISABLED ROW. An empty state has to say
		-- something, and a row that looks pressable and is not is worse than a
		-- line of text that never looked like one.
		items[#items + 1] = section('admin.menu.devNoInspection')
	else
		-- The first line of the block, which is the kind, as the row's value --
		-- and the whole block on the clipboard when it is pressed. A menu row is
		-- one line high and the report is a dozen.
		local first = tostring(last):match('^[^\n]*') or ''
		items[#items + 1] = icon(row('devCopy', locale('admin.menu.devCopyLast'),
			{ devCopy = true }, { value = first:sub(1, 28) }), 'tag')
	end

	return locale('admin.menu.dev'), items
end

SCREENS.weather = function()
	local link = links()
	local items = {}
	if link.WEATHER_SET then
		local presets = M.Settings.WEATHER_PRESETS
		for _, preset in ipairs(type(presets) == 'table' and presets or {}) do
			if type(preset) == 'string' and preset:match('^[%w_%-]+$') then
				-- The preset's own words where the catalogue has them -- the eye's
				-- weather rows already drew them -- and the config name otherwise.
				local worded = 'admin.weather.' .. preset
				local label = OPX.Locale.Exists(worded) and locale(worded) or preset
				items[#items + 1] = icon(command('preset_' .. preset, { text = label },
					{ link.WEATHER_SET, preset }), 'weather')
			end
		end
		if #items > 0 then table.insert(items, 1, section('admin.menu.section.presets')) end
	end
	items[#items + 1] = section('admin.menu.section.clock')
	if link.WEATHER_NEXT then
		items[#items + 1] = icon(command('next', 'admin.menu.weatherNext', { link.WEATHER_NEXT }),
			'refresh')
	end
	if link.WEATHER_FREEZE then
		items[#items + 1] = icon(command('hold', 'admin.menu.weatherHold',
			{ link.WEATHER_FREEZE, 'on' }), 'lock')
		items[#items + 1] = icon(command('release', 'admin.menu.weatherRelease',
			{ link.WEATHER_FREEZE, 'off' }), 'refresh')
	end
	return locale('admin.menu.weather'), items
end

SCREENS.time = function()
	local link = links()
	local items = {}
	if link.TIME then
		local times = M.Settings.TIMES
		for _, clock in ipairs(type(times) == 'table' and times or {}) do
			if type(clock) == 'string' and clock:match('^%d%d?:%d%d$') then
				items[#items + 1] = icon(command('at_' .. (clock:gsub(':', '_')), { text = clock },
					{ link.TIME, clock }), 'clock')
			end
		end
		if #items > 0 then table.insert(items, 1, section('admin.menu.section.presets')) end
		items[#items + 1] = icon(form('custom', 'admin.menu.timeCustom', 'time', nil, link.TIME),
			'clock')
	end
	items[#items + 1] = section('admin.menu.section.clock')
	if link.TIME_FREEZE then
		items[#items + 1] = icon(command('hold', 'admin.menu.clockHold',
			{ link.TIME_FREEZE, 'on' }), 'lock')
		items[#items + 1] = icon(command('release', 'admin.menu.clockRelease',
			{ link.TIME_FREEZE, 'off' }), 'refresh')
	end
	return locale('admin.menu.time'), items
end

SCREENS.server = function()
	local link = links()
	local items = {
		section('admin.menu.section.reports'),
		icon(command('status', 'admin.menu.status', { Command.READ_STATUS }), 'info'),
		icon(command('audit', 'admin.menu.audit', { Command.READ_AUDIT }), 'list'),
	}
	if link.PLAYERS or link.SAVE then
		items[#items + 1] = section('admin.menu.section.characters')
		if link.PLAYERS then
			items[#items + 1] = icon(command('characters', 'admin.menu.characters', { link.PLAYERS }),
				'person')
		end
		if link.SAVE then
			items[#items + 1] = icon(guarded('save', 'admin.menu.saveAll', { link.SAVE },
				'admin.confirm.save'), 'refresh')
		end
	end
	if inventoryUp() and link.INVENTORY_HOLDERS then
		items[#items + 1] = section('admin.menu.section.inventory')
		items[#items + 1] = goFor('holders', 'admin.menu.invHolders', 'itemCategories',
			{ m = 'holders' }, link.INVENTORY_HOLDERS, { icon = 'search' })
	end
	return locale('admin.menu.server'), items
end

SCREENS.confirm = function(arg)
	-- Cancel first, so the cursor starts on the harmless row.
	return locale(arg.key), {
		row('cancel', locale('admin.menu.cancel'), { back = true }, { icon = 'back' }),
		-- THE CONFIRM ROW SAYS THE ACTION. It read `Confirm` under a question,
		-- which is one more thing to read before knowing what Enter does; the
		-- row that asked for the confirmation carries its own words here, and
		-- `Confirm` is only for a caller that names none.
		row('confirm', type(arg.label) == 'string' and arg.label or locale('admin.menu.confirm'),
			{ confirmed = true },
			{ description = table.concat(arg.tokens, ' '), icon = 'warning' }),
	}
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local onAction

-- The screen at the top of the stack.
local function top()
	return stack[#stack]
end

-- The ids of the filter block, which is not part of the list it sits over.
local HEAD_ROWS = { search = true, searchClear = true, state = true }

-- WHERE THE CURSOR STARTS on a screen that has not been visited yet.
--
-- The contract's own rule is "the first row it can stand on", which was right
-- until a filter block appeared above the list: from then on, opening Players
-- landed the cursor on the search box, and Enter -- the key an operator presses
-- without looking -- asked them to type instead of opening the first player.
-- The box is a way INTO a list and not the list, so it is skipped. A screen with
-- nothing under the block lands on Back, which is the only thing left to do.
local function firstBelowHead(items)
	for _, item in ipairs(items) do
		if not item.separator and not item.disabled and not HEAD_ROWS[item.id] then
			return item.id
		end
	end
	return nil
end

-- Puts the top screen up, or rebuilds it in place.
-- HOW MUCH OF A SCREEN THIS PANEL ASKS TO SEE AT ONCE.
--
-- Named here and not in a config, because it is the size of THIS surface and
-- nothing else reads it. The menu module's own window is nine rows, which the
-- root filled exactly until the Recovery category was added -- the tenth row was
-- drawn only after the operator scrolled, which is a category nobody finds. The
-- staff tree is full of ten- and twenty-row screens, so the panel names a window
-- that shows them, and a height that fits it on a 900-pixel screen: twelve rows
-- draw about 590 pixels with the frame and the hint.
--
-- Settled at open, like the rest of a menu's geometry: an update rebuilds rows
-- and never moves the surface under the player.
local VISIBLE_ROWS = 12
local MAX_HEIGHT_VH = 72

local function drawNow(inPlace)
	local current = top()
	if current == nil or suspended then return end
	local builder = SCREENS[current.screen]
	if builder == nil then return end
	local contract = Client.Contract('menu')
	if contract == nil then return end

	local title, items = builder(current.arg)
	if current.screen ~= 'confirm' then
		items[#items + 1] = section()
		if #stack > 1 then
			items[#items + 1] = row('back', locale('admin.menu.back'), nil, { back = true, icon = 'back' })
		else
			local key = Keys.Effective(Keys.MENU)
			items[#items + 1] = { id = 'close', label = locale('admin.menu.close'), close = true, icon = 'door',
				description = key and locale('admin.menu.closeKey', { key = key }) or nil }
		end
	end

	-- THE CONTRACT GETS A RESUME OF ITS OWN. The menu module checks every row of
	-- the spec -- id, text, the size of its data -- before it sends, and that is
	-- several hundred instructions a row: on top of the builder's last stretch it
	-- was the dearest single resume this menu made. So the redraw's thread
	-- yields once between building and handing over.
	--
	-- AND THE SCREEN IS CHECKED AGAIN AFTER EVERY YIELD. A builder that breathes
	-- hands the frame to everything else: F9 can close the menu, a form can put
	-- it aside, the operator can step into another screen. A build that carried
	-- on regardless reopened a menu over an empty stack -- every press on it
	-- ignored -- or put a screen back up behind a form. What was built for a
	-- screen that is no longer on top is dropped; whoever moved it has asked
	-- for its own redraw.
	if suspended or top() ~= current or not ownsDraw() then return end
	if onDrawThread() then
		Wait(0)
		if suspended or top() ~= current or not ownsDraw() then return end
	end

	drawn = drawn + 1
	local mine = drawn
	local status = queuedStatus
	queuedStatus = nil

	-- IN PLACE, WHETHER THE SCREEN CHANGED OR ONLY ITS ROWS.
	--
	-- An update is the contract's own "rebuild the open menu from a fresh spec,
	-- keeping the player where they are", and it costs one frame. An OPEN closes the
	-- live menu first, and every one of the four things that costs is paid per
	-- keystroke: a new handle, a blank page for the round trip (the strip vanishes
	-- and comes back -- the flicker), the configuration re-sent, and the page's
	-- nine-row arrival walk re-run for a screen that did not arrive, it replaced
	-- one. The handle is also the capability every intent from the page names, so a
	-- click landing inside that window carried a dead handle, was dropped, and the
	-- press had to be repeated. That was one reopen per descend.
	--
	-- The cursor is pinned only when the SCREEN changed. A redraw of the screen the
	-- player is already on keeps their position, which is the point of an update; a
	-- screen that replaced it has no position to keep, so it gets the landing an
	-- open would have given it -- the row under the filter block, or the row the
	-- operator left.
	-- Assigned by presence, never folded through `and`/`or`: `inPlace and nil or x`
	-- is `x`, which is how a redraw would jump the player back to the top of the
	-- screen they were standing in.
	local landing
	if not inPlace then landing = current.cursor or firstBelowHead(items) end
	-- ON THE DRAW THREAD THE CONTRACT CHECKS THE ROWS IN STEPS (`yield`), a few
	-- rows a frame: the check was the dearest part of a redraw left in one
	-- resume. A frame can then pass inside the call, so the screen is checked
	-- again after it, exactly as after the builder's own breaths.
	local paced = onDrawThread()
	if handle ~= nil and not suspended then
		local patched = contract.Update(handle, {
			title = title,
			items = items,
			cursor = landing,
			status = status and status.text or nil,
			statusBad = status and status.ok == false or nil,
			yield = paced or nil,
		})
		if patched.ok then return end
		-- The live menu is no longer ours to patch (it was closed under us, or
		-- another owner has the surface). Refuse rather than guess, and open a
		-- fresh one below -- unless the screen itself went while the call ran.
		handle = nil
		if suspended or top() ~= current or not ownsDraw() then return end
	end

	local opened = contract.Open({
		owner = M.OWNER,
		id = 'admin.' .. current.screen,
		title = title,
		-- A remembered row first, then the first row UNDER the filter block. Only
		-- the open path needs it: an update keeps the cursor where the player left
		-- it, which is the whole point of updating in place.
		cursor = current.cursor or firstBelowHead(items),
		status = status and status.text or nil,
		statusBad = status and status.ok == false or nil,
		rows = VISIBLE_ROWS,
		maxHeight = MAX_HEIGHT_VH,
		items = items,
		on = onAction,
		yield = paced or nil,
	})
	-- Closed, put aside or replaced while the rows were being checked: the menu
	-- that just opened belongs to a screen that is gone.
	if opened.ok and (suspended or top() ~= current or not ownsDraw()) then
		contract.Close(opened.value.handle, 'superseded')
		return
	end
	if mine ~= drawn then return end
	if not opened.ok then
		handle = nil
		Open77.log.warn(('[admin] menu %s did not open: %s')
			:format(current.screen, tostring(opened.error)))
		if opened.error == 'menu_busy' then Client.Toast('admin.client.menuBusy', nil, 'warning') end
		return
	end
	handle = opened.value.handle
end

-- A redraw is QUEUED, NOT RUN, and every caller goes through here.
--
-- THE OWNER'S REPORT: the weapon search closed its box and no menu came back,
-- and F9 then needed two presses. The client log said why: "admin callback
-- raised on submit ... script execution budget exceeded". The client gives each
-- resume a fixed instruction budget, and a redraw -- filter a catalogue, build
-- every row, hand the spec to the menu contract, which validates it and closes
-- and reopens the surface -- was run inside whichever callback asked for it.
-- Inside the form's submit, after the form had already spent its share, that
-- was over budget: the coroutine died between closing the old menu and opening
-- the new one, and `handle` was left naming a menu that no longer existed.
--
-- On its own thread the redraw has a whole budget to itself, and several asks in
-- one frame -- a status line, a refresh, a filter -- become one redraw. It is
-- in place only if every ask was.
local drawQueued, drawQueuedInPlace = false, true
-- `drawingSince` (declared by `breathe`, which refreshes it) is when the
-- drawing thread last showed signs of life, nil while none runs. A thread the
-- budget killer unwound never clears it, so one older than `DRAW_STALE_MS` is
-- presumed dead and a new one takes over rather than the menu never drawing
-- again -- on the next ask, or on the upkeep pass if no ask comes.
local DRAW_STALE_MS = 2000

local function draw(inPlace)
	if type(CreateThread) ~= 'function' then return drawNow(inPlace) end
	drawQueuedInPlace = drawQueuedInPlace and inPlace == true
	drawQueued = true
	local now = Client.NowMs()
	if drawingSince ~= nil and now - drawingSince < DRAW_STALE_MS then return end
	drawingSince = now
	-- ONE THREAD AT A TIME, looping while asks keep arriving: a builder yields
	-- between rows now, and two of them interleaved would share `onDrawThread`
	-- and race each other to the contract.
	CreateThread(function()
		local me = coroutine.running()
		drawThread = me
		drawThreads[me] = true
		local again = false
		while drawQueued and drawThread == me do
			-- A redraw asked for while the last was building starts on a fresh
			-- resume: run straight on, it shared one with the contract call that
			-- had just finished, and that pair was this thread's dearest resume.
			if again then
				Wait(0)
				if not (drawQueued and drawThread == me) then break end
			end
			again = true
			local place = drawQueuedInPlace
			drawQueued, drawQueuedInPlace = false, true
			drawingSince = Client.NowMs()
			local ran, failure = pcall(drawNow, place)
			-- LOGGED, AND THE LOOP GOES ON. This used to re-raise, which ended the
			-- thread -- and with it any redraw asked for while the failed one was
			-- building, which had only set `drawQueued` and was never drawn.
			if not ran then
				Open77.log.error(('[admin] menu redraw raised: %s'):format(tostring(failure)))
			end
		end
		drawThreads[me] = nil
		-- A thread that was taken over leaves the take-over's state alone.
		if drawThread == me then
			drawThread = nil
			drawingSince = nil
		end
	end)
end

-- The upkeep pass's half of the stale take-over: a redraw asked for while a
-- dead thread still held `drawingSince` is drawn once that thread is presumed
-- dead, instead of waiting for some later ask to notice.
local function rescueDraw()
	if drawQueued and drawingSince ~= nil and Client.NowMs() - drawingSince >= DRAW_STALE_MS then
		draw(drawQueuedInPlace)
	end
end

-- THE SERVER'S REFRESH FLOOR, mirrored. `ADMIN_RATE_REFRESH_MS` is 750 out of
-- the box and the server remains the authority; this copy exists so the menu
-- does not SEND a request the server would only turn away. It is the same
-- bargain `FIND_MIN_TERM` strikes with the search floor a few hundred lines up.
local REFRESH_FLOOR_MS = 750

-- When each refresh question was last put to the server, by question.
local askedAt = {}

--- Asks the server for one list because the operator WALKED ONTO a screen that
--- draws it, and drops the ask when the same question went out a moment ago.
-- @author dop42
--
-- THE OWNER'S REPORT WAS "des fois je recois des message du style slow down
-- dans le menu admin mais cela marche quand meme" -- a Slow down toast on a
-- staff action that worked anyway -- and this was one of its two halves.
--
-- Walking root -> Players -> a player -> Health is three keypresses, and `push`
-- below asks for the ROSTER on every screen whose name starts with `player`. So
-- three deliberate presses put three identical roster requests on the wire
-- inside about 300ms, the server's 750ms floor turned the second and the third
-- away, and `OPX.Refuse` raised `error.tooFast` at the operator for each. The
-- navigation itself worked perfectly -- the screens draw from the roster this
-- client already holds -- so what the operator saw was a menu that worked while
-- telling them to slow down. The limit was not wrong; asking three times for
-- one list in a third of a second was.
--
-- ONLY THE INCIDENTAL ASKS COME THROUGH HERE. A refresh sent because a COMMAND
-- was answered goes straight out (see `Menu.Answered`): that one is the single
-- case where the list has actually changed and a stale answer is the wrong
-- answer. So are the per-target asks -- a bag, an account's characters, a find
-- page -- because each empties its store to `loading` before it asks, and a
-- dropped request would leave that screen waiting for ever.
-- @param topic string
-- @param arg any
-- @return boolean whether it was sent
local function askFor(topic, arg)
	local now = Client.NowMs()
	-- Swept on the way in rather than on a timer: an entry past the floor can
	-- never suppress anything again, so the table only ever holds the questions
	-- asked in the last three quarters of a second.
	for question, at in pairs(askedAt) do
		if now - at >= REFRESH_FLOOR_MS then askedAt[question] = nil end
	end

	-- Keyed by the question and not by the topic. None of the topics that reach
	-- here carries an argument today, but one that did -- and was keyed by its
	-- topic alone -- would answer a second target's question with the first's
	-- silence, which is the exact failure this whole change is about.
	local question = topic .. '|' .. tostring(arg)
	if askedAt[question] ~= nil then return false end
	askedAt[question] = now
	TriggerServerEvent(M.Event.REFRESH, topic, arg)
	return true
end

-- Pushes a screen, asks for its data again, and draws it. `page` is set only by
-- a list's next-page row.
local function push(screen, arg, page)
	-- A FILTER SURVIVES A PAGE TURN. `more` pushes the SAME screen with `p + 1`,
	-- which is a new stack entry -- and a new entry carries no filter, so page two
	-- of a search came back unfiltered and showed the twenty rows the operator had
	-- just filtered away. Only the same screen inherits: pushing from a list into
	-- one of its rows is a different question and starts clean.
	-- The roster's state filter is carried the same way, for the same reason.
	local current = stack[#stack]
	local same = current ~= nil and current.screen == screen
	stack[#stack + 1] = { screen = screen, arg = arg, filter = same and current.filter or nil,
		state = same and current.state or nil, page = math.tointeger(page) }
	-- Leaving the root is the moment to re-check what the ACL still grants.
	if #stack == 2 then askFor('access') end
	-- BEFORE the `^player` prefix test below, which this name also matches: that
	-- branch would win the chain and ask only for the roster, and the list would
	-- sit on 'loading' for ever. The roster is asked for here as well, because the
	-- screen's title names the player.
	if screen == 'offlineChars' then
		-- Opened on the recent list, never on the last search: a screen that came
		-- back holding somebody else's name is a screen the operator has to clear
		-- before it is useful.
		askFind({ mode = 'recent' })
	elseif screen == 'playerCharacters' then
		chars.target, chars.rows, chars.incoming = tostring(arg), {}, {}
		chars.loaded, chars.error = false, nil
		TriggerServerEvent(M.Event.REFRESH, 'characters', tostring(arg))
		askFor('roster')
	elseif screen:match('^player') then
		askFor('roster')
	elseif screen == 'locations' or screen == 'saved' then
		askFor('locations')
	elseif (screen == 'itemCategories' or screen == 'weaponList' or screen == 'ammoList') and
		(not catalog.loaded or catalog.error) then
		askFor('items')
	elseif screen == 'bag' then
		bag.target, bag.rows, bag.incoming, bag.loaded, bag.error = tostring(arg), {}, {}, false, nil
		TriggerServerEvent(M.Event.REFRESH, 'bag', tostring(arg))
	end
	draw()
end

-- Goes back a screen, or closes the menu at the root.
local function pop()
	if #stack <= 1 then return Menu.Close() end
	stack[#stack] = nil
	draw()
end

-- Pushes a screen over the root, or puts its form up with the screen under it.
local function land(wanted)
	if wanted.form then
		-- The form's cancel brings the screen back and its confirm pushes onto it.
		suspended = true
		push(wanted.screen, wanted.arg)
		Forms.Open(wanted.form, wanted.arg)
		return
	end
	if wanted.screen == 'root' then return draw() end
	push(wanted.screen, wanted.arg)
end

-- ── what another file calls ─────────────────────────────────────────────────

--- Writes the line under the list, or keeps it for the next screen.
---
--- THE ANSWER SAYS WHETHER THE PLAYER CAN READ IT NOW, and it used to say
--- nothing at all. `modules/menu` no longer draws a status line: `SetStatus` is
--- rerouted to a TOAST, because a line under a list is a line nobody watches. So
--- a caller that writes the status and then raises a toast of its own is putting
--- the same sentence on screen twice, in the same lane -- which is exactly what
--- the owner saw when they gave themselves an item as staff: one untitled toast
--- from here and one titled STAFF from `Client.Notice`. A caller cannot avoid
--- that without being told whether this call landed, so this answers.
---
--- Queued is NOT landed. With no menu open the line is kept for the next screen
--- and the player sees nothing now, so the caller's own toast is the only thing
--- that will say anything -- the keybinds and the map pick both run commands
--- with the menu shut.
-- @author dop42
-- @param line string
-- @param ok boolean
-- @return boolean whether the line is on screen now
function Menu.Status(line, ok)
	if type(line) ~= 'string' then return false end
	local one = line:match('^[^\n]*') or line
	if #one > 116 then one = Text.Bytes(one, 113) .. '...' end
	if handle == nil then
		queuedStatus = { text = one, ok = ok }
		return false
	end
	local contract = Client.Contract('menu')
	if contract == nil then return false end
	local wrote = contract.SetStatus(handle, one, ok == false)
	return type(wrote) == 'table' and wrote.ok == true
end

-- The refresh topics that are read FOR somebody, and are dropped by the server
-- without one. Everything else -- the roster, the locations, the catalogue -- is
-- the whole world's and takes no argument.
local PER_TARGET = { bag = true, characters = true, found = true }

-- GAPS, not instants: the settle after a switch waits each of these in turn, so
-- the screen is rebuilt about 120 ms, 250 ms, 500 ms and 1 s after the command
-- went out. Front-loaded because a client-side switch has usually landed within
-- one frame and the operator is looking straight at the row; the tail is for a
-- command that goes to the server and answers nothing back. Four redraws of a
-- nine-row list, once per deliberate keypress.
local SWITCH_SETTLE_MS = { 120, 130, 250, 500 }

--- Who a per-target topic is asked for, or nil.
-- The two are read from different places on purpose. A bag is read off the
-- screen the operator is standing on, because that screen IS the bag. A
-- character list is read off the list's own tag, because the screen asking for
-- it is usually the single-character page BELOW the list, whose own argument is
-- a citizen id rather than the player the account belongs to.
local function refreshArg(topic)
	if topic == 'bag' then
		local current = top()
		return current and current.screen == 'bag' and tostring(current.arg) or nil
	end
	if topic == 'characters' then return chars.target end
	-- A TABLE and not a token, which `PER_TARGET` above is happy with: it only
	-- asks whether there is one. The find's argument is the question it asked
	-- last, so a refresh brings back the same page rather than the first one.
	if topic == 'found' then return absent.request end
	return nil
end

--- Runs a command line and asks for a list again once the server has answered.
-- @author dop42
--
-- THIS USED TO BE A 1200 ms SLEEP, and that number was the whole bug the owner
-- reported as "deleting a character takes seconds to leave the screen". The
-- client already learns the outcome of every line it sends -- the dispatcher
-- answers on `COMMAND_RESULT` and `onCommandResult` in `main.lua` reads it -- and
-- the old code threw that away and guessed instead. Measured, the guess cost a
-- fixed 1200 ms on top of the command's own round trip, the refresh's, and the
-- two database reads behind the list.
--
-- IT WAS ALSO A CORRECTNESS BUG AND NOT ONLY A SLOW ONE. 1200 ms is a bet that
-- the server finishes first, and a character delete is the heaviest write in
-- this runtime: it ends a session and fans out across five modules. Lose the
-- bet and the refetch reads the list BEFORE the row goes, the answer redraws the
-- deleted row as though it were still there, and nothing asks again -- so the
-- row stays until the operator navigates away. A guess cannot be tuned out of
-- that; only the answer can.
--
-- A REFUSED LINE NOW ASKS FOR NOTHING. The old thread fired whatever the server
-- said, which spent a list read on a delete the ACL had just refused.
-- @param tokens table
-- @param refresh string|nil
function Menu.Run(tokens, refresh)
	suspended = false
	if #stack > 0 and handle == nil then draw() end
	if not Client.Execute(tokens) then
		Menu.Status(locale('admin.client.notSent'), false)
		return
	end
	if refresh == nil then return end
	local arg = refreshArg(refresh)
	-- A per-target topic with no target is a request the server drops anyway, so
	-- it is not sent: the list stays as it was rather than silently not arriving.
	if PER_TARGET[refresh] and arg == nil then return end

	-- Keyed by the command NAME, because that is what comes back on the answer.
	-- A second run of the same line replaces the first: both want the same list,
	-- and the later answer is the one that knows what is in it.
	pending[tostring(tokens[1]):lower()] =
		{ topic = refresh, arg = arg, tokens = tokens, atMs = Client.NowMs() }
end

-- Takes one character out of whichever list is holding it, answering whether it
-- was there. Both stores are swept: the same citizen id can be in an account's
-- list and in the find at once, and a row left in either is a row the operator
-- can open a page on.
local function dropCharacter(citizenId)
	local gone = false
	for _, store in ipairs({ chars, absent }) do
		for index = #store.rows, 1, -1 do
			if store.rows[index].citizenId == citizenId then
				table.remove(store.rows, index)
				gone = true
			end
		end
	end
	return gone
end

--- What the server said about a line this menu sent, and what follows from it.
-- @author dop42
--
-- NOT OPTIMISM. Nothing here runs until the server has answered, and a refusal
-- takes the other branch: the row stays, and the refusal is the line under the
-- list. Removing a row before the server agreed would be worse than the delay it
-- saves -- the case that matters is the delete that gets REFUSED, and a list
-- that silently put the row back is how somebody deletes the wrong character
-- twice.
-- @param name string the command name, lowercased
-- @param accepted boolean
function Menu.Answered(name, accepted)
	local held = pending[name]
	if held == nil then return end
	pending[name] = nil

	-- A refused line changed nothing, so there is nothing to ask for. The redraw
	-- `onCommandResult` already does puts back whatever state actually holds.
	if accepted ~= true then return end

	-- THE ROW GOES NOW, not a list read later. A confirmed delete is the server
	-- saying the character is gone; the refetch below is still sent, because the
	-- delete moves things this client cannot derive -- the account's active lock
	-- among them -- but the operator does not wait on it to see the thing they
	-- asked for happen.
	if held.tokens[1] == Command.CHARACTER_DELETE and held.tokens[2] ~= nil then
		if dropCharacter(tostring(held.tokens[2])) then draw(true) end
	end

	-- SENT, NEVER FLOORED -- `askFor` is deliberately not used here. This is the
	-- one refresh that knows the list it asks for has CHANGED: the operator just
	-- healed somebody, or renamed a character, and the server has said it
	-- happened. Dropping it because walking onto the screen asked for the same
	-- list half a second ago would leave the menu drawing the world as it was
	-- before the action -- which is the failure the answer-driven refetch was
	-- written to end. If it trips the server's floor the server drops it in
	-- silence; it does not tell the operator their action was too fast, because
	-- it was not.
	TriggerServerEvent(M.Event.REFRESH, held.topic, held.arg)
end

-- How long a pending refresh waits for an answer that may never come.
--
-- The dispatcher answers every line it accepts, but "every" is a claim about
-- code this module does not own, and the failure it would cause is the list
-- never refreshing at all -- the exact symptom this change exists to end. So the
-- old blind delay is kept as a FLOOR rather than the mechanism: past this the
-- refresh is sent unanswered, which is no worse than what shipped before.
local ANSWER_GRACE_MS = 3000

-- Sends any refresh whose answer never arrived. On the upkeep pass, so a
-- forgotten entry cannot outlive the menu.
local function sweepPending()
	local now = Client.NowMs()
	for name, held in pairs(pending) do
		if now - held.atMs > ANSWER_GRACE_MS then
			pending[name] = nil
			TriggerServerEvent(M.Event.REFRESH, held.topic, held.arg)
		end
	end
end

--- Puts a typed query on the open list screen, or clears it.
-- Called by the search form; nothing else sets a filter. The page number goes
-- back to one with it, because page four of the unfiltered list is almost never
-- a page of the filtered one -- and a filter that lands the operator on an empty
-- page reads as a search that found nothing.
-- @author dop42
-- @param query string|nil
function Menu.Filter(query)
	suspended = false
	local current = top()
	if current == nil then return end
	local typed = type(query) == 'string' and Text.Bytes(query, 48) or nil
	if typed ~= nil then typed = OPX.String.Trim(typed) end

	-- THE ONE SCREEN WHOSE FILTER IS NOT A FILTER. Every other list on this menu
	-- has already arrived in full and `matches()` cuts it down without touching
	-- the server. The find has no full list to cut -- that is the point of it --
	-- so the typed words are a QUERY: they go to the database, and what comes
	-- back is the page. Which also means the floor: a one-letter term is a table
	-- scan, so it is refused HERE with a sentence rather than sent and refused
	-- there with a code.
	if current.screen == 'offlineChars' then
		current.cursor = nil
		if typed ~= nil and typed ~= '' and #typed < FIND_MIN_TERM then
			Menu.Status(locale('admin.menu.findShort', { least = FIND_MIN_TERM }), false)
			return draw()
		end
		-- An empty box is how a filter is cleared everywhere else on this menu, so
		-- here it is how the operator gets back to the recent list.
		askFind((typed == nil or typed == '') and { mode = 'recent' }
			or { mode = 'search', term = typed })
		return draw()
	end

	current.filter = (typed ~= nil and typed ~= '') and typed or nil
	current.cursor = nil
	current.page = nil
	draw()
end

--- Pushes the confirmation screen for a command line.
-- @author dop42
-- @param tokens table
-- @param key string
-- @param refresh string|nil
-- @param popAfter boolean|nil
-- @param label string|nil what the confirm row says; `Confirm` when nil
function Menu.Confirm(tokens, key, refresh, popAfter, label)
	suspended = false
	if #stack == 0 then return end
	top().cursor = nil
	stack[#stack + 1] = { screen = 'confirm',
		arg = { tokens = tokens, key = key, refresh = refresh, back = popAfter == true,
			label = label } }
	draw()
end

-- Closes the open handle, if any.
local function takeDown()
	if handle == nil then return end
	local closing = handle
	handle = nil
	local contract = Client.Contract('menu')
	if contract ~= nil then contract.Close(closing, 'admin') end
end

--- Takes the menu down for a form, keeping the stack.
-- @author dop42
function Menu.Suspend()
	suspended = true
	takeDown()
end

--- Brings the menu back after a form, with an optional line under the list.
-- @author dop42
-- @param line string|nil
-- @param ok boolean|nil
function Menu.Resume(line, ok)
	suspended = false
	if line then queuedStatus = { text = line, ok = ok } end
	draw()
end

--- Takes the menu and any form down and empties the stack.
-- @author dop42
function Menu.Close()
	stack = {}
	suspended = false
	Forms.Close()
	takeDown()
end

--- Redraws the open screen in place, for text that changed under it.
-- @author dop42
function Menu.Refresh()
	if handle ~= nil and not suspended then draw(true) end
end

--- Whether the menu or one of its forms is up.
-- @author dop42
-- @return boolean
function Menu.IsOpen()
	return handle ~= nil or Forms.IsOpen()
end

--- Which list a character is currently drawn out of, as a refresh topic.
-- @author dop42
--
-- For the forms, which act on a citizen id and then have to ask the list it came
-- from for itself again. There are two lists now -- an account's characters and
-- the find -- and a form that named one of them outright refreshed the wrong one
-- half the time. Nil when the row is in neither, which means nothing to refresh.
-- @param citizenId CitizenId
-- @return string|nil
function Menu.ListOf(citizenId)
	local _, from = characterRow(citizenId)
	return from
end

--- The name of the screen at the top of the stack.
-- @author dop42
-- @return string|nil
function Menu.Screen()
	local current = top()
	return current and current.screen or nil
end

--- Opens the menu on one screen over the root, with a form over it when given.
-- @author dop42
-- @param screen string
-- @param arg any
-- @param formKind string|nil
-- @return boolean
function Menu.OpenAt(screen, arg, formKind)
	if SCREENS[screen] == nil then return false end
	local wanted = { screen = screen, arg = arg, form = formKind }
	if session ~= nil and #stack > 0 then
		Forms.Close()
		stack = { { screen = 'root' } }
		suspended = false
		land(wanted)
		return true
	end
	-- No session yet: the opener has to answer first, and the ACL decides whether
	-- it ever does. The wanted screen is held for a few seconds.
	wanted.atMs = Client.NowMs()
	landing = wanted
	return Client.Execute({ M.OPENER })
end

-- ── what the player did ─────────────────────────────────────────────────────

onAction = function(payload)
	if type(payload) ~= 'table' then return end

	if payload.action == 'close' then
		-- A reopen is this module replacing its own menu; the close belongs to the
		-- screen that has already gone.
		if payload.reason == 'reopened' or payload.handle ~= handle then return end
		handle = nil
		if suspended then return end
		-- The contract's own BACK at depth one closes the menu; here that means
		-- "up one of MY screens".
		if payload.reason == 'back' and #stack > 1 then
			stack[#stack] = nil
			return draw()
		end
		stack = {}
		return
	end

	local data = payload.data
	local current = top()
	if type(data) ~= 'table' or current == nil then return end

	-- A checkbox flips itself and reports the state it landed on; the command
	-- gets that state spelled out rather than a toggle, so a row that was already
	-- right cannot be flipped by a redraw.
	if payload.action == 'change' then
		-- THE STATE FILTER, which is a client flip by another name: it changes what
		-- THIS screen lists and nothing else, so it is answered here and the list is
		-- redrawn at once. The chosen LABEL comes back and is read to the key it
		-- stands for -- a word from a draw that has since been replaced resolves to
		-- nothing and is dropped rather than filtering to a state nobody picked.
		if data.states == true then
			local state = stateOf(payload.value)
			if state == nil then return end
			current.cursor = payload.itemId
			current.state = state ~= 'all' and state or nil
			current.page = nil
			return draw()
		end
		-- A CLIENT FLIP is answered here and the list is redrawn AT ONCE, rather
		-- than after the round trip a `switch` waits on -- because there is no
		-- round trip: the state the next draw reads is already the new one.
		if type(data.flip) == 'string' and type(payload.value) == 'boolean' then
			current.cursor = payload.itemId
			if data.flip == 'tagsOwn' then M.Tags.SetOwnShown(payload.value) end
			return draw()
		end
		if type(data.switch) ~= 'table' or type(payload.value) ~= 'boolean' then return end
		current.cursor = payload.itemId
		local tokens = {}
		for index, token in ipairs(data.switch) do tokens[index] = token end
		tokens[#tokens + 1] = payload.value and 'on' or 'off'
		Menu.Run(tokens)
		-- AND THEN REDRAW, WHICH THIS BRANCH ALONE DID NOT DO. The two branches
		-- above both end in `draw()` and both explain themselves by saying a
		-- switch is the case that "waits on the round trip". Some switches do:
		-- `tags` is answered by the server and its answer calls `Menu.Refresh`.
		-- Many do not. `noclip` is decided on this client, by this client, and
		-- nothing echoes -- so the row, and every OTHER row whose `disabled` is
		-- computed from it, kept whatever the last draw had decided. The operator
		-- saw a live checkbox beside a row that should have greyed out, and the
		-- screen only told the truth again when some unrelated event happened to
		-- redraw it. That is the "I have to move once for it to update" the owner
		-- reported, and it was never about the cursor: the menu module does not
		-- dispatch on a move, so moving cannot rebuild anything. It was about
		-- which event got there first.
		--
		-- A COMMAND IS NOT SYNCHRONOUS, so one redraw here would read the state
		-- the switch has not changed yet. A short bounded settle is what covers
		-- both kinds without the menu having to know which kind it just ran: the
		-- builder re-reads whatever it reads, four more times, over a second. An
		-- in-place update is a rebuild and one frame, the menu is open and already
		-- interactive, and a redundant frame costs a page repaint of nine rows.
		--
		-- A switch the SERVER answers keeps working exactly as before: its echo
		-- still calls `Menu.Refresh`, and landing on an unchanged frame is free.
		return CreateThread(function()
			for _, delay in ipairs(SWITCH_SETTLE_MS) do
				Wait(delay)
				if handle == nil then return end
				Menu.Refresh()
			end
		end)
	end

	if payload.action ~= 'select' then return end
	current.cursor = payload.itemId

	if data.back then return pop() end
	if data.clearFilter then return Menu.Filter(nil) end
	if data.confirmed and current.screen == 'confirm' then
		local held = current.arg
		stack[#stack] = nil
		-- `back` LEAVES THE PAGE THE ACTION DESTROYED. A confirmed delete drops the
		-- thing the screen underneath was drawing -- a deleted character's own page
		-- would come back reading its id and a blank name out of a list that no
		-- longer holds it -- so the caller that knows that says so, and the list
		-- above is what the operator lands on and what the refresh then redraws.
		if held.back and #stack > 1 then stack[#stack] = nil end
		draw()
		return Menu.Run(held.tokens, held.refresh)
	end
	-- A SEEK STAYS ON THE SCREEN. `paged()` turns a page by PUSHING the same
	-- screen with `p + 1`, which is right for a list the client already holds --
	-- going Back is then a page back. This one is a new request to the server, and
	-- pushing would grow a stack entry per page and leave every one of them
	-- pointing at a store that has moved on. So the store turns the page and the
	-- one screen is redrawn in place.
	if type(data.seek) == 'table' then
		askFind(data.seek)
		return draw()
	end
	-- The Dev screen's one pressable row: put the last inspection back on the
	-- clipboard. It is here rather than in the screen builder because a row's
	-- data is what the dispatch reads, and a builder that acted would act every
	-- time the screen was drawn.
	if data.devCopy == true then
		local last = M.Target.LastInspection and M.Target.LastInspection() or nil
		local clipboard = Open77.clipboard
		local copied = false
		if last ~= nil and type(clipboard) == 'table'
			and type(clipboard.setText) == 'function' then
			local wrote, ok = pcall(clipboard.setText, last)
			copied = wrote and ok == true
		end
		Client.Toast(copied and 'admin.menu.devCopied' or 'admin.menu.devCopyFailed', nil,
			copied and 'success' or 'error')
		return
	end
	if type(data.go) == 'string' and SCREENS[data.go] then return push(data.go, data.arg, data.page) end
	if type(data.run) == 'table' then
		Menu.Run(data.run, data.refresh)
		if data.closeAfter then Menu.Close() end
		return
	end
	if type(data.confirm) == 'table' and type(data.key) == 'string' then
		return Menu.Confirm(data.confirm, data.key, data.refresh, data.popAfter, data.label)
	end
	if type(data.form) == 'string' then return Forms.Open(data.form, data.arg) end
end

-- The menu key: closes an open menu, otherwise sends the opener.
local function pressed()
	if Menu.IsOpen() then return Menu.Close() end
	Client.Execute({ M.OPENER })
end

-- Sets the down screen aside while a downed operator has the menu or a form up,
-- and sends any refresh whose answer never came.
local function syncSuspend()
	sweepPending()
	local downed = Client.Contract('downed')
	if downed == nil then
		suspending = false
		return
	end
	local wanted = playerDown and (#stack > 0 or Forms.IsOpen())
	if wanted == suspending then return end
	local result = downed.Suspend(M.OWNER, wanted)
	if result.ok then
		suspending = wanted
	elseif not suspendReported then
		suspendReported = true
		Open77.log.warn(('[admin] the downed module refused to set its screen aside: %s. Add ' ..
			'`admin = true` to SUSPENDERS in config/downed.lua.'):format(tostring(result.error)))
	end
end

-- ── collecting the server's lists ───────────────────────────────────────────

-- Gathers one chunk of a list, answering whether it is complete.
local function collect(list, payload, accept)
	if payload.offset == 0 then list.incoming = {} end
	for _, entry in ipairs(payload.rows) do
		local kept = type(entry) == 'table' and accept(entry) or nil
		if kept then list.incoming[#list.incoming + 1] = kept end
	end
	-- Swapped whole, never merged: a half-arrived list drawn as if it were the
	-- whole one is a picker missing rows with nothing to say so.
	if payload.done ~= true then return false end
	list.rows, list.incoming = list.incoming, {}
	list.loaded = true
	list.error = type(payload.error) == 'string' and payload.error or nil
	return true
end

-- Takes a session or a refreshed access map.
local function adopt(payload)
	session = {
		access = type(payload.access) == 'table' and payload.access or {},
		aclKnown = payload.aclKnown == true,
		inventory = payload.inventory == true,
	}
end

--- Registers the menu key and wires the events the menu draws from.
-- @author dop42
function Menu.Start()
	local configured = M.Section('KEYS')
	Keys.Register(Keys.MENU, 'admin.key.menu', Keys.Setting('KEYS.MENU', configured.MENU, 'F9'),
		pressed, nil, function() return playerDown end)

	Keys.OnChanged(Menu.Refresh)

	RegisterNetEvent(M.Event.OPEN, function(payload)
		if type(payload) ~= 'table' then return end
		M.Target.Access(payload)
		local wanted = landing
		landing = nil
		if wanted and Client.NowMs() - wanted.atMs > LANDING_MS then wanted = nil end
		-- The opener toggles: running it again with the menu up closes it.
		if #stack > 0 and not suspended and wanted == nil then return Menu.Close() end
		if Client.Contract('menu') == nil then
			Client.Toast('admin.client.menuMissing', nil, 'error')
			return
		end
		adopt(payload)
		catalog.rows, catalog.incoming, catalog.loaded, catalog.error = {}, {}, false, nil
		Forms.Close()
		stack = { { screen = 'root' } }
		suspended = false
		if wanted then return land(wanted) end
		draw()
	end)

	RegisterNetEvent(M.Event.ACCESS, function(payload)
		if type(payload) ~= 'table' or type(payload.access) ~= 'table' then return end
		M.Target.Access(payload)
		if session == nil then return end
		local hadInventory = session.inventory
		adopt(payload)
		if session.inventory and not hadInventory then
			askFor('items')
		end
		draw(true)
	end)

	RegisterNetEvent(M.Event.ITEMS, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		local done = collect(catalog, payload, function(entry)
			if type(entry.name) ~= 'string' then return nil end
			return { name = entry.name, label = tostring(entry.label or entry.name),
				category = tostring(entry.category or 'misc'),
				weapon = entry.weapon == true, ammo = entry.ammo == true }
		end)
		local screen = Menu.Screen()
		if done and (screen == 'itemCategories' or screen == 'itemList' or screen == 'weaponList'
			or screen == 'ammoList') then
			draw(true)
		end
	end)

	RegisterNetEvent(M.Event.BAG, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.target ~= bag.target then return end
		local done = collect(bag, payload, function(entry)
			local slot, amount = tonumber(entry.slot), tonumber(entry.count)
			if slot == nil or amount == nil or type(entry.name) ~= 'string' then return nil end
			return { slot = math.floor(slot), count = math.floor(amount), name = entry.name,
				label = tostring(entry.label or entry.name) }
		end)
		if done and Menu.Screen() == 'bag' then draw(true) end
	end)

	RegisterNetEvent(M.Event.CHARACTERS, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		-- The tag, exactly as the bag above it: an answer for a player the operator
		-- has already moved on from is dropped rather than drawn as this one's.
		if payload.target ~= chars.target then return end
		local done = collect(chars, payload, function(entry)
			if type(entry.citizenId) ~= 'string' or entry.citizenId == '' then return nil end
			-- Rebuilt field by field rather than kept: everything on this payload
			-- is drawn, and a row that carried a table where a label belongs would
			-- reach the menu contract and be refused there -- taking the whole
			-- screen with it, because a spec is refused whole.
			return {
				citizenId = entry.citizenId,
				firstName = type(entry.firstName) == 'string' and entry.firstName or nil,
				lastName = type(entry.lastName) == 'string' and entry.lastName or nil,
				gender = type(entry.gender) == 'string' and entry.gender or nil,
				job = type(entry.job) == 'string' and entry.job or nil,
				gang = type(entry.gang) == 'string' and entry.gang or nil,
				createdAt = type(entry.createdAt) == 'string' and entry.createdAt or nil,
				lastLoggedOut = type(entry.lastLoggedOut) == 'string' and entry.lastLoggedOut or nil,
				active = entry.active == true or nil,
				live = entry.live == true or nil,
			}
		end)
		-- Both screens: the list draws the rows and the one below it draws a single
		-- row out of the same store, so a refresh after a rename redraws either.
		local screen = Menu.Screen()
		if done and (screen == 'playerCharacters' or screen == 'character') then draw(true) end
	end)

	RegisterNetEvent(M.Event.FOUND, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		-- THE TAG, and here it is the question rather than a player: an answer to
		-- a term the operator has already retyped, or to the page they have already
		-- turned past, is dropped rather than drawn under the one they are on.
		if payload.tag ~= absent.tag then return end
		local done = collect(absent, payload, function(entry)
			if type(entry.citizenId) ~= 'string' or entry.citizenId == '' then return nil end
			-- Rebuilt field by field, as the character list above is and for the
			-- same reason: a table where a label belongs reaches the menu contract
			-- and is refused there, taking the whole screen with it.
			return {
				citizenId = entry.citizenId,
				account = type(entry.account) == 'string' and entry.account or nil,
				firstName = type(entry.firstName) == 'string' and entry.firstName or nil,
				lastName = type(entry.lastName) == 'string' and entry.lastName or nil,
				gender = type(entry.gender) == 'string' and entry.gender or nil,
				job = type(entry.job) == 'string' and entry.job or nil,
				gang = type(entry.gang) == 'string' and entry.gang or nil,
				createdAt = type(entry.createdAt) == 'string' and entry.createdAt or nil,
				lastLoggedOut = type(entry.lastLoggedOut) == 'string' and entry.lastLoggedOut or nil,
				-- Slot numbers, not flags: the page draws the id of whoever is
				-- holding the row so an operator can go and deal with them.
				live = tonumber(entry.live),
				online = tonumber(entry.online),
			}
		end)
		if not done then return end
		-- Read off the completing chunk and only once the swap has happened, so a
		-- half-arrived page can never leave a `more` row pointing past its own list.
		absent.more = payload.more == true
		absent.cursor = type(payload.cursor) == 'string' and payload.cursor or nil
		absent.seenAt = type(payload.seenAt) == 'string' and payload.seenAt or nil
		-- Both screens, as the character list does: the page below this one draws
		-- a single row out of the same store.
		local screen = Menu.Screen()
		if screen == 'offlineChars' or screen == 'character' then draw(true) end
	end)

	RegisterNetEvent(M.Event.ROSTER, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.offset == 0 then rosterIncoming = {} end
		for _, entry in ipairs(payload.rows) do
			local id = tonumber(type(entry) == 'table' and entry.id or nil)
			if id and type(entry.name) == 'string' then
				rosterIncoming[#rosterIncoming + 1] = {
					id = id, name = entry.name,
					-- Both optional: a slot with no character loaded sends neither.
					user = type(entry.user) == 'string' and entry.user or nil,
					citizenId = type(entry.citizenId) == 'string' and entry.citizenId or nil,
					bucket = tonumber(entry.bucket) or 0,
					distance = tonumber(entry.distance),
					state = (entry.state == 'up' or entry.state == 'down' or entry.state == 'gate')
						and entry.state or 'loading',
				}
			end
		end
		if payload.done ~= true then return end
		roster, rosterById = rosterIncoming, {}
		rosterIncoming = {}
		for _, entry in ipairs(roster) do rosterById[entry.id] = entry end
		local screen = Menu.Screen()
		if screen == 'root' or (screen and screen:match('^player')) then draw(true) end
	end)

	RegisterNetEvent(M.Event.LOCATIONS, function(payload)
		if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.offset == 0 then locationsIncoming = {} end
		for _, entry in ipairs(payload.rows) do
			if type(entry) == 'table' and type(entry.name) == 'string'
				and entry.name:match('^[%w_%-]+$') then
				locationsIncoming[#locationsIncoming + 1] = { name = entry.name,
					label = tostring(entry.label or entry.name), runtime = entry.runtime == true }
			end
		end
		if payload.done ~= true then return end
		locations, locationsIncoming = locationsIncoming, {}
		local screen = Menu.Screen()
		if screen == 'locations' or screen == 'saved' then draw(true) end
	end)

	AddEventHandler(M.Event.ON_DOWNED, function(payload)
		if type(payload) ~= 'table' then return end
		playerDown = payload.down == true
	end)

	-- A poll, because a screen closes down several paths and none of them is an
	-- event this module could listen to.
	job = OPX.Scheduler.Every('admin.menu.upkeep', UPKEEP_MS, function()
		syncSuspend()
		rescueDraw()
	end)

	local downed = Client.Contract('downed')
	if downed ~= nil then
		local answer = downed.IsDown()
		if answer.ok then playerDown = answer.value.down == true end
	end
end

--- Cancels the upkeep pass.
-- @author dop42
function Menu.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
end
