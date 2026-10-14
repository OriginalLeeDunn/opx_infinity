--- Puts the character's stored clothing on its puppet, and saves what changes.
-- @author dop42
--
-- The order is the whole design.
--   1. It WAITS FOR THE FACE. Nothing goes on before this world entry's face has
--      settled and gameplay-ready has gone out, never while a modal, a face commit
--      or a body reload is in the way, and never on a puppet a face could not go on
--      either. The announcement does NOT wait for clothing: the platform's own
--      presentation service answers that same announcement with its records.
--   2. It PUTS THE RECORD ON: every outfit replaced, the active one chosen, then
--      the nine slots stated.
--   3. It READS IT BACK, because the registry and the wardrobe have to show what
--      was put on before anything may be saved from them.
--   4. It SAVES CHANGES, and only ones that have held.
--
-- `PlayerData.clothing` is a record, `false` for 'none stored yet', or nil for
-- 'the server could not say'. Nil dresses nothing and saves nothing: writing now
-- would replace a record nobody was ever shown.
--
-- STEP 1's GATE IS BOUNDED, and that is not a detail. Everything below it is
-- reached only through a put-on, so a gate that never opens produces no attempt,
-- no read-back, no failure and no decision -- nothing happens and nothing says
-- so, on a client whose log the operator cannot read anyway. That silence held
-- the join-time fitting room open on a decision that could never arrive. `shut`
-- names the clause, and `stalled` reports it and then settles the world entry.

local M = OPX.Modules.Get('appearance')

local State = M.Face
local Runtime = M.Runtime

M.Clothing = {}
local Clothing = M.Clothing

-- Put-ons before a world entry gives up on the record, and how long one may take
-- to read back before the next.
local RESTORE_ATTEMPTS = 5
local VERIFY_MS = 2000

-- How long the gate of step 1 may be shut before the operator is told which
-- clause is holding it, and before this world entry gives up on dressing at all.
--
-- BOTH NUMBERS EXIST BECAUSE THE WAIT USED TO BE UNBOUNDED, and an unbounded
-- wait here is not just clothes that never go on. Nothing publishes
-- `clothingRestored` until a put-on has been read back, so a gate that never
-- opens is also a fitting room offer that never comes, a `Settled` that only
-- ever times out, and a `Report` of 'waiting' that nobody reads -- all of it
-- with no line anywhere, because a put-on that never happened cannot fail.
--
-- The report comes first and by a wide margin, because the ordinary case is a
-- gate shut for a second or two while the face settles and a native modal comes
-- down. The give-up is under `WARDROBE.CREATION_WAIT_MS` (60s shipped) on
-- purpose: the join asks for a fitting room and waits that long for one, and a
-- decision that arrived after the room had given up would be a decision nobody
-- was left to act on.
--
-- BOTH ARE COUNTED FROM THE GATE, NOT FROM THE JOIN. See `HELD`: the clock
-- restarts while a screen the player is standing in front of is up, so the two
-- numbers keep the same relation to `CREATION_WAIT_MS` -- both are measured from
-- the first moment the clothes could have gone on -- and neither is spent on a
-- creation, which is where they used to go.
local GATE_REPORT_MS = 12000
local GATE_GIVEUP_MS = 40000

-- The clauses of `shut` that are a SCREEN THE PLAYER IS STANDING IN FRONT OF,
-- and against which neither number above may be counted.
--
-- No value of GATE_GIVEUP_MS is right for these. A creation is human-paced and
-- has no deadline anywhere in this module on purpose -- `awaitWorld` says so in
-- as many words, "a player building a face for an hour is a correct state" --
-- so a fixed budget measured from the character arriving is a budget that
-- expires mid-creation and then reports the player's own deliberation as a
-- fault. Measured on 2026-09-20: creator up at 14:46:47, the face stored at
-- 14:47:57, and this gate gave up at 14:47:27 -- thirty seconds before the
-- creation it was waiting for had ended.
--
-- THE SAFETY NET IS NOT WEAKENED, IT IS AIMED. The forty seconds exist so a
-- character is not held undressed and unplaced for a session by a gate nothing
-- is doing anything about; a modal on screen is the opposite of that, and every
-- one of these clauses ends in something bounded elsewhere -- the creator by
-- `CREATOR_UNSEEN_MS`, a commit by its own deadline, an edit by the player
-- closing it. So the clock is RESTARTED while one of them holds, and the full
-- forty seconds are then available from the moment the screen comes down, which
-- is the first moment the clothes could have gone on at all.
local HELD = {
	editing = true,
	creating = true,
	creator_up = true,
	committing = true,
}

-- Longest the published look waits for the clothes, so the player is not drawn in
-- the pristine puppet's clothes first.
local PRESENCE_HOLD_MS = 15000

-- Failed saves in a row before this character stops saving.
local STRIKES = 2

-- Shipped CLOTHING.SAVE_DEBOUNCE_MS, for a configuration that lost it.
local SAVE_DEBOUNCE_MS = 2000

-- Wardrobe outfits, indexed 0 to 6 as the platform indexes them.
local OUTFITS = 7

--- The nine equipment slots of a record and of a look.
M.Clothing.SLOTS = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit',
	'UnderwearTop', 'UnderwearBottom' }
local SLOTS = Clothing.SLOTS

--- The seven visible slots an outfit overrides.
M.Clothing.OUTFIT_SLOTS = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit' }
local OUTFIT_SLOTS = Clothing.OUTFIT_SLOTS

--- The record the platform states for a character without one. Never written.
M.Clothing.DEFAULT = {
	schemaVersion = 1,
	equipment = { Head = false, Face = false, InnerChest = false, OuterChest = false,
		Legs = false, Feet = false, Outfit = false, UnderwearTop = false,
		UnderwearBottom = 'Items.Underwear_Basic_01_Bottom' },
	wardrobe = { outfits = {} },
}
local DEFAULT = Clothing.DEFAULT

-- The character whose clothing this client handles, the server's record (false
-- when none is stored, nil when it could not be read), and whether changes go out.
local citizen, stored, saving = nil, nil, false

-- What the puppet should wear -- the last put on, or the last sent -- the save
-- sent and not yet answered, when the last one went out, failed saves in a row,
-- and whether the player has been told.
local wanted, pending, lastSentAtMs, strikes, told = nil, nil, nil, 0, false

-- This world entry's phase, the record put on this entry fitted to the body, the
-- put-ons spent, when the last went on, and when presence first waited.
local phase = 'idle'
local target = nil
local attempts, appliedAtMs, holdFromMs = 0, 0, 0

-- Since when the gate of step 1 has been shut this world entry (0 while it is
-- open), and the clause that was reported, so one stall is one line.
local gateSinceMs, gateSaid = 0, nil

-- A changed record seen on the puppet and since when, and the module holding the
-- puppet for a fitting room.
local candidate, candidateAtMs = nil, 0
local previewOwner = nil

-- The CRC-32 table a TweakDB id is hashed with.
local CRC = {}
for index = 0, 255 do
	local value = index
	for _ = 1, 8 do
		value = (value & 1) == 1 and ((value >> 1) ~ 0xEDB88320) or (value >> 1)
	end
	CRC[index] = value
end

-- Record names by the TweakDB id the registry reads them back as, and the names
-- already hashed into it.
local names, learned = {}, {}

--- A record name's TweakDB id as the registry prints it: length, then CRC-32.
local function tweakId(record)
	local crc = 0xFFFFFFFF
	for index = 1, #record do
		crc = (crc >> 8) ~ CRC[(crc ~ record:byte(index)) & 0xFF]
	end
	return ('0X%08X%08X'):format(#record, crc ~ 0xFFFFFFFF)
end

--- Remembers a record name so its TweakDB id reads back as the name.
-- @author dop42
-- @param record any
function M.Clothing.Learn(record)
	if type(record) ~= 'string' or record == '' or learned[record] then return end
	if record:match('^0[xX]%x+$') then return end
	learned[record] = true
	names[tweakId(record)] = record
end
local learn = Clothing.Learn

--- The record name behind a TweakDB id the registry returned, or the value.
-- @author dop42
-- @param value any
-- @return any
function M.Clothing.Resolve(value)
	if type(value) ~= 'string' or not value:match('^0[xX]%x+$') then return value end
	local key = value:upper()
	if names[key] then return names[key] end
	local equipment = Open77.equipment
	if type(equipment) == 'table' and type(equipment.info) == 'function' then
		local read, info = pcall(equipment.info, value)
		if read and type(info) == 'table' and type(info.record) == 'string' and
			not info.record:match('^0[xX]%x+$') then
			learn(info.record)
			return info.record
		end
	end
	return value
end
local resolve = Clothing.Resolve

--- A record name, or false for an empty slot.
local function recordOf(value)
	if type(value) ~= 'string' or value == '' then return false end
	learn(value)
	return resolve(value)
end

--- Puts a clothing-shaped table into the form the server canonicalises to.
local function normalize(value)
	if type(value) ~= 'table' then return nil end
	local equipment = type(value.equipment) == 'table' and value.equipment or {}
	local wardrobe = type(value.wardrobe) == 'table' and value.wardrobe or {}
	local out = { schemaVersion = 1, equipment = {}, wardrobe = { outfits = {} } }
	for _, slot in ipairs(SLOTS) do out.equipment[slot] = recordOf(equipment[slot]) end
	local active = tonumber(wardrobe.active)
	if active and active % 1 == 0 and active >= 0 and active < OUTFITS then
		out.wardrobe.active = math.floor(active)
	end
	local outfits = type(wardrobe.outfits) == 'table' and wardrobe.outfits or {}
	for index = 0, OUTFITS - 1 do
		-- After JSON the key is a string; before it, a number. Both are read.
		local overrides = outfits[tostring(index)] or outfits[index]
		if type(overrides) == 'table' then
			local shown, any = {}, false
			for _, slot in ipairs(OUTFIT_SLOTS) do
				local item = overrides[slot]
				if item == false or (type(item) == 'string' and item ~= '') then
					shown[slot], any = item and recordOf(item), true
				end
			end
			if any then out.wardrobe.outfits[tostring(index)] = shown end
		end
	end
	return out
end
M.Clothing.Normalize = normalize

--- Whether two plain values are equal, tables by content.
-- @author dop42
-- @param left any
-- @param right any
-- @return boolean
function M.Clothing.Same(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= 'table' then return left == right end
	for key, value in pairs(left) do
		if not Clothing.Same(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end
local same = Clothing.Same

--- Whether equipment info allows a body family to wear the item.
-- @author dop42
-- @param info table
-- @param family string|nil
-- @return boolean
function M.Clothing.Fits(info, family)
	if family == 'male' and info.supportsMale == false then return false end
	if family == 'female' and info.supportsFemale == false then return false end
	return true
end

--- An item this body can wear, or false.
-- An item the body cannot wear goes on as an empty slot rather than costing the
-- player the whole record: the stored one keeps it until they change something.
local function fit(record, family, lookups)
	if type(record) ~= 'string' then return false end
	if not lookups then return record end
	local read, info = pcall(Open77.equipment.info, record)
	if not read then return record end
	if type(info) ~= 'table' or not Clothing.Fits(info, family) then return false end
	return record
end

--- A normalized copy of a record fitted to a body family.
local function fitted(record, family)
	local out = normalize(record)
	local equipment = Open77.equipment
	local lookups = type(equipment) == 'table' and type(equipment.info) == 'function'
	if lookups then
		-- A catalogue that answers nothing at all must not empty every slot.
		local read, info = pcall(equipment.info, DEFAULT.equipment.UnderwearBottom)
		lookups = read and type(info) == 'table'
	end
	for _, slot in ipairs(SLOTS) do
		out.equipment[slot] = fit(out.equipment[slot], family, lookups)
	end
	for key, shown in pairs(out.wardrobe.outfits) do
		for slot, item in pairs(shown) do
			if item then shown[slot] = fit(item, family, lookups) end
		end
		out.wardrobe.outfits[key] = shown
	end
	return out
end

--- What the puppet wears, normalized, nil while it cannot be read.
-- @author dop42
-- @return table|nil
-- @return string|nil why
function M.Clothing.ReadWorn()
	local equipment, wardrobe = Open77.equipment, Open77.wardrobe
	if type(equipment) ~= 'table' or type(wardrobe) ~= 'table' then
		return nil, 'equipment_api_unavailable'
	end
	local read, registry, reason = pcall(equipment.registry)
	if not read or type(registry) ~= 'table' then
		return nil, tostring(read and reason or registry)
	end
	local listed, active, why = pcall(wardrobe.active)
	if not listed or active == nil then return nil, tostring(listed and why or active) end
	local record = { equipment = registry, wardrobe = { outfits = {} } }
	if active ~= false then record.wardrobe.active = active end
	for index = 0, OUTFITS - 1 do
		local opened, outfit, failure = pcall(wardrobe.outfit, index)
		if not opened or type(outfit) ~= 'table' or type(outfit.registry) ~= 'function' then
			return nil, tostring(opened and failure or outfit)
		end
		local got, overrides, missing = pcall(outfit.registry)
		if not got or type(overrides) ~= 'table' then
			return nil, tostring(got and missing or overrides)
		end
		record.wardrobe.outfits[tostring(index)] = overrides
	end
	return normalize(record)
end
local readWorn = Clothing.ReadWorn

--- Makes one native call, collecting its refusal instead of raising.
local function attempt(failures, label, fn, ...)
	local called, ok, reason = pcall(fn, ...)
	if not called then ok, reason = false, ok end
	if not ok then failures[#failures + 1] = ('%s: %s'):format(label, tostring(reason)) end
end

--- States a whole record on the puppet, wardrobe first.
-- `allowRestricted` as the platform's own relay states it: a record the character
-- owns is not this module's to second-guess.
local function putOn(record)
	local equipment, wardrobe = Open77.equipment, Open77.wardrobe
	if type(equipment) ~= 'table' or type(wardrobe) ~= 'table' then
		return false, 'equipment_api_unavailable'
	end
	local failures = {}
	for index = 0, OUTFITS - 1 do
		local opened, outfit = pcall(wardrobe.outfit, index)
		if opened and type(outfit) == 'table' and type(outfit.apply) == 'function' then
			attempt(failures, 'outfit ' .. index, outfit.apply,
				record.wardrobe.outfits[tostring(index)] or {},
				{ allowRestricted = true, replace = true })
		else
			failures[#failures + 1] = ('outfit %d: %s'):format(index, tostring(outfit))
		end
	end
	attempt(failures, 'activate', wardrobe.activate, record.wardrobe.active or false)
	attempt(failures, 'equipment', equipment.apply, record.equipment, { allowRestricted = true })
	if #failures > 0 then return false, table.concat(failures, '; ') end
	return true
end

--- Whether this client dresses and saves characters at all.
-- It stands down while the platform's own appearance package runs: that one
-- stores its own clothing, and two of them fight over the same puppet.
local function enabled()
	local config = type(M.Settings.CLOTHING) == 'table' and M.Settings.CLOTHING or {}
	if config.PERSIST == false then return false end
	return GetResourceState(M.OFFICIAL) ~= 'running'
end

--- CLOTHING.SAVE_DEBOUNCE_MS, or the shipped value for an unusable one.
local function debounceMs()
	local config = type(M.Settings.CLOTHING) == 'table' and M.Settings.CLOTHING or {}
	return M.ConfigMs(config.SAVE_DEBOUNCE_MS) or SAVE_DEBOUNCE_MS
end

--- WHY the puppet may not be dressed, or read for a save, now -- or nil.
-- @author dop42
--
-- This is the gate of step 1, and it is deliberately the strictest thing here.
-- It answers the NAME of the clause that is shut rather than a boolean, and that
-- is the whole difference between a fitting room that could not be diagnosed and
-- one that can: a shut gate produces no put-on, so it produces no read-back, so
-- it produces no `diagnose` line and no `clothingRestored` on the bus. The
-- symptom of every clause below is therefore identical and is *nothing at all* --
-- no clothes, no error, no journal line, and a join-time fitting room waiting on
-- a decision that is never reached. `Check` reports this name once the gate has
-- been shut long enough to be a fault rather than a moment.
--
-- THE CAUSES COME BEFORE THEIR CONSEQUENCES, and the order below is nothing but
-- that. `not_announced` and `appearance_unsettled` are both DOWNSTREAM of a
-- creation -- `AppearanceSettled` is false for as long as `creating` is true, by
-- design, and the announcement waits on `AppearanceSettled` -- so a creation
-- reported itself as `not_announced`, which is the symptom and names nothing a
-- reader can act on. Measured on 2026-09-20: forty seconds of `not_announced` on
-- ZXX-GAE6 that were forty seconds of a player standing in the character
-- creator, and two earlier diagnoses were argued from that word.
-- @return string|nil
local function shut()
	if State.citizenId == nil then return 'no_character' end
	if State.citizenId ~= citizen then return 'character_changed' end
	if State.editing then return 'editing' end
	if State.creating then return 'creating' end
	if State.creatorUp then return 'creator_up' end
	if State.commit ~= nil then return 'committing' end
	if not State.gameplayAnnounced then return 'not_announced' end
	if not State.AppearanceSettled() then return 'appearance_unsettled' end
	if Runtime.ModalOnScreen() then return 'native_modal' end
	if not Runtime.Faceable() then return 'not_faceable' end
	return nil
end
M.Clothing.Shut = shut

--- Whether the puppet may be dressed, or read for a save, now.
local function ready()
	return shut() == nil
end
M.Clothing.Ready = ready

--- Raises a clothing decision on the public bus.
local function publish(event, ok, failure)
	Runtime.Publish({ ok = ok, event = event, error = failure, citizenId = citizen })
end

--- Tells the player once per character that their clothes are not kept.
local function tell(key, reason)
	if told then return end
	told = true
	Runtime.Notify('warning', key, { reason = reason })
end

--- Puts the wanted, stored or default record on the puppet.
local function restore()
	attempts = attempts + 1
	local source = wanted or (stored ~= false and stored or DEFAULT)
	target = fitted(source, Runtime.BodyFamily())
	local ok, reason = putOn(target)
	appliedAtMs = Runtime.NowMs()
	phase = 'restoring'
	if not ok then
		Open77.log.debug(('[appearance] clothing put-on %d/%d refused: %s')
			:format(attempts, RESTORE_ATTEMPTS, tostring(reason)))
	end
end

--- A short printable form of a plain value, for a diagnostic line.
local function shown(value)
	if type(value) == 'string' then return value end
	if type(value) ~= 'table' then return tostring(value) end
	local parts = {}
	for key, item in pairs(value) do
		parts[#parts + 1] = tostring(key) .. '=' ..
			(type(item) == 'table' and 'table' or tostring(item))
		if #parts >= 12 then break end
	end
	table.sort(parts)
	return '{' .. table.concat(parts, ',') .. '}'
end

--- Where two plain values differ, as `path=left|right` lines.
local function differences(left, right)
	local out = {}
	local function walk(path, a, b)
		if #out >= 16 then return end
		if type(a) == 'table' and type(b) == 'table' then
			local keys = {}
			for key in pairs(a) do keys[key] = true end
			for key in pairs(b) do keys[key] = true end
			for key in pairs(keys) do walk(path .. '.' .. tostring(key), a[key], b[key]) end
		elseif not same(a, b) then
			out[#out + 1] = ('%s=%s|%s'):format(path, shown(a), shown(b))
		end
	end
	walk('', left, right)
	return table.concat(out, '; ')
end

--- Logs why the clothing did not read back, here and in the server log.
local function diagnose(worn, reason)
	local text = ('%s attempt %d/%d: '):format(tostring(citizen), attempts, RESTORE_ATTEMPTS)
	if worn == nil then
		text = text .. 'unreadable (' .. tostring(reason) .. ')'
	else
		text = text .. 'worn|target ' .. differences(worn, target)
	end
	-- Through `Runtime.Note` rather than raising the event itself, which is what
	-- this did: an unprotected `TriggerServerEvent` on the one path that runs
	-- while the clothing is already failing, outside the module's own bound and
	-- outside the local log line every other note writes.
	Runtime.Note('clothing read-back: ' .. text)
end

--- Reads the put-on record back, retrying or giving up.
local function verify()
	local worn, unreadable = readWorn()
	if worn ~= nil and same(worn, target) then
		phase = 'worn'
		wanted = target
		candidate = nil
		-- In the SERVER's journal, not only this client's log. One line per world
		-- entry, and it is the line that answers "did the restore run at all" --
		-- the question two diagnoses of the fitting room both had to guess at.
		Runtime.Note(('clothing of %s is on (%s)'):format(tostring(citizen),
			stored == false and 'the default record' or 'the stored record'))
		return publish('clothingRestored', true)
	end
	if Runtime.NowMs() - appliedAtMs < VERIFY_MS then return end
	if attempts == 1 or attempts >= RESTORE_ATTEMPTS then diagnose(worn, unreadable) end
	if attempts < RESTORE_ATTEMPTS then
		phase = 'waiting'
		return
	end
	-- Nothing is saved for the rest of this world entry: a save read off a puppet
	-- that never wore the record would store whatever it is wearing instead.
	phase = 'failed'
	Runtime.Note(('the clothing of %s did not read back after %d put-ons; it is not saved ' ..
		'until the next world entry'):format(tostring(citizen), attempts))
	publish('clothingRestored', false, 'clothing_not_restored')
	tell('appearance.clothingRestoreFailed', 'clothing_not_restored')
end

--- Sends a clothing record to the server and waits for its answer.
local function send(record)
	local now = Runtime.NowMs()
	lastSentAtMs = now
	local sent, reason = TriggerServerEvent(M.Event.SAVE_CLOTHING,
		{ citizenId = citizen, clothing = record })
	if not sent then
		Open77.log.debug('[appearance] clothing not sent: ' .. tostring(reason))
		return
	end
	local commitMs = M.ConfigMs(M.Settings.COMMIT_MS) or 20000
	pending = { record = record, previous = wanted, deadlineMs = now + commitMs }
	wanted = record
	candidate = nil
end

--- Counts a failed save and stops saving after STRIKES in a row.
local function strike(failed, reason)
	wanted = failed.previous
	strikes = strikes + 1
	if strikes < STRIKES then return end
	saving = false
	Open77.log.warn(('[appearance] the clothing of %s is no longer saved this session: %s')
		:format(tostring(citizen), reason))
	publish('clothingSaved', false, reason)
	tell('appearance.clothingNotSaved', reason)
end

--- Saves a held change on the puppet once the cooldown has passed.
local function capture()
	if not saving or pending ~= nil then return end
	local worn = readWorn()
	if worn == nil then return end
	if same(worn, wanted) then
		candidate = nil
		return
	end
	local now = Runtime.NowMs()
	if candidate == nil or not same(candidate, worn) then
		candidate, candidateAtMs = worn, now
		return
	end
	if now - candidateAtMs < debounceMs() then return end
	local cooldown = M.ConfigMs(M.Settings.SAVE_COOLDOWN_MS) or 2000
	if lastSentAtMs ~= nil and now - lastSentAtMs < cooldown then return end
	-- A look the server already holds is not sent.
	local holds = stored == false and DEFAULT or normalize(stored)
	if holds ~= nil and same(worn, holds) then
		wanted, candidate = worn, nil
		return
	end
	send(worn)
end

--- Strikes a clothing save the server did not answer in time.
local function expire()
	if pending == nil or Runtime.NowMs() < pending.deadlineMs then return end
	local failed = pending
	pending = nil
	Open77.log.warn(('[appearance] the clothing save of %s was not answered')
		:format(tostring(citizen)))
	strike(failed, 'save_timeout')
end

--- Starts a world entry: the pristine puppet has to be dressed again.
-- @author dop42
function M.Clothing.EnterWorld()
	target, attempts, appliedAtMs, holdFromMs = nil, 0, 0, 0
	candidate, previewOwner = nil, nil
	gateSinceMs, gateSaid = 0, nil
	phase = (citizen ~= nil and stored ~= nil and enabled()) and 'waiting' or 'idle'
end

--- Adopts the new live character's clothing from PlayerData.
-- @author dop42
-- @param playerData table
function M.Clothing.Adopt(playerData)
	citizen = playerData.citizenId
	local clothing = playerData.clothing
	if clothing == false then
		stored = false
	else
		stored = normalize(clothing)
	end
	saving = stored ~= nil and enabled()
	wanted, pending, lastSentAtMs, strikes, told = nil, nil, nil, 0, false
	Clothing.EnterWorld()
	if stored == nil then
		-- NOT A DEBUG LINE. This is the whole clothing half standing down for the
		-- session -- nothing is put on, nothing is read back, nothing is saved and
		-- no decision is ever published, so a fitting room offered on
		-- `clothingRestored` is offered to nobody. It was written at debug level to
		-- a log on the player's machine, which is two reasons nobody has ever seen
		-- it happen.
		Runtime.Note(('%s: no clothing came with the character; nothing is put on and nothing ' ..
			'is saved this session'):format(tostring(citizen)))
	end
end

--- Forgets the unloaded character's clothing.
-- @author dop42
function M.Clothing.Unload()
	citizen, stored, saving, wanted, pending, lastSentAtMs = nil, nil, false, nil, nil, nil
	strikes, told = 0, false
	Clothing.EnterWorld()
end

--- Whether the published look may go out: the clothes are on, or waited for long
--- enough that the player should be drawn anyway.
-- @author dop42
-- @return boolean
function M.Clothing.Settled()
	if phase ~= 'waiting' and phase ~= 'restoring' then return true end
	local now = Runtime.NowMs()
	if holdFromMs == 0 then holdFromMs = now end
	return now - holdFromMs >= PRESENCE_HOLD_MS
end

--- The clothing phase the `State` contract function reports.
-- @author dop42
-- @return string
function M.Clothing.Report()
	if previewOwner ~= nil then return 'previewing' end
	if phase == 'worn' and pending ~= nil then return 'saving' end
	if phase == 'worn' and not saving then return 'unsaved' end
	return phase
end

--- Whether something is trying clothes on the puppet.
-- @author dop42
-- @return boolean
function M.Clothing.Previewing()
	return previewOwner ~= nil
end

--- Lends the puppet to a fitting room: nothing is saved or published meanwhile.
-- @author dop42
-- @param owner string the caller's own name
-- @return table|nil what the puppet wears
-- @return string|nil the refusal
function M.Clothing.BeginPreview(owner)
	if type(owner) ~= 'string' or owner == '' then return nil, 'invalid_caller' end
	if previewOwner ~= nil then return nil, 'preview_busy' end
	if citizen == nil then return nil, 'no_character' end
	if stored == nil or not enabled() then return nil, 'clothing_unavailable' end
	if not saving then return nil, 'clothing_not_saved' end
	if phase ~= 'worn' or not ready() then return nil, 'clothing_not_ready' end
	if pending ~= nil then return nil, 'clothing_saving' end
	local worn, reason = readWorn()
	if worn == nil then return nil, tostring(reason or 'clothing_unreadable') end
	previewOwner, candidate = owner, nil
	Open77.log.info(('[appearance] %s tries clothes on %s'):format(owner, tostring(citizen)))
	return worn
end

--- Takes the puppet back, saving what it wears or putting the record back on.
-- @author dop42
-- @param owner string
-- @param keep boolean
-- @param records table|nil the record names the fitting room put on, so their
---   TweakDB ids read back by name
-- @return boolean
-- @return string|nil the refusal
function M.Clothing.EndPreview(owner, keep, records)
	if previewOwner == nil then return false, 'no_preview' end
	if previewOwner ~= owner then return false, 'not_owner' end
	previewOwner = nil
	if type(records) == 'table' then
		for _, record in pairs(records) do learn(record) end
	end
	if keep then
		local worn = readWorn()
		-- Dated back by the debounce, so a look the player already confirmed is not
		-- made to hold for another two seconds before it is saved.
		if worn ~= nil and not same(worn, wanted) then
			candidate, candidateAtMs = worn, Runtime.NowMs() - debounceMs()
		end
	else
		target, attempts, candidate = nil, 0, nil
		phase = 'waiting'
	end
	Open77.log.info(('[appearance] %s gave the puppet back (%s)')
		:format(owner, keep and 'kept' or 'restored'))
	return true
end

--- Reports a gate that has been shut too long, and settles one that never opens.
-- @author dop42
--
-- Answers whether the caller should stop: a world entry that has given up on
-- dressing is over, exactly as a read-back that ran out of put-ons is.
-- @param reason string the clause `shut` named
-- @return boolean
local function stalled(reason)
	local now = Runtime.NowMs()

	-- See `HELD`. Said once per clause per world entry -- `gateSaid` is cleared
	-- when the gate opens -- because it is a decision about what this module is
	-- doing, and because a line per pass would spend the note budget five times
	-- a second.
	if HELD[reason] then
		if gateSaid ~= reason then
			gateSaid = reason
			Runtime.Note(('the clothing of %s waits on %s; the give-up clock does not run ' ..
				'while a screen the player is standing in front of is up')
				:format(tostring(citizen), reason))
		end
		gateSinceMs = 0
		return false
	end

	if gateSinceMs == 0 then gateSinceMs = now end
	local held = now - gateSinceMs

	if held >= GATE_GIVEUP_MS then
		-- SETTLED, NOT LEFT WAITING. Nothing saves after this -- a save read off a
		-- puppet that never wore the record would store whatever it is wearing --
		-- but the decision does go out, because the join is behind it: the fitting
		-- room offer waits on `clothingRestored`, and a world entry that can never
		-- be dressed has to say so rather than hold the offer open for ever.
		phase = 'failed'
		Runtime.Note(('the clothing of %s was never put on: %s for %d ms')
			:format(tostring(citizen), reason, held))
		publish('clothingRestored', false, 'clothing_gate_shut')
		tell('appearance.clothingRestoreFailed', 'clothing_gate_shut')
		return true
	end

	if held >= GATE_REPORT_MS and gateSaid ~= reason then
		gateSaid = reason
		Runtime.Note(('the clothing of %s is waiting: %s (%d ms)')
			:format(tostring(citizen), reason, held))
	end
	return false
end

--- Runs one clothing pass: deadline, put-on, read-back or save.
-- @author dop42
function M.Clothing.Check()
	expire()
	if previewOwner ~= nil then return end
	if phase == 'idle' or phase == 'failed' then return end
	local closed = shut()
	if closed ~= nil then
		-- A change seen before the gate closed has to hold again once it opens.
		candidate = nil
		stalled(closed)
		return
	end
	gateSinceMs, gateSaid = 0, nil
	if phase == 'waiting' then return restore() end
	if phase == 'restoring' then return verify() end
	capture()
end

--- Ends the pending clothing save the server refused.
-- @author dop42
--
-- These codes are NOT catalogue keys and are never shown: they are published and
-- logged, and the look is dropped. `error.tooFast` is not a failure -- the change
-- is simply put back and tried again once the cooldown has passed.
-- @param code string
-- @param operation string
function M.Clothing.OnRefused(code, operation)
	if operation ~= M.Operation.SAVE_CLOTHING or pending == nil then return end
	local failed = pending
	pending = nil
	code = tostring(code)
	if code == 'error.tooFast' then
		wanted = failed.previous
		return
	end
	-- Neither is this client's business any more: the character has moved on.
	if code == 'clothing.stale' or code == 'error.notLoggedIn' then return end
	if code == 'error.unavailable' then return strike(failed, code) end
	-- THE SHOP COULD NOT TAKE THE MONEY, so the clothes go back. The server
	-- charges a priced room's save before writing it, and refused this one: the
	-- stored record is still what this character owns, so it is what the puppet
	-- is dressed in again -- the same restart a record stored elsewhere gets --
	-- rather than a look nobody paid for staying on, and being published.
	if code == 'clothing.unpaid' then
		wanted = failed.previous
		Runtime.Note(('the clothing of %s was not paid for; the stored look goes back on')
			:format(tostring(citizen)))
		publish('clothingSaved', false, code)
		if previewOwner == nil then Clothing.EnterWorld() end
		return
	end
	Open77.log.warn(('[appearance] clothing save refused: %s'):format(code))
	publish('clothingSaved', false, code)
end

--- Builds the held state. Never yields.
-- @author dop42
function M.Clothing.Init()
	citizen, stored, saving = nil, nil, false
	wanted, pending, lastSentAtMs, strikes, told = nil, nil, nil, 0, false
	phase, target = 'idle', nil
	attempts, appliedAtMs, holdFromMs = 0, 0, 0
	candidate, candidateAtMs, previewOwner = nil, 0, nil
	gateSinceMs, gateSaid = 0, nil
	names, learned = {}, {}
end

--- Registers the clothing answer from the server.
-- @author dop42
function M.Clothing.Wire()
	RegisterNetEvent(M.Event.CLOTHING_SAVED, function(record)
		record = normalize(record)
		if record == nil or citizen == nil then return end
		stored = record
		if pending ~= nil and same(pending.record, record) then
			pending, strikes = nil, 0
			return publish('clothingSaved', true)
		end
		if pending ~= nil then return end
		-- Stored somewhere else: it becomes what the puppet should wear, and a
		-- world entry that had finished starts over to put it on.
		wanted = record
		if previewOwner == nil and (phase == 'worn' or phase == 'failed') then
			Clothing.EnterWorld()
		end
	end)
end
