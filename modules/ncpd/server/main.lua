--- The server half: the book is journalled, crimes are charged, the city answers.
-- @author XEROX710
--
-- THE ONE PATH FROM A CRIME TO A WANTED PLAYER. `charge` is the only function
-- that writes the ledger, and `publish` the only one that tells a client and
-- stands a response up. Everything else -- the commands, the contract other
-- resources call, the decay pass -- goes through those two, so there is exactly
-- one place where a stage changes and exactly one place where the street reacts
-- to it. A second door would be two answers to "why are there police here".
--
-- THE LEDGER IS THE AUTHORITY AND THE ENGINE IS THE ACTOR. Nothing here writes a
-- wanted level fact or draws a star: the client is told the stage and asks the
-- engine's own scripted `PreventionSystem` for it, which is what makes the wanted
-- bar, the siren audio, the police radio and the stage's own effects real. A
-- client that cannot do that says so in its log and the ledger still holds the
-- score -- the city knows, the client cannot show it.
--
-- THE BOOK IS VALIDATED ELSEWHERE AND JOURNALLED HERE. `shared/law.lua` names
-- every value the config could not use; those warnings are worthless unless
-- somebody says them out loud, so `M.Start` prints them and then the book it did
-- accept, as one line an operator can read after editing a config.

local M = OPX.Modules.Get('ncpd')

local Law = M.Law
local Ledger = M.Ledger
local Response = M.Response

local character, hud

-- Whether the two kill handlers are subscribed; see `M.Start`.
local killHandlers = false
-- Whether the engine report and the crew door are on the wire (see `M.Start`).
local netHandlers = false

--- The ladder as one phrase: `ncpd 1-4, maxtac 5`.
-- @return string
local function ladder()
	local parts = {}
	local first = nil
	local division = nil
	for stage = 1, Law.StageCount do
		local row = Law.Stages[stage]
		local current = row ~= nil and row.Division or '?'
		if division == nil then
			first = stage
			division = current
		elseif current ~= division then
			local last = stage - 1
			parts[#parts + 1] = first == last and (division .. ' ' .. first)
				or (division .. ' ' .. first .. '-' .. last)
			first = stage
			division = current
		end
	end
	if division ~= nil then
		parts[#parts + 1] = first == Law.StageCount and (division .. ' ' .. first)
			or (division .. ' ' .. first .. '-' .. Law.StageCount)
	end
	return table.concat(parts, ', ')
end

--- The label a division is shown by, from the config, falling back to its id.
-- @param division string|nil
-- @return string|nil
local function labelOf(division)
	local divisions = M.Settings.DIVISIONS
	local row = type(divisions) == 'table' and divisions[division] or nil
	if type(row) == 'table' and type(row.label) == 'string' then return row.label end
	return division
end

--- The character a connection has loaded, as the character contract sees it.
-- The contract is optional: without it nobody can be charged, which is a refusal
-- with a line rather than a module that takes the resource down.
-- @param playerId number
-- @return table|nil `{ citizenId, source, job }`
local function characterOf(playerId)
	if character == nil then return nil end
	local read, player = pcall(character.GetPlayer, playerId)
	if not read or type(player) ~= 'table' then return nil end
	local data = player.PlayerData
	if type(data) ~= 'table' then return nil end
	local citizenId = data.citizenId
	if type(citizenId) ~= 'string' or citizenId == '' then return nil end
	return data
end

--- The connection a character is on, or nil when they are not in the world.
-- @param citizenId string
-- @return number|nil
local function sourceOf(citizenId)
	if character == nil then return nil end
	local read, player = pcall(character.GetPlayerByCitizenId, citizenId)
	if not read or type(player) ~= 'table' then return nil end
	local data = player.PlayerData
	if type(data) ~= 'table' then return nil end
	local source = tonumber(data.source)
	if source == nil or source <= 0 then return nil end
	return source
end

--- Whether this player holds the MaxTac division's right or one of its jobs.
-- Read only for the log at a summon: the seats are filled with bots either way
-- until the platform can put a player on duty somewhere.
-- @param data table PlayerData
-- @return boolean
local function isDivision(data)
	local maxtac = Law.Maxtac
	if maxtac == nil or type(data) ~= 'table' then return false end
	local job = data.job
	local name = type(job) == 'table' and job.name or nil
	if type(name) == 'string' then
		for _, listed in ipairs(maxtac.Jobs or {}) do
			if listed == name then return true end
		end
	end
	local acl = Open77.acl
	if maxtac.Right ~= nil and type(acl) == 'table' and type(acl.isAllowed) == 'function' then
		local read, allowed = pcall(acl.isAllowed, data.source, maxtac.Right)
		if read and allowed == true then return true end
	end
	return false
end

--- Whether this character may hold a seat in the MaxTac aircraft.
--
-- THE DIVISION'S OWN RULE, read from the config's jobs, and DUTY is the whole
-- filter -- the same `job.onDuty` the call-out uses, so a clocked-off officer can
-- neither hear the call nor take a seat. The opt-in right is the division's other
-- door and is kept for the same reason the call-out keeps it.
--
-- IT ANSWERS A REASON, NOT A BOOLEAN. The aircraft controller refuses with a name
-- (`not_boarding`, `too_far`, `no_seat`); a door that answered `false` would make
-- "you are off duty" and "there is no aircraft" the same sentence to the player.
-- @param data table PlayerData
-- @return boolean|string `true`, or the reason to refuse
local function mayBoard(data)
	local maxtac = Law.Maxtac
	local boarding = maxtac ~= nil and maxtac.Boarding or nil
	if boarding == nil then return 'no_door' end
	if type(data) ~= 'table' then return 'noCitizen' end

	local job = data.job
	local name = type(job) == 'table' and job.name or nil
	if type(job) ~= 'table' or job.onDuty ~= true or type(name) ~= 'string' then
		return 'notOnDuty'
	end
	for _, listed in ipairs(boarding.Jobs) do
		if listed == name then return true end
	end

	local acl = Open77.acl
	if maxtac.Right ~= nil and type(acl) == 'table' and type(acl.isAllowed) == 'function' then
		local read, allowed = pcall(acl.isAllowed, data.source, maxtac.Right)
		if read and allowed == true then return true end
	end
	return 'notDivision'
end

--- The division's own boarding rule, for a door another module holds: the
--- aircraft door (`modules/avdoor`) asks it about a parked MaxTac AV, so a hull
--- the crew stepped out of opens to exactly the people the crew door opened to.
-- @param playerId number
-- @return boolean|string `true`, or the reason to refuse
function M.MayCrew(playerId)
	local data = characterOf(tonumber(playerId))
	if data == nil then return 'noCitizen' end
	return mayBoard(data)
end

--- The sentence a crew-door refusal is read as.
--
-- ONE TABLE, TWO DOORS. The aircraft controller answers with a code, and
-- `M.BoardRefusal` is the module's single map from a code to the words a player
-- reads -- shared with the client half, so the officer who typed the command and
-- the one who pressed the key are told the same thing. A code the table has not
-- heard of still names itself rather than going blank.
-- @param code string|nil
-- @return string
local function boardWhy(code)
	local text = tostring(code or 'failed')
	return locale(M.BoardRefusal[text] or 'ncpd.board.failed', { reason = text })
end

-- ── the call-out ─────────────────────────────────────────────────────────────

-- When each suspect was last called out, so one climb is one message.
local called = {}

--- A player's position, or nil. Read from the host rather than trusted from a
--- client, which is how every distance in this tree is measured.
-- @param source number
-- @return table|nil `{ x, y, z, bucket }`
local function positionOf(source)
	local read, position = pcall(Open77.players.position, source)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = tonumber(position.bucket) or 0 }
end

--- Visits every connected player who is ON DUTY in one of `listed`.
--
-- THE HOST LISTS THE CONNECTIONS AND THE CONTRACT RESOLVES THE CHARACTER, which
-- is the walk `garages`, `dealership`, `jobs` and `downed` all use. It is NOT
-- `character.GetPlayers`: that one EVICTS a slot whose account id no longer
-- matches its session, so finding out who to tell about a crime would unload
-- characters as a side effect of reading a list.
--
-- The LIST is an argument because the module has two audiences: the call-out
-- goes to everyone who answers for the city, and the crew door goes to the air
-- division alone. One walk, two lists, so the duty rule is stated once.
-- @param listed table[] job names
-- @param fn function(source, who) called for each player on duty in one of them
-- @return integer how many were visited
local function walkOnDuty(listed, fn)
	if type(listed) ~= 'table' then return 0 end

	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return 0 end

	local seen = 0
	for index = 1, #ids do
		local who = characterOf(tonumber(ids[index]))
		if who ~= nil then
			local job = who.job
			local name = type(job) == 'table' and job.name or nil
			-- DUTY IS THE WHOLE FILTER, and it is the character module's own
			-- field: a clocked-off officer hears nothing.
			if type(job) == 'table' and job.onDuty == true and type(name) == 'string' then
				for _, wanted in ipairs(listed) do
					if name == wanted then
						seen = seen + 1
						fn(who.source, who)
						break
					end
				end
			end
		end
	end
	return seen
end

--- Calls back for every connected player who is ON DUTY in a job on the air.
-- @param fn function(source, who) called for each player on call
-- @return integer how many were visited
local function eachOnCall(fn)
	local alerts = type(M.Settings) == 'table' and M.Settings.ALERTS or nil
	return walkOnDuty(type(alerts) == 'table' and alerts.JOBS or nil, fn)
end

--- Why a call-out reached nobody, in words for the log.
--
-- "0 on-duty holder(s) told" is the line an operator reads when a toast never
-- appeared, and on its own it cannot tell an empty city from an officer who never
-- clocked in: a job change starts OFF the clock (`docs/jobs.md`), and the call-out
-- is for whoever is ON it. This counts the two apart.
-- @return string
local function nobodyNote()
	local alerts = type(M.Settings) == 'table' and M.Settings.ALERTS or nil
	local listed = type(alerts) == 'table' and alerts.JOBS or nil
	if type(listed) ~= 'table' then return ' (no jobs are on the air)' end

	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return '' end

	local clockedOff, connected = 0, #ids
	for index = 1, #ids do
		local who = characterOf(tonumber(ids[index]))
		local job = who ~= nil and who.job or nil
		if type(job) == 'table' and job.onDuty ~= true and type(job.name) == 'string' then
			for _, name in ipairs(listed) do
				if name == job.name then
					clockedOff = clockedOff + 1
					break
				end
			end
		end
	end
	local jobs = table.concat(listed, '/')
	if clockedOff > 0 then
		return (' (%d of %d connected hold %s but are CLOCKED OFF: they hear nothing until /opx.duty)')
			:format(clockedOff, connected, jobs)
	end
	return (' (%d connected, none of them an on-duty %s)'):format(connected, jobs)
end

--- Tells the air division where the crew door is, while it is open.
--
-- ONE DECISION, ANNOUNCED. The window is the aircraft's own (`server/av.lua`
-- holds the hull still and knows when the hold ends), so this half does not decide
-- when a body may board -- it tells the people who can walk through the door where
-- the door is, and withdraws the word with `nil` the moment it shuts. A client
-- that computed the window itself would be a second answer to the same question.
-- @param state table|nil `{ position, reach, seats, seconds }`, nil when shut
-- @return integer how many were told
function M.DoorCall(state)
	local maxtac = Law.Maxtac
	local boarding = maxtac ~= nil and maxtac.Boarding or nil
	if boarding == nil then return 0 end
	return walkOnDuty(boarding.Jobs, function(source)
		TriggerClientEvent(M.Event.DOOR, source, state)
	end)
end

--- Tells the people who answer for the city that a stage has gone up.
--
-- A RISE, AND ONLY A RISE. Every poll that crosses a stage reaches `publish`,
-- and so does the ledger's own decay back to zero -- once per poll, for as long
-- as the city remembers. Neither is news. The instant a stage rises is.
--
-- IT SPAWNS NOTHING. The engine's units and this module's response are already
-- moving when this runs, so the worst a call-out can do is fail: what is lost
-- is that the people playing the police never hear, which is why the count and
-- the refusal are both journalled.
-- @param citizenId string the suspect
-- @param playerId number|nil their connection, for the name and the place
-- @param stage number the stage now
-- @param previous number the stage before
-- @return integer how many were told
local function callOut(citizenId, playerId, stage, previous)
	local alerts = type(M.Settings) == 'table' and M.Settings.ALERTS or nil
	if type(alerts) ~= 'table' or alerts.enabled == false then return 0 end
	if stage <= previous or stage <= 0 then return 0 end
	if stage < (tonumber(alerts.MIN_STAGE) or 1) then return 0 end

	-- NO PLACE IS NO CALLOUT: a stage that rose with nobody connected has no
	-- location to give, and a marker at 0,0 in the middle of the map is worse
	-- than silence.
	local where = playerId ~= nil and positionOf(playerId) or nil
	if where == nil then
		Open77.log.info(('[ncpd] stage %d for %s: no call-out, their position could not be read')
			:format(stage, citizenId))
		return 0
	end

	local now = OPX.Now()
	local cooldown = tonumber(alerts.COOLDOWN_MS) or 20000
	local last = called[citizenId]
	-- THE CROSSING INTO MAXTAC'S STAGE IS NEVER SWALLOWED BY THE COOLDOWN. The
	-- floor is there so one firefight climbing the NCPD's stages is one message;
	-- a cyberpsycho is the firefight that climbed out of them, and the squad's
	-- alarm rides this call-out. Measured in the bot lab: a psycho at stage 2,
	-- 3, 4 and 5 inside eight seconds was called out at 2 and never at 5.
	local maxtacNow = Law.Division(stage) == M.DIVISION.MAXTAC
		and Law.Division(previous) ~= M.DIVISION.MAXTAC
	if cooldown > 0 and last ~= nil and now - last < cooldown and not maxtacNow then
		Open77.log.info(('[ncpd] stage %d for %s: no call-out, one went out %d ms ago')
			:format(stage, citizenId, now - last))
		return 0
	end
	called[citizenId] = now

	-- Rounded to a place rather than a coordinate, so the radio does not hand
	-- every officer a metre-perfect fix on somebody trying to get away.
	local round = tonumber(alerts.ROUND_METRES) or 0.0
	local x = where.x
	local y = where.y
	if round > 0 then
		x = math.floor(where.x / round + 0.5) * round
		y = math.floor(where.y / round + 0.5) * round
	end
	-- `-0.0` formats as `-0`, which reads like a fault in a notification.
	if x == 0 then x = 0 end
	if y == 0 then y = 0 end

	local name = nil
	if alerts.NAME_SUSPECT ~= false then
		local data = characterOf(playerId)
		local read = data ~= nil and tostring(data.name or '') or ''
		if read ~= '' then name = read end
	end

	local args = {
		division = tostring(labelOf(Law.Division(stage)) or 'NCPD'),
		stage = stage,
		x = math.floor(x),
		y = math.floor(y),
		name = name or '',
	}
	local key = name ~= nil and 'ncpd.dispatch.suspect' or 'ncpd.dispatch.rise'

	local told = 0
	eachOnCall(function(recipient)
		-- THE SUSPECT IS NOT TOLD. Their own client already has the stage, the
		-- label and the response; a call-out to them would be a second, and it
		-- would name them to themselves.
		if playerId ~= nil and recipient == playerId then return end
		told = told + 1
		OPX.NotifyLocale(recipient, key, args, 'warning')
	end)

	-- The same moment on the air: the dispatch band hears the call-out with the
	-- SAME key and arguments the toast used -- one moment, one wording, two
	-- surfaces -- and the suspect is kept off the line exactly as the toast
	-- keeps them off it.
	M.Radio.Push('ncpd', key, args, playerId)

	-- AND THE SAME MOMENT ON THE SCREENS, LOUD. The dispatch board is the same
	-- key and the same arguments again, shouted: every receiver draws its own
	-- toast out of its own `ALERTS.DISPATCH` block, so this half sends WORDS and
	-- never a sound. `DISPATCH.JOBS` names its own air crew when the board is
	-- not for everybody on the air; `false` is the call-out's own audience.
	local dispatch = type(alerts.DISPATCH) == 'table' and alerts.DISPATCH or nil
	if dispatch ~= nil and dispatch.enabled ~= false then
		local board = type(dispatch.JOBS) == 'table' and dispatch.JOBS or nil
		local aired = 0
		walkOnDuty(board or alerts.JOBS, function(recipient)
			if playerId ~= nil and recipient == playerId then return end
			aired = aired + 1
			TriggerClientEvent(M.Event.DISPATCH, recipient, { key = key, args = args })
		end)
		if aired > 0 then
			Open77.log.info(('[ncpd] dispatch board: %d screen(s) lit for stage %d')
				:format(aired, stage))
		end
	end

	-- AND WHEN IT IS MAXTAC'S STAGE, THE SQUAD'S WHOLE SCREEN (`ALERTS.ALARM`).
	-- The same rise, the same suspect kept out of it.
	local alarm = type(alerts.ALARM) == 'table' and alerts.ALARM or nil
	if alarm ~= nil and alarm.enabled ~= false and Law.Division(stage) == M.DIVISION.MAXTAC
		and Law.Division(previous) ~= M.DIVISION.MAXTAC then
		local squad = 0
		walkOnDuty(type(alarm.JOBS) == 'table' and alarm.JOBS or { M.DIVISION.MAXTAC }, function(recipient)
			if playerId ~= nil and recipient == playerId then return end
			squad = squad + 1
			TriggerClientEvent(M.Event.ALARM, recipient, {
				stage = stage, x = args.x, y = args.y, name = args.name, division = args.division,
			})
		end)
		-- AND THE PSYCHO IS TOLD WHAT IS COMING. The squad's screen is not theirs
		-- -- it would name them to themselves -- but a player who has just become
		-- MaxTac's business hears the klaxon and reads it in words
		-- (`ALARM.SUSPECT`). The bot lab, 2026-10-07: four bodies and "i didnt get
		-- maxtac alert".
		local warned = false
		if playerId ~= nil and alarm.SUSPECT ~= false then
			warned = pcall(TriggerClientEvent, M.Event.ALARM, playerId, { stage = stage, suspect = true })
		end
		Open77.log.info(('[ncpd] MAXTAC ALARM: %s went cyberpsycho (stage %d) -- %d squad screen(s) lit%s%s')
			:format(citizenId, stage, squad, squad == 0 and ' (no MaxTac on duty)' or '',
				warned and ', and the psycho is told MaxTac is coming' or ''))
	end

	Open77.log.info(('[ncpd] call-out: %s rose to stage %d/%d at %.0f, %.0f -- %d on-duty holder(s) told%s')
		:format(citizenId, stage, Law.StageCount, x, y, told, told == 0 and nobodyNote() or ''))
	return told
end

-- ── the body on the street ───────────────────────────────────────────────────
--
-- A KILL IS CALLED IN WHETHER OR NOT A STAGE MOVES. `callOut` above is the
-- manhunt and answers a RISE; this is the body, and it answers the charge. See
-- `HOMICIDE` in `config/ncpd.lua` for the two faults it closes: one murder never
-- crossed `Heat_0` and so told nobody, and a player killed by a player was never
-- charged at all.

-- When each suspect's last kill was called in, so a spree is one call-out every
-- few seconds rather than one per body.
local sceneCalled = {}

--- The `HOMICIDE` block, or nil when it is off. Read live, the same rule as the
--- rest of `M.Settings`: a config reload is a new answer on the next kill.
-- @return table|nil
local function homicide()
	local block = type(M.Settings) == 'table' and M.Settings.HOMICIDE or nil
	if type(block) ~= 'table' or block.enabled == false then return nil end
	return block
end

--- Whether a character is ON DUTY in one of the jobs on the air.
-- The same two fields `walkOnDuty` reads -- the character module's own duty
-- flag and the call-out's own job list -- so "who hears the call" and "who is
-- the city" cannot disagree.
-- @param data table|nil PlayerData
-- @return boolean
local function onCall(data)
	if type(data) ~= 'table' then return false end
	local job = data.job
	if type(job) ~= 'table' or job.onDuty ~= true or type(job.name) ~= 'string' then return false end
	local alerts = type(M.Settings) == 'table' and M.Settings.ALERTS or nil
	local listed = type(alerts) == 'table' and alerts.JOBS or nil
	if type(listed) ~= 'table' then return false end
	for _, name in ipairs(listed) do
		if name == job.name then return true end
	end
	return false
end

--- A point as `{ x, y, z }`, from either shape the host answers in -- a
--- snapshot carrying `position`, or the flat position itself -- or nil.
-- @param value any
-- @return table|nil
local function pointOf(value)
	if type(value) ~= 'table' then return nil end
	local at = type(value.position) == 'table' and value.position or value
	local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
	if x == nil or y == nil or x ~= x or y ~= y then return nil end
	if z == nil or z ~= z then z = 0.0 end
	return { x = x, y = y, z = z }
end

--- Calls a kill in to everybody on duty, at the scene.
--
-- THE SAME THREE SURFACES AS A STAGE CALL-OUT -- the toast, the scanner line
-- and the loud board -- with the same audience and the same rule that the
-- suspect is never told about themselves. What is added is the SCENE: it rides
-- the board to each receiving client, which pins it on that player's own map
-- for `PIN_SECONDS` and takes the pin down again itself.
-- @param citizenId string the suspect
-- @param playerId number|nil their connection
-- @param lawId string the law they were just charged with
-- @param at table|nil where the body is; the suspect's own position when nil
-- @param victim number|nil a player who is the body, kept off the air like the
--   suspect: an officer is not called to their own death
-- @return integer how many were told
local function sceneCallOut(citizenId, playerId, lawId, at, victim)
	local block = homicide()
	if block == nil then return 0 end
	local calls = type(block.CALL_OUT) == 'table' and block.CALL_OUT or nil
	local base = calls ~= nil and calls[lawId] or nil
	if type(base) ~= 'string' or base == '' then return 0 end
	local alerts = type(M.Settings) == 'table' and M.Settings.ALERTS or nil
	if type(alerts) ~= 'table' or alerts.enabled == false then return 0 end

	local where = pointOf(at)
	if where == nil and playerId ~= nil then where = positionOf(playerId) end
	if where == nil then
		Open77.log.info(('[ncpd] %s charged with %s: no call-out, the scene could not be read')
			:format(citizenId, tostring(lawId)))
		return 0
	end

	local now = OPX.Now()
	local cooldown = tonumber(block.COOLDOWN_MS) or 8000
	local last = sceneCalled[citizenId]
	if cooldown > 0 and last ~= nil and now - last < cooldown then
		Open77.log.info(('[ncpd] %s charged with %s: no call-out, one went out %d ms ago')
			:format(citizenId, tostring(lawId), now - last))
		return 0
	end
	sceneCalled[citizenId] = now

	-- Rounded exactly as a stage call-out is, for the same reason: the scene is
	-- where the suspect WAS a moment ago, and radio traffic is a place, not a fix.
	local round = tonumber(alerts.ROUND_METRES) or 0.0
	local x, y = where.x, where.y
	if round > 0 then
		x = math.floor(where.x / round + 0.5) * round
		y = math.floor(where.y / round + 0.5) * round
	end
	if x == 0 then x = 0 end
	if y == 0 then y = 0 end

	local name = nil
	if alerts.NAME_SUSPECT ~= false and playerId ~= nil then
		local data = characterOf(playerId)
		local read = data ~= nil and tostring(data.name or '') or ''
		if read ~= '' then name = read end
	end
	local key = name ~= nil and (base .. 'Named') or base
	local args = { x = math.floor(x), y = math.floor(y), name = name or '' }

	local seconds = tonumber(block.PIN_SECONDS) or 0
	if seconds ~= seconds or seconds < 0 then seconds = 0 end
	if seconds > 900 then seconds = 900 end
	local scene = nil
	if seconds > 0 then
		scene = {
			x = math.floor(x), y = math.floor(y), z = math.floor(where.z + 0.5),
			seconds = seconds,
			sprite = type(block.PIN_SPRITE) == 'string' and block.PIN_SPRITE or 'objective',
			label = base .. '.pin',
		}
	end

	local function silent(recipient)
		return (playerId ~= nil and recipient == playerId) or (victim ~= nil and recipient == victim)
	end
	local told = 0
	eachOnCall(function(recipient)
		if silent(recipient) then return end
		told = told + 1
		OPX.NotifyLocale(recipient, key, args, 'error')
	end)

	M.Radio.Push('ncpd', key, args, playerId)

	local dispatch = type(alerts.DISPATCH) == 'table' and alerts.DISPATCH or nil
	if dispatch ~= nil and dispatch.enabled ~= false then
		local board = type(dispatch.JOBS) == 'table' and dispatch.JOBS or nil
		walkOnDuty(board or alerts.JOBS, function(recipient)
			if silent(recipient) then return end
			TriggerClientEvent(M.Event.DISPATCH, recipient, { key = key, args = args, scene = scene })
		end)
	end

	Open77.log.info(('[ncpd] call-out: %s charged with %s at %.0f, %.0f -- %d on-duty holder(s) told%s')
		:format(citizenId, tostring(lawId), x, y, told, told == 0 and nobodyNote() or ''))
	return told
end

--- Stands the response up for a stage and tells the player's client about it.
--
-- The order matters: the ledger is already written when this runs, so a client
-- that never answers still leaves a city that knows what the player did. The
-- response is applied first because it is the half that can fail loudly, and the
-- event last because it is the half that can be delivered once.
-- @param citizenId string
-- @param verdict table what the ledger decided
-- @param options table|nil `{ silence = boolean }`
-- @return table the applied response, or nil when the stage did not move
local function publish(citizenId, verdict, options)
	local stage = tonumber(verdict.stage) or 0
	local playerId = sourceOf(citizenId)
	local previous = tonumber(verdict.previous) or 0
	local opts = type(options) == 'table' and options or {}

	local applied = Response.Apply(citizenId, playerId, stage)
	if applied.ok ~= true then
		Open77.log.warn(('[ncpd] response refused for %s at stage %d: %s')
			:format(citizenId, stage, tostring(applied.error)))
	end

	-- A dropped stage is a cleared city: the units come down and the client is
	-- told to stand the engine's own heat back to zero.
	local clear = stage == 0
	local division = Law.Division(stage)

	if playerId ~= nil then
		TriggerClientEvent(M.Event.STAGE, playerId, {
			playerId = playerId,
			stage = stage,
			previous = previous,
			division = division,
			label = labelOf(division),
			heat = Law.Heat(stage),
			clear = clear,
			av = applied.ok == true and applied.value.av == true,
			reason = opts.reason or 'crime',
		})
	end

	-- The call-out, and it comes after the response on purpose: the units are
	-- already moving by the time anybody is told, so the message is never the
	-- thing the city's safety depends on.
	callOut(citizenId, playerId, stage, previous)

	if applied.ok == true and applied.value.av == true then
		local maxtac = Law.Maxtac
		local seats = tonumber(applied.value.seats) or 0
		local filled = tonumber(applied.value.filled) or 0
		local crew = 0
		if playerId ~= nil then
			local data = characterOf(playerId)
			-- Counted, not seated: a player trooper needs a duty half this
			-- platform does not have yet, and a squad that never arrives is
			-- worse than a squad of bots. The number is in the log so a server
			-- that wants that half knows what it is asking for.
			local read, others = pcall(function()
				local list = character.GetPlayers and character.GetPlayers() or {}
				local total = 0
				for _, player in ipairs(list) do
					local data2 = player.PlayerData
					if type(data2) == 'table' and isDivision(data2) then total = total + 1 end
				end
				return total
			end)
			crew = read and tonumber(others) or 0
		end
		Open77.log.info(('[ncpd] %s is wanted: stage %d/%d, %s answering, AV requested%s')
			:format(citizenId, stage, Law.StageCount, tostring(division),
				maxtac ~= nil and maxtac.Fill == 'players' and ' (player-only squad)' or ''))
		Open77.log.info(('[ncpd] squad: %d seat(s), %d filled by bots, %d player(s) hold the division')
			:format(seats, filled, crew))
	end

	Open77.log.info(('[ncpd] charge %s: %s (+%.1f) -> stage %d/%d %s, %d unit(s), %d vehicle(s), %d refusal(s)')
		:format(citizenId, tostring(verdict.law or 'stage'), tonumber(verdict.delta) or 0.0,
			stage, Law.StageCount, tostring(division),
			applied.ok == true and applied.value.npcs or 0,
			applied.ok == true and applied.value.vehicles or 0,
			applied.ok == true and #(applied.value.refused or {}) or 0))

	if applied.ok == true then
		for _, refusal in ipairs(applied.value.refused or {}) do
			Open77.log.warn(('[ncpd] %s: refused spawn: %s'):format(citizenId, tostring(refusal)))
		end
		-- THE CEILING, said out loud (`LIMITS`): a psycho NCPD holds while every
		-- MaxTac squad is out, and a response the street had no more room for.
		local value = applied.value
		local street = type(Response.Street) == 'function' and Response.Street() or nil
		local ceiling = street ~= nil and street.limits or nil
		if value.queued == true then
			Open77.log.info(('[ncpd] MaxTac is committed (%d squad(s) out of %d): NCPD\'s stage %d holds %s ' ..
				'until a squad is free'):format(street and street.squads or 0, ceiling and ceiling.squads or 0,
				tonumber(value.stage) or 0, citizenId))
			M.Radio.Push('maxtac', 'ncpd.radio.maxtac.committed', { citizen = citizenId })
		end
		local trimmed = value.trimmed
		if type(trimmed) == 'table' and ceiling ~= nil and (trimmed.units > 0 or trimmed.vehicles > 0) then
			Open77.log.info(('[ncpd] the street is full for %s: %d officer(s) and %d car(s) wait for room ' ..
				'(%d/%d officers, %d/%d cars standing for every wanted character)')
				:format(citizenId, trimmed.units, trimmed.vehicles, street.units, ceiling.units,
					street.vehicles, ceiling.vehicles))
		end
	end

	TriggerEvent(M.Event.ON_STAGE, {
		citizenId = citizenId,
		playerId = playerId,
		stage = stage,
		previous = previous,
		division = division,
	})

	return applied.ok == true and applied.value or nil
end

-- THE CYBERPSYCHO RULE: when each character's recent killings were charged, by
-- citizen id, oldest first. See `PSYCHO_KILLS` in config/ncpd.lua.
local killings = {}

--- The first stage MaxTac answers, or nil when the ladder names none.
local function maxtacStage()
	for stage = 1, Law.StageCount do
		if Law.Division(stage) == M.DIVISION.MAXTAC then return stage end
	end
	return nil
end

--- Counts a charged killing, and sends a character who has killed more than
--- `PSYCHO_KILLS` people inside `PSYCHO_WINDOW_SECONDS` straight to MaxTac.
-- The owner, 2026-10-07: "when i kill more then 3 people thats when your labeled
-- cyberphysco". The score ladder alone takes far more than four murders to
-- climb to MaxTac's stage.
-- @param citizenId string
-- @param lawId string
-- @param verdict table what the ledger decided for this charge
-- @return table|nil the verdict that put them on MaxTac's stage
local function psychoRule(citizenId, lawId, verdict)
	local block = homicide()
	if block == nil or type(block.CALL_OUT) ~= 'table' or block.CALL_OUT[lawId] == nil then return nil end
	local limit = block.PSYCHO_KILLS
	if limit == false or limit == nil then return nil end
	limit = math.floor(tonumber(limit) or 3)
	if limit < 1 then return nil end
	local windowMs = math.floor(math.max(10, math.min(86400, tonumber(block.PSYCHO_WINDOW_SECONDS) or 600)) * 1000)
	local now = OPX.Now()
	local list = killings[citizenId] or {}
	local kept = {}
	for _, at in ipairs(list) do
		if now - at < windowMs then kept[#kept + 1] = at end
	end
	kept[#kept + 1] = now
	killings[citizenId] = kept
	if #kept <= limit then return nil end
	local stage = maxtacStage()
	if stage == nil or (tonumber(verdict.stage) or 0) >= stage then return nil end
	local set = Ledger.Set(citizenId, stage, now)
	if set.ok ~= true then return nil end
	Open77.log.info(('[ncpd] %s killed %d people in %ds: CYBERPSYCHO -- straight to MaxTac\'s stage %d')
		:format(citizenId, #kept, math.floor((now - kept[1]) / 1000), stage))
	return set.value
end

--- Charges one character and publishes whatever the charge did.
-- @param citizenId string
-- @param lawId string
-- @param options table|nil
-- @return table a `Result`
local function charge(citizenId, lawId, options)
	local charged = Ledger.Report(citizenId, lawId, options)
	if charged.ok ~= true then return charged end

	local verdict = charged.value
	local psycho = psychoRule(citizenId, tostring(lawId), verdict)
	if psycho ~= nil then
		psycho.law = lawId
		publish(citizenId, psycho, { reason = 'cyberpsycho' })
	elseif verdict.crossed == true or verdict.stage ~= verdict.previous then
		publish(citizenId, verdict, { reason = 'crime' })
	end

	-- THE BODY, WHATEVER THE STAGE DID. A law `HOMICIDE.CALL_OUT` names is
	-- called in on the charge itself, so every door that charges one -- a kill
	-- below, the test crowd, the console, another resource's contract call --
	-- reaches the people on duty the same way. `at` is the scene when the caller
	-- knows it; `playerId` is the suspect's connection when the caller has it.
	local opts = type(options) == 'table' and options or {}
	local suspect = tonumber(opts.playerId) or sourceOf(citizenId)
	sceneCallOut(citizenId, suspect, tostring(lawId), opts.at, tonumber(opts.victim))
	return charged
end

--- Charges a crime to the character a connection has loaded, by connection.
--
-- THE DOOR A BOT'S KILLER IS CHARGED THROUGH (`server/bots.lua`) and the body
-- of the contract's own `ReportPlayer` below: one path from a connection to a
-- charge, written once, so the crowd and every other resource meet the same
-- refusal when the connection holds no character.
-- @param playerId number
-- @param lawId string
-- @param options table|nil
-- @return table a `Result`
local function chargePlayer(playerId, lawId, options)
	local data = characterOf(playerId)
	if data == nil then return OPX.Result.Err('ncpd.noCitizen') end
	local opts = {}
	if type(options) == 'table' then
		for key, value in pairs(options) do opts[key] = value end
	end
	-- The connection the charge arrived on IS the suspect: said here once so
	-- the call-out names and excludes the right body without a second lookup.
	if opts.playerId == nil then opts.playerId = playerId end
	return charge(data.citizenId, lawId, opts)
end

-- `server/bots.lua` charges a killed body's killer through here.
M.ChargePlayer = chargePlayer

--- A death's context as a table, from either shape the host raises it in: JSON
--- text or an already-decoded table. Nil when it is neither.
-- @param context any
-- @return table|nil
local function contextOf(context)
	if type(context) == 'table' then return context end
	if type(context) ~= 'string' or context == '' then return nil end
	if type(json) ~= 'table' or type(json.decode) ~= 'function' then return nil end
	local read, decoded = pcall(json.decode, context)
	if read and type(decoded) == 'table' then return decoded end
	return nil
end

-- When each victim's death was last booked, and for how long a second report of
-- it is the same death: far longer than the three events of one kill take to
-- arrive, far shorter than the respawn that has to come before the next one.
local deathBooked = {}
local DEATH_MEMORY_MS = 5000

-- When each body's death was last booked, by id as text. A death is reported by
-- the platform's `onNpcDied` and, when that is missing, by the hit relay reading
-- the body's own health; a minute is the same bound the crowd keeps for its own.
local npcBooked = {}
local NPC_MEMORY_MS = 60000

-- The shortest gap between two engine reports from one player. The client polls
-- once a second, so a legitimate report is never closer than that.
local REPORT_EVERY_MS = 500

-- The last player to hurt each player, so a death that arrives with no killer
-- can still be put down to whoever had just shot them. `{ by, at }` per victim.
local lastHurt = {}

--- The player a death's source names, or nil when it names nobody alive.
-- The platform passes a source as it has it -- a player id as text, or an
-- opaque script name like `resource:arena` (`wiki/npcs.md`) -- and the character
-- contract is the real test of whether a connection was behind it.
-- @param value any
-- @return number|nil
local function killerOf(value)
	local id = tonumber(value)
	if id == nil then id = tonumber(tostring(value):match('player:(%d+)')) end
	if id == nil or id ~= math.floor(id) or id <= 0 then return nil end
	-- A connection is a small number; an NPC's id is a 64-bit one. An NPC that
	-- killed a player is not a player who killed one, and reading its id as a slot
	-- would charge whoever happened to hold that slot's low bits.
	if id >= 1048576 then return nil end
	return id
end

--- Whether an on-duty officer's kill of a player is use of force.
--
-- USE OF FORCE IS AGAINST A SUSPECT. The bot lab, 2026-10-07: "i killed more
-- then 3 bot players and i didnt get maxtac alert". The tester was on duty as
-- MaxTac, and every one of the four bodies was booked "use of force, not
-- charged" -- four bystanders, none of them wanted, none of them armed. A
-- badge is not a licence: the kill is the officer's job when the victim was
-- WANTED, or had just hurt the officer (inside `ATTRIBUTION_MS`); any other
-- body is a murder like anybody's, and counts toward the cyberpsycho rule.
-- `EXEMPT_ON_DUTY = 'all'` is the old blanket exemption.
-- @param block table the HOMICIDE block
-- @param officerId number
-- @param victimId number|nil
-- @return boolean
-- @return string why, for the journal
local function useOfForce(block, officerId, victimId)
	if block.EXEMPT_ON_DUTY == 'all' then return true, 'EXEMPT_ON_DUTY is all' end
	local dead = victimId ~= nil and characterOf(victimId) or nil
	if dead ~= nil and Ledger.Stage(dead.citizenId) > 0 then
		return true, ('the victim was wanted at stage %d'):format(Ledger.Stage(dead.citizenId))
	end
	local hurt = lastHurt[officerId]
	local window = math.max(tonumber(block.ATTRIBUTION_MS) or 8000, 1000)
	if hurt ~= nil and victimId ~= nil and hurt.by == victimId and OPX.Now() - hurt.at < window then
		return true, 'the victim had just hurt them'
	end
	return false, 'the victim was not wanted and had not hurt them'
end

--- A player killed by a player: the platform's own attributed death.
--
-- `open77:playerKilled(victimId, killerId, contextJson)` is raised into every
-- running resource for a death whose killer the host's damage authority named
-- (`wiki/player-life.md`; an unattributed death raises only `playerDied`). The
-- context carries the body's position, which is the scene.
-- @param victimId any
-- @param killerId any
-- @param context string|table|nil
local function onPlayerKilled(victimId, killerId, context, via)
	local block = homicide()
	if block == nil or block.PLAYERS == false then return end
	local victim = tonumber(victimId)
	local killer = killerOf(killerId)
	if killer == nil or killer == victim then return end

	-- ONE DEATH, ONE CHARGE, HOWEVER MANY DOORS REPORT IT. The lethal damage, the
	-- death and the attributed kill are three events for one body, and the first
	-- to arrive books it; the others find the mark and stand down.
	local now = OPX.Now()
	local key = victim ~= nil and victim or tostring(victimId)
	local booked = deathBooked[key]
	if booked ~= nil and now - booked < DEATH_MEMORY_MS then return end
	deathBooked[key] = now
	for other, when in pairs(deathBooked) do
		if now - when >= DEATH_MEMORY_MS then deathBooked[other] = nil end
	end

	Open77.log.info(('[ncpd] player kill seen (%s): victim %s, killer %d')
		:format(tostring(via or 'playerKilled'), tostring(victimId), killer))

	local suspect = characterOf(killer)
	if suspect == nil then
		Open77.log.info(('[ncpd] player %d killed player %s with no character loaded: nobody to charge')
			:format(killer, tostring(victimId)))
		return
	end
	if block.EXEMPT_ON_DUTY ~= false and onCall(suspect) then
		local force, because = useOfForce(block, killer, victim)
		if force then
			Open77.log.info(('[ncpd] %s killed player %s on duty: use of force (%s), not charged')
				:format(suspect.citizenId, tostring(victimId), because))
			return
		end
		Open77.log.info(('[ncpd] %s killed player %s on duty, but %s: that is not use of force, it is charged')
			:format(suspect.citizenId, tostring(victimId), because))
	end

	local dead = victim ~= nil and characterOf(victim) or nil
	local law = (dead ~= nil and onCall(dead)) and block.POLICE_LAW or block.LAW
	if type(law) ~= 'string' or law == '' then law = 'murder' end

	local scene = nil
	local read = contextOf(context)
	if read ~= nil then scene = pointOf(read.position) end
	if scene == nil and victim ~= nil then scene = positionOf(victim) end

	local charged = charge(suspect.citizenId, law, { at = scene, playerId = killer, victim = victim })
	if charged.ok ~= true then
		Open77.log.warn(('[ncpd] the killing of player %s could not be charged to %s: %s')
			:format(tostring(victimId), suspect.citizenId, tostring(charged.error)))
	else
		Open77.log.info(('[ncpd] %s charged with %s for killing player %s')
			:format(suspect.citizenId, law, tostring(victimId)))
	end
end

--- A server NPC killed by a player: `onNpcDied(npcId, source, cause)`.
--
-- The test crowd books its own kills (`server/bots.lua`) and is skipped here by
-- the id it placed, so a crowd death is charged exactly once. A unit this
-- module put on the street is the city's own, and a kill of one is
-- `POLICE_LAW`.
-- @param npcId any
-- @param source any
local function onNpcKilled(npcId, source)
	local block = homicide()
	if block == nil or block.NPCS == false then return end
	if M.Bots ~= nil and type(M.Bots.Owns) == 'function' and M.Bots.Owns(npcId) then return end

	-- ONE BODY, ONE CHARGE. The platform's `onNpcDied` and the hit relay's own
	-- reading of a body's health (`server/hits.lua`) can both report one death.
	local now = OPX.Now()
	local key = tostring(npcId)
	local booked = npcBooked[key]
	if booked ~= nil and now - booked < NPC_MEMORY_MS then return end
	npcBooked[key] = now
	for other, when in pairs(npcBooked) do
		if now - when >= NPC_MEMORY_MS then npcBooked[other] = nil end
	end

	local killer = killerOf(source)
	if killer == nil then
		Open77.log.info(('[ncpd] npc %s died with nobody to charge (source %s)')
			:format(key, tostring(source)))
		return
	end
	local suspect = characterOf(killer)
	if suspect == nil then
		Open77.log.info(('[ncpd] player %d killed npc %s with no character loaded: nobody to charge')
			:format(killer, key))
		return
	end
	if block.EXEMPT_ON_DUTY ~= false and onCall(suspect) then
		Open77.log.info(('[ncpd] %s killed npc %s on duty: use of force, not charged')
			:format(suspect.citizenId, key))
		return
	end

	local police = type(Response.OwnsNpc) == 'function' and Response.OwnsNpc(npcId)
	local law = police and block.POLICE_LAW or block.LAW
	if type(law) ~= 'string' or law == '' then law = 'murder' end

	local scene = nil
	local npcs = Open77.npcs
	if type(npcs) == 'table' and type(npcs.get) == 'function' then
		local read, snapshot = pcall(npcs.get, npcId)
		if read then scene = pointOf(snapshot) end
	end

	local charged = charge(suspect.citizenId, law, { at = scene, playerId = killer })
	if charged.ok ~= true then
		Open77.log.warn(('[ncpd] the killing of npc %s could not be charged to %s: %s')
			:format(key, suspect.citizenId, tostring(charged.error)))
	else
		Open77.log.info(('[ncpd] %s charged with %s for killing npc %s%s')
			:format(suspect.citizenId, law, key, police and ' (a unit of the response)' or ''))
	end
end

--- A player hurt by a player: remembered, and a lethal hit is a kill at once.
--
-- `open77:playerDamaged(victim, attacker, amount, kind, weapon, part, health,
-- maxHealth, lethal, downed)`, every argument text. The attacker of a player hit
-- by an NPC is that NPC's id, which `killerOf` refuses as a slot.
-- @param victimId any
-- @param attackerId any
-- @param lethal any `"1"` on the hit that ends the victim
local function onPlayerHurt(victimId, attackerId, _, _, _, _, _, _, lethal)
	local block = homicide()
	if block == nil or block.PLAYERS == false then return end
	local victim = tonumber(victimId)
	local attacker = killerOf(attackerId)
	if victim == nil or attacker == nil or attacker == victim then return end

	local now = OPX.Now()
	lastHurt[victim] = { by = attacker, at = now }
	local window = tonumber(block.ATTRIBUTION_MS) or 8000
	for other, row in pairs(lastHurt) do
		if now - row.at >= math.max(window, 1000) then lastHurt[other] = nil end
	end

	if lethal == '1' or lethal == 1 or lethal == true or lethal == 'true' then
		onPlayerKilled(victim, attacker, nil, 'lethal hit')
	end
end

--- A player died: `open77:playerDied(playerId, contextJson)`.
--
-- Raised for EVERY death, attributed or not (`open77:playerKilled` only for one
-- the host could attribute). The context may name a killer; when it does not, the
-- last player to hurt the victim inside `HOMICIDE.ATTRIBUTION_MS` is put down for
-- it -- never for a fall, the environment or a script, which are not anybody's
-- murder.
-- @param playerId any
-- @param context string|table|nil
local function onPlayerDied(playerId, context)
	local block = homicide()
	if block == nil or block.PLAYERS == false then return end
	local victim = tonumber(playerId)
	if victim == nil then return end

	local read = contextOf(context)
	local killer = read ~= nil and killerOf(read.killer or read.killerPlayerId) or nil
	local via = 'playerDied'
	if killer == nil then
		local cause = read ~= nil and tostring(read.cause or '') or ''
		local window = tonumber(block.ATTRIBUTION_MS) or 8000
		local row = lastHurt[victim]
		if window > 0 and row ~= nil and OPX.Now() - row.at < window
			and cause ~= 'script' and cause ~= 'fall' and cause ~= 'environment' then
			killer = row.by
			via = 'recent hit'
		end
	end
	if killer == nil then
		Open77.log.info(('[ncpd] player %d died with nobody to charge (cause %s)')
			:format(victim, tostring(read ~= nil and read.cause or 'unknown')))
		return
	end
	lastHurt[victim] = nil
	onPlayerKilled(victim, killer, context, via)
end

--- One decay pass: drain every score, and publish the characters that fell free.
-- @param nowMs integer|nil
-- @return integer how many characters were dropped
local function decayPass(nowMs)
	local now = tonumber(nowMs) or OPX.Now()
	local dropped = 0
	for _, item in ipairs(Ledger.All()) do
		local _, freed = Ledger.Decay(item.citizenId, now)
		if freed then
			dropped = dropped + 1
			local playerId = sourceOf(item.citizenId)
			local stage = 0
			publish(item.citizenId, {
				citizenId = item.citizenId, stage = stage, previous = item.entry.stage or 0,
				law = 'decay', delta = 0.0,
			}, { reason = 'decay' })
			if playerId ~= nil then
				OPX.NotifyLocale(playerId, 'ncpd.cleared', nil, 'success')
			end
			-- Case closed on the air as well: the dispatch band hears the same
			-- sentence the freed player was just told, and they are kept off the
			-- line for the same reason the call-out keeps a suspect off it.
			M.Radio.Push('ncpd', 'ncpd.cleared', nil, playerId)
		end
	end
	return dropped
end

-- ── neutralized: a wanted character who is down ──────────────────────────────
--
-- THE JOB IS DONE WHEN THE SUSPECT IS DOWN. A MaxTac squad leaves once the
-- psycho is down, and a stage held over a body for as long as the ledger's quiet
-- window is the other half of the lab's pile-up: its responses never came down,
-- because nobody left alive was going to be quiet for ninety seconds. A wanted
-- character down for `LIMITS.NEUTRALIZED_SECONDS` is cleared, the response goes
-- home and the room it held is somebody else's (`Response.Refill`).

-- When each wanted character was first seen down, by citizen id.
local downSince = {}
-- When each character was neutralized: their own engine's report of a stage is
-- not heard for `ENGINE_GRACE_MS` after it, because an engine that has not yet
-- heard the clear would otherwise put them straight back on the ladder.
local stoodDown = {}
local ENGINE_GRACE_MS = 30000

--- How long a wanted character is down before they are neutralized, or nil when
--- that is off (`LIMITS = false`, or `NEUTRALIZED_SECONDS = false`).
-- @return integer|nil milliseconds
local function neutralizedMs()
	-- Read in two steps: `a and false or nil` is nil, and `false` is the switch.
	local declared = nil
	if type(M.Settings) == 'table' then declared = M.Settings.LIMITS end
	if declared == false then return nil end
	local block = type(declared) == 'table' and declared or {}
	if block.NEUTRALIZED_SECONDS == false then return nil end
	local seconds = tonumber(block.NEUTRALIZED_SECONDS)
	if seconds == nil or seconds ~= seconds or seconds < 0 or seconds > 3600 then seconds = 10 end
	return math.floor(seconds * 1000)
end

--- Whether a connection's body is down: the platform's own life phase.
-- @param playerId number
-- @return boolean
local function isDown(playerId)
	local players = Open77.players
	if type(players) ~= 'table' then return false end
	if type(players.getLifeState) == 'function' then
		local read, life = pcall(players.getLifeState, playerId)
		if read and type(life) == 'table' then
			local phase = tostring(life.phase or '')
			return phase == 'dead' or phase == 'revivepending'
		end
		if read then return false end
	end
	if type(players.isDead) == 'function' then
		local read, dead = pcall(players.isDead, playerId)
		return read and dead == true
	end
	return false
end

--- One neutralize pass: every wanted character down for the window is cleared,
--- told so, and their response stands down.
-- @param nowMs integer|nil
-- @return integer how many were neutralized
local function neutralizePass(nowMs)
	local window = neutralizedMs()
	if window == nil then
		downSince = {}
		return 0
	end
	local now = tonumber(nowMs) or OPX.Now()
	local seen, dropped = {}, 0
	for _, item in ipairs(Ledger.All()) do
		local citizenId, entry = item.citizenId, item.entry
		local previous = tonumber(entry.stage) or 0
		local playerId = previous > 0 and sourceOf(citizenId) or nil
		if playerId ~= nil and isDown(playerId) then
			seen[citizenId] = true
			local since = downSince[citizenId]
			if since == nil then
				downSince[citizenId] = now
			elseif now - since >= window then
				Ledger.Clear(citizenId)
				killings[citizenId] = nil
				downSince[citizenId] = nil
				seen[citizenId] = nil
				stoodDown[citizenId] = now
				dropped = dropped + 1
				local psychoStage = maxtacStage()
				local maxtac = psychoStage ~= nil and previous >= psychoStage
				Open77.log.info(('[ncpd] %s was down for %.0fs at stage %d: NEUTRALIZED -- the stage is ' ..
					'cleared and the %s response stands down'):format(citizenId, (now - since) / 1000,
					previous, maxtac and 'MaxTac' or 'NCPD'))
				publish(citizenId, {
					citizenId = citizenId, stage = 0, previous = previous, law = 'neutralized', delta = 0.0,
				}, { reason = 'neutralized' })
				M.Radio.Push(maxtac and 'maxtac' or 'ncpd', 'ncpd.radio.neutralized',
					{ citizen = citizenId }, playerId)
			end
		end
	end
	for citizenId in pairs(downSince) do
		if not seen[citizenId] then downSince[citizenId] = nil end
	end
	for citizenId, at in pairs(stoodDown) do
		if now - at >= ENGINE_GRACE_MS then stoodDown[citizenId] = nil end
	end
	return dropped
end

--- One refill pass: what the ceiling held back stands up as room comes free --
--- a held cyberpsycho gets the MaxTac squad, a trimmed response its officers.
-- @return integer how many responses were stood again
local function refillPass()
	if type(Response.Refill) ~= 'function' then return 0 end
	local done = Response.Refill()
	for _, item in ipairs(done) do
		local applied = item.applied
		local value = type(applied) == 'table' and applied.ok == true and applied.value or nil
		if value == nil then
			Open77.log.warn(('[ncpd] the held response for %s could not be stood again: %s')
				:format(item.citizenId, tostring(type(applied) == 'table' and applied.error or 'no answer')))
		elseif item.queued and value.queued ~= true then
			Open77.log.info(('[ncpd] a MaxTac squad is free: it answers %s now (stage %d), %d unit(s), ' ..
				'%d vehicle(s)%s'):format(item.citizenId, item.stage, value.npcs, value.vehicles,
				value.av and ', the AV is called' or ''))
			M.Radio.Push('maxtac', 'ncpd.radio.maxtac.free', { citizen = item.citizenId })
		else
			Open77.log.info(('[ncpd] room on the street: %s now has %d unit(s) and %d vehicle(s) at stage %d')
				:format(item.citizenId, value.npcs, value.vehicles, tonumber(value.stage) or 0))
		end
	end
	return #done
end

-- ── the surfaces ─────────────────────────────────────────────────────────────

--- Whether the ACL lets this player run one of this module's commands.
-- @param player number
-- @param name string the command name without its prefix
-- @return boolean
local function aclAllows(player, name)
	local acl = Open77.acl
	if type(acl) ~= 'table' or type(acl.isAllowed) ~= 'function' then return false end
	local read, allowed = pcall(acl.isAllowed, player, 'command.' .. name)
	return read and allowed == true
end

--- Registers one command, ACL-gated, with the same shape every module uses.
-- @param name string
-- @param spec table `{ help, params }`
-- @param handler function(source, args)
local function register(name, spec, handler)
	if type(OPX.Command) ~= 'table' or type(OPX.Command.Register) ~= 'function' then return end
	OPX.Command.Register(name, {
		restricted = true,
		help = spec.help,
		params = spec.params or {},
	}, function(source, args)
		if not aclAllows(source, name) then
			return OPX.CommandResult(source, false, 'not allowed')
		end
		return handler(source, args)
	end)
end

--- The player a command is acting on: the id given, or the caller.
-- @param source number
-- @param args table
-- @param index number
-- @return number|nil
local function targetOf(source, args, index)
	local named = tonumber(args[index])
	if named == nil then return source end
	if named <= 0 then return nil end
	return named
end

local function registerCommands()
	local names = M.Command

	register(names.STATUS, {
		help = 'ncpd.help.status',
		params = { { name = 'player', optional = true, help = 'ncpd.help.player' } },
	}, function(source, args)
		local target = targetOf(source, args, 1)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		local status = Ledger.Status(data.citizenId)
		local response = Response.Status(data.citizenId)

		-- WHO A CALL-OUT WOULD REACH RIGHT NOW, and what the hit relay has done:
		-- the two facts that say why a kill was or was not called in.
		local alerts = type(M.Settings) == 'table' and M.Settings.ALERTS or nil
		local onAir = eachOnCall(function() end)
		local jobs = type(alerts) == 'table' and type(alerts.JOBS) == 'table'
			and table.concat(alerts.JOBS, '/') or '?'
		local relay = M.Hits ~= nil and type(M.Hits.Status) == 'function' and M.Hits.Status() or nil
		local relayed = 'off'
		if relay ~= nil then
			local why = {}
			for reason, count in pairs(relay.refused) do
				why[#why + 1] = ('%s %d'):format(reason, count)
			end
			table.sort(why)
			relayed = ('%d seen, %d applied, %d lethal%s'):format(relay.seen, relay.applied,
				relay.lethal, #why > 0 and (', refused: ' .. table.concat(why, ', ')) or '')
		end

		-- THE WHOLE STREET beside this one response: the ceiling every wanted
		-- character shares (`LIMITS`), so "why only two officers" has its answer.
		local street = type(Response.Street) == 'function' and Response.Street() or nil
		local ceiling = street ~= nil and street.limits or nil
		local shared = 'no ceiling (LIMITS = false)'
		if street ~= nil and ceiling ~= nil then
			shared = ('%d/%d NCPD officer(s), %d/%d car(s), %d/%d MaxTac squad(s), %d response(s)%s')
				:format(street.units, ceiling.units, street.vehicles, ceiling.vehicles, street.squads,
					ceiling.squads, street.responses,
					street.queued > 0 and (', %d psycho(s) held for a squad'):format(street.queued) or '')
		end

		OPX.CommandResult(source, true, table.concat({
			('citizen   : %s'):format(data.citizenId),
			('stage     : %d/%d (%s)%s'):format(status.stage, Law.StageCount,
				tostring(status.division or 'nobody'),
				status.wanted and '' or ' -- not wanted'),
			('score     : %.1f'):format(status.score),
			('quiet for : %.0fs'):format(status.sinceSeconds),
			('on street : %d unit(s), %d vehicle(s) [stage %d]%s'):format(
				response.npcs, response.vehicles, response.stage,
				response.queued and ' -- NCPD holds them until a MaxTac squad is free' or ''),
			('the street: %s'):format(shared),
			('on the air: %d on duty in %s (a call-out reaches only them)'):format(onAir, jobs),
			('hit relay : %s'):format(relayed),
		}, '\n'))
	end)

	register(names.REPORT, {
		help = 'ncpd.help.report',
		params = {
			{ name = 'law', help = 'ncpd.help.law' },
			{ name = 'player', optional = true, help = 'ncpd.help.player' },
		},
	}, function(source, args)
		local target = targetOf(source, args, 2)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		CreateThread(function()
			local charged = charge(data.citizenId, tostring(args[1]))
			if charged.ok ~= true then
				return OPX.CommandResult(source, false, tostring(charged.error))
			end
			local value = charged.value
			OPX.CommandResult(source, true, ('%s charged with %s: %.1f -> stage %d (%s)')
				:format(data.citizenId, tostring(value.law), value.delta, value.stage,
					tostring(value.division or 'nobody')))
		end)
	end)

	register(names.HEAT, {
		help = 'ncpd.help.heat',
		params = {
			{ name = 'stage', help = 'ncpd.help.stage' },
			{ name = 'player', optional = true, help = 'ncpd.help.player' },
		},
	}, function(source, args)
		local target = targetOf(source, args, 2)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		CreateThread(function()
			local set = Ledger.Set(data.citizenId, tonumber(args[1]))
			if set.ok ~= true then
				return OPX.CommandResult(source, false, tostring(set.error))
			end
			publish(data.citizenId, set.value, { reason = 'command' })
			OPX.CommandResult(source, true, ('%s is on stage %d (%s)')
				:format(data.citizenId, set.value.stage, tostring(set.value.division or 'nobody')))
		end)
	end)

	register(names.AV, {
		help = 'ncpd.help.av',
		params = { { name = 'player', optional = true, help = 'ncpd.help.player' } },
	}, function(source, args)
		local target = targetOf(source, args, 1)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		-- The AV is the client's own request: the engine's spawn system runs in
		-- its script frame, so this re-publishes the current stage with the AV
		-- flag set rather than pretending the server can ask for one.
		local status = Ledger.Status(data.citizenId)
		TriggerClientEvent(M.Event.STAGE, target, {
			playerId = target,
			stage = status.stage,
			previous = status.stage,
			division = status.division,
			label = labelOf(status.division),
			heat = status.heat,
			clear = false,
			av = true,
			reason = 'command',
		})
		OPX.CommandResult(source, true, 'asked their client for the MaxTac AV')
	end)

	-- The console door to the crew seat. The strip row is the way in for a body
	-- standing under the aircraft; this is the way in for an operator who wants a
	-- seat without one, and both go through `Av.Board` -- one decision, two doors.
	register(names.BOARD, {
		help = 'ncpd.help.board',
		params = { { name = 'seat', optional = true, help = 'ncpd.help.seat' } },
	}, function(source, args)
		local data = characterOf(source)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		local av = M.Av
		if av == nil or type(av.Board) ~= 'function' then
			return OPX.CommandResult(source, false, 'the aircraft controller is unavailable')
		end
		local seat, why = av.Board(source, mayBoard(data), args[1])
		if seat == nil then
			return OPX.CommandResult(source, false, boardWhy(why))
		end
		OPX.CommandResult(source, true, locale('ncpd.board.aboard', { seat = tostring(seat) }))
	end)

	register(names.CLEAR, {
		help = 'ncpd.help.clear',
		params = { { name = 'player', optional = true, help = 'ncpd.help.player' } },
	}, function(source, args)
		local target = targetOf(source, args, 1)
		if target == nil then return OPX.CommandResult(source, false, 'no such player') end
		local data = characterOf(target)
		if data == nil then
			return OPX.CommandResult(source, false, locale('ncpd.noCitizen'))
		end
		local cleared = Ledger.Clear(data.citizenId)
		if cleared.ok ~= true then
			return OPX.CommandResult(source, false, tostring(cleared.error))
		end
		publish(data.citizenId, { stage = 0, previous = cleared.value.previous, law = 'clear' },
			{ reason = 'command' })
		OPX.CommandResult(source, true, ('%s is forgotten (was stage %d)')
			:format(data.citizenId, cleared.value.previous))
	end)

	register(names.LAWS, {
		help = 'ncpd.help.laws',
		params = {},
	}, function(source)
		local lines = { ('the law book: %d offence(s), ladder %s'):format(#Law.Ids, ladder()) }
		for _, id in ipairs(Law.Ids) do
			local law = Law.Book[id]
			lines[#lines + 1] = ('  %-16s %6.1f  ceiling %-4s %s')
				:format(id, law.Score or 0.0, law.Ceiling ~= nil and tostring(law.Ceiling) or '-',
					tostring(law.Group or ''))
		end
		OPX.CommandResult(source, true, table.concat(lines, '\n'))
	end)

	-- THE CROWD DOOR: the rig an operator kills to watch the ladder work.
	-- The verbs are three and the answers name themselves: a crowd placed,
	-- a street taken back, or where the bodies stand.
	register(names.BOTS, {
		help = 'ncpd.help.bots',
		params = {
			{ name = 'action', help = 'ncpd.help.botsAction' },
			{ name = 'count', optional = true, help = 'ncpd.help.botsCount' },
		},
	}, function(source, args)
		local bots = M.Bots
		if bots == nil then
			return OPX.CommandResult(source, false, 'the crowd is not in this build')
		end
		local action = tostring(args[1] or ''):lower()
		if action == 'spawn' then
			local at = positionOf(source)
			if at == nil then
				return OPX.CommandResult(source, false, 'no position of yours the host can read')
			end
			local made, why = bots.Spawn(at, tonumber(args[2]))
			if made == 0 then
				return OPX.CommandResult(source, false,
					('the crowd is not placed: %s'):format(tostring(why or 'refused')))
			end
			return OPX.CommandResult(source, true,
				('%d civilian(s) around you (%d standing)'):format(made, bots.Live()))
		elseif action == 'clear' then
			return OPX.CommandResult(source, true,
				('%d civilian(s) taken off the street'):format(bots.Clear('an operator asked')))
		elseif action == 'status' then
			local status = bots.Status()
			return OPX.CommandResult(source, true, table.concat({
				('standing : %d'):format(status.live),
				('placed   : %d'):format(status.placed),
				('booked   : %d kill(s) charged'):format(status.booked),
			}, '\n'))
		end
		return OPX.CommandResult(source, false,
			'usage: /opx.ncpd.bots spawn [count] | clear | status')
	end)
end

-- ── the engine's own heat, mirrored ───────────────────────────────────────────

--- Mirrors the stage one client's own engine is holding into the ledger.
--
-- WHY THIS IS THE CRIME PATH AND NOT A SHORTCUT. The engine scores its own crimes
-- -- a kill, a theft, a car through a crowd -- and nothing native can read that
-- score: `PreventionSystem`'s 287 methods are all scripted. So the ledger cannot
-- charge a crime it cannot see, and the one place a real crime is visible at all is
-- the client that committed it. That client reads its own engine and states the
-- stage; this function applies it, stands the response up and lets the log name it.
--
-- THE STAGE IS COPIED, NEVER SCORED. Charging the book for a reported stage would
-- be a second scorer: the engine would climb, we would charge a law, our stage would
-- cross higher than the engine's, the client would be told to climb, and it would
-- report that back -- each loop a stage. `Set` is the only write here, so the ledger
-- follows the engine and can never amplify it.
--
-- ATTRIBUTED BY CONNECTION. The payload is one stage and nothing else; the citizen
-- is resolved from the connection the report arrived on, so the worst a modified
-- client can do is lie about its OWN heat -- which the engine on its own client
-- would immediately contradict, one report later.
-- @param stage any the stage the engine mirror last read
local function onEngineStage(stage)
	-- THE CONNECTION IS THE `source` GLOBAL, never a parameter: the host
	-- delivers payload only and names the sender in `source` around the
	-- call, so a parameter named `source` here swallowed the stage.
	local playerId = tonumber(source)
	if playerId == nil or playerId <= 0 then return end
	-- ONE REPORT PER REPORT_EVERY_MS. The client polls once a second and sends
	-- only a change or a heartbeat; anything faster is a client flooding the
	-- ledger (a database write and a street rebuild per crossing), not heat.
	if OPX.Cooling(playerId, 'ncpd.report', REPORT_EVERY_MS) then return end
	local data = characterOf(playerId)
	if data == nil then
		Open77.log.warn(('[ncpd] engine report from player %d refused: no character loaded')
			:format(playerId))
		return
	end

	local wanted = tonumber(stage)
	if wanted == nil or wanted ~= math.floor(wanted)
		or wanted < 0 or wanted > Law.StageCount then
		Open77.log.warn(('[ncpd] engine report from %s refused: stage %s is not 0-%d')
			:format(data.citizenId, tostring(stage), Law.StageCount))
		return
	end

	-- JUST NEUTRALIZED: the stage was cleared over their body, and the report of
	-- an engine that has not heard the clear yet is not a new crime. A crime the
	-- server charges itself still counts; only this mirror waits out the grace.
	local stood = stoodDown[data.citizenId]
	if wanted > 0 and stood ~= nil and OPX.Now() - stood < ENGINE_GRACE_MS then return end

	-- `Mirror`, not `Set`: the report may raise a stage, never take one the
	-- server charged below its floor (see `Ledger.Mirror`).
	local set = Ledger.Mirror(data.citizenId, wanted)
	if set.ok ~= true then
		Open77.log.warn(('[ncpd] engine report for %s refused: %s')
			:format(data.citizenId, tostring(set.error)))
		return
	end

	-- Unchanged is the heartbeat, not an event: the stage is already on the street
	-- and re-publishing it would rebuild the response once a poll.
	if set.value.crossed ~= true then return end

	publish(data.citizenId, set.value, { reason = 'engine' })
	Open77.log.info(('[ncpd] %s crossed to stage %d on the engine\'s own heat')
		:format(data.citizenId, set.value.stage))
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Reads what the module needs. Never yields.
function M.Init()
	M.running = false
end

--- Publishes the contract other resources charge crimes through.
function M.Api()
	OPX.Api.Provide('ncpd', 1, {
		--- Charges an offence to a citizen id.
		-- @param citizenId string
		-- @param lawId string
		-- @param options table|nil
		-- @return table a `Result`
		Report = function(citizenId, lawId, options)
			return charge(citizenId, lawId, options)
		end,

		--- Charges an offence to the character a connection has loaded.
		-- @param playerId number
		-- @param lawId string
		-- @param options table|nil
		-- @return table a `Result`
		ReportPlayer = function(playerId, lawId, options)
			return chargePlayer(playerId, lawId, options)
		end,

		--- Where a citizen stands, after the drain.
		-- @param citizenId string
		-- @return table
		Status = function(citizenId)
			return Ledger.Status(citizenId)
		end,

		--- Where the connection's own character stands.
		-- @param playerId number
		-- @return table|nil
		StatusPlayer = function(playerId)
			local data = characterOf(playerId)
			if data == nil then return nil end
			return Ledger.Status(data.citizenId)
		end,

		--- Puts a citizen on a stage without a crime: a job's floor.
		-- @param citizenId string
		-- @param stage number
		-- @return table a `Result`
		Set = function(citizenId, stage)
			local set = Ledger.Set(citizenId, stage)
			if set.ok ~= true then return set end
			publish(citizenId, set.value, { reason = 'contract' })
			return set
		end,

		--- Forgets a citizen.
		-- @param citizenId string
		-- @return table a `Result`
		Clear = function(citizenId)
			local cleared = Ledger.Clear(citizenId)
			if cleared.ok ~= true then return cleared end
			publish(citizenId, { stage = 0, previous = cleared.value.previous, law = 'clear' },
				{ reason = 'contract' })
			return cleared
		end,

		--- The book, as the config stands now.
		-- @return table `{ ids, book, stages, count }`
		Book = function()
			return {
				ids = Law.Ids,
				book = Law.Book,
				stages = Law.Stages,
				count = Law.StageCount,
				maxtac = Law.Maxtac,
			}
		end,
	})
end

--- Registers what the module answers to, and starts the decay pass.
function M.Start()
	character = OPX.Api.Get('character')
	hud = OPX.Api.Get('hud')

	for _, line in ipairs(Law.Warnings) do
		Open77.log.warn('[ncpd] config: ' .. line)
	end

	-- The street half, named before it is needed: a host without the vehicle or
	-- the npc contract is a response that cannot arrive, and that is worth one
	-- line at boot rather than a silent empty street at stage 4.
	local canSpawn = type(Open77.vehicles) == 'table' and type(Open77.npcs) == 'table'
	Open77.log.info(('[ncpd] ready: %d law(s), %d heat stage(s): %s; %s')
		:format(#Law.Ids, Law.StageCount, ladder(),
			canSpawn and 'the street can answer' or 'NO spawn contract: units will be refused'))

	-- Named at BOOT, not at the first charge. The client refuses to raise its own
	-- heat while its ambient policy has not heard that this bucket allows police,
	-- so a stage applied before the policy lands is a star with no unit behind it
	-- -- and the one window that cannot be retried is the first one. See
	-- `allowPolice` in `response.lua` for what the bit is and why it is the
	-- server's to set.
	-- Only the refusal is said HERE. The write that succeeds already prints its
	-- own line, with the crowd and traffic it preserved, and a second line for
	-- the same fact at the same moment is noise -- the first boot after the
	-- policy was ever empty is the only boot that needs either of them.
	local police, policeWhy = Response.AllowPolice(0)
	if not police then
		Open77.log.warn('[ncpd] bucket 0 does NOT allow police (' .. tostring(policeWhy) ..
			'): stages will set with no unit behind them')
	end
	if character == nil then
		Open77.log.warn('[ncpd] no character contract: nobody can be charged')
	end

	registerCommands()
	-- The two wire handlers are registered once, below with the crew door: `M.Start`
	-- runs again on a module restart, and a second registration answers twice.

	-- THE KILLS (`HOMICIDE` in config). Subscribed ONCE, the rule the crowd's
	-- own handlers keep: `M.Start` runs again on a module restart, and a second
	-- pair of handlers would charge and call in every body twice.
	if not killHandlers then
		killHandlers = true
		AddEventHandler('open77:playerKilled', function(victimId, killerId, context)
			local ran, failure = pcall(onPlayerKilled, victimId, killerId, context, 'playerKilled')
			if not ran then
				Open77.log.error('[ncpd] a player kill could not be read: ' .. tostring(failure))
			end
		end)
		-- THE TWO NETS UNDER IT. The host raises `playerKilled` only for a death it
		-- could attribute; the lethal hit and the bare death are how a kill it did
		-- not attribute still reaches the book. One death is one charge whichever
		-- of the three comes first (`deathBooked`).
		AddEventHandler('open77:playerDamaged', function(...)
			local ran, failure = pcall(onPlayerHurt, ...)
			if not ran then
				Open77.log.error('[ncpd] a player hit could not be read: ' .. tostring(failure))
			end
		end)
		AddEventHandler('open77:playerDied', function(playerId, context)
			local ran, failure = pcall(onPlayerDied, playerId, context)
			if not ran then
				Open77.log.error('[ncpd] a player death could not be read: ' .. tostring(failure))
			end
		end)
		AddEventHandler('onNpcDied', function(npcId, killer)
			local ran, failure = pcall(onNpcKilled, npcId, killer)
			if not ran then
				Open77.log.error('[ncpd] an npc kill could not be read: ' .. tostring(failure))
			end
		end)
	end

	-- The airwaves: one voice channel per band on the host's own VOIP, seated
	-- by the same audience rule the line feed pushes with (`server/radio.lua`).
	M.Radio.VoiceStart()

	-- The operator's crowd, when the build carries it: mortal civilians whose
	-- deaths are charged through the door above.
	if M.Bots ~= nil and type(M.Bots.Start) == 'function' then M.Bots.Start() end

	-- THE HIT RELAY (`server/hits.lua`): what turns a player's shot at one of this
	-- module's bodies into damage, and so into a death the handlers above can
	-- charge. The platform does not carry that shot to the server on its own.
	if M.Hits ~= nil and type(M.Hits.Start) == 'function' then
		M.Hits.Start({
			characterOf = characterOf,
			positionOf = positionOf,
			onCall = onCall,
			-- Whose body it is, by the two tables that placed one: the id the
			-- host was handed back, and which kind of body it is.
			resolve = function(key)
				local id = Response.IdOf(key)
				if id ~= nil then return id, 'police' end
				if M.Bots ~= nil and type(M.Bots.IdOf) == 'function' then
					id = M.Bots.IdOf(key)
					if id ~= nil then return id, 'crowd' end
				end
				return nil
			end,
			-- The one door a body's death is booked through when the platform
			-- raised no event for it: the crowd first (it books its own), then
			-- the module's kill rule (which leaves the crowd's to the crowd).
			died = function(npcId, source, cause)
				if M.Bots ~= nil and type(M.Bots.Died) == 'function' then
					M.Bots.Died(npcId, source, cause)
				end
				onNpcKilled(npcId, source)
			end,
		})
	end

	-- The crew door's own ask, and it carries nothing at all. The player comes
	-- from the connection, the permission from the module's own duty rule, the
	-- hull and the distance from the controller's own reads -- so a modified
	-- client can knock, and that is the whole of what it can do.
	if not netHandlers then
		netHandlers = true
		RegisterNetEvent(M.Event.REPORT, onEngineStage)
		RegisterNetEvent(M.Event.BOARD, function()
			-- No `source` parameter: the sender is the host's `source` global,
			-- and a parameter of that name shadows it with the empty payload.
			local playerId = tonumber(source)
			if playerId == nil or playerId <= 0 then return end
			local data = characterOf(playerId)
			local permit = data ~= nil and mayBoard(data) or 'noCitizen'
			local av = M.Av
			local seat, why = nil, 'the aircraft controller is unavailable'
			if av ~= nil and type(av.Board) == 'function' then
				seat, why = av.Board(playerId, permit)
			end
			if seat == nil then
				Open77.log.info(('[ncpd] player %d could not board the MaxTac AV: %s')
					:format(playerId, tostring(why)))
			end
			TriggerClientEvent(M.Event.BOARDED, playerId, {
				ok = seat ~= nil,
				seat = seat,
				reason = seat == nil and tostring(why) or nil,
			})
		end)
	end

	M.running = true
	CreateThread(function()
		while M.running do
			Wait(1000)
			decayPass()
			-- A suspect who is down first, so the room their response held is
			-- free before the ceiling is asked who gets it.
			local ran, failure = pcall(neutralizePass)
			if not ran then Open77.log.error('[ncpd] the neutralize pass raised: ' .. tostring(failure)) end
			ran, failure = pcall(refillPass)
			if not ran then Open77.log.error('[ncpd] the refill pass raised: ' .. tostring(failure)) end
		end
	end)
end

--- Deregisters the surface and takes every response down.
function M.Stop()
	M.running = false
	sceneCalled = {}
	deathBooked, npcBooked, lastHurt, killings = {}, {}, {}, {}
	downSince, stoodDown = {}, {}
	if M.Hits ~= nil and type(M.Hits.Stop) == 'function' then M.Hits.Stop() end
	if M.Bots ~= nil and type(M.Bots.Stop) == 'function' then M.Bots.Stop() end
	-- The aircraft first: `Response.ReleaseAll` walks the responses it still
	-- holds, and an insertion is not one of them -- it is a run of its own that
	-- would otherwise keep posing an airframe in a bucket nothing owns again.
	local av = M.Av
	local flying = av ~= nil and type(av.RetractAll) == 'function' and av.RetractAll('the module stopped') or 0
	local removed = Response.ReleaseAll()
	Ledger.Forget()
	if flying > 0 then
		Open77.log.info(('[ncpd] stopped: %d MaxTac AV(s) taken down'):format(flying))
	end
	if removed > 0 then
		Open77.log.info(('[ncpd] stopped: %d unit(s) taken down'):format(removed))
	end
end
