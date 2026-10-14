--- Staff name tags: who is nearby, what they are called, and where the tag sits.
-- @author dop42
--
-- The ACCOUNT list is the one thing a client cannot work out for itself, and the
-- server sends it only to a player the ACL grants `opx.admin.self.tags`. Nothing
-- here asks for it: it arrives, and it stops arriving the moment the grant does.
--
-- THE CHARACTER IS ON THAT LIST TOO, and it used not to be. Who somebody was
-- PLAYING was read off their replicated state bag -- which every client in the
-- bucket held, staff or not, so the staff tool was reading a list every stranger
-- had. Never a name to a stranger is the owner's decision: the bag carries
-- nothing now, and the character and citizen id arrive with the account on the
-- staff list, behind the same grant.
--
-- A tag therefore carries three names, all off the staff list:
--   `name`       the CHARACTER -- what the city calls them
--   `user`       the ACCOUNT -- what a ban is keyed on
--   `citizenId`  the character's public id -- what survives both
-- With no character loaded the account moves into `name` and `user` goes empty:
-- a tag over a body has to say something, and the account is what there is.
--
-- The pass is registered with `OPX.Scheduler` and never spawned as a loop of its
-- own: exceeding the per-resume instruction budget unwinds out of a coroutine
-- body and a `while true ... Wait(n)` loop that hits it is never resumed again,
-- silently. It returns at once while the tags are off.

local M = OPX.Modules.Get('admin')

local Client = M.Client
local Text = OPX.Text

M.Tags = {}
local Tags = M.Tags

-- The client store key the switch is remembered under.
local KVP_KEY = 'opx.admin.tags.shown'

-- The client store key the operator's own tag is remembered under. Its own key
-- and not a field of the one above: the two are asked back at different moments
-- -- the switch has to go through the server for the grant, this one never does.
local KVP_OWN_KEY = 'opx.admin.tags.own'

-- Anchors the platform allows one resource, which bounds how many tags a view
-- can be asked to draw at once.
local ANCHOR_LIMIT = 32

-- Metres past the configured distance a player is looked at early, so a tag is
-- ready the moment they come into range rather than a pass later.
local CULL_MARGIN = 1.5

-- Times a saved switch is asked back, and the wait before each ask. The server
-- half may not be listening the instant this client starts.
local RESTORE_TRIES, RESTORE_DELAY_MS = 3, 5000

-- Whether the server last said this operator's tags are on, and whether it has
-- said anything at all since this module started.
local shown, answered = false, false

-- Names by player id from the server, and a list still arriving.
local known, incoming = {}, {}

-- Whether the player is down, in which case no tag is drawn.
local down = false

-- Whether the operator asked to see their OWN tag. Starts at TAGS.OWN and is
-- theirs to change from the menu after that; it is remembered on this machine.
--
-- IT NEEDS NO SERVER AND NO GRANT, and that is the whole reason it is a flag
-- here rather than a command like the switch above it. It changes what THIS
-- client draws over its own head: the name is the player's own, the body is
-- their own, and nothing about it is knowledge the server would be handing out.
-- The gate is already upstream -- no tags at all without `opx.admin.self.tags`.
local ownShown = false

-- The settings, read once at start.
local tuning = {}

-- The signature of the rows last published, so an unchanged frame is not sent.
local published

-- The scheduler handle, and how many restore attempts are left.
local job, restoresLeft = nil, 0

-- Problems already logged, one line each.
local reported = {}

-- Consecutive passes the operator's own tag has been asked for and not drawn.
-- See the probe at the end of `pass`.
local ownQuiet = 0


-- The last pass outcome put in the journal, and how many have been. See
-- `outcome` below for why both bounds are here rather than one.
local lastOutcome, outcomes = nil, 0

-- Outcomes one session will report. `OPX.Note` is bounded at sixty a session for
-- the whole client, and this pass runs four times a second: a fault that flaps
-- between two outcomes would spend the entire runtime's budget in fifteen
-- seconds and leave every other module unable to say anything. Twelve is enough
-- to see a boot, a switch-on, a fault and its recovery.
local MAX_OUTCOMES = 12

--- One line in the OPERATOR's journal, once per key.
--
-- THROUGH `OPX.Note` AND NOT `Open77.log`. A client's log is a file on the
-- player's machine, in a folder they have to be talked into finding, on a PC
-- that is not the one the server runs on -- so every refusal this file could
-- report was written where the only person who could act on it cannot read it.
-- That is not hypothetical here: the name tags stopped drawing entirely after
-- the `opx_lib` migration and produced not one diagnosable line, because every
-- line they produce goes there. `Note` keeps the local copy and relays.
local function warnOnce(key, message)
	if reported[key] then return end
	reported[key] = true
	OPX.Note('admin', 'tags: ' .. message)
end

--- Reports what a pass DECIDED, when that decision changes.
--
-- The pass is a tick and `Note` is for decisions, so this reports neither every
-- pass nor only the first: it reports each distinct OUTCOME once. "The switch is
-- on, the library answered ok, four bodies were near, three rows were built" is
-- one outcome and says itself once however many thousand passes hold it; the
-- moment any part of that sentence changes it is news and is said again.
--
-- That is the shape the last three diagnoses of this file needed and did not
-- have. A pass producing nothing and a pass never running are identical from the
-- journal, and so are "nobody is near" and "the library refused" -- each pair
-- differs by a sentence nobody was writing.
local function outcome(text)
	if text == lastOutcome or outcomes >= MAX_OUTCOMES then return end
	lastOutcome = text
	outcomes = outcomes + 1
	OPX.Note('admin', 'tags: ' .. text)
end

--- Saves the own-tag preference on this machine.
-- Defined up here rather than beside `remember` because `Tags.SetOwnShown` is
-- written above that one, and a `local function` further down the file is a
-- DIFFERENT local: the call above it would reach for a global that is never set.
local function rememberOwn(on)
	-- `Store.Set` folds the absent-namespace check, the pcall and the two-return
	-- unwrap into one Result, so the missing store and the refused write arrive
	-- the same way: the distinction never changed what this function does, which
	-- is warn once and carry on with a session-only switch.
	local saved = OPX.Lib.Store.Set(KVP_OWN_KEY, on)
	if not saved.ok then
		warnOnce('kvpSetOwn', ('the own-tag preference was not saved: %s')
			:format(tostring(saved.detail)))
	end
end

-- ── the view seam ───────────────────────────────────────────────────────────
-- This module owns the state machine and nothing else: no surface is created
-- here, and there is no tags module under `ui/src/modules/` yet. Everything it
-- has to say to whatever draws the tags leaves on `M.Event.ON_TAGS`, and a view
-- module attaches by listening to it with a bare `AddEventHandler`.
--
-- A view for this belongs on the OVERLAY surface (`OPX.UI.Send('overlay', ...)`)
-- and must never take focus: a name tag that captured the keyboard would stop the
-- player moving. It draws each row against a world anchor -- `Open77.anchors`,
-- with the overlay surface as the anchor's page -- and nothing else.
--
-- Three kinds go out:
--   'config'  once, and again on every switch-on: the colours, whether the id
--             square is drawn, and the word a staff badge carries
--   'rows'    the tags to draw now: one row per player, with the entity to
--             follow, the metres above its origin, and the fade
--   'hide'    every tag comes down

--- Tells the view something.
-- @author dop42
-- @param kind string 'config', 'rows' or 'hide'
-- @param payload table|nil
local function publish(kind, payload)
	payload = payload or {}
	payload.kind = kind
	TriggerEvent(M.Event.ON_TAGS, payload)
end

-- ── the state ───────────────────────────────────────────────────────────────

--- Whether this operator's name tags are on, for the menu row and the eye.
-- @author dop42
-- @return boolean
function Tags.IsShown()
	return shown
end

--- Whether the operator asked to see their own tag, for the menu row.
-- @author dop42
-- @return boolean
function Tags.IsOwnShown()
	return ownShown
end

--- Turns the operator's own tag on or off and redraws at the next pass.
--
-- `published` is cleared rather than the pass being run here: the pass is on the
-- scheduler at `UPDATE_MS` and running it inline would be a second one in the
-- same frame. Clearing the signature is what makes the next one redraw instead
-- of deciding nothing changed.
--
-- IT IS STILL THIRD PERSON ONLY, and that is not this switch's business to
-- override. `pass` draws the local body's tag only when the view is `tps`,
-- because in first person the tag would sit in the middle of the screen with no
-- head under it. Asking for your own tag asks for it where there is somewhere to
-- put it.
-- @author dop42
-- @param on boolean
function Tags.SetOwnShown(on)
	on = on == true
	if ownShown == on then return end
	ownShown = on
	published = nil
	rememberOwn(on)
end

-- A configured number inside its range, or the fallback.
local function setting(value, fallback, low, high)
	local number = Text.Finite(value)
	if number == nil or number < low or number > high then return fallback end
	return number
end

-- A configured #RRGGBB colour, or the fallback.
local function colour(value, fallback)
	if type(value) == 'string' and value:match('^#%x%x%x%x%x%x$') then return value:upper() end
	return fallback
end

-- Fades a tag over the far part of the distance, in tenths, so the view is not
-- asked to redraw for a hundredth of an alpha.
local function alphaFor(distance)
	local start = tuning.distance * tuning.fadeStart
	local alpha = 1.0
	if distance > start and tuning.distance > start then
		alpha = math.max(0.0, 1.0 - (distance - start) / (tuning.distance - start))
	end
	return math.floor(alpha * 10 + 0.5) / 10
end

-- Metres from a body's origin to just above its head slot.
local function headOffset(entity, position)
	local character = Open77.character
	if type(character) ~= 'table' or type(character.bonePosition) ~= 'function'
		or type(position) ~= 'table' then
		return tuning.headOffset
	end
	local read, head, reason = pcall(character.bonePosition, entity, 'head')
	if not read or type(head) ~= 'table' then
		-- A body that is not attached yet, and a build with no head bone, are both
		-- ordinary; anything else is worth one line.
		if read and reason ~= 'unknown_bone' and reason ~= 'entity_not_attached' then
			warnOnce('head', ('name tags cannot read the head slot (%s): using TAGS.HEAD_OFFSET_Z')
				:format(tostring(reason)))
		end
		return tuning.headOffset
	end
	local headZ, bodyZ = Text.Finite(head.z), Text.Finite(position.z)
	if headZ == nil or bodyZ == nil then return tuning.headOffset end
	local offset = headZ - bodyZ + tuning.headLift
	if offset < 0.5 or offset > 3.0 then return tuning.headOffset end
	return offset
end

-- Whether the view in force is third person, nil when it cannot be read.
local function thirdPerson()
	local perspective = Open77.perspective
	if type(perspective) ~= 'table' or type(perspective.get) ~= 'function' then return nil end
	local read, mode = pcall(perspective.get)
	if not read or type(mode) ~= 'string' then return nil end
	return mode == 'tps'
end

-- Sends the view the configuration it draws with.
local function publishConfig()
	publish('config', {
		distance = tuning.distance,
		fadeStart = tuning.fadeStart,
		technical = tuning.technical,
		showUser = tuning.username,
		showCitizen = tuning.citizen,
		staffLabel = locale('admin.tags.staff'),
		colors = { text = tuning.text, accent = tuning.accent, staff = tuning.staff,
			background = tuning.background },
	})
end

-- One pass: works out the tags to draw and publishes them when they changed.
local function pass()
	if not shown then
		-- THE SILENT OUTCOME, and the one that cost the most. A pass that returns
		-- here and a pass that never runs at all are the same absence in the
		-- journal, so "the tags are gone" could mean the switch never came on, the
		-- module never started, or the rows came out empty -- three faults with
		-- nothing to tell them apart. It says which.
		outcome('the switch is off, so no pass computes anything')
		return
	end
	-- The early return is the point, not the check: without the native there are
	-- no rows to compute and publishing an empty frame would TAKE DOWN tags that
	-- are on screen. `Native.Reach` is the same two-level lookup written once.
	--
	-- THE SECOND RETURN IS THE WHOLE DIAGNOSIS and was being thrown away.
	-- `open77_unavailable` means the library cannot see the `Open77` namespace at
	-- all -- a library-side fault affecting every wrapper this resource owns --
	-- while `native_not_found` means this client build simply lacks the native.
	-- The two want opposite fixes and the line said neither.
	local native, missing = OPX.Lib.Native.Reach('players.nearby')
	if native == nil then
		return warnOnce('nearby', ('Open77.players.nearby is not reachable (%s): name tags '
			.. 'cannot be drawn'):format(tostring(missing)))
	end

	local third = thirdPerson()
	local rows = {}
	-- Why the operator's own tag was left out, for the one line below. Nil means
	-- it was drawn, or was never asked for.
	local ownMissing = nil
	-- What the pass decided, for `outcome` at the end. Counted rather than
	-- narrated: the three ways an entry is dropped are the three candidates for
	-- "the list arrives and nothing draws", and which of them is non-zero names
	-- the half at fault -- the server's name list, the engine's entity, or the
	-- distance.
	local reach, near = nil, 0
	local nameless, bodiless, far = 0, 0, 0
	if down or (tuning.hideFirstPerson and third == false) then
		reach = down and 'the operator is down' or 'the view is first person'
	else
		-- A Result, not `(entries, reason)`. `Nearby` folds the three ways the old
		-- call could come back empty -- raised, refused, nobody near -- into two:
		-- Ok with a list that may be empty, or a refusal carrying the reason. It
		-- also bounds the radius, which this site never did.
		local radius = tuning.distance + CULL_MARGIN
		local found = OPX.Lib.Players.Nearby(radius,
			{ includeSelf = ownShown, limit = tuning.max })
		local entries = found.ok and type(found.value) == 'table' and found.value or {}
		-- THE ARGUMENTS ARE IN THE LINE, not only the answer. The library bounds
		-- the radius and refuses an options table it does not like, and both
		-- refusals answer the same shape as "nobody is near" once this site has
		-- folded them into an empty list -- so the values that were sent are what
		-- separates a bad call from an empty world.
		reach = ('radius=%.1f limit=%s includeSelf=%s -> %s'):format(radius,
			tostring(tuning.max), tostring(ownShown),
			found.ok and ('ok, %d near'):format(#entries)
				or ('%s (%s)'):format(tostring(found.error), tostring(found.detail)))
		near = #entries
		if ownShown then
			ownMissing = ('the local body is not in players.nearby (%d entries, %s)')
				:format(found.ok and #entries or -1,
					found.ok and 'no reason given' or tostring(found.detail))
		end
		for _, entry in ipairs(entries) do
			local id = type(entry) == 'table' and tonumber(entry.playerId) or nil
			local row = id and known[id] or nil
			local distance = row and Text.Finite(entry.distance) or nil
			if ownShown and entry.isLocal == true then
				ownMissing = row == nil and 'the server has not sent this operator\'s own name'
					or entry.entity == nil and 'the local body has no entity'
					or distance == nil and 'the local body has no distance'
					or nil
			end
			-- THE CHECKBOX IS THE ANSWER, and it did not used to be. This read
			-- `entry.isLocal ~= true or third == true`: the operator's own tag was
			-- drawn in THIRD PERSON ONLY, because in first person the head is at
			-- the camera and the tag "would sit in the middle of the screen".
			--
			-- The fear is real and the guard was the wrong place for it. It made a
			-- ticked box do nothing in the view most players are in, with nothing
			-- anywhere saying why -- and it was a guess besides: `thirdPerson()`
			-- answers nil on a build that cannot read the perspective, and nil is
			-- not `true`, so the tag was withheld from anyone whose client could
			-- not be asked.
			--
			-- The middle-of-the-screen case is now refused on EVIDENCE instead, one
			-- layer down: the anchor projects the head every frame and carries the
			-- depth in front of the camera with it, and `TagsRoot.vue` draws no tag
			-- closer than half a metre. A head at the camera fails that test by
			-- construction, in any view, on any build -- and a tag that the page
			-- can actually put over a head is drawn, which is what the box says.
			if distance and entry.entity ~= nil and (entry.isLocal ~= true or ownShown) then
				rows[#rows + 1] = {
					playerId = id,
					entity = entry.entity,
					-- THE LOCAL BODY IS NOT AN ANCHORABLE ENTITY. `players.nearby`
					-- answers entity `0` for your own body -- the reserved id every
					-- Open77 entity API reads as "the local player" -- and the anchor
					-- backend refuses it by name: `invalid_entity`. The view follows
					-- this row by POSITION instead, and this is the flag that tells
					-- it which one. The position itself is deliberately NOT carried
					-- here: it moves every frame, and the row signature below is what
					-- stops this module republishing a frame that has not changed.
					own = entry.isLocal == true,
					-- THE CHARACTER TAKES THE MAIN SLOT and the account falls back into
					-- it, which is why `user` is nil rather than repeated whenever that
					-- fallback is what happened. The page then never has to work out
					-- which of two names it is looking at.
					name = row.character or row.name,
					user = row.character and row.name or nil,
					citizenId = row.citizenId,
					staff = row.staff == true,
					offsetZ = headOffset(entry.entity, entry.position),
					alpha = alphaFor(distance),
				}
			elseif row == nil then
				-- The server's name list has not reached this client, or has and does
				-- not carry this id. It is the one half of a tag a client cannot work
				-- out for itself, so a full list of nearby bodies and no names at all
				-- is `TAG_ROWS` never arriving -- a server-side or grant fault, and
				-- nothing to do with the natives.
				nameless = nameless + 1
			elseif entry.entity == nil then
				bodiless = bodiless + 1
			elseif distance == nil then
				far = far + 1
			end
		end
	end

	-- ONE LINE, ONCE, when the box is ticked and the tag still is not there. The
	-- option is the sort that is either on screen or unexplained, and "it does not
	-- work" is not something anyone can act on. A tag that IS published and then
	-- culled by the page's depth test is the first-person case and says so there.
	-- NOT ON THE FIRST PASS. The pass runs at `UPDATE_MS` and the first few after a
	-- reconnect are genuinely empty: the switch is restored from the store before
	-- the body is streamed and before the server's first name list lands, so a
	-- probe that latched on pass one reported the boot and then never looked
	-- again. It has to be wrong for a couple of seconds together before it is news.
	ownQuiet = ownMissing ~= nil and ownQuiet + 1 or 0
	if ownQuiet == math.max(2, math.floor(2000 / tuning.updateMs)) and not reported.own then
		reported.own = true
		Client.Journal(('the own name tag is on but not drawn: %s'):format(ownMissing))
	end

	-- WHAT THIS PASS DECIDED, in one sentence, once per distinct decision. Every
	-- number in it answers one of the questions a "the tags do not work" report
	-- cannot otherwise be taken past: whether the pass ran, what the library was
	-- asked and what it answered, how many bodies came back, how many became rows,
	-- and which of the three drops ate the rest. `outcome` is what keeps it off
	-- the note budget while nothing changes.
	outcome(('%s | %d near, %d drawn (no name %d, no entity %d, no distance %d)%s')
		:format(reach or 'not asked', near, #rows, nameless, bodiless, far,
			ownShown and (', own ' .. (ownMissing and ('missing: ' .. ownMissing) or 'drawn'))
				or ''))

	table.sort(rows, function(left, right) return left.playerId < right.playerId end)

	local parts = {}
	for index, row in ipairs(rows) do
		-- Every field the view draws, so a frame that changed only the account or
		-- the citizen id is republished rather than decided unchanged.
		parts[index] = ('%d\t%s\t%s\t%s\t%s\t%d\t%.2f\t%.1f'):format(row.playerId,
			tostring(row.entity), row.name, row.user or '', row.citizenId or '',
			row.staff and 1 or 0, row.offsetZ, row.alpha)
	end
	local signature = table.concat(parts, '\n')
	if signature == published then return end
	published = signature
	-- THE VIEW DRAWS ON A RESUME OF ITS OWN. This pass is a scheduler job, and
	-- the scheduler runs up to four jobs in one resume of the client's only loop:
	-- `ON_TAGS` is a local event, dispatched synchronously, so the view placing
	-- and anchoring up to 32 tags -- creating every anchor on the first frame --
	-- was spent on that same shared budget, on top of this pass's own walk over
	-- 32 bodies. The frame is handed over on a one-shot thread instead, and
	-- dropped there if a newer frame, a hide or a stop came after it.
	if type(CreateThread) ~= 'function' then return publish('rows', { rows = rows }) end
	CreateThread(function()
		if published ~= signature or not shown then return end
		publish('rows', { rows = rows })
	end)
end

-- Saves the switch on this machine for this server.
local function remember(on)
	local saved = OPX.Lib.Store.Set(KVP_KEY, on)
	if not saved.ok then
		warnOnce('kvpSet', ('the name tag switch was not saved: %s'):format(tostring(saved.detail)))
	end
end

-- Asks the server to turn the tags back on, a few times, and gives up quietly.
-- The grant is re-checked there: the stored preference is this client's word.
local function restorePass()
	if answered or restoresLeft <= 0 then return end
	restoresLeft = restoresLeft - 1
	TriggerServerEvent(M.Event.TAGS_RESTORE)
end

--- Reads the settings, wires the two events and registers the pass.
-- @author dop42
function Tags.Start()
	local settings = M.Section('TAGS')
	local colors = type(settings.COLORS) == 'table' and settings.COLORS or {}
	tuning = {
		distance = setting(settings.DISTANCE, 25.0, 1.0, 100.0),
		fadeStart = setting(settings.FADE_START, 0.55, 0.0, 1.0),
		headLift = setting(settings.HEAD_LIFT, 0.35, 0.0, 2.0),
		headOffset = setting(settings.HEAD_OFFSET_Z, 2.05, 0.5, 3.0),
		updateMs = math.floor(setting(settings.UPDATE_MS, 250, 50, 2000)),
		max = math.floor(setting(settings.MAX, ANCHOR_LIMIT, 1, ANCHOR_LIMIT)),
		hideFirstPerson = settings.HIDE_IN_FIRST_PERSON == true,
		technical = settings.TECHNICAL ~= false,
		username = settings.USERNAME ~= false,
		citizen = settings.CITIZEN ~= false,
		text = colour(colors.TEXT, '#F2F6F8'),
		accent = colour(colors.ACCENT, '#FCEE0A'),
		staff = colour(colors.STAFF, '#22D8E2'),
		background = colour(colors.BACKGROUND, '#0A1220'),
	}

	RegisterNetEvent(M.Event.TAGS_STATE, function(on, persist)
		answered = true
		shown = on == true
		-- The server is the only thing that can turn these on, so this is the
		-- moment the feature becomes the client's problem. Without it, a switch
		-- the server never granted and a pass that computed nothing are the same
		-- silence -- and one of them is not this file's fault at all.
		outcome(('the server says the switch is %s'):format(shown and 'on' or 'off'))
		if persist == true then remember(shown) end
		if shown then
			published = nil
			publishConfig()
		else
			known, incoming, published = {}, {}, nil
			publish('hide')
		end
		M.Menu.Refresh()
	end)

	RegisterNetEvent(M.Event.TAG_ROWS, function(payload)
		if not shown or type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
		if payload.offset == 0 then incoming = {} end
		for _, entry in ipairs(payload.rows) do
			local id = tonumber(type(entry) == 'table' and entry.id or nil)
			if id and type(entry.name) == 'string' then
				incoming[id] = { name = Text.Bytes(entry.name, 192), staff = entry.staff == true,
					character = type(entry.character) == 'string' and entry.character ~= ''
						and Text.Bytes(entry.character, 192) or nil,
					citizenId = type(entry.citizenId) == 'string' and entry.citizenId ~= ''
						and Text.Bytes(entry.citizenId, 64) or nil }
			end
		end
		-- Swapped whole, never merged: a list that arrived in pieces and was
		-- applied in pieces would tag a player who has just left.
		if payload.done ~= true then return end
		known, incoming = incoming, {}
	end)

	AddEventHandler(M.Event.ON_DOWNED, function(payload)
		if type(payload) ~= 'table' then return end
		down = payload.down == true
	end)

	-- GUARDED, BECAUSE THE JOURNAL SAYS THE PASS STOPS. The switch goes on, the
	-- server's answer is reported, and then the outcome line at the end of `pass`
	-- -- which reports every pass whose decision changed, and had ten of its
	-- twelve reports left -- is never written again. No `warnOnce` fires either,
	-- and `appearance`'s own scheduler jobs keep reporting through the same
	-- minutes, so the scheduler itself is alive. A pass that ran and decided
	-- nothing would still have said so. The remaining reading is that `pass`
	-- RAISES, somewhere past the switch check, and the raise goes wherever an
	-- error inside a scheduler job goes -- which is not this journal.
	--
	-- So it is caught here and named. The job survives a raising pass instead of
	-- being taken down by it, and the first raise is a line an operator can read
	-- with the message and the traceback's own text in it. `warnOnce` keys it, so
	-- a fault that repeats four times a second costs exactly one note.
	--
	-- This is a diagnostic AND a fix: a per-frame tick that can be killed by one
	-- bad frame -- an entity that stopped streaming between two reads is enough --
	-- should not stay dead for the rest of the session.
	job = OPX.Scheduler.Every('admin.tags', tuning.updateMs, function()
		local ran, failure = pcall(pass)
		if not ran then
			warnOnce('passRaised', ('the pass raised and was caught: %s'):format(tostring(failure)))
		end
	end)

	-- The own-tag preference: `TAGS.OWN` is the DEFAULT, not the value. It is what
	-- a machine that has never been asked starts at, and the store wins after
	-- that, because from then on it is the operator's own answer. Read before the
	-- switch below, which may return early.
	--
	-- `Store.Get` takes the fallback rather than answering a Result, so the
	-- unreadable store and the unset key land on the same line the way they
	-- always meant to. The hand-rolled version did not quite manage that: an
	-- absent `Open77.kvp` returned out of `Start` before this line, leaving
	-- `ownShown` at its initialiser and silently discarding `TAGS.OWN`.
	ownShown = OPX.Lib.Store.Get(KVP_OWN_KEY, settings.OWN == true) == true

	local remembered = OPX.Lib.Store.Get(KVP_KEY, false) == true
	-- ONE LINE PER SESSION, AND IT IS THE FLOOR OF EVERY OTHER DIAGNOSIS. Until
	-- this arrives there is no evidence the module started at all -- and a module
	-- that did not start, a pass that was never registered and a pass that drew
	-- nothing are three different faults that produce the same empty journal. It
	-- also states the two values every later line is read against.
	OPX.Note('admin', ('tags: pass registered at %dms, own=%s, remembered=%s')
		:format(tuning.updateMs, tostring(ownShown), tostring(remembered)))

	if not remembered then return end
	restoresLeft = RESTORE_TRIES
	OPX.Scheduler.Every('admin.tags.restore', RESTORE_DELAY_MS, restorePass)
end

--- Takes every tag down and forgets the list.
-- @author dop42
function Tags.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	shown = false
	known, incoming, published = {}, {}, nil
	publish('hide')
end
