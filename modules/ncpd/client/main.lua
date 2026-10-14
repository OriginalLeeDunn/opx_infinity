--- The client half: one stage from the server becomes this client's own heat.
-- @author XEROX710
--
-- WHY THE CLIENT DOES THIS AND NOT THE SERVER. `PreventionSystem`'s 287 methods
-- are all scripted -- not one is native -- and the ones that raise a stage are
-- private, so nothing outside the game's script frame can move a star. `open77-base`
-- therefore carries a narrow seam: `Open77.prevention.heat(playerId, stage)` and
-- `.av(playerId)` queue the request into the REDscript bridge, which executes it
-- inside the script frame the client owns, on the LOCAL player only. The address
-- is the safety property -- a command naming a player this client is not is
-- refused by the bridge and counted -- so this file passes the id the server
-- named and never substitutes its own.
--
-- THE ENGINE OWNS EVERYTHING VISIBLE. The wanted bar, the stars, the siren audio
-- stake, the police radio and the per-stage effects all happen inside the game's
-- own `OnHeatChanged`, which is why there is no HUD drawn here: drawing a second
-- wanted bar over the engine's would be two answers to "how wanted am I".
--
-- A CLIENT WITHOUT THE SEAM SAYS SO ONCE. The seam arrived after the build that
-- shipped it, so an older plugin answers `nil` for `Open77.prevention`. That is a
-- warning once and a named refusal per request, never a silent nothing: the
-- server's ledger still holds the score, and the one line in the log says which
-- half is missing.

local M = OPX.Modules.Get('ncpd')
local Law = M.Law

--- Whether this client has already complained about a missing seam.
local seamWarned = false

--- The stage this client has asked the engine for.
local applied = 0

--- The prevention seam, or nil when this build does not have it.
--
-- ONE SHAPE, AND IT IS THE PLATFORM'S. The seam is `Open77.prevention`, gated by
-- `world.prevention`: `setWanted(stage)` moves this client's own wanted level,
-- `requestAv()` asks the engine's spawn system for the MaxTac AV, and `state()`
-- reports what was asked and what the script loop answered. There is no player
-- argument on any of them, because the engine's wanted level is scalar on a
-- singleton system and the spawn system holds one player handle -- the world
-- this client is simulating is the only world there is to move. The player id in
-- the payload below is therefore the server's bookkeeping and this module's own
-- correlation, never something the engine is told.
-- @return table|nil
local function seam()
	local prevention = Open77 and Open77.prevention
	if type(prevention) ~= 'table' then return nil end
	if type(prevention.setWanted) ~= 'function' then return nil end
	return prevention
end

--- Asks the engine for a heat stage: this client's own wanted level.
-- @param playerId number the player the server named (bookkeeping, not a target)
-- @param stage number 0..5
-- @return boolean accepted
-- @return string|nil why not
local function applyHeat(playerId, stage)
	local prevention = seam()
	if prevention == nil then
		if not seamWarned then
			seamWarned = true
			Open77.log.warn('[ncpd] this client has no Open77.prevention seam ' ..
				'(the plugin is older than the module): heat cannot be raised')
		end
		return false, 'seam_unavailable'
	end

	-- The id stops here, deliberately: a resource that cannot name a puppet
	-- cannot reach the wrong one, and the only world this lever can move is the
	-- one this client is simulating.
	local read, accepted, why = pcall(prevention.setWanted, stage)
	if not read then return false, tostring(accepted) end
	if accepted ~= true then return false, tostring(why or 'refused') end
	return true
end

--- Asks the engine for the MaxTac AV, for the player the server named.
--
-- `true` means the request was QUEUED. Whether the engine's spawn system took it
-- is a separate fact and it is the ticket: `state().avTicket` carries the number
-- `RequestAVSpawn` returned, and the trace below reads it back one poll later so
-- "nothing happened" is never the whole story.
-- @param playerId number the player the server named (bookkeeping, not a target)
-- @return boolean accepted
-- @return string|nil why not
local function requestAv(playerId)
	local prevention = seam()
	if prevention == nil then return false, 'seam_unavailable' end
	if type(prevention.requestAv) ~= 'function' then
		return false, 'seam_av_unavailable'
	end

	local read, accepted, why = pcall(prevention.requestAv)
	if not read then return false, tostring(accepted) end
	if accepted ~= true then return false, tostring(why or 'refused') end

	-- The ticket is read a moment later rather than assumed here: the script loop
	-- is asynchronous by construction, and a zero ticket is the engine saying no.
	-- One line, on the client that owns the AV, because that is where the answer
	-- exists; a node that wants it reads the client's log rather than being told a
	-- second-hand number it cannot verify.
	CreateThread(function()
		Wait(AV_TICKET_DELAY_MS)
		local reading = prevention.state and prevention.state() or nil
		local ticket = type(reading) == 'table' and tonumber(reading.avTicket) or nil
		if ticket ~= nil then
			Open77.log.info(('[ncpd] MaxTac AV asked for player %s: ticket %d (%s)')
				:format(tostring(playerId), ticket,
					ticket > 0 and 'the engine took it' or 'REFUSED by the spawn system'))
		else
			Open77.log.info('[ncpd] MaxTac AV asked for: this client reports no ticket ' ..
				'channel (Open77.prevention.state has no avTicket)')
		end
	end)
	return true
end

--- One line per instruction, naming both halves: what the server asked for and
--- whether the engine took it. A stage that never shows is then read rather than
--- guessed at.
-- @param payload table
-- @return boolean heat accepted
-- @return boolean av accepted
local function act(payload)
	local playerId = tonumber(payload.playerId)
	local stage = tonumber(payload.stage) or 0
	local division = tostring(payload.division or 'nobody')
	local av = payload.av == true

	local heat, heatWhy = applyHeat(playerId, stage)
	local asked, avWhy = false, nil
	-- THE AV IS NOT A PROPERTY OF THE STAGE. `/opx.ncpd.av` arrives with
	-- `av = true` and `stage = 0` by design -- asking for the aircraft is not
	-- asking to be wanted -- and the engine's spawn system reads this client's
	-- own wanted level rather than the payload's. Gating the call on
	-- `stage > 0` made that command a no-op that still logged
	-- `av=refused:nil`: "i typed ncpd av and nothing happened", with an
	-- operator line naming no cause. `av` alone decides it.
	if av then
		asked, avWhy = requestAv(playerId)
	end

	Open77.log.info(('[ncpd] %s: stage %d -> %d, division %s, heat=%s%s, av=%s%s')
		:format(tostring(payload.reason or 'server'), tonumber(payload.previous) or 0, stage, division,
			heat and 'accepted' or 'refused',
			heat and '' or (':' .. tostring(heatWhy)),
			av and (asked and 'accepted' or ('refused:' .. tostring(avWhy))) or 'not-asked',
			''))

	if heat then applied = stage end
	return heat, asked
end

--- The one wire handler: a stage, an optional AV, and nothing else.
RegisterNetEvent(M.Event.STAGE, function(payload)
	if type(payload) ~= 'table' then return end
	local playerId = tonumber(payload.playerId)
	if playerId == nil or playerId <= 0 then return end

	local stage = tonumber(payload.stage) or 0
	local heat, asked = act(payload)
	local maxtacStage = Law.Maxtac ~= nil and tonumber(Law.Maxtac.Stage) or 5

	if heat ~= true then
		-- The ledger is the city's; the client only says it cannot show it.
		OPX.Toast.Locale('ncpd.seamUnavailable', nil, 'error')
	elseif stage == 0 and payload.reason == 'neutralized' then
		-- Cleared over their own body (`LIMITS.NEUTRALIZED_SECONDS`): the city
		-- stood down because they went down, not because it lost interest.
		OPX.Toast.Locale('ncpd.neutralized', nil, 'info')
	elseif stage == 0 then
		OPX.Toast.Locale('ncpd.cleared', nil, 'success')
	elseif asked then
		OPX.Toast.Locale('ncpd.maxtacInbound', nil, 'error')
	elseif stage >= maxtacStage then
		OPX.Toast.Locale('ncpd.heatRaised',
			{ division = tostring(payload.label or payload.division or 'MaxTac'), stage = stage }, 'error')
	else
		OPX.Toast.Locale('ncpd.heatRaised',
			{ division = tostring(payload.label or payload.division or 'NCPD'), stage = stage }, 'warning')
	end

	-- The local bus, so a HUD or a job resource hears the crossing without
	-- asking the server for what it was already told.
	TriggerEvent(M.Event.ON_STAGE, {
		playerId = playerId,
		stage = stage,
		previous = tonumber(payload.previous) or 0,
		division = payload.division,
		heat = heat == true,
		av = asked == true,
	})
end)

-- ── the dispatch board ─────────────────────────────────────────────────────────
--
-- THE CALL-OUT, SHOUTED. The server sends the locale KEY and its arguments and
-- NOTHING about the presentation: the frame, the lifetime and the two clips that
-- wrap it are read here, out of this client's own `ALERTS.DISPATCH` block -- the
-- same bargain `modules/admin/client/announce.lua` makes, and for the same
-- reason: a client that has the stinger files plays them, one that named `''`
-- does not, and neither case can make a dispatch fail to arrive.
--
-- ONE TOAST ID, so a second dispatch replaces the board still on screen rather
-- than stacking under it. A firefight that climbs three stages is one dispatch,
-- the last.
--- Pins a called-in scene on this player's own map for as long as the server
--- said, and takes the pin down again. Nothing about it is stored anywhere: a
--- pin is a hint on one map, created and removed by the client that draws it.
-- @param scene table `{ x, y, z, seconds, sprite, label }`
-- @return string|nil the blip id
local function pinScene(scene)
	if type(scene) ~= 'table' then return nil end
	local x, y, z = tonumber(scene.x), tonumber(scene.y), tonumber(scene.z) or 0.0
	local seconds = tonumber(scene.seconds)
	if x == nil or y == nil or seconds == nil or seconds <= 0 then return nil end
	local blips = Open77 and Open77.blips
	if type(blips) ~= 'table' or type(blips.create) ~= 'function' then return nil end
	local label = type(scene.label) == 'string' and locale(scene.label) or locale('ncpd.dispatch.title')
	local read, id, why = pcall(blips.create, {
		position = { x = x, y = y, z = z },
		sprite = type(scene.sprite) == 'string' and scene.sprite or 'objective',
		title = label,
		description = locale('ncpd.dispatch.title'),
		active = true,
		visibleThroughWalls = false,
	})
	if not read or type(id) ~= 'string' or id == '' then
		Open77.log.warn(('[ncpd] the scene was not pinned: %s')
			:format(tostring(read and why or id)))
		return nil
	end
	-- MEASURED ON THE MODULE'S OWN CLOCK, not trusted to one long `Wait`: a
	-- resume can come back early (a world reload, a host that yields per
	-- frame), and a pin that fell off early is a scene nobody drives to.
	local deadline = OPX.Now() + math.floor(math.min(seconds, 900) * 1000)
	CreateThread(function()
		while OPX.Now() < deadline do Wait(500) end
		if type(blips.remove) == 'function' then pcall(blips.remove, id) end
	end)
	return id
end

RegisterNetEvent(M.Event.DISPATCH, function(payload)
	if type(payload) ~= 'table' then return end
	local key = payload.key
	if type(key) ~= 'string' or key == '' then return end
	local args = type(payload.args) == 'table' and payload.args or nil

	-- Said in the client log the moment it arrives, so a call-out that never
	-- reached a screen can be told from one that arrived and was not drawn.
	Open77.log.info(('[ncpd] dispatch received: %s%s'):format(key, payload.scene ~= nil and ' (with a scene)' or ''))

	-- A called-in body carries its scene; the pin goes up whatever the board
	-- does below, because the pin is where the officer drives.
	if payload.scene ~= nil then pinScene(payload.scene) end

	-- Read live and from this client's own copy: `OPX.Modules.Rebind` re-points
	-- `M.Settings` after the shared scripts load, and a board a config disabled
	-- must stay dark even for a payload that was already on the wire.
	local alerts = type(M.Settings) == 'table' and M.Settings.ALERTS or nil
	local board = type(alerts) == 'table' and alerts.DISPATCH or nil
	if type(board) ~= 'table' or board.enabled == false then return end

	-- A lifetime that is not a finite number is left to the runtime's own
	-- default rather than refused: the words are the part that matters.
	local durationMs = tonumber(board.DURATION_MS)
	if durationMs == nil or durationMs ~= durationMs or durationMs < 0 then durationMs = nil end

	local raised, why = OPX.Toast.Show({
		id = 'opx.ncpd.dispatch',
		kind = board.KIND,
		title = locale('ncpd.dispatch.title'),
		message = locale(key, args),
		durationMs = durationMs,
		-- Validated by the runtime rather than here: `core/client/notify.lua` is
		-- the one place that decides what a toast may carry, and it drops a clip
		-- name that is not a bare file name while still drawing the dispatch.
		stinger = board.STINGER,
	})
	if raised == nil then
		Open77.log.warn(('[ncpd] a dispatch was not drawn: %s'):format(tostring(why)))
	end
end)

-- ── the maxtac alarm ───────────────────────────────────────────────────────────
--
-- THE SQUAD'S WHOLE SCREEN when somebody goes cyberpsycho (`ALERTS.ALARM`): a
-- flashing red frame and "MAXTAC ALERT" over a klaxon and a voice, drawn on the
-- page's notice layer (`ui/src/modules/alarm`). It takes neither the keyboard
-- nor the pointer -- the squad has to run for the AV while it is up. The words
-- are resolved here, in the player's language; the sound and the lifetime are
-- this client's own config, as the board's are.

--- How far this body is from a point on the ground, in whole metres, or nil.
local function metresTo(x, y)
	local character = Open77 and Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, px, py = pcall(character.position)
	if not read or type(px) ~= 'number' or type(py) ~= 'number' then return nil end
	local dx, dy = x - px, y - py
	return math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
end

RegisterNetEvent(M.Event.ALARM, function(payload)
	if type(payload) ~= 'table' then return end
	local alerts = type(M.Settings) == 'table' and M.Settings.ALERTS or nil
	local alarm = type(alerts) == 'table' and alerts.ALARM or nil
	if type(alarm) ~= 'table' or alarm.enabled == false then return end

	local stage = math.floor(tonumber(payload.stage) or 5)
	local x, y = tonumber(payload.x), tonumber(payload.y)

	--- A configured number of milliseconds within [low, high], or `default`.
	local function ms(value, default, low, high)
		value = tonumber(value)
		if value == nil or value ~= value then return default end
		return math.floor(math.max(low, math.min(high, value)))
	end
	local volume = tonumber(alarm.VOLUME)
	if volume == nil or volume ~= volume then volume = 1.0 end
	volume = math.max(0.0, math.min(1.0, volume))

	-- THE PSYCHO'S OWN SCREEN: what is coming for them, never who they are.
	if payload.suspect == true then
		if alarm.SUSPECT == false then return end
		local duration = ms(alarm.DURATION_MS, 9000, 1000, 60000)
		local mine = OPX.UI.Send('overlay', 'alarm:show', {
			title = locale('ncpd.alarm.you.title'),
			subtitle = locale('ncpd.alarm.you.subtitle'),
			lines = { locale('ncpd.alarm.you.hint') },
			brief = { locale('ncpd.alarm.you.brief') },
			durationMs = duration,
			flashMs = ms(alarm.FLASH_MS, 1500, 0, duration),
			quietMs = 0,
			sound = type(alarm.SUSPECT_SOUND) == 'string' and alarm.SUSPECT_SOUND or '',
			volume = volume,
		})
		Open77.log.info(('[ncpd] CYBERPSYCHO: this player is MaxTac\'s business now (stage %d)%s')
			:format(stage, mine and '' or ': the page did not take the alarm'))
		return
	end

	-- `brief` is what the strip at the top edge holds once the flash is over:
	-- who and where. `lines` adds the order to respond, for the flash.
	local brief = {}
	local name = type(payload.name) == 'string' and payload.name or ''
	if name ~= '' then brief[#brief + 1] = locale('ncpd.alarm.named', { name = name }) end
	if x ~= nil and y ~= nil then
		local metres = metresTo(x, y)
		brief[#brief + 1] = locale('ncpd.alarm.where', {
			metres = metres ~= nil and tostring(metres) or '?', x = math.floor(x), y = math.floor(y),
		})
	end
	local lines = {}
	for index = 1, #brief do lines[index] = brief[index] end
	lines[#lines + 1] = locale('ncpd.alarm.respond')

	local duration = ms(alarm.DURATION_MS, 9000, 1000, 60000)
	local sent = OPX.UI.Send('overlay', 'alarm:show', {
		title = locale('ncpd.alarm.title'),
		subtitle = locale('ncpd.alarm.subtitle', { stage = stage }),
		lines = lines,
		brief = brief,
		durationMs = duration,
		flashMs = ms(alarm.FLASH_MS, 1500, 0, duration),
		quietMs = ms(alarm.QUIET_MS, 30000, 0, 600000),
		-- In the language this player's game speaks (`SOUNDS`), English otherwise.
		sound = OPX.Locale.ForVoice(alarm.SOUNDS, type(alarm.SOUND) == 'string' and alarm.SOUND or ''),
		volume = math.max(0.0, math.min(1.0, volume)),
	})
	Open77.log.info(('[ncpd] MAXTAC ALARM received (stage %d)%s'):format(stage,
		sent and '' or ': the page did not take it'))
end)

-- ── the crew door ─────────────────────────────────────────────────────────────
--
-- THE SERVER DECIDES AND THIS HALF ASKS. Which aircraft is boardable, who may
-- hold a seat and whether one is free are the controller's own reads
-- (`server/av.lua`): it announces the door to the air division the moment it
-- opens and withdraws the word with a `nil` when it shuts. Nothing here computes
-- a window, a reach or a seat. This half draws the row while the body is inside
-- the reach that door named, and it knocks -- one event, carrying nothing at all.
--
-- THE ROW IS NOT THE PERMISSION. It is a hint that a door exists nearby and which
-- key walks through it; the duty rule, the distance and the seat are all settled
-- again on the server, so a client that never draws the row still has the console
-- door (`/opx.ncpd.board`) and a client that draws one it should not have simply
-- gets a refusal it can read.

--- The prompts group this row lives in. One owner, one group: the aircraft's
--- controller owns the decision and this is the surface it appears on.
local OWNER = 'ncpd'
local GROUP = 'crew'

--- How often the row is re-read against the player's own position. Half a second:
--- fast enough that walking up to a hull has the row on screen before the hold is
--- half over, and small enough that the read costs nothing.
local DOOR_SCAN_MS = 500

--- The door as the server last announced it, or nil when there is none. The
--- payload is the aircraft's own: `{ citizenId, avId, position, reach, seats,
--- seconds }`.
local door = nil

--- Whether the key mapping answered, whether the row is up, and the locale key it
--- was drawn with -- so a change of what the key does is a redraw and nothing else.
local keyRegistered, shown, shownLabel = false, false, nil

--- Whether this client has already said the two things it says once.
local stripWarned = false

--- The key declaration, read from the validated config with the shipped value as
--- the fallback: a config that lost its key block still names one rather than
--- leaving the feature unreachable.
-- @return table
local function boardKey()
	local maxtac = Law.Maxtac
	local boarding = maxtac ~= nil and maxtac.Boarding or nil
	local key = boarding ~= nil and boarding.Key or nil
	if type(key) == 'table' and type(key.ID) == 'string' and key.ID ~= ''
		and type(key.NAME) == 'string' and key.NAME ~= '' then
		return {
			ID = key.ID,
			NAME = key.NAME,
			-- `false` is a real declaration: "no default binding".
			DEFAULT = key.DEFAULT ~= false and (key.DEFAULT or 'F') or false,
		}
	end
	return { ID = 'opx.ncpd.board', NAME = 'ncpd.key.board', DEFAULT = 'F' }
end

--- Where the local player is, or nil. Read rather than kept, because a body walks
--- and the hull does not.
-- @return table|nil `{ x, y, z }`
local function myself()
	local character = Open77 and Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, x, y, z = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then
		return nil
	end
	-- A read that answers a NaN is a read that failed, and a comparison against
	-- one is never true: said here so the row cannot light up on a broken read.
	if x ~= x or y ~= y or z ~= z then return nil end
	return { x = x, y = y, z = z }
end

--- Whether another surface holds the keyboard. A key pressed into a menu is not a
--- request to board, which is why the row is not drawn while one is up either.
-- @return boolean
local function captured()
	local input = Open77 and Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

--- How far the player is from the hull the server named, or nil when either end of
--- that measurement is unknown.
-- @return number|nil
local function metresToDoor()
	if type(door) ~= 'table' or type(door.position) ~= 'table' then return nil end
	local at = myself()
	if at == nil then return nil end
	local hull = door.position
	local dx = at.x - (tonumber(hull.x) or 0.0)
	local dy = at.y - (tonumber(hull.y) or 0.0)
	local dz = at.z - (tonumber(hull.z) or 0.0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Whether the row should be up: a door the server says is open, a body inside the
--- reach that door named, a key that answers, and no menu holding the keyboard.
-- @return boolean
local function rowWanted()
	if type(door) ~= 'table' or not keyRegistered or captured() then return false end
	local reach = tonumber(door.reach)
	local metres = metresToDoor()
	return reach ~= nil and metres ~= nil and metres <= reach
end

--- Names the key the row is bound to, or nil when the mapping was refused. Read
--- from the host's resolved caps so a rebind is the player's own word for it.
-- @return string|nil
local function keyLabel()
	if not keyRegistered then return nil end
	local declared = boardKey()
	if OPX.Lib ~= nil and OPX.Lib.Input ~= nil and type(OPX.Lib.Input.KeyFor) == 'function' then
		return OPX.Lib.Input.KeyFor(declared.ID) or declared.DEFAULT
	end
	return declared.DEFAULT
end

--- Brings the strip in line with the door and with where the body stands.
-- A row that outlived its window would be a key that answers a refusal forever,
-- and a row that only appeared on a keystroke would never appear at all.
local function syncRow()
	local want = rowWanted()
	local label = want and 'ncpd.prompt.board' or nil
	if want == shown and label == shownLabel then return end

	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		-- No strip is not a failure: the console door still seats a crew, and
		-- this is said once.
		if want and not stripWarned then
			stripWarned = true
			Open77.log.info('[ncpd] no prompts contract; the crew-door row is not shown')
		end
		shown = false
		return
	end

	shown, shownLabel = want, label
	local ran, answer
	if want then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = boardKey().ID },
			-- Short on purpose: the strip never wraps a line.
			label = locale(label),
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	local failure = nil
	if not ran then
		failure = tostring(answer)
	elseif type(answer) ~= 'table' or answer.ok ~= true then
		failure = type(answer) == 'table' and tostring(answer.error or 'refused') or 'malformed_answer'
	end
	if failure ~= nil and not stripWarned then
		stripWarned = true
		Open77.log.warn('[ncpd] the crew-door row was refused: ' .. failure)
	end
end

--- Knocks on the crew door: one event, carrying nothing.
--
-- THE TWO LOCAL REFUSALS ARE THE TWO THAT NEED NO WIRE TRIP -- a key pressed into
-- a menu, and a key pressed with no door open anywhere on this client. Everything
-- else is the server's answer, read back through `M.Event.BOARDED`, because the
-- duty rule and the seat are exactly the things a client must not be believed on.
-- @param origin string|nil 'key' for a key press, for the log line
-- @return table `{ ok, code }`
function M.Board(origin)
	if captured() then return { ok = false, code = 'captured' } end
	if type(door) ~= 'table' then return { ok = false, code = 'no_aircraft' } end
	TriggerServerEvent(M.Event.BOARD)
	if origin ~= nil then
		Open77.log.info(('[ncpd] crew door knocked on (%s)'):format(tostring(origin)))
	end
	return { ok = true, queued = true }
end

--- What this half knows about the door, for a diagnostic or a test.
-- @return table
function M.BoardStatus()
	return {
		door = type(door) == 'table',
		shown = shown,
		label = shownLabel,
		key = keyLabel(),
		metres = metresToDoor(),
	}
end

--- The door opening and shutting, as the controller announced it. `nil` is the
--- shut door: the row comes down and a key pressed afterwards is answered locally
--- rather than by a round trip that can only say "there is no aircraft".
RegisterNetEvent(M.Event.DOOR, function(state)
	if state == nil then
		door = nil
		syncRow()
		return
	end
	if type(state) ~= 'table' or type(state.position) ~= 'table' then return end
	door = state
	syncRow()
end)

--- The aircraft controller's answer to this client's own knock: one toast, and
--- the local bus for anything that wants to know a seat was taken.
RegisterNetEvent(M.Event.BOARDED, function(payload)
	if type(payload) ~= 'table' then return end
	local seat = type(payload.seat) == 'string' and payload.seat or nil
	if payload.ok == true and seat ~= nil then
		OPX.Toast.Locale('ncpd.board.aboard', { seat = seat }, 'success')
	else
		local code = tostring(payload.reason or 'failed')
		OPX.Toast.Locale(M.BoardRefusal[code] or 'ncpd.board.failed', { reason = code }, 'error')
		Open77.log.info(('[ncpd] the crew door refused this client: %s'):format(code))
	end
	TriggerEvent(M.Event.ON_BOARD, {
		ok = payload.ok == true,
		seat = seat,
		code = payload.reason,
	})
end)

--- The exit lock coming off. The one moment a body in a flying hull has something
--- to do, so it is said out loud rather than left to be discovered.
RegisterNetEvent(M.Event.RELEASED, function(payload)
	local seat = type(payload) == 'table' and tostring(payload.seat or '?') or '?'
	OPX.Toast.Locale('ncpd.board.released', nil, 'success')
	Open77.log.info(('[ncpd] the exit lock is off in %s: this crew may step out'):format(seat))
end)

-- ── the engine's own heat, reported back ───────────────────────────────────────
--
-- THIS IS HOW A CRIME REACHES THE LEDGER. The engine charges its own crime score
-- when a player kills, steals or drives a car through a crowd -- `PreventionSystem`
-- owns it, 287 scripted methods and not one readable from native code -- so the
-- only place a real crime is visible is that client's own reading of it, and the
-- only way the server learns of one is that client saying so. `Open77.prevention.state()`
-- is that read: it names no player, so a client reports what it is holding and
-- nothing else, and the server attributes the report to the connection it arrived
-- on rather than to anything the payload claims.
--
-- THE STAGE, NOT THE SCORE. The engine zeroes its score as it crosses a stage, so
-- a score reported second-hand would be a number our ledger re-scores from -- two
-- answers to "how wanted am I", the newer one wrong. The stage is what the player
-- can see, so the stage is what is mirrored.

--- How often the engine's own reading is polled. The engine's heat moves on the
--- scale of a crime and a quiet minute, so a second is finer than it can change.
local POLL_MS = 1000

--- How long to wait before reading the AV ticket back. One engine tick is enough
--- for the script loop to run the request; a second is well inside that and long
--- enough that a busy frame cannot read the previous answer.
local AV_TICKET_DELAY_MS = 700

--- How often an unchanged stage is repeated.
--
-- The repeat is not decoration: the server's ledger lets a stage go after its own
-- quiet window, and the engine's heat can outlast that window -- a player pinned at
-- two stars with nobody left to chase has nothing to report and nothing to stop
-- them being reported as free. So a stage still held is restated well inside the
-- window, which also means a client that stops talking (a crash, a dropped
-- connection) lets its own response stand down on schedule.
local HEARTBEAT_MS = 30000

--- Whether this client has already said that it cannot report engine heat.
local mirrorWarned = false

--- The stage this client last told the server about, or nil before the first.
local reported = nil

--- When the last report went out, on the module's own clock.
local reportedAtMs = 0

--- The engine's own stage, or nil while no reading has arrived.
--
-- `engineHeat` and not `requestedLevel`. Those are two different facts: one is
-- what the engine's `PreventionSystem` currently holds, the other is what this
-- client asked it for a moment ago. Reporting the request would let a raise the
-- engine refused come back to the server as a crime the engine charged itself,
-- which is the one thing this mirror must never do.
-- @return number|nil
local function engineStage()
	local prevention = seam()
	if prevention == nil or type(prevention.state) ~= 'function' then return nil end

	local read, reading = pcall(prevention.state)
	if not read or type(reading) ~= 'table' then return nil end
	local stage = tonumber(reading.engineHeat)
	if stage == nil or stage < 0 or stage > 5 then return nil end
	return stage
end

--- Reports the engine's own heat to the server: once per change, and at least once
--- per heartbeat while a stage is held.
-- The first reading is sent even when it is zero: a client that has just stood up
-- is telling the server where it stands, and a ledger that never heard otherwise
-- holds whatever the last session left behind.
-- @return boolean whether a report went out
function M.Report()
	local stage = engineStage()
	if stage == nil then
		-- Said once, and named, rather than looking like a quiet world: a client
		-- whose platform has no engine reading can still be charged by a command,
		-- but nothing it does in the street will ever reach the ledger.
		if not mirrorWarned then
			mirrorWarned = true
			Open77.log.warn('[ncpd] this client reports no engine heat ' ..
				'(Open77.prevention.state has no engineHeat): crimes cannot charge the ledger')
		end
		return false
	end

	local now = OPX.Now()
	local previous = reported
	local changed = previous ~= stage
	local due = now - reportedAtMs >= HEARTBEAT_MS
	if not changed and not due then return false end

	reported = stage
	reportedAtMs = now
	TriggerServerEvent(M.Event.REPORT, stage)

	-- Only a change is worth a line: a heartbeat is the same fact restated, and a
	-- line a second would bury the reading it exists to show.
	if changed then
		Open77.log.info(('[ncpd] engine heat %d reported (was %s)')
			:format(stage, previous == nil and 'nothing yet' or tostring(previous)))
	end
	return true
end

--- What this client has asked the engine for. Read by the `server.status` probe
--- (`Open77.modules`), and the only way to tell "the server never asked" from
--- "the engine refused" when a stage is missing in game.
-- @return table
function M.Status()
	return { applied = applied, reported = reported, seam = seam() ~= nil }
end

--- Starts the two polls and declares the crew door's key.
function M.Start()
	M.running = true
	CreateThread(function()
		while M.running do
			Wait(POLL_MS)
			pcall(M.Report)
		end
	end)

	-- The mapping's name is translated at registration and its id is stable,
	-- because a player's rebind is stored under the id.
	local declared = boardKey()
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				-- The menu test is made twice on purpose: the row is not drawn while
				-- one is up, so a key pressed into a menu is a key pressed with no
				-- row on screen, and it must do nothing rather than knock.
				if captured() then return end
				local ran, failure = pcall(M.Board, 'key')
				if not ran then
					Open77.log.error(('[ncpd] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		-- Two answer shapes are documented for the host call: the effective key,
		-- or `true, key`. Reading only the second logged a working mapping as
		-- refused.
		local effective = nil
		if called then
			effective = type(ok) == 'string' and ok ~= '' and ok
				or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
		end
		if not called or (ok ~= true and effective == nil) then
			Open77.log.warn(('[ncpd] key mapping %s (%s) not registered: %s')
				:format(declared.ID, tostring(declared.DEFAULT),
					tostring(called and answer or ok)))
		else
			keyRegistered = true
		end
	end

	-- A rebind changes the caps the row is drawn with; the strip itself re-reads
	-- them, so this only re-reads whether the row should be up at all.
	AddEventHandler(OPX.Host.KEYBINDS_CHANGED, function() syncRow() end)

	-- The row follows the body. Walking into reach has to light it up without a
	-- keystroke, and the aircraft leaving has to take it down without one too.
	CreateThread(function()
		while M.running do
			Wait(DOOR_SCAN_MS)
			pcall(syncRow)
		end
	end)

	-- The police scanner: its key and wire handlers (the state half), then its
	-- view seam. Two starts because two files own two concerns -- README's view
	-- seam is a file of its own.
	if M.Radio.Start then M.Radio.Start() end
	if M.RadioView and M.RadioView.Start then M.RadioView.Start() end

	-- The hit relay's client half: this player's own shots at the server's bodies,
	-- forwarded for the server to price (`server/hits.lua` says why it must be).
	if M.Hits and M.Hits.Start then M.Hits.Start() end
end

--- Stops the two polls and takes the row down. The next session reports its
--- reading again from scratch, and hears the door again from the server.
function M.Stop()
	M.running = false
	reported = nil
	reportedAtMs = 0
	door = nil
	-- Through `syncRow`, so the strip is cleared through the same contract that
	-- put it up. `keyRegistered` is left alone: a stop is not a rebind, and a
	-- restart re-registers anyway.
	syncRow()
	-- The scanner down last: the view seam gives up focus first, then the state
	-- half forgets the frame.
	if M.RadioView and M.RadioView.Stop then M.RadioView.Stop() end
	if M.Radio.Stop then M.Radio.Stop() end
	if M.Hits and M.Hits.Stop then M.Hits.Stop() end
end
