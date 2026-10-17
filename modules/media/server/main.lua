--- Server half: breaking news, photos, stories, the editor desk, the tips line
--- and the press kit.
-- @author dop42
--
-- THIS FILE IS THE NEWSROOM. A client names a desk, types a headline or a
-- story, uses a camera from its bag; every other fact is read here: the job,
-- grade and duty from the character contract, the newsroom from the
-- character's metadata, the position and bucket from the host, the camera,
-- photos and stories from the inventory contract, the clock from this VM.
--
-- BREAKING NEWS rides the staff announcement's own path: one net event per
-- connected player, drawn by the client on the runtime's overlay with the two
-- stingers its own config names, plus a chat line on core's answer channel.
-- It is held to three floors -- one newsroom, every newsroom, and an hourly
-- count -- because every break lands on every screen in the city.
--
-- A PHOTO is a server-timed `progress` bar; the camera must still be in its
-- slot and the reporter where they started when it ends. Then, and only when
-- the operator named an UPLOAD_URL, the server asks the client for a real
-- screenshot (`Open77.players.requestScreenshot`, delivered by the client to
-- that URL -- the picture never crosses the game transport). Either way the
-- photo item carries the server's reads: where, when, who, how many in frame.
--
-- THE DESK PAYS IN THIS ORDER: the pieces leave the bag first, then the money
-- leaves the newsroom's treasury (`accounts.Withdraw`, idempotent by opId) or
-- is minted under MINT_PER_HOUR when there is no treasury, then the reporter
-- is paid. A refusal at any step puts back what moved before it.

local M = OPX.Modules.Get('media')
local Model = M.Model
local Command = M.Command

local OWNER = 'media'

local built = nil
-- network -> ms of its last break; ms of the last break anywhere; network ->
-- { at } in ms for the hourly count; the read-back feed, newest first.
local lastBreak, lastAnyBreak, breaks, feed = {}, nil, {}, {}
-- Anonymous tips, newest first: { id, text, at } (wall seconds).
local tips, tipSerial = {}, 0
-- citizen id -> { at } wall seconds, for the hourly photo and story caps.
local photosBy, storiesBy = {}, {}
-- citizen id -> { at, amount }; network -> { at, amount }; desk id -> { x, y, z, at }.
local paidTo, minted, bought = {}, {}, {}
-- Caps and scene deduplication span desks and reporters; one sale owns them until settlement.
local selling = false
-- player -> the photo being framed: { slot, at, cid, network, barId }.
local shoots = {}
-- A per-process counter for serials and idempotency keys.
local serial = 0

-- ── reading the world ───────────────────────────────────────────────────────

local function pointOf(player)
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y), OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end

local function distance(a, x, y, z)
	local dx, dy, dz = a.x - x, a.y - y, a.z - z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Wall-clock seconds: what a photo, a story and a tip are stamped with,
--- because a photo outlives the process.
local function wallS()
	local time = Open77.time
	if type(time) == 'table' and type(time.unix) == 'function' then
		local read, value = pcall(time.unix)
		value = read and OPX.Math.Finite(value) or nil
		if value ~= nil then return value end
	end
	return OPX.Now() / 1000
end

local function nextSerial(prefix)
	serial = serial + 1
	return ('%s-%d-%d'):format(prefix, math.floor(wallS()), serial)
end

local function character() return OPX.Api.Get('character') end
local function inventory() return OPX.Api.Get('inventory') end

local function playerOf(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, value = pcall(api.GetPlayer, player)
	if not read or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return value
end

local function nameOf(loaded)
	local info = loaded.PlayerData.charInfo
	if type(info) ~= 'table' then return '?' end
	return OPX.Text.Clean(('%s %s'):format(tostring(info.firstName or ''), tostring(info.lastName or '')), 64) or '?'
end

local function valueOf(fn, ...)
	if type(fn) ~= 'function' then return nil end
	local read, answer = pcall(fn, ...)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return nil end
	return answer.value
end

local function itemsOf(player)
	local api = inventory()
	local bag = api and valueOf(api.GetInventory, player) or nil
	return type(bag) == 'table' and type(bag.items) == 'table' and bag.items or {}
end

local function stackAt(player, slot)
	local api = inventory()
	local stack = api and slot and valueOf(api.GetSlot, player, slot) or nil
	return type(stack) == 'table' and stack or nil
end

local function down(player)
	return OPX.Life ~= nil and type(OPX.Life.Down) == 'function' and OPX.Life.Down(player) == true
end

-- ── answers ─────────────────────────────────────────────────────────────────

--- Tells one player how a request went, as a toast from the catalogue.
local function answer(player, ok, code, params)
	local key = (ok and 'media.answer.' or 'media.error.') .. tostring(code)
	if not OPX.Locale.Exists(key) then key = ok and 'media.answer.done' or 'media.error.invalid' end
	pcall(OPX.NotifyLocale, player, key, params, ok and 'success' or 'error')
	return ok, code
end

-- ── who is asking ───────────────────────────────────────────────────────────

local function gradeLabel(grade)
	local key = ('character.grade.%s.%d'):format(built.job, grade)
	-- The catalogue carries every shipped grade (the labels test holds it to
	-- that); a grade an operator added without a line reads as its number.
	if OPX.Locale.Exists(key) then return locale(key) end
	return tostring(grade)
end

local function networkRecord(player)
	local api = character()
	if api == nil or type(api.GetMetadata) ~= 'function' then return nil end
	local read, value = pcall(api.GetMetadata, player, built.metadata)
	return read and value or nil
end

--- The reporter asking, or nil and why: `{ loaded, cid, grade, network,
--- name }`. `needDuty = false` lets an off-duty reporter through.
local function reporterOf(player, needDuty)
	local loaded = playerOf(player)
	if loaded == nil then return nil, 'no_character' end
	local job = loaded.PlayerData.job
	if type(job) ~= 'table' or job.name ~= built.job then return nil, 'not_reporter' end
	if needDuty ~= false and built.onDuty and job.onDuty ~= true then return nil, 'off_duty' end
	local grade = type(job.grade) == 'table' and math.tointeger(OPX.Math.Finite(job.grade.level) or 0) or 0
	return {
		loaded = loaded,
		cid = loaded.PlayerData.citizenId,
		grade = grade or 0,
		network = Model.NetworkOf(built, networkRecord(player)),
		name = nameOf(loaded),
	}
end

--- Every reporter on duty, as player ids.
local function onDutyReporters()
	local api = character()
	if api == nil or type(api.GetPlayersByJob) ~= 'function' then return {} end
	local read, list = pcall(api.GetPlayersByJob, built.job, built.onDuty)
	local out = {}
	if read and type(list) == 'table' then
		for index = 1, #list do
			local other = type(list[index]) == 'table' and list[index].PlayerData and list[index].PlayerData.source
			if math.tointeger(other) ~= nil then out[#out + 1] = other end
		end
	end
	return out
end

local function everybody()
	local read, players = pcall(Open77.players.all)
	local ids = {}
	for _, value in ipairs(read and type(players) == 'table' and players or {}) do
		local id = math.tointeger(tonumber(value))
		if id ~= nil and id > 0 then ids[#ids + 1] = id end
	end
	return ids
end

-- ── breaking news ───────────────────────────────────────────────────────────

--- Airs a break for the sender's newsroom to every connected player.
-- @author dop42
-- @param player integer
-- @param payload table { headline, text }
-- @return boolean ok
-- @return string code
function M.Breaking(player, payload)
	if OPX.Cooling(player, 'media.request', built.requestMs) then return answer(player, false, 'too_fast') end
	local who, why = reporterOf(player)
	if who == nil then return answer(player, false, why) end
	local rules = built.broadcast
	if who.grade < rules.minGrade then
		return answer(player, false, 'grade_too_low', { grade = gradeLabel(rules.minGrade) })
	end
	local network = built.networks[who.network]
	if network == nil or not network.broadcast then return answer(player, false, 'off_air') end
	payload = type(payload) == 'table' and payload or {}
	local headline, bad = Model.Line(payload.headline, rules.headline)
	if headline == nil then
		return answer(player, false, 'headline_' .. bad, { min = rules.headline.min, max = rules.headline.max })
	end
	local text
	text, bad = Model.Line(payload.text, rules.text)
	if text == nil then
		return answer(player, false, 'text_' .. bad, { min = rules.text.min, max = rules.text.max })
	end

	local now = OPX.Now()
	local waitMs = 0
	if lastAnyBreak ~= nil then waitMs = math.max(waitMs, rules.globalCooldownMs - (now - lastAnyBreak)) end
	if lastBreak[network.key] ~= nil then
		waitMs = math.max(waitMs, rules.networkCooldownMs - (now - lastBreak[network.key]))
	end
	if waitMs > 0 then return answer(player, false, 'air_busy', { seconds = math.ceil(waitMs / 1000) }) end
	local recent = {}
	for _, at in ipairs(breaks[network.key] or {}) do
		if now - at < 3600000 then recent[#recent + 1] = at end
	end
	if #recent >= rules.maxPerHour then return answer(player, false, 'air_quota', { count = rules.maxPerHour }) end
	recent[#recent + 1] = now
	breaks[network.key] = recent
	lastBreak[network.key], lastAnyBreak = now, now

	local message = { network = network.key, tag = network.tag, label = network.label, headline = headline,
		text = text ~= '' and text or nil, durationMs = rules.durationMs }
	local line = text ~= '' and ('[%s] %s - %s'):format(network.tag, headline, text)
		or ('[%s] %s'):format(network.tag, headline)
	local delivered = 0
	for _, id in ipairs(everybody()) do
		-- Best effort per player, like the staff announcement: one client that
		-- cannot be reached must not stop the break reaching the rest.
		if pcall(TriggerClientEvent, M.Event.BROADCAST, id, message) then delivered = delivered + 1 end
		if rules.chat then pcall(OPX.CommandResult, id, true, line) end
	end
	table.insert(feed, 1, { tag = network.tag, headline = headline, text = text, at = wallS() })
	while #feed > rules.feed do feed[#feed] = nil end
	OPX.Audit.Log({ event = 'media.broadcast', message = ('%s (%s) aired on %s: %s'):format(who.cid, who.name,
		network.key, line), data = { network = network.key, delivered = delivered }, source = player,
		citizenId = who.cid })
	OPX.Publish(M.Event.ON_BROADCAST, player, { network = network.key, headline = headline, text = text })
	return answer(player, true, 'aired', { count = delivered, network = network.label })
end

-- ── stories ─────────────────────────────────────────────────────────────────

local function hourly(store, cid, nowS)
	store[cid] = Model.Prune(store[cid], nowS)
	return store[cid]
end

local function unreserve(store, cid, stamp)
	for index, row in ipairs(store[cid] or {}) do
		if row == stamp then table.remove(store[cid], index); return end
	end
end

local function canCarry(player, name)
	local api = inventory()
	if api == nil or type(api.CanCarry) ~= 'function' then return true end
	local value = valueOf(api.CanCarry, player, name, 1)
	return value ~= false
end

local function give(player, name, metadata)
	local api = inventory()
	if api == nil or type(api.AddItem) ~= 'function' then return false end
	local read, added = pcall(api.AddItem, player, name, 1, metadata)
	return read and type(added) == 'table' and added.ok == true
end

--- Files a story: a `press_story` item with the headline and body on it.
-- @author dop42
-- @param player integer
-- @param payload table { headline, body }
-- @return boolean ok
-- @return string code
function M.Story(player, payload)
	if OPX.Cooling(player, 'media.request', built.requestMs) then return answer(player, false, 'too_fast') end
	local who, why = reporterOf(player)
	if who == nil then return answer(player, false, why) end
	local rules = built.story
	if who.grade < rules.minGrade then
		return answer(player, false, 'grade_too_low', { grade = gradeLabel(rules.minGrade) })
	end
	payload = type(payload) == 'table' and payload or {}
	local headline, bad = Model.Line(payload.headline, rules.headline)
	if headline == nil then
		return answer(player, false, 'headline_' .. bad, { min = rules.headline.min, max = rules.headline.max })
	end
	local body
	body, bad = Model.Line(payload.body, rules.body)
	if body == nil then return answer(player, false, 'body_' .. bad, { min = rules.body.min, max = rules.body.max }) end
	local nowS = wallS()
	local filed = hourly(storiesBy, who.cid, nowS)
	local last = filed[#filed]
	if last ~= nil and (nowS - last.at) * 1000 < rules.cooldownMs then
		return answer(player, false, 'story_too_soon', { seconds = math.ceil(rules.cooldownMs / 1000 - (nowS - last.at)) })
	end
	if #filed >= rules.maxPerHour then return answer(player, false, 'story_quota', { count = rules.maxPerHour }) end
	-- Reserve before bag operations yield, so overlapping drafts count against
	-- the same allowance. A failed delivery gives its reservation back.
	local stamp = { at = nowS }
	filed[#filed + 1] = stamp
	local item = built.items.story
	if not canCarry(who.cid, item.name) then
		unreserve(storiesBy, who.cid, stamp)
		return answer(player, false, 'bag_full')
	end
	if playerOf(player) ~= who.loaded then unreserve(storiesBy, who.cid, stamp); return false, 'no_character' end
	local metadata = {
		serial = nextSerial('S'), network = who.network, by = who.cid, author = who.name,
		headline = headline, body = body, words = Model.Words(body), at = math.floor(nowS),
		label = OPX.Text.Clean(headline, 48),
	}
	if not give(who.cid, item.name, metadata) then
		unreserve(storiesBy, who.cid, stamp)
		return answer(player, false, 'bag_full')
	end
	OPX.Audit.Log({ event = 'media.story', message = ('%s filed "%s" (%d words)'):format(who.cid, headline,
		metadata.words), data = { serial = metadata.serial, network = who.network }, source = player,
		citizenId = who.cid })
	return answer(player, true, 'story_filed', { headline = headline })
end

-- ── photos ──────────────────────────────────────────────────────────────────

local function progressApi()
	local api = OPX.Api.Get('progress')
	if api == nil or type(api.Start) ~= 'function' then return nil end
	return api
end

--- Other players within the crowd radius, same bucket.
local function crowdAround(player, at)
	local count = 0
	if built.photo.crowdRadius <= 0 then return 0 end
	for _, id in ipairs(everybody()) do
		if id ~= player then
			local other = pointOf(id)
			if other ~= nil and other.bucket == at.bucket
				and distance(other, at.x, at.y, at.z) <= built.photo.crowdRadius then
				count = count + 1
			end
		end
	end
	return count
end

--- The real picture, when the operator named somewhere for it to go. Answers
--- whether the client's upload was taken (HTTP 2xx). Yields: thread only.
local function screenshot(player, metadata)
	local rules = built.photo
	if rules.uploadUrl == '' then return false, 'no_url' end
	local players = Open77.players
	if type(players) ~= 'table' or type(players.requestScreenshot) ~= 'function' then return false, 'no_native' end
	local read, promise, why = pcall(players.requestScreenshot, player, {
		url = rules.uploadUrl, format = rules.upload.format, quality = rules.upload.quality,
		scale = rules.upload.scale, timeout = rules.upload.timeoutMs,
		filename = ('%s.%s'):format(metadata.serial, rules.upload.format == 'png' and 'png' or 'jpg'),
		fields = { serial = metadata.serial, network = metadata.network, by = metadata.by },
	})
	if not read or promise == nil then return false, tostring(read and why or promise) end
	local awaited, receipt, failure = pcall(function() return promise:await() end)
	if not awaited or type(receipt) ~= 'table' then return false, tostring(awaited and failure or receipt) end
	local status = math.tointeger(receipt.status) or 0
	return status >= 200 and status < 300, ('http_%d'):format(status)
end

--- The shot is framed: check again, maybe upload, then the photo item.
local function develop(player, shoot)
	local who = reporterOf(player)
	if who == nil or who.cid ~= shoot.cid then return answer(player, false, 'photo_lost') end
	local stack = stackAt(player, shoot.slot)
	if stack == nil or stack.name ~= built.items.camera.name then return answer(player, false, 'no_camera') end
	if down(player) then return answer(player, false, 'player_down') end
	local at = pointOf(player)
	if at == nil or at.bucket ~= shoot.at.bucket
		or distance(at, shoot.at.x, shoot.at.y, shoot.at.z) > built.photo.maxDrift then
		return answer(player, false, 'photo_moved')
	end
	local nowS = wallS()
	local taken = hourly(photosBy, who.cid, nowS)
	if #taken >= built.photo.maxPerHour then
		return answer(player, false, 'photo_quota', { count = built.photo.maxPerHour })
	end
	local stamp = { at = nowS }
	taken[#taken + 1] = stamp
	local metadata = {
		serial = nextSerial('P'), network = who.network, by = who.cid, author = who.name,
		x = math.floor(at.x * 10 + 0.5) / 10, y = math.floor(at.y * 10 + 0.5) / 10,
		z = math.floor(at.z * 10 + 0.5) / 10, bucket = at.bucket,
		at = math.floor(nowS), crowd = crowdAround(player, at), uploaded = false,
	}
	local uploaded, how = screenshot(player, metadata)
	metadata.uploaded = uploaded == true
	if not give(who.cid, built.items.photo.name, metadata) then
		unreserve(photosBy, who.cid, stamp)
		return answer(player, false, 'bag_full')
	end
	OPX.Audit.Log({ event = 'media.photo', message = ('%s shot %s at %.1f %.1f %.1f (crowd %d, upload %s)'):format(
		who.cid, metadata.serial, metadata.x, metadata.y, metadata.z, metadata.crowd, tostring(how)),
		data = { serial = metadata.serial, uploaded = metadata.uploaded }, source = player, citizenId = who.cid })
	OPX.Publish(M.Event.ON_PHOTO, player, { serial = metadata.serial, network = metadata.network, x = metadata.x,
		y = metadata.y, z = metadata.z, crowd = metadata.crowd, uploaded = metadata.uploaded })
	return answer(player, true, metadata.uploaded and 'photo_uploaded' or 'photo_taken', { crowd = metadata.crowd })
end

--- Frames a photo with the camera in a slot: a server-timed bar, then the
--- photo. Answers the code the reporter was told.
-- @author dop42
-- @param player integer
-- @param slot integer
-- @return boolean ok
-- @return string code
function M.TakePhoto(player, slot)
	if OPX.Cooling(player, 'media.request', built.requestMs) then return answer(player, false, 'too_fast') end
	if shoots[player] ~= nil then return answer(player, false, 'busy') end
	local who, why = reporterOf(player)
	if who == nil then return answer(player, false, why) end
	local rules = built.photo
	if who.grade < rules.minGrade then
		return answer(player, false, 'grade_too_low', { grade = gradeLabel(rules.minGrade) })
	end
	slot = math.tointeger(slot)
	local stack = stackAt(player, slot)
	if stack == nil or stack.name ~= built.items.camera.name then return answer(player, false, 'no_camera') end
	if down(player) then return answer(player, false, 'player_down') end
	local at = pointOf(player)
	if at == nil then return answer(player, false, 'no_position') end
	if #hourly(photosBy, who.cid, wallS()) >= rules.maxPerHour then
		return answer(player, false, 'photo_quota', { count = rules.maxPerHour })
	end
	if not canCarry(player, built.items.photo.name) then return answer(player, false, 'bag_full') end
	local shoot = { slot = slot, at = at, cid = who.cid }
	local api = progressApi()
	if api == nil or rules.durationMs <= 0 then
		shoots[player] = shoot
		local ok, code = develop(player, shoot)
		shoots[player] = nil
		return ok, code
	end
	shoots[player] = shoot
	local started = api.Start(player, OWNER, {
		label = locale('media.bar.photo'),
		durationMs = rules.durationMs,
		cancelable = true,
		animation = rules.animation and { name = rules.animation } or nil,
	}, function(who2, outcome)
		local current = shoots[who2]
		if current == nil or type(outcome) ~= 'table' or outcome.id ~= current.barId then return end
		shoots[who2] = nil
		if outcome.completed ~= true then
			if outcome.ending ~= 'left' then answer(who2, false, 'photo_cancelled') end
			return
		end
		-- Its own thread: the upload awaits the client's receipt.
		CreateThread(function() develop(who2, current) end)
	end)
	if type(started) ~= 'table' or not started.ok then
		shoots[player] = nil
		return answer(player, false, 'busy')
	end
	shoot.barId = started.value.id
	return true, 'framing'
end

-- ── the desk ────────────────────────────────────────────────────────────────

local function deskOf(network, key)
	local room = type(network) == 'string' and built.networks[network] or nil
	if room == nil then return nil end
	for _, desk in ipairs(room.desks) do
		if desk.key == key then return desk end
	end
	return nil
end

local function accountsApi()
	local api = OPX.Api.Get('accounts')
	if api == nil or type(api.Withdraw) ~= 'function' then return nil end
	return api
end

--- Sells every photo and story of the reporter's own byline to a desk.
-- @author dop42
-- @param player integer
-- @param payload table { network, desk }
-- @return boolean ok
-- @return string code
local function sellOnce(player, payload)
	if OPX.Cooling(player, 'media.request', built.requestMs) then return answer(player, false, 'too_fast') end
	payload = type(payload) == 'table' and payload or {}
	local desk = deskOf(payload.network, payload.desk)
	if desk == nil then return answer(player, false, 'unknown_desk') end
	local who, why = reporterOf(player)
	if who == nil then return answer(player, false, why) end
	if not Model.MaySellTo(built, who.grade, who.network, desk.network) then
		return answer(player, false, 'wrong_newsroom', { network = built.networks[desk.network].label })
	end
	if down(player) then return answer(player, false, 'player_down') end
	local at = pointOf(player)
	if at == nil then return answer(player, false, 'no_position') end
	if at.bucket ~= desk.bucket or distance(at, desk.x, desk.y, desk.z) > OPX.Spots.ServerReach(desk.radius) then
		return answer(player, false, 'too_far')
	end
	local api = inventory()
	if api == nil or type(api.RemoveFromSlot) ~= 'function' then return answer(player, false, 'no_inventory') end

	local network = built.networks[desk.network]
	local treasury = network.account ~= nil and accountsApi() or nil
	local nowS = wallS()
	local deskId = desk.network .. '/' .. desk.key
	bought[deskId] = Model.Prune(bought[deskId], nowS, built.sales.repeatS)
	paidTo[who.cid] = Model.Prune(paidTo[who.cid], nowS)
	minted[network.key] = Model.Prune(minted[network.key], nowS)
	local room = Model.Left(paidTo[who.cid], built.sales.sellerCap, nowS)
	if treasury == nil then room = math.min(room, Model.Left(minted[network.key], built.sales.mintCap, nowS)) end

	local photoName, storyName = built.items.photo.name, built.items.story.name
	local picked, total, foreign, capped, photos, stories, old = {}, 0, 0, 0, 0, 0, 0
	-- The desk's recent purchases plus what this sale has picked so far: two
	-- photos of one scene sold together are one scoop, and the second is old news.
	local scene = {}
	for index, row in ipairs(bought[deskId]) do scene[index] = row end
	for _, item in ipairs(itemsOf(player)) do
		if type(item) == 'table' and (item.name == photoName or item.name == storyName) then
			local metadata = type(item.metadata) == 'table' and item.metadata or {}
			if metadata.by ~= who.cid then
				foreign = foreign + 1
			else
				local price, repeated
				if item.name == photoName then
					price, repeated = Model.PhotoPrice(built, desk, metadata, scene, nowS)
				else
					price = Model.StoryPrice(built, desk, metadata, nowS)
				end
				local count = math.max(1, math.tointeger(item.count) or 1)
				for _ = 1, count do
					if total + price > room then
						capped = capped + 1
					else
						picked[#picked + 1] = { slot = item.slot, name = item.name, metadata = metadata, price = price }
						total = total + price
						if item.name == photoName then
							photos = photos + 1
							if repeated then old = old + 1 end
							scene[#scene + 1] = { x = OPX.Math.Finite(metadata.x) or 0, y = OPX.Math.Finite(metadata.y) or 0,
								z = OPX.Math.Finite(metadata.z) or 0, at = nowS }
						else
							stories = stories + 1
						end
					end
				end
			end
		end
	end
	if #picked == 0 then
		if capped > 0 then return answer(player, false, 'desk_capped') end
		return answer(player, false, foreign > 0 and 'not_your_byline' or 'nothing_to_sell')
	end

	-- 1. The pieces leave the bag.
	local removed = {}
	for _, piece in ipairs(picked) do
		local read, done = pcall(api.RemoveFromSlot, who.cid, piece.slot, 1, piece)
		if read and type(done) == 'table' and done.ok == true then
			removed[#removed + 1] = piece
		else
			total = total - piece.price
		end
	end
	local function putBack()
		for _, piece in ipairs(removed) do pcall(api.AddItem, who.cid, piece.name, 1, piece.metadata) end
	end
	if #removed == 0 then return answer(player, false, 'nothing_to_sell') end

	-- 2. The money leaves the newsroom (or is minted under the cap).
	local opId = ('media:%s:%s'):format(who.cid, nextSerial('sale'))
	local reason = ('media:desk:%s'):format(deskId)
	local fundedFrom = 'mint'
	if total > 0 and treasury ~= nil then
		local read, result = pcall(treasury.Withdraw, network.account.kind, network.account.key, total, reason, opId)
		if not read or type(result) ~= 'table' or result.ok ~= true then
			putBack()
			local code = read and type(result) == 'table' and result.error or nil
			return answer(player, false, code == 'insufficient_funds' and 'desk_broke' or 'desk_closed')
		end
		fundedFrom = 'accounts'
	end

	-- 3. The reporter is paid.
	local paid = total <= 0
	if not paid then
		local money = character()
		if money ~= nil and type(money.AddMoneyOffline) == 'function' then
			local read, result = pcall(money.AddMoneyOffline, who.cid, built.currency, total, reason)
			paid = read and type(result) == 'table' and result.ok == true
		end
	end
	if not paid then
		if fundedFrom == 'accounts' then
			pcall(treasury.Deposit, network.account.kind, network.account.key, total, reason .. ':refund', opId .. ':refund')
		end
		putBack()
		return answer(player, false, 'sale_failed')
	end

	local rows = paidTo[who.cid]
	rows[#rows + 1] = { at = nowS, amount = total }
	if fundedFrom == 'mint' then
		local mintRows = minted[network.key]
		mintRows[#mintRows + 1] = { at = nowS, amount = total }
	end
	bought[deskId] = scene
	local serials = {}
	for index = 1, math.min(#removed, 20) do serials[index] = removed[index].metadata.serial end
	OPX.Audit.Log({ event = 'media.sell', message = ('%s sold %d photo(s) and %d story(ies) to %s for %d (%s)')
		:format(who.cid, photos, stories, deskId, total, fundedFrom), data = { desk = deskId, total = total,
		source = fundedFrom, serials = serials, opId = opId }, source = player, citizenId = who.cid })
	OPX.Publish(M.Event.ON_SOLD, player, { network = network.key, desk = desk.key, photos = photos,
		stories = stories, total = total, source = fundedFrom })
	return answer(player, true, capped > 0 and 'sold_capped' or (old > 0 and 'sold_old' or 'sold'),
		{ photos = photos, stories = stories, total = OPX.Locale.Money(total, built.currency), desk = desk.label,
			left = capped })
end

--- Serializes the cap check through settlement; always releases after a failure.
function M.Sell(player, payload)
	if selling then return answer(player, false, 'busy') end
	selling = true
	local called, ok, code = pcall(sellOnce, player, payload)
	selling = false
	if not called then
		Open77.log.error(('[media] a desk sale raised: %s'):format(tostring(ok)))
		return answer(player, false, 'sale_failed')
	end
	return ok, code
end

-- ── the tips line ───────────────────────────────────────────────────────────

local function liveTips(nowS)
	local keep = {}
	for _, tip in ipairs(tips) do
		if nowS - tip.at < built.tips.keepS and #keep < built.tips.keep then keep[#keep + 1] = tip end
	end
	tips = keep
	return keep
end

--- Phones an anonymous tip to every reporter on duty.
-- @author dop42
-- @param player integer
-- @param raw string
-- @return boolean ok
-- @return string code
function M.Tip(player, raw)
	local loaded = playerOf(player)
	if loaded == nil then return answer(player, false, 'no_character') end
	local text, bad = Model.Line(raw, { min = built.tips.min, max = built.tips.max })
	if text == nil then return answer(player, false, 'tip_' .. bad, { min = built.tips.min, max = built.tips.max }) end
	if OPX.Cooling(player, 'media.tip', built.tips.cooldownMs) then
		return answer(player, false, 'tip_too_fast', { seconds = math.ceil(built.tips.cooldownMs / 1000) })
	end
	tipSerial = tipSerial + 1
	local nowS = wallS()
	liveTips(nowS)
	if built.tips.keep > 0 then table.insert(tips, 1, { id = tipSerial, text = text, at = nowS }) end
	local receivers = 0
	for _, id in ipairs(onDutyReporters()) do
		if id ~= player then
			if pcall(TriggerClientEvent, M.Event.TIP, id, { id = tipSerial, text = text }) then
				receivers = receivers + 1
			end
			pcall(OPX.CommandResult, id, true, locale('media.tip.line', { id = tipSerial, text = text }))
		end
	end
	-- The caller's identity goes to the journal and nowhere else: a tips line
	-- that could be abused anonymously would be closed by the first operator
	-- who had to answer for it.
	OPX.Audit.Log({ event = 'media.tip', message = ('tip #%d from %s: %s'):format(tipSerial,
		tostring(loaded.PlayerData.citizenId), text), data = { id = tipSerial, receivers = receivers },
		source = player, citizenId = loaded.PlayerData.citizenId })
	OPX.Publish(M.Event.ON_TIP, nil, { id = tipSerial, receivers = receivers })
	if receivers == 0 then return answer(player, true, 'tip_held') end
	return answer(player, true, 'tip_sent', { count = receivers })
end

local function readTips(player)
	local who, why = reporterOf(player)
	if who == nil then return answer(player, false, why) end
	local nowS = wallS()
	local lines = {}
	for _, tip in ipairs(liveTips(nowS)) do
		lines[#lines + 1] = locale('media.tip.old', { id = tip.id, minutes = math.floor((nowS - tip.at) / 60),
			text = tip.text })
	end
	if #lines == 0 then return answer(player, true, 'no_tips') end
	OPX.CommandResult(player, true, table.concat(lines, '\n'))
	return true, 'tips'
end

local function readNews(player)
	if #feed == 0 then return answer(player, true, 'no_news') end
	local nowS = wallS()
	local lines = {}
	for _, row in ipairs(feed) do
		lines[#lines + 1] = locale('media.news.line', { tag = row.tag, headline = row.headline,
			text = row.text or '', minutes = math.floor((nowS - row.at) / 60) })
	end
	OPX.CommandResult(player, true, table.concat(lines, '\n'))
	return true, 'news'
end

-- ── the press kit and the pass ──────────────────────────────────────────────

--- Draws whatever of the kit is missing: the reporter's own pass, a camera.
-- @author dop42
-- @param player integer
-- @return boolean ok
-- @return string code
function M.Kit(player)
	local who, why = reporterOf(player)
	if who == nil then return answer(player, false, why) end
	local passItem, cameraItem = built.items.pass, built.items.camera
	local hasPass, hasCamera = false, false
	for _, item in ipairs(itemsOf(player)) do
		if type(item) == 'table' then
			if item.name == cameraItem.name then hasCamera = true end
			if item.name == passItem.name and type(item.metadata) == 'table' and item.metadata.cid == who.cid
				and item.metadata.network == who.network then
				hasPass = true
			end
		end
	end
	local wantCamera = not hasCamera and who.grade >= built.kit.cameraGrade
	if hasPass and not wantCamera then return answer(player, false, 'kit_full') end
	if OPX.Cooling(player, 'media.kit', built.kit.cooldownMs) then return answer(player, false, 'kit_too_soon') end
	local given = {}
	if not hasPass then
		local network = built.networks[who.network]
		if give(who.cid, passItem.name, { cid = who.cid, name = who.name, network = who.network,
			networkLabel = network and network.label or who.network, grade = who.grade,
			gradeLabel = gradeLabel(who.grade), serial = nextSerial('ID'), issued = math.floor(wallS()),
			label = OPX.Text.Clean(('%s - %s'):format(passItem.label, who.name), 48) }) then
			given[#given + 1] = passItem.label
		end
	end
	if wantCamera and give(who.cid, cameraItem.name, { serial = nextSerial('CAM'), issuedTo = who.cid }) then
		given[#given + 1] = cameraItem.label
	end
	if #given == 0 then return answer(player, false, 'bag_full') end
	OPX.Audit.Log({ event = 'media.kit', message = ('%s drew %s'):format(who.cid, table.concat(given, ', ')),
		source = player, citizenId = who.cid })
	return answer(player, true, 'kit_given', { items = table.concat(given, ', ') })
end

--- A pass shown: everybody near is told whose it is and whether it holds.
local function onPassUsed(source, info)
	local slot = type(info) == 'table' and math.tointeger(info.slot) or nil
	local stack = stackAt(source, slot)
	if stack == nil or stack.name ~= built.items.pass.name or type(stack.metadata) ~= 'table' then
		return { ok = true, consume = 0 }
	end
	if OPX.Cooling(source, 'media.pass', 3000) then return { ok = true, consume = 0 } end
	local metadata = stack.metadata
	local status = 'unverified'
	local api = character()
	if type(metadata.cid) == 'string' and api ~= nil and type(api.GetPlayerByCitizenId) == 'function' then
		local read, holder = pcall(api.GetPlayerByCitizenId, metadata.cid)
		if read and type(holder) == 'table' and type(holder.PlayerData) == 'table' then
			local job = holder.PlayerData.job
			local network = Model.NetworkOf(built, networkRecord(holder.PlayerData.source))
			status = (type(job) == 'table' and job.name == built.job and network == metadata.network) and 'valid'
				or 'revoked'
		end
	end
	local network = built.networks[metadata.network]
	local card = {
		name = OPX.Text.Clean(metadata.name, 64) or '?',
		network = network and network.label or OPX.Text.Clean(metadata.networkLabel, 48) or '?',
		grade = OPX.Text.Clean(metadata.gradeLabel, 48) or '',
		status = status,
	}
	local at = pointOf(source)
	local shown = 0
	for _, id in ipairs(everybody()) do
		local other = id == source and at or pointOf(id)
		if other ~= nil and at ~= nil and other.bucket == at.bucket
			and distance(other, at.x, at.y, at.z) <= built.pass.showRadius then
			pcall(TriggerClientEvent, M.Event.PASS, id, card)
			shown = shown + 1
		end
	end
	if at == nil then pcall(TriggerClientEvent, M.Event.PASS, source, card) end
	return { ok = true, consume = 0 }
end

local function onCameraUsed(source, info)
	local slot = type(info) == 'table' and math.tointeger(info.slot) or nil
	-- Its own thread: the use handler has a deadline, a photo has a bar.
	local loaded = playerOf(source)
	CreateThread(function()
		if loaded == nil or playerOf(source) ~= loaded then return end
		M.TakePhoto(source, slot)
	end)
	return { ok = true, consume = 0 }
end

--- The two item uses, as fields so a test can play a use without the bag.
M.OnPassUsed = onPassUsed
M.OnCameraUsed = onCameraUsed

-- ── newsrooms ───────────────────────────────────────────────────────────────

--- Moves a reporter to a newsroom. `staff` skips the Editor-in-chief rules.
-- @author dop42
-- @param player integer who asks (0 = console)
-- @param target integer
-- @param network string
-- @param staff boolean|nil
-- @return boolean ok
-- @return string code
function M.Assign(player, target, network, staff)
	local function say(ok, code, params)
		if player > 0 then return answer(player, ok, code, params) end
		Open77.log.info(('[media] assign from the console: %s'):format(code))
		return ok, code
	end
	if type(network) ~= 'string' or built.networks[network] == nil then return say(false, 'unknown_network') end
	if not staff then
		local who, why = reporterOf(player, false)
		if who == nil then return say(false, why) end
		if who.grade < built.assignGrade then return say(false, 'grade_too_low', { grade = gradeLabel(built.assignGrade) }) end
		if network ~= who.network then return say(false, 'not_your_newsroom') end
	end
	target = math.tointeger(tonumber(target))
	local loaded = target and playerOf(target) or nil
	if loaded == nil then return say(false, 'no_target') end
	local job = loaded.PlayerData.job
	if type(job) ~= 'table' or job.name ~= built.job then return say(false, 'target_not_reporter') end
	local api = character()
	if api == nil or type(api.SetMetadata) ~= 'function' then return say(false, 'invalid') end
	local read, set = pcall(api.SetMetadata, target, built.metadata, { network = network })
	if not read or set == false then return say(false, 'invalid') end
	local label = built.networks[network].label
	OPX.Audit.Log({ event = 'media.assign', message = ('%s moved %s to %s'):format(
		player > 0 and tostring((playerOf(player) or { PlayerData = {} }).PlayerData.citizenId) or 'console',
		tostring(loaded.PlayerData.citizenId), network), source = player > 0 and player or nil,
		citizenId = loaded.PlayerData.citizenId })
	if target ~= player then answer(target, true, 'assigned_you', { network = label }) end
	return say(true, 'assigned', { name = nameOf(loaded), network = label })
end

-- ── staff ───────────────────────────────────────────────────────────────────

local function report(source)
	local lines, names = {}, {}
	for key in pairs(built.networks) do names[#names + 1] = key end
	table.sort(names)
	for _, key in ipairs(names) do
		local network = built.networks[key]
		local desks = {}
		for _, desk in ipairs(network.desks) do desks[#desks + 1] = desk.key end
		lines[#lines + 1] = ('%s [%s] %s desks=%s account=%s%s'):format(key, network.tag, network.label,
			#desks > 0 and table.concat(desks, ',') or '-',
			network.account and (network.account.kind .. ':' .. network.account.key) or 'mint',
			network.broadcast and '' or ' OFF-AIR')
	end
	for _, key in ipairs(built.placeholders) do lines[#lines + 1] = key .. ' DISABLED: not surveyed yet' end
	for _, line in ipairs(built.problems) do lines[#lines + 1] = 'REFUSED: ' .. line end
	lines[#lines + 1] = ('treasury: %s; photo upload: %s'):format(accountsApi() and 'accounts contract' or
		'none (desks mint, capped)', built.photo.uploadUrl ~= '' and 'on' or 'off (records only)')
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

local function capture(source, args)
	if source <= 0 then return OPX.CommandResult(source, false, 'the console stands nowhere') end
	local network, desk = args[1], args[2]
	if not Model.Key(network) or not Model.Key(desk) then
		return OPX.CommandResult(source, false, 'usage: capture <network> <desk>')
	end
	local at = pointOf(source)
	if at == nil then return OPX.CommandResult(source, false, 'your position could not be read') end
	local line = ("NETWORKS.%s.DESKS: { KEY = %q, LABEL = '...', X = %.2f, Y = %.2f, Z = %.2f, RADIUS = 2.0, " ..
		'BUCKET = %d, RATE = 1.0 },'):format(network, desk, at.x, at.y, at.z, at.bucket)
	Open77.log.info(('[media] capture by %d: %s'):format(source, line))
	OPX.Audit.Log({ event = 'media.capture', message = line, source = source })
	OPX.CommandResult(source, true, ('paste into config/media.lua, then restart:\n  %s'):format(line))
end

local function sendForm(player, kind)
	local who, why = reporterOf(player)
	if who == nil then return answer(player, false, why) end
	local network = built.networks[who.network]
	if kind == 'breaking' then
		if who.grade < built.broadcast.minGrade then
			return answer(player, false, 'grade_too_low', { grade = gradeLabel(built.broadcast.minGrade) })
		end
		if network == nil or not network.broadcast then return answer(player, false, 'off_air') end
		TriggerClientEvent(M.Event.FORM, player, { kind = 'breaking', label = network.label,
			headline = built.broadcast.headline, text = built.broadcast.text })
	else
		TriggerClientEvent(M.Event.FORM, player, { kind = 'story', label = network and network.label or '',
			headline = built.story.headline, body = built.story.body })
	end
	return true, 'form'
end

local function registerCommands()
	OPX.Command.Register(Command.BREAKING, { help = 'media.help.breaking', cooldownMs = 500,
		params = { { name = 'headline | text', optional = true, help = locale('media.help.breakingText') } } },
		function(player, args)
			if player <= 0 then return end
			if #args == 0 then return sendForm(player, 'breaking') end
			local headline, text = Model.SplitBreaking(OPX.Text.Rest(args, 1) or '')
			M.Breaking(player, { headline = headline, text = text })
		end)
	OPX.Command.Register(Command.STORY, { help = 'media.help.story', cooldownMs = 500 },
		function(player)
			if player > 0 then sendForm(player, 'story') end
		end)
	OPX.Command.Register(Command.TIP, { help = 'media.help.tip',
		params = { { name = 'text', help = locale('media.help.tipText') } } },
		function(player, args)
			if player > 0 then M.Tip(player, OPX.Text.Rest(args, 1) or '') end
		end)
	OPX.Command.Register(Command.TIPS, { help = 'media.help.tips', cooldownMs = 1000 },
		function(player) if player > 0 then readTips(player) end end)
	OPX.Command.Register(Command.NEWS, { help = 'media.help.news', cooldownMs = 1000 },
		function(player) if player > 0 then readNews(player) end end)
	OPX.Command.Register(Command.KIT, { help = 'media.help.kit', cooldownMs = 1000 },
		function(player) if player > 0 then CreateThread(function() M.Kit(player) end) end end)
	OPX.Command.Register(Command.NETWORK, { help = 'media.help.network', cooldownMs = 1000,
		params = { { name = 'id', optional = true, help = locale('media.help.id') },
			{ name = 'network', optional = true, help = locale('media.help.networkKey') } } },
		function(player, args)
			if player <= 0 then return end
			if args[1] == nil then
				local who, why = reporterOf(player, false)
				if who == nil then return answer(player, false, why) end
				return answer(player, true, 'your_newsroom', { network = built.networks[who.network].label })
			end
			M.Assign(player, args[1], args[2], false)
		end)
	OPX.Command.Register(Command.ASSIGN, { restricted = true, help = 'media.help.assign',
		params = { { name = 'id', help = locale('media.help.id') },
			{ name = 'network', help = locale('media.help.networkKey') } } },
		function(player, args) M.Assign(player, args[1], args[2], true) end)
	OPX.Command.Register(Command.DESKS, { restricted = true, help = 'media.help.desks' },
		function(source) report(source) end)
	OPX.Command.Register(Command.CAPTURE, { restricted = true, help = 'media.help.capture',
		params = { { name = 'network', help = locale('media.help.networkKey') },
			{ name = 'desk', help = locale('media.help.desk') } } },
		function(source, args) capture(source, args) end)
end

-- ── items ───────────────────────────────────────────────────────────────────

local function registerItems()
	local api = inventory()
	if api == nil or type(api.RegisterItem) ~= 'function' then
		Open77.log.warn('[media] no inventory contract: no camera, photo, story or pass item')
		return
	end
	local function register(item, extra)
		local definition = { label = item.label, description = item.description, weight = item.weight, stack = false }
		for key, value in pairs(extra or {}) do definition[key] = value end
		if type(api.GetItem) == 'function' then
			local read, known = pcall(api.GetItem, item.name)
			if read and known ~= nil then return true end
		end
		local read, done = pcall(api.RegisterItem, item.name, definition, OWNER)
		if not read or type(done) ~= 'table' or done.ok ~= true then
			Open77.log.warn(('[media] the item %s could not be registered: %s'):format(item.name,
				tostring(read and type(done) == 'table' and done.error or done)))
			return false
		end
		return true
	end
	local items = built.items
	register(items.photo, { model = 'crate.valuable' })
	register(items.story, { model = 'crate.valuable' })
	if register(items.pass, { model = 'crate.valuable', use = { consume = 0, close = true } })
		and type(api.RegisterUsable) == 'function' then
		pcall(api.RegisterUsable, items.pass.name, onPassUsed, OWNER)
	end
	if register(items.camera, { model = 'electronics.monitor.device', use = { consume = 0, close = true } })
		and type(api.RegisterUsable) == 'function' then
		pcall(api.RegisterUsable, items.camera.name, onCameraUsed, OWNER)
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the newsrooms out of the config. Never yields.
-- @author dop42
function M.Init()
	built = Model.Build(OPX.Config.MODULES.media or M.Settings)
	M.Built = built
	lastBreak, lastAnyBreak, breaks, feed = {}, nil, {}, {}
	tips, tipSerial, photosBy, storiesBy = {}, 0, {}, {}
	paidTo, minted, bought, shoots = {}, {}, {}, {}
	selling = false
end

--- Publishes the server half of the media contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('media', 1, {
		--- The newsroom a player works for, or nil when they are no reporter.
		NetworkOf = function(player)
			local who = reporterOf(player, false)
			return who and who.network or nil
		end,
		--- Every newsroom: key -> { label, tag, broadcast }.
		Networks = function()
			local out = {}
			for key, network in pairs(built.networks) do
				out[key] = { label = network.label, tag = network.tag, broadcast = network.broadcast }
			end
			return out
		end,
		--- The breaks still in the feed, newest first: { tag, headline, text, at }.
		Feed = function() return OPX.Table.DeepCopy(feed) end,
	})
end

--- Registers the items, the net doors and the commands.
-- @author dop42
function M.Start()
	for _, line in ipairs(built.problems) do Open77.log.warn('[media] config: ' .. line) end
	if #built.placeholders > 0 then
		Open77.log.info(('[media] desks disabled until surveyed (/opx.media.capture): %s')
			:format(table.concat(built.placeholders, ', ')))
	end
	if accountsApi() == nil then
		Open77.log.info('[media] no accounts contract: the desks mint their payments, capped by SALES.MINT_PER_HOUR')
	end
	if built.photo.uploadUrl == '' then
		Open77.log.info('[media] no PHOTO.UPLOAD_URL: photos are records of a shot, no screenshot is taken')
	end
	registerItems()

	-- One door, three verbs. A story and a sale read the bag, which yields, so
	-- they run on their own thread rather than holding the event pump.
	local VERBS = { breaking = M.Breaking, story = M.Story, sell = M.Sell }
	RegisterNetEvent(M.Event.REQUEST, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		local verb = type(payload) == 'table' and VERBS[payload.verb] or nil
		if verb == nil then return answer(player, false, 'invalid') end
		local loaded = playerOf(player)
		CreateThread(function()
			if loaded == nil or playerOf(player) ~= loaded then return end
			verb(player, payload)
		end)
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = math.tointeger(tonumber(playerId))
		if player ~= nil then shoots[player] = nil end
	end)

	registerCommands()
end

--- Lets go of the item uses and any shot being framed.
-- @author dop42
function M.Stop()
	local api = inventory()
	if api ~= nil and type(api.UnregisterUsable) == 'function' then
		pcall(api.UnregisterUsable, built.items.pass.name, OWNER)
		pcall(api.UnregisterUsable, built.items.camera.name, OWNER)
	end
	local progress = progressApi()
	for player, shoot in pairs(shoots) do
		if progress ~= nil and type(progress.Stop) == 'function' and shoot.barId ~= nil then
			pcall(progress.Stop, player, OWNER, shoot.barId)
		end
	end
	shoots = {}
end
