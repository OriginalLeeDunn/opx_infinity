--- Entry, the wire doorways, the commands, the background work and the phases.
-- @author dop42
--
-- Nothing in the handlers below decides anything: each one checks what arrived
-- and calls into character.lua or player.lua. Everything a client sends is
-- attacker-controlled; only `source` cannot be forged.
--
-- Core owns sessions, the readiness gate, routing buckets, cooldowns and the
-- answer channels. It deliberately does not know this module's name, so the
-- entry sequence -- hold, isolate, send the roster, hand the give-up decision to
-- the gate watch -- lives here, where the roster does.

local M = OPX.Modules.Get('character')

-- Core announces a dropped session here and leaves the unloading to whoever owns
-- the roster.
local SESSION_FORGOTTEN = OPX.Event(OPX.Channel.INTERNAL, 'session', 'forgotten')

-- What the platform log shows against our hold.
local HOLD_REASON = 'opx_infinity:character-selection'

-- How long entry waits for the boot thread to settle the schema question, and
-- how often it looks. Bounded so a boot that never finishes leaves no thread
-- polling for the life of the resource; the gate watch is what the player sees.
local BOOT_SETTLE_MS = 30000
local BOOT_POLL_MS = 100

-- ── the background pass ──────────────────────────────────────────────────────

-- Milliseconds between two passes. Position is sampled at 1 Hz because by the
-- time a disconnect handler runs the session is usually gone and the host answers
-- no position at all.
local SAMPLE_MS = 1000

-- Metres a character must move before its row counts as dirty. Zero would make
-- every idle character a moving one: a standing player drifts a few centimetres
-- while an animation settles.
local MOVED_METRES = 1.0

-- Position and revision at each character's last successful write.
local lastWritten = {}

-- Set by Stop so the background thread ends with the module.
local stopped = false

--- Answers whether a character's row would come out different.
-- Two questions, because position sits outside the revision counter: a 1 Hz
-- sample routed through a mutator would dirty everybody every pass.
local function needsWriting(player)
	local mark = lastWritten[player.PlayerData.citizenId]
	if not mark then return true end
	if player.Revision ~= mark.revision then return true end

	local current = player.PlayerData.position
	if not current then return false end
	if not mark.position then return true end
	return OPX.Math.DistanceSquared(current, mark.position) >= MOVED_METRES * MOVED_METRES
end

--- Records the revision and position a successful write stored.
-- @param revision integer Read BEFORE the write started.
local function remember(player, revision)
	local position = player.PlayerData.position
	lastWritten[player.PlayerData.citizenId] = {
		revision = revision,
		position = position and { x = position.x, y = position.y, z = position.z } or nil,
	}
end

--- Writes every loaded character whose row would come out different.
local function autosave()
	local players = M.GetPlayers()
	local written = 0

	for i = 1, #players do
		local player = players[i]
		if needsWriting(player) then
			-- The revision is read BEFORE the write: Save yields, and a payment that
			-- arrived meanwhile would otherwise be marked as already written.
			local revision = player.Revision
			local saved = M.Save(player, false)
			if saved.ok then
				remember(player, revision)
				written = written + 1
			end
		end
	end

	if written > 0 then
		Open77.log.debug(('[character] autosave wrote %d of %d character(s)')
			:format(written, #players))
	end
end

--- Pays every eligible character their grade payment.
local function paycheck()
	local players = M.GetPlayers()
	local requireDuty = M.Settings.MONEY.PAYCHECK_REQUIRES_DUTY

	for i = 1, #players do
		local player = players[i]
		local job = player.PlayerData.job
		local definition = M.Groups.GetJob(job.name)
		local payment = math.floor(job.payment or 0)

		-- `offDutyPay` is the job's own exemption, and the global switch does not
		-- contradict it.
		local eligible = payment > 0
			and (not requireDuty or job.onDuty or (definition and definition.offDutyPay))

		if eligible then
			if OPX.Hooks.Trigger('paycheck:before', { player = player, amount = payment }) then
				if M.AddMoney(player, M.PaycheckType, payment, 'paycheck:' .. job.name) then
					-- SAID AS WHERE IT WENT. A paycheck paid into the account is
					-- money the player has to go and draw at a bank branch
					-- (`modules/bank`), and "You received 150 BANK" never said so.
					-- A cash paycheck reads the way main words it, the amount
					-- formatted with its kind (`OPX.Locale.Money`).
					local toBank = M.PaycheckType == 'BANK'
					OPX.NotifyLocale(player.PlayerData.source,
						toBank and 'money.paycheckBank' or 'money.paycheck',
						{ amount = toBank and M.FormatMoney(payment) or OPX.Locale.Money(payment, M.PaycheckType),
							job = job.label }, 'success')
					TriggerEvent(M.Event.IN_PAYCHECK,
						player.PlayerData.source, payment, job.name)
				end
			end
		end
	end
end

--- Forgets the write tracking of characters nobody is playing.
local function prune()
	for citizenId in pairs(lastWritten) do
		if not M.Registry.byCitizenId[citizenId] then
			lastWritten[citizenId] = nil
		end
	end
end

-- When the next autosave, paycheck and prune are due.
local nextSaveAt, nextPaycheckAt, nextPruneAt

--- Runs one pass: sampling, autosave, paychecks and pruning.
local function tick()
	-- Deliberately `pairs(M.Players)` and not `M.GetPlayers()`: that walk evicts,
	-- and an eviction would put a database write inside a 1 Hz loop.
	local sampled, sampleError = pcall(function()
		for _, player in pairs(M.Players) do
			M.SamplePosition(player)
		end
	end)
	if not sampled then
		Open77.log.error('[character] position sampling raised: ' .. tostring(sampleError))
	end

	local now = OPX.Now()

	-- The intervals are re-read at every deadline: a setting captured in a local
	-- at load freezes for the life of the resource. Each job is wrapped in its own
	-- pcall so that one failing job does not stop the others.
	if now >= nextSaveAt then
		nextSaveAt = now + M.Number(M.Settings.AUTOSAVE_SECONDS, 300) * 1000
		local ok, err = pcall(autosave)
		if not ok then Open77.log.error('[character] autosave raised: ' .. tostring(err)) end
	end

	local paycheckMinutes = M.Number(M.Settings.MONEY.PAYCHECK_MINUTES, 0)
	if paycheckMinutes > 0 and now >= nextPaycheckAt then
		nextPaycheckAt = now + paycheckMinutes * 60000
		local ok, err = pcall(paycheck)
		if not ok then Open77.log.error('[character] paycheck raised: ' .. tostring(err)) end
	end

	if now >= nextPruneAt then
		nextPruneAt = now + 300000
		prune()
	end
end

--- Runs the background pass until the module stops.
local function background()
	nextSaveAt = OPX.Now() + M.Number(M.Settings.AUTOSAVE_SECONDS, 300) * 1000
	nextPaycheckAt = OPX.Now() + math.max(M.Number(M.Settings.MONEY.PAYCHECK_MINUTES, 0), 1) * 60000
	nextPruneAt = OPX.Now() + 300000

	while not stopped do
		Wait(SAMPLE_MS)

		-- Nothing is written while the schema question is unsettled.
		if not OPX.BootError and not stopped then
			-- The whole pass is wrapped again by the loop: OPX.Now and the settings
			-- are host reads too, and an error in one of them would end the autosave
			-- for the rest of the session.
			local ok, err = pcall(tick)
			if not ok then
				Open77.log.error('[character] the background pass raised: ' .. tostring(err))
			end
		end
	end
end

-- ── entry ────────────────────────────────────────────────────────────────────

--- Releases the gate and closes the connection of a player who cannot be
--- admitted at all.
-- Releasing the gate alone would leave them in bucket 0 with no character, for
-- ever. Every attempt from a selector would meet the same missing identity, so
-- there is nothing to retry.
local function refuseEntry(source, code, note)
	OPX.Gate.Release(source, note)
	local closed, reason = Open77.players.disconnect(source, locale(code))
	if not closed then
		Open77.log.error(('[character] could not disconnect %d (%s): %s')
			:format(source, note, tostring(reason)))
		OPX.Refuse(source, code, M.Operation.ENTRY)
	end
end

--- Holds the gate, isolates the player and sends them their roster.
-- The bucket move is deliberately made with the gate still shut: it writes no
-- transform and no life state, and taken now nobody else has ever been
-- replicated into the world this player is about to load into.
-- @author dop42
-- @param source Source
function M.BeginEntry(source)
	local session = OPX.EnsureSession(source)
	if not session then
		Open77.log.error(('[character] no verified identity for %d, refusing entry'):format(source))
		refuseEntry(source, 'entry.noIdentity', 'no-identity')
		return
	end
	Open77.log.debug(('[character] %s (%s) connected as %d')
		:format(session.displayName, session.userId, source))

	OPX.Gate.Hold(source, HOLD_REASON)

	OPX.Buckets.Isolate(source, 'joined')

	-- THE GIVE-UP WATCH, AND NOTHING CALLED IT BEFORE THIS. Every return path in
	-- the thread below releases the hold, but a read that never answers returns
	-- from nothing: a database that has stopped responding leaves this player
	-- behind a shut gate until the HOST's liveness interval expires, and the host
	-- then opens it with `liveness_lost:` and no idea why. The watch's deadline
	-- sits below that interval on purpose -- `core/server/gate.lua` says the
	-- runtime "gives up first, and says why" -- and with no caller that sentence
	-- was untrue and `ENTRY.WATCH_MS` was a validated operator setting with no
	-- effect at all.
	--
	-- It answers anything but false, so core releases the hold itself. Answering
	-- false means "this player is mine now", which is only honest while somebody
	-- is going to release it; the thread below may be the thing that has stalled,
	-- so claiming the hold here is how it ends up held for the session.
	OPX.Gate.Watch(source, nil, function(src)
		Open77.log.error(('[character] entry for %d did not finish before the gate deadline; '
			.. 'releasing rather than leaving the hold for the host to time out'):format(src))
		OPX.Refuse(src, 'entry.failed', M.Operation.ENTRY)
	end)

	-- Its own thread, for the database reads, and no failure path leaves the
	-- player held. There is nothing to choose and nothing to wait for: the account
	-- is locked on a character, or it is about to be locked on a new one.
	--
	-- THE ACCOUNT THIS ENTRY IS FOR, read before anything yields. `EnterSession`
	-- is database reads end to end and every one of them gives up the thread; a
	-- player who drops during a slow read has their slot recycled, and the
	-- failure path below then spoke for whoever took it -- a refusal toast to a
	-- stranger, and a gate release that admitted them with no character.
	local userId = session.userId

	CreateThread(function()
		-- BOOT IS NOT INSTANT, AND NOTHING WAITED FOR IT. `OPX.Booted` was
		-- written twice in `core/server/boot.lua` and read nowhere at all: the
		-- guards that matter all read `OPX.BootError`, which is nil for the
		-- whole of boot precisely because the schema question has not been
		-- settled yet. A player reconnecting just after a restart came through
		-- here while `Schema.Apply` was still creating tables -- every statement
		-- is a round trip that yields, and `Start` yields between every module,
		-- so the window is dozens of frames -- and the reads below then ran
		-- against tables that did not exist, with `OPX.BootError` set behind
		-- them on a player who was already half in.
		--
		-- Waiting is kinder than refusing, and costs nothing: the gate hold is
		-- already taken, so the player simply stays behind it, and the watch
		-- started above gives up and says why if boot never settles.
		local waited = 0
		while not OPX.Booted and waited < BOOT_SETTLE_MS do
			Wait(BOOT_POLL_MS)
			waited = waited + BOOT_POLL_MS
		end
		if not OPX.Booted then
			Open77.log.error(('[character] boot had not settled after %d ms; refusing entry for %d')
				:format(waited, source))
			local stalled = OPX.Sessions[source]
			if stalled and stalled.userId == userId then
				OPX.Refuse(source, 'entry.failed', M.Operation.ENTRY)
				OPX.Gate.Release(source, 'boot-unsettled', userId)
			end
			return
		end

		local entered = M.EnterSession(source)
		if entered.ok then return end
		Open77.log.error(('[character] %d could not be brought into the world: %s (%s)')
			:format(source, tostring(entered.error), tostring(entered.detail)))
		local live = OPX.Sessions[source]
		if not live or live.userId ~= userId then
			Open77.log.warn(('[character] %d is no longer %s; not answering for the slot')
				:format(source, tostring(userId)))
			return
		end
		OPX.Refuse(source, 'entry.failed', M.Operation.ENTRY)
		OPX.Gate.Release(source, 'entry-failed', userId)
	end)
end

-- ── the wire doorways ────────────────────────────────────────────────────────

--- Registers every event handler.
-- Each net handler checks its cooldown BEFORE its CreateThread, on a `.request`
-- key of its own: `Cooling` records the attempt it allows, so sharing the key of
-- the operation itself would make the operation refuse itself.
local function registerEvents()
	-- A broadcast: `source` is not set on it, so the player id arrives as an
	-- argument, and as a string. It carries nothing else -- the name and the
	-- account come from the session BeginEntry has just made.
	AddEventHandler(OPX.Host.PLAYER_CONNECTED, function(rawPlayerId)
		local src = tonumber(rawPlayerId)
		if not src or src <= 0 then
			Open77.log.error(('[character] unusable player id %q on connect')
				:format(tostring(rawPlayerId)))
			return
		end
		M.BeginEntry(src)
	end)

	-- A departure is best effort: one nobody reports is covered by the account
	-- re-check in `GetPlayers`, and Logout is idempotent. The citizen id is read
	-- BEFORE Logout, which removes it, and Logout runs BEFORE ForgetSession so
	-- that the position is still sampled for a normal departure.
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(rawPlayerId, reason)
		local src = tonumber(rawPlayerId)
		if not src then return end
		local session = OPX.Sessions[src]
		local player = M.Players[src]
		local citizenId = player and player.PlayerData.citizenId or nil
		OPX.Audit.Log({
			event = 'session.disconnect',
			severity = 'info',
			source = src,
			citizenId = citizenId,
			userId = session and session.userId or nil,
			message = reason or 'connection_closed',
		})
		M.Logout(src)
		M.ForgetPlacement(src)
		OPX.ForgetSession(src)
		-- Both are keyed by source, and a source is recycled. The citizen id read
		-- earlier covers the audit entries keyed by character instead.
		OPX.ForgetCooldowns(src)
		OPX.Audit.Forget(src, citizenId)
	end)

	-- The platform says this player is incarnated: every hold has cleared, their
	-- client has announced gameplay-ready, and there is a living body to put the
	-- character's row on. THIS is where a join places, and nowhere earlier.
	AddEventHandler(OPX.Host.PLAYER_READY, function(rawPlayerId)
		local src = tonumber(rawPlayerId)
		if not src then return end
		if M.AwaitingPlacement[src] == nil then return end
		CreateThread(function() M.PlacePending(src) end)
	end)

	-- Core dropping a session is the safety net for a departure nobody signalled,
	-- and for a slot that changed hands: the character still attached is logged
	-- out and saved.
	--
	-- THE EVENT IS QUEUED (`core/server/sessions.lua`), so this runs a tick after
	-- the session is gone -- and on an eviction, after the NEXT account's session
	-- is already on the slot. The departed account travels with the event and is
	-- the one this acts for: a Player of any other account on the slot is somebody
	-- who has just arrived, and logging THEM out would be the bug.
	AddEventHandler(SESSION_FORGOTTEN, function(playerId, departedUserId)
		local player = M.Players[tonumber(playerId) or -1]
		if not player then return end
		if departedUserId ~= nil and player.PlayerData.userId ~= departedUserId then return end
		-- The slot may already belong to somebody else, whose position must never
		-- be written into this row: the save of an eviction does not sample.
		player.MaySample = false
		M.Logout(playerId)
	end)

	-- The client's announce, and what fills the roster again after a reload:
	-- onPlayerConnected does not fire a second time for players already here.
	RegisterNetEvent(M.Event.ANNOUNCE, function()
		local src = tonumber(source)
		if not src then return end
		if OPX.Cooling(src, 'ready', 2000) then return end

		local session = OPX.EnsureSession(src)
		if not session then return end

		-- Somebody who already has a character is told which one, and nothing else
		-- happens: this is a client that reloaded, not an arrival.
		local player = M.GetPlayer(src)
		if player then
			TriggerClientEvent(M.Event.LOADED, src, player.PlayerData)
			return
		end

		-- Isolated ONLY if their gate is still closed: an arrival whose move was
		-- refused, or someone still behind the gate when the VM reloaded. Whoever
		-- passed the gate has been in the world this session and stays where they
		-- are.
		if not OPX.Gate.IsReady(src) then OPX.Buckets.Isolate(src, 'ready') end

		CreateThread(function() M.EnterSession(src) end)
	end)

	-- The one thing a player still types about their character. It is accepted
	-- once: `SetName` refuses a second one, and the client only asks while the row
	-- it is loaded on has no name.
	RegisterNetEvent(M.Event.NAME, function(payload)
		local src = tonumber(source)
		if not src then return end

		local operation = M.Operation.NAME
		if type(payload) ~= 'table' then
			return OPX.Refuse(src, 'error.badRequest', operation)
		end
		if OPX.Cooling(src, 'name.request', 1000) then
			return OPX.Refuse(src, 'error.tooFast', operation)
		end

		CreateThread(function()
			local named = M.SetName(src, payload.firstName, payload.lastName)
			if not named.ok then
				-- The bounds ride along: the length sentence names them.
				OPX.Refuse(src, named.error, operation, nil, select(2, M.NameRefusal(nil)))
				return
			end
			OPX.NotifyLocale(src, 'character.named', {
				name = ('%s %s'):format(named.value.firstName, named.value.lastName),
			}, 'success')
		end)
	end)

	-- A hint, nothing more. Only the heading is kept: x, y and z are re-derived
	-- from the server snapshot when the row is written, so a client lying about
	-- them lies to nobody. The cooldown is a literal and not a client setting: the
	-- server VM never loads the client configuration.
	RegisterNetEvent(M.Event.HEADING, function(payload)
		local src = tonumber(source)
		if not src then return end

		if OPX.Cooling(src, 'heading', 1000) then return end

		local player = M.GetPlayer(src)
		if not player then return end

		local heading = OPX.Validate.Number(
			type(payload) == 'table' and payload.heading or nil, { min = -360, max = 360 })
		if heading.ok then player.PlayerData.reportedHeading = heading.value end
	end)
end

-- ── the commands ─────────────────────────────────────────────────────────────

--- Answers the caller's loaded Player, or tells them they have none.
-- The console runs as source 0, which is not a player and has no character.
local function requirePlayer(source, raw)
	local player = M.GetPlayer(source)
	if not player then
		OPX.CommandNotice(source, raw, 'error', locale('error.notLoggedIn'))
		return nil
	end
	return player
end

--- Resolves a player id or citizen id argument to a loaded Player.
-- By its PARSED form and never the raw one: a citizen id typed without its
-- separator is still a citizen id.
local function targetOf(argument, fallbackSource)
	if argument == nil then return M.GetPlayer(fallbackSource) end
	local asId = tonumber(argument)
	if asId then return M.GetPlayer(asId) end
	local parsed = OPX.CitizenId.Parse(argument)
	if not parsed.ok then return nil end
	return M.GetPlayerByCitizenId(parsed.value)
end

--- Renders a failed Result as catalogue text, logging a hidden cause.
-- A MySQL message has no business in a toast.
local function failureText(failed, withDetail)
	local key = OPX.RefusalKey(failed.error)
	if key ~= failed.error then
		Open77.log.warn(('[character] %s: %s')
			:format(tostring(failed.error), tostring(failed.detail)))
		return locale(key)
	end
	if withDetail and failed.detail ~= nil then
		return ('%s (%s)'):format(locale(key), tostring(failed.detail))
	end
	return locale(key)
end

--- Registers every command through core, which owns the ACL flag, the doorway
--- cooldown and the suggestion list.
-- An open command shares its cooldown `key` with the wire door into the same
-- operation, so that both entrances share one window.
local function registerCommands()
	OPX.Command.Register('opx.players', { restricted = true, help = 'command.help.players' },
		function(source)
			local players = M.GetPlayers()
			-- Sorted so that two runs compare line by line.
			table.sort(players, function(a, b) return a.PlayerData.source < b.PlayerData.source end)
			local lines = {
				('character -- %d character(s) in the world'):format(#players),
			}
			if OPX.BootError then
				lines[#lines + 1] = ('  DEGRADED: %s'):format(OPX.BootError)
			end
			for i = 1, #players do
				local data = players[i].PlayerData
				lines[#lines + 1] = ('  %-4d %-10s %s %s  %s')
					:format(data.source, data.citizenId,
						data.charInfo.firstName or '?', data.charInfo.lastName or '?',
						data.job.label or '?')
			end
			OPX.CommandResult(source, true, table.concat(lines, '\n'))
		end)

	-- What the SERVER believes, and nothing else.
	OPX.Command.Register('opx.where', { restricted = true, help = 'command.help.where' },
		function(source, args, raw)
			local target = tonumber(args[1]) or source
			local session = OPX.Sessions[target]
			if not session then
				return OPX.CommandNotice(source, raw, 'warning',
					locale('command.noSession', { id = target }))
			end

			local player = M.GetPlayer(target)
			local position = Open77.players.position(target)
			local life = Open77.players.getLifeState(target)

			local lines = {
				('player %d  user=%s  name=%s')
					:format(target, tostring(session.userId), tostring(session.displayName)),
				('  character : %s'):format(player and player.PlayerData.citizenId or 'none loaded'),
				('  gate      : %s'):format(session.gateSession and 'held' or 'released'),
				('  life      : %s'):format(life and life.phase or 'unreadable'),
				('  position  : %s'):format(position
					and ('%.1f %.1f %.1f  bucket=%d'):format(position.x, position.y, position.z,
						position.bucket or 0)
					or 'unreadable'),
			}
			if player then
				local data = player.PlayerData
				lines[#lines + 1] = ('  job       : %s %s')
					:format(data.job.name, data.job.onDuty and '(on duty)' or '')
				lines[#lines + 1] = ('  gang      : %s'):format(data.gang.name)
				local moneyTypes = {}
				for moneyType in pairs(data.money) do moneyTypes[#moneyTypes + 1] = moneyType end
				-- Sorted, or `pairs` would reorder the block between two runs.
				table.sort(moneyTypes)
				for i = 1, #moneyTypes do
					lines[#lines + 1] = ('  %-10s: %d')
						:format(moneyTypes[i], data.money[moneyTypes[i]])
				end
			end
			OPX.CommandResult(source, true, table.concat(lines, '\n'))
		end)

	-- Prints the position in exactly the shape DEFAULT_SPAWN expects.
	OPX.Command.Register('opx.here', { restricted = true, help = 'command.help.here' },
		function(source, _, raw)
			if source <= 0 then
				return OPX.CommandResult(source, false, 'opx.here has to be run in game')
			end
			local position = Open77.players.position(source)
			if not position then
				return OPX.CommandNotice(source, raw, 'error', locale('command.positionUnreadable'))
			end

			local player = M.GetPlayer(source)
			local heading = player and player.PlayerData.reportedHeading or 0.0
			OPX.CommandResult(source, true, ([[
DEFAULT_SPAWN = {
  SET = true,
  X = %.2f,
  Y = %.2f,
  Z = %.2f,
  HEADING = %.2f,
},]]):format(position.x, position.y, position.z, heading))
		end)

	-- The three commands the roster screen used to be. A player reads their
	-- characters, takes one, or asks for a new one -- and the last two end the
	-- session, because a character is entered at a connection and nowhere else.
	OPX.Command.Register('opx.characters',
		{ help = 'command.help.characters', cooldownMs = 2000, key = 'characters' },
		function(source, _, raw)
			if source <= 0 then
				return OPX.CommandNotice(source, raw, 'error', locale('command.inGameOnly'))
			end
			CreateThread(function()
				local listed = M.ListCharacters(source)
				if not listed.ok then
					return OPX.CommandNotice(source, raw, 'error',
						locale(OPX.RefusalKey(listed.error)))
				end
				local list = listed.value.characters
				local lines = { locale('command.characterCount',
					{ count = #list, slots = listed.value.slots }) }
				for i = 1, #list do
					local character = list[i]
					local name = character.firstName ~= nil
						and ('%s %s'):format(character.firstName, character.lastName or '')
						or locale('character.unnamed')
					lines[#lines + 1] = ('  %s %-10s %-26s %s'):format(
						character.citizenId == listed.value.active and '>' or ' ',
						character.citizenId, name, character.gender or '-')
				end
				-- The hint says what the two commands DO, and under a relog only one
				-- of them still disconnects. Chosen from the resolved mode rather
				-- than written once: a player told they will be kicked and then not
				-- kicked stops believing the next thing the line says.
				lines[#lines + 1] = locale(M.SwitchMode == M.Switch.RELOG
					and 'command.characterHintRelog' or 'command.characterHint')
				OPX.CommandResult(source, true, table.concat(lines, '\n'))
			end)
		end)

	OPX.Command.Register('opx.select',
		{ help = 'command.help.select', cooldownMs = 3000, key = 'select.request' },
		function(source, args, raw)
			if source <= 0 or not args[1] then
				return OPX.CommandNotice(source, raw, 'warning', locale('command.usage.select'))
			end
			CreateThread(function()
				local switched = M.SwitchTo(source, args[1])
				if not switched.ok then
					return OPX.CommandNotice(source, raw, 'error',
						locale(OPX.RefusalKey(switched.error)))
				end
				-- Under `reconnect` this notice races the disconnect the command
				-- asked for, so it is sent and not waited on: the reason the player
				-- reads is then the one carried by the disconnect itself. Under
				-- `relog` nothing races it and it is the only thing they are told,
				-- which is the point -- the switch has already happened around them.
				local name = switched.value.firstName ~= nil
					and ('%s %s'):format(switched.value.firstName, switched.value.lastName or '')
					or locale('character.unnamed')
				-- `locked` tells them to reconnect; under a relog there is nothing
				-- to reconnect to, because they are already standing in the world
				-- as the character they asked for.
				OPX.CommandNotice(source, raw, 'success',
					locale(M.SwitchMode == M.Switch.RELOG and 'command.switched'
						or 'command.locked', { name = name }))
			end)
		end)

	-- Only the catalogue line is answered: the command is open, and a detail can
	-- carry a raw exception from the database.
	OPX.Command.Register('opx.create',
		{ help = 'command.help.create', cooldownMs = 3000, key = 'create.request' },
		function(source, _, raw)
			if source <= 0 then
				return OPX.CommandNotice(source, raw, 'error', locale('command.inGameOnly'))
			end
			CreateThread(function()
				local asked = M.NewCharacter(source)
				OPX.CommandNotice(source, raw, asked.ok and 'success' or 'error',
					asked.ok and locale('command.buildingNew')
						or locale(OPX.RefusalKey(asked.error), { max = asked.detail }))
			end)
		end)

	OPX.Command.Register('opx.delete',
		{ help = 'command.help.delete', cooldownMs = 1000, key = 'delete.request' },
		function(source, args, raw)
			if source <= 0 or not args[1] then
				return OPX.CommandNotice(source, raw, 'warning', locale('command.usage.delete'))
			end
			-- ASKED TWICE, BECAUSE IT CANNOT BE UNDONE. A delete takes the
			-- character's clothes, items, vehicles and groups with it, and one
			-- typed character in a citizen id is somebody else of yours. So the
			-- bare command only says what it is about to do and how to go on.
			if tostring(args[2] or ''):lower() ~= 'confirm' then
				return OPX.CommandNotice(source, raw, 'warning',
					locale('character.deleteConfirm', { citizenId = tostring(args[1]) }))
			end
			CreateThread(function()
				local deleted = M.DeleteCharacter(source, args[1])
				OPX.CommandNotice(source, raw, deleted.ok and 'success' or 'error',
					deleted.ok and locale('character.deleted')
						or locale(OPX.RefusalKey(deleted.error)))
			end)
		end)

	-- Every run costs two outgoing events carrying the whole PlayerData, hence the
	-- 2 s cooldown. The success is already toasted by SetJobDuty, so `toasted`
	-- holds it to one.
	OPX.Command.Register('opx.duty',
		{ help = 'command.help.duty', cooldownMs = 2000, key = 'duty' },
		function(source, _, raw)
			local player = requirePlayer(source, raw)
			if not player then return end
			CreateThread(function()
				local toggled = M.Groups.SetJobDuty(player, not player.PlayerData.job.onDuty)
				OPX.CommandNotice(source, raw, toggled.ok and 'success' or 'error',
					toggled.ok and (toggled.value and locale('job.onDuty') or locale('job.offDuty'))
						or locale(OPX.RefusalKey(toggled.error)), toggled.ok)
			end)
		end)

	OPX.Command.Register('opx.money', { restricted = true, help = 'command.help.money' },
		function(source, args, raw)
			local target = targetOf(args[1], source)
			local moneyType = args[2] and args[2]:upper()
			local amount = tonumber(args[3])
			if not target or not moneyType or not amount then
				return OPX.CommandNotice(source, raw, 'warning', locale('command.usage.money'))
			end

			local reason = ('staff command by %s'):format(tostring(source))

			-- A real if/else: in `a >= 0 and Add() or Remove()`, a false answered by
			-- Add would run Remove as well.
			local ok, why
			if amount >= 0 then
				ok, why = M.AddMoney(target, moneyType, amount, reason)
			else
				ok, why = M.RemoveMoney(target, moneyType, -amount, reason)
			end

			-- One parameter table covers every code the mutators answer; a spare
			-- parameter is ignored.
			OPX.CommandNotice(source, raw, ok and 'success' or 'error', ok
				and locale('command.moneySet', { citizenId = target.PlayerData.citizenId,
					amount = M.FormatMoney(target.PlayerData.money[moneyType] or 0, moneyType) })
				or locale(why or 'error.badRequest', { type = moneyType }))
		end)

	OPX.Command.Register('opx.job', { restricted = true, help = 'command.help.job' },
		function(source, args, raw)
			local target = targetOf(args[1], source)
			if not target or not args[2] then
				return OPX.CommandNotice(source, raw, 'warning', locale('command.usage.job'))
			end
			CreateThread(function()
				local set = M.Groups.SetJob(target, args[2], tonumber(args[3]) or 0)
				OPX.CommandNotice(source, raw, set.ok and 'success' or 'error',
					set.ok and locale('command.jobSet', { citizenId = target.PlayerData.citizenId,
						grade = set.value.grade.name, job = set.value.label })
						or failureText(set, true))
			end)
		end)

	OPX.Command.Register('opx.gang', { restricted = true, help = 'command.help.gang' },
		function(source, args, raw)
			local target = targetOf(args[1], source)
			if not target or not args[2] then
				return OPX.CommandNotice(source, raw, 'warning', locale('command.usage.gang'))
			end
			CreateThread(function()
				local set = M.Groups.SetGang(target, args[2], tonumber(args[3]) or 0)
				OPX.CommandNotice(source, raw, set.ok and 'success' or 'error',
					set.ok and locale('command.gangSet', { citizenId = target.PlayerData.citizenId,
						grade = set.value.grade.name, gang = set.value.label })
						or failureText(set, true))
			end)
		end)

	OPX.Command.Register('opx.group', { restricted = true, help = 'command.help.group' },
		function(source, args, raw)
			local groupType, name = args[1], args[2]
			if groupType ~= 'job' and groupType ~= 'gang' or not name then
				return OPX.CommandNotice(source, raw, 'warning', locale('command.usage.group'))
			end
			CreateThread(function()
				local members = M.Groups.GetGroupMembers(groupType, name)
				if not members.ok then
					return OPX.CommandNotice(source, raw, 'error', failureText(members, false))
				end
				local lines = { ('%s %s -- %d member(s)'):format(groupType, name, #members.value) }
				for i = 1, #members.value do
					local member = members.value[i]
					lines[#lines + 1] = ('  %-10s grade %d  %s')
						:format(member.citizenId, member.grade, member.name)
				end
				OPX.CommandResult(source, true, table.concat(lines, '\n'))
			end)
		end)

	-- For the minute before a planned restart.
	OPX.Command.Register('opx.save', { restricted = true, help = 'command.help.save' },
		function(source, _, raw)
			CreateThread(function()
				local players = M.GetPlayers()
				local saved = 0
				for i = 1, #players do
					if M.Save(players[i]).ok then saved = saved + 1 end
				end
				OPX.CommandNotice(source, raw, 'success',
					locale('command.saved', { saved = saved, total = #players }))
			end)
		end)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds state and contributes this module's tables. Never yields.
function M.Init()
	-- Resolved once, so a name that is not a money type is reported at start
	-- rather than on every cycle.
	M.PaycheckType = M.Settings.MONEY.PAYCHECK_TYPE
	if not M.IsMoneyType(M.PaycheckType) then
		Open77.log.warn(('[character] MONEY.PAYCHECK_TYPE %s is not a money type; paying into %s')
			:format(tostring(M.PaycheckType), OPX.Config.SHARED.MONEY.DEFAULT))
		M.PaycheckType = OPX.Config.SHARED.MONEY.DEFAULT
	end

	-- HOW `opx.select` MOVES AN ACCOUNT, settled once here for the same reason as
	-- the paycheck type above it: a setting read at the point of use is a setting
	-- whose typo is reported in the middle of somebody's switch, where nobody
	-- reads it. Resolved at boot it is said once, in the block an operator scans
	-- after editing a config file.
	M.SwitchMode = M.KnownSwitch(M.Settings.CHARACTERS.SWITCH)
	if M.SwitchMode == nil then
		-- NAMED, NOT SILENT. Both values are on the line so the journal says what
		-- was refused and what is running instead: a typo that quietly went back
		-- to disconnecting people is indistinguishable from the relog not working.
		Open77.log.warn(('[character] CHARACTERS.SWITCH %s is not relog or reconnect; ' ..
			'switching by %s instead')
			:format(tostring(M.Settings.CHARACTERS.SWITCH), M.SWITCH_DEFAULT))
		M.SwitchMode = M.SWITCH_DEFAULT
	end

	OPX.Schema.Add(M.Storage.SCHEMA)
	OPX.Schema.AddIndexes(M.Storage.INDEXES)
end

--- Publishes the contract. Nothing may read one before this phase ends.
function M.Api()
	OPX.Api.Provide('character', 1, {
		GetPlayer = M.GetPlayer,
		GetPlayerByCitizenId = M.GetPlayerByCitizenId,
		GetPlayerByUserId = M.GetPlayerByUserId,
		GetPlayers = M.GetPlayers,
		GetPlayerCount = M.GetPlayerCount,
		ResolvePlayer = M.ResolvePlayer,
		GetCharacter = M.GetCharacter,

		-- The placement primitive, and not a transform: a placement is a kill and a
		-- respawn, which is what carries the fade, the streaming preload and the
		-- grace window. Published because the spawn module decides WHERE a brand new
		-- character starts and this module owns HOW every character is put
		-- anywhere. The optional second argument is that decision; omitted, the
		-- character's own row decides, as it always did.
		PlaceCharacter = M.PlaceCharacter,

		-- The cyberware identity: what the binder last did for a connection,
		-- and the one lever a "not ready" record has (bind again). Read by the
		-- ripperdoc's diagnosis; nothing else binds.
		CyberwareStatus = M.CyberwareStatus,
		RebindCyberware = M.RebindCyberware,

		AddMoney = M.AddMoney,
		-- The one money door that reaches a character nobody is playing. Answers
		-- a Result, unlike the three above, because it yields and reaches the
		-- database: `ok, code` cannot carry the balance it left behind.
		AddMoneyOffline = M.AddMoneyOffline,
		RemoveMoney = M.RemoveMoney,
		SetMoney = M.SetMoney,
		GetMoney = M.GetMoney,
		FormatMoney = M.FormatMoney,
		IsMoneyType = M.IsMoneyType,

		-- The closed public copy of a loaded character, the shape the creator
		-- exports and the public bus hand out. See `player.lua`.
		PublicView = M.PublicView,

		GetMetadata = M.GetMetadata,
		SetMetadata = M.SetMetadata,
		ReadMetadata = M.ReadMetadata,
		WriteMetadata = M.WriteMetadata,
		SetBodyFamily = M.SetBodyFamily,
		SetName = M.SetName,

		GetJob = M.Groups.GetJob,
		GetGang = M.Groups.GetGang,
		SetJob = M.Groups.SetJob,
		SetGang = M.Groups.SetGang,
		SetJobDuty = M.Groups.SetJobDuty,
		HasJob = M.Groups.HasJob,
		HasGang = M.Groups.HasGang,
		AddPlayerToJob = M.Groups.AddPlayerToJob,
		AddPlayerToGang = M.Groups.AddPlayerToGang,
		RemovePlayerFromJob = M.Groups.RemovePlayerFromJob,
		RemovePlayerFromGang = M.Groups.RemovePlayerFromGang,
		SetPlayerPrimaryJob = M.Groups.SetPlayerPrimaryJob,
		SetPlayerPrimaryGang = M.Groups.SetPlayerPrimaryGang,
		GetPlayersByJob = M.Groups.GetPlayersByJob,
		GetPlayersByGang = M.Groups.GetPlayersByGang,
		GetGroupMembers = M.Groups.GetGroupMembers,
		ListGroups = M.Groups.List,

		ListCharacters = M.ListCharacters,
		EnterSession = M.EnterSession,
		SelectCharacter = M.SelectCharacter,
		SwitchTo = M.SwitchTo,
		NewCharacter = M.NewCharacter,
		CreateCharacter = M.CreateCharacter,
		DeleteCharacter = M.DeleteCharacter,
		-- THE THREE STAFF DOORS, beside the self-service ones. None of them checks
		-- ownership and none reads `SELF_DELETE`; whoever calls them has passed the
		-- access list, and that is the check. They are here rather than in `admin`
		-- because what a character IS belongs to this module -- `admin` reads them
		-- through the contract on the SERVER, where a caller has been through the
		-- ACL, and never from a client, where a contract call is no check at all.
		ListCharactersFor = M.ListCharactersFor,
		-- The fourth, and the one that is handed no account: it searches EVERY
		-- account, because the person staff are looking for is not connected and
		-- there is no session to read one out of. Bounded in the SQL rather than
		-- by its caller -- see the function.
		FindCharacters = M.FindCharacters,
		RenameCharacter = M.RenameCharacter,
		RemoveCharacter = M.RemoveCharacter,

		Save = M.Save,
		Logout = M.Logout,
	})
end

--- Registers the doorways and starts the background work. Runs on a coroutine.
function M.Start()
	registerEvents()
	registerCommands()

	if not M.Settings.DEFAULT_SPAWN.SET then
		Open77.log.warn('[character] DEFAULT_SPAWN.SET is false in config/character.lua: ' ..
			'characters with no stored position are left where the game put them. Run ' ..
			'`opx.here` in game to print a coordinate in the right shape.')
	end
	Open77.log.debug(('[character] %d job(s) and %d gang(s) defined')
		:format(OPX.Table.Count(M.Settings.JOBS), OPX.Table.Count(M.Settings.GANGS)))

	CreateThread(background)
end

--- The last chance to write: one thread per character, never one loop.
-- A single loop would send the first UPDATE, suspend, and never be resumed. This
-- is best effort, and the log line says so.
function M.Stop()
	stopped = true

	-- Before the saves, which yield: a bag left standing is a name on a client
	-- with nothing left to change it.
	M.State.Release()

	local players = M.GetPlayers()

	for i = 1, #players do
		local player = players[i]
		CreateThread(function() M.Save(player, false) end)
	end

	Open77.log.info(('[character] stopping: dispatched a save for %d character(s), best effort')
		:format(#players))
end
