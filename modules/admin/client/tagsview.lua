--- The other half of the name tags: the state on one side, the page on the other.
-- @author dop42
--
-- `client/tags.lua` owns which tags exist and draws nothing. It says everything
-- it has to say on `M.Event.ON_TAGS` and this file is the only thing that knows
-- the other end is a CEF page with world anchors under it -- which is what lets
-- the state half stay readable without one.
--
-- A NAME TAG IS TWO THINGS AT ONCE, and that is the whole of this file:
--
--   1. A WORLD ANCHOR. `Open77.anchors` follows a streamed entity and projects
--      it on every game frame, which is not something Lua could do on a 250ms
--      scheduler pass without the tag swimming behind the body. `render =
--      'page'` publishes the projection to the surface as a batch, so the page
--      moves its own DOM and no coordinate ever crosses the Lua tick.
--   2. A ROW OF CONTENT. The name, whether they are staff, and the fade. That
--      travels on our own channel and changes only when `tags.lua` says the
--      frame changed -- which is a handful of times a minute, against sixty
--      projections a second.
--
-- The two are joined by the ANCHOR ID: `rows` carries one per row and the page
-- matches it against the batch. An id in the batch with no row is a body whose
-- tag has gone; a row with no projection is a body behind the camera, out of the
-- distance band, or not streamed -- the page draws neither.
--
-- THE 32-ANCHOR QUOTA IS THE PLATFORM'S, not ours: `Open77.anchors.create`
-- refuses past 32 per resource and 128 in all. `TAGS.MAX` is already clamped to
-- 32 in `tags.lua`, so a full frame spends the resource's entire quota and any
-- other world anchor this runtime ever wants would be refused. Nothing else asks
-- for one today; the day something does, this is where the budget is split.

local M = OPX.Modules.Get('admin')

M.TagsView = {}
local TagsView = M.TagsView

-- The layer the tags draw on. Never focused: a name tag that took the keyboard
-- would stop the player moving.
local SURFACE = 'overlay'

-- What a published payload travels on.
local CHANNEL = 'admin:tags'

-- Anchor handles by player id, and the count, so the quota can be respected
-- without walking the table.
local anchors, anchorCount = {}, 0

-- The furthest a tag is drawn, mirrored from the config payload so the anchors
-- are given the same band the state half culls on.
local maxDistance = 25.0

-- Logged once each.
local reported = {}

-- Whether the temporary projection probe in `onRows` has fired.
local probedList = false

-- The player id whose anchor is a POSITION one -- the local body -- and the
-- metres above its origin its head sits at. Nil when no own tag is up.
local localAnchor, localOffsetZ = nil, nil

-- The per-frame tick that follows the local body, and the scheduler job that
-- stands in for it on a build with no `SetTick`.
local localTick, localJob = nil, nil

--- One line, once, in the CLIENT log and in the SERVER journal.
--
-- `Open77.log` alone was the hole this file spent two rounds in: every refusal it
-- could report went to a file on the player's machine, so from the operator's
-- side an anchor that was refused and an anchor that was never asked for looked
-- identical -- which is exactly the failure `modules/diagnostics` exists to close.
-- The relay is asked for by name rather than depended on: a runtime without the
-- diagnostics module keeps the line local, as before.
local function warnOnce(key, message)
	if reported[key] then return end
	reported[key] = true
	M.Client.Journal(message)
end

--- Whether this client build has the anchor backend at all.
local function anchorsAvailable()
	local api = Open77.anchors
	return type(api) == 'table' and type(api.create) == 'function'
end

--- Where the local player's head is now, or nil while there is no body.
-- `Open77.character.state()` with no argument is the local player, and one pass
-- fills the whole record -- so this is one engine read, not one per field.
local function localHead(offsetZ)
	local character = Open77.character
	if type(character) ~= 'table' or type(character.state) ~= 'function' then return nil end
	local read, state = pcall(character.state)
	if not read or type(state) ~= 'table' or type(state.position) ~= 'table' then return nil end
	local x, y, z = tonumber(state.position.x), tonumber(state.position.y), tonumber(state.position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z + (tonumber(offsetZ) or 2.05) }
end

--- Drops one player's anchor. Safe to call for a player that has none.
local function drop(playerId)
	local handle = anchors[playerId]
	if handle == nil then return end
	anchors[playerId] = nil
	anchorCount = anchorCount - 1
	pcall(Open77.anchors.remove, handle)
end

--- Drops every anchor this file holds.
local function dropAll()
	for playerId in pairs(anchors) do
		local handle = anchors[playerId]
		anchors[playerId] = nil
		pcall(Open77.anchors.remove, handle)
	end
	anchorCount = 0
end

--- Points one player's anchor at the body it should follow, making it if there
--- is none, and answers the anchor's id.
--
-- An entity anchor may be RE-POINTED -- `update` documents it as the respawn
-- case -- so a player who died and came back keeps their handle rather than
-- spending a create and a remove on the same tag.
local function place(row)
	local playerId = row.playerId
	local offset = { x = 0.0, y = 0.0, z = row.offsetZ }
	local handle = anchors[playerId]

	-- THE LOCAL BODY TAKES A POSITION ANCHOR, everyone else an entity one.
	--
	-- `players.nearby` answers entity `0` for your own body -- the reserved id
	-- that means "the local player" to every Open77 entity API -- and the anchor
	-- backend refuses it outright with `invalid_entity`. That refusal is the whole
	-- reason the operator's own tag never appeared, through three rounds of
	-- looking at the wrong layer.
	--
	-- A position anchor has no body to follow, so `localPass` below re-points it
	-- from `Open77.character.state()` on its own fast job. It is the only anchor
	-- in this file that costs anything per tick, and there is at most one.
	local patch = row.own and { position = localHead(row.offsetZ) }
		or { entity = row.entity, offset = offset }
	if row.own and patch.position == nil then return nil end

	if handle ~= nil then
		local called, updated = pcall(Open77.anchors.update, handle, patch)
		if called and updated == true then return handle end
		-- A handle the host has forgotten: drop it and make a new one below.
		drop(playerId)
	end

	if anchorCount >= 32 then
		warnOnce('quota', 'the anchor quota is spent: name tags past the 32nd are not drawn')
		return nil
	end

	local page = OPX.UI.Surface()
	if page == nil or page.page == nil then return nil end

	local made, id, reason = pcall(Open77.anchors.create, {
		render = 'page',
		page = page.page,
		-- Exactly one of `position` or `entity`: passing both, or neither, is
		-- refused with `position_or_entity_required`.
		position = patch.position,
		entity = patch.entity,
		offset = patch.offset,
		maxDistance = maxDistance,
		-- Bounded to `[A-Za-z0-9_.:-]`, 32 bytes. The player id is enough to read
		-- one of these back out of `Open77.anchors.list` while debugging.
		tag = ('opx.tag.%d'):format(playerId),
	})
	if not made or id == nil then
		-- Keyed on the REASON and not on 'create': the first refusal was
		-- `invalid_entity`, and a key that latched on the verb would have hidden
		-- every different refusal after it behind the one already reported.
		local why = tostring(made and reason or id)
		warnOnce('create:' .. why, ('a name tag anchor was refused: %s (%s)')
			:format(why, patch.position and 'position' or 'entity'))
		return nil
	end

	anchors[playerId] = id
	anchorCount = anchorCount + 1
	return id
end

--- Reconciles the anchors with the rows, and sends the page what to draw.
local function onRows(payload)
	local rows = type(payload.rows) == 'table' and payload.rows or {}

	-- Release peers that left before spending the resource's anchor quota on
	-- new arrivals. A full roster otherwise rejects replacements until the
	-- next changed frame, which may never arrive.
	local wanted = {}
	for _, row in ipairs(rows) do wanted[row.playerId] = true end
	for playerId in pairs(anchors) do
		if not wanted[playerId] then drop(playerId) end
	end

	local seen = {}
	local out = {}
	for index = 1, #rows do
		local row = rows[index]
		local id = place(row)
		if id ~= nil then
			seen[row.playerId] = true
			if row.own then localAnchor, localOffsetZ = row.playerId, row.offsetZ end
			out[#out + 1] = {
				-- What the page matches against the projection batch.
				anchor = id,
				playerId = row.playerId,
				-- THE THREE NAMES, straight through. Which of them is the character
				-- and which the account was decided in `tags.lua`; this file moves
				-- them and draws nothing.
				name = row.name,
				user = row.user,
				citizenId = row.citizenId,
				staff = row.staff == true,
				alpha = row.alpha,
			}
		end
	end

	-- Anyone who fell out of the frame: their body may still be streamed, so the
	-- anchor has to be taken down rather than left to be culled by distance.
	for playerId in pairs(anchors) do
		if not seen[playerId] then drop(playerId) end
	end
	if localAnchor ~= nil and not seen[localAnchor] then localAnchor = nil end

	local sent = OPX.UI.Send(SURFACE, CHANNEL, { kind = 'rows', rows = out })

	-- TEMPORARY INSTRUMENT, and it is the one that answers the question this
	-- feature is actually stuck on: the page never reported a single
	-- `open77:anchors` batch, and from Lua there is no way to tell whether that is
	-- because no anchor exists, because the host is not projecting ours, or
	-- because the batch goes somewhere else.
	--
	-- `Open77.anchors.list` answers the first two directly: it returns THIS
	-- resource's anchors with the projection the host computed for them on the
	-- last frame. If it lists ours with `onScreen` and a screen point, the anchors
	-- are working and only the delivery to the page is not. If it lists nothing,
	-- the creates above never took. Remove this the session a tag is seen.
	if not probedList and #rows > 0 then
		probedList = true
		local read, list = pcall(Open77.anchors.list)
		local first = read and type(list) == 'table' and list[1] or nil
		local screen = type(first) == 'table' and type(first.screen) == 'table' and first.screen or {}
		warnOnce('list', ('tags: %d row(s), %d published, sent=%s, anchors.list=%s, ' ..
			'first onScreen=%s x=%s y=%s depth=%s')
			:format(#rows, #out, tostring(sent),
				read and tostring(type(list) == 'table' and #list or list) or 'raised',
				tostring(first and first.onScreen), tostring(screen.x), tostring(screen.y),
				tostring(screen.depth)))
	end
end

--- Re-points the operator's own anchor at where their head is now.
--
-- WHY THIS JOB EXISTS AT ALL. Every other tag is an ENTITY anchor: the host
-- follows the body itself and projects it on every game frame, and Lua is not in
-- that loop. The local body cannot be one -- its entity id is `0` and the backend
-- refuses it -- so its anchor is a fixed world point, and a fixed point does not
-- follow anybody. Without this the operator's own tag would hang in the air where
-- they were standing when the tag was made.
--
-- ONCE PER FRAME, and 80ms was not enough. It was a scheduler job at 80ms -- twelve
-- updates a second against a game drawing sixty -- and the owner read the result
-- exactly right: the tag TELEPORTS. Every other tag is an entity anchor the host
-- projects on every frame, so the local one was the only thing on screen moving in
-- steps, beside four that were not.
--
-- `SetTick` is the host's own per-frame task: an implicit `Wait(0)` loop under the
-- same per-frame budget as any other. The body is one engine read and one patch,
-- for at most ONE anchor, and it returns immediately when no own tag is up -- so
-- the frames where this costs anything are the frames where it is being looked at.
local function localPass()
	local handle = localAnchor and anchors[localAnchor] or nil
	if handle == nil then return end
	local position = localHead(localOffsetZ)
	if position == nil then return end
	pcall(Open77.anchors.update, handle, { position = position })
end

--- Everything comes down: the anchors and the page's own list.
local function onHide()
	dropAll()
	localAnchor = nil
	OPX.UI.Send(SURFACE, CHANNEL, { kind = 'hide' })
end

--- Wires the page to the seam.
-- @author dop42
function TagsView.Start()
	if not anchorsAvailable() then
		warnOnce('backend', 'this client has no anchor backend: name tags cannot be drawn')
		return
	end

	-- Per frame where the host offers it, and a job at 80ms where it does not: a
	-- build without `SetTick` gets the stepping back, which is worse than smooth
	-- and far better than a tag left standing where the player used to be.
	if type(SetTick) == 'function' then
		localTick = SetTick(localPass)
	end
	if localTick == nil then
		localJob = OPX.Scheduler.Every('admin.tags.own', 80, localPass)
	end

	AddEventHandler(M.Event.ON_TAGS, function(payload)
		if type(payload) ~= 'table' then return end
		local kind = payload.kind

		if kind == 'config' then
			local distance = tonumber(payload.distance)
			if distance ~= nil and distance > 0 then maxDistance = distance end
			-- The whole payload travels: the page reads what it draws and ignores
			-- the rest, which is the standing rule for a field a surface has
			-- stopped drawing rather than a reason to trim the contract.
			OPX.UI.Send(SURFACE, CHANNEL, {
				kind = 'config',
				technical = payload.technical ~= false,
				showUser = payload.showUser ~= false,
				showCitizen = payload.showCitizen ~= false,
				staffLabel = payload.staffLabel,
			})
		elseif kind == 'rows' then
			onRows(payload)
		elseif kind == 'hide' then
			onHide()
		end
	end)
end

--- Takes every anchor down. An anchor held across a stop follows a body around
--- for the rest of the session with nothing left to draw on it.
-- @author dop42
function TagsView.Stop()
	if localTick ~= nil and type(ClearTick) == 'function' then pcall(ClearTick, localTick) end
	if localJob ~= nil then OPX.Scheduler.Cancel(localJob) end
	localTick, localJob, localAnchor = nil, nil, nil
	if not anchorsAvailable() then return end
	dropAll()
end
