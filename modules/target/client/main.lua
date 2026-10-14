--- The eye: the held key, the screen ray under the cursor, the row list and the pick.
-- @author dop42
--
-- WHERE THE WORK IS BOUNDED, because this is the module that proved it matters.
--
-- Holding the key and pressing the RIGHT button asks every row that matches what
-- the ray hit whether it applies. A row whose owner is another resource answers
-- over a host call, and the original did all of them inside one coroutine body.
-- That body exceeded the per-resume instruction budget, which unwinds straight out
-- of the coroutine and never resumes it -- no crash, no repeat, nothing logged.
-- Three things keep that from coming back and none of them is optional:
--
--   1. a pick is resolved in SLICES of `BATCH` rows, one slice per scheduler pass,
--      each on its own one-shot thread that ends when the slice does;
--   2. an owner's liveness is cached for `ALIVE_CACHE_MS` and the registry sweeps
--      ONCE per batch, not once per row;
--   3. `MAX_PER_OWNER` bounds how much any one owner can add to the walk.
--
-- The scheduler is the other half of it: there is no `CreateThread` loop here at
-- all. `OPX.Scheduler.Every` runs the repeating jobs, and the only threads this
-- file spawns are one-shot bodies for work that has to yield on a promise.
--
-- TWO of those jobs stand for the session -- `target:sweep` and `target:watch` --
-- and the third, `target:resolve`, exists only while a pick is in flight. The
-- slicing above is what makes it the fastest job in the resource, and a job at
-- that interval sets the floor on how often the one client loop wakes; leaving it
-- registered between picks bought forty passes a second of reading a nil. See
-- `setPending`.

local M = OPX.Modules.Get('target')
local Model = M.Model
local Result = OPX.Result

-- The key mapping id the pause menu lists.
local KEY_ID = 'opx.target.activate'

-- The surface the page draws on, and this module's name on its focus stack.
local SURFACE = 'interactive'
local FOCUS = 'target'

-- The public client bus: what another resource listens to with a bare
-- AddEventHandler. It must stay on the LOCAL channel -- the host dispatcher
-- matches on the name alone, so a local raise on a NET name would re-enter a
-- network handler of the same name.
local EVENT_OPENED = OPX.Event(OPX.Channel.LOCAL, 'target', 'opened')
local EVENT_CLOSED = OPX.Event(OPX.Channel.LOCAL, 'target', 'closed')
local EVENT_SELECTED = OPX.Event(OPX.Channel.LOCAL, 'target', 'selected')

-- What `downed` raises when the player goes down or gets back up.
local EVENT_DOWNED = OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed')

-- Milliseconds two picks must be apart.
local PICK_GAP_MS = 150

-- Milliseconds an owner's running answer is reused. A start or a stop forgets it
-- at once, so this only ever delays noticing a reload.
local ALIVE_CACHE_MS = 500

-- What a module id is stamped with in place of a generation. A module lives in
-- this VM: it has no resource generation, so it is never swept for a reload it
-- cannot have had. Only stopping takes its rows away.
local IN_PROCESS = 'module'

-- Settings, read in Init so a config change does not need a code change.
local KEY, BLOCK_WEAPON_WHEEL, RAY_DISTANCE, MAX_OPTIONS = 'ALT', true, 12.0, 32
local HOVER_MS, WATCH_MS, RESOLVE_MS, SWEEP_MS = 90, 50, 25, 2000
local REVALIDATE_MS, LOOKUP_BUDGET_MS, BATCH = 200, 1500, 5

-- Whether the key is held and the eye is up.
local opened = false

-- Whether this module actually took the control restrictions, so that `close`
-- does not hand back restrictions it never took.
local heldControls = false

-- Whether a pick or a select is being worked out.
local busy = false

-- The handle the page echoes on every message. One per open; a message carrying
-- any other handle is a message from a session that has gone.
local handle = nil
local sequence = 0

-- Bumped on every open, pick, select and close, so a late answer is dropped. The
-- page never sees it: the handle is the page's guard, this is Lua's.
local request = 0

-- What the listed rows were built for.
local selection

-- Tokens of the rows on screen, the only ones a select may name.
local listed = {}

-- Whether the key was released since the last open. The host reports a captured
-- key as up, so this is what keeps one press from reopening the eye forever.
local armed = true

-- Milliseconds of the last pick and the last hover look, and of the next check
-- that the picked target is still there.
local lastPick, lastHover, nextCheck = -math.huge, -math.huge, 0

-- Owners that switched targeting off, to the generation that did.
local disabledBy = {}

-- Whether `downed` says the player is on the floor.
local down = false

-- Owner to its generation and when that was read.
local liveness = {}

-- The pick being resolved, or nil: request, context, queue, at, rows, listed,
-- budget and whether a slice's thread is running. Written only through
-- `setPending`, which is what keeps the resolve job alive for exactly as long as
-- there is a pick to slice.
local pending = nil

-- The resolve job's handle while a pick is in flight, and the job body itself,
-- declared here because `setPending` is needed above the point `resolve` can be
-- written -- `close` clears a pick, and `close` comes before the slicing.
local resolveJob = nil
local resolve

-- Scheduler handles, so Stop takes the jobs down with the module.
local jobs = {}

--- Sets the pick being resolved, registering the job that slices it and dropping
--- that job again the moment there is nothing to slice.
---
--- WHY RESOLVE IS NOT A STANDING JOB. `pending` is nil except between a right
--- button press and the last slice of that press: a fraction of a second, a few
--- times a minute. Registered for the session at RESOLVE_MS it was the fastest
--- interval in the resource, so it set the floor on how often the one client loop
--- woke at all -- forty passes a second, every one of them to read a nil and
--- return. The scheduler is built for exactly this: `Cancel` drops a job at the
--- next pass rather than leaving a hole, so a job may follow the thing it serves.
---
--- THE SLICING IS UNTOUCHED. While a pick is in flight the job is registered at
--- the same RESOLVE_MS and hands `slice` the same BATCH rows per pass. This
--- decides only whether the job exists when there is no pick, and the budget
--- margin during one is the margin it always was.
-- @author dop42
-- @param job table|nil
local function setPending(job)
	pending = job
	if job ~= nil then
		if resolveJob == nil then
			resolveJob = OPX.Scheduler.Every('target:resolve', RESOLVE_MS, resolve)
		end
		return
	end
	if resolveJob ~= nil then
		OPX.Scheduler.Cancel(resolveJob)
		resolveJob = nil
	end
end

-- Reads the generation an owner is on, or nil when it is not running. A module in
-- this VM answers the sentinel; a separate resource answers the host's number, so
-- a reload leaves its rows behind.
local function readGeneration(owner)
	if OPX.Modules.IsRunning(owner) then return IN_PROCESS end
	local record = OPX.Modules.Record(owner)
	-- `started` is only stamped once EVERY module's Start has run, so a module
	-- registering its rows from its own Start is still `declared` here. Without
	-- this it would be refused by nothing but the boot order.
	if record ~= nil then return record.State == 'declared' and IN_PROCESS or nil end
	local read, state = pcall(GetResourceState, owner)
	if not read or state ~= 'running' then return nil end
	local resource = Open77.resource
	if type(resource) ~= 'table' or type(resource.generation) ~= 'function' then return IN_PROCESS end
	local got, current = pcall(resource.generation, owner)
	if not got or current == nil then return IN_PROCESS end
	return current
end

-- The generation an owner is on now, read at most twice a second.
local function generationOf(owner)
	if type(owner) ~= 'string' or owner == '' then return nil end
	local at = OPX.Now()
	local known = liveness[owner]
	if known == nil or at - known.at > ALIVE_CACHE_MS then
		known = { at = at, generation = readGeneration(owner) }
		liveness[owner] = known
	end
	return known.generation
end

-- Whether an owner still runs the generation that registered.
local function alive(owner, generation)
	local current = generationOf(owner)
	return current ~= nil and current == generation
end

--- Every row every owner registered.
M.Registry = Model.New(alive)
local Registry = M.Registry

-- Writes one message to the page. False means there is no surface, or the page
-- has not reported ready, which is a refusal and not a retry.
local function send(channel, payload)
	return OPX.UI.Send(SURFACE, channel, payload)
end

-- The key the player bound, or the configured one.
local function key()
	return OPX.Lib.Input.KeyFor(KEY_ID) or KEY
end

-- Whether the target key is down.
local function held()
	return OPX.Lib.Input.IsDown(key())
end

-- The character state when it stands in the world alive, or nil.
local function living()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.state) ~= 'function' then return nil end
	local read, state = pcall(character.state)
	if not read or type(state) ~= 'table' or not state.attached or not state.alive then return nil end
	if type(state.health) ~= 'number' or state.health <= 0 or type(state.position) ~= 'table' then return nil end
	return state
end

-- Whether this client can pick at all. Without a screen ray there is no eye, and
-- the registry is the only half of the module that still works.
local function canPick()
	return OPX.Lib.Native.Reach('camera.screenRaycast') ~= nil
		and OPX.Lib.Native.Reach('input.cursor') ~= nil
end

-- Holds or hands back aim, shooting, interaction and the camera. Every one of
-- these needs `players.controls`; without the permission the eye refuses to open
-- rather than opening over live controls.
--
-- ALL OR NOTHING. The four were applied in one chain, so a later one that raised
-- or refused (a build without `freezeRotation`, a host that said no) left the
-- earlier ones applied -- while `heldControls` stayed false, so `close` never
-- gave them back: aim, shooting and interaction stayed off for the session,
-- and every later press of the key took them again. All four are now checked
-- present before any is touched, and a step that fails undoes the ones before
-- it, each by its own inverse (never `resetControls`, which would also clear
-- what another module holds).
local HOLD_STEPS = {
	{ name = 'allowAim', take = false, give = true },
	{ name = 'allowShoot', take = false, give = true },
	{ name = 'allowInteraction', take = false, give = true },
	{ name = 'freezeRotation', take = true, give = false },
}

local function controls(hold)
	local players = Open77.players
	if type(players) ~= 'table' then return false end
	if not hold then
		if type(players.resetControls) == 'function' then pcall(players.resetControls) end
		return true
	end
	for index = 1, #HOLD_STEPS do
		if type(players[HOLD_STEPS[index].name]) ~= 'function' then return false end
	end
	for index = 1, #HOLD_STEPS do
		local step = HOLD_STEPS[index]
		local called, applied = pcall(players[step.name], step.take)
		if not called or not applied then
			for back = index - 1, 1, -1 do
				local undo = HOLD_STEPS[back]
				pcall(players[undo.name], undo.give)
			end
			return false
		end
	end
	return true
end

-- The hold on its own, for the suite: opening the eye needs a screen ray, a
-- cursor and a held key, none of which is what is under test there.
M.HoldControls = controls

--- Takes the eye down and hands the cursor, camera and weapons back.
-- @author dop42
-- @param reason string
local function close(reason)
	request = request + 1
	local was = opened
	opened, busy, selection, listed = false, false, nil, {}
	setPending(nil)
	if handle ~= nil then send('target:close', { handle = handle }) end
	handle = nil
	OPX.UI.ReleaseFocus(FOCUS)
	if not was then return end
	-- ONLY IF THEY WERE TAKEN. `controls(false)` is a global reset of this
	-- resource's control restrictions, not the inverse of what this function
	-- set, so calling it on a path that never took them hands back restrictions
	-- another module is relying on.
	if heldControls then
		controls(false)
		heldControls = false
	end
	TriggerEvent(EVENT_CLOSED, reason or 'closed')
end

-- Whether no running owner has switched targeting off.
local function targetingEnabled()
	for owner, generation in pairs(disabledBy) do
		if not alive(owner, generation) then disabledBy[owner] = nil end
	end
	return next(disabledBy) == nil
end

-- Casts the screen ray at a point and describes what it hit.
local function contextAt(x, y)
	local state = living()
	if state == nil then return nil end
	-- `world.query` is named so an operator who dropped it from the manifest gets
	-- the line to add rather than an eye that silently never opens. The Result is
	-- unwrapped straight back to nil: this is a per-frame read and every caller
	-- already treats "nothing under the cursor" the same as "could not ask".
	local cast = OPX.Lib.Native.Call('camera.screenRaycast', 'world.query',
		x, y, RAY_DISTANCE, { self = true })
	if not cast.ok or type(cast.value) ~= 'table' then return nil end
	local hit = cast.value
	hit.screen = { x = x, y = y }
	if not hit.hit then
		hit.target = { kind = 'sky', networked = false }
		hit.kind = 'sky'
		hit.playerDistance = nil

		-- THE HOST'S OWN `direction` IS KEPT, AND IT WAS BRIEFLY OVERWRITTEN.
		--
		-- A derivation stood here, on the belief that `camera.screenRaycast`
		-- returns no direction. It does. `screen-picking` says the raycast
		-- "uses the same arguments as `screenRay`" and that "all ray fields
		-- remain present" -- those fields being `origin`, `direction`,
		-- `position` and `maxDistance`, with `direction` a unit world-space
		-- vector; a hit ADDS `normal`, `distance`, `material` and the rest
		-- rather than replacing them. And `context-menu` says it for this exact
		-- case: "For sky, `hit=false`: use `origin` and unit `direction` to
		-- aim. `position` is only the ray endpoint at `maxDistance`."
		--
		-- The belief came from reading a card that enumerated what a hit ADDS
		-- and concluding the base fields were absent. They were never absent.
		--
		-- The derivation was also wrong in a way that mattered: it measured from
		-- the BODY, not the camera. `sameTarget` calls two sky contexts the same
		-- at a dot product above 0.9998, which over a 12 m ray is about 24 cm of
		-- movement -- and `controls(true)` blocks aim, fire, interaction and
		-- rotation, NOT walking. So a player taking one step while the list was
		-- open lost their pick. With the camera's own direction the camera has
		-- not moved, so it never happens; in third person, where the body sits
		-- metres from the camera, the derived vector was wrong outright.
		return hit
	end
	if not hit.entityLookupAvailable then return nil end
	local at, here = hit.position, state.position
	if type(at) ~= 'table' then return nil end
	hit.playerDistance = math.sqrt((at.x - here.x) ^ 2 + (at.y - here.y) ^ 2 + (at.z - here.z) ^ 2)
	hit.target = type(hit.target) == 'table' and hit.target or { kind = 'world', networked = false }
	hit.kind = hit.target.isLocalPlayer and 'self' or hit.target.kind
	return hit
end

-- Whether two contexts hit the same thing.
local function sameTarget(left, right)
	if left == nil or right == nil or left.kind ~= right.kind then return false end
	if left.kind == 'sky' then
		local p, q = left.direction, right.direction
		if type(p) == 'table' and type(q) == 'table' then
			return p.x * q.x + p.y * q.y + p.z * q.z > 0.9998
		end
		-- A DIRECTION THAT COULD NOT BE DERIVED IS NOT A DIFFERENT SKY. Without
		-- this the answer was false, for ever, and false here means "you looked
		-- somewhere else" -- so the pick was dropped on every revalidation and
		-- the list never stayed up. `contextAt` derives the direction from the
		-- ray endpoint now, so this is reached only when the body's own position
		-- could not be read; the endpoints are then compared instead, at the
		-- ray's own scale rather than the 20 cm a surface is compared at.
		local a, b = left.position, right.position
		if type(a) ~= 'table' or type(b) ~= 'table' then return true end
		return (a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2 < 1.0
	end
	if left.target.engineEntity or right.target.engineEntity then
		return left.target.engineEntity == right.target.engineEntity
	end
	local p, q = left.position, right.position
	if type(p) ~= 'table' or type(q) ~= 'table' then return false end
	return (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2 < 0.04
end

-- Whether a request is still the current one, the surface still holds focus and
-- the player still holds the key.
local function stillHeld(at)
	if not opened or at ~= request then return false end
	return OPX.UI.FocusOwner() == FOCUS and held()
end

-- Reads a page point in 0..1, or nil.
local function point(payload)
	local x, y = payload.x, payload.y
	if type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y or x < 0 or x > 1 or y < 0 or y > 1 then
		return nil
	end
	return x, y
end

-- Asks one row's owner a question about what the ray hit.
--
-- A FUNCTION is called here, in this VM: no promise, no host call, no yield, and
-- it is the reason a module's rows cost the budget almost nothing. A
-- `{ resource, export }` pair is a genuinely separate resource and goes over
-- `OPX.Lib.Rpc.Call`, which yields on the promise -- which is why every caller of
-- this runs on a one-shot thread and never on a scheduler job.
local function ask(row, callback, context)
	local observation = {}
	for field, value in pairs(context) do observation[field] = value end
	observation.option = { id = row.id, owner = row.owner, token = row.token, data = row.data }
	if type(callback) == 'function' then
		local ran, answer = pcall(callback, observation)
		if not ran then return nil, tostring(answer) end
		return answer
	end
	if type(callback) ~= 'table' then return nil, 'no_callback' end
	-- `answer.value` is the remote's whole reply table; its payload is the
	-- `value` inside that, which is why this reads twice.
	local answer = OPX.Lib.Rpc.Call(callback.resource, callback.export, observation)
	if not answer.ok then return nil, answer.error end
	return answer.value.value
end

-- Draws the resolved list, or nothing at all.
local function finish()
	local job = pending
	setPending(nil)
	if job == nil or not stillHeld(job.request) then return end
	busy = false
	if #job.rows == 0 then
		-- Nothing to offer: the eye goes back to hovering as if the press never
		-- happened. Not an empty panel, and not a line saying there is nothing here.
		listed = {}
		send('target:empty', { handle = handle })
		return
	end
	selection, listed = job.context, job.listed
	send('target:menu', {
		handle = handle,
		x = job.context.screen.x,
		y = job.context.screen.y,
		options = job.rows,
	})
end

-- One slice of a pick: at most BATCH rows, then the body ends. Runs on its own
-- one-shot thread because `ask` may yield.
--
-- A SLICE ONLY EVER SPEAKS FOR ITS OWN PICK. `ask` yields on a round trip, and
-- in that gap the player can release, press again and start a new pick. The
-- old slice then woke up and cleared `pending` -- the NEW pick's -- which left
-- that one on its spinner with `busy` set, refusing every pick and hover until
-- the eye was closed. Every check after a yield is now against `job` itself.
local function slice()
	local job = pending
	if job == nil then return end
	local function drop()
		if pending == job then setPending(nil) end
	end
	local last = math.min(job.at + BATCH - 1, #job.queue)
	while job.at <= last do
		if pending ~= job then return end
		if not stillHeld(job.request) then
			drop()
			return
		end
		if OPX.Now() >= job.budget then
			-- A spent budget never dispatches a call whose answer would be dropped.
			job.at = #job.queue + 1
			break
		end
		local row = job.queue[job.at]
		job.at = job.at + 1
		local allowed = row.canInteract == nil or ask(row, row.canInteract, job.context) == true
		local mark
		if allowed and row.checked ~= nil then
			local answer = ask(row, row.checked, job.context)
			-- Only a boolean draws a box; nil, an error or a refusal leaves the row
			-- without one.
			if answer == true or answer == false then mark = answer end
		end
		if pending ~= job then return end
		if not stillHeld(job.request) then
			drop()
			return
		end
		if allowed and Registry.Get(row.token) == row and Registry.Matches(row, job.context) then
			job.rows[#job.rows + 1] = {
				token = row.token, label = row.label, description = row.description,
				group = row.group, icon = row.icon, danger = row.danger, checked = mark,
			}
			job.listed[row.token] = true
			if #job.rows >= MAX_OPTIONS then
				job.at = #job.queue + 1
				break
			end
		end
	end
	if pending ~= job then return end
	if job.at > #job.queue then return finish() end
	job.inFlight = false
end

-- How long past its lookup budget a slice may stay in flight before it is
-- presumed dead. A slice the instruction budget unwound never clears
-- `inFlight`, and the pick would sit on its spinner until the eye closed.
local SLICE_STALE_MS = 1000

-- Starts the next slice, if the last one has finished. The scheduler job, and the
-- only thing that paces the resolution.
function resolve()
	local job = pending
	if job == nil then return end
	if job.inFlight then
		if OPX.Now() < job.budget + SLICE_STALE_MS then return end
		-- Draw what was resolved; a slice still alive after this finds its pick
		-- gone and stops.
		job.at = #job.queue + 1
		return finish()
	end
	if not stillHeld(job.request) then
		setPending(nil)
		return
	end
	job.inFlight = true
	-- One thread per slice, and the slice is bounded. The instruction budget
	-- unwinds out of a coroutine body and never resumes it; a body that handles
	-- five rows and then ends cannot become the loop that silently stopped,
	-- because the next slice gets a thread of its own either way.
	CreateThread(slice)
end

-- Lights the eye when the cursor is over something with rows, predicates aside.
-- Which context kinds this session has already reported on.
local notedKinds = {}

--- Says once, per kind, what a pick found -- and relays it where an operator is.
--- `Open77.log` on a client writes to the PLAYER'S machine, which is why this
--- goes through `OPX.Note` instead: a diagnostic nobody can read is not one.
---
--- IT STAYS. The scaffolding around it is gone -- a `Registry.List` sweep per
--- owner that answered which rows a kind actually held, and whose own first
--- version exceeded the instruction budget asking thirty times. This one line
--- is what is left, and it is what found the defect it was built for: `a pick
--- on sky matched 0 row(s)` against `a pick on self matched 13 row(s)` said, in
--- the server journal, that the ray and the kind were fine and the rows were
--- not there -- after an afternoon of guessing at the raycast, at `Matches` and
--- at the ACL in turn, each of which looks identical from outside the client.
---
--- One note per kind per session, no sweep, no host read, and `OPX.Note` bounds
--- it again at sixty a session.
local function notedKind(kind, matched)
	if notedKinds[kind] then return end
	notedKinds[kind] = true
	OPX.Note('target', ('a pick on %s matched %d row(s)'):format(kind, matched))
end

local function hover(payload)
	if not opened or busy or selection ~= nil or payload.handle ~= handle then return end
	if OPX.Now() - lastHover < HOVER_MS * 0.5 then return end
	lastHover = OPX.Now()
	local x, y = point(payload)
	if x == nil then return end
	local context = contextAt(x, y)
	-- `Any` deliberately does not sweep: this runs while the pointer moves, and a
	-- sweep here would be a host read per owner per frame.
	send('target:hover', { handle = handle, available = context ~= nil and Registry.Any(context) })
end

-- Lists the rows for what is under a pick -- the point of the right-button press.
local function pick(payload)
	if not opened or busy or payload.handle ~= handle then return end
	if OPX.Now() - lastPick < PICK_GAP_MS then return end
	lastPick = OPX.Now()
	local cursor = OPX.Lib.Input.Cursor()
	if cursor == nil or not cursor.inBounds then return end
	-- The PRESS's point, not the cursor's later one: between the press and this
	-- handler the pointer has already moved, and the ray below is cast fresh at the
	-- point the player actually pressed.
	local x, y = point(payload)
	if x == nil then return end

	request = request + 1
	selection, listed, busy = nil, {}, true
	if not send('target:loading', { handle = handle, x = x, y = y }) then
		return close('no_surface')
	end
	local context = contextAt(x, y)
	if context == nil then
		busy = false
		-- A ray that answered nothing at all is not the same as a ray that hit
		-- something nobody has a row for, and the player sees one empty list
		-- either way. Said once per session: a client whose raycast is refused
		-- -- a missing grant, an option this build will not take -- otherwise
		-- looks exactly like a world nobody registered anything in.
		notedKind('none', 0)
		send('target:empty', { handle = handle })
		return
	end

	-- One sweep for the whole pick, inside Candidates.
	local queue = Registry.Candidates(context)

	-- WHAT THE RAY TOUCHED AND WHAT MATCHED IT, once per kind per session.
	--
	-- Everything between the key press and a drawn row is client-side, so when a
	-- list comes up empty there is nothing an operator can read: the rows may be
	-- unregistered, the context may be a kind nobody covers, or the ray may not
	-- have produced a context at all, and all three look identical from the
	-- outside. The three were guessed at in turn over one afternoon. This is the
	-- one number that separates them, and it costs at most a handful of notes --
	-- `OPX.Note` is bounded at sixty per session and this is bounded again by
	-- the number of kinds.
	notedKind(tostring(context.kind), #queue)

	setPending({
		request = request,
		context = context,
		queue = queue,
		at = 1,
		rows = {},
		listed = {},
		budget = OPX.Now() + LOOKUP_BUDGET_MS,
		inFlight = false,
	})
end

-- Runs a listed row's onSelect once its target and its predicate still hold. On
-- its own one-shot thread: every step here may yield on a promise.
local function commit(row, at)
	-- The thread starts a frame after the click, and the eye can close in that
	-- frame: `selection` is then nil, and indexing it raised on this bare thread.
	if not stillHeld(at) or selection == nil then return end
	local current = contextAt(selection.screen.x, selection.screen.y)
	if not sameTarget(selection, current) or not Registry.Matches(row, current) then
		return close('target_changed')
	end
	local allowed = row.canInteract == nil or ask(row, row.canInteract, current) == true
	if not stillHeld(at) then return end
	-- Checked again AFTER a predicate that may have yielded, not only before it.
	local fresh = contextAt(selection.screen.x, selection.screen.y)
	if not allowed or Registry.Get(row.token) ~= row or not sameTarget(current, fresh)
		or not Registry.Matches(row, fresh) then
		busy = false
		send('target:error', { handle = handle })
		return
	end
	fresh.option = { id = row.id, owner = row.owner, token = row.token, data = row.data }
	-- Input goes back before the owner opens its own screen.
	close('selected')
	TriggerEvent(EVENT_SELECTED, fresh)
	-- The callback comes from the REGISTERED ROW, never from the page. The page
	-- said which row was clicked and nothing else; this is the re-resolution.
	local answer, failure = ask(row, row.onSelect, fresh)
	if answer == false or failure ~= nil then
		Open77.log.warn(('%s/%s refused the pick: %s'):format(row.owner, row.id,
			tostring(failure or 'rejected')))
	end
end

-- How long an armed confirm row waits for its second click.
local CONFIRM_MS = 4000

-- The confirm row armed by a first click: `{ token, handle, atMs }`, or nil.
local armedConfirm = nil

-- The page reports which row was clicked; everything about it is re-derived here.
local function choose(payload)
	if not opened or busy or payload.handle ~= handle then return end
	if type(payload.token) ~= 'string' or not listed[payload.token] then return end
	local row = Registry.Get(payload.token)
	if row == nil or selection == nil then return close('option_unavailable') end
	-- A ROW THAT DESTROYS SOMETHING ASKS TWICE. The first click relabels it
	-- `Confirm: <label>` in place, inside whatever folder it sits in; only a
	-- second click on the same row, on the same eye, within a few seconds runs
	-- it. Removing a vehicle used to take one stray click.
	if row.confirm == true then
		local armed = armedConfirm
		local again = armed ~= nil and armed.token == payload.token and armed.handle == handle
			and OPX.Now() - armed.atMs <= CONFIRM_MS
		if not again then
			armedConfirm = { token = payload.token, handle = handle, atMs = OPX.Now() }
			send('target:confirm', { handle = handle, token = payload.token,
				label = locale('target.confirm', { label = row.label }) })
			return
		end
	end
	armedConfirm = nil
	request = request + 1
	local at = request
	busy = true
	send('target:busy', { handle = handle, token = payload.token })
	CreateThread(function() commit(row, at) end)
end

-- Puts the eye up while the key is held. The key mapping's own callback, so it
-- runs on a press and never on a loop.
local function open()
	if not armed or not held() then return end
	-- Never again until a real release, even after a pick or Escape.
	armed = false
	if opened or down or not targetingEnabled() or not canPick() then return end
	-- A key that fires while another surface owns the keyboard types into someone
	-- else's text box. `OPX.Lib.Input.IsCaptured` answers CAPTURED when the read itself
	-- raises, which is the safe answer, so this is a refusal and not a warning.
	if OPX.Lib.Input.IsCaptured() then return end
	if living() == nil then return end
	local cursor = OPX.Lib.Input.Cursor()
	if cursor == nil or cursor.captured then return end

	request = request + 1
	sequence = sequence + 1
	handle = ('t%d'):format(sequence)
	opened, selection, listed, busy = true, nil, {}, false
	setPending(nil)
	-- THE FOCUS IS TAKEN AFTER THE PAGE HAS THE OPEN, not before it. Taken
	-- first, a page that never drew left the player holding keyboard and cursor
	-- with nothing on screen -- the same ordering defect that was corrected in
	-- `inventory`, left standing here. And `send` forwards BOTH of
	-- `OPX.UI.Send`'s answers, of which the second says the host refused the
	-- payload whole while reporting the send a success; `local drawn = send(...)`
	-- threw that one away, so a refused open read as a drawn one.
	-- CONTROLS FIRST, THEN THE PAGE, THEN THE FOCUS. Moving the send above the
	-- controls to keep focus from being taken before anything was drawn put the
	-- send above them TOO, and that cost two things: a refused `controls` left
	-- the eye drawn for one frame before `close` tore it down -- a flicker on
	-- every key press on a client without `players.controls` -- and `close`
	-- reached `controls(false)` on a path where nothing had ever been taken.
	-- `controls(false)` is `Open77.players.resetControls()`, which clears EVERY
	-- control restriction this resource holds, not the ones this function set:
	-- a player who is down, cuffed or in an animation would have got their aim
	-- and their weapon back by pressing the target key.
	--
	-- Only the FOCUS has to wait for the draw, and only the focus does.
	if not controls(true) then return close('controls_unavailable') end
	heldControls = true

	local drawn, refused = send('target:open', {
		handle = handle,
		hoverMs = HOVER_MS,
		labels = {
			looking = locale('target.looking'),
			unavailable = locale('target.unavailable'),
		},
	})
	if not drawn or refused then return close(refused and 'payload_refused' or 'no_surface') end
	OPX.UI.AcquireFocus(FOCUS, { keyboard = true, cursor = true })
	TriggerEvent(EVENT_OPENED, { handle = handle })
end

-- Records whether the player is down, taking the eye with it.
local function setDown(value)
	down = value == true
	if down and opened then close('player_down') end
end

-- Closes the eye once the key, the focus or the target is gone.
local function watch()
	-- `armed` FIRST, and the order is the whole point. Re-arming is a latch that
	-- only ever goes one way: `open` drops it on a press, this raises it on the
	-- release, and raising one that is already up is the definition of
	-- recomputing an answer that did not change. `held` is two host reads --
	-- `input.keyFor` then `input.isDown` -- so an ungated read cost forty of them
	-- a second for the whole session to re-decide a boolean that is true except
	-- in the fraction of a second between a press and its release.
	if not armed and not held() then armed = true end
	if not opened then return end
	if OPX.UI.FocusOwner() ~= FOCUS or not held() or down or living() == nil then
		return close('input_released')
	end
	if selection ~= nil and not busy and OPX.Now() >= nextCheck then
		nextCheck = OPX.Now() + REVALIDATE_MS
		-- The menu names one thing. When that thing is gone the menu is a list of
		-- actions against nothing, so it closes rather than going stale.
		if not sameTarget(selection, contextAt(selection.screen.x, selection.screen.y)) then
			close('target_changed')
		end
	end
end

-- Forgets the rows of owners that have gone, while the eye is down. A pick sweeps
-- for itself; this is what keeps the table from holding a stopped module's rows
-- for a session in which nobody ever targets anything.
local function sweep()
	if opened then return end
	for owner, generation in pairs(disabledBy) do
		if not alive(owner, generation) then disabledBy[owner] = nil end
	end
	Registry.Sweep()
end

-- ── the contract ─────────────────────────────────────────────────────────────
-- Every entry takes the caller's own name as `owner`. There is no
-- `GetInvokingResource` for an in-process call, so the name is given rather than
-- read, exactly as `downed.Suspend` does: a switch, not a boundary.

-- Registers one definition or a batch for an owner, each forced through a filter.
local function stored(owner, definitions, filter)
	if type(owner) ~= 'string' or owner == '' then return Result.Err('invalid_caller') end
	if type(definitions) ~= 'table' then return Result.Err('invalid_options') end
	local generation = generationOf(owner)
	if generation == nil then return Result.Err('invalid_owner') end

	local single = definitions.id ~= nil
	local batch = {}
	for index, definition in pairs(single and { definitions } or definitions) do
		if type(definition) ~= 'table' then return Result.Err('invalid_option') end
		local row = {}
		for field, value in pairs(definition) do row[field] = value end
		for field, value in pairs(filter) do row[field] = value end
		batch[index] = row
	end

	local tokens, reason = Registry.RegisterMany(owner, generation, batch)
	if tokens == nil then return Result.Err(reason) end
	if single then return Result.Ok({ token = tokens[1] }) end
	return Result.Ok({ tokens = tokens })
end

--- Registers one row, or a batch whole or not at all.
-- @author dop42
-- @param owner string
-- @param definitions table one definition, or a list of them
-- @return Result
local function register(owner, definitions)
	return stored(owner, definitions, {})
end

--- Registers rows shown on other players.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerPlayers(owner, definitions)
	return stored(owner, definitions, { types = { 'player' } })
end

--- Registers rows shown on the player's own body.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerSelf(owner, definitions)
	return stored(owner, definitions, { types = { 'player' }, allowSelf = true, selfOnly = true })
end

--- Registers rows shown on vehicles.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerVehicles(owner, definitions)
	return stored(owner, definitions, { types = { 'vehicle' } })
end

--- Registers rows shown on npcs.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerNpcs(owner, definitions)
	return stored(owner, definitions, { types = { 'npc' } })
end

--- Registers rows shown on props.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerProps(owner, definitions)
	return stored(owner, definitions, { types = { 'prop' } })
end

--- Registers rows shown on doors.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerDoors(owner, definitions)
	return stored(owner, definitions, { types = { 'door' } })
end

--- Registers rows shown on any bare surface.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerWorld(owner, definitions)
	return stored(owner, definitions, { types = { 'world' } })
end

--- Registers rows shown on empty space; the context carries a direction, not a point.
-- @author dop42
-- @param owner string
-- @param definitions table
-- @return Result
local function registerSky(owner, definitions)
	return stored(owner, definitions, { types = { 'sky' } })
end

--- Registers rows shown on entities of the given records.
-- @author dop42
-- @param owner string
-- @param records string[]
-- @param definitions table
-- @return Result
local function registerModels(owner, records, definitions)
	if records == nil then return Result.Err('invalid_records') end
	return stored(owner, definitions, { records = records })
end

--- Registers rows shown on the given entities only.
-- @author dop42
-- @param owner string
-- @param entities table[] each names one of playerId, vehicleId, npcId, engineEntity or propId
-- @param definitions table
-- @return Result
local function registerEntities(owner, entities, definitions)
	if entities == nil then return Result.Err('invalid_entities') end
	return stored(owner, definitions, { entities = entities })
end

--- Registers rows shown when the ray lands within one of the given spheres,
--- whatever it hit.
-- @author dop42
-- @param owner string
-- @param spheres table[] each is x, y, z and radius in metres, 0.1..10
-- @param definitions table
-- @return Result
local function registerSpheres(owner, spheres, definitions)
	if spheres == nil then return Result.Err('invalid_spheres') end
	return stored(owner, definitions, { spheres = spheres })
end

--- Changes some fields of one of the owner's rows; the answer carries its new token.
-- @author dop42
-- @param owner string
-- @param token string
-- @param patch table
-- @return Result
local function update(owner, token, patch)
	local generation = generationOf(owner)
	if generation == nil then return Result.Err('invalid_owner') end
	local fresh, reason = Registry.Update(owner, generation, token, patch)
	if fresh == nil then return Result.Err(reason) end
	return Result.Ok({ token = fresh })
end

--- A copy of one of the owner's definitions.
-- @author dop42
-- @param owner string
-- @param token string
-- @return Result
local function get(owner, token)
	local definition, reason = Registry.Describe(owner, token)
	if definition == nil then return Result.Err(reason) end
	return Result.Ok({ token = token, definition = definition })
end

--- Removes one of the owner's rows.
-- @author dop42
-- @param owner string
-- @param token string
-- @return Result
local function unregister(owner, token)
	local ok, reason = Registry.Unregister(owner, token)
	if not ok then return Result.Err(reason) end
	return Result.Ok(true)
end

--- Removes several of the owner's rows, all or none.
-- @author dop42
-- @param owner string
-- @param tokens string[]
-- @return Result
local function unregisterMany(owner, tokens)
	local ok, reason = Registry.UnregisterMany(owner, tokens)
	if not ok then return Result.Err(reason) end
	return Result.Ok(true)
end

--- Removes every row of one owner.
-- @author dop42
-- @param owner string
-- @return Result
local function clear(owner)
	if type(owner) ~= 'string' or owner == '' then return Result.Err('invalid_caller') end
	Registry.RemoveOwner(owner)
	return Result.Ok(true)
end

--- Switches one of the owner's rows on or off.
-- @author dop42
-- @param owner string
-- @param token string
-- @param value boolean
-- @return Result
local function setEnabled(owner, token, value)
	local ok, reason = Registry.SetEnabled(owner, token, value)
	if not ok then return Result.Err(reason) end
	return Result.Ok(true)
end

--- The owner's rows, short form.
-- @author dop42
-- @param owner string
-- @return Result
local function list(owner)
	if type(owner) ~= 'string' or owner == '' then return Result.Err('invalid_caller') end
	return Result.Ok({ options = Registry.List(owner) })
end

--- Switches the eye off for as long as the caller runs, or back on.
-- @author dop42
-- @param owner string
-- @param value boolean
-- @return Result
local function setTargetingEnabled(owner, value)
	local generation = generationOf(owner)
	if generation == nil then return Result.Err('invalid_owner') end
	if type(value) ~= 'boolean' then return Result.Err('expected_boolean') end
	disabledBy[owner] = not value and generation or nil
	if not value and opened then close('provider_disabled') end
	return Result.Ok(true)
end

--- Takes the eye down.
-- @author dop42
-- @return Result
local function closeEye()
	close('provider_closed')
	return Result.Ok(true)
end

--- Whether the eye can be drawn and is up, and what the open list was built for.
-- @author dop42
-- @return Result
local function state()
	local total, owners = Registry.Size()
	return Result.Ok({
		ready = canPick(),
		open = opened,
		enabled = targetingEnabled(),
		handle = handle,
		target = selection and selection.target or nil,
		context = selection,
		rows = total,
		owners = owners,
	})
end

-- ── lifecycle ────────────────────────────────────────────────────────────────

-- A setting, clamped, or the fallback when it is missing or not a number.
local function tuned(name, fallback, low, high)
	local value = tonumber(M.Settings[name])
	if value == nil or value ~= value then return fallback end
	if low ~= nil and value < low then return low end
	if high ~= nil and value > high then return high end
	return value
end

--- Reads the settings and clears every piece of held state.
-- @author dop42
function M.Init()
	local settings = M.Settings
	KEY = type(settings.KEY) == 'string' and settings.KEY ~= '' and settings.KEY or 'ALT'
	BLOCK_WEAPON_WHEEL = settings.BLOCK_WEAPON_WHEEL ~= false
	RAY_DISTANCE = tuned('RAY_DISTANCE', 12.0, 1.0, 100.0)
	MAX_OPTIONS = math.floor(tuned('MAX_OPTIONS', 32, 1, Model.MAX_TOTAL))
	HOVER_MS = math.floor(tuned('HOVER_MS', 90, 30, 1000))
	WATCH_MS = math.floor(tuned('WATCH_MS', 50, 10, 1000))
	RESOLVE_MS = math.floor(tuned('RESOLVE_MS', 25, 1, 1000))
	SWEEP_MS = math.floor(tuned('SWEEP_MS', 2000, 250, 60000))
	REVALIDATE_MS = math.floor(tuned('REVALIDATE_MS', 200, 50, 5000))
	LOOKUP_BUDGET_MS = math.floor(tuned('LOOKUP_BUDGET_MS', 1500, 100, 10000))
	-- The bound the budget lesson is written into. One is legal and slow; a large
	-- one is the failure this module was ported to keep out.
	BATCH = math.floor(tuned('BATCH', 5, 1, 16))

	opened, busy, handle, sequence, request = false, false, nil, 0, 0
	selection, listed = nil, {}
	setPending(nil)
	armed, down = true, false
	lastPick, lastHover, nextCheck = -math.huge, -math.huge, 0
	disabledBy, liveness, jobs = {}, {}, {}
end

--- Publishes the registry and the eye's switches.
-- @author dop42
function M.Api()
	OPX.Api.Provide('target', 1, {
		Register = register,
		RegisterPlayers = registerPlayers,
		RegisterSelf = registerSelf,
		RegisterVehicles = registerVehicles,
		RegisterNpcs = registerNpcs,
		RegisterProps = registerProps,
		RegisterDoors = registerDoors,
		RegisterWorld = registerWorld,
		RegisterSky = registerSky,
		RegisterModels = registerModels,
		RegisterEntities = registerEntities,
		RegisterSpheres = registerSpheres,
		Update = update,
		Get = get,
		Unregister = unregister,
		UnregisterMany = unregisterMany,
		Clear = clear,
		SetEnabled = setEnabled,
		List = list,
		SetTargetingEnabled = setTargetingEnabled,
		Close = closeEye,
		State = state,
	})
end

-- ── the eye's own row: who is this ───────────────────────────────────────────
--
-- THE OWNER: "en gors avec alt sur un joeuru tu peux recup c'est identifiant
-- donc id serveur est id perso c'est tous". See the IDENTIFY block in
-- `config/target.lua` for why this row lives in the eye and not in `character`:
-- the short version is that `character` cannot depend on `target` without
-- closing a cycle through `downed`, and the graph refuses a cycle by name.
--
-- THE SERVER ID ONLY. The character id was the second half of the answer, read
-- off the player's replicated state bag; never a name to a stranger is the
-- owner's decision (#91), a citizen id names a person as surely as their name
-- does, and the bag no longer carries it. The server id is what a report to
-- staff needs, and the eye already holds it.
local IDENTIFY_OWNER = 'target'

-- The player id the eye's context names, as a number.
local function identifyTarget(context)
	local subject = type(context) == 'table' and context.target or nil
	if type(subject) ~= 'table' then return nil end
	local id = tonumber(subject.playerId)
	if id == nil or id <= 0 or id % 1 ~= 0 then return nil end
	return id
end

-- Puts one line on the clipboard, and answers whether it went. A host with no
-- clipboard costs the copy and not the row: the identifiers are still on screen.
local function copy(line)
	local clipboard = Open77.clipboard
	if type(clipboard) ~= 'table' or type(clipboard.setText) ~= 'function' then
		return false
	end
	local wrote, ok = pcall(clipboard.setText, line)
	return wrote and ok == true
end

-- Registers the row, if the config asks for it. On a thread with a `Wait(0)`,
-- because `RegisterMany` is all-or-nothing and its refusal is written to a log
-- on the player's own machine.
local function registerIdentify()
	local block = type(M.Settings.IDENTIFY) == 'table' and M.Settings.IDENTIFY or {}
	if block.ENABLED == false then return end

	local reach = OPX.Math.Finite(block.DISTANCE) or 12.0
	reach = math.min(50.0, math.max(1.0, reach))

	CreateThread(function()
		Wait(0)
		local answer = registerPlayers(IDENTIFY_OWNER, { M.IdentifyRow(reach) })
		if answer == nil or answer.ok ~= true then
			OPX.Note('target', ('the identify row was refused: %s')
				:format(tostring(answer and answer.error)))
		end
	end)
end

--- The row itself, built rather than inlined so a test can ask it questions.
--- `Registry.List` answers a projection with no predicates in it, so a row that
--- is only ever a table literal inside a registration is a row whose
--- `canInteract` and `onSelect` nothing can reach.
-- @author dop42
-- @param reach number metres
-- @return table
function M.IdentifyRow(reach)
	return {
			id = 'whoIsThis',
			label = OPX.Locale.Text('target.identify.row'),
			icon = 'tag',
			order = 5,
			distance = reach,
			-- Offered on any player the eye resolved to an id.
			canInteract = function(context)
				return identifyTarget(context) ~= nil
			end,
			onSelect = function(context)
				local who = identifyTarget(context)
				if who == nil then return false end

				local copied = copy(tostring(who))
				OPX.Toast.Show({
					id = 'opx.target.identify',
					kind = 'info',
					title = OPX.Locale.Text('target.identify.title'),
					message = OPX.Locale.Text(
						copied and 'target.identify.copied' or 'target.identify.shown',
						{ server = tostring(who) }),
					durationMs = 8000,
				})
				return true
			end,
	}
end

--- Wires the page, claims the key and starts the two jobs.
-- @author dop42
function M.Start()
	-- The sweep runs whether or not this client can draw an eye: the registry is
	-- the half of this module that still works without a screen ray, and a stopped
	-- owner's rows must not outlive it either way.
	jobs[#jobs + 1] = OPX.Scheduler.Every('target:sweep', SWEEP_MS, sweep)

	registerIdentify()

	if not canPick() then
		Open77.log.warn('this client has no screen picking: the target eye is off')
		return
	end

	-- The surface is created here rather than on the first press. It is lazy by
	-- default for a reason -- a second CEF page is not free -- but this one is
	-- reached by a key a player holds within seconds of spawning, and a first press
	-- that did nothing while the page loaded would read as a broken key.
	if OPX.UI.Interactive() == nil then
		Open77.log.error('no interactive surface: the target eye cannot be drawn')
		return
	end

	OPX.UI.On(SURFACE, 'target:hover', hover)
	OPX.UI.On(SURFACE, 'target:pick', pick)
	OPX.UI.On(SURFACE, 'target:select', choose)
	OPX.UI.On(SURFACE, 'target:cancel', function(payload)
		if opened and payload.handle == handle then close('cancelled') end
	end)

	if BLOCK_WEAPON_WHEEL then
		local blocked = OPX.Lib.Input.Block('WeaponWheel', true)
		if not blocked.ok then
			Open77.log.warn('the weapon wheel stays on the key: ' .. tostring(blocked.detail))
		end
	end

	local mapper = rawget(_G, 'RegisterKeyMapping')
	if type(mapper) == 'function' then
		local mapped, failure = pcall(mapper, KEY_ID, locale('target.key'), KEY, open)
		if not mapped then Open77.log.error('the target key was not mapped: ' .. tostring(failure)) end
	end

	AddEventHandler(EVENT_DOWNED, function(payload)
		if type(payload) ~= 'table' then return end
		setDown(payload.down == true)
	end)

	-- `downed` may have raised its state before this module wired the handler, so
	-- the contract is read once. Absent, the eye simply never learns about it.
	local downed = OPX.Api.Get('downed', 1)
	if downed ~= nil and type(downed.IsDown) == 'function' then
		local read, answer = pcall(downed.IsDown)
		if read and type(answer) == 'table' and answer.ok and type(answer.value) == 'table' then
			setDown(answer.value.down == true)
		end
	end

	jobs[#jobs + 1] = OPX.Scheduler.Every('target:watch', WATCH_MS, watch)
	-- `target:resolve` is not registered here. It exists only while a pick is
	-- being sliced, and `setPending` is what puts it up and takes it down.
end

--- Takes the eye down and gives the key and the controls back.
-- @author dop42
function M.Stop()
	close('module_stopped')
	for _, handleId in ipairs(jobs) do OPX.Scheduler.Cancel(handleId) end
	jobs = {}
	if BLOCK_WEAPON_WHEEL then OPX.Lib.Input.Block('WeaponWheel', false) end
end
