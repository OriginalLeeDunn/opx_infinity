--- The picker, one screen at a time, and its two keys.
-- @author dop42
--
-- Each screen is its own `Open` on the menu contract, NOT one sub-menu tree: the
-- whole catalogue in a single spec went past the host's 1024-value bound on an
-- export call, which dropped the call without a word and left the key doing
-- nothing. The screen stack is kept here, a page of PAGE_ROWS at a time.
--
-- Do not fold the screens back into one tree.
--
-- A LONG LIST IS PAGED, NOT CUT. With the platform's catalogue adopted the
-- picker offers a hundred-odd emotes, and `Every emote` alone is seven screens of
-- PAGE_ROWS. A page ends with a row to the next, as the staff menu's do, and
-- Back steps a page back.
--
-- A SCREEN IS BUILT ON ITS OWN THREAD and yields as it walks the catalogue:
-- the client gives one resume a fixed instruction budget, and a key press or a
-- menu callback that built a hundred rows inline is the outage the staff menu
-- already had (`modules/admin/client/menu.lua`, `breathe`). The callback only
-- queues the draw.
--
-- The picker is optional: without the menu contract every command, key and
-- contract function still works, and its absence costs one logged line a session.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Opt = M.Opt
local Runtime = M.Runtime
local Keys = M.Keys

M.Picker = {}
local Picker = M.Picker

-- What the menu contract records as this module's own: the owner is how it tells
-- two callers apart, and the id names this particular menu.
local OWNER = 'animations'
local SPEC_ID = 'animations.picker'

-- Stable mapping ids; a player's rebind is stored under them.
local KEY_PICKER = 'opx.animations.picker'
local KEY_STOP = 'opx.animations.stop'

-- Rows one page of a list draws. Sixteen, not the staff menu's twenty: these
-- rows carry a description and a family, and the menu's install of a full
-- screen after its last paced step is what sets the ceiling.
local PAGE_ROWS = 16

-- Rows a builder walks between two yields, on the draw thread only.
local BREATHE_EVERY = 8
local breaths = 0
local onDrawThread = false

-- Gives the frame back every BREATHE_EVERY rows while a screen is built on the
-- draw thread. Anywhere else a builder runs straight.
local function breathe()
	breaths = breaths + 1
	if breaths % BREATHE_EVERY ~= 0 then return end
	if onDrawThread and type(Wait) == 'function' then Wait(0) end
end

-- Emotes a screen must offer before it is worth searching. Under this the list
-- is shorter than the search box would be useful for, and a box over six rows
-- is a row in the way.
local SEARCH_FROM = 8

-- The longest query the box takes.
local MAX_QUERY = 32

-- How often an open picker checks whether the player has gone down.
local DOWN_MS = 500

-- Screens from the root down; empty while the picker is down.
local stack = {}

-- Handle of the menu screen this file has up, and the stack entry it draws.
local handle, shown = nil, nil

-- Whether the missing menu was already logged this session.
local warned = false

-- The scheduler handle of the down watch.
local downJob = nil

-- Handle of the search box while one is up.
local formHandle

-- Forward-declared: the menu spec carries this callback, and it is written below
-- the drawing it calls back into. `onForm` is the same for the search box.
local onRow
local onForm

-- Calls one function of a contract. Answers its value, or a failure code;
-- `menu_not_running` is the one the player is told about by name.
local function on(contract, name, ...)
	local api = OPX.Api.Get(contract)
	if api == nil or type(api[name]) ~= 'function' then return nil, contract .. '_not_running' end
	local ran, answer = pcall(api[name], ...)
	if not ran then
		Open77.log.error(('[animations] %s %s raised: %s')
			:format(contract, name, tostring(answer)))
		return nil, 'menu_raised'
	end
	if type(answer) ~= 'table' then return nil, 'malformed_answer' end
	if answer.ok ~= true then return nil, tostring(answer.error or 'refused') end
	return answer.value or answer, nil
end

-- Calls one function of the menu contract.
local function call(name, ...)
	return on('menu', name, ...)
end

-- Whether the menu contract is there to draw with.
local function available()
	local api = OPX.Api.Get('menu')
	return api ~= nil and type(api.Open) == 'function'
end

-- Whether the player is down right now, read from the contract at the moment of
-- use. Without the contract nobody is down.
local function isDown()
	local api = OPX.Api.Get('downed')
	if api == nil or type(api.IsDown) ~= 'function' then return false end
	local ran, answer = pcall(api.IsDown)
	if not ran or type(answer) ~= 'table' or answer.ok ~= true then return false end
	return type(answer.value) == 'table' and answer.value.down == true
end

-- The Back row every screen below the root ends with. A screen is its own menu,
-- so the menu's own back row closes it with `back`, which is what steps us up.
local function backRow()
	return { id = 'back', label = locale('animations.picker.back'), back = true, icon = 'back' }
end

-- A row that plays or stops. With CLOSE_ON_SELECT the handler closes the menu
-- itself: a row carrying the menu's own `close` flag becomes a row that ONLY
-- closes, and its data would never reach the handler.
local function choice(id, label, data, extra)
	local item = { id = id, label = label, data = data }
	for key, value in pairs(extra or {}) do item[key] = value end
	return item
end

-- A row that opens another screen.
--
-- `submenu = true` is what puts the `>` in the affordance column. This picker
-- holds its own screen stack -- one `Open` per screen, never one nested spec,
-- for the reason at the top of this file -- so the menu contract cannot see that
-- these rows lead anywhere and could not derive the arrow itself. Without the
-- flag, `Gestures` and `Stop` drew identically.
local function go(id, label, screen, arg, value, icon)
	return { id = id, label = label, value = value, icon = icon, submenu = true,
		data = { go = screen, arg = arg } }
end

-- A separator row, with a heading when one is given.
local function section(key)
	return { separator = true, label = key and locale(key) or nil }
end

-- One page of a long list: the rows above it as given, PAGE_ROWS of the list,
-- and a row to the next page. Answers the rows and the page title suffix.
local function paged(head, list, page, build)
	local pages = math.max(1, math.ceil(#list / PAGE_ROWS))
	page = math.min(math.max(math.floor(tonumber(page) or 1), 1), pages)
	local items = head
	local first = (page - 1) * PAGE_ROWS + 1
	for position = first, math.min(#list, first + PAGE_ROWS - 1) do
		breathe()
		items[#items + 1] = build(list[position])
	end
	if page < pages then
		items[#items + 1] = { id = 'more', label = locale('animations.picker.more'),
			value = ('%d/%d'):format(page + 1, pages), icon = 'arrow', submenu = true,
			data = { page = page + 1 } }
	end
	return items, pages > 1 and (' %d/%d'):format(page, pages) or ''
end

-- ── the search ──────────────────────────────────────────────────────────────
--
-- THE SAME ANSWER THE STAFF MENU GIVES, for the same reason. The strip reads six
-- keys and no letters, so the one surface that takes typed text is the form: the
-- search row opens one, and the word comes back as a screen of its own rather
-- than as a filter over the screen underneath -- a search here crosses the
-- categories, and `smoke` is in one of them and `cigar` in another.

-- Whether an emote's words match the query: case-insensitive, plain substring,
-- and every word of the query has to appear. Plain `find`, never a pattern -- a
-- typed `(` is a character and not syntax.
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

-- The search row, or nothing at all on a list too short to need it.
local function searchRow(total, query)
	if query == nil and total < SEARCH_FROM then return nil end
	return { id = 'search', label = locale('animations.picker.search'), icon = 'search',
		value = query, description = locale('animations.picker.searchHint'),
		data = { search = true, query = query } }
end

-- Screen builders, each answering a title and its rows. A builder that lists
-- takes the page it is on.
local SCREENS = {}

-- What a row says under its name about where the body goes. A layer walks; a
-- workspot holds the player where they stand, and one authored against
-- furniture plays on nothing -- the platform's own device is the chair.
local function placementHint(entry)
	if entry.kind == 'layer' then return locale('animations.picker.walkable') end
	local placement = entry.placement
	if placement == nil or placement == 'standing' then return nil end
	local key = 'animations.placement.' .. placement
	return OPX.Locale.Exists(key) and locale(key) or nil
end

-- One emote's row: the variant straight away when it has only one, and the
-- variant screen when it has several. `value` carries the count so a row that
-- leads somewhere says how far, and the category is named on a screen that mixes
-- categories -- which is only the search result and `all`.
local function entryRow(entry, withCategory)
	local label = Catalogue.Label(entry)
	local variants = Runtime.Variants(entry.name)
	local aside = withCategory and locale('animations.category.' .. entry.category) or nil
	if #variants == 1 then
		return choice(entry.name, label, { name = entry.name, variant = variants[1] },
			{ icon = entry.icon, value = aside, description = placementHint(entry) })
	end
	local row = go(entry.name, label, 'variants', entry.name,
		aside and ('%s  %d'):format(aside, #variants) or tostring(#variants), entry.icon)
	row.description = placementHint(entry)
	return row
end

SCREENS.root = function()
	local stopKey = Keys.Effective(KEY_STOP)
	local everything = Runtime.Entries(nil)
	local items = {
		section('animations.picker.section.current'),
		choice('stop', locale('animations.picker.stop'), { stop = true }, {
			icon = 'ban',
			description = stopKey and locale('animations.picker.stopHintKey', { key = stopKey })
				or locale('animations.picker.stopHint'),
		}),
	}

	-- The search box and the flat list stand together above the categories: they
	-- are the two ways INTO the catalogue that are not a category, and a player
	-- who knows the word they want should not have to guess which family it is
	-- filed under first.
	local search = searchRow(#everything, nil)
	if search ~= nil or #everything > 0 then
		items[#items + 1] = section('animations.picker.section.find')
		if search ~= nil then items[#items + 1] = search end
		items[#items + 1] = go('all', locale('animations.picker.all'), 'all', nil,
			tostring(#everything), 'list')
	end

	-- WITH SOMEBODY ELSE, apart from the families: these are not emotes of the
	-- player's own body but an invitation, and they are only drawn when the
	-- server could offer one.
	local duos = Runtime.Duos()
	if #duos.kinds > 0 or #duos.pairs > 0 or (duos.any and #everything > 0) then
		items[#items + 1] = section('animations.picker.section.together')
		items[#items + 1] = go('duo', locale('animations.picker.duo'), 'duo', nil, nil, 'person')
	end

	local categories = {}
	for index = 1, #Catalogue.CATEGORIES do
		local category = Catalogue.CATEGORIES[index]
		-- A category with nothing offered is not drawn.
		local offered = Runtime.Entries(category)
		if #offered > 0 then
			categories[#categories + 1] = go(category, locale('animations.category.' .. category),
				'category', category, tostring(#offered),
				Catalogue.CATEGORY_ICONS[category] or 'emote')
		end
	end
	if #categories > 0 then items[#items + 1] = section('animations.picker.section.categories') end
	for _, item in ipairs(categories) do items[#items + 1] = item end
	return locale('animations.picker.title'), items
end

SCREENS.category = function(category, page)
	local entries = Catalogue.IsCategory(category) and Runtime.Entries(category:lower()) or {}
	local items, suffix = paged({}, entries, page, function(entry)
		return entryRow(entry, false)
	end)
	local title = Catalogue.IsCategory(category) and
		locale('animations.category.' .. category:lower()) or locale('animations.picker.title')
	return title .. suffix, items
end

SCREENS.all = function(_, page)
	local entries = Runtime.Entries(nil)
	local head = {}
	local search = searchRow(#entries, nil)
	if search ~= nil then
		head[1] = search
		head[2] = section()
	end
	local items, suffix = paged(head, entries, page, function(entry)
		return entryRow(entry, true)
	end)
	return locale('animations.picker.all') .. suffix, items
end

SCREENS.search = function(query, page)
	local entries = Runtime.Entries(nil)
	local matching = {}
	for _, entry in ipairs(entries) do
		-- The category word is part of the haystack: `social` finds what is filed
		-- under it, which is the answer a player typing a family name expects
		-- rather than "nothing matches that". So is the platform's own English
		-- label beside the translated one, and the profile id a command takes.
		if matches(query, entry.name, Catalogue.Label(entry), entry.label,
			locale('animations.category.' .. entry.category)) then
			matching[#matching + 1] = entry
		end
	end
	-- The box stays at the top of its own result, holding the word it found them
	-- with and the count it found: searching again is one row away, and Back --
	-- the row every screen below the root ends with -- is how the search is left.
	local box = searchRow(#entries, query)
	box.value = ('%s  %d/%d'):format(query, #matching, #entries)
	local items, suffix = paged({ box, section() }, matching, page, function(entry)
		return entryRow(entry, true)
	end)
	if #matching == 0 then
		items[#items + 1] = { id = 'none', label = locale('animations.picker.noMatch'),
			disabled = true, icon = 'info' }
	end
	return ('%s: %s%s'):format(locale('animations.picker.search'), query, suffix), items
end

SCREENS.variants = function(name, page)
	local entry = Runtime.Offered(name)
	-- An offer that landed while the screen was stacked can have dropped it.
	if entry == nil then return locale('animations.picker.title'), {} end
	local variants = Runtime.Variants(name)
	local items, suffix = paged({}, variants, page, function(variant)
		return choice('v' .. variant,
			locale('animations.picker.variant', { index = variant }),
			{ name = entry.name, variant = variant },
			{ icon = entry.icon,
				value = Opt.SHOW_VARIANT_WORDS and entry.words[variant] or nil })
	end)
	return Catalogue.Label(entry) .. suffix, items
end

-- ── with a nearby player ────────────────────────────────────────────────────
--
-- EVERY PAIR THE PLATFORM CAN PLAY, without listing ten thousand rows. The
-- coordinator's own kinds and the configured shortcuts are rows of their own;
-- "any two" is two picks through the same families as the solo picker -- the
-- asker's animation, then the other player's, with "the same" on top -- so
-- every ordered pair of offered profiles is two screens and one page away.
-- A pick carries no variant: the coordinator plays a profile, not a clip.

-- The label of a profile name, or the name itself when this client lacks it.
local function profileLabel(name)
	local entry = Catalogue.Entry(name)
	return entry and Catalogue.Label(entry) or name
end

-- The label of a paired kind, or of a shortcut: its own, or its two profiles.
local function kindLabel(id)
	return locale('animations.duo.kind.' .. id)
end
local function pairLabel(pair)
	local key = 'animations.duo.name.' .. pair.id
	if OPX.Locale.Exists(key) then return locale(key) end
	return locale('animations.duo.both', { mine = profileLabel(pair.actor),
		theirs = profileLabel(pair.target) })
end

SCREENS.duo = function()
	local items = {}
	local duos = Runtime.Duos()
	if #duos.kinds > 0 then items[#items + 1] = section('animations.picker.section.paired') end
	for position = 1, #duos.kinds do
		local id = duos.kinds[position]
		items[#items + 1] = choice('kind_' .. id, kindLabel(id), { duo = { kind = id } },
			{ icon = 'person', description = locale('animations.duo.kindHint.' .. id) })
	end
	if #duos.pairs > 0 then items[#items + 1] = section('animations.picker.section.shortcuts') end
	for position = 1, #duos.pairs do
		local pair = duos.pairs[position]
		items[#items + 1] = choice('pair_' .. pair.id, pairLabel(pair), { duo = { pair = pair.id } },
			{ icon = 'person', description = locale('animations.duo.hint') })
	end
	if duos.any and #Runtime.Entries(nil) > 0 then
		items[#items + 1] = section('animations.picker.section.any')
		items[#items + 1] = go('any', locale('animations.duo.any'), 'duopick', '',
			tostring(#Runtime.Entries(nil)), 'emote')
		items[#items].description = locale('animations.duo.anyHint')
	end
	return locale('animations.picker.duo'), items
end

-- A pick's screen argument is a STRING, `<mine>:<category>`, either part
-- empty: a table per row would be a dozen more nodes on every screen for the
-- menu to copy and send, and profile names never carry a colon.
local function pickArg(mine, category)
	return ('%s:%s'):format(mine or '', category or '')
end
local function readPick(arg)
	local mine, category = tostring(arg or ''):match('^([%l%d_]*):?([%l%d_]*)$')
	mine = mine ~= nil and mine ~= '' and Runtime.Offered(mine) and mine or nil
	category = category ~= nil and Catalogue.IsCategory(category) and category or nil
	return mine, category
end

-- The families to pick from, for the asker (no `mine` yet) or for the other
-- player (`mine` the asker's pick), with "the same" first in the second.
SCREENS.duopick = function(arg)
	local mine = readPick(arg)
	local items = {}
	if mine ~= nil then
		items[#items + 1] = choice('same', locale('animations.duo.same',
			{ name = profileLabel(mine) }), { duo = { actor = mine, target = mine } },
			{ icon = 'person', description = locale('animations.duo.hint') })
		items[#items + 1] = section()
	end
	local everything = Runtime.Entries(nil)
	items[#items + 1] = go('all', locale('animations.picker.all'), 'duolist', pickArg(mine, nil),
		tostring(#everything), 'list')
	for index = 1, #Catalogue.CATEGORIES do
		local category = Catalogue.CATEGORIES[index]
		local offered = Runtime.Entries(category)
		if #offered > 0 then
			items[#items + 1] = go(category, locale('animations.category.' .. category), 'duolist',
				pickArg(mine, category), tostring(#offered),
				Catalogue.CATEGORY_ICONS[category] or 'emote')
		end
	end
	local title = mine and locale('animations.duo.theirs', { name = profileLabel(mine) })
		or locale('animations.duo.mine')
	return title, items
end

-- One family, or every emote, as picks: the asker's leads to the second
-- screen, the other player's sends the invitation.
SCREENS.duolist = function(arg, page)
	local mine, category = readPick(arg)
	local entries = Runtime.Entries(category)
	local items, suffix = paged({}, entries, page, function(entry)
		local label = Catalogue.Label(entry)
		local aside = category == nil and locale('animations.category.' .. entry.category) or nil
		if mine == nil then
			return go(entry.name, label, 'duopick', pickArg(entry.name, nil), aside, entry.icon)
		end
		return choice(entry.name, label, { duo = { actor = mine, target = entry.name } },
			{ icon = entry.icon, value = aside })
	end)
	local title = category and locale('animations.category.' .. category)
		or locale('animations.picker.all')
	return title .. suffix, items
end

-- Takes the search box down, if one is up.
local function closeForm()
	if formHandle == nil then return end
	local closing = formHandle
	formHandle = nil
	on('form', 'Close', closing)
end

-- Takes the menu down and KEEPS the screen stack, which is what putting a form
-- over it needs. The close lands on `onRow` naming a handle this file no longer
-- holds, and is dropped there rather than emptying the stack.
local function suspend()
	local closing = handle
	handle, shown = nil, nil
	if closing ~= nil then call('Close', closing, 'picker') end
end

-- Closes whatever screen of ours is up and forgets the stack. Only ever closes
-- what this file opened: a caller cannot close another module's menu.
local function takeDown()
	local closing, waiting = handle, #stack > 0
	handle, shown, stack = nil, nil, {}
	closeForm()
	if closing ~= nil then call('Close', closing, 'picker') end
	return closing ~= nil or waiting
end

-- Tells the player why the picker is not up. A log line alone would leave the
-- key looking broken.
local function refused(failure)
	if failure == 'menu_busy' then return Runtime.Notify('info', 'animations.picker.busy') end
	if failure == 'menu_not_running' then return Runtime.Refuse('menu_not_running') end
	Runtime.Notify('warning', 'animations.picker.failed')
end

-- WHERE THE CURSOR STARTS on a screen nothing has been chosen on yet. The
-- contract's rule is "the first row it can stand on", which lands on the search
-- box once a screen carries one -- and the box is the way into a list, not the
-- list. Skipped, so Enter opens the first emote.
local function firstBelowHead(items)
	for _, item in ipairs(items) do
		if not item.separator and not item.disabled and item.id ~= 'search' then return item.id end
	end
	return nil
end

-- Builds the top screen and puts it up, or rebuilds the open one in place.
local function drawNow(inPlace)
	local current = stack[#stack]
	if current == nil then return end
	local title, items = SCREENS[current.screen](current.arg, current.page)
	-- BUILT, THEN HANDED OVER IN A FRESH RESUME: the menu checks and installs
	-- the rows on this thread too, and the two together are past the budget on
	-- a full screen.
	if onDrawThread and type(Wait) == 'function' then Wait(0) end
	-- The builder yields, and the player can close the picker or step away
	-- while it does: a screen that is no longer on top is not drawn. Whatever
	-- moved the stack queued its own draw.
	if stack[#stack] ~= current then return end
	if #stack > 1 then items[#items + 1] = backRow() end

	if inPlace then
		if handle == nil then return end
		local _, failure = call('Update', handle, { title = title, items = items,
			yield = onDrawThread })
		if failure ~= nil then
			Open77.log.debug('[animations] picker not redrawn: ' .. failure)
		end
		return
	end

	local result, failure = call('Open', {
		owner = OWNER,
		id = SPEC_ID,
		title = title,
		on = onRow,
		cursor = current.cursor or firstBelowHead(items),
		items = items,
		-- On the draw thread the menu checks the rows a few at a time with a
		-- frame between, rather than all of them inside this resume.
		yield = onDrawThread,
	})
	if result == nil then
		Open77.log.warn(('[animations] picker %s did not open: %s')
			:format(current.screen, tostring(failure)))
		refused(failure)
		-- A refused open replaces nothing: fall back to the screen still shown
		-- when it is ours, and take everything down otherwise.
		for depth = #stack, 1, -1 do
			if handle ~= nil and stack[depth] == shown then
				for above = #stack, depth + 1, -1 do stack[above] = nil end
				return
			end
		end
		takeDown()
		return
	end
	handle, shown = result.handle, current
end

-- Whether a draw is waiting, whether every waiting ask was an in-place one, and
-- since when a draw thread has been running. A thread a budget killer unwound
-- never clears `drawingSince`, so one older than DRAW_STALE_MS is presumed dead
-- and a new one takes over rather than the picker never drawing again.
local drawQueued, drawQueuedInPlace, drawingSince = false, true, nil
local DRAW_STALE_MS = 2000

-- Puts the top screen up, or rebuilds the open one in place -- on a thread of
-- its own, ONE AT A TIME and looping while asks keep arriving, as the staff
-- menu draws. The caller returns at once, whatever the screen costs to build.
local function draw(inPlace)
	if type(CreateThread) ~= 'function' then return drawNow(inPlace) end
	drawQueuedInPlace = drawQueuedInPlace and inPlace == true
	drawQueued = true
	local now = OPX.Now()
	if drawingSince ~= nil and now - drawingSince < DRAW_STALE_MS then return end
	drawingSince = now
	CreateThread(function()
		while drawQueued do
			local place = drawQueuedInPlace
			drawQueued, drawQueuedInPlace = false, true
			drawingSince = OPX.Now()
			onDrawThread = true
			local ran, failure = pcall(drawNow, place)
			onDrawThread = false
			if not ran then
				drawingSince = nil
				Open77.log.error('[animations] picker draw raised: ' .. tostring(failure))
				return
			end
		end
		drawingSince = nil
	end)
end

-- Stacks a screen and draws it.
local function push(screen, arg, page)
	stack[#stack + 1] = { screen = screen, arg = arg, page = page }
	draw()
end

-- Steps up a screen, closing the picker from the root.
local function pop()
	if #stack <= 1 then
		takeDown()
		return
	end
	stack[#stack] = nil
	draw()
end

-- Puts the search box up over the screen that asked for it. A box that cannot
-- be opened is a logged line and the screen coming straight back: the form
-- contract is as optional here as the menu one, and the picker still works
-- without it -- it is one row that does nothing rather than a picker that will
-- not open.
local function openSearch(query)
	suspend()
	local spec = {
		owner = OWNER,
		id = 'animations.search',
		title = locale('animations.picker.search'),
		description = locale('animations.picker.searchHint'),
		fields = {
			{ id = 'query', label = locale('animations.picker.searchField'),
				value = query, maxLength = MAX_QUERY },
		},
		on = onForm,
	}
	local result, failure = on('form', 'Open', spec)
	if result == nil then
		formHandle = nil
		Open77.log.debug('[animations] the search box did not open: ' .. tostring(failure))
		draw()
		return
	end
	formHandle = result.handle
end

-- Takes the word the box was given and shows what it found.
local function filter(query)
	local typed = type(query) == 'string' and OPX.String.Trim(query) or ''
	local current = stack[#stack]
	if current == nil then return end
	if typed == '' then
		-- AN EMPTY BOX IS HOW A SEARCH IS LEFT. Submitting nothing from a result
		-- screen drops it and brings back the screen it was opened from; from
		-- anywhere else it changes nothing at all.
		if current.screen == 'search' then stack[#stack] = nil end
		return draw()
	end
	if current.screen == 'search' then
		-- Searching again REPLACES the result rather than stacking a second one:
		-- Back has to lead out of the search, not back through every word tried.
		current.arg, current.cursor = typed, nil
		return draw()
	end
	push('search', typed)
end

--- Opens the picker at the root, or on a named category.
-- A screen of ours already up is replaced. The root is stacked under the named
-- category with its cursor on that row, so Back lands there; a category with
-- nothing offered has no row and opens the root.
-- @author dop42
-- @param category string|nil
-- @return table
function Picker.Open(category)
	if isDown() then return { ok = false, error = 'player_down' } end
	if Runtime.Locked() then return { ok = false, error = 'animation_locked' } end
	if not available() then
		if not warned then
			warned = true
			Open77.log.warn('[animations] no menu contract: no picker, the commands and the ' ..
				'animations contract still work')
		end
		return { ok = false, error = 'menu_not_running' }
	end
	if category ~= nil and not Catalogue.IsCategory(category) then
		return { ok = false, error = 'unknown_category' }
	end
	local named = category and category:lower() or nil
	stack = { { screen = 'root', cursor = named } }
	if named ~= nil and #Runtime.Entries(named) > 0 then
		stack[2] = { screen = 'category', arg = named }
	end
	draw()
	return { ok = true, queued = true }
end

--- Closes the picker this file opened.
-- @author dop42
-- @return table
function Picker.Close()
	if not takeDown() then return { ok = false, error = 'picker_not_open' } end
	return { ok = true, queued = true }
end

--- Whether a picker screen of ours, or its search box, is up.
-- The box counts: while one is up the strip is down and `handle` is nil, and a
-- key that read only the handle would open a SECOND picker over the form.
-- @author dop42
-- @return boolean
function Picker.IsOpen()
	return handle ~= nil or formHandle ~= nil
end

-- Navigates, plays or stops for a row the menu raised. The shape is checked
-- because the menu also raises every action on its own public bus.
onRow = function(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= SPEC_ID then
		return
	end
	if payload.action == 'close' then
		-- A close for a screen this file has already replaced can land after the
		-- new handle; it is not ours to act on.
		if payload.reason == 'reopened' or payload.handle ~= handle then return end
		handle = nil
		-- Back on a one-level screen would close it; step up instead.
		if payload.reason == 'back' and #stack > 1 then return pop() end
		stack = {}
		return
	end
	-- A row arriving from a screen that is closing is ignored while down: a
	-- navigation would reopen one.
	if payload.action ~= 'select' or isDown() then return end

	local data = payload.data
	local current = stack[#stack]
	if type(data) ~= 'table' or current == nil then return end
	current.cursor = payload.itemId
	if data.search == true then
		return openSearch(type(data.query) == 'string' and data.query or nil)
	end
	-- The next page is the same screen pushed again, so Back is a page back.
	if type(data.page) == 'number' then return push(current.screen, current.arg, data.page) end
	if data.go == 'all' then return push('all', nil) end
	if data.go == 'duo' then return push('duo', nil) end
	-- The two picks of "any two" and the solo screens alike take a string, read
	-- again by the screen against the offer, so a forged one draws nothing.
	if (data.go == 'category' or data.go == 'variants' or data.go == 'duopick'
		or data.go == 'duolist') and type(data.arg) == 'string' then
		return push(data.go, data.arg)
	end

	-- Taken down before the request, so the key opens rather than closes and the
	-- refusal toast is not raised under a menu.
	if Opt.CLOSE_ON_SELECT then takeDown() end
	if data.stop == true then
		local stopped = Runtime.Stop('picker')
		if stopped.error == 'animation_locked' then Runtime.Refuse(stopped.error) end
		return
	end
	if type(data.duo) == 'table' then
		local asked = Runtime.Duo(data.duo)
		if not asked.ok then Runtime.Refuse(asked.error) end
		return
	end
	local result = Runtime.Play(data.name, { variant = data.variant }, 'picker', nil)
	if not result.ok then Runtime.Refuse(result.error) end
end

-- What the search box answered. A cancel brings the screen back exactly as it
-- was; a submit is a query, and an empty one is how a search is left.
onForm = function(payload)
	if type(payload) ~= 'table' then return end
	-- An answer about a box this file no longer holds belongs to whatever
	-- replaced it, and is not ours to act on.
	if formHandle ~= nil and payload.handle ~= nil and payload.handle ~= formHandle then return end
	formHandle = nil
	if #stack == 0 then return end
	if payload.action ~= 'submit' or type(payload.values) ~= 'table' then return draw() end
	filter(payload.values.query)
end

-- Toggles the picker from its key.
local function pickerPressed()
	if Picker.IsOpen() then
		Picker.Close()
		return
	end
	local result = Picker.Open(nil)
	if not result.ok then Runtime.Refuse(result.error) end
end

-- Stops the local player's animation from the stop key. Nothing in progress is
-- not a refusal, and is not a request either.
--
-- NOTHING PLAYING SAYS NOTHING AND SENDS NOTHING. X is shared -- the progress
-- cancel, a call's decline and hang-up, the crate drop -- and every one of those
-- presses also sent a stop to the server, spending the player's request window,
-- and answered "the animation is locked" over the progress bar's own animation
-- the same press had just cancelled.
local function stopPressed()
	if not Runtime.Playing() then return end
	local result = Runtime.Stop('key')
	if not result.ok then Runtime.Refuse(result.error) end
end

-- The stop key's claim on a shared X: the player's own emote, below a bar, a
-- ringing call and a carried crate, above a call merely going on.
local function stopWants()
	if Runtime.Playing() then return OPX.Spots.Key.Rank('EMOTE') end
	return nil
end

--- Clears the screen stack.
-- @author dop42
function Picker.Init()
	stack, handle, shown, warned, downJob = {}, nil, nil, false, nil
	formHandle = nil
	drawQueued, drawQueuedInPlace, drawingSince, onDrawThread = false, true, nil, false
end

--- Registers both keys, the row channel and the down watch.
-- @author dop42
function Picker.Start()
	Keys.Register(KEY_PICKER, 'animations.key.picker', Opt.KEY_PICKER, pickerPressed)
	Keys.Register(KEY_STOP, 'animations.key.stop', Opt.KEY_STOP, stopPressed, stopWants)

	RegisterNetEvent(M.Event.PICKER, function(category)
		if type(category) ~= 'string' or category == '' then category = nil end
		local result = Picker.Open(category)
		if not result.ok then Runtime.Refuse(result.error) end
	end)

	-- The Stop row names the stop key, so a rebind redraws an open root in
	-- place; the menu keeps the cursor across an update.
	Keys.OnChanged(function()
		local current = stack[#stack]
		if handle == nil or current == nil or current.screen ~= 'root' or not available() then
			return
		end
		draw(true)
	end)

	-- The platform's catalogue lands after the hello, a few frames in: an open
	-- picker is redrawn in place so its counts and families are the offer's.
	Runtime.OnOffered = function()
		if handle ~= nil and #stack > 0 and available() then draw(true) end
	end

	-- Going down only ever closes the picker and keeps it closed; standing back
	-- up opens nothing.
	downJob = OPX.Scheduler.Every('animations:down', DOWN_MS, function()
		if handle == nil and #stack == 0 then return end
		if isDown() then takeDown() end
	end)
end

--- Closes the picker and cancels the down watch.
-- @author dop42
function Picker.Shutdown()
	if downJob ~= nil then
		OPX.Scheduler.Cancel(downJob)
		downJob = nil
	end
	takeDown()
end
