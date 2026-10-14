--- The server half: validating a face, validating what is worn, storing both, and
--- handing every player's look to the other players.
-- @author dop42
--
-- Nothing a client sends is trusted here. The character written is always the one
-- on the connection, resolved before any thread; a citizen id inside a payload is
-- only ever used to REFUSE a save captured for the character before a switch.
--
-- The validators below are the whole value of this file. They are written against
-- what the engine actually renders, not against what a well-behaved client would
-- send, and every guard in them answers a specific way a client can lie.

local M = OPX.Modules.Get('appearance')

local Result = OPX.Result

-- The character contract, looked up in `Start`: contracts only exist from the api
-- phase on. Never the module by name.
local character

-- The host announces a bucket change under a name `OPX.Host` does not list; it is
-- in `M.HostEvent` with the other host names this module knows.
local HOST_BUCKET_CHANGE = M.HostEvent.BUCKET_CHANGE

-- ── the face ─────────────────────────────────────────────────────────────────

M.Appearance = {}
local Appearance = M.Appearance

--- The schema version written into every stored snapshot.
M.Appearance.VERSION = 1

-- The three parts the engine's catalogue is divided into.
local PARTS = { head = true, body = true, arms = true }

-- The ceiling on an option index and on its choice count.
local MAX_CHOICES = 512

-- The most options one snapshot may carry.
local MAX_OPTIONS = 256

--- Whether a value is a finite whole number.
-- Deliberately NOT `tonumber`: an option index arriving as the string "3" is a
-- client that no longer speaks this protocol, and accepting it would let a
-- rewritten client decide what the catalogue means.
local function isInteger(value)
	return type(value) == 'number' and OPX.Math.IsFinite(value) and value % 1 == 0
end

--- Whether a value is a 64-bit engine id as the platform renders it.
-- `0x` and sixteen hex digits, compared as text and NEVER through `tonumber`,
-- which a 64-bit hash does not survive: the two largest halves of the id space
-- both collapse onto the same double.
-- @param allowZero boolean true for the body-family hash, which may be null
local function isHash(value, allowZero)
	if type(value) ~= 'string' or #value ~= 18 then return false end
	if value:sub(1, 2) ~= '0x' or value:sub(3):match('^%x+$') == nil then return false end
	return allowZero or value ~= '0x0000000000000000'
end

--- Lower-cases a SHA-256 catalogue fingerprint, or answers nil.
local function digest(value)
	if type(value) ~= 'string' then return nil end
	local lowered = value:lower()
	if #lowered ~= 64 or lowered:match('^%x+$') == nil then return nil end
	return lowered
end

--- Answers a snapshot in canonical form, or nil and a code.
-- @author dop42
--
-- Canonical means dense options, lower-cased names, and each field the type its
-- column expects. Two guards are worth naming: `choices = 0` is a catalogue entry
-- with nothing to choose, which the engine really does report, and is the only
-- case where the index cannot be bounded by it; and `#value.options` stops at the
-- first hole, so the loop has only proved a PREFIX -- a final pass refuses any
-- numeric key outside `1..count`.
-- @param value any
-- @return table|nil
-- @return string|nil the code
function M.Appearance.Canonical(value)
	if type(value) ~= 'table' then return nil, 'invalid_snapshot' end
	if value.schemaVersion ~= Appearance.VERSION then return nil, 'unsupported_schema' end
	if not M.BuildAccepted(value.gameBuild) then return nil, 'unsupported_game_build' end

	local catalog = digest(value.catalogDigest)
	if catalog == nil then return nil, 'invalid_catalog_digest' end

	-- The engine's opaque body hash, not the female/male string: that one is
	-- `charInfo.gender` and lives on the character row.
	if not isHash(value.gender, true) then return nil, 'invalid_gender' end

	if type(value.options) ~= 'table' then return nil, 'invalid_options' end
	local count = #value.options
	if count < 1 or count > MAX_OPTIONS then return nil, 'invalid_option_count' end

	local canonical = {
		schemaVersion = Appearance.VERSION,
		gameBuild = value.gameBuild,
		catalogDigest = catalog,
		gender = value.gender,
		options = {},
	}

	local seen = {}
	for index = 1, count do
		local option = value.options[index]
		if type(option) ~= 'table' then return nil, 'invalid_option' end
		if not PARTS[option.part] then return nil, 'invalid_option_part' end
		if not isHash(option.name, false) then return nil, 'invalid_option_name' end
		if not isInteger(option.value) or option.value < 0 or option.value >= MAX_CHOICES then
			return nil, 'invalid_option_value'
		end
		if not isInteger(option.choices) or option.choices < 0 or option.choices > MAX_CHOICES then
			return nil, 'invalid_option_choices'
		end
		if option.choices > 0 and option.value >= option.choices then
			return nil, 'option_out_of_range'
		end
		local key = option.part .. ':' .. option.name:lower()
		if seen[key] then return nil, 'duplicate_option' end
		seen[key] = true
		canonical.options[index] = {
			part = option.part,
			name = option.name:lower(),
			value = option.value,
			choices = option.choices,
		}
	end

	for key in pairs(value.options) do
		if type(key) == 'number' and (not isInteger(key) or key < 1 or key > count) then
			return nil, 'sparse_options'
		end
	end

	return canonical
end

--- Whether two canonical snapshots are the same face.
-- @author dop42
-- @param left table|nil
-- @param right table|nil
-- @return boolean
function M.Appearance.Same(left, right)
	if type(left) ~= 'table' or type(right) ~= 'table' then return false end
	if left.gameBuild ~= right.gameBuild or left.catalogDigest ~= right.catalogDigest then
		return false
	end
	if left.gender ~= right.gender then return false end
	local count = #left.options
	if count ~= #right.options then return false end
	for index = 1, count do
		local a, b = left.options[index], right.options[index]
		if a.part ~= b.part or a.name ~= b.name or a.value ~= b.value then return false end
	end
	return true
end

--- Tells the client its PlayerData changed, when the character module offers it.
local function republish(player)
	local functions = player.Functions
	if type(functions) == 'table' and type(functions.UpdatePlayerData) == 'function' then
		functions.UpdatePlayerData()
	end
end

--- Validates, stores and publishes a character's captured face. Coroutine only.
-- @author dop42
--
-- THE ORDER IS THE CONTRACT. `Same` is compared BEFORE the encoding, so the size
-- check cannot answer differently for a face that is already stored. And
-- `PlayerData.appearance` is set BEFORE the write and put back only if nothing
-- else replaced it meanwhile: the character module's disconnect save rewrites
-- that column from memory, and started while this write waited it would otherwise
-- clobber the face that was just stored.
-- @param identifier Player|Source|CitizenId
-- @param snapshot any
-- @return Result
function M.SaveAppearance(identifier, snapshot)
	local player = character and character.ResolvePlayer(identifier) or nil
	if not player then return Result.Err('error.notLoggedIn', tostring(identifier)) end

	local canonical, reason = Appearance.Canonical(snapshot)
	if not canonical then return Result.Err('appearance.invalid', reason) end

	local data = player.PlayerData
	if Appearance.Same(data.appearance, canonical) then return Result.Ok(data.appearance) end

	local encoded = json.encode(canonical)
	if #encoded > M.MaxFaceBytes then
		return Result.Err('appearance.tooLarge', tostring(#encoded))
	end

	local previous = data.appearance
	data.appearance = canonical
	local written = M.Storage.SaveAppearance(data.citizenId, canonical)
	if not written.ok then
		if data.appearance == canonical then data.appearance = previous end
		return written
	end

	-- The write yielded, so this only goes out while this Player is still the one
	-- loaded on that source.
	if not player.Offline and character.GetPlayer(data.source) == player then
		republish(player)
		TriggerClientEvent(M.Event.FACE_SAVED, data.source, canonical)
	end
	TriggerEvent(M.Event.IN_FACE, data.source, data.citizenId, canonical)

	OPX.Audit.Player(player, 'appearance.saved', canonical.gameBuild,
		{ options = #canonical.options })
	return Result.Ok(canonical)
end

--- Writes the body a character was built on to its row, once. Coroutine only.
-- @author dop42
--
-- THE ONLY FIELD OF AN IDENTITY THAT ARRIVES WITH A FACE. It has to: the body
-- family is the engine's own character creator's answer, and the creator runs
-- after the row exists. The client is trusted to name one of the two families
-- and with nothing else -- the character module refuses a second write, so the
-- family that is stored is the one that came with the character's first face and
-- can never be moved afterwards.
--
-- A refusal is logged and goes no further. The face itself IS saved, and a
-- character whose row kept the body it already had is not a reason to refuse a
-- player their own face.
-- @param player Player
-- @param family any
-- @return boolean
function M.AdoptBodyFamily(player, family)
	if character == nil or type(character.SetBodyFamily) ~= 'function' then return false end
	local citizen = tostring(player.PlayerData.citizenId)

	if family ~= 'female' and family ~= 'male' then
		Open77.log.warn(('[appearance] %s named %s as a body family')
			:format(citizen, tostring(family)))
		return false
	end

	local written = character.SetBodyFamily(player, family)
	if written.ok then return true end
	Open77.log.warn(('[appearance] the %s body was not written for %s: %s (%s)')
		:format(family, citizen, tostring(written.error), tostring(written.detail)))
	return false
end

--- The stored face of a character, online or not. Coroutine only when offline.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @return Result
function M.GetAppearance(identifier)
	local player = character and character.ResolvePlayer(identifier) or nil
	if player then return Result.Ok(player.PlayerData.appearance) end
	if type(identifier) ~= 'string' then
		return Result.Err('error.notLoggedIn', tostring(identifier))
	end
	return M.Storage.FetchAppearance(identifier)
end

-- ── what the character wears ─────────────────────────────────────────────────

M.Clothing = {}
local Clothing = M.Clothing

--- The schema version written into every stored record.
M.Clothing.VERSION = 1

-- The nine equipment slots, as the platform names them.
local SLOTS = { 'Head', 'Face', 'InnerChest', 'OuterChest', 'Legs', 'Feet', 'Outfit',
	'UnderwearTop', 'UnderwearBottom' }

local IS_SLOT = {}
for index = 1, #SLOTS do IS_SLOT[SLOTS[index]] = true end

-- The seven visible slots an outfit may override. Underwear is worn but never
-- replaced by an outfit, which is why it is absent here and present above.
local IS_OUTFIT_SLOT = { Head = true, Face = true, InnerChest = true, OuterChest = true,
	Legs = true, Feet = true, Outfit = true }

-- How many wardrobe outfits exist, indexed 0 to 6 as the platform indexes them.
local OUTFITS = 7

-- The longest record name, as the equipment service bounds one.
local MAX_RECORD_BYTES = 160

-- The largest encoded clothing document stored. Not a setting, and deliberately
-- separate from the face ceiling: it only catches a shape the checks above it
-- should already have caught, since nine slots and forty-nine overrides of 160
-- bytes stay under 10 KiB.
local MAX_CLOTHING_JSON_BYTES = 16384

-- Milliseconds between two saves of either kind from one player.
local COOLDOWN_MS = 2000

--- Answers a worn record name, false for an empty slot, nil otherwise.
-- There is no catalogue on a server, so this is a shape and not a lookup -- the
-- same shape the look distribution below accepts.
--
-- ANCHORED TO `Items.`, WHICH IS AS FAR AS A SHAPE CAN GO. The pattern used to be
-- `[%w_%.%-]+` and nothing else, so `Character.Judy` and `Vehicle.Cthulhu` were
-- accepted as things to wear; every clothing record the equipment service knows
-- is in the `Items` namespace, so one anchor turns a whole family of nonsense
-- into a refusal. It is NOT membership validation and must not grow into one:
-- `Open77.equipment.records` and `.info` are client-only, there is no catalogue
-- on this side to check against, and asking the client for one would be trusting
-- the thing the check exists to distrust.
local function recordOf(value)
	if value == false then return false end
	if type(value) ~= 'string' or #value < 1 or #value > MAX_RECORD_BYTES then return nil end
	if value:match('^Items%.[%w_%.%-]+$') == nil then return nil end
	return value
end

--- Reads an outfit index from a number or from a single-digit string key.
-- JSON turns a table's integer keys into strings, so both shapes arrive.
local function outfitIndex(key)
	local number
	if type(key) == 'number' then
		number = key
	elseif type(key) == 'string' and key:match('^%d$') then
		number = tonumber(key)
	end
	if not isInteger(number) or number < 0 or number >= OUTFITS then return nil end
	return math.floor(number)
end

--- Answers a clothing record in canonical form, or nil and a code.
-- @author dop42
--
-- `"0"` and `0` are the same outfit: receiving both is a client that means two
-- different things at once, and it is refused rather than resolved.
-- @param value any
-- @return table|nil
-- @return string|nil the code
function M.Clothing.Canonical(value)
	if type(value) ~= 'table' then return nil, 'invalid_record' end
	for key in pairs(value) do
		if key ~= 'schemaVersion' and key ~= 'equipment' and key ~= 'wardrobe' then
			return nil, 'unknown_field'
		end
	end
	if value.schemaVersion ~= Clothing.VERSION then return nil, 'unsupported_schema' end

	local equipment = value.equipment
	if type(equipment) ~= 'table' then return nil, 'invalid_equipment' end
	local canonical = {
		schemaVersion = Clothing.VERSION, equipment = {}, wardrobe = { outfits = {} },
	}
	for slot, item in pairs(equipment) do
		if not IS_SLOT[slot] then return nil, 'invalid_slot' end
		if recordOf(item) == nil then return nil, 'invalid_item' end
	end
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		canonical.equipment[slot] = recordOf(equipment[slot]) or false
	end

	local wardrobe = value.wardrobe
	if type(wardrobe) ~= 'table' then return nil, 'invalid_wardrobe' end
	for key in pairs(wardrobe) do
		if key ~= 'active' and key ~= 'outfits' then return nil, 'unknown_wardrobe_field' end
	end
	if wardrobe.active ~= nil then
		local active = outfitIndex(wardrobe.active)
		if active == nil or type(wardrobe.active) ~= 'number' then return nil, 'invalid_active' end
		canonical.wardrobe.active = active
	end

	local outfits = wardrobe.outfits
	if outfits ~= nil and type(outfits) ~= 'table' then return nil, 'invalid_outfits' end
	local seen, count = {}, 0
	for key, overrides in pairs(outfits or {}) do
		count = count + 1
		local index = outfitIndex(key)
		if count > OUTFITS or index == nil or seen[index] then return nil, 'invalid_outfit' end
		seen[index] = true
		if type(overrides) ~= 'table' then return nil, 'invalid_outfit' end
		local clean, any = {}, false
		for slot, item in pairs(overrides) do
			if not IS_OUTFIT_SLOT[slot] then return nil, 'invalid_outfit_slot' end
			local record = recordOf(item)
			if record == nil then return nil, 'invalid_item' end
			clean[slot], any = record, true
		end
		if any then canonical.wardrobe.outfits[tostring(index)] = clean end
	end

	return canonical
end

--- Whether two canonical records are the same clothing.
-- @author dop42
-- @param left table|nil
-- @param right table|nil
-- @return boolean
function M.Clothing.Same(left, right)
	if type(left) ~= 'table' or type(right) ~= 'table' then return false end
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		if left.equipment[slot] ~= right.equipment[slot] then return false end
	end
	if left.wardrobe.active ~= right.wardrobe.active then return false end
	for index = 0, OUTFITS - 1 do
		local a, b = left.wardrobe.outfits[tostring(index)], right.wardrobe.outfits[tostring(index)]
		if (a == nil) ~= (b == nil) then return false end
		if a ~= nil then
			for slot in pairs(IS_OUTFIT_SLOT) do
				if a[slot] ~= b[slot] then return false end
			end
		end
	end
	return true
end

--- Reads and validates a character's stored clothing record. Coroutine only.
local function fetchClothing(citizenId)
	local fetched = M.Storage.FetchClothing(citizenId)
	if not fetched.ok then return fetched end
	if fetched.value == nil then return Result.Ok(false) end
	local canonical, reason = Clothing.Canonical(fetched.value)
	if not canonical then return Result.Err('clothing.unreadable', reason) end
	return Result.Ok(canonical)
end

--- What `PlayerData.clothing` starts as at login. Coroutine only.
-- @author dop42
--
-- NEVER refuses a login. A failure answers nil, which the client reads as 'dress
-- nothing, save nothing', and which `SaveClothing` refuses to write over: a
-- record nobody was able to show the player must not be replaced by one the
-- player never chose.
-- @param citizenId CitizenId
-- @return table|false|nil
function M.Clothing.Load(citizenId)
	local fetched = fetchClothing(citizenId)
	if fetched.ok then return fetched.value end
	Open77.log.warn(('[appearance] %s: the stored clothing could not be read (%s: %s); it is ' ..
		'neither restored nor overwritten this session'):format(OPX.Audit.Safe(citizenId),
			tostring(fetched.error), tostring(fetched.detail)))
	return nil
end

--- Validates, stores and publishes what a character wears. Coroutine only.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param clothing any
-- @return Result
function M.SaveClothing(identifier, clothing)
	local player = character and character.ResolvePlayer(identifier) or nil
	if not player then return Result.Err('error.notLoggedIn', tostring(identifier)) end

	local canonical, reason = Clothing.Canonical(clothing)
	if not canonical then return Result.Err('clothing.invalid', reason) end

	local data = player.PlayerData
	-- nil is 'the stored record could not be read', never 'nothing stored'.
	if data.clothing == nil then
		return Result.Err('error.unavailable', 'clothing_unavailable')
	end
	if Clothing.Same(data.clothing, canonical) then return Result.Ok(data.clothing) end

	local encoded = json.encode(canonical)
	if #encoded > MAX_CLOTHING_JSON_BYTES then
		return Result.Err('clothing.tooLarge', tostring(#encoded))
	end

	local written = M.Storage.SaveClothing(data.citizenId, encoded)
	if not written.ok then return written end
	data.clothing = canonical

	-- The write yielded: a player who switched character meanwhile is not sent
	-- this one's clothes.
	if not player.Offline and character.GetPlayer(data.source) == player then
		republish(player)
		TriggerClientEvent(M.Event.CLOTHING_SAVED, data.source, canonical)
	end
	TriggerEvent(M.Event.IN_CLOTHING, data.source, data.citizenId, canonical)

	OPX.Audit.Player(player, 'clothing.saved', nil, { bytes = #encoded })
	return Result.Ok(canonical)
end

--- The stored clothing of a character, online or not. Coroutine only when offline.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @return Result
function M.GetClothing(identifier)
	local player = character and character.ResolvePlayer(identifier) or nil
	if player then return Result.Ok(player.PlayerData.clothing) end
	if type(identifier) ~= 'string' then
		return Result.Err('error.notLoggedIn', tostring(identifier))
	end
	return fetchClothing(identifier)
end

-- ── the looks other players are drawn from ───────────────────────────────────
-- Another client draws this player only from what it is handed: the engine
-- replicates the position, the vehicle and the actions, never the look. A proxy
-- nobody dresses is never drawn at all, so the player simply is not there.
--
-- What is checked below is the SHAPE and not the truth: a client can only ever
-- describe its own player, which is the trust the platform's own package extends.

-- Least milliseconds between two requests of one kind from one player.
--
-- A PUBLICATION IS FANNED OUT, a replay is not. One accepted look is re-sent to
-- every connected player, and a body may weigh 48 KiB, so a client publishing
-- a different body every 500 ms -- which a modified one can -- pushed some
-- 96 KiB a second to EACH of N players. A real client publishes on a change
-- and retries an unanswered one after three seconds, so two seconds costs it
-- nothing: a change inside the floor is simply not acknowledged, and its retry
-- lands. A replay goes to the asker alone and keeps the short floor.
local FLOOR_MS = { present = 2000, replay = 500 }

-- Most bytes one encoded body, and one encoded equipment plus wardrobe, may weigh.
local MAX_BODY_BYTES = 49152
local MAX_CLOTHING_BYTES = 4096

-- The last look accepted for each player, players whose body is away during a
-- reload, when each player last got through the floor, and whose unreadable body
-- was already logged.
local looks, absent, lastAt, warned = {}, {}, {}, {}

-- The fingerprint of the last look each player was fanned out with. See
-- `M.LookFingerprint`.
local printed = {}

-- Whether the "this half drops every look" warning has been said.
local saidPresentingOff = false

--- Whether this half hands looks out at all.
local function presenting()
	return M.Settings.PRESENT_BODIES ~= false
end

--- Whether a player's request of this kind falls inside the floor.
local function cooled(kind, player)
	local key, atMs = kind .. ':' .. player, OPX.Now()
	local floor = FLOOR_MS[kind] or FLOOR_MS.replay
	if lastAt[key] and atMs - lastAt[key] < floor then return true end
	lastAt[key] = atMs
	return false
end

--- A 32-bit FNV-1a hash of a string, as eight hex digits.
local function fnv(text)
	local hash = 2166136261
	for index = 1, #text do
		hash = ((hash ~ text:byte(index)) * 16777619) & 0xFFFFFFFF
	end
	return ('%08x'):format(hash)
end

--- A fingerprint of a look: its length and a hash of a canonical rendering.
--
-- CANONICAL AND NOT `json.encode`, whose key order follows `pairs` and is not
-- promised to repeat for two equal tables. The body is walked in its own array
-- order, the nine slots in theirs, the outfits by index and their slots sorted,
-- so the same look always renders the same text. The length rides with the hash
-- so a collision would have to match both.
-- @param look table { body, equipment, wardrobe } as stored in `looks`
-- @return string
function M.LookFingerprint(look)
	local parts = { tostring(look.body.family) }
	local groups = look.body.groups
	for index = 1, #groups do
		local group = groups[index]
		parts[#parts + 1] = group.part .. ':' .. group.name
		for keyIndex = 1, #group.keys do
			local key = group.keys[keyIndex]
			parts[#parts + 1] = key[1] .. '=' .. key[2]
		end
	end
	for index = 1, #SLOTS do parts[#parts + 1] = tostring(look.equipment[SLOTS[index]]) end
	parts[#parts + 1] = 'active=' .. tostring(look.wardrobe.active)
	local outfitSlots = {}
	for slot in pairs(IS_OUTFIT_SLOT) do outfitSlots[#outfitSlots + 1] = slot end
	table.sort(outfitSlots)
	for index = 0, OUTFITS - 1 do
		local overrides = look.wardrobe.outfits[tostring(index)]
		if overrides ~= nil then
			parts[#parts + 1] = 'outfit' .. index
			for slotIndex = 1, #outfitSlots do
				parts[#parts + 1] = tostring(overrides[outfitSlots[slotIndex]])
			end
		end
	end
	local text = table.concat(parts, '|')
	return #text .. ':' .. fnv(text)
end

--- Whether a value is a non-zero sixteen-digit engine hash.
local function fixedHash(value)
	return isHash(value, false)
end

--- Whether a body has the shape and the bounds the platform accepts.
-- Refused whole when it is wrong, and answered, so the client stops sending it
-- rather than retrying a body this server will never read.
local function validBody(body)
	if type(body) ~= 'table' or type(body.groups) ~= 'table' then return false end
	if not M.IsFamily(body.family) then return false end
	local count = #body.groups
	if count == 0 or count > 64 then return false end
	local seen = {}
	for index, group in pairs(body.groups) do
		if not isInteger(index) or index < 1 or index > count or type(group) ~= 'table' then
			return false
		end
		if not PARTS[group.part] then return false end
		if not fixedHash(group.name) or type(group.keys) ~= 'table' then return false end
		local id = group.part .. ':' .. group.name:lower()
		if seen[id] then return false end
		seen[id] = true
		local keys = #group.keys
		if keys == 0 or keys > 64 then return false end
		for keyIndex, key in pairs(group.keys) do
			if not isInteger(keyIndex) or keyIndex < 1 or keyIndex > keys or type(key) ~= 'table' or
				#key ~= 2 or not fixedHash(key[1]) or not fixedHash(key[2]) then
				return false
			end
		end
	end
	local encoded, text = pcall(json.encode, body)
	return encoded and type(text) == 'string' and #text <= MAX_BODY_BYTES
end

--- Whether a value is a record name or false.
local function validItem(value)
	return recordOf(value) ~= nil
end

--- All nine slots, an unreadable one as empty.
-- An item that cannot be read costs its slot and never the whole body: being
-- drawn in the wrong jacket beats not being drawn at all.
local function equipmentOf(value)
	local clean = {}
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		local item = type(value) == 'table' and value[slot] or false
		clean[slot] = validItem(item) and item or false
	end
	return clean
end

--- The readable active outfit and outfit overrides.
local function wardrobeOf(value)
	local wardrobe = { outfits = {} }
	if type(value) ~= 'table' then return wardrobe end
	if isInteger(value.active) and value.active >= 0 and value.active < OUTFITS then
		wardrobe.active = value.active
	end
	for index, slots in pairs(type(value.outfits) == 'table' and value.outfits or {}) do
		local number = tonumber(index)
		if isInteger(number) and number >= 0 and number < OUTFITS and type(slots) == 'table' then
			local clean = {}
			for slot, item in pairs(slots) do
				if IS_OUTFIT_SLOT[slot] and validItem(item) then clean[slot] = item end
			end
			wardrobe.outfits[tostring(math.floor(number))] = clean
		end
	end
	return wardrobe
end

--- The numeric player ids of a host list.
local function playerIds(list)
	local ids = {}
	for _, id in ipairs(list) do
		id = tonumber(id)
		if id then ids[#ids + 1] = id end
	end
	return ids
end

--- Every connected player id, empty when it cannot be read.
local function everybody()
	local read, list = pcall(Open77.players.all)
	return playerIds(read and type(list) == 'table' and list or {})
end

--- The looks this half is holding, and for whom.
-- The single answer to "why can nobody see that player": a player who is not in
-- this list is drawn by nobody, wherever the fault actually lies.
local function heldLooks()
	local ids = {}
	for id in pairs(looks) do ids[#ids + 1] = tostring(id) end
	table.sort(ids)
	return #ids, table.concat(ids, ' ')
end

--- Sends one player's look, or its absence, to one other viewer, and says
-- whether it went out. Never to its owner: that player's own look is the engine's.
local function deliver(viewer, player)
	if viewer == player then return false end
	local look = looks[player]
	if look == nil then return false end
	if absent[player] then
		TriggerClientEvent(M.Event.LOOK, viewer, player, false)
	else
		TriggerClientEvent(M.Event.LOOK, viewer, player, look)
	end
	return true
end

--- Sends a player's look to everybody else, and answers how many got it.
local function broadcast(player)
	local handed = 0
	for _, other in ipairs(everybody()) do
		if deliver(other, player) then handed = handed + 1 end
	end
	return handed
end

--- The players in a routing bucket, or everybody when it cannot be read.
local function playersIn(bucket)
	local read, list = pcall(Open77.players.inBucket, bucket)
	if not read or type(list) ~= 'table' then return everybody() end
	return playerIds(list)
end

--- A player's current routing bucket, nil when it cannot be read.
local function bucketOf(player)
	local read, bucket = pcall(Open77.routingBuckets.getPlayer, player)
	return read and tonumber(bucket) or nil
end

-- ── the fitting-room grant ───────────────────────────────────────────────────
-- WHY THE CLOTHING SAVE NEEDS ONE. `SAVE_CLOTHING` asked four questions -- is
-- this a table, is it too soon, is a character loaded, is it THIS character --
-- and then wrote whatever nine `Items.*` records the payload named. Not one of
-- them asks where the player is standing or whether a fitting room was ever put
-- up, so a rewritten client dressed itself out of the whole catalogue, from
-- anywhere in the city, as often as the 2 s floor allowed.
--
-- That is the same argument that retired the `opx.appearance.wardrobe` command
-- (see `VIEW_COMMANDS` below: "a free door onto a priced room is not a
-- convenience, it is the price being optional"). The command was shut and the
-- net event was left open, and the net event is the bigger door of the two: it
-- needs no room at all.
--
-- AN OPEN GRANT IS NOT A BILL. It says only that a door THIS SERVER KNOWS ABOUT
-- put a fitting room up for this player -- a clothing store, a staff member, or
-- the character's own creation -- and those rooms are free. A SHOP's room is a
-- PRICED grant: the save that leaves it is diffed here against the stored
-- record, the moved slots are charged through the shop's own function, and the
-- record is written only once that charge went through (`admitSave`). The shop
-- used to be told the slots by the client, after the save, on an event a client
-- could simply not send.

-- How long one grant lets a client save for, in milliseconds.
--
-- IT HAS TO OUTLIVE A BROWSE, and nothing tells this half when a room closed.
-- The client lends its puppet to the room, saves nothing while it is lent, and
-- sends the one save a debounce later -- so the window has to cover a player
-- reading through every jacket the catalogue holds, that debounce, and the
-- bill-then-restore round trip `modules/shops` does on top of it when the money
-- is not there. Ten minutes is generous; it is also finite and it is tied to a
-- door, which is the whole of the difference from what was here before.
local DRESSING_MS = 600000

-- How long an open room's grant may be kept alive by its client (`ROOM_ALIVE`),
-- counted from the ask. Half an hour of browsing is generous; past it the room
-- is somebody who walked away with it open.
local ROOM_CAP_MS = 30 * 60 * 1000

-- source -> the grants this connection holds, three kinds:
--   open    { untilMs, owner }          any save, free: the join's own room, a
--                                       staff member, a clothing store
--   priced  { untilMs, owner, charge }  any save, and the slots it moves are
--                                       charged through `charge` BEFORE it is
--                                       written: a shop's fitting room
--   looks   { { untilMs, owner, wear } } one save, free, of exactly the look the
--                                       server put on: a bought uniform, a saved
--                                       outfit, a share code
local dressing = {}

-- How many look grants one connection may hold at once. Each is spent by the
-- one save it was handed for; the bound only stops a loop of doors piling them.
local MAX_LOOK_GRANTS = 8

-- The `WARDROBE.OFFER_POLICY` this half resolved at Init, so the join's own room
-- -- which the client offers, and which this half is never told about -- can be
-- granted by the same setting that decides whether it appears.
local wardrobeOffer = M.WARDROBE_POLICY_DEFAULT

--- The grants a connection still holds, the expired ones dropped; nil for none.
local function grantsOf(source)
	local held = dressing[source]
	if held == nil then return nil end
	local now = OPX.Now()
	if held.open ~= nil and now >= held.open.untilMs then held.open = nil end
	if held.priced ~= nil and now >= held.priced.untilMs then held.priced = nil end
	local kept = {}
	for index = 1, #held.looks do
		if now < held.looks[index].untilMs then kept[#kept + 1] = held.looks[index] end
	end
	held.looks = kept
	if held.open == nil and held.priced == nil and #kept == 0 then
		dressing[source] = nil
		return nil
	end
	return held
end

--- Whether this player may have an authoritative clothing write right now.
local function dressed(source)
	return grantsOf(source) ~= nil
end

--- The record a stored slot holds, false for an empty or unreadable one.
local function storedSlot(stored, slot)
	local equipment = type(stored) == 'table' and stored.equipment or nil
	local worn = type(equipment) == 'table' and equipment[slot] or false
	if worn == nil then worn = false end
	return worn
end

--- The outfit overrides of a stored record, an empty table for none.
local function storedOutfits(stored)
	local wardrobe = type(stored) == 'table' and stored.wardrobe or nil
	return type(wardrobe) == 'table' and type(wardrobe.outfits) == 'table' and wardrobe.outfits or {}
end

--- The slots a save moves against what is stored, in canonical order.
-- @author dop42
--
-- THE EQUIPMENT AND THE OUTFIT OVERRIDES BOTH COUNT. The seven wardrobe outfits
-- override the visible slots when one is active, so a garment written into an
-- override is a garment worn: billing the equipment alone would make every
-- purchase free to a client that saved it one level down. Which outfit is
-- ACTIVE is not a purchase -- flipping between sets you own buys nothing.
-- @param stored table|false the canonical record held, false for none
-- @param after table the canonical record arriving
-- @return table an array of slot names
function M.Clothing.Moved(stored, after)
	local seen = {}
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		if storedSlot(stored, slot) ~= after.equipment[slot] then seen[slot] = true end
	end
	local before = storedOutfits(stored)
	for index = 0, OUTFITS - 1 do
		local a = after.wardrobe.outfits[tostring(index)] or {}
		local b = before[tostring(index)] or {}
		for slot in pairs(IS_OUTFIT_SLOT) do
			if a[slot] ~= b[slot] then seen[slot] = true end
		end
	end
	local moved = {}
	for index = 1, #SLOTS do
		if seen[SLOTS[index]] then moved[#moved + 1] = SLOTS[index] end
	end
	return moved
end

--- Whether a save is exactly the look a look grant was handed for.
-- The slots the look names hold its record -- or nothing, which is what a body
-- that cannot wear a piece is dressed in -- and every other slot, and every
-- outfit override, is what is stored. Nothing else rides along for free.
local function fitsLook(wear, stored, after)
	for index = 1, #SLOTS do
		local slot = SLOTS[index]
		local now = after.equipment[slot]
		local wanted = wear[slot]
		if wanted ~= nil then
			if now ~= wanted and now ~= false then return false end
		elseif now ~= storedSlot(stored, slot) then
			return false
		end
	end
	local before = storedOutfits(stored)
	for index = 0, OUTFITS - 1 do
		local a = after.wardrobe.outfits[tostring(index)] or {}
		local b = before[tostring(index)] or {}
		for slot in pairs(IS_OUTFIT_SLOT) do
			if a[slot] ~= b[slot] then return false end
		end
	end
	return true
end

--- Decides whether a save may be written, charging for it where a shop asks.
-- Coroutine only: a charge moves money, which may write.
--
-- THE SERVER COMPUTES THE BILL. The shop used to be told which slots changed by
-- the client, after the fact, on its own event -- so a client that never sent
-- that event kept the clothes and paid nothing. The slots are now read off the
-- stored record and the one arriving, and the money is taken before the record
-- is written; a charge that fails is a save refused, and the client puts the
-- stored look back.
-- @return table|nil `{ undo = function|nil }` when it may be written
-- @return string|nil the refusal code
--- Runs one charge function, answering `(paid, code, undo)` and never raising.
local function runCharge(fn, owner, source, ...)
	local ran, paid, code, undo = pcall(fn, source, ...)
	if not ran then
		Open77.log.error(('[appearance] the %s charge for player %d raised: %s')
			:format(owner, source, tostring(paid)))
		return false, 'clothing.unpaid'
	end
	if paid ~= true then return false, type(code) == 'string' and code or 'clothing.unpaid' end
	return true, nil, type(undo) == 'function' and undo or nil
end

local function admitSave(source, player, canonical)
	local held = grantsOf(source)
	if held == nil then return nil, 'clothing.noFittingRoom' end
	local stored = player.PlayerData.clothing
	-- nil is "the stored record could not be read", which `SaveClothing` refuses.
	if stored == nil then return {} end

	-- A LOOK WITH A PRICE IS BILLED HERE, ON THE SAVE, and not when it was put
	-- on. A shop's uniform used to be charged the moment it was picked, so a
	-- Cancel kept the money and dropped the clothes; now the grant carries a
	-- `bill`, run only by the save that keeps it. A room left by Cancel saves
	-- nothing and costs nothing.
	local undos = {}
	local function settle(code)
		for index = #undos, 1, -1 do pcall(undos[index]) end
		return nil, code
	end
	local function bill(grant)
		if type(grant.bill) ~= 'function' then return true end
		local paid, code, undo = runCharge(grant.bill, grant.owner, source)
		if not paid then return false, code end
		if undo ~= nil then undos[#undos + 1] = undo end
		return true
	end
	local function done()
		if #undos == 0 then return {} end
		return { undo = function() for index = #undos, 1, -1 do pcall(undos[index]) end end }
	end

	for index = 1, #held.looks do
		local grant = held.looks[index]
		if fitsLook(grant.wear, stored, canonical) then
			local paid, code = bill(grant)
			if not paid then return settle(code) end
			table.remove(held.looks, index)
			return done()
		end
	end
	if held.open ~= nil then return {} end

	local priced = held.priced
	if priced == nil then return nil, 'clothing.noFittingRoom' end
	-- A LOOK'S OWN SLOTS ARE NOT BILLED AGAIN BY THE ROOM. A uniform picked
	-- inside the room is laid on its draft, so the save that leaves the room
	-- carries it beside whatever else moved: the slots that are wearing it are
	-- the look's, billed once at the look's price, and only the rest is the
	-- room's to charge by the slot. A piece this body could not wear kept the
	-- garment it had, which moved nothing and is billed nothing; it used to make
	-- the whole uniform count as not worn and bill every slot of it again.
	local prepaid, spent = {}, {}
	for index = #held.looks, 1, -1 do
		local grant = held.looks[index]
		local matched = {}
		for slot, wanted in pairs(grant.wear) do
			if wanted ~= false and canonical.equipment[slot] == wanted then matched[#matched + 1] = slot end
		end
		if #matched > 0 then
			local paid, code = bill(grant)
			if not paid then return settle(code) end
			for _, slot in ipairs(matched) do prepaid[slot] = true end
			-- Spent only once the whole save is paid for: a refusal below gives
			-- the money back and must leave the grant to be used again.
			spent[#spent + 1] = index
		end
	end
	local function spend()
		for _, index in ipairs(spent) do table.remove(held.looks, index) end
	end
	local slots = {}
	local moved = M.Clothing.Moved(stored, canonical)
	for index = 1, #moved do
		if not prepaid[moved[index]] then slots[#slots + 1] = moved[index] end
	end
	if #slots == 0 then
		spend()
		return done()
	end
	local paid, code, undo = runCharge(priced.charge, priced.owner, source, slots)
	if not paid then return settle(code) end
	if undo ~= nil then undos[#undos + 1] = undo end
	spend()
	return done()
end

--- Forgets a departed player's look, absence, warning, floors and grant.
local function forget(player)
	looks[player], absent[player], warned[player] = nil, nil, nil
	printed[player] = nil
	dressing[player] = nil
	local prefix = ':' .. player
	for key in pairs(lastAt) do
		if key:sub(-#prefix) == prefix then lastAt[key] = nil end
	end
end

-- ── the wire doors ───────────────────────────────────────────────────────────

--- Registers every event handler.
-- Each save door checks its cooldown and resolves the connection's character
-- BEFORE its `CreateThread`: the payload names a character only so that a save
-- captured for the one before a switch can be refused.
local function registerEvents()
	RegisterNetEvent(M.Event.SAVE_FACE, function(payload)
		local src = tonumber(source)
		if not src then return end
		local operation = M.Operation.SAVE_FACE
		if type(payload) ~= 'table' then
			return M.RefuseSave(src, 'error.badRequest', operation)
		end
		if OPX.Cooling(src, 'appearance.request', COOLDOWN_MS) then
			return M.RefuseSave(src, 'error.tooFast', operation)
		end

		local player = character and character.GetPlayer(src) or nil
		if not player then return M.RefuseSave(src, 'error.notLoggedIn', operation) end
		-- Optional, and only ever a reason to refuse: a client that does not send
		-- it still saves.
		if payload.citizenId ~= nil and payload.citizenId ~= player.PlayerData.citizenId then
			return M.RefuseSave(src, 'appearance.stale', operation)
		end

		local snapshot = payload.snapshot or payload
		-- Sent by a creation and by nothing else: an edit cannot change a body
		-- family, so an edit has no reason to name one.
		local family = payload.family
		CreateThread(function()
			local saved = M.SaveAppearance(player, snapshot)
			if not saved.ok then
				Open77.log.warn(('[appearance] %d sent an unusable face: %s (%s)')
					:format(src, tostring(saved.error), tostring(saved.detail)))
				return M.RefuseSave(src, saved.error, operation)
			end
			-- After the face and never before it: a face the server would not take
			-- is a creation that did not happen, and its body belongs to nobody.
			if family ~= nil then M.AdoptBodyFamily(player, family) end
		end)
	end)

	-- A ROOM STILL OPEN KEEPS ITS GRANT. The client says so every two minutes
	-- while its fitting room is up; the room's grant (open or priced, never a
	-- one-look grant) is pushed a full window on, never past `ROOM_CAP_MS` from
	-- the ask. A forged ping keeps alive a grant the player already holds, for
	-- at most the cap, and grants nothing that was not granted.
	RegisterNetEvent(M.Event.ROOM_ALIVE, function()
		local src = tonumber(source)
		if src == nil or src <= 0 then return end
		local held = grantsOf(src)
		if held == nil then return end
		local now = OPX.Now()
		for _, grant in ipairs({ held.priced, held.open }) do
			if grant ~= nil then
				local cap = (grant.sinceMs or now) + ROOM_CAP_MS
				grant.untilMs = math.min(cap, math.max(grant.untilMs, now + DRESSING_MS))
			end
		end
	end)

	RegisterNetEvent(M.Event.SAVE_CLOTHING, function(payload)
		local src = tonumber(source)
		if not src then return end
		local operation = M.Operation.SAVE_CLOTHING
		if type(payload) ~= 'table' then
			return M.RefuseSave(src, 'error.badRequest', operation)
		end
		if OPX.Cooling(src, 'clothing.request', COOLDOWN_MS) then
			return M.RefuseSave(src, 'error.tooFast', operation)
		end

		local player = character and character.GetPlayer(src) or nil
		if not player then return M.RefuseSave(src, 'error.notLoggedIn', operation) end
		if payload.citizenId ~= player.PlayerData.citizenId then
			return M.RefuseSave(src, 'clothing.stale', operation)
		end
		-- THE ONLY QUESTION HERE THAT IS NOT ABOUT IDENTITY. Everything above
		-- asks who is sending; this asks whether anybody ever opened a room for
		-- them to change in. See `the fitting-room grant` above for why a save
		-- that did not come through one is a wardrobe with no door on it.
		if not dressed(src) then
			OPX.Audit.Player(player, 'clothing.refused', nil, { reason = 'no_fitting_room' })
			return M.RefuseSave(src, 'clothing.noFittingRoom', operation)
		end

		CreateThread(function()
			local canonical, invalid = Clothing.Canonical(payload.clothing)
			if not canonical then
				Open77.log.warn(('[appearance] %d: clothing not saved: clothing.invalid (%s)')
					:format(src, tostring(invalid)))
				return M.RefuseSave(src, 'clothing.invalid', operation)
			end
			local admitted, refusal = admitSave(src, player, canonical)
			if admitted == nil then
				OPX.Audit.Player(player, 'clothing.refused', nil, { reason = refusal })
				return M.RefuseSave(src, refusal, operation)
			end
			local saved = M.SaveClothing(player, canonical)
			if not saved.ok then
				-- Charged and not written: the money goes back, or the player paid
				-- for clothes that do not survive the session.
				if admitted.undo ~= nil then pcall(admitted.undo) end
				Open77.log.warn(('[appearance] %d: clothing not saved: %s (%s)')
					:format(src, tostring(saved.error), tostring(saved.detail)))
				M.RefuseSave(src, saved.error, operation)
			end
		end)
	end)

	RegisterNetEvent(M.Event.PRESENT, function(body, equipment, wardrobe, sequence)
		local player = tonumber(source)
		if not player or player <= 0 or not isInteger(sequence) or sequence < 1 then return end
		if not presenting() then
			if not saidPresentingOff then
				saidPresentingOff = true
				Open77.log.warn('[appearance] PRESENT_BODIES is false: every look is being dropped, ' ..
					'so no player can be drawn by anybody. Set it true, or leave it unset.')
			end
			return
		end
		if cooled('present', player) then return end

		if not validBody(body) then
			if not warned[player] then
				warned[player] = true
				Open77.log.warn(('[appearance] player %d published a body this server cannot read; ' ..
					'other players cannot draw them'):format(player))
			end
			TriggerClientEvent(M.Event.PRESENT_ACK, player, sequence, false)
			return
		end

		local look = { body = body, equipment = equipmentOf(equipment), wardrobe = wardrobeOf(wardrobe) }
		local encoded, text = pcall(json.encode, { look.equipment, look.wardrobe })
		if not encoded or type(text) ~= 'string' or #text > MAX_CLOTHING_BYTES then
			look.equipment, look.wardrobe = equipmentOf(nil), wardrobeOf(nil)
		end

		warned[player] = nil
		-- THE SAME LOOK IS NOT SENT TO EVERYBODY TWICE. A client re-publishes an
		-- identical look whenever an acknowledgement went missing, and a modified
		-- one can re-publish it on every floor: every peer already holds it, a
		-- newcomer is handed it by the replay and by a bucket change, so only a
		-- look that changed -- or one coming back after a withdrawal -- goes out.
		-- It is still acknowledged, or the client would keep retrying.
		local fingerprint = M.LookFingerprint(look)
		if printed[player] == fingerprint and not absent[player] and looks[player] ~= nil then
			looks[player] = look
			Open77.log.debug(('[appearance] player %d published the look it already has; ' ..
				'nothing re-sent'):format(player))
			TriggerClientEvent(M.Event.PRESENT_ACK, player, sequence, true)
			return
		end
		printed[player] = fingerprint
		looks[player] = look
		absent[player] = nil
		local handed = broadcast(player)
		-- Said on every acceptance, because the alternative is a player nobody can
		-- see and a server log that says nothing at all about it.
		local held, who = heldLooks()
		Open77.log.info(('[appearance] look stored for player %d (%s, %d group(s)): handed to %d ' ..
			'peer(s); holding %d [%s]'):format(player, tostring(body.family),
			type(body.groups) == 'table' and #body.groups or 0, handed, held, who))
		TriggerClientEvent(M.Event.PRESENT_ACK, player, sequence, true)
	end)

	RegisterNetEvent(M.Event.REPLAY, function(sequence)
		local player = tonumber(source)
		if not player or player <= 0 or not isInteger(sequence) then return end
		if not presenting() then return end
		if cooled('replay', player) then return end
		local handed = 0
		for other in pairs(looks) do
			if deliver(player, other) then handed = handed + 1 end
		end
		local held, who = heldLooks()
		Open77.log.info(('[appearance] player %d asked for looks: holding %d [%s], handed over %d')
			:format(player, held, who, handed))
		TriggerClientEvent(M.Event.REPLAYED, player, sequence)
	end)

	RegisterNetEvent(M.Event.ABSENT, function()
		local player = tonumber(source)
		if not player or player <= 0 or not presenting() or absent[player] then return end
		absent[player] = true
		if looks[player] ~= nil then broadcast(player) end
	end)

	-- The `DIAGNOSTIC` handler was here: forty lines per player per session, its
	-- own counter, its own truncation. `core/server/note.lua` is that door now,
	-- with one budget, one rate window and one counter for every module -- which
	-- is the point, since two separate bounds on the same journal each think they
	-- are the only one.

	-- The native roster retires the replicas of a player who changes bucket, and
	-- a character being placed moves them out of their selection bucket. So both
	-- sides are handed each other's looks again, and a move another one has
	-- already superseded is ignored.
	AddEventHandler(HOST_BUCKET_CHANGE, function(player, bucket, previous)
		player, bucket, previous = tonumber(player), tonumber(bucket), tonumber(previous)
		if not player or player <= 0 or not bucket or bucket == previous then return end
		if not presenting() then return end
		local read, name = pcall(Open77.players.name, player)
		if not read or name == nil then return end
		local current = bucketOf(player)
		if current ~= nil and current ~= bucket then return end
		for _, other in ipairs(playersIn(bucket)) do
			if other ~= player then
				deliver(player, other)
				deliver(other, player)
			end
		end
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player then forget(player) end
	end)
end

--- Tells a client which save was refused, and with what code.
-- @author dop42
--
-- A face refusal also goes through `OPX.Refuse`, whose catalogue guarantee means
-- the player reads it in their own language. A clothing refusal does not: those
-- codes are not catalogue keys and were never meant to be shown -- the client
-- publishes and logs them and drops the look. Both carry the operation, without
-- which a client waiting on a face save and a clothing save at once cannot tell
-- which refusal is whose.
-- @param source Source
-- @param code string
-- @param operation string
function M.RefuseSave(source, code, operation)
	source = tonumber(source)
	if not source or source <= 0 then return end
	if operation == M.Operation.SAVE_FACE then OPX.Refuse(source, code, operation) end
	TriggerClientEvent(M.Event.REFUSED, source, tostring(code), operation)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds state and contributes this module's table. Never yields.
function M.Init()
	looks, absent, lastAt, warned = {}, {}, {}, {}
	printed = {}
	dressing = {}

	-- Resolved once, on this half too, for the reason the client resolves it
	-- once: a policy read per join is a typo reported on every join. The join is
	-- the one fitting room this half never puts up itself -- the client offers it
	-- off `OFFER_POLICY` the moment a character enters the world -- so reading
	-- the same setting is the only way the grant can follow the room.
	wardrobeOffer = M.ResolveWardrobePolicy()

	-- Resolved once: a ceiling read per save would let a changed setting measure a
	-- half-finished save against something else.
	local ceiling = tonumber(M.Settings.MAX_JSON_BYTES)
	if not OPX.Math.IsFinite(ceiling) or ceiling < 1024 then ceiling = 49152 end
	M.MaxFaceBytes = math.floor(ceiling)

	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the contract. Nothing may read one before this phase ends.
function M.Api()
	--- Lets one player's client save what it is wearing for the next few minutes.
	--
	-- WHOEVER CALLS THIS HAS ALREADY DECIDED THEY MAY, exactly as with
	-- `OpenWardrobe` below: this module holds no notion of a shop, a store, a
	-- till or a staff grant, and the caller's own door is where the player was
	-- checked. `shops` measures the distance to the shop before it dresses
	-- anybody; `clothing` measures it to the store; `admin` reads its ACL.
	--
	-- IT IS FOR DOORS THAT DRESS WITHOUT A ROOM. A caller that puts the fitting
	-- room up should use `OpenWardrobe`, which grants this for itself. This one
	-- exists for the paths that put clothes STRAIGHT ON -- a bought uniform, a
	-- saved outfit, a shared code -- where the client's own save is the only
	-- thing that follows and would otherwise be refused as roomless.
	-- @author dop42
	--
	-- THREE KINDS, and the caller picks by what it passes. Nothing: an OPEN grant,
	-- any save for ten minutes, free -- the join's room, staff, a clothing store.
	-- `{ charge = fn }`: a PRICED one -- any save, and the slots it moves against
	-- the stored record are passed to `fn(source, slots)` before anything is
	-- written; `fn` answers `true[, nil, undo]` or `false, code`, and a refusal
	-- is the save refused. `{ wear = { slot = record|false } }`: a LOOK grant --
	-- ONE free save of exactly that look on top of what is stored, which is what
	-- a door that puts clothes on (a bought uniform, a saved outfit, a code)
	-- needs, and all it gets: an open grant there was ten minutes of the whole
	-- catalogue for free, from anywhere, behind a shop that charges.
	-- @param playerId integer
	-- @param owner string the caller's own name, for the journal
	-- @param options table|nil `charge` or `wear`, see above
	-- @return boolean
	-- @return string|nil the refusal
	function M.AllowClothingSave(playerId, owner, options)
		local id = tonumber(playerId)
		if id == nil or id <= 0 then return false, 'invalid_player' end
		options = type(options) == 'table' and options or {}
		local grant = { untilMs = OPX.Now() + DRESSING_MS, owner = tostring(owner or '?'),
			sinceMs = OPX.Now() }
		-- A look's price, run by the save that keeps it (see `admitSave`).
		if type(options.bill) == 'function' then grant.bill = options.bill end
		local wear
		if type(options.charge) ~= 'function' and type(options.wear) == 'table' then
			wear = {}
			for slot, record in pairs(options.wear) do
				if not IS_SLOT[slot] then return false, 'invalid_slot' end
				local clean = recordOf(record)
				if clean == nil then return false, 'invalid_item' end
				wear[slot] = clean
			end
		end
		local held = grantsOf(id) or { looks = {} }
		local kind
		if type(options.charge) == 'function' then
			grant.charge, held.priced, kind = options.charge, grant, 'priced'
		elseif wear ~= nil then
			grant.wear, kind = wear, 'one look'
			held.looks[#held.looks + 1] = grant
			while #held.looks > MAX_LOOK_GRANTS do table.remove(held.looks, 1) end
		else
			held.open, kind = grant, 'open'
		end
		dressing[id] = held
		Open77.log.debug(('[appearance] %s may save clothing for player %d (%s)')
			:format(grant.owner, id, kind))
		return true
	end

	--- The owner of the priced room a player holds right now, or nil.
	--
	-- A READ OF THE GRANT, not of the screen: this half never hears that a room
	-- closed, so an unexpired priced grant is the best answer there is to "is
	-- this player in a shop's room". What it guards is a door that puts clothes
	-- on INSIDE that room, so the room's own charge bills them -- `shops`'s share
	-- codes, which used to dress a player free from anywhere.
	-- @param playerId integer
	-- @return string|nil the owner the room was opened under
	function M.PricedRoom(playerId)
		local id = tonumber(playerId)
		if id == nil or id <= 0 then return nil end
		local held = grantsOf(id)
		return held ~= nil and held.priced ~= nil and held.priced.owner or nil
	end

	--- Asks one player's client to put the fitting room up.
	--
	-- WHOEVER CALLS THIS HAS ALREADY DECIDED THEY MAY. This module holds no
	-- notion of staff and checks no grant: the caller's own command is where the
	-- ACL is read, which is the same division every other contract here keeps.
	-- What it does own is the id: a player who is not connected is refused here
	-- rather than becoming a `TriggerClientEvent` into nothing.
	--
	-- Answers only whether the ASK went out. Whether a room opens is the client's
	-- to decide and it may well say no -- the puppet has to be alive on foot and
	-- nothing else may hold the keyboard -- so a true here is not a room.
	-- @author dop42
	-- @param playerId integer
	-- @param options table|nil `{ owner, charge }`: a shop's room is priced, see
	--        `AllowClothingSave`; no options is a free room
	-- @return boolean
	-- @return string|nil the refusal
	function M.OpenWardrobe(playerId, options)
		local id = tonumber(playerId)
		if id == nil or id <= 0 then return false, 'invalid_player' end
		-- NO CONNECTION CHECK HERE, deliberately. There is no `players.exists` on
		-- this build, and the callers that matter resolve their target through
		-- `Server.Target` first, which does. Inventing a second, weaker check out
		-- of `players.all` would be a roster walk per call that answers the same
		-- question worse.
		--
		-- THE GRANT GOES WITH THE ASK and not with the room opening, because this
		-- half never hears that one did. A player whose client refuses the room
		-- holds a grant they cannot use: they still have to change clothes
		-- somehow for it to matter, and every way of doing that is a door that
		-- would have granted it anyway.
		options = type(options) == 'table' and options or {}
		local granted, refused = M.AllowClothingSave(id, options.owner or 'wardrobe',
			type(options.charge) == 'function' and { charge = options.charge } or nil)
		if not granted then return false, refused end
		TriggerClientEvent(M.Event.OPEN_WARDROBE, id)
		return true
	end

	OPX.Api.Provide('appearance', 1, {
		GetAppearance = M.GetAppearance,
		SaveAppearance = M.SaveAppearance,
		GetClothing = M.GetClothing,
		SaveClothing = M.SaveClothing,
		OpenWardrobe = M.OpenWardrobe,
		AllowClothingSave = M.AllowClothingSave,
		PricedRoom = M.PricedRoom,
	})
end

--- Registers the two commands that put a view up.
-- @author dop42
--
-- WHY THE SERVER AND NOT THE CLIENT. A chat command is a server-side door on
-- every framework this pack runs on, and the state machine it opens lives on the
-- client -- so all this does is name a view and hand it to the caller's own
-- client. Neither command takes an argument: what a player may edit is checked
-- by the state half against the catalogue it streamed, which is where a modified
-- page is refused and a mistyped one is refused alike.
--
-- UNRESTRICTED ON PURPOSE. Both act on the caller alone and there is nothing for
-- the ACL to protect, so a player who has been granted nothing still has to be
-- able to reach their own clothes. The fitting room's door is here as well as
-- behind the panel because `WARDROBE.OFFER_POLICY` only ever offers the room to
-- a character the game's own creator has just built -- so for everybody else
-- these two commands and the key are the whole of the way in.
-- The two doors, as data: the command's name, the catalogue key its help line
-- comes from, and the view it names. One list rather than two registrations, so
-- the boot line below cannot fall out of step with what was registered.
-- THE FITTING ROOM IS NOT ON THIS LIST, and its absence is the point.
--
-- It was, as `opx.appearance.wardrobe`, open to everybody, from anywhere, twice
-- a second. The argument for it was sound when it was written -- under a policy
-- of 'first' or 'never' the room was unreachable for the rest of a character's
-- life -- but it stopped being sound the moment the room acquired a price.
-- `modules/shops` charges per changed slot, and it can only charge for a room
-- IT opened: a player who types a command instead changes all nine slots
-- standing in the street and pays nothing. A free door onto a priced room is
-- not a convenience, it is the price being optional.
--
-- The two halves of the original argument both have doors now, and neither is
-- this one: a player reaches the room at a clothing store, and staff reach it
-- for anybody through `opx.admin.player.wardrobe`. Putting this command back
-- means deciding that clothes are free.
local VIEW_COMMANDS = {
	-- The panel keeps the 2 s it always had. It was briefly 500 ms when the two
	-- doors shared one number, which is looser than the thing it replaced for no
	-- reason anybody chose.
	{ name = 'opx.appearance', help = 'appearance.command.panel', kind = 'panel',
		cooldownMs = 2000 },
}

function M.RegisterCommands()
	local names = {}
	for index = 1, #VIEW_COMMANDS do
		local entry = VIEW_COMMANDS[index]
		OPX.Command.Register(entry.name, {
			restricted = false,
			help = entry.help,
			cooldownMs = entry.cooldownMs or 500,
		}, function(source)
			TriggerClientEvent(M.Event.SHOW, source, entry.kind)
		end)
		names[index] = entry.name .. ' [open]'
	end

	-- Said once, at boot, in the shape the other modules say it. It is the line an
	-- operator reads when a player reports that the panel will not open, and
	-- without it a pack whose commands failed to register looks exactly like one
	-- whose client half is not listening.
	Open77.log.info(('[appearance] commands: %s'):format(table.concat(names, ', ')))
end

--- Wires the doors and hooks the character load. Runs on a coroutine.
function M.Start()
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.error('[appearance] no character contract: no face or clothing can be stored')
		return
	end

	-- A DELETED CHARACTER TAKES ITS CLOTHES WITH IT, and this is what does it: the
	-- table's foreign key never fires, because a character delete is a soft one.
	-- See `character.Event.IN_DELETED`, whose name is rebuilt here the way every
	-- module rebuilds another's -- a bare string would be a typo waiting to happen.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			local purged = M.Storage.PurgeCharacter(citizenId)
			if purged ~= nil and not purged.ok then
				Open77.log.warn(('[appearance] the clothing of the deleted %s was not removed: %s')
					:format(citizenId, tostring(purged.detail or purged.error)))
			end
		end)

	-- THE JOIN'S OWN FITTING ROOM, WHICH THIS HALF NEVER OPENS. The client offers
	-- it off `WARDROBE.OFFER_POLICY` as soon as a character enters the world, and
	-- says nothing to the server about it -- so without this the one room a
	-- player is GUARANTEED, the one a character is dressed in at creation, would
	-- be the only room whose save is refused.
	--
	-- 'first' is read here as 'this character has never had clothing stored',
	-- which is `clothing == false` and is exactly what the creator's own first
	-- save writes over. It is one grant, spent or not, and it cannot come round
	-- again: the row exists from then on. `nil` is not `false` and gets nothing
	-- -- the record could not be read, so the client is not saving anyway.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'loaded'),
		function(source, playerData)
			local id = tonumber(source)
			if id == nil or id <= 0 or type(playerData) ~= 'table' then return end
			local offered = wardrobeOffer == M.WardrobePolicy.ALWAYS
				or (wardrobeOffer == M.WardrobePolicy.FIRST and playerData.clothing == false)
			if offered then M.AllowClothingSave(id, 'join') end
		end)

	registerEvents()
	M.RegisterCommands()

	-- The seam the character module left exactly where its own clothing read used
	-- to be: it yields where that read yielded, which is what makes the session
	-- re-check below it meaningful. Whatever is put in `extras.data` is merged
	-- into PlayerData after the Player is built.
	--
	-- Nothing here may refuse a login. `Load` answers nil for a row it could not
	-- read, and a nil field is not merged at all -- which is exactly right:
	-- PlayerData.clothing then stays nil, the client dresses nothing, and
	-- SaveClothing refuses to write over a record nobody ever saw.
	OPX.Hooks.Register('character:loading', function(extras)
		if OPX.BootError then return end
		extras.data.clothing = M.Clothing.Load(extras.citizenId)
	end)

	if not presenting() then
		Open77.log.info('[appearance] PRESENT_BODIES is false: something else must hand every ' ..
			'look out, or nobody sees anybody')
		return
	end

	-- A restart of this half means every client is holding a look nobody here
	-- knows about any more.
	TriggerClientEvent(M.Event.RESEND, -1)
end

--- Drops the looks held in memory. Nothing here is stored, so there is nothing
--- to write: the next publication rebuilds all of it.
function M.Stop()
	looks, absent, lastAt, warned = {}, {}, {}, {}
	printed = {}
	-- The grants go too. A restart is every fitting room in the city closing at
	-- once, and a grant that outlived one would be a door left open by a room
	-- that no longer exists.
	dressing = {}
end
