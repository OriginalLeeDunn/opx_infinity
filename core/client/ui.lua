--- The surface, the bridge to it, and the focus stack.
-- @author dop42
--
-- Twelve resources used to own a full-screen CEF surface each, ranked by a
-- hand-maintained z-index ladder from 700 to 760. One resource may have eight,
-- so a surface per feature is not an option any more -- and it was never a good
-- one: twelve browsers meant twelve copies of the same stylesheet, because each
-- WebUI runs on its own isolated origin and cannot load a file from another.
--
-- ONE surface, two layers inside the page. It was two surfaces -- an overlay and
-- an interactive layer -- and that split cost 400 kB of byte-identical duplication
-- (the Vue runtime, the design system, eight woff2 faces) for two properties: a
-- frame rate per layer, and an exception in a heavy view being unable to blank the
-- HUD. Both are given up knowingly. `fps` is fixed at creation for the whole page,
-- and the layers are now separated by a component boundary in one JS realm rather
-- than by two browsers.
--
-- `Overlay()` and `Interactive()` both answer with that one surface. Callers still
-- pass a target, because which LAYER a module draws on is still real on the page
-- side -- the overlay layer never takes a pointer.
--
-- Channel names are `opx:<module>:<verb>`. The surface id is `opx` and
-- `OPX.Surface` prefixes it, so a caller passes `character:loaded` and the page
-- sees `opx:character:loaded`.

OPX.UI = OPX.UI or {}

local ID = 'opx'
local REPLY = 'reply'

-- One surface, built on first use and kept until Teardown.
local page = nil

local focusStack = {}

-- Forward-declared: the surface's own `focus:set` reconciliation is wired inside
-- `create()`, which is written above the definition below. Without this the
-- closure there would resolve a GLOBAL of this name -- nil at call time -- and
-- the reconciliation would raise the first time the page announced a change.
local applyFocus

--- Wires every channel a view may emit before its own module is running.
--
-- THE PAGE IS BUILT BEFORE THE MODULES ARE. `core/client/boot.lua` creates the
-- surface first -- deliberately, so a module drawing from `Start` has something
-- to draw on -- and then walks the modules a FRAME AT A TIME, because `Start`
-- yields between them to reset the instruction budget. That is a window of
-- twenty-odd frames.
--
-- A view emits `opx:<module>:ready` from its `onMounted`, and `ui/src/bridge/
-- channel.ts` releases all of them in the same tick as `opx:ready`. With warm CEF
-- assets the page mounts inside the window -- which is every reconnection, and a
-- character switch ends the session -- so those signals arrived while the module
-- that answers them was still several frames from registering. There was no host
-- listener on the channel at all, so nothing was dropped by this resource: it was
-- never delivered to it. And the page says ready ONCE.
--
-- Wiring them here, against the module list rather than a hand-kept one, gives
-- every `<id>:ready` a listener from the moment the page exists. What arrives
-- with no handler yet is held by `lib/client/surface.lua` and replayed to the
-- module when it finally registers.
local function wireReadyChannels(surface)
	for _, module in ipairs(OPX.Modules.All()) do
		OPX.Surface.Wire(surface, module.Id .. ':ready')
	end
end

-- Locale keys written to the page in one `locale:set`.
--
-- THE WHOLE CATALOGUE IN ONE SEND WAS PAST THE HOST'S CEILING. It is 1,533 keys
-- and about 78 kB for one language today, and it grows with every module added:
-- `modules/inventory/client/main.lua` records that "a page write past 1,024 value
-- nodes is dropped without a word", which is why the item catalogue is drained 40
-- at a time, and `modules/inventory/server/containers.lua` sets its own budget at
-- 900. This one send was half as large again as that figure and was not chunked
-- at all.
--
-- What it cost when the host refused it: the answer was discarded, so nothing
-- knew; `useLocale.ts` answers the key on a miss, so EVERY label on EVERY surface
-- renders as its raw key for the whole session; it is sent once, from the `ready`
-- handler, with no retry. `modules/hud/client/main.lua` records players seeing
-- `hud.voice.state.idle` painted on screen, which is exactly this symptom.
-- The drain's grain, taken from the one drain that is proven live:
-- `modules/inventory/client/main.lua`'s `CATALOG_PART = 40`, on purpose. Its
-- comment is the law: an entry costs about sixty VM instructions to shape, and
-- a client handler that passes 10 000 is stopped by the host -- the same
-- figure `core/shared/lifecycle.lua` names (~10 000 instructions). Forty
-- shaped entries are ~2 400 instructions; the first attempt's 250 were
-- ~15 000 -- every part over the ceiling by itself, so the chunking died
-- exactly as the unchunked send had.
local CATALOGUE_PART = 40

-- The grain of the two cheap walks before the drain -- the merge and the key
-- list -- which copy a reference per entry rather than shaping one: main's 250,
-- ~2 500 instructions a unit, well inside the same ceiling.
local COPY_GRAIN = 250

--- Writes the locale catalogue to the page, in parts, reading every answer.
---
--- The page's boot subscribes to `locale:set` and cannot call back for a string
--- per render, so it gets the catalogue rather than a lookup. `first` clears what
--- the page holds and `done` says the last part has landed -- the same idiom
--- `modules/inventory`'s `drainCatalog` uses, and for the same reason.
---
--- ONE BOUNDED UNIT PER RESUME. A `Wait(0)` resets the per-resume instruction
--- budget (~10 000 instructions), the same argument `core/shared/lifecycle.lua`
--- makes for yielding between module `Start`s: the merge, the key list and each
--- 40-key part shaped and sent in one resume is one budget between them.
local function sendCatalogue(surface)
	local function write()
		-- ONE BOUNDED UNIT PER RESUME, each behind its own `Wait(0)`. The host
		-- stops a client handler at ~10 000 instructions -- inventory's and
		-- lifecycle's shared, live-proven figure -- and the units are sized
		-- against it: the merge, the key list, and one drained part each take
		-- a resume of their own. The first fix left the merge and the key list
		-- sharing the first part's resume, and that resume still died bare
		-- ("Open77 script execution budget exceeded", no frame) with the
		-- catalogue lost and every label rendering as its raw key.
		--
		-- THE KEY LIST IS BUILT HERE, ON THE THREAD, and yields as it goes
		-- (main's fix): it was built in the page's `ready` callback before the
		-- thread started, and a catalogue of a few thousand keys spent that
		-- callback's whole client budget. The merge itself yields as it goes too
		-- (`OPX.Locale.CatalogueSliced`).
		if type(Wait) == 'function' then Wait(0) end
		local strings = OPX.Locale.CatalogueSliced(COPY_GRAIN)
		if type(Wait) == 'function' then Wait(0) end
		local keys, counted = {}, 0
		for key in pairs(strings) do
			keys[#keys + 1] = key
			counted = counted + 1
			if counted % COPY_GRAIN == 0 and type(Wait) == 'function' then Wait(0) end
		end

		local at = 1
		local total = #keys
		while at <= total do
			if type(Wait) == 'function' then Wait(0) end
			local last = math.min(total, at + CATALOGUE_PART - 1)
			local part = {}
			for index = at, last do part[keys[index]] = strings[keys[index]] end

			local sent, refused = OPX.Surface.Send(surface, 'locale:set', {
				locale = OPX.Locale.Current(),
				strings = part,
				first = at == 1,
				done = last >= total,
			})
			-- BOTH ANSWERS. The single value this read before could not tell a
			-- part the page drew from one the host threw away, and a thrown-away
			-- part is a block of labels that render as their own keys for the
			-- session with no trace anywhere the operator can reach.
			if not sent or refused then
				Open77.log.error(('[ui] locale keys %d..%d were not written: %s')
					:format(at, last, refused and 'the host refused the payload' or 'no surface'))
				OPX.Note('ui', ('%d locale keys of %d were refused by the page; those labels '
					.. 'will render as their raw keys'):format(last - at + 1, total))
				return
			end

			at = last + 1
		end
	end

	-- On a thread, because `write` yields and this runs from a page callback.
	-- Guarded on the native rather than on the side, the way `runPhase` is: a
	-- build or a test host without `CreateThread` still gets its catalogue, just
	-- in one frame, as every build did before.
	if type(CreateThread) == 'function' then CreateThread(write) else write() end
end

--- Builds the surface from its configured layer, z-index and frame rate.
local function create()
	local settings = OPX.Config.CLIENT.SURFACE or {}
	local surface, why = OPX.Surface.Create({
		id = ID,
		entry = 'web/index.html',
		layer = settings.layer,
		zIndex = settings.zIndex,
		fps = settings.fps,
		-- Created VISIBLE, deliberately. Creation is asynchronous, and a `show()`
		-- issued straight after `create` loses the race against the `visible` flag
		-- the request carried -- the surface then never paints at all.
		visible = true,
	})
	if surface == nil then
		Open77.log.error(('[ui] the surface failed: %s'):format(tostring(why)))
		Open77.log.error('  nothing can be drawn; every view will answer no_surface.')
		-- AND IN THE SERVER'S JOURNAL. The two lines above land in a file on the
		-- PLAYER's machine, so from the server a client that can draw nothing at
		-- all is indistinguishable from a quiet one -- which is the exact
		-- confusion `OPX.Note` exists to end. One-off, boot-time and terminal is
		-- precisely what its sixty-per-session budget is for.
		OPX.Note('ui', ('the surface failed (%s): nothing can be drawn on this client')
			:format(tostring(why)))
		return nil
	end

	OPX.Surface.On(surface, 'ready', function()
		surface.ready = true
		sendCatalogue(surface)
	end)

	-- THE PAGE IS THE TRUTH ABOUT WHAT IS ON SCREEN, and this stack was only
	-- ever corrected by the modules that remembered to listen. Six of the eight
	-- owners wire `focus:set` for themselves; `inventory` and `target` do not,
	-- and `focus:set` is a property of the SURFACE, not of any one module, so it
	-- belongs here -- once -- rather than in eight copies of which two were
	-- missing.
	--
	-- What the gap cost: a render error inside a view unmounts it
	-- (`ui/src/boot/ModuleHost.vue` drops the slot on `onErrorCaptured`), the
	-- page releases its own focus and announces an empty stack, and every module
	-- handler releases only ITS OWN owners -- so nobody released `inventory`.
	-- The Lua entry stayed on top, `applyFocus` kept re-applying it, and the
	-- player was left holding keyboard and cursor with nothing drawn: no
	-- movement, a pointer on screen, and the only way out was to die.
	OPX.Surface.On(surface, 'focus:set', function(payload)
		if type(payload) ~= 'table' then return end
		local owner = payload.owner
		local top = (payload.focus == true and type(owner) == 'string') and owner or nil

		-- Nothing on the page wants focus, so nothing in Lua may keep claiming it.
		if top == nil then
			focusStack = {}
			applyFocus()
			return
		end

		-- Anything stacked ABOVE the announced top is a view the page no longer
		-- has. An owner we do not hold at all is somebody else's to acquire --
		-- their own handler does that -- so it is left alone rather than guessed at.
		local at
		for index = #focusStack, 1, -1 do
			if focusStack[index].owner == top then
				at = index
				break
			end
		end
		if at == nil then return end
		for index = #focusStack, at + 1, -1 do table.remove(focusStack, index) end
		applyFocus()
	end)

	-- Before anything can be emitted, which is the whole point: a channel wired
	-- after the page mounted is wired too late.
	wireReadyChannels(surface)

	return surface
end

--- The surface, created on first use and kept for the life of the resource.
-- @author dop42
-- @return table|nil
function OPX.UI.Surface()
	if page == nil then page = create() or false end
	return page or nil
end

-- Two names for one surface. They were two CEF pages; they are two layers of one
-- page now, and both names still answer so the modules that draw on them did not
-- have to be touched. The distinction they carry is still true -- `overlay` is the
-- layer that never takes a pointer -- it is just enforced on the page side.
OPX.UI.Overlay = OPX.UI.Surface
OPX.UI.Interactive = OPX.UI.Surface

--- Resolves a target name to the surface. There is one, so the name survives as a
--- layer hint the page reads off the channel rather than as a choice of browser.
local function surfaceOf()
	return OPX.UI.Surface()
end

--- Sends a payload to a surface.
-- Both of `OPX.Surface.Send`'s answers are forwarded, and the second is the one
-- worth knowing about: the host bounds a WebUI payload and REFUSES an oversized
-- one whole rather than truncating it, while the send itself still reports
-- success. A caller that reads one value behaves exactly as it always did.
-- @author dop42
-- @param target string 'overlay' or 'interactive'
-- @param channel string `<module>:<verb>`
-- @param payload table|nil
-- @return boolean sent
-- @return boolean refused by the host
function OPX.UI.Send(target, channel, payload)
	local surface = surfaceOf(target)
	if surface == nil then return false, false end
	return OPX.Surface.Send(surface, channel, payload)
end

--- Handles a channel the page emits. The page sends INTENTS, never facts:
--- nothing it computes is trusted, and every handler re-derives from state the
--- runtime owns.
-- @author dop42
-- @param target string
-- @param channel string
-- @param handler fun(payload: table)
-- @return boolean
function OPX.UI.On(target, channel, handler)
	local surface = surfaceOf(target)
	if surface == nil then return false end
	return OPX.Surface.On(surface, channel, function(payload)
		if type(payload) ~= 'table' then return end
		handler(payload)
	end)
end

--- Answers a request the page made. The page generates the ref and waits on it
--- with its own timeout, so an answer that never comes degrades into a rejected
--- promise rather than a view stuck forever.
-- @author dop42
-- @param target string
-- @param ref any the ref the request carried
-- @param payload table
function OPX.UI.Answer(target, ref, payload)
	if ref == nil then return end
	payload = payload or {}
	payload.ref = ref

	-- BOTH ANSWERS, for the same reason the send path above reads both: the host
	-- refuses an oversized payload WHOLE and still reports the send as a
	-- success. This direction was left out of that correction, and it is the
	-- direction a view is waiting on -- a container or a two-hundred-slot stash
	-- is exactly the answer large enough to be refused. Lua believed it had
	-- replied, the page's promise timed out five seconds later with
	-- `error.rpc_timeout`, and nothing anywhere said why: the refusal note is
	-- keyed by channel, and every reply in the session shares one channel, so
	-- one note covered every module for the rest of the session.
	--
	-- The recovery has to be a payload that cannot itself be refused, so it
	-- carries the ref and a code and nothing else. The view then shows an error
	-- instead of a spinner.
	local sent, refused = OPX.UI.Send(target, REPLY, payload)
	if sent and refused then
		Open77.log.error(('[ui] the answer to %s was refused by the host; replying with a code')
			:format(tostring(ref)))
		OPX.UI.Send(target, REPLY, { ref = ref, ok = false, error = 'error.payloadRefused' })
	end
	return sent, refused
end

-- `OPX.UI.Serve(target, channel, handler)` was here -- `On` plus a pcall plus
-- `Answer` -- and nothing in the resource called it: the two modules that answer
-- the page call `Answer` themselves, with refusals of their own. Removed rather
-- than kept as a second way to do what they already do.

--- Applies whatever is on top of the focus stack, or drops focus entirely.
---
--- It does NOT hide the surface when the stack empties. It used to, back when the
--- interactive layer was its own page and hiding it was free; the HUD lives on this
--- surface now, and hiding it would blank the health bar every time a menu closed.
--- The page inerts its own modal layer instead -- `Focus(false, false)` reaches it
--- as a focus event, and the layer drops `pointer-events` on it.
function applyFocus()
	local surface = OPX.UI.Surface()
	if surface == nil then return end

	local top = focusStack[#focusStack]
	if top == nil then
		OPX.Surface.Focus(surface, false, false)
		return
	end
	OPX.Surface.Focus(surface, top.keyboard == true, top.cursor == true)
end

--- Takes keyboard and cursor for a named owner. Stacked rather than set, so a
--- view opened over another gives focus back to it on release instead of
--- dropping it to nothing.
-- @author dop42
-- @param owner string
-- @param wants table|nil keyboard, cursor
-- @return boolean
function OPX.UI.AcquireFocus(owner, wants)
	if type(owner) ~= 'string' or owner == '' then return false end
	wants = wants or {}

	for index = 1, #focusStack do
		if focusStack[index].owner == owner then table.remove(focusStack, index) break end
	end
	focusStack[#focusStack + 1] = {
		owner = owner,
		keyboard = wants.keyboard ~= false,
		cursor = wants.cursor == true,
	}
	applyFocus()
	return true
end

--- Gives focus back. Safe for an owner that never held it.
-- @author dop42
-- @param owner string
function OPX.UI.ReleaseFocus(owner)
	for index = #focusStack, 1, -1 do
		if focusStack[index].owner == owner then table.remove(focusStack, index) end
	end
	applyFocus()
end

--- Gives every owner's focus back at once, and tells the page.
---
--- The stop path's first step, BEFORE any module stops. Leaving it to
--- `Teardown`, after `Modules.Stop`, made the one thing a player cannot recover
--- from -- keyboard and cursor held with nothing drawn -- depend on thirty
--- module `Stop`s all finishing inside the instruction budget first. It costs
--- nothing to do it early: a module releasing its own owner afterwards finds an
--- empty stack, and the page is still there for it to talk to.
-- @author dop42
function OPX.UI.ReleaseAllFocus()
	focusStack = {}
	if page then pcall(OPX.Surface.Focus, page, false, false) end
end

--- Who currently holds focus, or nil.
-- @author dop42
-- @return string|nil
function OPX.UI.FocusOwner()
	local top = focusStack[#focusStack]
	return top and top.owner or nil
end

--- Destroys the surface. The page is not replaced in place, which is why this
--- resource reloads with `reconnect`; this is the stop path, not a reload path.
-- @author dop42
function OPX.UI.Teardown()
	focusStack = {}
	if page then
		-- EMPTYING THE STACK IS NOT THE SAME AS GIVING THE FOCUS BACK. This
		-- cleared the Lua list and never applied it, and `OPX.Surface.Destroy`
		-- does not release focus either -- so the only thing standing between a
		-- stop and a player left with a cursor and no controls was every one of
		-- the eight focus owners remembering to release in its own `Stop`. They
		-- all do today; the core owes them a floor that does not depend on it,
		-- because there is no recovery from this one short of dying.
		pcall(OPX.Surface.Focus, page, false, false)
		OPX.Surface.Destroy(page)
	end
	page = nil
end
