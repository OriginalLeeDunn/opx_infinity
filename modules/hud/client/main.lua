--- Samples the player, decides every tone, formats every number, and pushes the
--- seven overlay channels the HUD page draws.
-- @author dop42
--
-- THE PAGE DECIDES NOTHING. Two rules follow from that and they are the whole
-- shape of this file:
--
--   * a gauge's `tone` arrives decided. The thresholds are configuration, and a
--     page that coloured its own gauge would be a second opinion about the
--     player's health;
--   * a read-out's `value` arrives formatted. Separators, currency symbols and
--     rounding are decisions too.
--
-- Labels go the other way: they travel as CATALOGUE KEYS and the page resolves
-- them against the catalogue it was handed at boot, because a page that cannot
-- call back for a string per render still has to speak the player's language.
--
-- EVERY PUSH IS CHANGE-GATED. `hud:vitals` runs at the surface's own 30 fps, and
-- a channel at 30 Hz that re-sends an identical frame is pure cost. Each channel
-- keeps the signature of what the page last accepted; a send that did not land
-- forgets it, so the next pass tries again rather than believing the page is
-- showing something it never received.
--
-- AND THE GATE IS AHEAD OF THE BUILD, not only ahead of the send. A signature is
-- a concat over a table this file just allocated, so a channel gated only at the
-- send still paid to discover it had nothing to say. `hud:vitals` is gated on the
-- sampled pools instead, which is three integers, and builds the column only when
-- one of them moved. See the job in `Start`.
--
-- Nothing here is authoritative and nothing here writes: no mutator, no database
-- and no event to the server.

local M = OPX.Modules.Get('hud')

local Result = OPX.Result
local Settings = M.Settings

-- Page channels. `OPX.UI.Send` prefixes the surface id, so the page sees these
-- as `opx:hud:<verb>`.
local CHANNEL_CONFIG = 'hud:config'
local CHANNEL_VITALS = 'hud:vitals'
local CHANNEL_INFO = 'hud:info'
local CHANNEL_STATUS = 'hud:status'
local CHANNEL_VOICE = 'hud:voice'
local CHANNEL_VEHICLE = 'hud:vehicle'
local CHANNEL_SHOW = 'hud:show'
local CHANNEL_READY = 'hud:ready'

-- The character module's public bus.
local EVENT_CHARACTER_LOADED = OPX.Event(OPX.Channel.LOCAL, 'character', 'loaded')
local EVENT_CHARACTER_UNLOADED = OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded')
local EVENT_CHARACTER_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'character', 'changed')
local EVENT_CHARACTER_MONEY = OPX.Event(OPX.Channel.LOCAL, 'character', 'money')
local EVENT_CHARACTER_JOB = OPX.Event(OPX.Channel.LOCAL, 'character', 'job')

-- The needs module's public bus: the values, and the chip strip.
local EVENT_NEEDS_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'needs', 'changed')
local EVENT_NEEDS_EFFECTS = OPX.Event(OPX.Channel.LOCAL, 'needs', 'effects')

-- The downed module's public bus.
local EVENT_DOWNED_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed')

-- THE FOUR SCREENS THAT OWN THE DISPLAY INSTEAD OF THIS ONE, each on its own
-- module's public bus. Read with a bare AddEventHandler and nothing is required:
-- a world without one of these modules simply never raises its name, which is
-- the right answer rather than a HUD that hides for a screen nobody can open.
--
--   entry      the join: the name form, the character creator, and a fitting
--              room that is owed but not yet drawn. It already resolves all
--              three into one `open`, which is why this module does not have to.
--   spawn      the spawn menu, which stands aside behind `entry` and then has
--              the screen to itself.
--   appearance the fitting room once it IS drawn -- including one the player
--              asked for from the appearance panel, long after the join, which
--              `entry` knows nothing about and should not.
--   menu       any open menu. Added on the owner's word once the vanilla
--              minimap came back and the money block moved left to get out of
--              its way: a menu opening over that corner is one more thing in a
--              corner that now has two already.
local EVENT_ENTRY_STATE = OPX.Event(OPX.Channel.LOCAL, 'entry', 'state')
local EVENT_SPAWN_STATE = OPX.Event(OPX.Channel.LOCAL, 'spawn', 'state')
local EVENT_MENU_STATE = OPX.Event(OPX.Channel.LOCAL, 'menu', 'state')
local EVENT_APPEARANCE_DECISION = OPX.Event(OPX.Channel.LOCAL, 'appearance', 'decision')

-- THE GAME'S OWN LOADING SCREEN, a fifth screen in front of this one and the
-- only one that is not ours: `modules/loading` reads the platform's native
-- lifecycle and says `active` for as long as it is up. The page already takes
-- this HUD off screen for it; counting it here as well is what stops the two
-- sampling jobs below reading vitals and voice for a HUD nobody can see, and
-- keeps `hud:visibility` honest about why it is hidden.
local EVENT_LOADING_STATE = OPX.Event(OPX.Channel.LOCAL, 'loading', 'state')

-- This module's own public bus, raised after the surface was told, so a handler
-- reading the contract sees the visibility it was just told about. It must stay
-- on the LOCAL channel: the host dispatcher matches on the name alone.
local EVENT_VISIBILITY = OPX.Event(OPX.Channel.LOCAL, 'hud', 'visibility')

-- Raised by the engine when the local player's health, stamina or armour moved.
-- A host name, so it is not built from `OPX.Event`.
local HOST_STATS_CHANGED = 'open77:playerStatsChanged'

-- Voice links. Two platform resources, reached through their exports and never a
-- dependency: without either, the block still draws what the engine's own voice
-- status says.
local VOICE_MODE_CHANGED = 'open-voice:modeChanged'
local VOICE_HUD_VISIBLE = 'open-voice:setHudVisible'
local VOICE_KEY_CHANGED = 'open77:voice:pushToTalkKeyChanged'

-- Seat whose occupant drives; the front-left seat holds the physics lease.
local DRIVER_SEAT = 'seat_front_left'

-- Metres per second to kilometres per hour, and the highest speed drawn: a
-- physics spike must not widen the read-out.
local KPH = 3.6
local MAX_KPH = 999

-- Input level above which the microphone reads as picking up a voice.
local DETECT_LEVEL = 0.025

-- Longest key name kept from another resource, and most reach modes kept, as
-- many as open-voice accepts itself.
local MAX_KEY = 12
local MAX_MODES = 8

-- Bounds the chip strip's published offset, which reaches a CSS length.
local SURFACE_HEIGHT = 1080

-- Whether the player chose to see the HUD, and whether they are down. Held
-- apart: `visible` is the player's choice and goes on being recorded while they
-- are down, so standing them back up restores exactly what they had.
local visible = true
local down = false

-- WHO ELSE OWNS THE DISPLAY, by name, and how many of them there are.
--
-- The same mechanism as `down` and not a second one: a boolean beside the
-- player's own choice that takes the surface off without touching it. What
-- `down` could not be is SHARED -- being down is one module's answer, and the
-- character creator, the spawn menu and the fitting room are three, each
-- starting and ending on its own clock and any two of them able to overlap at
-- join. A single flag written by three owners is whichever of them finished
-- last; a set is the question actually being asked, which is "is anybody".
--
-- It stays out of `down` because the two are not the same fact. Down is a
-- condition of the character and the HUD is hidden BECAUSE of it; this is a
-- screen in front of the HUD, and the vitals under it are still true.
local owners, covered = {}, false

-- Live health, armour and stamina as percents, or nil where unreadable. A value
-- that cannot be read is never drawn as zero: an empty hunger bar is a thing a
-- player acts on.
local live = {}

-- The same pools in POINTS, for the read-out. Held apart from `live` because
-- they answer different questions and are gated separately: `live` is what the
-- bar is scaled by and is a share, this is what the number says and is not.
local points = {}

-- The needs the needs module published, nil until it has.
local needs = nil

-- The bounded chip strip and the count it left out.
local chips = {}
local hiddenChips = 0

-- Where the needs module asks its strip to sit, when this module's own config
-- does not say.
local stripAnchor = nil
local stripOffset = nil

-- Signature of the last payload the page accepted, per channel.
local drawn = {}

-- Whether the page has reported ready.
local ready = false

-- Visibility of each vanilla component before the first apply, and whether this
-- module currently hides them. Reported by the contract, for whoever is
-- debugging a game HUD that will not go away.
local vanillaFound = nil

-- Components whose refusal has been noted, so a refusal is said once.
local vanillaRefused = {}

-- The reach mode open-voice last applied, its cycle, and the two keys.
local reach = {}
local modes = {}
local cycleKey = nil
local pushToTalkKey = nil

-- Whether an unreadable stats bridge and a failed voice hide have been logged.
local statsReported = false

-- How many vitals readings have been relayed, and when the last one went. See
-- `sampleVitals`: `Open77.log` on a client writes to the PLAYER'S machine, so a
-- number an operator needs has to travel.

-- Whether a value is a number that is neither NaN nor infinite. The one shared
-- predicate, aliased rather than wrapped: a one-line wrapper is a second name
-- for the same answer and the only thing it can ever do is drift.
local finite = OPX.Math.IsFinite

--- Clamps a value to 0..100 and rounds it, or answers nil for an unreadable one.
local function percent(value)
	if not finite(value) then return nil end
	return math.floor(OPX.Math.Clamp(value, 0, 100) + 0.5)
end

-- The same rounding with NO ceiling, for a pool drawn in points rather than in
-- percent. `percent` clamps to 100 because a share cannot exceed one; a health
-- pool whose maximum is 250 very much can, and clamping it here is how the
-- read-out would go on saying 100 after everything else had been fixed.
local function finiteRound(value)
	if not finite(value) then return nil end
	return math.floor(math.max(0, value) + 0.5)
end

--- Sends one channel when its picture changed, forgetting the signature of a
--- send that did not land so the next pass tries again.
local function push(channel, payload, signature, force)
	if not ready then return end
	if not force and drawn[channel] == signature then return end
	drawn[channel] = OPX.UI.Send('overlay', channel, payload) and signature or nil
end

-- ── configuration ────────────────────────────────────────────────────────────

--- The layout the page draws with. `statusAnchor` falls through to whatever the
--- needs module asked for, and only then to the gauge column's own corner, which
--- is the page's own fallback.
local function layout()
	return {
		anchor = Settings.ANCHOR,
		infoAnchor = Settings.INFO_ANCHOR,
		statusAnchor = Settings.STATUS_ANCHOR or stripAnchor,
		statusOffset = Settings.STATUS_OFFSET or stripOffset,
		vehicleAnchor = Settings.VEHICLE_ANCHOR,
		width = Settings.WIDTH,
		segments = Settings.SEGMENTS,
		voiceSegments = Settings.VOICE_SEGMENTS,
	}
end

--- Pushes the layout. Sent again when the needs module moves its strip, and
--- change-gated like everything else, so the usual case is one send per page.
local function drawConfig(force)
	local view = layout()
	push(CHANNEL_CONFIG, view, table.concat({
		tostring(view.anchor), tostring(view.infoAnchor), tostring(view.statusAnchor),
		tostring(view.statusOffset), tostring(view.vehicleAnchor), tostring(view.width),
		tostring(view.segments), tostring(view.voiceSegments),
	}, '\1'), force)
end

-- ── the gauges ───────────────────────────────────────────────────────────────

--- One gauge's percent, or nil when nothing can read it.
-- The live pool wins over the stored need wherever the server reports one: the
-- canonical pool is authoritative, the stored character value is a fallback.
local function sourceOf(name)
	if name == 'health' or name == 'armor' then return live[name] end
	if name == 'stamina' and live.stamina ~= nil then return live.stamina end
	if needs == nil then return nil end
	return percent(needs[name])
end

--- The tone a gauge takes at a value. The page never decides this.
local function toneOf(row, value)
	if row.ALERT == false then return 'neutral' end
	if value <= (Settings.TONE_BAD or 15) then return 'bad' end
	if value <= (Settings.TONE_WARN or 33) then return 'warn' end
	return row.TONE or 'neutral'
end

--- Builds the gauge column, in the configured order.
local function gauges()
	local rows = {}
	local configured = type(Settings.GAUGES) == 'table' and Settings.GAUGES or {}
	for index = 1, #configured do
		local row = configured[index]
		local value = type(row) == 'table' and sourceOf(row.SOURCE) or nil
		if value ~= nil
			and not (row.HIDE_AT_ZERO and value <= 0)
			and not (finite(row.HIDE_ABOVE) and value > row.HIDE_ABOVE) then
			rows[#rows + 1] = {
				id = row.ID,
				icon = row.ICON,
				label = row.LABEL,
				pct = value,
				-- The read-out's number when the source keeps one. Absent for
				-- armour and for every need, which are percentages already, and
				-- the page draws `pct` for those exactly as it always did.
				points = points[row.SOURCE],
				tone = toneOf(row, value),
			}
		end
	end
	return rows
end

--- Pushes the gauge column.
local function drawVitals(force)
	local rows = gauges()
	local marks = {}
	for index = 1, #rows do
		local row = rows[index]
		marks[index] = table.concat({ tostring(row.id), tostring(row.icon), tostring(row.label),
			tostring(row.pct), tostring(row.points), row.tone }, '\1')
	end
	push(CHANNEL_VITALS, { gauges = rows }, table.concat(marks, '\2'), force)
end

-- ── the read-out ─────────────────────────────────────────────────────────────

--- Money types held but not configured, sorted, so a new purse shows up without
--- a config change. Only string keys are kept: `table.sort` over mixed key types
--- raises, and so does `:lower()` on a number.
local function extraMoney(purse, known)
	local extra = nil
	for key in pairs(purse) do
		if type(key) == 'string' and not known[key] then
			extra = extra or {}
			extra[#extra + 1] = key
		end
	end
	if extra ~= nil then table.sort(extra) end
	return extra
end

--- Appends one line per held money type, the configured ones first.
local function moneyLines(data, lines)
	local purse = type(data.money) == 'table' and data.money or {}
	local order = type(Settings.MONEY) == 'table' and Settings.MONEY or {}
	local known = {}
	for index = 1, #order do known[order[index]] = true end

	local extra = extraMoney(purse, known)
	local led = #order
	for index = 1, led + (extra ~= nil and #extra or 0) do
		local key = index <= led and order[index] or extra[index - led]
		local amount = purse[key]
		if finite(amount) and amount ~= 0 then
			-- A caption from the catalogue when it has one; the id itself, as
			-- before, for a purse nobody wrote words for.
			local caption = 'hud.money.' .. key
			lines[#lines + 1] = {
				id = key:lower(),
				label = OPX.Locale.Exists(caption) and caption or key,
				value = OPX.Math.GroupDigits(amount, Settings.MONEY_SEPARATOR),
				tone = 'neutral',
			}
		end
	end
end

--- Appends the job line and the street cred line.
local function identityLines(data, lines)
	local job = data.job
	if Settings.SHOW_JOB ~= false and type(job) == 'table' and job.label ~= nil then
		-- IN THE PLAYER'S LANGUAGE when the catalogue has the job and the grade
		-- (`character.job.<job>`, `character.grade.<job>.<level>`), and the
		-- config's own text otherwise: a French HUD read "Unemployed / Freelancer".
		-- The label travels as a key the page looks up; the value is drawn as it
		-- comes, so it is resolved here.
		local jobKey = 'character.job.' .. tostring(job.name)
		local grade = type(job.grade) == 'table' and job.grade or {}
		local gradeKey = ('character.grade.%s.%s'):format(tostring(job.name), tostring(grade.level))
		lines[#lines + 1] = {
			id = 'job',
			label = OPX.Locale.Exists(jobKey) and jobKey or tostring(job.label),
			value = OPX.Locale.Exists(gradeKey) and locale(gradeKey) or tostring(grade.name or ''),
			tone = job.onDuty == true and 'on' or 'neutral',
		}
	end

	local cred = needs ~= nil and needs.streetCred or nil
	if Settings.SHOW_CRED ~= false and finite(cred) and cred > 0 then
		lines[#lines + 1] = {
			id = 'cred',
			label = 'hud.info.cred',
			value = OPX.Math.GroupDigits(cred, Settings.MONEY_SEPARATOR),
			tone = 'neutral',
		}
	end
end

--- Pushes the money, job and cred read-out. Every value is already written the
--- way it will be drawn.
local function drawInfo(force)
	local character = OPX.Api.Get('character')
	local data = character ~= nil and character.GetPlayerData() or {}
	local lines = {}
	if character ~= nil and character.IsLoggedIn() then
		moneyLines(data, lines)
		identityLines(data, lines)
	end

	local marks = {}
	for index = 1, #lines do
		local line = lines[index]
		marks[index] = table.concat({ line.id, line.label, line.value, line.tone }, '\1')
	end
	push(CHANNEL_INFO, { eyebrow = Settings.INFO_EYEBROW, lines = lines },
		table.concat(marks, '\2'), force)
end

-- ── the chip strip ───────────────────────────────────────────────────────────

--- Pushes the status chips.
-- `remainingMs` is deliberately absent from the signature: a counter ticking
-- down is not a new image, and the page animates it on its own clock.
local function drawStatus(force)
	local marks = { tostring(hiddenChips) }
	for index = 1, #chips do
		local chip = chips[index]
		marks[index + 1] = table.concat({
			tostring(chip.id), tostring(chip.label or ''), tostring(chip.icon or ''),
			tostring(chip.tone or ''), tostring(chip.progress or ''), tostring(chip.totalMs or ''),
		}, '\1')
	end
	push(CHANNEL_STATUS, { chips = chips, hidden = hiddenChips },
		table.concat(marks, '\2'), force)
end

--- Adopts the strip the needs module published, bounded before it reaches the
--- page. The client's local bus is shared with every resource on the host, so
--- anything at all may raise this name.
-- The most chips the strip draws, and the most entries a payload is read for.
local MAX_CHIPS = 12
local MAX_OFFERED = 64

local function onEffects(payload)
	if type(payload) ~= 'table' then return end

	-- BOUNDED, AND REBUILT FIELD BY FIELD. The header above says why and the code
	-- did half of it: a chip needed only a string id, and was then forwarded as
	-- given -- any count, any field, tables where text belongs. One oversized or
	-- malformed strip is a HUD payload the host refuses WHOLE, vitals and all,
	-- and every redraw concatenated a signature over all of it. At most
	-- MAX_CHIPS are kept, the rest are counted into the hidden tally the page
	-- already draws, and only the fields the page reads cross.
	local kept, overflow = {}, 0
	local offered = type(payload.chips) == 'table' and payload.chips or {}
	for index = 1, math.min(#offered, MAX_OFFERED) do
		local chip = offered[index]
		if type(chip) == 'table' and type(chip.id) == 'string' and chip.id ~= '' and #chip.id <= 96 then
			if #kept >= MAX_CHIPS then
				overflow = overflow + 1
			else
				local progress, remaining, total = tonumber(chip.progress),
					tonumber(chip.remainingMs), tonumber(chip.totalMs)
				kept[#kept + 1] = {
					id = chip.id,
					label = OPX.Text.Clean(chip.label, 48),
					icon = type(chip.icon) == 'string' and #chip.icon <= 32 and chip.icon or nil,
					tone = type(chip.tone) == 'string' and #chip.tone <= 16 and chip.tone or nil,
					progress = finite(progress) and OPX.Math.Clamp(progress, 0, 1) or nil,
					remainingMs = finite(remaining) and remaining >= 0 and math.floor(remaining) or nil,
					totalMs = finite(total) and total >= 0 and math.floor(total) or nil,
				}
			end
		end
	end
	chips = kept

	local hidden = tonumber(payload.hidden)
	hiddenChips = finite(hidden) and math.floor(OPX.Math.Clamp(hidden, 0, 999)) or 0
	hiddenChips = math.min(999, hiddenChips + overflow)

	local anchor = type(payload.anchor) == 'string' and #payload.anchor <= 32
		and payload.anchor or nil
	local offset = tonumber(payload.offset)
	offset = finite(offset) and offset >= 0 and offset <= SURFACE_HEIGHT
		and math.floor(offset) or nil
	if anchor ~= stripAnchor or offset ~= stripOffset then
		stripAnchor, stripOffset = anchor, offset
		drawConfig()
	end

	drawStatus()
end

-- ── the live pools ───────────────────────────────────────────────────────────

--- The first of two values that is a finite number, or nil.
local function firstFinite(first, second)
	if finite(first) then return first end
	if finite(second) then return second end
	return nil
end

--- A pool as a percent of its maximum: a pool table, or a flat value beside its
--- maximum. The client documents pool tables and the server flat numbers, so
--- either shape is read.
local function share(pool, flatMaximum)
	local value, maximum
	if type(pool) == 'table' then
		value = firstFinite(pool.value, pool.current)
		maximum = firstFinite(pool.maximum, pool.max)
		if value == nil and finite(pool.fraction) then
			return math.max(0, pool.fraction) * 100
		end
	elseif finite(pool) then
		value, maximum = pool, flatMaximum
	end
	if value == nil then return nil end
	if not finite(maximum) or maximum <= 0 then maximum = 100 end
	return math.max(0, value) / maximum * 100
end

--- Reads the engine's pools once. Keeps the last reading through an answer that
--- simply did not arrive, and clears it when the bridge says there is none.
---
--- ANSWERS WHETHER THE READING MOVED, because the caller at 30 Hz has no other
--- way to know. An unchanged pool means an unchanged gauge column, and building
--- one to discover that is the cost this return exists to let the caller skip.
--- A read that simply did not arrive answers false: the held reading is still the
--- one the page is showing.
-- @return boolean
local function sampleVitals()
	local stats = Open77.stats
	if type(stats) ~= 'table' or type(stats.get) ~= 'function' then
		local moved = live.health ~= nil or live.armor ~= nil or live.stamina ~= nil
		live = {}
		if not statsReported then
			statsReported = true
			Open77.log.warn('[hud] live pools unreadable: health falls back to the stored character')
		end
		return moved
	end

	local read, state = pcall(stats.get)
	if not read or type(state) ~= 'table' then return false end

	-- ONE POOL, AND IT IS THE SERVER'S. There was a second reading here: the local
	-- body's health, off `Open77.character.state`, on the grounds that damage the
	-- server never hears of -- a fall, an npc -- only ever lowers the body, so the
	-- body should win. It was measured against the CANONICAL maximum, and the two
	-- are not on the same scale.
	--
	-- Nobody could see that while the maximum was 100, because 100 and 100 divide
	-- the same. Raising it to 250 separated them and the bar stuck at 40% -- the
	-- owner read that as a heal that had stopped healing, and the staff menu was
	-- innocent: the audit line said `admin.self.heal … "250"` and the server had
	-- applied it. The reading that settled it is in the journal verbatim:
	--
	--   vitals: engine body 100.0, canonical 250.0 of 250.0, drawn 40%
	--
	-- Full health, reported as two fifths of it. The engine body carries no
	-- maximum of its own in that record -- `Open77.character.state` answers
	-- placement, orientation and health, nothing to divide by -- so there is no
	-- honest way to put it on the same axis as a canonical pool, and no need:
	-- `player-stats` opens with "Open77 owns player health and stamina on the
	-- dedicated server". The pool IS the truth, fall damage included. The second
	-- opinion was never worth having and is gone.
	local health = share(state.health, state.maxHealth)

	-- Compared AFTER `percent`, not before: the gauges draw whole percents, so a
	-- pool that moved by a hundredth of a point did not move anything the player
	-- can see, and a raw comparison would report a change on almost every pass.
	local nowHealth = percent(health)
	local nowArmor = percent(finite(state.armor) and math.max(0, state.armor) or 0)
	local nowStamina = percent(share(state.stamina, state.maxStamina))
	-- THE POINTS AS WELL AS THE SHARE, because a percent stopped being an answer
	-- the moment the maximum stopped being 100.
	--
	-- THE OWNER, on a full player: "le hud affiche 100 enfois de 250 dans vie".
	-- The gauge was drawing 100 and it was right -- a hundred percent of a full
	-- pool -- and it was also useless. While `HEALTH.MAX` was 100 the percent and
	-- the points were the same number, so the read-out could be either and nobody
	-- had to decide which it was; at 250 they part, and the one a player wants is
	-- the one their maximum is written in. The BAR keeps the share, because a bar
	-- is a share; the read-out gets the points.
	--
	-- Armour has no pool of its own here -- `state.armor` arrives already a
	-- percent -- and the needs are percentages by definition, so those keep the
	-- number they always had. A source with no points is simply not given any,
	-- and the page falls back to what it drew before.
	local pool = type(state.health) == 'table' and state.health or nil
	local nowPoints = pool and finiteRound(firstFinite(pool.value, pool.current))
		or finiteRound(state.health)
	local staminaPool = type(state.stamina) == 'table' and state.stamina or nil
	local nowStaminaPoints = staminaPool
		and finiteRound(firstFinite(staminaPool.value, staminaPool.current)) or nil

	local moved = nowHealth ~= live.health
		or nowArmor ~= live.armor
		or nowStamina ~= live.stamina
		or nowPoints ~= points.health
		or nowStaminaPoints ~= points.stamina

	live = { health = nowHealth, armor = nowArmor, stamina = nowStamina }
	points = { health = nowPoints, stamina = nowStaminaPoints }
	return moved
end

-- ── the microphone ───────────────────────────────────────────────────────────

--- A short key name in capitals, or nil.
local function keyName(value)
	if type(value) ~= 'string' or value == '' or #value > MAX_KEY
		or value:find('[%s%c]') then
		return nil
	end
	return value:upper()
end

--- Adopts one reach mode as open-voice reported it.
local function setReach(name, distance, label)
	if type(name) ~= 'string' or name == '' or #name > 24 then return end
	reach = {
		name = name:lower(),
		label = type(label) == 'string' and label:sub(1, 32) or nil,
		distance = finite(distance) and distance > 0 and distance or nil,
	}
end

--- Keeps the reach mode names of an open-voice `getModes` answer, in order.
local function adoptModes(list)
	local names = {}
	for index = 1, math.min(#list, MAX_MODES) do
		local mode = list[index]
		if type(mode) ~= 'table' or type(mode.name) ~= 'string' then return end
		names[index] = mode.name:lower()
	end
	modes = names
end

--- The configured voice settings, or nil when the block is switched off.
local function voiceSettings()
	return type(Settings.VOICE) == 'table' and Settings.VOICE or nil
end

--- Reads the reach mode, its cycle and the push-to-talk key once. Yields on the
--- remote's promise, so it only runs inside a thread.
local function pullVoice()
	local voice = voiceSettings()
	if voice == nil then return end

	local state = OPX.Lib.Rpc.Call(voice.OPEN_VOICE, 'getState')
	if state.ok and state.value.configured == true then
		setReach(state.value.mode, state.value.distance, state.value.label)
		cycleKey = keyName(state.value.cycleKey)
	end

	local list = OPX.Lib.Rpc.Call(voice.OPEN_VOICE, 'getModes')
	if list.ok and type(list.value.modes) == 'table' then adoptModes(list.value.modes) end

	local driver = OPX.Lib.Rpc.Call(voice.DRIVER, 'getPushToTalkKey')
	local key = driver.ok and keyName(driver.value.key) or nil
	if key ~= nil then pushToTalkKey = key end
end

--- Shows or hides open-voice's own line, which this block stands in for.
local function setOpenVoiceHud(shown)
	local voice = voiceSettings()
	if voice == nil or voice.HIDE_OPEN_VOICE == false then return end
	-- Both doors, because the resource has answered on either depending on its
	-- build, and neither is a dependency.
	pcall(TriggerEvent, VOICE_HUD_VISIBLE, shown == true)
	local exports = Open77.exports
	if type(exports) ~= 'table' or type(exports.call) ~= 'function' then return end
	if not OPX.Lib.Rpc.IsRunning(voice.OPEN_VOICE) then return end
	pcall(exports.call, voice.OPEN_VOICE, 'setHudVisible', shown == true)
end

--- Formats a reach in metres: one decimal under ten when fractional, whole
--- otherwise.
local function formatDistance(metres)
	if metres < 10 and metres ~= math.floor(metres) then return ('%.1f'):format(metres) end
	return tostring(math.floor(metres + 0.5))
end

--- The catalogue key for the current reach mode, or open-voice's own label.
-- A key when there is one and a literal otherwise: the page resolves what it
-- gets and renders the rest verbatim.
local function modeLabel()
	if reach.name == nil then return 'hud.voice.mode.proximity' end
	local key = 'hud.voice.mode.' .. reach.name
	if OPX.Locale.Exists(key) then return key end
	return reach.label or reach.name:upper()
end

--- The indicator state a native voice status reads as, and its input level.
local function stateOf(status)
	if status == nil then return 'offline', 0 end
	local level = status.inputLevel
	if not finite(level) then level = status.microphoneActivity end
	if not finite(level) or level < 0 then level = 0 end
	if level > 1 then level = 1 end
	if status.available ~= true then return 'offline', 0 end
	if status.captureEnabled ~= true then return 'muted', 0 end
	if status.transmitting == true then return 'talking', level end
	if status.localTalking == true or level > DETECT_LEVEL then return 'detected', level end
	return 'idle', level
end

--- The microphone block, or nil when this client has no voice bridge.
local function voiceView()
	if voiceSettings() == nil then return nil end
	local api = Open77.voice
	if type(api) ~= 'table' or type(api.status) ~= 'function' then return nil end
	local read, status = pcall(api.status)
	if not read or type(status) ~= 'table' then status = nil end

	local state, level = stateOf(status)

	local metres = reach.distance
	if metres == nil and status ~= nil then
		if finite(status.proximityDistance) and status.proximityDistance > 0 then
			metres = status.proximityDistance
		elseif finite(status.defaultProximityDistance)
			and status.defaultProximityDistance > 0 then
			metres = status.defaultProximityDistance
		end
	end

	local index = 0
	if reach.name ~= nil then
		for position = 1, #modes do
			if modes[position] == reach.name then index = position end
		end
	end

	-- The activation cap says how you talk, not what you press: an open mic has
	-- a word there and not a key, so it is resolved here rather than sent as a
	-- key the page would draw raw.
	local activation = pushToTalkKey
	if status ~= nil and status.voiceActivation == true then
		activation = locale('hud.voice.open')
	end

	local heard = 0
	if status ~= nil and finite(status.activeTalkers) and status.activeTalkers > 0 then
		heard = math.min(99, math.floor(status.activeTalkers))
	end

	return {
		active = true,
		state = state,
		-- RENDERED HERE, NOT ON THE PAGE. These two used to travel as catalogue
		-- keys for the page's `t()` to resolve, and they reached players as the
		-- raw keys -- `hud.voice.state.idle` written across the microphone block.
		-- Every other label in this file already renders through `locale()`
		-- (`activation` and `distance` below, `unit` in the vehicle block), which
		-- is why those were the only two that ever showed wrong.
		--
		-- `t()` on the page returns its argument unchanged when it is not a
		-- catalogue key, so rendered text passes straight through it and the page
		-- needs no change. `modeLabel` may itself answer open-voice's own literal
		-- rather than a key, and `locale()` returns a miss unchanged too, so that
		-- case survives the wrapping.
		caption = locale('hud.voice.state.' .. state),
		mode = locale(modeLabel()),
		-- Drawn verbatim, so it is a formatted sentence and not a key.
		distance = metres ~= nil
			and locale('hud.voice.distance', { metres = formatDistance(metres) }) or '',
		level = math.floor(level * 100 + 0.5),
		count = index > 0 and #modes or 0,
		index = index,
		key = cycleKey or '',
		activation = activation or '',
		heard = heard,
	}
end

-- ── the vehicle dial ─────────────────────────────────────────────────────────

--- R, N or the forward gear number a snapshot reports.
local function gearLabel(vehicle)
	local gear = finite(vehicle.gear) and math.floor(vehicle.gear) or 0
	if vehicle.reversing == true or gear < 0 then return 'R' end
	if gear == 0 then return 'N' end
	return tostring(gear)
end

--- The read-out for the vehicle the character sits in, or nil when on foot.
-- `rpm` and `integrity` are ABSENT rather than zero when the vehicle does not
-- report them: 0 is a real reading, an unreported integrity is not, and an empty
-- integrity ring is a thing a player brakes for.
local function vehicleView()
	local configured = type(Settings.VEHICLE) == 'table' and Settings.VEHICLE or nil
	if configured == nil then return nil end

	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.getPlayerSeat) ~= 'function'
		or type(vehicles.get) ~= 'function' then
		return nil
	end

	local seated, seat = pcall(vehicles.getPlayerSeat)
	if not seated or type(seat) ~= 'table' or seat.vehicleId == nil then return nil end
	local driving = seat.seat == nil or tostring(seat.seat) == DRIVER_SEAT
	if not driving and configured.PASSENGER == false then return nil end

	local read, vehicle = pcall(vehicles.get, seat.vehicleId)
	if not read or type(vehicle) ~= 'table' then return nil end

	local speed = finite(vehicle.speed) and math.abs(vehicle.speed) * KPH or 0
	speed = math.min(MAX_KPH, math.floor(speed + 0.5))

	local view = {
		active = true,
		speed = speed,
		unit = locale('hud.vehicle.unit'),
		gear = gearLabel(vehicle),
		-- Rendered here for the same reason as the two in the voice block above:
		-- sent as a key it reached the player as `hud.vehicle.integrity`.
		integrityLabel = locale('hud.vehicle.integrity'),
		tone = 'neutral',
		airborne = vehicle.onGround == false,
		airborneLabel = locale('hud.vehicle.airborne'),
	}

	if finite(vehicle.rpm) and finite(vehicle.rpmMax) and vehicle.rpmMax > 1 then
		view.rpm = percent(vehicle.rpm / vehicle.rpmMax * 100)
	end
	if finite(vehicle.health) then
		view.integrity = percent(vehicle.health * 100)
		if view.integrity <= (Settings.TONE_BAD or 15) then
			view.tone = 'bad'
		elseif view.integrity <= (Settings.TONE_WARN or 33) then
			view.tone = 'warn'
		end
	end

	-- THE TANK, read off the vehicle's `fuel` bag field through the fuel module
	-- (ox's `Entity(vehicle).state.fuel`). ABSENT, not 0, for a car nobody has
	-- filled or a server without the module: an empty gauge is a thing a player
	-- pulls over for.
	if configured.FUEL ~= false then
		local fuel = OPX.Api.Get('fuel')
		local read, level = false, nil
		if fuel ~= nil and type(fuel.Percent) == 'function' then
			read, level = pcall(fuel.Percent, seat.vehicleId)
		end
		if read and finite(level) then
			view.fuel = percent(level)
			view.fuelLabel = locale('hud.vehicle.fuel')
			view.fuelTone = view.fuel <= (Settings.TONE_BAD or 15) and 'bad'
				or view.fuel <= (Settings.TONE_WARN or 33) and 'warn' or 'neutral'
		end
	end

	return view
end

--- Sends one of the two blocks that switch themselves off. A nil view is not an
--- empty payload: the page fades the block out on `active` and keeps its caption
--- so that it does not go blank on the way out.
local function drawBlock(channel, view, marks, force)
	if view == nil then
		push(channel, { active = false }, '\0', force)
		return
	end
	push(channel, view, table.concat(marks, '\1'), force)
end

--- Samples and pushes the microphone and the vehicle dial.
local function drawWidgets(force)
	local voice = visible and not down and voiceView() or nil
	drawBlock(CHANNEL_VOICE, voice, voice ~= nil and {
		voice.state, voice.caption, tostring(voice.level), voice.mode, voice.distance,
		tostring(voice.index), tostring(voice.count), voice.key, voice.activation,
		tostring(voice.heard),
	} or nil, force)

	local vehicle = visible and not down and vehicleView() or nil
	drawBlock(CHANNEL_VEHICLE, vehicle, vehicle ~= nil and {
		tostring(vehicle.speed), vehicle.gear, tostring(vehicle.rpm or ''),
		tostring(vehicle.integrity or ''), vehicle.tone, vehicle.airborne and '1' or '0',
		tostring(vehicle.fuel or ''), vehicle.fuelTone or '',
	} or nil, force)
end

-- ── the game's own HUD ───────────────────────────────────────────────────────

--- The host HUD bridge when it can set visibility, else nil.
local function vanillaApi()
	local hud = Open77.hud
	if type(hud) ~= 'table' or type(hud.setVisible) ~= 'function' then return nil end
	return hud
end

--- The component names this client reports, or nil.
-- An empty answer is not the claim that there are no components: it is an answer
-- that did not arrive, and nothing is validated against it.
local function vanillaKnown(hud)
	if type(hud.components) ~= 'function' then return nil end
	local read, list = pcall(hud.components)
	if not read or type(list) ~= 'table' then return nil end
	local set = {}
	for index = 1, #list do
		if type(list[index]) == 'string' then set[list[index]] = true end
	end
	if next(set) == nil then return nil end
	return set
end

--- Hides the components this HUD replaces, recording their prior visibility once.
-- Nothing is put back on stop: `setVisible(component, false)` posts a hide
-- request in this resource's name, and the platform drops every request a
-- resource holds when it stops or reloads. Restoring by hand would re-post a
-- hide for a component another resource is already hiding.
local function applyVanilla()
	local wanted = Settings.VANILLA
	if type(wanted) ~= 'table' then return 0 end

	local hud = vanillaApi()
	if hud == nil then return 0 end

	local known = vanillaKnown(hud)
	local first = vanillaFound == nil
	if first then vanillaFound = {} end

	-- EVERY COMPONENT THE BUILD KNOWS, NOT ONLY THE ONES NAMED. The owner: "regarde
	-- si ont hide bien tous ... sauf la minimap". A component the config does not
	-- name is HIDDEN, so one the platform adds later is covered on the day it
	-- ships instead of appearing over our HUD until somebody lists it. Without the
	-- build's own list, the named ones are all there is to go on.
	local plan = {}
	for component in pairs(known or {}) do plan[component] = false end
	for component, shown in pairs(wanted) do
		if type(component) == 'string' and type(shown) == 'boolean'
			and (known == nil or known[component]) then
			plan[component] = shown
		end
	end

	local applied = 0
	for component, shown in pairs(plan) do
		if first and type(hud.isVisible) == 'function' then
			local read, was = pcall(hud.isVisible, component)
			vanillaFound[component] = read and was or nil
		end
		-- THE ANSWER IS READ. `setVisible` answers `false, reason` rather than
		-- raising, and `pcall` alone counted every refusal as applied.
		local called, ok, why = pcall(hud.setVisible, component, shown)
		if called and ok == true then
			applied = applied + 1
		elseif not vanillaRefused[component] then
			vanillaRefused[component] = true
			OPX.Note('hud', ('the vanilla %s could not be %s: %s'):format(component,
				shown and 'shown' or 'hidden', tostring(called and why or ok)))
		end
	end
	return applied
end

-- ── visibility ───────────────────────────────────────────────────────────────

--- Pushes the whole-surface switch and forces every block to re-send.
-- Forced on purpose: neither the player's choice nor the down state is part of
-- any block's signature, so an otherwise identical frame would be skipped and
-- the page would come back holding the picture it had before the player went
-- down.
--
-- THE SWITCH AT ONCE, THE BLOCKS ONE A RESUME. Re-sending every block -- the
-- gauges, the money (sorted and grouped), the effect strip and the widgets with
-- their host reads and catalogue lines -- ran inside whichever handler asked:
-- the page reporting ready, the player going down or coming back, a surface
-- covering the HUD. The switch is still pushed in that resume, so the HUD shows
-- or hides on the frame it was asked to; the four re-sends follow on a thread of
-- their own, one a frame, and a newer redraw abandons an older one.
local showGeneration = 0

local function drawShow(force)
	local shown = visible and not down and not covered
	push(CHANNEL_SHOW, { visible = shown }, shown and '1' or '0', force)
	local blocks = shown and { drawVitals, drawInfo, drawStatus, drawWidgets } or { drawWidgets }
	showGeneration = showGeneration + 1
	if type(CreateThread) ~= 'function' then
		for index = 1, #blocks do blocks[index](true) end
		return
	end
	local mine = showGeneration
	CreateThread(function()
		for index = 1, #blocks do
			if index > 1 then Wait(0) end
			if showGeneration ~= mine then return end
			blocks[index](true)
		end
	end)
end

--- Shows or hides the HUD. Any value but `false` shows, which is the contract
--- players inherit through the page.
local function setVisible(value)
	local wanted = value ~= false
	if visible ~= wanted then
		visible = wanted
		drawShow()
		TriggerEvent(EVENT_VISIBILITY, { visible = visible, down = down, covered = covered })
	end
	return Result.Ok({ visible = visible, down = down, covered = covered })
end

--- Takes the surface off screen while the player is down, and back after. The
--- player's own choice is never touched.
local function setDown(value)
	local wanted = value == true
	if down == wanted then return end
	down = wanted
	drawShow()
end

--- Records that a named screen has the display, or has given it back.
-- The player's own choice is never touched, exactly as `setDown` does not touch
-- it: what the player asked for is restored the moment the last screen closes.
local function setCovered(owner, value)
	local wanted = value == true or nil
	if owners[owner] == wanted then return end
	owners[owner] = wanted
	local anybody = next(owners) ~= nil
	if covered == anybody then return end
	covered = anybody
	drawShow()
	-- On the public bus as well, because `hud:visibility` is what a listener
	-- reads to know whether the HUD is on screen, and a HUD hidden behind the
	-- creator is as hidden as one the player switched off.
	TriggerEvent(EVENT_VISIBILITY, { visible = visible, down = down, covered = covered })
end

-- ── the contract ─────────────────────────────────────────────────────────────

--- Whether the HUD is chosen shown, and whether the player is down.
-- @author dop42
-- @return Result
local function isVisible()
	return Result.Ok({ visible = visible, down = down, covered = covered })
end

--- What became of the game's own HUD. Read-only, and deliberately without a
--- setter: this module hides those components because it draws their
--- replacement, and a second opinion from elsewhere is how a player ends up with
--- no HUD at all.
-- @author dop42
-- @return Result
local function vanilla()
	local hud = vanillaApi()
	local state = nil
	if hud ~= nil and type(hud.state) == 'function' then
		local read, value = pcall(hud.state)
		if read and type(value) == 'table' then state = value end
	end
	return Result.Ok({ available = hud ~= nil, found = vanillaFound, state = state })
end

-- ── the sources ──────────────────────────────────────────────────────────────

--- Adopts published needs. They are cleared rather than kept when the module
--- says it is not ready: a stale hunger bar is a thing a player acts on.
local function setNeeds(values, isReady)
	needs = isReady == true and type(values) == 'table' and values or nil
end

--- Reads the needs once, for a character loaded before this module started.
local function pullNeeds()
	local api = OPX.Api.Get('needs')
	if api == nil then return end
	local answer = api.GetNeeds()
	if not answer.ok then
		setNeeds(nil, false)
		return
	end
	setNeeds(answer.value.values, answer.value.ready)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the held state. Never yields and reaches no other module.
-- @author dop42
function M.Init()
	visible = true
	down = false
	owners, covered = {}, false
	live = {}
	needs = nil
	chips = {}
	hiddenChips = 0
	stripAnchor, stripOffset = nil, nil
	drawn = {}
	ready = false
	vanillaFound = nil
	reach, modes, cycleKey, pushToTalkKey = {}, {}, nil, nil
	statsReported = false
end

--- Publishes the visibility switch and the read-only vanilla report.
-- @author dop42
function M.Api()
	OPX.Api.Provide('hud', 1, {
		IsVisible = isVisible,
		SetVisible = setVisible,
		Vanilla = vanilla,
		-- Puts this HUD's vanilla claims back. For `downed`, whose release on
		-- revive clears them: claims belong to the RESOURCE, and this runtime is
		-- one resource, so `setVisible(c, true)` there released ours too.
		ApplyVanilla = applyVanilla,
	})
end

--- Wires the page, the three sources and the two sampling loops.
-- @author dop42
function M.Start()
	local downHeard = 0

	OPX.UI.On('overlay', CHANNEL_READY, function()
		-- The page's DOM is new, so every signature this module holds describes
		-- something that no longer exists.
		ready = true
		drawn = {}
		drawConfig(true)
		sampleVitals()
		drawShow(true)
	end)

	AddEventHandler(EVENT_CHARACTER_LOADED, function()
		sampleVitals()
		drawVitals()
		drawInfo()
		-- The game brings its own HUD back at incarnation, which happens after
		-- this module started. Up to thirteen components, two host calls each and
		-- a note per refusal: on a resume of its own, not the event's.
		if type(CreateThread) == 'function' then CreateThread(applyVanilla) else applyVanilla() end
	end)
	AddEventHandler(EVENT_CHARACTER_UNLOADED, function()
		live = {}
		setNeeds(nil, false)
		drawVitals()
		drawInfo()
	end)
	AddEventHandler(EVENT_CHARACTER_CHANGED, drawInfo)
	AddEventHandler(EVENT_CHARACTER_MONEY, drawInfo)
	AddEventHandler(EVENT_CHARACTER_JOB, drawInfo)

	AddEventHandler(EVENT_NEEDS_CHANGED, function(payload)
		if type(payload) ~= 'table' then return end
		setNeeds(payload.values, payload.ready)
		drawVitals()
		drawInfo()
	end)
	AddEventHandler(EVENT_NEEDS_EFFECTS, onEffects)

	AddEventHandler(EVENT_DOWNED_CHANGED, function(payload)
		if type(payload) ~= 'table' then return end
		downHeard = downHeard + 1
		setDown(payload.down == true)
		-- THE STOCK HUD THIS ONE REPLACES GOES BACK UNDER, AFTER EVERY DOWN. A hide
		-- is a claim held in the RESOURCE's name, and `modules/downed` is the same
		-- resource: standing a player up, it gives back the thirteen components it
		-- hid -- which erases this module's claims on the seven it hides for good
		-- (`HudComponents.hpp`: `SetVisible(owner, c, true)` releases that owner's
		-- claim). The stock health, stamina, ammo, compass, clock and speedometer
		-- then sat over this HUD, and the vanilla hub menu opened, until the next
		-- character load. The downed module raises this event after its release,
		-- so re-applying here is the last word.
		if payload.down ~= true then applyVanilla() end
	end)

	AddEventHandler(EVENT_ENTRY_STATE, function(payload)
		if type(payload) ~= 'table' then return end
		setCovered('entry', payload.open == true)
	end)

	AddEventHandler(EVENT_SPAWN_STATE, function(payload)
		if type(payload) ~= 'table' then return end
		setCovered('spawn', payload.open == true)
	end)

	-- A MENU IS A SCREEN THE PLAYER IS READING, so the HUD stands aside for it
	-- exactly as it does for the join and the fitting room. "quand le menu est
	-- ouvert hide la" -- and the reason is the corner: the vanilla minimap came
	-- back with the blips work, the money block moved to the left to get out of
	-- its way, and a menu opening over it is one more thing in a corner that now
	-- has two already.
	--
	-- The fourth name in a set, not a fourth mechanism: `setCovered` restores
	-- whatever the player themselves chose the moment the last screen closes.
	AddEventHandler(EVENT_MENU_STATE, function(payload)
		if type(payload) ~= 'table' then return end
		setCovered('menu', payload.open == true)
	end)

	-- A load is a screen in front of the HUD for exactly as long as the platform
	-- says it is up. The player's own choice is untouched, as for every other
	-- name in the set, so whatever they had comes back when it ends.
	AddEventHandler(EVENT_LOADING_STATE, function(payload)
		if type(payload) ~= 'table' then return end
		setCovered('loading', payload.active == true)
	end)

	-- A room that is DRAWN. `entry` already covers one that is merely owed, and
	-- the two overlap on purpose: the join holds the cover across the gap between
	-- the offer and the room, and this holds it for a room `entry` never heard of
	-- because the player opened it from the appearance panel.
	AddEventHandler(EVENT_APPEARANCE_DECISION, function(payload)
		if type(payload) ~= 'table' then return end
		if payload.event == 'wardrobeOpened' then
			-- `ok = false` is a room that was refused, which is not a room.
			return setCovered('wardrobe', payload.ok == true)
		end
		if payload.event == 'wardrobeClosed' then return setCovered('wardrobe', false) end
	end)

	-- The engine reports a pool moving, so the change is drawn now rather than
	-- at the next sample.
	AddEventHandler(HOST_STATS_CHANGED, function()
		sampleVitals()
		drawVitals()
	end)

	AddEventHandler(VOICE_MODE_CHANGED, function(mode, distance, label)
		setReach(mode, distance, label)
	end)
	AddEventHandler(VOICE_KEY_CHANGED, function(key)
		local name = keyName(key)
		if name ~= nil then pushToTalkKey = name end
	end)

	applyVanilla()
	pullNeeds()

	-- The down state once, for a HUD started while the player is already down. A
	-- state event that landed while the contract was being read is newer than
	-- the answer, and wins.
	local downed = OPX.Api.Get('downed')
	if downed ~= nil then
		local heard = downHeard
		local answer = downed.IsDown()
		if answer.ok and downHeard == heard then setDown(answer.value.down == true) end
	end

	-- One-shot: both reads yield on a remote promise, which the scheduler's
	-- passes may not do.
	CreateThread(function()
		setOpenVoiceHud(false)
		pullVoice()
		drawWidgets()
	end)

	OPX.Scheduler.Every('hud.vitals', Settings.VITALS_MS or 33, function()
		if not ready or not visible or down or covered then return end
		-- THE SAMPLE STAYS AT THE SURFACE'S RATE AND THE DRAW DOES NOT. The two
		-- host reads are the poll and the poll is load-bearing: the body wins
		-- over the canonical pool precisely for damage the server never hears of
		-- -- a fall, an npc -- which reaches this module through no event at all,
		-- so the `open77:playerStatsChanged` handler above is a shortcut to
		-- drawing sooner and never a replacement for this.
		--
		-- The DRAW is the part that was recomputing an unchanged answer.
		-- `gauges()` is a pure function of the live pools, the stored needs and
		-- the configuration. Needs arrive on their own event and redraw from
		-- there; the configuration does not move at runtime. So the pools are the
		-- only input this pass owns, and a pass whose pools did not move was
		-- building a row table, five `tostring`s and a concat per row and one
		-- more over the lot, purely to compare equal and throw it away -- thirty
		-- times a second, for the whole session.
		--
		-- `drawn[CHANNEL_VITALS] == nil` IS THE RETRY, and it is why this gate
		-- cannot strand the page: `push` forgets the signature of a send that did
		-- not land, and the ready handler clears every signature it holds, so an
		-- undrawn channel is redrawn on the next pass whether the pools moved or
		-- not.
		if sampleVitals() or drawn[CHANNEL_VITALS] == nil then drawVitals() end
	end)

	OPX.Scheduler.Every('hud.widgets', Settings.WIDGET_MS or 100, function()
		-- `covered` BELONGS HERE TOO, and its absence was the whole of this cost.
		-- The vitals job two lines up steps aside for a full-screen view; this one
		-- gated on `ready` alone, so while a join screen or the inventory held the
		-- display `voiceView()` and `vehicleView()` -- four host reads and seven
		-- locale lookups between them -- kept running ten times a second to build
		-- payloads for widgets the page has hidden.
		if not ready or covered then return end
		drawWidgets()
	end)
end

--- Gives open-voice its own line back and blanks the surface.
-- The vanilla components are not restored: the platform drops this resource's
-- hide requests when it stops, and re-posting one for a component another
-- resource hides would outlive us.
-- @author dop42
function M.Stop()
	setOpenVoiceHud(true)
	ready = false
	drawn = {}
	OPX.UI.Send('overlay', CHANNEL_SHOW, { visible = false })
end
