--- Server half: the crates, the wire, the refill pass and the pay.
-- @author dop42
--
-- THE SERVER OWNS EVERY CRATE. It creates them, in the SITE's bucket and never in
-- the reporting player's -- the mistake `modules/elevators/server/main.lua:5-8`
-- already warns about for lifts, and the one `rp_nomade` makes for crates: it
-- creates them in the accepting driver's bucket, so nobody outside that instance
-- can ever see one and the race the whole feature is built on never happens.
--
-- Every value off the wire goes through `safe` before it reaches a format string:
-- a newline would forge a whole log line.
--
-- The shape is `modules/elevators/server/main.lua`'s, because that is this
-- resource's house pattern for a server-owned world thing: a table of what we
-- own, an explicit release that tells everyone who was told, a `forget` on
-- disconnect, and a periodic sweep. It teaches the two lessons this module needs
-- most -- verify against the host before committing, and release rather than keep
-- a half-good claim.
--
-- WHAT IS DELIBERATELY NOT HERE:
--
--   `Open77.world.nearby` -- a CLIENT game native. On the server it answers
--   `part_layout_not_proven` and is not a proximity query at all.
--
--   `Open77.props.catalog()` -- always an empty table on the server, so a model
--   alias cannot be validated against a list. `probe` below validates it by
--   TRYING, once, at boot.
--
--   `Open77.props.remove`'s truthiness as a test of existence -- the server card
--   lists `not_found` while the client card says removing an already-gone prop
--   SUCCEEDS, and that contradiction is unresolved. Nothing branches on it here.
--
--   `Open77.kvp.compareAndSet` -- a real typed CAS and a genuine third belt, and
--   two are enough: the non-yielding claim guards our own table and the prop
--   `revision` guards the host's. A third store to keep in step is a third store
--   that can disagree with the other two.

local M = OPX.Modules.Get('hauling')
local Access, Claim = M.Access, M.Claim
local Where, Step = M.Where, M.Step

-- Prop id to the crate record this module owns. The one source of truth for who
-- has what; `Claim` is the only thing allowed to change the ownership fields.
local crates = {}

-- Site key to point index to the earliest millisecond that point may be refilled.
-- A delivered crate's point cools for RESPAWN_MS so a worked site reads as worked
-- rather than replacing a crate before the driver is out of the yard.
local cooling = {}

-- Player to the sale they have begun at a seller: `{ site, dropoff, startedAtMs }`.
-- A sale is not a crate -- loaded crates are trunk items -- so it is not in
-- `crates` and `Claim` knows nothing of it.
local sales = {}

-- The seller NPCs, by id as a decimal string -> `{ id, site, dropoff, bucket }`.
-- One per drop-off that declares an NPC.
local sellers = {}

-- Players handed the snapshot, so a delta reaches all of them and a release tells
-- everyone who was told.
local told = {}

-- Per-player rate-limit windows: requests and log lines.
local requestWindows, logWindows = {}, {}

-- Requests one player may make per window, and the window.
local REQUESTS_PER_WINDOW = 10
local REQUEST_WINDOW_MS = 5000

-- Age past which the sweep collects a rate-limit window. Far longer than the
-- widest window asked for, so a present player's counter is never lost.
local WINDOW_GC_MS = 60000

-- Crates in one snapshot part. The same reason `modules/inventory` chunks its
-- piles: one message per crate is a packet storm at login and one message for
-- sixty-four crates is a payload the host may refuse whole.
local SNAPSHOT_PART = 24

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

-- The refill pass's handle, so `Stop` can cancel it.
local refillJob = nil

local coordinate, integer = Access.Coordinate, Access.Integer

--- Cleans and caps a wire value before it reaches a log line.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

--- Calls a host native that answers `true`, or `nil, reason`, and flattens every
--- way it can go into one pair.
--
-- THREE SHAPES REACH A CALLER and two of them are easy to read as success. The
-- native raises (and `pcall` puts the message where the value goes); it answers
-- `nil, reason`; or it answers `true`. Written out at each site, the middle case
-- is the one that gets dropped -- `local ok = pcall(attach, ...)` is `true` for a
-- refused attach, and a refused attach read as success is a claim held over a
-- crate that is in nobody's hands.
-- @author dop42
-- @param fn function
-- @return boolean
-- @return string|nil
local function hostCall(fn, ...)
	if type(fn) ~= 'function' then return false, 'native_unavailable' end
	local called, value, detail = pcall(fn, ...)
	if not called then return false, 'raised: ' .. tostring(value) end
	if value == true then return true, nil end
	return false, tostring(detail or value or 'refused')
end

--- Counts one event in a player's window, refusing AT the limit rather than
--- counting on through the rest of it.
local function within(windows, player, limit, spanMs)
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= spanMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limit then return false end
	window.count = window.count + 1
	return true
end

--- Whether this host has the prop API at all.
-- Read at the moment of use and never cached: the table belongs to the native
-- layer and a reference kept across a resource reload would outlive the layer
-- that published it.
local function propsReady()
	local props = Open77.props
	return type(props) == 'table' and type(props.create) == 'function'
end

--- The revision the host currently records for a prop, or nil.
--
-- READ BY THE CALLER AND HANDED TO THE CLAIM, never read inside it. This is a
-- host call: it is not on the documented list of things that yield, and that is
-- exactly why it must not be inside `Claim.Take` -- the claim's rule is "no host
-- call at all", which is checkable by reading the function, where "no host call
-- that yields today" is not.
local function revisionOf(propId)
	if not propsReady() or type(Open77.props.get) ~= 'function' then return nil end
	local read, snapshot = pcall(Open77.props.get, propId)
	if not read or type(snapshot) ~= 'table' then return nil end
	return integer(snapshot.revision)
end

--- One crate in the shape a client is sent.
-- The POSITION IS THE POINT and not the prop's live transform: a carried crate
-- moves every frame and the client only needs to know where its home is, which
-- is what the world-mode target row matches against and what a put-back returns
-- it to.
local function wireOf(crate)
	return { id = crate.id, site = crate.site, x = crate.x, y = crate.y, z = crate.z,
		bucket = crate.bucket, where = crate.where }
end

--- Tells one player about one crate.
local function tell(player, crate)
	TriggerClientEvent(M.Event.CRATE, player, wireOf(crate))
end

--- Tells every player handed the snapshot about one crate.
local function announce(crate)
	for player in pairs(told) do tell(player, crate) end
end

--- Tells every player handed the snapshot that a crate is gone.
local function announceGone(propId)
	for player in pairs(told) do TriggerClientEvent(M.Event.GONE, player, propId) end
end

--- Answers one player's request, and tells them what they are holding.
-- `carrying` rides on every answer rather than on an event of its own: a client
-- that missed one refusal would otherwise keep drawing a carry row for a crate it
-- no longer has, and the next answer would not correct it.
local function answer(player, ok, reason)
	local held = Claim.HeldBy(crates, player)
	TriggerClientEvent(M.Event.ANSWER, player, ok == true, reason,
		held ~= nil and held.id or false)
end

--- Sends one player every crate, in parts.
--
-- EVERY BUCKET'S CRATES GO TO EVERY CLIENT and the server refuses on bucket at
-- the moment of use. Filtering at send time is the obvious fix and is wrong for
-- the same reason it is wrong in `modules/inventory/server/world.lua:180-186`: a
-- player changes bucket with no hello -- character selection, an instance -- and
-- would never receive the crates of the bucket they arrive in.
local function sendSnapshot(player)
	local list = {}
	for _, crate in pairs(crates) do list[#list + 1] = wireOf(crate) end
	-- Sorted, because `pairs` order would reshuffle the snapshot between two
	-- players who joined a second apart and make a wire bug look intermittent.
	table.sort(list, function(left, right) return tostring(left.id) < tostring(right.id) end)

	local first = 1
	repeat
		local last = math.min(#list, first + SNAPSHOT_PART - 1)
		local part = {}
		for index = first, last do part[#part + 1] = list[index] end
		TriggerClientEvent(M.Event.SNAPSHOT, player,
			{ first = first == 1, done = last >= #list, crates = part })
		first = last + 1
	until first > #list
end

-- ── the carry pose ──────────────────────────────────────────────────────────

--- Starts the two-handed carry on a player, answering its playback id or nil.
--
-- `carry` is the platform's own profile (`open77_animations/shared/catalog.lua`):
-- an UPPER-BODY LAYER, so the player still walks and runs, looping until stopped.
-- No shipped resource plays it, and the catalogue still marks it
-- `graph_verified_runtime_pending` -- so a refusal is logged once and the carry
-- goes on without it rather than failing the pickup.
local posesRefused = false
local function playPose(player, name, loop)
	local animations = Open77.animations
	if type(animations) ~= 'table' or type(animations.play) ~= 'function' then return nil end
	local called, playback, why = pcall(animations.play, player, name, { loop = loop })
	if called and type(playback) == 'table' and playback.playbackId ~= nil then
		return playback.playbackId
	end
	if not posesRefused then
		posesRefused = true
		Open77.log.warn(('[hauling] the %s animation was refused: %s')
			:format(name, safe(called and why or playback)))
	end
	return nil
end

-- How long `carry_pickup` runs before the loop takes over; see `M.LIFT_MS`.
local PICKUP_CLIP_MS = M.LIFT_MS

--- Plays the lift, then the two-handed carry loop, on a crate just picked up.
--
-- The owner: "je sais pas si tu peux trouver une animation pour le pickup". The
-- platform ships one: `carry_pickup`, the `enter` of the same carry, played once.
-- A new play replaces the last on a player, so the loop simply follows it -- but
-- only if the crate is still in the same hands with the same pose, since a drop
-- or a load during the clip has already stopped it.
local function carryPose(crate, player)
	local lift = playPose(player, 'carry_pickup', false)
	if lift == nil then
		crate.pose = playPose(player, 'carry', true)
		return
	end
	crate.pose = lift
	CreateThread(function()
		Wait(PICKUP_CLIP_MS)
		if crates[crate.id] ~= crate or crate.owner ~= player or crate.pose ~= lift
			or crate.where ~= Where.CARRIED then
			return
		end
		crate.pose = playPose(player, 'carry', true)
	end)
end

--- Whether a player has a crate in their hands. For other modules: the
--- inventory refuses item use to somebody carrying one.
local function isCarrying(player)
	local crate = Claim.HeldBy(crates, tonumber(player) or 0)
	return crate ~= nil and crate.where == Where.CARRIED
end

--- Stops the carry pose a crate started, if it did.
local function dropPose(crate)
	local player, playback = crate.owner, crate.pose
	crate.pose = nil
	if player == nil or playback == nil then return end
	if type(Open77.animations) ~= 'table' or type(Open77.animations.stop) ~= 'function' then
		return
	end
	pcall(Open77.animations.stop, player, playback)
end

-- Metres the client's measured ground may sit from the server's reading of the
-- player's height and still be believed: a step, a kerb, a slope.
local DROP_GROUND_SLACK = 1.5

-- Tries a placement gets before it is given up on, and the wait between them.
local PLACE_TRIES = 5
local PLACE_RETRY_MS = 150

--- Stands a crate at `crate.x/y/z/yaw`, reading the host's answer.
--
-- THE ANSWER WAS NOT READ. Both callers did `local moved = pcall(setTransform,
-- ...)`, which is `true` for a refusal: `setTransform` answers `false,
-- 'prop_attached'` rather than raising. And `detach` "leaves the prop at the
-- server's last coarse parent anchor" -- chest height -- so a refused move is
-- a crate hanging in the air where the carrier's body last was. The owner saw
-- exactly that: "quand je lache le props il se remet pas au sol il fly".
--
-- `prop_attached` straight after a detach is retried a few times on a thread of
-- its own; every other refusal is final and goes to the journal.
local function place(crate, what)
	if not propsReady() or type(Open77.props.setTransform) ~= 'function' then return end
	local function once()
		return hostCall(Open77.props.setTransform, crate.id,
			{ position = { x = crate.x, y = crate.y, z = crate.z }, yaw = crate.yaw })
	end
	local moved, why = once()
	if moved then return end
	if why ~= 'prop_attached' then
		Open77.log.warn(('[hauling] crate %s could not be %s: %s')
			:format(safe(crate.id), what, safe(why)))
		return
	end
	CreateThread(function()
		for _ = 1, PLACE_TRIES do
			Wait(PLACE_RETRY_MS)
			-- A crate somebody took meanwhile is theirs now, and not ours to move.
			if crates[crate.id] ~= crate or crate.where ~= Where.GROUND then return end
			moved, why = once()
			if moved then return end
		end
		Open77.log.warn(('[hauling] crate %s could not be %s: %s')
			:format(safe(crate.id), what, safe(why)))
	end)
end

--- Replaces a crate's prop with a fresh one at `crate.x/y/z/yaw`.
--
-- A DETACHED PROP KEEPS FLYING ON THE CLIENT. The owner, twice: "quand je lache le
-- props il se remet pas au sol il fly". The journal said the server had it on the
-- floor -- `setTransform` accepted, z 52.50, the spawn height -- and the client kept
-- drawing it where the detach left it, the carrier's chest. A prop that was never
-- attached has no such state to carry, so the carried one is removed and a new one
-- is created on the floor, under a new id the clients are told about.
--
-- OUT OF THE REGISTRY BEFORE THE REMOVE, for `retire`'s reason: removing the old
-- prop raises `onPropAttachmentChanged` and `onPropRemoved` for it, and both
-- handlers must find nothing under the old id.
-- @return boolean false when no new prop could be made; the caller falls back
local function reprop(crate, what)
	if not propsReady() then return false end
	local called, id, reason = pcall(Open77.props.create, {
		model = Access.Model(crate.site),
		position = { x = crate.x, y = crate.y, z = crate.z },
		yaw = crate.yaw,
		bucket = crate.bucket,
		physics = 'static',
		collision = true,
	})
	if not called or id == nil then
		Open77.log.warn(('[hauling] crate %s: no fresh prop to be %s (%s)')
			:format(safe(crate.id), what, safe(called and reason or id)))
		return false
	end
	local old = crate.id
	crates[old] = nil
	crate.id = id
	crates[id] = crate
	crate.revision = revisionOf(id)
	if type(Open77.props.remove) == 'function' then pcall(Open77.props.remove, old) end
	announceGone(old)
	return true
end

--- Takes a crate out of whatever it was attached to and stands it back on its point.
--
-- PUT BACK AND NOT DELETED, which is the whole difference between a carry that
-- ended and a crate that was denied to everybody else. The platform detaches
-- automatically on death, disconnect, parent removal and bucket change, and if
-- this deleted the crate instead then disconnecting would be how a player takes a
-- crate away from the competition -- press alt-F4 and nobody gets it.
--
-- DETACH FIRST. `Open77.props.setTransform` answers `prop_attached` for a bound
-- prop, so the order here is not a style choice: reversed, the crate would stay
-- wherever the coarse detach anchor left it and the point would look occupied by
-- a crate standing somewhere else.
local function putBack(crate, reason)
	dropPose(crate)
	-- HOME, NOT WHERE IT LAST WAS. A crate somebody dropped has moved off its
	-- point, and `crate.x` is where it lies; its point is still the config's.
	local point = Access.Point(crate.site, crate.index)
	if point ~= nil then
		crate.x, crate.y, crate.z, crate.yaw = point.x, point.y, point.z, point.yaw
	end
	local fresh = reprop(crate, 'stood back up')
	if not fresh and propsReady() and type(Open77.props.detach) == 'function' then
		-- Read, like the `setTransform` below it already is: a refused detach
		-- leaves the crate on the carrier's body while this function goes on to
		-- stand it back up on its point and announce it as on the ground.
		local let, detached, why = pcall(Open77.props.detach, crate.id)
		if not let or detached == false then
			Open77.log.warn(('[hauling] crate %s would not come off the body: %s')
				:format(safe(crate.id), safe(let and why or detached)))
		end
	end
	crate.where = Where.GROUND
	crate.owner = nil
	crate.step = nil
	crate.claimedAtMs = nil
	crate.pendingVehicle = nil
	crate.droppedAtMs = nil
	if not fresh then place(crate, 'stood back up') end
	crate.revision = revisionOf(crate.id) or crate.revision
	announce(crate)
	Open77.log.info(('[hauling] crate %s back on %s point %d: %s'):format(safe(crate.id),
		safe(crate.site), crate.index, safe(reason)))
end

--- Drops a crate from the world and from this module, and cools its point.
local function retire(crate, reason)
	-- OUT OF THE REGISTRY FIRST. `Open77.props.remove` raises
	-- `onPropAttachmentChanged` and `onPropRemoved`, and both handlers look the
	-- crate up here: a crate still present when the attachment event lands would be
	-- stood back up on its point a millisecond after being paid for and removed.
	crates[crate.id] = nil
	dropPose(crate)
	local points = cooling[crate.site]
	if points == nil then
		points = {}
		cooling[crate.site] = points
	end
	points[crate.index] = OPX.Now() + Access.RespawnMs(crate.site)

	if propsReady() and type(Open77.props.remove) == 'function' then
		-- The answer is read: `remove` refuses with a reason, and this told
		-- every client the crate was gone and armed its respawn regardless. A
		-- refusal left the crate standing on its point while the server said it
		-- had gone and prepared to put a second one in the same place.
		local called, removed, why = pcall(Open77.props.remove, crate.id)
		if not called or removed ~= true then
			Open77.log.error(('[hauling] crate %s was paid for but not removed from the ' ..
				'world (%s); a second one may appear beside it'):format(safe(crate.id),
				safe(called and why or removed)))
		end
	end
	announceGone(crate.id)
	Open77.log.info(('[hauling] crate %s removed from %s point %d: %s'):format(
		safe(crate.id), safe(crate.site), crate.index, safe(reason)))
end

--- Puts one crate on one point of one site, or answers why not.
-- @return string|nil prop id
-- @return string|nil reason
local function spawn(siteKey, index)
	if not propsReady() then return nil, 'props_unavailable' end
	local point = Access.Point(siteKey, index)
	if point == nil then return nil, 'no_such_point' end

	-- THE SITE'S BUCKET. See the file header: the reporting player's bucket is the
	-- bug, not the shortcut.
	local created, id, reason = pcall(Open77.props.create, {
		model = Access.Model(siteKey),
		position = { x = point.x, y = point.y, z = point.z },
		yaw = point.yaw,
		bucket = Access.Bucket(siteKey),
		physics = 'static',
		collision = true,
	})
	if not created then return nil, 'create_raised' end
	if id == nil then return nil, tostring(reason) end

	local crate = {
		id = id,
		site = siteKey,
		index = index,
		x = point.x, y = point.y, z = point.z, yaw = point.yaw,
		bucket = Access.Bucket(siteKey),
		where = Where.GROUND,
		owner = nil,
		revision = revisionOf(id),
	}
	crates[id] = crate
	announce(crate)
	return id
end

--- How many crates this module has standing, across every site.
local function crateCount()
	return OPX.Table.Count(crates)
end

--- Which point indexes of a site have no crate and are not cooling.
local function freePoints(siteKey, atMs)
	local site = Access.Site(siteKey)
	if site == nil or type(site.POINTS) ~= 'table' then return {} end
	local taken = {}
	for _, crate in pairs(crates) do
		if crate.site == siteKey then taken[crate.index] = true end
	end
	local points = cooling[siteKey] or {}
	local free = {}
	for index = 1, #site.POINTS do
		if not taken[index] and (points[index] == nil or atMs >= points[index]) then
			free[#free + 1] = index
		end
	end
	return free
end

-- ── the sellers ─────────────────────────────────────────────────────────────

--- The sellers as a client is sent them.
local function sellerList()
	local list = {}
	for key, seller in pairs(sellers) do
		list[#list + 1] = { npc = key, site = seller.site, dropoff = seller.dropoff }
	end
	table.sort(list, function(left, right) return left.npc < right.npc end)
	return list
end

-- `site\1dropoff` of every drop-off that has a seller, and of every one whose
-- seller was refused -- the second so the refusal is logged once, not every pass.
local placed, refusedSellers = {}, {}

--- Puts a seller NPC on every drop-off of every usable site that names one and
--- has none yet.
--
-- RUN ON EVERY REFILL PASS and not only at boot: a site becomes usable after boot
-- (an operator's fix, a fresh validation) and must not wait for a restart to be
-- sold at. A drop-off that has one is skipped, so a pass that finds nothing to do
-- costs a walk over the config.
--
-- `world.npcs`. Passive, silent and immortal: a seller who can be shot is a
-- drop-off that closes for the session the first time somebody is bored.
local function spawnSellers()
	local npcs = Open77.npcs
	if type(npcs) ~= 'table' or type(npcs.create) ~= 'function' then
		if not refusedSellers['\0api'] then
			refusedSellers['\0api'] = true
			Open77.log.error('[hauling] the NPC API is unavailable; no seller will stand anywhere')
		end
		return
	end
	local added = false
	local ai = type(npcs.ai) == 'table' and npcs.ai.tasks or nil
	-- AN INTEGER OR NOTHING. `damagePolicy` is a number from `Open77.npcs.damage`
	-- and a string raises inside `CreateNpc`; with the table missing, nil asks for
	-- the host's default, which is `immortal` too.
	local immortal = type(npcs.damage) == 'table' and npcs.damage.immortal or nil
	for _, siteKey in ipairs(Access.UsableKeys()) do
		for _, dropoff in ipairs(Access.Dropoffs(siteKey)) do
			local slot = siteKey .. '\1' .. tostring(dropoff.key)
			if dropoff.npc ~= nil and not placed[slot] and not refusedSellers[slot] then
				local called, id, why = pcall(npcs.create, {
					record = dropoff.npc.record,
					position = { x = dropoff.x, y = dropoff.y, z = dropoff.z },
					yaw = dropoff.npc.yaw,
					bucket = Access.Bucket(siteKey),
					aiMode = ai,
					damagePolicy = immortal,
					behavior = { combatEnabled = false, voiceEnabled = false },
					despawnWhenUnobserved = false,
				})
				if called and id ~= nil then
					-- A DECIMAL STRING, never a number on the wire: the id is 64-bit
					-- and a double would hand the client a different NPC.
					local key = math.type(id) == 'integer' and ('%d'):format(id) or tostring(id)
					sellers[key] = { id = id, site = siteKey, dropoff = dropoff.key,
						bucket = Access.Bucket(siteKey) }
					placed[slot] = true
					added = true
				else
					refusedSellers[slot] = true
					Open77.log.error(('[hauling] no seller at %s/%s (%s): %s'):format(
						safe(siteKey), safe(dropoff.key), safe(dropoff.npc.record),
						safe(called and why or id)))
				end
			end
		end
	end
	if not added then return end
	local list = sellerList()
	for player in pairs(told) do TriggerClientEvent(M.Event.SELLERS, player, list) end
end

--- Takes every seller out of the world.
local function removeSellers()
	if type(Open77.npcs) == 'table' and type(Open77.npcs.remove) == 'function' then
		for _, seller in pairs(sellers) do pcall(Open77.npcs.remove, seller.id) end
	end
	sellers, placed, refusedSellers = {}, {}, {}
end

--- One refill-and-reap pass.
--
-- REAP FIRST, SPAWN SECOND, and in that order on purpose: a claim that expired
-- this pass frees a crate that is already standing on its point, so a spawn that
-- ran first would have counted that point as taken and the site would refill one
-- crate slower than it should for ever.
local function refillOnce()
	local at = OPX.Now()

	local stale = Claim.Expired(crates, at, Access.CLAIM_GRACE_MS, Access.StepMs)
	for index = 1, #stale do
		local crate = crates[stale[index]]
		if crate ~= nil then
			local was = crate.owner
			dropPose(crate)
			Claim.Release(crates, crate.id)
			crate.pendingVehicle = nil
			announce(crate)
			Open77.log.info(('[hauling] crate %s: player %s claimed it and never finished; ' ..
				'released'):format(safe(crate.id), tostring(was)))
			if was ~= nil then answer(was, false, 'claim_expired') end
		end
	end

	-- A DROPPED CRATE LEFT LYING still holds its point; after DROP_RETURN_MS it
	-- goes home so an alley does not keep a point out of the job for good.
	local lying = {}
	for _, crate in pairs(crates) do
		if crate.where == Where.GROUND and crate.droppedAtMs ~= nil
			and at - crate.droppedAtMs >= Access.DROP_RETURN_MS then
			lying[#lying + 1] = crate
		end
	end
	for index = 1, #lying do putBack(lying[index], 'left where it was dropped') end

	local ceiling = Access.MAX_CRATES
	for _, siteKey in ipairs(Access.UsableKeys()) do
		local allowance = Access.SpawnPerPass(siteKey)
		local free = freePoints(siteKey, at)
		for index = 1, #free do
			if allowance <= 0 then break end
			if crateCount() >= ceiling then break end
			local id, reason = spawn(siteKey, free[index])
			if id == nil then
				-- A SITE WHOSE MODEL THE ENGINE DOES NOT KNOW IS CONDEMNED, not
				-- retried every minute for the session. `unknown_alias` is a config
				-- mistake and no number of passes will fix it; the alternative is one
				-- log line a minute for ever, which is the same as silence.
				if reason == 'unknown_alias' or reason == 'invalid_model' then
					Access.Condemn(siteKey)
					Open77.log.error(('[hauling] SITE %s IS DISABLED: the engine does not know ' ..
						'the model %q. It must be a curated prop alias -- crate.small is the one ' ..
						'that has actually been carried -- and never a .mesh path, which renders ' ..
						'as placeholder geometry and cannot be attached at all')
						:format(safe(siteKey), safe(Access.Model(siteKey))))
					break
				end
				Open77.log.warn(('[hauling] %s point %d: no crate (%s)'):format(safe(siteKey),
					free[index], safe(reason)))
			end
			allowance = allowance - 1
		end
	end

	spawnSellers()

	for _, windows in ipairs({ requestWindows, logWindows }) do
		for player, window in pairs(windows) do
			if at - (window.started or at) > WINDOW_GC_MS then windows[player] = nil end
		end
	end
end

--- The player's position, or nil. One host read, which answers the point AND the
--- bucket -- the two things every reach test here needs.
--
-- `Open77.players.nearby` and `Open77.zones.playersIn` are the server's proximity
-- queries and both would work, but both SEARCH: they answer "who is near this
-- point", and the question here is "how far is this one player from that one
-- point", which is one subtraction once this read has happened. The searches earn
-- their keep for a drop-off with a crowd in it; they are the wrong shape for a
-- reach test.
--
-- THE SERVER HAS NO PHYSICS WORLD, so none of this is line of sight: a player on
-- the floor above a crate is within three metres of it and nothing here can tell.
local function standing(player)
	if type(Open77.players) ~= 'table' or type(Open77.players.position) ~= 'function' then
		return nil
	end
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = coordinate(position.x), coordinate(position.y), coordinate(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = integer(position.bucket) or 0 }
end

--- A live vehicle's snapshot, or nil.
local function vehicleAt(vehicleId)
	if type(Open77.vehicles) ~= 'table' or type(Open77.vehicles.get) ~= 'function' then
		return nil
	end
	local read, snapshot = pcall(Open77.vehicles.get, vehicleId)
	if not read or type(snapshot) ~= 'table' then return nil end
	-- The host nests the transform under `position` and also flattens it; either
	-- shape is legal and a build answers one of them.
	local at = type(snapshot.position) == 'table' and snapshot.position or snapshot
	local x, y, z = coordinate(at.x), coordinate(at.y), coordinate(at.z)
	if x == nil or y == nil or z == nil then return nil end
	-- THE BUCKET RIDES ALONG. Every reach test against a vehicle compared distance
	-- only, so a truck parked on the same spot in another routing bucket -- an
	-- instance, a character-select bucket -- was a truck the player could load
	-- into without ever seeing it. `vehiclekeys` refuses the same case for a lock
	-- (snapshot `bucket` against `players.position().bucket`); this is that rule.
	return { id = snapshot.id or vehicleId, record = snapshot.record, x = x, y = y, z = z,
		bucket = integer(snapshot.bucket) or 0 }
end

--- A vehicle subject off the wire, in the shape the host answers to.
-- A DECIMAL STRING is how the client sends it, because a vehicle id carries a
-- generation and can pass 2^53, where a JSON number stops being exact -- the
-- reason `modules/vehiclekeys` and the trunk screen send one. A string of digits
-- is read back as the integer the host keys by; anything else is handed on as it
-- came, and the host's own `get` decides whether it names a vehicle.
local function vehicleSubject(subject)
	if type(subject) == 'string' and #subject <= 19 and subject:match('^%d+$') then
		local number = math.tointeger(tonumber(subject))
		if number ~= nil and number > 0 then return number end
	end
	if math.type(subject) == 'float' then
		local number = math.tointeger(subject)
		if number ~= nil then return number end
	end
	return subject
end

--- The job fields of a loaded character, stamped at `atMs`, or nil.
-- The caller passes its own clock read in so the snapshot and the question are
-- timed off the same instant: this is a server-side roster read in the server's
-- own VM, so the age is zero by construction and `Access.Evaluate` passes no
-- staleness bound.
local function jobSnapshot(player, atMs)
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, loaded = pcall(api.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then
		return nil
	end
	local data = loaded.PlayerData
	return {
		job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		atMs = atMs,
	}
end

--- Whether the character holding this connection may work a site.
-- JOBS IS ABSENT FROM THE SHIPPED SITES ON PURPOSE -- the owner asked for a job
-- that needs no job -- so this answers true for every site that declares none,
-- and the whole read of the character roster is skipped rather than made and
-- ignored. `OPX.JobGate.Evaluate` reads an absent JOBS as public, but the read
-- is skipped HERE so the common path costs no contract call.
--
-- THE DECISION ITSELF IS `lib/shared/jobgate.lua`, through this module's own
-- adapter, so `JOBS` and `ON_DUTY` on a site mean exactly what they mean on a
-- lift, an entrance and a bench.
local function mayWork(player, siteKey)
	local site = Access.Site(siteKey)
	if site == nil then return false, 'no_such_site' end
	if type(site.JOBS) ~= 'table' or next(site.JOBS) == nil then return true end

	local now = OPX.Now()
	return Access.Evaluate(site, jobSnapshot(player, now), now)
end

--- Begins the pickup bar on a crate, if this player may have it.
--
-- THE ORDER OF THIS FUNCTION IS THE DESIGN. Everything that reads the host, asks
-- another contract or could conceivably yield happens ABOVE the claim; the claim
-- itself is table arithmetic; nothing below it can undo the fact that this player
-- won. The inventory question in particular is a contract call that goes through
-- `withBag` and really does yield, which is why it is asked before rather than
-- inside -- a yield there is the whole bug this module was written around.
local function beginPickup(player, propId)
	local crate = crates[propId]
	if crate == nil then return false, 'no_such_crate' end
	if crate.where ~= Where.GROUND then return false, 'already_claimed' end

	local allowed, refusal = mayWork(player, crate.site)
	if not allowed then return false, refusal end

	local here = standing(player)
	if here == nil then return false, 'no_position' end
	if here.bucket ~= crate.bucket then return false, 'wrong_bucket' end
	local gap = Access.GapSquared(here, crate)
	if gap == nil or gap > Access.REACH_SQ then return false, 'too_far' end

	if Claim.HeldBy(crates, player) ~= nil then return false, 'already_carrying' end

	-- Read here, one line above the claim, with nothing between. The claim hands
	-- it straight to `Open77.props.attach` as `expectedRevision` when the bar
	-- completes, so a prop something else re-bound in the meantime is refused by
	-- the host before any mutation happens.
	local revision = revisionOf(propId)

	local granted, why = Claim.Take(crates, propId, player, Step.PICKUP, revision, OPX.Now())
	if not granted then return false, why end

	-- Kneel at the crate for the length of the bar. A pose is a host call and the
	-- claim is already won, so it cannot reopen the race; `carryPose` replaces it
	-- when the bar completes, and every way the claim ends stops it.
	local kneel = Access.PickupPose(crate.site)
	if kneel ~= '' then crate.pose = playPose(player, kneel, true) end

	announce(crate)
	return true
end

--- Begins the load bar: the carried crate into a vehicle the player is standing at.
local function beginLoad(player, vehicleId)
	local crate = Claim.HeldBy(crates, player)
	if crate == nil then return false, 'not_carrying' end
	if crate.where ~= Where.CARRIED then return false, 'not_carrying' end
	-- Not while the last load is still being written; see `crate.loading`.
	if crate.loading then return false, 'busy' end

	vehicleId = vehicleSubject(vehicleId)
	local vehicle = vehicleAt(vehicleId)
	if vehicle == nil then return false, 'no_such_vehicle' end
	local here = standing(player)
	if here == nil then return false, 'no_position' end
	if here.bucket ~= vehicle.bucket then return false, 'wrong_bucket' end
	local gap = Access.GapSquared(here, vehicle)
	if gap == nil or gap > Access.VEHICLE_REACH_SQ then return false, 'too_far' end

	local ok, why = Claim.Restamp(crates, crate.id, player, Step.LOAD, OPX.Now())
	if not ok then return false, why end
	crate.pendingVehicle = vehicleId
	return true
end

--- Puts the carried crate down in front of the carrier, where anyone may take it.
--
-- The owner: "pendant qu'on carry ont peux faire x pour la drop".
--
-- THE SERVER HAS NO HEADING FOR A PLAYER, only a position, so the client's yaw
-- says which way is "in front". It moves the crate DROP_DISTANCE metres at most
-- from where the SERVER reads the player, so a forged yaw buys less than a metre.
--
-- THE STATE FLIPS BEFORE THE DETACH. `Open77.props.detach` raises
-- `onPropAttachmentChanged`, and that handler stands a CARRIED crate back on its
-- point -- which, reached first, would send a dropped crate home instead.
-- @return boolean
-- @return string|nil
local function dropCrate(player, yaw, groundZ)
	local crate = Claim.HeldBy(crates, player)
	if crate == nil or crate.where ~= Where.CARRIED then return false, 'not_carrying' end
	-- NOT WHILE A BAR RUNS. The owner: "pendant qu'on load dans la voiture le
	-- joueur peux plus faire x". The client stops offering it; this is the rule.
	if crate.step ~= nil or crate.loading then return false, 'busy' end
	local here = standing(player)
	if here == nil then return false, 'no_position' end

	-- THE CLIENT'S GROUND, BELIEVED WITHIN DROP_GROUND_SLACK OF THE SERVER'S
	-- READING. The server has no physics world, so the floor under the drop is
	-- the client's `Open77.world.groundZ`; a value further off than a step or a
	-- kerb is a forged or a missed ray, and the player's own height is used.
	local z = here.z
	groundZ = Access.FiniteNumber(groundZ)
	if groundZ ~= nil and math.abs(groundZ - here.z) <= DROP_GROUND_SLACK then z = groundZ end

	local x, y = here.x, here.y
	yaw = Access.FiniteNumber(yaw)
	if yaw ~= nil then
		-- Cyberpunk's forward for a yaw in degrees: 0 faces +Y, and it turns
		-- towards -X as the yaw grows.
		local radians = math.rad(yaw)
		x = x - math.sin(radians) * Access.DROP_DISTANCE
		y = y + math.cos(radians) * Access.DROP_DISTANCE
	end

	dropPose(crate)
	crate.where = Where.GROUND
	crate.owner = nil
	crate.step = nil
	crate.claimedAtMs = nil
	crate.pendingVehicle = nil
	crate.x, crate.y, crate.z, crate.yaw = x, y, z, yaw or crate.yaw
	crate.droppedAtMs = OPX.Now()

	if not reprop(crate, 'put down') then
		if propsReady() and type(Open77.props.detach) == 'function' then
			local let, detached, why = pcall(Open77.props.detach, crate.id)
			if not let or detached == false then
				Open77.log.warn(('[hauling] crate %s would not come off the body: %s')
					:format(safe(crate.id), safe(let and why or detached)))
			end
		end
		place(crate, 'put down')
		crate.revision = revisionOf(crate.id) or crate.revision
	end
	announce(crate)
	Open77.log.info(('[hauling] crate %s put down by player %d at %.2f, %.2f, %.2f')
		:format(safe(crate.id), player, crate.x, crate.y, crate.z))
	return true
end

--- The bar a begun step asks the client to draw.
local function runBar(player, step, id, site)
	TriggerClientEvent(M.Event.RUN, player, {
		id = id, step = step, durationMs = Access.StepMs(step), site = site,
	})
end

--- The inventory contract, when it can hold and sell trunk items.
local function inventoryApi()
	local api = OPX.Api.Get('inventory')
	if api == nil or type(api.AddToTrunk) ~= 'function' then return nil end
	return api
end

--- Maps an inventory refusal onto a code this module has a sentence for. The
--- inventory's own word goes to the journal.
local function trunkRefusal(code)
	if code == 'too_heavy' or code == 'no_room' then return 'trunk_full' end
	if code == 'not_yours' then return 'not_your_trunk' end
	if code == 'locked' then return 'trunk_locked' end
	if code == 'no_storage' then return 'no_trunk' end
	if code == 'no_vehicle' then return 'no_such_vehicle' end
	return 'trunk_refused'
end

--- Every vehicle standing inside a drop-off, in the player's bucket.
-- `Open77.vehicles.all` is a server read of its own registry and does not yield.
local function vehiclesAt(dropoff, bucket)
	if type(Open77.vehicles) ~= 'table' or type(Open77.vehicles.all) ~= 'function' then
		return {}
	end
	local read, list = pcall(Open77.vehicles.all, bucket)
	if not read or type(list) ~= 'table' then return {} end
	local out = {}
	for _, snapshot in ipairs(list) do
		if type(snapshot) == 'table' and snapshot.id ~= nil then
			local at = type(snapshot.position) == 'table' and snapshot.position or snapshot
			local gap = Access.GapSquared(at, dropoff)
			if gap ~= nil and gap <= dropoff.radius * dropoff.radius then
				out[#out + 1] = snapshot.id
			end
		end
	end
	return out
end

--- The citizen id behind a connection, for an audit line or an
--- ownership check, or nil.
local function citizenOf(player)
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, loaded = pcall(api.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	return loaded.PlayerData.citizenId
end

--- Whether a parked vehicle's trunk is this player's to sell out of: they own the
--- vehicle (the `vehicles` contract's row) or carry its key (`vehiclekeys`).
-- MAY YIELD: counting a key reads the bag. With neither contract on this server
-- nothing can prove either, and the inventory's own TRUNK_OWNER_ONLY rule is the
-- only gate, as it was before; that is said once in the journal.
local warnedNoProof = false
local function mayTakeFrom(player, vehicleId)
	local vehicles = OPX.Api.Get('vehicles')
	local keys = OPX.Api.Get('vehiclekeys')
	local canOwn = vehicles ~= nil and type(vehicles.PlateOf) == 'function'
	local canKey = keys ~= nil and type(keys.Holds) == 'function'
	if not canOwn and not canKey then
		if not warnedNoProof then
			warnedNoProof = true
			Open77.log.warn('[hauling] neither the vehicles nor the vehiclekeys contract is here: a ' ..
				'sale counts any trunk at the drop-off the inventory lets the player open')
		end
		return true
	end
	if canOwn then
		local read, plate, owner = pcall(vehicles.PlateOf, vehicleId)
		if read and plate ~= nil and owner ~= nil and owner == citizenOf(player) then return true end
	end
	if canKey then
		local read, holds = pcall(keys.Holds, player, vehicleId)
		if read and holds == true then return true end
	end
	return false
end

--- Where this site's crates are for a sale: the player's bag, then every trunk
--- parked inside the drop-off that the player may open. YIELDS.
-- @return table[] `{ vehicle = id|nil, count = n }`, only the non-empty ones
-- @return integer the total
local function stockFor(player, site, dropoff, bucket)
	local inventory = inventoryApi()
	if inventory == nil then return {}, 0 end
	local tag = { site = site }
	local out, total = {}, 0

	local bag = inventory.GetItemCount(player, Access.ITEM, tag)
	if type(bag) == 'table' and bag.ok and (bag.value or 0) > 0 then
		out[#out + 1] = { vehicle = nil, count = bag.value }
		total = total + bag.value
	end
	-- A trunk the player may not open (TRUNK_OWNER_ONLY) answers `not_yours` and is
	-- skipped: selling out of a stranger's boot is the theft the screen refuses.
	-- And a trunk the inventory WOULD open -- an unowned truck has no owner to
	-- refuse anyone -- is counted only when the vehicle is the player's or they
	-- hold its key (`mayTakeFrom`), so a hauler who parks at the drop-off is not
	-- paid out by whoever reaches the buyer first.
	for _, vehicleId in ipairs(vehiclesAt(dropoff, bucket)) do
		if mayTakeFrom(player, vehicleId) then
			local held = inventory.CountInTrunk(vehicleId, Access.ITEM, tag, player)
			if type(held) == 'table' and held.ok and (held.value or 0) > 0 then
				out[#out + 1] = { vehicle = vehicleId, count = held.value }
				total = total + held.value
			end
		end
	end
	return out, total
end

--- Calls one inventory contract function and answers whether it took, and the
--- inventory's word when it did not. A raise is a refusal, never a lost thread.
-- @return boolean
-- @return string|nil
local function stored(fn, ...)
	if type(fn) ~= 'function' then return false, 'no_function' end
	local called, result = pcall(fn, ...)
	if not called then return false, 'raised: ' .. tostring(result) end
	if type(result) == 'table' and result.ok then return true, nil end
	return false, type(result) == 'table' and tostring(result.error) or 'refused'
end

--- Puts back what a sale took when the pay refused, and answers how many crates
--- could not be put back anywhere.
--
-- THE PUT-BACK USED TO BE TRUSTED. Every inventory call it made yields, and the
-- world moves meanwhile: the owner locks the truck from the seat (`locked`), the
-- bag fills from a trade (`no_room`). Each refusal was dropped on the floor, so a
-- sale the wallet refused could leave the player with no crates AND no money and
-- not one line anywhere saying so.
--
-- Now a crate that will not go back where it came from tries the bag, then every
-- other trunk the sale took from, ONE AT A TIME so a bag with room for two of
-- five still keeps two. What fits nowhere is written to the journal at error and
-- to the audit, with the site, the count and what it would have paid, so staff
-- can refund it from one line.
-- @return integer crates lost
local function restore(inventory, player, taken, tag, sale, dropoff, each)
	--- One destination as a function of a count: the bag, or a trunk by id.
	local function into(vehicle)
		if vehicle == nil then
			return function(count) return stored(inventory.AddItem, player, Access.ITEM, count, tag) end
		end
		-- No `player`: this is a put-back into the trunk the item came out of a
		-- second ago, and not the player reaching into somebody's boot.
		return function(count)
			return stored(inventory.AddToTrunk, vehicle, Access.ITEM, count, tag)
		end
	end
	local function name(vehicle)
		return vehicle == nil and 'the bag' or ('the trunk of ' .. safe(vehicle))
	end

	local lost = 0
	for _, source in ipairs(taken) do
		local home = into(source.vehicle)
		local back, why = home(source.count)
		if not back then
			-- Every other place this player's crates were, in the order the sale
			-- found them, the bag first because nothing locks it.
			local fallbacks = {}
			if source.vehicle ~= nil then fallbacks[#fallbacks + 1] = { vehicle = nil } end
			for _, other in ipairs(taken) do
				if other.vehicle ~= nil and other.vehicle ~= source.vehicle then
					fallbacks[#fallbacks + 1] = { vehicle = other.vehicle }
				end
			end
			local missing = 0
			for _ = 1, source.count do
				local placed = home(1)
				local where = source.vehicle
				local index = 1
				while not placed and index <= #fallbacks do
					where = fallbacks[index].vehicle
					placed = into(where)(1)
					index = index + 1
				end
				if placed and where ~= source.vehicle then
					Open77.log.warn(('[hauling] player %d: a crate of %s from %s went back into ' ..
						'%s instead (%s)'):format(player, safe(sale.site), name(source.vehicle),
						name(where), safe(why)))
				elseif not placed then
					missing = missing + 1
				end
			end
			if missing > 0 then
				lost = lost + missing
				Open77.log.error(('[hauling] CRATES LOST: player %d sold %d crate(s) of %s at %s, ' ..
					'was not paid, and they could not be put back in %s or anywhere else (%s). ' ..
					'Refund %d %s'):format(player, missing, safe(sale.site), safe(dropoff.key),
					name(source.vehicle), safe(why), each * missing, safe(Access.CURRENCY)))
				OPX.Audit.Log({
					event = 'hauling.crateLost',
					severity = 'error',
					message = ('%d crate(s) of %s lost after an unpaid sale'):format(missing,
						tostring(sale.site)),
					data = { site = sale.site, dropoff = dropoff.key, count = missing,
						from = source.vehicle ~= nil and tostring(source.vehicle) or 'bag',
						refund = each * missing, currency = Access.CURRENCY, error = why },
					source = player,
					citizenId = citizenOf(player),
				})
			end
		end
	end
	return lost
end

--- Begins the sale bar at a seller NPC.
local function beginSale(player, npcId)
	local whole = math.type(npcId) == 'integer' and npcId or nil
	local seller = sellers[whole ~= nil and ('%d'):format(whole) or tostring(npcId)]
	if seller == nil then return false, 'no_such_seller' end
	if Claim.HeldBy(crates, player) ~= nil then return false, 'already_carrying' end
	if inventoryApi() == nil then return false, 'no_inventory' end

	local allowed, refusal = mayWork(player, seller.site)
	if not allowed then return false, refusal end

	local dropoff = Access.Dropoff(seller.site, seller.dropoff)
	if dropoff == nil then return false, 'no_such_seller' end
	local here = standing(player)
	if here == nil then return false, 'no_position' end
	-- THE SELLER'S BUCKET, which is the site's: the NPC was created there, and a
	-- player on the same spot in another bucket has no seller in front of them.
	if here.bucket ~= seller.bucket then return false, 'wrong_bucket' end
	local gap = Access.GapSquared(here, dropoff)
	if gap == nil or gap > Access.VEHICLE_REACH_SQ then return false, 'too_far' end

	local _, total = stockFor(player, seller.site, dropoff, here.bucket)
	if total <= 0 then return false, 'no_crates' end

	sales[player] = { site = seller.site, dropoff = seller.dropoff, bucket = seller.bucket,
		startedAtMs = OPX.Now() }
	runBar(player, Step.DELIVER, tostring(npcId), seller.site)
	return true
end

--- Completes a sale: takes every crate of the site within reach and pays for them.
--
-- THE RECORD IS CLEARED BEFORE THE FIRST YIELD. Every inventory call below yields,
-- and a second FINISH arriving during one must find nothing to complete, or the
-- same crates are counted and paid twice.
local function completeSale(player, sale)
	sales[player] = nil
	if Claim.TooSoon({ claimedAtMs = sale.startedAtMs }, OPX.Now(),
		Access.StepMs(Step.DELIVER), Access.CLOCK_TOLERANCE_MS) then
		return false, 'too_soon'
	end

	local dropoff = Access.Dropoff(sale.site, sale.dropoff)
	if dropoff == nil then return false, 'no_such_seller' end
	local here = standing(player)
	if here == nil then return false, 'no_position' end
	if here.bucket ~= sale.bucket then return false, 'wrong_bucket' end
	local gap = Access.GapSquared(here, dropoff)
	if gap == nil or gap > Access.VEHICLE_REACH_SQ then return false, 'too_far' end

	local character = OPX.Api.Get('character')
	if character == nil or type(character.AddMoney) ~= 'function' then
		return false, 'no_character'
	end
	local inventory = inventoryApi()
	if inventory == nil then return false, 'no_inventory' end

	-- WHO IS SELLING, pinned before the first yield. The removals below yield,
	-- and a connection can leave or switch character in the world meanwhile; the
	-- pay used to follow the CONNECTION, so the crates of one character paid
	-- the next one, or paid nobody and were put back into a bag already saved.
	local seller = citizenOf(player)
	local tag = { site = sale.site }
	local stock = stockFor(player, sale.site, dropoff, here.bucket)
	local taken, sold = {}, 0
	for _, source in ipairs(stock) do
		-- Through `stored`: a raise here, after an earlier source was already
		-- taken, would end the handler with those crates gone and nothing paid.
		local removed = source.vehicle == nil
			and stored(inventory.RemoveItem, player, Access.ITEM, source.count, tag)
			or stored(inventory.RemoveFromTrunk, source.vehicle, Access.ITEM, source.count, tag,
				player)
		if removed then
			taken[#taken + 1] = source
			sold = sold + source.count
		end
	end
	if sold <= 0 then return false, 'no_crates' end

	-- THE TUNABLE IS READ HERE, at the sale. It was declared `apply = 'live'` and
	-- read by nobody, so the panel moved a number that paid nothing different.
	local tuned = OPX.Tune.Get('HAUL_PAY_PER_CRATE')
	tuned = type(tuned) == 'number' and math.tointeger(tuned) or nil
	local each = Access.Pay(sale.site, tuned)
	local pay = each * sold
	local reason = ('hauling:%s:%s'):format(tostring(sale.site), tostring(dropoff.key))
	local moved = seller ~= nil and citizenOf(player) ~= seller
	local called, paid, why
	if moved and type(character.AddMoneyOffline) == 'function' then
		-- The character who sold is no longer on this connection: paid by citizen
		-- id, in memory if they are loaded elsewhere and in their row if not.
		local answer
		called, answer = pcall(character.AddMoneyOffline, seller, Access.CURRENCY, pay, reason)
		paid = called and type(answer) == 'table' and answer.ok == true
		why = called and type(answer) == 'table' and answer.error or answer
	else
		called, paid, why = pcall(character.AddMoney, player, Access.CURRENCY, pay, reason)
	end
	if not called or paid ~= true then
		Open77.log.warn(('[hauling] player %d sold %d crate(s) at %s and was not paid: %s')
			:format(player, sold, safe(dropoff.key), safe(called and why or paid)))
		local lost = restore(inventory, player, taken, tag, sale, dropoff, each)
		return false, lost > 0 and 'not_paid_lost' or 'not_paid'
	end
	Open77.log.info(('[hauling] player %d sold %d crate(s) of %s at %s for %d')
		:format(player, sold, safe(sale.site), safe(dropoff.key), pay))
	OPX.Publish(M.Event.ON_SOLD, player, {
		citizenId = seller or citizenOf(player),
		site = sale.site,
		dropoff = dropoff.key,
		count = sold,
		pay = pay,
		each = each,
		currency = Access.CURRENCY,
	})
	-- Not said to a connection that holds somebody else now.
	if moved then return true end
	OPX.NotifyLocale(player, 'hauling.paid',
		{ amount = OPX.Locale.Money(pay, Access.CURRENCY), count = sold, dropoff = dropoff.label },
		'success')
	return true
end

--- Completes whatever the player had begun.
local function complete(player)
	local sale = sales[player]
	-- A SALE EXPIRES LIKE A CLAIM. Nothing else ends one but an ABORT or a FINISH,
	-- and a FINISH the rate limit swallowed left it standing: the bar could be
	-- skipped by coming back later, and the next pickup's FINISH was spent on it.
	if sale ~= nil and OPX.Now() - sale.startedAtMs
		> Access.StepMs(Step.DELIVER) + Access.CLAIM_GRACE_MS then
		sales[player] = nil
		sale = nil
	end
	if sale ~= nil then return completeSale(player, sale) end

	local crate = Claim.HeldBy(crates, player)
	if crate == nil or crate.step == nil then return false, 'nothing_running' end

	-- THE SERVER'S CLOCK AND NOT THE CLIENT'S. `modules/progress` counts down on
	-- the player's own machine, so the arrival of a `finish` proves only that a
	-- client sent one. The stamp is the rule.
	if Claim.TooSoon(crate, OPX.Now(), Access.StepMs(crate.step),
		Access.CLOCK_TOLERANCE_MS) then
		return false, 'too_soon'
	end

	local step = crate.step

	if step == Step.PICKUP then
		-- A REFUSED PICKUP GIVES THE CRATE BACK, as a refused attach already did.
		-- Kept claimed, the crate sat in nobody's hands for up to a minute and a
		-- half: the player's hands blocked, "Load the crate" offered on every
		-- car, every other crate answering "Your hands are full", and at the end
		-- "You took too long" for a pickup that had been refused at once.
		local function giveBack(code)
			dropPose(crate)
			Claim.Release(crates, crate.id, player)
			announce(crate)
			return false, code
		end
		local carry = Access.Carry(crate.site)
		if carry == nil then return giveBack('no_carry_config') end
		-- The reach is checked AGAIN, because the bar took seconds and the player
		-- could have walked away during it. What this refuses is finishing a
		-- pickup from across the yard.
		local here = standing(player)
		if here == nil then return giveBack('no_position') end
		-- And the bucket, which BEGIN checks: a player moved to another instance
		-- during the bar is not standing beside this crate, however close the
		-- coordinates are.
		if here.bucket ~= crate.bucket then return giveBack('wrong_bucket') end
		local gap = Access.GapSquared(here, crate)
		if gap == nil or gap > Access.REACH_SQ then return giveBack('too_far') end

		-- THE COMPARE-AND-SWAP. `expectedRevision` is the revision read one line
		-- above the claim: a prop something else re-bound while the bar ran is
		-- refused here, before any mutation, rather than producing a carry over a
		-- stale binding.
		local attached, why = hostCall(Open77.props.attach, crate.id, {
			parentType = 'player',
			parentId = player,
			bone = carry.bone,
			offset = carry.offset,
			rotation = carry.rotation,
		}, crate.revision)
		if not attached then
			-- RELEASED RATHER THAN KEPT. A claim whose attach was refused is a crate
			-- nobody can see in anybody's hands and that nobody else may take; that
			-- is strictly worse than the crate standing on its point.
			dropPose(crate)
			Claim.Release(crates, crate.id, player)
			announce(crate)
			-- THE HOST'S OWN WORDS GO TO THE JOURNAL, NOT TO THE CLIENT. What
			-- `Open77.props.attach` answers is the platform's vocabulary and it
			-- grows with the build -- `invalid_attachment_parent`,
			-- `invalid_attachment_bone`, whatever comes next -- and the client has
			-- a sentence for none of it. Handing it over made the refusal a
			-- description of our own internals that a player reads as gibberish
			-- and an attacker reads as a map. One stable code out, the detail in.
			Open77.log.warn(('[hauling] crate %s would not attach to player %d: %s')
				:format(safe(crate.id), player, safe(why)))
			return false, 'attach_refused'
		end
		crate.where = Where.CARRIED
		carryPose(crate, player)
		-- HANDS FULL: whatever they were holding goes away. The owner: "si ont
		-- porte le truc on puisse pas frapper n'y utiliser un item inv". The
		-- client blocks drawing it again; the inventory refuses item use.
		if type(Open77.weapons) == 'table' and type(Open77.weapons.holster) == 'function' then
			pcall(Open77.weapons.holster, player)
		end
		crate.step = nil
		crate.revision = revisionOf(crate.id) or crate.revision
		announce(crate)
		return true
	end

	if step == Step.LOAD then
		-- A REFUSED LOAD ENDS THE STEP, and the crate stays in their hands. These
		-- returns used to leave the step on, and `dropCrate` refuses a crate with
		-- a step running: a truck driven off during the bar left the player
		-- holding a crate X could not put down ("Not while you are loading it.")
		-- until they found another vehicle.
		local function stopLoading(code)
			crate.step, crate.claimedAtMs, crate.pendingVehicle = nil, nil, nil
			return false, code
		end
		local vehicleId = crate.pendingVehicle
		local vehicle = vehicleAt(vehicleId)
		if vehicle == nil then return stopLoading('no_such_vehicle') end
		local here = standing(player)
		if here == nil then return stopLoading('no_position') end
		if here.bucket ~= vehicle.bucket then return stopLoading('wrong_bucket') end
		local gap = Access.GapSquared(here, vehicle)
		if gap == nil or gap > Access.VEHICLE_REACH_SQ then return stopLoading('too_far') end
		local inventory = inventoryApi()
		if inventory == nil then return stopLoading('no_inventory') end

		-- THE CRATE BECOMES AN ITEM IN THE TRUNK. The owner: "des qu'il pose dans
		-- le vehicule cela deviens un item".
		--
		-- THE STEP COMES OFF BEFORE THE YIELD. `AddToTrunk` loads an owned trunk by
		-- plate and yields; a second FINISH arriving meanwhile must answer
		-- `nothing_running` rather than add a second item. The crate stays CARRIED
		-- and theirs, so a refusal leaves it in their hands where it was.
		--
		-- AND `loading` STAYS ON ACROSS IT. With the step off, a second BEGIN
		-- LOAD could re-stamp the same crate during a slow write, and its FINISH
		-- -- a bar later -- ran `AddToTrunk` again: one crate, two trunk items.
		crate.step = nil
		crate.claimedAtMs = nil
		crate.pendingVehicle = nil
		crate.loading = true
		-- Under pcall, so a raise cannot leave `loading` on and the crate stuck in
		-- the carrier's hands for good; it reads as the refusal `raised`.
		local called, added = pcall(inventory.AddToTrunk, vehicleId, Access.ITEM, 1,
			{ site = crate.site }, player)
		crate.loading = nil
		if not called then added = nil end
		if type(added) ~= 'table' or not added.ok then
			local code = type(added) == 'table' and added.error or 'raised'
			Open77.log.info(('[hauling] crate %s refused by the trunk of %s: %s')
				:format(safe(crate.id), safe(vehicleId), safe(code)))
			return false, trunkRefusal(code)
		end
		-- The item is in. The prop goes, whatever happened to the carry during the
		-- yield: a crate put back on its point meanwhile would otherwise exist twice.
		if crates[crate.id] == crate then
			retire(crate, ('loaded into the trunk of %s by player %d')
				:format(tostring(vehicleId), player))
		end
		return true
	end

	return false, 'nothing_running'
end

--- Ends whatever the player had begun, without completing it.
local function abort(player, reason)
	if sales[player] ~= nil then
		sales[player] = nil
		return
	end
	local crate = Claim.HeldBy(crates, player)
	if crate == nil then return end
	if crate.where == Where.CLAIMED then
		dropPose(crate)
		Claim.Release(crates, crate.id, player)
		crate.pendingVehicle = nil
		announce(crate)
		return
	end
	-- Nothing running is nothing to tell anybody about.
	if crate.step == nil and crate.pendingVehicle == nil then return end
	crate.step = nil
	crate.claimedAtMs = nil
	crate.pendingVehicle = nil
	announce(crate)
	Open77.log.debug(('[hauling] player %d ended a bar early: %s'):format(player, safe(reason)))
end

--- Forgets a departing player and stands their crate back up.
-- Crates they loaded are trunk items by now and belong to the trunk.
local function forget(playerId)
	local player = tonumber(playerId) or 0
	if player <= 0 then return end
	requestWindows[player] = nil
	logWindows[player] = nil
	told[player] = nil
	sales[player] = nil

	-- COLLECTED FIRST: `putBack` re-keys a crate under a fresh prop id, and adding
	-- a key to a table `pairs` is walking is undefined -- `invalid key to 'next'`.
	local theirs = {}
	for _, crate in pairs(crates) do
		if crate.owner == player then theirs[#theirs + 1] = crate end
	end
	for _, crate in ipairs(theirs) do
		do
			if crate.where == Where.CARRIED then
				putBack(crate, 'the carrier disconnected')
			else
				Claim.Release(crates, crate.id, player)
				crate.pendingVehicle = nil
				announce(crate)
			end
		end
	end
end

--- Creates one crate at each site's first point to find out whether its model is
--- a model the engine knows.
--
-- THE ONLY WAY TO VALIDATE AN ALIAS ON THE SERVER. `Open77.props.catalog()` is
-- always an empty table here, so there is no list to check against and a typo'd
-- alias is otherwise a site whose crates silently never appear -- which looks
-- exactly like a site nobody has visited. This turns that into one loud line at
-- boot and a site that is switched off rather than left pretending.
local function probe()
	for _, siteKey in ipairs(Access.UsableKeys()) do
		local id, reason = spawn(siteKey, 1)
		if id == nil then
			if reason == 'unknown_alias' or reason == 'invalid_model' then
				Access.Condemn(siteKey)
				Open77.log.error(('[hauling] SITE %s IS DISABLED: the engine does not know the ' ..
					'model %q. A MODEL must be a curated prop alias and never a .mesh path -- a ' ..
					'raw mesh renders as placeholder geometry AND cannot be attached at all, so ' ..
					'the pickup would appear to work and nothing would ever be carried')
					:format(safe(siteKey), safe(Access.Model(siteKey))))
			else
				Open77.log.warn(('[hauling] %s: the boot crate was refused (%s); the refill pass ' ..
					'will try again'):format(safe(siteKey), safe(reason)))
			end
		end
	end
end

--- Answers what this server has standing, by site. For the diagnostic.
-- @author dop42
-- @return Result
local function state()
	local sites = {}
	for _, siteKey in ipairs(Access.UsableKeys()) do
		sites[siteKey] = { standing = 0, claimed = 0, carried = 0 }
	end
	for _, crate in pairs(crates) do
		local row = sites[crate.site]
		if row ~= nil then
			row.standing = row.standing + 1
			if crate.where == Where.CLAIMED then row.claimed = row.claimed + 1 end
			if crate.where == Where.CARRIED then row.carried = row.carried + 1 end
		end
	end
	return OPX.Result.Ok({ sites = sites, total = crateCount() })
end

--- Builds the crate registry and declares the operator numbers.
-- @author dop42
function M.Init()
	crates, cooling, told, sales = {}, {}, {}, {}
	sellers = {}
	requestWindows, logWindows = {}, {}

	OPX.Tune.Declare{
		HAUL_REFILL_MS = { value = Access.REFILL_MS, type = 'integer', min = 1000, max = 600000,
			unit = 'ms', apply = 'live', label = 'Crate refill interval', group = 'Hauling',
			order = 1,
			description = 'How often the hauling pass reaps expired claims and puts new crates ' ..
				'on free points.' },
		HAUL_PAY_PER_CRATE = { value = Access.PAY_PER_CRATE, type = 'integer', min = 0,
			max = 100000, apply = 'live', label = 'Pay per crate', group = 'Hauling', order = 2,
			description = 'What one delivered crate pays at a site that names no PAY of its own.' },
	}
end

--- Publishes the server half of the hauling contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('hauling', 1, {
		State = state,
		IsCarrying = isCarrying,
	})
end

--- Wires the requests, the host events and the refill pass.
-- @author dop42
function M.Start()
	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[hauling] config: ' .. line)
	end

	if not propsReady() then
		Open77.log.error('[hauling] the world prop API is unavailable; no crate will be created')
		return
	end

	RegisterNetEvent(M.Event.HELLO, function()
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(requestWindows, player, REQUESTS_PER_WINDOW, REQUEST_WINDOW_MS) then
			return
		end
		told[player] = true
		sendSnapshot(player)
		TriggerClientEvent(M.Event.SELLERS, player, sellerList())
		answer(player, true, nil)
	end)

	RegisterNetEvent(M.Event.BEGIN, function(step, subject)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(requestWindows, player, REQUESTS_PER_WINDOW, REQUEST_WINDOW_MS) then
			return answer(player, false, 'rate_limited')
		end

		-- THE SUBJECT IS A NAME, and a name is a string or a number. Everything
		-- below hands it to a host native or to a format string, and a client is
		-- free to put a table on the wire: `Open77.vehicles.get({})` is a raise
		-- inside a network handler, which takes the handler down for the rest of the
		-- request rather than refusing one player.
		if type(subject) ~= 'string' and type(subject) ~= 'number' then
			return answer(player, false, 'invalid_subject')
		end

		-- A NEW STEP ENDS A SALE. The client runs one bar at a time, so a pickup or
		-- a load asked for means the sale bar is no longer up; left standing, the
		-- sale would take the FINISH that bar sends and the pickup would never end.
		if step ~= Step.DELIVER then sales[player] = nil end

		-- ON A THREAD OF ITS OWN, as every other handler here that reaches the
		-- inventory does: a sale counts the stock, which yields, and a handler is
		-- not something to leave suspended on the platform's event dispatch.
		CreateThread(function()
			local ok, reason
			if step == Step.PICKUP then
				ok, reason = beginPickup(player, subject)
			elseif step == Step.LOAD then
				ok, reason = beginLoad(player, subject)
			elseif step == Step.DELIVER then
				ok, reason = beginSale(player, subject)
			else
				ok, reason = false, 'unknown_step'
			end

			-- A sale runs its own bar; the other two steps run the crate's.
			if ok and step ~= Step.DELIVER then
				local crate = Claim.HeldBy(crates, player)
				if crate ~= nil then runBar(player, crate.step, crate.id, crate.site) end
			end
			answer(player, ok, reason)
			if not ok and within(logWindows, player, 1, 1000) then
				Open77.log.info(('[hauling] player %d refused %s on %s: %s'):format(player,
					safe(step), safe(subject), safe(reason)))
			end
		end)
	end)

	RegisterNetEvent(M.Event.FINISH, function()
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(requestWindows, player, REQUESTS_PER_WINDOW, REQUEST_WINDOW_MS) then
			return answer(player, false, 'rate_limited')
		end
		-- On a thread: a load and a sale move crates through the inventory, and
		-- every one of those calls yields. Run inline, a FINISH whose handler was
		-- not resumed after its first yield took the crates and never paid, or left
		-- a crate `loading` for good. What the record guards (a sale cleared before
		-- its first yield, `crate.loading`) is unchanged and still holds against a
		-- second FINISH arriving meanwhile.
		CreateThread(function()
			local ok, reason = complete(player)
			answer(player, ok, reason)
			if not ok and within(logWindows, player, 1, 1000) then
				Open77.log.info(('[hauling] player %d could not finish: %s'):format(player,
					safe(reason)))
			end
		end)
	end)

	RegisterNetEvent(M.Event.DROP, function(where)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not within(requestWindows, player, REQUESTS_PER_WINDOW, REQUEST_WINDOW_MS) then
			return answer(player, false, 'rate_limited')
		end
		local yaw, groundZ = nil, nil
		if type(where) == 'number' then
			yaw = where
		elseif type(where) == 'table' then
			if type(where.yaw) == 'number' then yaw = where.yaw end
			if type(where.z) == 'number' then groundZ = where.z end
		end
		local ok, reason = dropCrate(player, yaw, groundZ)
		answer(player, ok, ok and 'dropped' or reason)
	end)

	RegisterNetEvent(M.Event.ABORT, function(reason)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		-- Counted like every other door: each abort that ends a bar announces the
		-- crate to every client, so an unmetered one was a broadcast on demand.
		if not within(requestWindows, player, REQUESTS_PER_WINDOW, REQUEST_WINDOW_MS) then
			return answer(player, false, 'rate_limited')
		end
		abort(player, tostring(reason))
		answer(player, true, 'aborted')
	end)

	-- THE AUTHORITATIVE END OF A CARRY. Death, disconnect, parent removal and a
	-- bucket change all detach a prop without this module being asked, and this
	-- event is the only thing that reports all four. `current` nil is the prop
	-- coming loose; anything else is a rebinding we asked for.
	AddEventHandler(M.PROP_ATTACHMENT_CHANGED, function(id, current, _, reason, revision)
		local crate = crates[id]
		if crate == nil then return end
		local fresh = integer(revision)
		if fresh ~= nil then crate.revision = fresh end
		if current ~= nil then return end
		if crate.where ~= Where.CARRIED then return end
		-- THE CARRIER IS TOLD, as the seat handler below tells them. `carrying`
		-- on the client moves only on an ANSWER, so a carry the platform ended --
		-- a death, a bucket change -- left the client sure it still held the
		-- crate: weapons blocked, every other crate refused as "already
		-- carrying", until some unrelated request happened to be answered.
		local owner = crate.owner
		putBack(crate, ('the attachment ended (%s)'):format(safe(reason)))
		if owner ~= nil then answer(owner, false, 'carry_ended') end
	end)

	AddEventHandler(M.PROP_REMOVED, function(id, reason)
		local crate = crates[id]
		if crate == nil then return end
		-- The host dropped a crate this module still thought it had. Forget it and
		-- let the point cool, rather than leaving a record nothing can ever satisfy.
		-- Whoever held or was lifting it is told, for the reason given above.
		local owner = crate.owner
		retire(crate, ('the host removed it (%s)'):format(safe(reason)))
		if owner ~= nil then answer(owner, false, 'carry_ended') end
	end)

	-- GETTING INTO A CAR IS NOT A WAY TO LOAD A CRATE. The platform detaches on
	-- death, disconnect, parent removal and bucket change -- and a seat is none of
	-- those, so without this the carrier keeps the crate stuck to their chest
	-- inside the cabin and drives off with it, bypassing the load action that is
	-- the only thing that puts the crate in the bed where everybody can see it.
	AddEventHandler(M.PLAYER_ENTERED_VEHICLE, function(playerId)
		local player = tonumber(playerId) or 0
		if player <= 0 then return end
		local crate = Claim.HeldBy(crates, player)
		if crate == nil or crate.where ~= Where.CARRIED then return end
		-- AT THEIR FEET, NOT BACK ON ITS POINT. It used to go home: a crate
		-- carried across the yard teleported back and was offered to rivals. The
		-- lead's decision is that it is put down where the player got in. A bar
		-- under way ends with it; a trunk write already running is left to land.
		if crate.loading then return end
		crate.step, crate.claimedAtMs, crate.pendingVehicle = nil, nil, nil
		local put = dropCrate(player, nil, nil)
		if not put then
			putBack(crate, ('player %d got into a vehicle while carrying it'):format(player))
		end
		answer(player, false, 'carry_dropped')
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, forget)

	-- The boot probe, on a thread: `Start` may yield and the probe is a host call
	-- per site, which is work that has no business delaying the rest of the phase.
	CreateThread(function()
		local ok, failure = pcall(probe)
		if not ok then
			Open77.log.error('[hauling] the boot crate probe failed: ' .. tostring(failure))
		end
		local placed, why = pcall(spawnSellers)
		if not placed then
			Open77.log.error('[hauling] placing the sellers failed: ' .. tostring(why))
		end
	end)

	-- `integer|function`, and a function is re-read EVERY PASS, which is the whole
	-- reason the tunable is worth declaring: an operator retunes the spawn rate
	-- from the panel and the next pass uses it. The client half of `Every` takes a
	-- number only and raises on a function; this is the server half.
	refillJob = OPX.Scheduler.Every('hauling:refill', function()
		return OPX.Tune.Number('HAUL_REFILL_MS', Access.REFILL_MS)
	end, refillOnce)

	local keys = Access.UsableKeys()
	if #keys == 0 then
		Open77.log.error('[hauling] NOT ONE SITE IS USABLE, so no crate will ever appear. ' ..
			'The lines above say why; the shipped sites are placeholders and every position ' ..
			'in config/hauling.lua has to be surveyed in game before this job exists')
		return
	end
	Open77.log.info(('[hauling] ready: %d site(s) -- %s'):format(#keys, table.concat(keys, ', ')))
end

--- Stops the refill pass and stands every carried crate back up.
-- @author dop42
function M.Stop()
	removeSellers()
	if refillJob ~= nil then
		OPX.Scheduler.Cancel(refillJob)
		refillJob = nil
	end
	-- Collected first, as in `forget`: `putBack` re-keys the table.
	local carried = {}
	for _, crate in pairs(crates) do
		if crate.where == Where.CARRIED then carried[#carried + 1] = crate end
	end
	for _, crate in ipairs(carried) do
		do
			pcall(putBack, crate, 'the resource stopped')
		end
	end
end
