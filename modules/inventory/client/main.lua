--- The screen: its page, its requests, the server's pushes and a confirmed use.
-- @author dop42
--
-- The server decides every change; the page predicts one and draws it, and the
-- next push corrects it. Nothing here is authoritative about anything.
--
-- The page lives on the INTERACTIVE surface (z 740), which takes the keyboard and
-- the cursor for exactly as long as the screen is up. `OPX.UI` owns the surface
-- and the focus stack; this file owns one module on it.
--
-- WHAT THIS RUNTIME DELETED. The screen used to create and own a CEF surface of
-- its own, one of twelve, each carrying its own copy of the same stylesheet
-- because a WebUI page cannot load a file from another origin. It is one module
-- on a shared surface now, and the focus it takes is a stack entry rather than a
-- `setFocus` nobody else can see.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Catalog = M.Catalog

M.Screen = {}
local Screen = M.Screen

-- The one surface this module draws on, and the owner name it takes focus under.
local SURFACE = 'interactive'
local FOCUS_OWNER = 'inventory'

-- Milliseconds before a request with no answer settles as a timeout. Above the
-- server's own bounded waits, so a slow answer arrives rather than being dropped.
local REQUEST_TIMEOUT_MS = 15000

-- Catalogue entries carried by one page write. An entry is about twenty value
-- nodes with its name, and the host REFUSES a page write past 1,024 value nodes
-- WHOLE rather than truncating it -- `lib/client/surface.lua` hands that refusal
-- back as `Send`'s second answer, and this file reads it on the open path.
--
-- AND A PART IS ONE RESUME. Shaping an entry costs ~130 VM instructions (two
-- catalogue-key lookups), so the forty a part used to carry were ~5,400 -- in
-- the scheduler's shared pass, beside up to three other jobs, where the meter
-- put the job alone at ~8,000 of a ~10,000 budget whose overrun unwinds the
-- whole pass in silence. Twenty is ~2,700, on a thread of its own.
local CATALOG_PART = 20

-- Whether the surface has been built and its channels wired, whether the page has
-- reported itself mounted, the one write that is waiting for it to, and when that
-- write started waiting.
local surfaceWired = false
local pageReady = false
local pendingOpen = nil
local pendingSince = nil

-- The handle the current opening is keyed on. A payload carrying any other handle
-- belongs to a screen that has already been replaced, and is dropped.
local handle = nil
local handleSequence = 0

local open = false
local opening = false
local openAgain = false

-- The bag the server last pushed, and the weapon the bag put in hand.
local own = nil
local held = nil

-- Requests awaiting an answer, and the last id handed out.
local waiting = {}
local nextRequest = 0

-- The generation the catalogue writer belongs to: a newer send stops an older
-- writer at its next part.
local catalogWrites = 0

local release = nil

-- Forward-declared: the open path calls it and it is defined further down, beside
-- the page channels it wires. A local declared after its caller would leave that
-- caller reading a global that is never set.
local ensureSurface

--- Writes one message to the page.
local function send(name, payload)
	if not pageReady then return false end
	return OPX.UI.Send(SURFACE, 'inventory:' .. name, payload)
end

--- Whether a payload belongs to the screen that is open now.
local function mine(payload)
	return handle ~= nil and payload.handle == handle
end

--- The words and the tabs the page draws, in the configured language.
local function labels()
	local keys = {
		'bag', 'ground', 'trunk', 'glovebox', 'stash', 'drop', 'weight', 'ammo', 'serial',
		'condition', 'use', 'split', 'dropZone', 'giveTo', 'sortWeight', 'sortName', 'close',
		'nobody', 'unknown', 'kg', 'g', 'm', 'groundHint',
		-- `character` is the eyebrow over a searched bag, which drew the raw kind;
		-- `cancel` is the split dialog's way out, which said `Close`.
		'character', 'cancel',
		-- The count dialog's give and drop questions, and its give button.
		'give', 'giveHowMany', 'dropHowMany',
		-- Where a person in the give list stands, never who they are.
		'sideAhead', 'sideBehind', 'sideLeft', 'sideRight', 'decimal',
		-- The two the page needs for its own status line. Every refusal the SERVER
		-- makes is toasted from there, so the page only ever has to say that a
		-- round trip failed or never came back.
		'failed', 'timeout',
	}
	local out = {}
	for index = 1, #keys do out[keys[index]] = locale('inventory.ui.' .. keys[index]) end

	local tabs = {}
	for index, tab in ipairs(Options.TABS) do
		tabs[index] = {
			key = tab.key,
			label = locale('inventory.tab.' .. tab.key),
			categories = tab.categories,
			rest = tab.rest,
		}
	end
	out.tabs = tabs
	return out
end

--- The words, the tabs, the hotbar keys and the open key.
-- The keys are read at send time rather than at registration: a player who
-- rebinds one gets the new cap without anything being registered again.
local function configPayload()
	local hotbar = {}
	for index = 1, Options.HOTBAR_SLOTS do
		hotbar[index] = M.Keys.Effective('opx.inventory.hotbar' .. index)
			or (Options.KEYS_HOTBAR[index] or '')
	end
	return {
		labels = labels(),
		hotbar = hotbar,
		openKey = M.Keys.Effective('opx.inventory.open') or '',
		drops = Options.DROPS,
		defaultWeight = Catalog.DefaultWeight(),
	}
end

--- Sends the page the configuration on its own, for a rebind.
-- @author dop42
function Screen.SendConfig()
	send('config', configPayload())
end

--- Writes the whole catalogue to the page in parts, one part a frame.
-- ON A THREAD OF ITS OWN, a part a resume: a client resume that passes ~10,000
-- instructions is stopped by the host, and a page write past 1,024 value nodes
-- is dropped without a word -- see `CATALOG_PART`. It used to be drained a part
-- per pass of the 500 ms screen job, inside the scheduler's shared resume; a
-- frame apiece is both cheaper per resume and sooner. A newer write (the page
-- reporting ready again) stops an older one before its next part.
local function queueCatalog()
	catalogWrites = catalogWrites + 1
	local mark = catalogWrites
	local names = Catalog.Names()
	CreateThread(function()
		local first = 1
		-- One part even for an empty catalogue: `first` and `done` together are
		-- how the page is told it holds nothing.
		repeat
			if mark ~= catalogWrites or not pageReady then return end
			local last = math.min(#names, first + CATALOG_PART - 1)
			local entries = {}
			for index = first, last do entries[names[index]] = Catalog.ViewOf(names[index]) end
			send('catalog', { entries = entries, first = first == 1, done = last >= #names })
			first = last + 1
			if first <= #names then Wait(0) end
		until first > #names
	end)
end

-- ── requests ─────────────────────────────────────────────────────────────────

--- Sends one request to the server, answered to the page, to a callback, or both.
-- @author dop42
-- @param action string
-- @param payload table|nil
-- @param callback fun(ok: boolean, code: string, data: table)|nil
-- @param ref any the page reference the answer is written back under
function Screen.Request(action, payload, callback, ref)
	nextRequest = nextRequest % 2147483646 + 1
	waiting[nextRequest] = { ref = ref, callback = callback, atMs = OPX.Now() }
	TriggerServerEvent(M.Event.REQUEST, nextRequest, action, payload or {})
end

--- Delivers one answer to the page and to the callback.
local function settle(entry, ok, code, data)
	if entry.ref ~= nil then
		-- The page waits on `opx:reply` under the ref it generated; `OPX.UI.Answer`
		-- is the channel `ui/src/bridge/rpc.ts` listens on.
		OPX.UI.Answer(SURFACE, entry.ref, { ok = ok, error = code, data = data })
	end
	if entry.callback then
		local ran, failure = pcall(entry.callback, ok, code, data)
		if not ran then Open77.log.error('[inventory] request callback: ' .. tostring(failure)) end
	end
end

--- Whether something says the local player is down.
-- The `downed` contract answers a Result carrying `{ down, waiting }`, not a
-- boolean: reading the Result itself as one makes every player permanently down,
-- because a table is truthy.
local function isDown()
	local downed = M.Contracts.downed
	if downed == nil then return false end
	local answer = downed.IsDown()
	return answer ~= nil and answer.ok == true and answer.value.down == true
end

--- Whether the screen may be up at all: not down, and not dead.
local function usable()
	if isDown() then return false end
	local character = Open77.character
	if type(character) == 'table' and type(character.isAlive) == 'function' then
		local read, alive = pcall(character.isAlive)
		if read and alive == false then return false end
	end
	return true
end

--- Whether the screen is up.
-- @author dop42
-- @return boolean
function Screen.IsOpen()
	return open
end

--- The bag the server last pushed, or nil.
-- @author dop42
-- @return table|nil
function Screen.Own()
	return own
end

--- The weapon the bag put in hand, or nil.
-- @author dop42
-- @return table|nil
function Screen.Held()
	return held
end

--- How many units of an item the bag the server last pushed holds.
-- Read off the LAST PUSH, which is the server's own copy, and never off a
-- prediction the page has drawn.
local function countOf(name)
	local bag = own
	if type(bag) ~= 'table' or type(bag.items) ~= 'table' then return 0 end
	local total = 0
	for index = 1, #bag.items do
		local entry = bag.items[index]
		if entry.name == name then total = total + (tonumber(entry.count) or 0) end
	end
	return total
end

--- Whether something says the local player is down.
-- @author dop42
-- @return boolean
function Screen.IsDown()
	return isDown()
end

-- ── opening and closing ──────────────────────────────────────────────────────

--- Takes the keyboard and the cursor for a screen the page has the payload for.
-- The page holds the keyboard as well as the cursor: the modifier gestures and
-- Escape are read there, and a held ALT must not open something else over the
-- top. Idempotent, because the open path reaches it on a refresh as well.
local function takeFocus()
	if release ~= nil then return end
	release = OPX.UI.AcquireFocus(FOCUS_OWNER, { keyboard = true, cursor = true })
		and function() OPX.UI.ReleaseFocus(FOCUS_OWNER) end
		or nil
end

--- Gives up on an open the page will never draw, and says so.
-- Both callers reach here with the screen NOT drawn, so there is nothing on
-- screen to explain the missing inventory: the toast is the only thing the
-- player gets, and the journal line is the only thing anybody debugging it gets.
local function abandonOpen(why)
	Open77.log.error(('[inventory] the open payload never reached the page (%s): the screen ' ..
		'is not drawn, so the keyboard and the cursor are not taken'):format(why))
	local line = locale('inventory.error.failed')
	if OPX.Toast.Show({ id = 'inventory.open', kind = 'error', message = line }) == nil then
		Open77.log.info('[inventory] ' .. line)
	end
	if open then
		Screen.Close()
	else
		-- The server opened a container for a screen that is not going to exist.
		Screen.Request('close')
	end
end

--- Draws the granted open answer, and takes the focus once the page has it.
--
-- THE FOCUS IS TAKEN AFTER THE PAYLOAD LANDS, NEVER BEFORE IT. The host bounds a
-- WebUI payload and REFUSES an oversized one whole -- see `CATALOG_PART` -- and
-- this write carries TWO containers plus `configPayload()`, while the server
-- bounds one container at 900 nodes and a 200-slot stash is a legal
-- configuration. So the refusal is reachable, not theoretical.
--
-- Taken first, it left the player here: keyboard and cursor acquired, `open`
-- true, and the page never sent `inventory:open` -- so its own focus stack is
-- empty, `.layer-modal` keeps `pointer-events: none`, and no Escape handler was
-- ever armed. Nothing is drawn and nothing answers, and `pass()`'s only recovery
-- is `usable()`, which is false ONLY when the player is down or dead. The way
-- out was to die.
local function show(data)
	if type(data.primary) ~= 'table' then return end
	own = data.primary
	if Screen.IsDown() then
		if not open then Screen.Request('close') end
		return
	end

	local wasOpen = open
	local drawOn = handle
	if not wasOpen then
		handleSequence = handleSequence + 1
		drawOn = ('inv%d'):format(handleSequence)
	end

	local payload = {
		handle = drawOn,
		config = configPayload(),
		primary = data.primary,
		secondary = type(data.secondary) == 'table' and data.secondary or false,
	}
	-- BOTH ANSWERS ARE READ, and reading only the first was the bug. `false` is
	-- "the page has not reported ready" -- a send then is DROPPED, not queued, so
	-- the payload is held for the handshake. The second answer is the HOST's
	-- refusal, and it comes back alongside a `true`: a caller reading one value
	-- took a payload the page never saw for one it had drawn.
	local sent, refused = send('open', payload)
	if refused then
		abandonOpen('the host refused it as too large or not serialisable')
		return
	end

	handle = drawOn
	open = true
	if sent then
		pendingOpen, pendingSince = nil, nil
		takeFocus()
	else
		pendingOpen, pendingSince = payload, OPX.Now()
	end

	if not wasOpen then TriggerEvent(M.Event.ON_OPENED) end
end

--- Closes the screen and hands the focus back.
-- @author dop42
function Screen.Close()
	if not open then return end
	open = false
	send('close', { handle = handle })
	handle = nil
	pendingOpen, pendingSince = nil, nil
	if release then release() end
	release = nil
	Screen.Request('close')
	TriggerEvent(M.Event.ON_CLOSED)
end

--- Opens the screen, optionally after a request that opens a container first.
-- `first` is sent before the open; `onlyWith` says the screen must stay closed
-- when that request is refused, which is what a world prompt wants and what the
-- open key does not.
-- @author dop42
-- @param first string|nil a request action sent before the open
-- @param payload table|nil
-- @param onlyWith boolean|nil
function Screen.Open(first, payload, onlyWith)
	if opening then return end
	if not usable() then return end
	-- The surface is built here, on the first open, and not at start: a player who
	-- never opens anything never pays for a second CEF page.
	if not ensureSurface() then return end
	opening = true

	local function settled()
		opening = false
		if not openAgain then return end
		openAgain = false
		Screen.FromServer()
	end

	local function openBag()
		Screen.Request('open', nil, function(ok, code, data)
			opening = false
			if ok then
				show(data)
			elseif code ~= 'not_ready' and code ~= 'not_loaded' then
				-- Those two are the ordinary "not in the world yet" and are silent.
				Open77.log.info('[inventory] open refused: ' .. tostring(code))
			end
			settled()
		end)
	end

	if not first then return openBag() end
	Screen.Request(first, payload, function(ok)
		if not ok and onlyWith then return settled() end
		openBag()
	end)
end

--- Opens what the server has just opened beside the bag.
-- Held back while an opening is already in flight and replayed as soon as that
-- one settles, accepted or refused: without that the screen could end up closed,
-- or open without the container the server had just put beside it -- whose push
-- is ignored while the screen is closed.
-- @author dop42
function Screen.FromServer()
	if Screen.IsDown() then return Screen.Request('close') end
	if opening then
		openAgain = true
		return
	end
	if open then
		Screen.Request('open', nil, function(ok, _, data) if ok then show(data) end end)
		return
	end
	Screen.Open()
end

-- ── what the server pushes ───────────────────────────────────────────────────

--- Units per item name in a bag payload.
local function countsOf(bag)
	local counts = {}
	local items = type(bag.items) == 'table' and bag.items or {}
	for index = 1, #items do
		local entry = items[index]
		counts[entry.name] = (counts[entry.name] or 0) + (tonumber(entry.count) or 0)
	end
	return counts
end

--- What the bag gained and lost between two pushes.
local function changesOf(previous, current)
	if not previous or previous.id ~= current.id then return {} end
	local before, after = countsOf(previous), countsOf(current)
	local changes = {}
	for name, count in pairs(after) do
		local delta = count - (before[name] or 0)
		if delta ~= 0 then changes[#changes + 1] = { name = name, delta = delta } end
	end
	for name, count in pairs(before) do
		if not after[name] then changes[#changes + 1] = { name = name, delta = -count } end
	end
	return changes
end

--- Says what the bag gained and lost, with the screen closed.
-- One replaceable toast and not a strip of its own: the interactive surface is
-- not built until the player opens something, and a running total of pickups is
-- exactly what the overlay's toast lane is for. The id is fixed, so a run of
-- pickups rewrites one toast instead of stacking a pile of them.
local function announce(changes)
	local lines = {}
	for index = 1, #changes do
		local change = changes[index]
		-- NOT THE NOTES. Every move of money as notes is told by the server, as
		-- an amount ("You took 1,000 €$ out as notes."); a "+1000 Eddies" here
		-- on top was the same withdraw on a second surface.
		if change.name ~= Options.CURRENCY_ITEM then
			lines[#lines + 1] = ('%s%d %s')
				:format(change.delta > 0 and '+' or '', change.delta, Catalog.Label(change.name))
		end
	end
	if #lines == 0 then return end
	-- THE ANSWER IS CHECKED, because it can be refused. `OPX.Toast.Show` answers
	-- nil for a surface that is not up, and this used to discard that: the notice
	-- went nowhere and said so to nobody. Six other modules already fall back to
	-- the client journal on this exact path; these three did not, and the toast's
	-- own docstring claimed they did.
	local line = table.concat(lines, '   ')
	local raised = OPX.Toast.Show({
		id = 'inventory.change',
		kind = 'info',
		message = line,
	})
	if raised == nil then Open77.log.info('[inventory] ' .. line) end
end

--- Sends another resource's client half a message, from a thread of its own.
-- Each call gets its own thread so one slow answer cannot hold up the rest; a
-- resource that is simply not running costs nothing and is not reported.
local function tell(resource, name, ...)
	local args = table.pack(...)
	CreateThread(function()
		local sent = OPX.Lib.Rpc.Call(resource, name, table.unpack(args, 1, args.n))
		if not sent.ok and sent.error ~= 'not_running' and sent.error ~= 'no_exports' then
			Open77.log.info(('[inventory] %s.%s answered %s'):format(resource, name, sent.error))
		end
	end)
end

-- Most runtime items one catalogue event may carry: what the server sends
-- (`RUNTIME_CHUNK`), and what fits one resume with every item at the
-- validator's bounds. A longer list is refused whole rather than validated past
-- the resume budget.
local MAX_RUNTIME_PART = 4

--- Takes in items another resource registered at runtime, a few at a time, and
--- rewrites the page's catalogue once they are in.
-- Each one is validated again by `Catalog.Register`, the function the server
-- ran, so a row the server took is a row this half takes too.
local function receiveCatalog(part)
	if type(part) ~= 'table' or #part > MAX_RUNTIME_PART then return end
	local taken = 0
	for index = 1, #part do
		local row = part[index]
		if type(row) == 'table' then
			local registered, why = Catalog.Register(row.name, row.definition, row.owner)
			if registered then
				taken = taken + 1
			else
				Open77.log.warn(('[inventory] runtime item %s refused: %s')
					:format(tostring(row.name), tostring(why)))
			end
		end
	end
	if taken > 0 and pageReady then queueCatalog() end
end

-- ── a give offered to this player ──────────────────────────────────────────
-- A GIVE ASKS FIRST (the owner's ruling, 2026-10): somebody in reach pressed
-- give, and the server asks this player before anything moves. What is shown is
-- the item, the count and where the giver stands -- in the #91 words the give
-- list uses, "To your left · 1.2 m" -- and never who. The answer goes back as a
-- token the server minted; it re-checks everything on a yes. An offer nobody
-- answers is withdrawn by the server after fifteen seconds.

local GIVE_MENU_OWNER = 'inventory'
local GIVE_MENU_ID = 'inventory.giveOffer'

-- The offer on screen: its token and the menu handle, or nil.
local offered = nil

-- Calls one function of the menu contract, answering its value or nil.
local function menuCall(name, ...)
	local api = OPX.Api.Get('menu')
	if api == nil or type(api[name]) ~= 'function' then return nil end
	local ran, answer = pcall(api[name], ...)
	if not ran or type(answer) ~= 'table' or answer.ok ~= true then return nil end
	return answer.value or answer
end

-- Takes the offer's menu down, if it is up.
local function closeOffer()
	local shown = offered and offered.handle or nil
	if offered ~= nil then offered.handle = nil end
	if shown ~= nil then menuCall('Close', shown, 'offer') end
end

-- Sends the answer once and forgets the offer.
local function answerOffer(accepted)
	if offered == nil then return end
	local token = offered.token
	closeOffer()
	offered = nil
	TriggerServerEvent(M.Event.GIVE_ANSWER, token, accepted == true)
end

-- The menu's rows. Shape-checked: the menu raises every action on its bus too.
local function onOfferMenu(payload)
	if type(payload) ~= 'table' or payload.owner ~= GIVE_MENU_OWNER or payload.menu ~= GIVE_MENU_ID then
		return
	end
	if offered == nil or payload.handle ~= offered.handle then return end
	if payload.action == 'close' then
		-- Closed without a choice is a no: the giver is not left waiting on a
		-- card nobody can see any more.
		offered.handle = nil
		return answerOffer(false)
	end
	if payload.action ~= 'select' or type(payload.data) ~= 'table' then return end
	answerOffer(payload.data.accept == true)
end

local SIDE_KEYS = {
	ahead = 'inventory.ui.sideAhead', behind = 'inventory.ui.sideBehind',
	left = 'inventory.ui.sideLeft', right = 'inventory.ui.sideRight',
}

-- Puts an offer in front of the player. The server's words only: nothing here
-- is read off a name.
local function onGiveOffer(token, info)
	token = math.tointeger(tonumber(token))
	if token == nil or token < 1 or type(info) ~= 'table' then return end
	local item = type(info.item) == 'string' and OPX.Text.Clean(info.item, 64, '...') or nil
	local count = math.tointeger(tonumber(info.count))
	if item == nil or count == nil or count < 1 then return end
	local distance = tonumber(info.distance)
	distance = OPX.Math.IsFinite(distance) and distance or 0
	local where = SIDE_KEYS[info.side] ~= nil
		and locale('inventory.offer.where', { side = locale(SIDE_KEYS[info.side]),
			distance = ('%.1f'):format(distance) })
		or locale('inventory.offer.nearby', { distance = ('%.1f'):format(distance) })

	-- A newer offer replaces an unanswered one; the server withdrew it.
	closeOffer()
	offered = { token = token }
	OPX.Toast.Show({ id = 'inventory.offer', kind = 'info',
		message = locale('inventory.offer.toast', { count = count, item = item }) })
	local opened = menuCall('Open', {
		owner = GIVE_MENU_OWNER,
		id = GIVE_MENU_ID,
		title = locale('inventory.offer.title'),
		on = onOfferMenu,
		cursor = 'accept',
		items = {
			{ id = 'what', label = locale('inventory.offer.what', { count = count, item = item }),
				icon = 'box', disabled = true, description = where },
			{ id = 'accept', label = locale('inventory.offer.accept'), icon = 'plus',
				data = { accept = true } },
			{ id = 'refuse', label = locale('inventory.offer.refuse'), icon = 'ban',
				data = { accept = false } },
		},
	})
	if opened ~= nil and offered ~= nil and offered.token == token then
		offered.handle = opened.handle
	end
end

-- The server withdrew the offer: it expired, or the giver left.
local function onGiveWithdrawn(token)
	token = math.tointeger(tonumber(token))
	if offered == nil or offered.token ~= token then return end
	closeOffer()
	offered = nil
	OPX.Toast.Show({ id = 'inventory.offer', kind = 'info', message = locale('inventory.offer.withdrawn') })
end

--- Registers the handlers the server pushes to.
local function registerEvents()
	RegisterNetEvent(M.Event.CATALOG, receiveCatalog)
	RegisterNetEvent(M.Event.GIVE_OFFER, onGiveOffer)
	RegisterNetEvent(M.Event.GIVE_WITHDRAWN, onGiveWithdrawn)
	RegisterNetEvent(M.Event.ANSWER, function(requestId, ok, code, data)
		local entry = waiting[requestId]
		if not entry then return end
		waiting[requestId] = nil
		settle(entry, ok == true, type(code) == 'string' and code or '',
			type(data) == 'table' and data or {})
	end)

	RegisterNetEvent(M.Event.OWN, function(payload)
		if type(payload) ~= 'table' then return end
		local changes = changesOf(own, payload)
		own = payload
		if open then
			send('update', { handle = handle, container = payload })
		elseif #changes > 0 and not Screen.IsDown() then
			announce(changes)
		end
		-- The mirror is updated BEFORE the event, so a handler reading `Own` sees
		-- the change and not the value it replaced.
		TriggerEvent(M.Event.ON_CHANGED, { inventory = payload, changes = changes })
	end)

	RegisterNetEvent(M.Event.CONTAINER, function(payload)
		if not open or type(payload) ~= 'table' then return end
		send('update', { handle = handle, container = payload })
	end)

	RegisterNetEvent(M.Event.SECONDARY, function(payload)
		if not open then return end
		send('secondary', { handle = handle,
			container = type(payload) == 'table' and payload or false })
	end)

	RegisterNetEvent(M.Event.NEARBY, function(list)
		if not open then return end
		send('nearby', { handle = handle, players = type(list) == 'table' and list or {} })
	end)

	RegisterNetEvent(M.Event.OPEN, function()
		Screen.FromServer()
	end)

	RegisterNetEvent(M.Event.RESET, function()
		Screen.Close()
		own = nil
		held = nil
		OPX.Toast.Dismiss('inventory.change')
	end)

	RegisterNetEvent(M.Event.ARMED, function(payload)
		held = type(payload) == 'table' and payload or nil
		TriggerEvent(M.Event.ON_ARMED, held)
	end)

	RegisterNetEvent(M.Event.USED, function(payload)
		if type(payload) ~= 'table' then return end
		if payload.close ~= false then Screen.Close() end

		-- NO NEEDS ARE MOVED HERE. The server adds the item's status when it
		-- consumes the unit and sends the new values to the needs module; this
		-- half only plays the gesture.

		local animation = payload.animation
		if type(animation) == 'table' and type(animation.name) == 'string' then
			-- THROUGH OUR OWN CONTRACT, AND IT USED TO BE A CALL INTO NOTHING. This
			-- read `tell('opx77_animations', 'play', ...)` -- the external resource
			-- `modules/animations` was written to replace, which this server does
			-- not load and which the manifest does not name. A cross-resource call
			-- to a resource that is not running costs nothing and says nothing, so
			-- eating an item played no animation at all and nobody could tell the
			-- difference between "the config is wrong" and "the call went nowhere".
			--
			-- The comment that was here said there was no contract to read. There
			-- is: `animations` publishes one, it takes the same four options under
			-- the same names, and it is in this runtime.
			-- THE BAR OWNS THE GESTURE, and that is why this asks `progress` rather
			-- than `animations`. A timed action is three things -- a picture of how
			-- long is left, a hold on the player, and a gesture -- and they have to
			-- begin and end together or the player is left standing in an animation
			-- with no bar, or held by a lock with nothing on screen to explain it.
			-- `progress` starts both and `finish` takes both down on every exit.
			--
			-- A DURATION IS WHAT MAKES IT A BAR. An item whose `USE.ANIMATION` names
			-- no `DURATION_MS` is a gesture and not a timed action, so it goes
			-- straight to `animations` as before -- there is nothing to count.
			local progress = OPX.Api.Get('progress')
			local animations = OPX.Api.Get('animations')

			if progress ~= nil and animation.durationMs ~= nil then
				local shown = progress.Start(FOCUS_OWNER, {
					label = payload.label or payload.name or '',
					durationMs = animation.durationMs,
					animation = { name = animation.name, variant = animation.variant },
					-- Eating is the case this was written for, and the owner's words
					-- were that the player must not be able to stop it.
					cancelable = false,
				})
				if type(shown) == 'table' and shown.ok ~= true then
					Open77.log.debug(('[inventory] the bar for %s was refused: %s')
						:format(animation.name, tostring(shown.error)))
				end
			elseif animations == nil then
				-- Optional, like every other contract this module reaches for: the
				-- item is still used and its needs still move, and only the gesture
				-- is lost. Said once rather than silently, because a missing
				-- animation is exactly what the old call failed to report.
				Open77.log.debug('[inventory] no animations contract: ' .. animation.name
					.. ' is not played')
			else
				local played = animations.Play(animation.name, {
					variant = animation.variant,
					loop = false,
					durationMs = animation.durationMs,
					cancelable = false,
				}, FOCUS_OWNER)
				if type(played) == 'table' and played.ok ~= true then
					Open77.log.debug(('[inventory] %s was refused: %s')
						:format(animation.name, tostring(played.error)))
				end
			end
		end

		TriggerEvent(M.Event.ON_USED, payload)
	end)

	-- A character leaving takes the screen and the mirror with it.
	AddEventHandler(M.Event.ON_CHARACTER_UNLOADED, function()
		Screen.Close()
		own = nil
		held = nil
	end)

	AddEventHandler(M.Event.ON_CHARACTER_LOADED, function()
		TriggerServerEvent(M.Event.HELLO)
	end)
end

--- Builds the interactive surface if it does not exist, and wires this module's
--- page channels once. Answers whether there is a surface at all.
--
-- CALLED FROM `Start`, and idempotently from the open path after it. It used to be
-- called ONLY from the open path, to keep a player who never opens anything from
-- paying for a second CEF page. That reasoning died with the page merge: there is
-- one surface now and `core/client/boot.lua` creates it BEFORE any module's
-- `Start`, so nothing is saved by wiring late -- and wiring late broke the screen
-- outright.
--
-- `inventory:ready` is emitted ONCE, from the page's `setup()`, and a channel
-- event raised before its handler exists is dropped, not queued. Wiring on first
-- open therefore always missed it: `pageReady` stayed false, `send` refused every
-- write for the life of the session, and the first open parked its payload in
-- `pendingOpen` waiting for a handshake that had already been and gone. The player
-- lost the keyboard and the cursor to a screen that was never drawn.
--
-- This is the same idiom `modules/hud/client/main.lua` uses: the ready channel is
-- wired in `Start`, which is the only phase that is guaranteed to run before the
-- page mounts.
-- @return boolean
function ensureSurface()
	if surfaceWired then return true end
	if OPX.UI.Interactive() == nil then return false end
	surfaceWired = true

	-- The page says when it has mounted. Core's `ui.lua` owns `opx:ready` and uses
	-- it to hand the page the locale catalogue; replacing that handler would leave
	-- every label rendering as its own key, so this module has a channel of its own.
	OPX.UI.On(SURFACE, 'inventory:ready', function()
		pageReady = true
		Screen.SendConfig()
		queueCatalog()
		-- A screen opened before the page had mounted: its one write was held back
		-- rather than dropped, because a send made before ready is not queued.
		--
		-- BOTH ANSWERS HERE TOO. This used to read none at all and clear the
		-- payload regardless, so a refusal on the replay lost the open for good
		-- while the screen stayed marked up -- and this is the LAST chance the
		-- payload gets, because `inventory:ready` is emitted once per page.
		if pendingOpen ~= nil then
			local replayed, refused = send('open', pendingOpen)
			pendingOpen, pendingSince = nil, nil
			if replayed and not refused then
				takeFocus()
			else
				abandonOpen(refused and 'the host refused the replay'
					or 'the replay was not sent')
			end
		end
	end)

	OPX.UI.On(SURFACE, 'inventory:request', function(payload)
		if type(payload.action) ~= 'string' then return end
		if payload.handle ~= nil and not mine(payload) then return end
		local body = type(payload.payload) == 'table' and payload.payload or {}
		if payload.action == 'drop' then
			-- The heading lets the server put the pile in front of the player rather
			-- than under them. It is the only thing the client is asked for here,
			-- and all it can do is turn the pile around a position the server owns.
			local character = Open77.character
			local read, yaw = pcall(function() return character.yaw() end)
			body.yaw = read and tonumber(yaw) or nil
		end
		Screen.Request(payload.action, body, nil, payload.ref)
	end)

	-- A channel of its own, and not the one Lua sends `close` on. One name used in
	-- both directions reads as a loop even where it is not one, and the page
	-- asking to be closed is not the same message as Lua saying it has been.
	OPX.UI.On(SURFACE, 'inventory:dismiss', function(payload)
		if payload.handle ~= nil and not mine(payload) then return end
		Screen.Close()
	end)

	return true
end

--- One pass: expires unanswered requests and closes a screen the player may no
--- longer have up.
local function pass()
	local now = OPX.Now()
	for requestId, entry in pairs(waiting) do
		if now - entry.atMs > REQUEST_TIMEOUT_MS then
			waiting[requestId] = nil
			settle(entry, false, 'timeout', {})
		end
	end

	-- A SCREEN MARKED UP THAT WAS NEVER DRAWN, and a recovery that does not need
	-- the player to die. `usable()` below goes false only when they are down or
	-- dead, so it was the only way out of an open the page never received.
	-- `inventory:ready` is emitted once per page; a payload still waiting for it
	-- a whole request timeout later is not going to be replayed.
	if pendingOpen ~= nil and pendingSince ~= nil
		and now - pendingSince > REQUEST_TIMEOUT_MS then
		abandonOpen('the page never reported ready')
	end

	if open and not usable() then Screen.Close() end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Nothing to build before the contract: the mirror is empty by definition.
-- @author dop42
function M.Init()
	M.Contracts = {}
end

--- Publishes the client half of the contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('inventory', 1, {
		Open = function() Screen.Open() end,
		Close = Screen.Close,
		IsOpen = Screen.IsOpen,

		GetInventory = Screen.Own,
		GetHeldWeapon = Screen.Held,

		GetItemCount = countOf,

		HasItem = function(name, count)
			return countOf(name) >= (Common.Integer(count, 1, Options.MAX_STACK) or 1)
		end,

		GetItem = Catalog.ViewOf,

		OpenStash = function(name)
			-- Asking only. The server checks that the player is standing at it.
			Screen.Open('openStash', { name = name }, true)
		end,
	})
end

--- Wires the page and the wire, and registers the one pass. On a coroutine.
-- @author dop42
function M.Start()
	M.Contracts.downed = OPX.Api.Get('downed')
	M.Contracts.target = OPX.Api.Get('target')

	registerEvents()

	-- FIRST, and before anything that sends. The page emits `inventory:ready` once,
	-- from its own `setup()`, and a channel event with no handler is dropped rather
	-- than queued -- so the handler has to exist before the page mounts. `Start` is
	-- the last phase that is still inside the synchronous boot pass, and
	-- `core/client/boot.lua` created the surface before that pass began, so there is
	-- no page here to pay for: it is already up.
	if not ensureSurface() then
		Open77.log.error('[inventory] there is no surface: the screen can never be drawn')
	end

	-- A FRESH RESUME BEFORE THE KEYS, AND ANOTHER BEFORE THE WORLD ROWS. This runs
	-- on the client boot thread, and a page that mounted before the modules hands
	-- its latched `inventory:ready` to the handler wired just above -- config and
	-- all, right here. With the keys and the world rows (the eye checks every row
	-- it is given) that came to ~5,100 VM instructions in one resume, 6,500 on the
	-- budget meter: the dearest of the boot, where an overrun unwinds the thread
	-- and every module after this one. `Start` may yield; under pcall for a caller
	-- that is not on a thread.
	pcall(Wait, 0)
	-- THE KEYS BEFORE THE WORLD ROWS, and the order is load-bearing rather than
	-- tidy. `Wire` registers rows with the target module, and a raise anywhere in
	-- there aborts this function -- so with the two the other way round, one bad
	-- registration cost the player the open key AND the whole hotbar, which is
	-- every way into the bag at once. It is what the budget overrun did: the
	-- screen was unreachable by any route and nothing on screen said why.
	-- Nothing in `Register` needs a world row, so it goes first and survives.
	M.Keys.Register()
	M.Slotbar.Wire()
	pcall(Wait, 0)
	M.World.Wire()

	OPX.Scheduler.Every('inventory.screen', 500, pass)

	TriggerServerEvent(M.Event.HELLO)
end

--- Gives the focus back unconditionally.
-- A cursor left captured through a stop leaves the player unable to move, which
-- is worse than any state this module could be leaving behind.
-- @author dop42
function M.Stop()
	closeOffer()
	offered = nil
	open = false
	pageReady = false
	handle = nil
	OPX.UI.ReleaseFocus(FOCUS_OWNER)
end
