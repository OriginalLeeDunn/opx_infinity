--- The machinery the three modal views share: `menu`, `form` and `panel`.
-- @author dop42
--
-- Each of the three carried its own copy of the same things: the id checks,
-- the payload node counter, the slider step, the focus responder and the
-- down / sweep / pause lifecycle around its one open view. Three copies drift --
-- "a view opened from inside a close callback is orphaned" was fixed in all
-- three separately -- so they live here once, and each module keeps only what
-- is its own: its spec, its frame and its contract.
--
-- Nothing here holds a view. A module hands `New` the functions that read and
-- close its own, and the set answers for the lifecycle around it.

OPX.Modal = {}

-- ── ids ─────────────────────────────────────────────────────────────────────

--- Whether a value is a bounded identifier: word characters, `_`, `:`, `-`, `.`.
-- What `menu` and `form` hold an owner, a view id and a row or field id to.
-- @author dop42
-- @param value any
-- @param maximum integer
-- @return boolean
function OPX.Modal.ValidName(value, maximum)
	return type(value) == 'string' and #value > 0 and #value <= maximum
		and value:match('^[%w_:%-%.]+$') ~= nil
end

--- Whether a value is an identifier: non-empty text without control characters.
-- `panel`'s looser rule: its ids are the caller's own item keys, not names.
-- @author dop42
-- @param value any
-- @param maximum integer
-- @return boolean
function OPX.Modal.ValidId(value, maximum)
	return type(value) == 'string' and #value > 0 and #value <= maximum
		and not value:find('%c')
end

-- ── the payload bound ───────────────────────────────────────────────────────
--
-- The host discards an event carrying more than 1024 value nodes and says
-- nothing. A node is the value itself and both halves of every pair under a
-- table, counted the way the host counts them.

--- Walks a table, counting into `budget.nodes` until `budget.ceiling`.
--
-- A SCALAR IS COUNTED IN PLACE, NOT THROUGH A CALL. A row's `data` is walked
-- inside the one resume `Open` or `Update` runs in, and a call per key and per
-- value was the dearest part of checking a menu spec: about 150 instructions a
-- row. Only a nested table recurses; the count and the limits are the same.
local function walk(value, depth, budget)
	local ceiling = budget.ceiling
	local nodes = budget.nodes + 1
	if nodes > ceiling then
		budget.nodes = nodes
		return false
	end
	if type(value) ~= 'table' then
		budget.nodes = nodes
		return true
	end
	if depth > budget.depth then
		budget.nodes = nodes
		return false
	end
	for key, nested in pairs(value) do
		if type(key) == 'table' then
			budget.nodes = nodes
			if not walk(key, depth + 1, budget) then return false end
			nodes = budget.nodes
		else
			nodes = nodes + 1
			if nodes > ceiling then
				budget.nodes = nodes
				return false
			end
		end
		if type(nested) == 'table' then
			budget.nodes = nodes
			if not walk(nested, depth + 1, budget) then return false end
			nodes = budget.nodes
		else
			nodes = nodes + 1
			if nodes > ceiling then
				budget.nodes = nodes
				return false
			end
		end
	end
	budget.nodes = nodes
	return true
end

--- Whether a value fits `ceiling` nodes, nested no deeper than `depth` tables,
--- and the nodes counted getting there (stopped at the first past the ceiling).
--
-- A FLAT TABLE IS COUNTED IN ONE LOOP, two nodes a pair, which is every menu
-- row's `data` in practice; the first table met inside hands the count to the
-- full walk from the start. A flat table of n pairs is 1 + 2n nodes either way.
-- @author dop42
-- @param value any
-- @param ceiling number
-- @param depth number|nil the deepest table counted; nil for no bound
-- @return boolean
-- @return integer
function OPX.Modal.Fits(value, ceiling, depth)
	depth = depth or math.huge
	if type(value) == 'table' and depth >= 1 then
		local nodes = 1
		for key, nested in pairs(value) do
			if type(nested) == 'table' or type(key) == 'table' then
				local budget = { nodes = 0, ceiling = ceiling, depth = depth }
				return walk(value, 1, budget), budget.nodes
			end
			nodes = nodes + 2
			-- Stopped where the walk would stop: at the key, when it was the key.
			if nodes > ceiling then return false, nodes - 1 > ceiling and nodes - 1 or nodes end
		end
		if nodes > ceiling then return false, nodes end
		return true, nodes
	end
	local budget = { nodes = 0, ceiling = ceiling, depth = depth }
	return walk(value, 1, budget), budget.nodes
end

--- What a value costs, counted whole.
-- @author dop42
-- @param value any
-- @return integer
function OPX.Modal.Nodes(value)
	local _, nodes = OPX.Modal.Fits(value, math.huge, nil)
	return nodes
end

-- A caller's opaque table -- a menu row's `data`, a menu's, a form's -- is held
-- to this many nodes and this many tables deep: room for what a caller needs to
-- know which row it was, and not a channel to ship a payload through.
OPX.Modal.DATA_NODES = 64
OPX.Modal.DATA_DEPTH = 4

--- Validates a caller's opaque table whole, answering `notTable`, `tooLarge`
--- or nil. Absent is fine.
--
-- THE FLAT CASE IS COUNTED HERE, NOT THROUGH `Fits`: this runs once a menu row,
-- inside the caller's resume, and a second call a row was most of what the
-- shared counter cost over the inline one. The count and the refusal are the
-- same: 1 + 2n nodes for n pairs, and the full walk for anything nested.
-- @author dop42
-- @param value any
-- @param notTable string
-- @param tooLarge string
-- @return string|nil
function OPX.Modal.DataFault(value, notTable, tooLarge)
	if value == nil then return nil end
	if type(value) ~= 'table' then return notTable end
	local ceiling = OPX.Modal.DATA_NODES
	local nodes = 1
	for key, nested in pairs(value) do
		if type(nested) == 'table' or type(key) == 'table' then
			local budget = { nodes = 0, ceiling = ceiling, depth = OPX.Modal.DATA_DEPTH }
			if not walk(value, 1, budget) then return tooLarge end
			return nil
		end
		nodes = nodes + 2
		if nodes > ceiling then return tooLarge end
	end
	return nil
end

-- ── sliders ─────────────────────────────────────────────────────────────────

-- Whether a value is a number that is neither NaN nor infinite.
local finite = OPX.Math.IsFinite

--- Validates a slider's range and settles its step and starting value. The
--- suffix is the caller's: `menu` cuts one and `form` refuses one.
-- @author dop42
-- @param slider any
-- @return table|nil `{ min, max, step, value }`
-- @return string|nil the refusal
function OPX.Modal.SliderRange(slider)
	if type(slider) ~= 'table' then return nil, 'invalid_slider' end
	local low = finite(slider.min) and slider.min + 0.0 or 0.0
	local high = finite(slider.max) and slider.max + 0.0 or 100.0
	if high <= low then return nil, 'invalid_slider_range' end
	local step = finite(slider.step) and math.abs(slider.step) + 0.0 or 1.0
	if step <= 0 then step = 1.0 end
	local value = finite(slider.value) and slider.value + 0.0 or low
	if value < low then value = low end
	if value > high then value = high end
	return { min = low, max = high, step = step, value = value }
end

--- Steps a settled slider by `delta` steps, answering whether it moved.
-- @author dop42
-- @param slider table
-- @param delta integer
-- @return boolean
function OPX.Modal.StepSlider(slider, delta)
	local before = slider.value
	local value = slider.value + (slider.step * delta)
	-- Clamped, never wrapped: a volume that jumps from 0 to 100 is a
	-- complaint, not a feature.
	if value < slider.min then value = slider.min end
	if value > slider.max then value = slider.max end
	-- Snapped back onto the step grid after every move, because 0.1 added
	-- ten times is not 1.0.
	local steps = math.floor(((value - slider.min) / slider.step) + 0.5)
	value = slider.min + (steps * slider.step)
	if value > slider.max then value = slider.max end
	slider.value = value
	return value ~= before
end

-- ── focus ───────────────────────────────────────────────────────────────────

--- The answer to the surface-wide focus broadcast, for one module's owners.
--
-- THE BROADCAST NAMES THE WHOLE STACK'S TOP, NOT JUST "EMPTY OR NOT", and
-- reading only the empty case was the incomplete half of this idiom.
-- `ui/src/bridge/focus.ts` announces on EVERY change to the page's focus stack,
-- carrying the one owner now on top -- so a top that moved from one of OURS to
-- somebody else's arrives here as `focus = true` with an owner this module does
-- not know. The stale Lua entry then sat above the module actually on screen
-- and `applyFocus` applied ITS wants: the chat line's `cursor = false` over the
-- inventory's `cursor = true`, with the inventory drawn and the cursor gone.
--
-- The answer: release every owner of mine that is NOT the announced one, then
-- acquire the announced one if it is mine. `focus` is read at every broadcast,
-- so a module that rewrites what an owner is granted (`menu`, per open) is
-- answered with what it holds now.
-- @author dop42
-- @param focus table owner -> `{ keyboard, cursor }`
-- @return function the `focus:set` handler
function OPX.Modal.FocusResponder(focus)
	return function(payload)
		if type(payload) ~= 'table' then return end
		local owner = payload.owner
		local held = (payload.focus == true and type(owner) == 'string') and owner or nil
		for name in pairs(focus) do
			if name ~= held then OPX.UI.ReleaseFocus(name) end
		end
		local wants = held ~= nil and focus[held] or nil
		if wants == nil then return end
		OPX.UI.AcquireFocus(held, wants)
	end
end

-- ── the lifecycle around one open view ──────────────────────────────────────

--- The down state, the owner sweep, the pause key and the upkeep pass around
--- one module's single open view.
-- @author dop42
-- @param options table
--   name      string    the module: the log tag, and the pause key's layer
--   current   function  () -> the open view's record, or nil; a record carries
--             `owner`, and `openedAtMs` for the layer
--   close     function  (reason) closes the open view
--   settings  function  () -> the module's settings, read for `WHILE_DOWN`
--   pauseKey  string    the host's Escape event
--   pause     function  (record) Escape as the top layer, with a view open
--   job       string    the upkeep job's name
--   everyMs   integer   how often it runs
--   upkeep    function  (record) the module's own part of a pass, before the sweep
-- @return table the set: `Reset()`, `IsDown()`, `AllowedWhileDown(owner)`,
--   `Blocked(owner)`, `FromPage(payload)`, `Supersede(reason)`, `Start()`
function OPX.Modal.New(options)
	local name = options.name
	local current, close = options.current, options.close
	local down, downHeard = false, 0
	local set = {}

	--- Forgets the down state; the module's `Init`.
	function set.Reset()
		down, downHeard = false, 0
	end

	--- Whether the player is down.
	function set.IsDown()
		return down
	end

	--- Whether an owner's view opens, and stays open, while the player is down.
	function set.AllowedWhileDown(owner)
		local allowed = options.settings().WHILE_DOWN
		return type(allowed) == 'table' and allowed[owner] == true
	end

	--- Whether the player being down refuses an owner's view.
	function set.Blocked(owner)
		return down and not set.AllowedWhileDown(owner)
	end

	--- The open view a page payload is about, or nil for a late one. Every
	--- payload carries the handle this module minted; one naming another is
	--- about a view that has already gone.
	function set.FromPage(payload)
		local record = current()
		if record == nil or type(payload) ~= 'table' then return nil end
		if payload.handle ~= record.handle then return nil end
		return record
	end

	--- Takes the open view down for a newer one.
	--
	-- THE CLOSE CALLBACK MAY OPEN ANOTHER. The old owner hears its close
	-- synchronously, and an owner that answers a close by opening its next view
	-- installed it here -- then the open overwrote it: a live handle nobody
	-- could close, its close never raised, its polling and focus left behind.
	-- What the callback opened is closed in turn; the open is the newer ask.
	function set.Supersede(reason)
		if current() == nil then return end
		close(reason)
		if current() ~= nil then close('superseded') end
	end

	-- Closes a view whose owner is a module that has stopped. Only a declared
	-- module is swept: an owner this runtime knows nothing about is left alone
	-- rather than guessed at.
	local function sweepOwner()
		local record = current()
		if record == nil then return end
		local owner = OPX.Modules.Record(record.owner)
		if owner ~= nil and owner.State ~= 'started' then close('owner_stopped') end
	end

	-- Holds the down flag and closes a view not allowed to stay up.
	local function setDown(value)
		down = value == true
		local record = current()
		if down and record ~= nil and not set.AllowedWhileDown(record.owner) then
			close('player_down')
		end
	end

	-- Catches up once with a player who went down before the module started.
	-- A state heard while the read was in flight is newer than the read, and wins.
	local function adoptDownState()
		local downed = OPX.Api.Get('downed')
		if downed == nil then return end
		local heard = downHeard
		local answer = downed.IsDown()
		if not answer.ok then
			Open77.log.warn(('[%s] the downed contract did not answer: %s')
				:format(name, tostring(answer.error)))
			return
		end
		if downHeard ~= heard then return end
		setDown(answer.value.down == true)
	end

	--- Wires the down state, the pause key and the upkeep pass; the module's
	--- `Start`.
	--
	-- Escape is swallowed by the plugin before any surface sees it, and arrives
	-- on the pause key instead. ONLY AS THE TOP LAYER (`OPX.Spots.Key.Layer`): a
	-- view under another opened after it stays.
	function set.Start()
		AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed'), function(payload)
			if type(payload) ~= 'table' then return end
			downHeard = downHeard + 1
			setDown(payload.down == true)
		end)

		local layer = OPX.Spots.Key.Layer(name, function()
			local record = current()
			return record and record.openedAtMs
		end)
		AddEventHandler(options.pauseKey, function()
			if not OPX.Spots.Key.TopLayer(layer) then return end
			local record = current()
			if record ~= nil then options.pause(record) end
		end)

		local upkeep = options.upkeep
		OPX.Scheduler.Every(options.job, options.everyMs, function()
			local record = current()
			if record == nil then return end
			upkeep(record)
			sweepOwner()
		end)

		adoptDownState()
	end

	return set
end
